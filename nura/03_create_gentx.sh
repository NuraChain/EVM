#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
nura::load_env "$SCRIPT_DIR"

: "${NODE_HOME:?Set NODE_HOME}"
: "${VALIDATOR_KEY:=validator}"
: "${GENTX_SELF_DELEGATION:=100000}"

nura::require_cmd evmd jq

SELF_DELEGATION_BASE="$(nura::to_base_units "$GENTX_SELF_DELEGATION" GENTX_SELF_DELEGATION)"

# The coordinator's genesis must be in place, otherwise the gentx is signed
# against the wrong chain state and collect-gentxs will reject it.
nura::sync_genesis

nura::enter_workdir "$NODE_HOME"

nura::run_as evmd genesis validate-genesis --home "$NODE_HOME" >/dev/null

# Catches the common mistake of signing a gentx against the stock `evmd init`
# genesis instead of the coordinator's prepared one.
GENESIS_DENOM="$(jq -r '.app_state.staking.params.bond_denom' "$NODE_HOME/config/genesis.json")"
[[ "$GENESIS_DENOM" == "$DENOM" ]] || nura::die "genesis bond_denom is '$GENESIS_DENOM' but DENOM is '$DENOM'. This is not the coordinator's genesis."

nura::run_as evmd genesis gentx "$VALIDATOR_KEY" \
	"${SELF_DELEGATION_BASE}${DENOM}" \
	--chain-id "$CHAIN_ID" \
	--gas-prices "$MIN_GAS_PRICES" \
	--keyring-backend "$KEYRING_BACKEND" \
	--home "$NODE_HOME"

echo
echo "Gentx created under $NODE_HOME/config/gentx"
echo "Self-delegation: ${GENTX_SELF_DELEGATION} ${DISPLAY_DENOM}"
