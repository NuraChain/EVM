#!/usr/bin/env bash
# Starts a Nura node inside the container. Runs on every container start, so
# each step is idempotent: NODE_HOME lives on a persistent volume and is only
# initialized the first time.
set -euo pipefail

: "${NODE_HOME:?Set NODE_HOME}"
: "${MONIKER:?Set MONIKER}"
: "${PERSISTENT_PEERS:?Set PERSISTENT_PEERS to at least the coordinator nodeid@host:26656}"
: "${EXTERNAL_ADDRESS:?Set EXTERNAL_ADDRESS to this server public host:26656}"
# 05_configure_node.sh only warns when this is empty. A container must never
# start a node on a genesis nobody verified.
: "${GENESIS_SHA256:?Set GENESIS_SHA256 to the checksum the coordinator published}"

# evmd calls mkdir("data") relative to the working directory.
cd "$NODE_HOME"

if [[ ! -f "$NODE_HOME/config/genesis.json" ]]; then
	evmd init "$MONIKER" --chain-id "$CHAIN_ID" --home "$NODE_HOME"
	cat <<EOF

This volume now holds a unique consensus key at
  $NODE_HOME/config/priv_validator_key.json
Back it up offline. Never start a second node from a copy of this volume:
two nodes signing with the same key are slashed and tombstoned permanently.

EOF
fi

# Writes a CometBFT key file from a base64 environment variable, so an existing
# node's keys can move into the container without copying files onto the host.
# Runs after init: CometBFT refuses to load a validator key without
# data/priv_validator_state.json, which init creates.
install_key_from_env() {
	local var="$1" file="$2" tmp
	[[ -n "${!var:-}" ]] || return 0
	tmp="$file.from-env.$$"
	if ! (umask 077 && printf '%s' "${!var}" | tr -d '[:space:]' | base64 -d > "$tmp" 2>/dev/null); then
		rm -f "$tmp"
		echo "error: $var is not valid base64. Encode the file with: base64 -w0 <file>" >&2
		exit 1
	fi
	if ! jq -e '.priv_key.value | type == "string"' "$tmp" >/dev/null 2>&1; then
		rm -f "$tmp"
		echo "error: $var does not decode to a CometBFT key file." >&2
		exit 1
	fi
	mv "$tmp" "$file"
	echo "Installed $file from $var"
}

install_key_from_env PRIV_VALIDATOR_KEY_B64 "$NODE_HOME/config/priv_validator_key.json"
install_key_from_env NODE_KEY_B64 "$NODE_HOME/config/node_key.json"

# Public values only, so the operator can check the keys in the deploy log.
echo "Consensus public key: $(jq -r '.pub_key.value' "$NODE_HOME/config/priv_validator_key.json")"
echo "Node ID: $(evmd comet show-node-id --home "$NODE_HOME")"

evmd config set client chain-id "$CHAIN_ID" --home "$NODE_HOME"
evmd config set client keyring-backend "$KEYRING_BACKEND" --home "$NODE_HOME"

# Installs the genesis baked into the image, refuses a checksum mismatch, and
# writes app.toml and config.toml exactly as on a systemd host.
/opt/nura/05_configure_node.sh

exec evmd start --home "$NODE_HOME" --chain-id "$CHAIN_ID" --log_level info
