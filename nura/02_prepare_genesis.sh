#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
nura::load_env "$SCRIPT_DIR"

: "${GENESIS_HOME:?Set GENESIS_HOME}"
: "${SYMBOL:=NURA}"
: "${VALIDATOR_ADDRESSES:?Set VALIDATOR_ADDRESSES as comma-separated account addresses}"
: "${BASE_FEE_WEI:=1000000000}"
: "${GENESIS_BALANCE:=1000000}"
: "${GOV_MIN_DEPOSIT:=10000}"
: "${GOV_EXPEDITED_MIN_DEPOSIT:=50000}"
: "${BLOCK_MAX_GAS:=100000000}"
: "${SECONDS_PER_BLOCK:=5}"
: "${WRAPPED_NATIVE_ADDRESS:?Set WRAPPED_NATIVE_ADDRESS}"
: "${GENESIS_TIME:=}"

nura::require_cmd evmd jq
nura::validate_uint "$BASE_FEE_WEI" "BASE_FEE_WEI"
nura::validate_uint "$SECONDS_PER_BLOCK" "SECONDS_PER_BLOCK"
nura::validate_uint "$BLOCK_MAX_GAS" "BLOCK_MAX_GAS"
nura::validate_hex_address "$WRAPPED_NATIVE_ADDRESS" "WRAPPED_NATIVE_ADDRESS"

# cosmos/evm's example genesis ships a token pair for the WEVMOS test contract.
# Reusing that address would leave a dead pair pointing at the wrong denom.
if [[ "${WRAPPED_NATIVE_ADDRESS,,}" == "0xd4949664cd82660aae99bedc034a0dea8a0bd517" ]]; then
	nura::die "WRAPPED_NATIVE_ADDRESS is cosmos/evm's example WEVMOS address. Choose your own."
fi

GENESIS="$GENESIS_HOME/config/genesis.json"

# `evmd init` refuses to overwrite, and silently regenerating a coordinated
# genesis would invalidate every gentx already collected against it.
if [[ -f "$GENESIS" && "${1:-}" != "--force" ]]; then
	nura::die "$GENESIS already exists. Re-run with --force to discard it and start over."
fi

if [[ ! -d "$GENESIS_HOME" ]]; then
	nura::require_root
	install -d -o "$NODE_USER" -g "$NODE_USER" -m 0750 "$GENESIS_HOME"
fi

nura::enter_workdir "$GENESIS_HOME"

nura::run_as evmd init genesis --chain-id "$CHAIN_ID" --home "$GENESIS_HOME" --overwrite

# 18-decimal amounts exceed bash's integer range, so they are built as strings.
GENESIS_BALANCE_BASE="$(nura::to_base_units "$GENESIS_BALANCE" GENESIS_BALANCE)"
GOV_MIN_DEPOSIT_BASE="$(nura::to_base_units "$GOV_MIN_DEPOSIT" GOV_MIN_DEPOSIT)"
GOV_EXPEDITED_MIN_DEPOSIT_BASE="$(nura::to_base_units "$GOV_EXPEDITED_MIN_DEPOSIT" GOV_EXPEDITED_MIN_DEPOSIT)"
MIN_GAS_PRICE_DEC="$(nura::to_legacy_dec "$MIN_GAS_PRICE_WEI" MIN_GAS_PRICE_WEI)"
BASE_FEE_DEC="$(nura::to_legacy_dec "$BASE_FEE_WEI" BASE_FEE_WEI)"
BLOCKS_PER_YEAR="$(( 31557600 / SECONDS_PER_BLOCK ))"

# 0x...803 is reserved for the vesting precompile, which is listed in
# AvailableStaticPrecompiles but is not built by DefaultStaticPrecompiles.
# Leaving it active advertises a precompile that does not exist.
VESTING_PRECOMPILE="0x0000000000000000000000000000000000000803"

TMP="$GENESIS.tmp"

jq \
	--arg denom "$DENOM" \
	--arg display "$DISPLAY_DENOM" \
	--arg symbol "$SYMBOL" \
	--arg gov_min_deposit "$GOV_MIN_DEPOSIT_BASE" \
	--arg gov_expedited_min_deposit "$GOV_EXPEDITED_MIN_DEPOSIT_BASE" \
	--arg min_gas_price "$MIN_GAS_PRICE_DEC" \
	--arg base_fee "$BASE_FEE_DEC" \
	--arg block_max_gas "$BLOCK_MAX_GAS" \
	--arg blocks_per_year "$BLOCKS_PER_YEAR" \
	--arg werc20 "$WRAPPED_NATIVE_ADDRESS" \
	--arg vesting "$VESTING_PRECOMPILE" '
  .app_state.staking.params.bond_denom = $denom |
  .app_state.mint.params.mint_denom = $denom |
  .app_state.mint.params.blocks_per_year = $blocks_per_year |

  # Both the denom and the amount must be set. Leaving the SDK default of
  # 10000000 base units makes a proposal deposit worth 1e-11 whole tokens.
  .app_state.gov.params.min_deposit = [{ denom: $denom, amount: $gov_min_deposit }] |
  .app_state.gov.params.expedited_min_deposit = [{ denom: $denom, amount: $gov_expedited_min_deposit }] |

  .app_state.evm.params.evm_denom = $denom |
  .app_state.evm.params.active_static_precompiles =
    (.app_state.evm.params.active_static_precompiles | map(select(. != $vesting))) |

  # The example chain disables the base fee and leaves the floor at zero, so
  # nothing at the consensus layer stops zero-price EVM transactions. Node-local
  # minimum-gas-prices is not consensus-enforced and cannot substitute for this.
  .app_state.feemarket.params.no_base_fee = false |
  .app_state.feemarket.params.base_fee = $base_fee |
  .app_state.feemarket.params.min_gas_price = $min_gas_price |

  # x/vm derives the EVM decimals from the metadata unit whose denom equals
  # `display`, so this block is what makes the chain 18-decimal.
  .app_state.bank.denom_metadata = [{
    description: "The native token for the Nura network.",
    denom_units: [
      { denom: $denom, exponent: 0, aliases: [] },
      { denom: $display, exponent: 18, aliases: [] }
    ],
    base: $denom,
    display: $display,
    name: "Nura",
    symbol: $symbol,
    uri: "",
    uri_hash: ""
  }] |

  # The example genesis registers a wrapped-token pair for the "aatom" test
  # denom, which would leave the real native token with no ERC-20 form.
  .app_state.erc20.token_pairs = [{
    erc20_address: $werc20,
    denom: $denom,
    enabled: true,
    contract_owner: "OWNER_MODULE"
  }] |
  .app_state.erc20.native_precompiles = [$werc20] |
  .app_state.erc20.dynamic_precompiles = [] |
  .app_state.erc20.allowances = [] |

  # CometBFT encodes 64-bit integers as JSON strings. -1 means unlimited, which
  # lets one transaction consume a whole block.
  .consensus.params.block.max_gas = $block_max_gas
' "$GENESIS" > "$TMP"
mv "$TMP" "$GENESIS"

if [[ -n "$GENESIS_TIME" ]]; then
	jq --arg genesis_time "$GENESIS_TIME" '.genesis_time = $genesis_time' "$GENESIS" > "$TMP"
	mv "$TMP" "$GENESIS"
fi

chown "$NODE_USER:$NODE_USER" "$GENESIS" 2>/dev/null || true

IFS=',' read -r -a addresses <<< "$VALIDATOR_ADDRESSES"
for address in "${addresses[@]}"; do
	address="${address//[[:space:]]/}"
	[[ -n "$address" ]] || continue
	nura::run_as evmd genesis add-genesis-account "$address" \
		"${GENESIS_BALANCE_BASE}${DENOM}" --home "$GENESIS_HOME"
done

nura::run_as evmd genesis validate-genesis --home "$GENESIS_HOME"

# 03_create_gentx.sh signs against NODE_HOME's genesis, so the coordinator's own
# node gets the prepared file immediately. Without this the gentx would be
# signed against the stock `evmd init` genesis still sitting there.
if [[ -n "${NODE_HOME:-}" && -d "$NODE_HOME/config" ]]; then
	nura::install_genesis "$GENESIS" "$NODE_HOME/config/genesis.json"
fi

echo
echo "Prepared shared genesis at $GENESIS"
echo "  denom              ${DENOM} (display ${DISPLAY_DENOM}, 18 decimals)"
echo "  min gas price      ${MIN_GAS_PRICE_WEI}${DENOM} per gas (consensus-enforced)"
echo "  block max gas      ${BLOCK_MAX_GAS}"
echo "  blocks per year    ${BLOCKS_PER_YEAR} (at ${SECONDS_PER_BLOCK}s per block)"
echo "  wrapped native     ${WRAPPED_NATIVE_ADDRESS}"
echo "  gov min deposit    ${GOV_MIN_DEPOSIT} ${DISPLAY_DENOM}"
