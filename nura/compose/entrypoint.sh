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

evmd config set client chain-id "$CHAIN_ID" --home "$NODE_HOME"
evmd config set client keyring-backend "$KEYRING_BACKEND" --home "$NODE_HOME"

# Installs the genesis baked into the image, refuses a checksum mismatch, and
# writes app.toml and config.toml exactly as on a systemd host.
/opt/nura/05_configure_node.sh

exec evmd start --home "$NODE_HOME" --chain-id "$CHAIN_ID" --log_level info
