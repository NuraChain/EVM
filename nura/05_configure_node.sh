#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
nura::load_env "$SCRIPT_DIR"

: "${NODE_HOME:?Set NODE_HOME}"
: "${EVM_CHAIN_ID:?Set EVM_CHAIN_ID}"
: "${JSONRPC_ENABLE:=true}"
: "${JSONRPC_ADDRESS:=127.0.0.1:8545}"
: "${JSONRPC_WS_ADDRESS:=127.0.0.1:8546}"
: "${JSONRPC_NAMESPACES:=eth,net,web3}"
: "${JSONRPC_WS_ORIGINS:=127.0.0.1,localhost}"
: "${JSONRPC_ENABLE_INDEXER:=true}"
: "${API_ADDRESS:=tcp://127.0.0.1:1317}"
: "${API_ENABLE_UNSAFE_CORS:=false}"
: "${COMET_RPC_ADDRESS:=tcp://127.0.0.1:26657}"
: "${COMET_RPC_CORS_ORIGINS:=}"
: "${PERSISTENT_PEERS:=}"
: "${EXTERNAL_ADDRESS:=}"
: "${PRUNING:=default}"
: "${SECONDS_PER_BLOCK:=5}"
: "${GENESIS_SHA256:=}"

nura::require_cmd awk
nura::validate_uint "$EVM_CHAIN_ID" "EVM_CHAIN_ID"

APP_TOML="$NODE_HOME/config/app.toml"
CONFIG_TOML="$NODE_HOME/config/config.toml"
GENESIS="$NODE_HOME/config/genesis.json"

for file in "$APP_TOML" "$CONFIG_TOML"; do
	[[ -f "$file" ]] || nura::die "missing $file. Run 01_init_node.sh first."
done

# Picks up the post-collect-gentxs genesis, which differs from the one this node
# held while creating its gentx. Running the pre-collect copy is the mismatch
# the checksum check below exists to catch.
nura::sync_genesis

if [[ "$EVM_CHAIN_ID" == "262144" ]]; then
	nura::die "EVM_CHAIN_ID is still cosmos/evm's default of 262144. Claim your own EIP-155 chain ID."
fi

# Exposing personal/debug/miner over a public endpoint hands out key access and
# unbounded tracing to anyone who can reach the port.
for namespace in personal debug miner; do
	if [[ ",$JSONRPC_NAMESPACES," == *",$namespace,"* ]]; then
		nura::die "JSONRPC_NAMESPACES must not contain '$namespace'."
	fi
done

# Without the scheme CometBFT refuses to start with an error that never names
# the setting.
for address in "$API_ADDRESS" "$COMET_RPC_ADDRESS"; do
	[[ "$address" == tcp://* ]] || nura::die "'$address' must start with tcp://, e.g. tcp://0.0.0.0:1317."
done
[[ "$API_ENABLE_UNSAFE_CORS" == "true" || "$API_ENABLE_UNSAFE_CORS" == "false" ]] ||
	nura::die "API_ENABLE_UNSAFE_CORS must be true or false."

if [[ -n "$GENESIS_SHA256" ]]; then
	ACTUAL="$(nura::sha256 "$GENESIS")"
	[[ "$ACTUAL" == "$GENESIS_SHA256" ]] || nura::die "genesis checksum mismatch.
  expected $GENESIS_SHA256
  actual   $ACTUAL
This node holds a different genesis than the coordinator published."
	echo "Genesis checksum verified: $ACTUAL"
else
	echo "WARNING: GENESIS_SHA256 is unset, skipping genesis verification." >&2
fi

# Section-aware TOML setter. Fails loudly when a key is absent rather than
# silently leaving the default in place.
nura::set_toml() {
	local file="$1" section="$2" key="$3" value="$4" tmp
	tmp="$(mktemp)"
	awk -v section="$section" -v key="$key" -v value="$value" '
		BEGIN { current = ""; done = 0 }
		/^[[:space:]]*\[/ {
			header = $0
			sub(/^[[:space:]]*\[/, "", header)
			sub(/\].*$/, "", header)
			current = header
		}
		{
			if (!done && current == section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=") {
				equals = index($0, "=")
				printf "%s= %s\n", substr($0, 1, equals - 1), value
				done = 1
				next
			}
			print
		}
		END { if (!done) exit 3 }
	' "$file" > "$tmp" || { rm -f "$tmp"; nura::die "key '$key' not found in section [$section] of $file"; }
	cat "$tmp" > "$file"
	rm -f "$tmp"
}

echo "Configuring $APP_TOML"

# Without this the node runs with EIP-155 chain ID 262144, and any validator
# whose value differs will reject transactions the others accept.
nura::set_toml "$APP_TOML" "evm" "evm-chain-id" "$EVM_CHAIN_ID"

# cosmos/evm ships JSON-RPC disabled, so an EVM chain otherwise starts with no
# Ethereum endpoint at all.
nura::set_toml "$APP_TOML" "json-rpc" "enable" "$JSONRPC_ENABLE"
nura::set_toml "$APP_TOML" "json-rpc" "address" "\"$JSONRPC_ADDRESS\""
nura::set_toml "$APP_TOML" "json-rpc" "ws-address" "\"$JSONRPC_WS_ADDRESS\""
nura::set_toml "$APP_TOML" "json-rpc" "api" "\"$JSONRPC_NAMESPACES\""
nura::set_toml "$APP_TOML" "json-rpc" "enable-indexer" "$JSONRPC_ENABLE_INDEXER"
nura::set_toml "$APP_TOML" "json-rpc" "allow-insecure-unlock" "false"

# The WebSocket server compares only the Origin header's hostname, so a URL here
# would silently never match, and an empty list rejects every client, including
# ones that send no Origin header.
WS_ORIGINS_TOML=""
IFS=',' read -ra ws_origins <<< "$JSONRPC_WS_ORIGINS"
for origin in "${ws_origins[@]}"; do
	origin="${origin//[[:space:]]/}"
	[[ -n "$origin" ]] || continue
	[[ "$origin" =~ ^(\*|[A-Za-z0-9.-]+)$ ]] ||
		nura::die "JSONRPC_WS_ORIGINS entry '$origin' must be a bare hostname or *, not a URL."
	WS_ORIGINS_TOML+="${WS_ORIGINS_TOML:+, }\"$origin\""
done
[[ -n "$WS_ORIGINS_TOML" ]] || nura::die "JSONRPC_WS_ORIGINS must list at least one hostname, or *."
nura::set_toml "$APP_TOML" "json-rpc" "ws-origins" "[$WS_ORIGINS_TOML]"

nura::set_toml "$APP_TOML" "" "minimum-gas-prices" "\"$MIN_GAS_PRICES\""
nura::set_toml "$APP_TOML" "" "pruning" "\"$PRUNING\""

# Loopback unless API_ADDRESS says otherwise; put a TLS reverse proxy in front
# of anything wider. Browser explorers such as Ping.pub call REST directly, so
# they also need CORS.
nura::set_toml "$APP_TOML" "api" "enable" "true"
nura::set_toml "$APP_TOML" "api" "address" "\"$API_ADDRESS\""
nura::set_toml "$APP_TOML" "api" "enabled-unsafe-cors" "$API_ENABLE_UNSAFE_CORS"
nura::set_toml "$APP_TOML" "grpc" "enable" "true"
nura::set_toml "$APP_TOML" "grpc" "address" "\"127.0.0.1:9090\""

echo "Configuring $CONFIG_TOML"

# Origins (https://host) or *, comma-separated. Empty sends no CORS headers.
COMET_CORS_TOML=""
IFS=',' read -ra comet_origins <<< "$COMET_RPC_CORS_ORIGINS"
for origin in "${comet_origins[@]}"; do
	origin="${origin//[[:space:]]/}"
	[[ -n "$origin" ]] || continue
	[[ "$origin" =~ ^(\*|https?://[A-Za-z0-9.:*-]+)$ ]] ||
		nura::die "COMET_RPC_CORS_ORIGINS entry '$origin' must be * or an origin such as https://explorer.example."
	COMET_CORS_TOML+="${COMET_CORS_TOML:+, }\"$origin\""
done

nura::set_toml "$CONFIG_TOML" "rpc" "laddr" "\"$COMET_RPC_ADDRESS\""
nura::set_toml "$CONFIG_TOML" "rpc" "cors_allowed_origins" "[$COMET_CORS_TOML]"
nura::set_toml "$CONFIG_TOML" "rpc" "unsafe" "false"

nura::set_toml "$CONFIG_TOML" "p2p" "persistent_peers" "\"$PERSISTENT_PEERS\""
nura::set_toml "$CONFIG_TOML" "p2p" "external_address" "\"$EXTERNAL_ADDRESS\""
nura::set_toml "$CONFIG_TOML" "p2p" "addr_book_strict" "true"
nura::set_toml "$CONFIG_TOML" "p2p" "pex" "true"

# `evmd start` always enables the app-side EVM mempool (it forces
# mempool.max-txs=0 over app.toml), and refuses to start unless CometBFT hands
# the mempool to the app. `evmd init` writes "flood".
nura::set_toml "$CONFIG_TOML" "mempool" "type" "\"app\""

# Keeps real block time aligned with the blocks_per_year baked into genesis.
nura::set_toml "$CONFIG_TOML" "consensus" "timeout_commit" "\"${SECONDS_PER_BLOCK}s\""

nura::set_toml "$CONFIG_TOML" "instrumentation" "prometheus" "true"

chown "$NODE_USER:$NODE_USER" "$APP_TOML" "$CONFIG_TOML" 2>/dev/null || true

echo
echo "Configured node at $NODE_HOME"
echo "  EIP-155 chain ID   $EVM_CHAIN_ID"
echo "  JSON-RPC           $JSONRPC_ENABLE on $JSONRPC_ADDRESS (namespaces: $JSONRPC_NAMESPACES)"
echo "  WebSocket origins  $JSONRPC_WS_ORIGINS"
echo "  REST API           $API_ADDRESS (CORS: $API_ENABLE_UNSAFE_CORS)"
echo "  CometBFT RPC       $COMET_RPC_ADDRESS (CORS: ${COMET_RPC_CORS_ORIGINS:-none})"
echo "  minimum gas price  $MIN_GAS_PRICES"
echo "  block time target  ${SECONDS_PER_BLOCK}s"

if [[ -z "$PERSISTENT_PEERS" ]]; then
	echo
	echo "WARNING: PERSISTENT_PEERS is empty. This node has no peers to dial." >&2
fi
