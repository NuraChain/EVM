#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
nura::load_env "$SCRIPT_DIR"

: "${NODE_HOME:?Set NODE_HOME}"
: "${MONIKER:?Set MONIKER}"
: "${VALIDATOR_KEY:=validator}"
: "${GENTX_SELF_DELEGATION:=100000}"

nura::require_cmd evmd jq

SELF_DELEGATION_BASE="$(nura::to_base_units "$GENTX_SELF_DELEGATION" GENTX_SELF_DELEGATION)"

nura::enter_workdir "$NODE_HOME"

# A validator whose node is still catching up is bonded but cannot sign, so it
# starts missing blocks the moment the transaction lands.
CATCHING_UP="$(nura::run_as evmd status --home "$NODE_HOME" | jq -r '.sync_info.catching_up')" ||
	nura::die "cannot reach the local node. Run 07_start.sh first."
[[ "$CATCHING_UP" == "false" ]] ||
	nura::die "the local node is still syncing (catching_up=$CATCHING_UP). Wait until it reaches the chain head."

OPERATOR="$(nura::run_as evmd keys show "$VALIDATOR_KEY" --bech val --address \
	--keyring-backend "$KEYRING_BACKEND" --home "$NODE_HOME")"

if nura::run_as evmd query staking validator "$OPERATOR" --home "$NODE_HOME" >/dev/null 2>&1; then
	nura::die "$OPERATOR is already a validator."
fi

# show-validator prints through cobra, which writes to stderr.
PUBKEY="$(nura::run_as evmd comet show-validator --home "$NODE_HOME" 2>&1 | grep -m1 '"@type"' || true)"
jq -e '."@type" and .key' <<< "$PUBKEY" >/dev/null 2>&1 ||
	nura::die "could not read this node's consensus public key from $NODE_HOME/config/priv_validator_key.json."

# The keyring passphrase prompt needs stdin, so the validator description goes
# through a file the service account can read.
VALIDATOR_JSON="$NODE_HOME/config/create-validator.json"
trap 'rm -f "$VALIDATOR_JSON"' EXIT

# Commission and minimum self-delegation are the gentx defaults, so validators
# that join after launch match the one created at genesis.
jq -n \
	--argjson pubkey "$PUBKEY" \
	--arg amount "${SELF_DELEGATION_BASE}${DENOM}" \
	--arg moniker "$MONIKER" '{
  pubkey: $pubkey,
  amount: $amount,
  moniker: $moniker,
  "commission-rate": "0.1",
  "commission-max-rate": "0.2",
  "commission-max-change-rate": "0.01",
  "min-self-delegation": "1"
}' > "$VALIDATOR_JSON"
chown "$NODE_USER:$NODE_USER" "$VALIDATOR_JSON" 2>/dev/null || true

nura::run_as evmd tx staking create-validator "$VALIDATOR_JSON" \
	--from "$VALIDATOR_KEY" \
	--chain-id "$CHAIN_ID" \
	--gas auto \
	--gas-adjustment 1.5 \
	--gas-prices "$MIN_GAS_PRICES" \
	--keyring-backend "$KEYRING_BACKEND" \
	--home "$NODE_HOME"

cat <<EOF

Submitted create-validator for $OPERATOR
Self-delegation: ${GENTX_SELF_DELEGATION} ${DISPLAY_DENOM}

Confirm it is bonded after a few blocks with:
  sudo -u $NODE_USER bash -c 'cd $NODE_HOME && evmd query staking validator $OPERATOR --home $NODE_HOME'
EOF
