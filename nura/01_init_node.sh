#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
nura::load_env "$SCRIPT_DIR"

: "${NODE_HOME:?Set NODE_HOME}"
: "${MONIKER:?Set MONIKER}"
: "${VALIDATOR_KEY:=validator}"

nura::require_cmd evmd

id -u "$NODE_USER" >/dev/null 2>&1 || nura::die "user '$NODE_USER' does not exist. Run 00_build.sh first."

if [[ ! -d "$NODE_HOME" ]]; then
	nura::require_root
	install -d -o "$NODE_USER" -g "$NODE_USER" -m 0750 "$NODE_HOME"
fi

if [[ ! -f "$NODE_HOME/config/genesis.json" ]]; then
	nura::run_as evmd init "$MONIKER" --chain-id "$CHAIN_ID" --home "$NODE_HOME"
fi

nura::run_as evmd config set client chain-id "$CHAIN_ID" --home "$NODE_HOME"
nura::run_as evmd config set client keyring-backend "$KEYRING_BACKEND" --home "$NODE_HOME"

if ! nura::run_as evmd keys show "$VALIDATOR_KEY" --keyring-backend "$KEYRING_BACKEND" --home "$NODE_HOME" >/dev/null 2>&1; then
	nura::run_as evmd keys add "$VALIDATOR_KEY" \
		--algo eth_secp256k1 \
		--keyring-backend "$KEYRING_BACKEND" \
		--home "$NODE_HOME"
fi

echo
echo "Account address:"
nura::run_as evmd keys show "$VALIDATOR_KEY" --address \
	--keyring-backend "$KEYRING_BACKEND" --home "$NODE_HOME"
echo "Node ID:"
nura::run_as evmd tendermint show-node-id --home "$NODE_HOME"

cat <<EOF

WARNING: this host now holds a unique consensus key at
  $NODE_HOME/config/priv_validator_key.json

Back it up offline, but NEVER run a second node from a copy of this directory.
Two nodes signing with the same key double-sign and are slashed and tombstoned
permanently. priv_validator_state.json must never be rolled back either.
EOF
