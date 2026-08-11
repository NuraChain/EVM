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
: "${JSONRPC_ENABLE_INDEXER:=true}"
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

for file in "$APP_TOML" "$CONFIG_TOML" "$GENESIS"; do
	[[ -f "$file" ]] || nura::die "missing $file. Run 01_init_node.sh and copy the final genesis first."
done

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

nura::set_toml "$APP_TOML" "" "minimum-gas-prices" "\"$MIN_GAS_PRICES\""
nura::set_toml "$APP_TOML" "" "pruning" "\"$PRUNING\""

# Keep the query APIs on loopback; put a TLS reverse proxy in front if needed.
nura::set_toml "$APP_TOML" "api" "enable" "true"
nura::set_toml "$APP_TOML" "api" "address" "\"tcp://127.0.0.1:1317\""
nura::set_toml "$APP_TOML" "grpc" "enable" "true"
nura::set_toml "$APP_TOML" "grpc" "address" "\"127.0.0.1:9090\""

echo "Configuring $CONFIG_TOML"

nura::set_toml "$CONFIG_TOML" "rpc" "laddr" "\"tcp://127.0.0.1:26657\""
nura::set_toml "$CONFIG_TOML" "rpc" "unsafe" "false"

nura::set_toml "$CONFIG_TOML" "p2p" "persistent_peers" "\"$PERSISTENT_PEERS\""
nura::set_toml "$CONFIG_TOML" "p2p" "external_address" "\"$EXTERNAL_ADDRESS\""
nura::set_toml "$CONFIG_TOML" "p2p" "addr_book_strict" "true"
nura::set_toml "$CONFIG_TOML" "p2p" "pex" "true"

# Keeps real block time aligned with the blocks_per_year baked into genesis.
nura::set_toml "$CONFIG_TOML" "consensus" "timeout_commit" "\"${SECONDS_PER_BLOCK}s\""

nura::set_toml "$CONFIG_TOML" "instrumentation" "prometheus" "true"

chown "$NODE_USER:$NODE_USER" "$APP_TOML" "$CONFIG_TOML" 2>/dev/null || true

echo
echo "Configured node at $NODE_HOME"
echo "  EIP-155 chain ID   $EVM_CHAIN_ID"
echo "  JSON-RPC           $JSONRPC_ENABLE on $JSONRPC_ADDRESS (namespaces: $JSONRPC_NAMESPACES)"
echo "  minimum gas price  $MIN_GAS_PRICES"
echo "  block time target  ${SECONDS_PER_BLOCK}s"

if [[ -z "$PERSISTENT_PEERS" ]]; then
	echo
	echo "WARNING: PERSISTENT_PEERS is empty. This node has no peers to dial." >&2
fi
