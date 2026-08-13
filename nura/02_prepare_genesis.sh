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
: "${TOTAL_SUPPLY:=1000000000}"
: "${GENESIS_BALANCE:=1000000}"
: "${GENESIS_ALLOCATIONS:=}"
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
nura::validate_token_amount "$TOTAL_SUPPLY" "TOTAL_SUPPLY"
nura::validate_token_amount "$GENESIS_BALANCE" "GENESIS_BALANCE"
nura::validate_hex_address "$WRAPPED_NATIVE_ADDRESS" "WRAPPED_NATIVE_ADDRESS"

# cosmos/evm's example genesis ships a token pair for the WEVMOS test contract.
# Reusing that address would leave a dead pair pointing at the wrong denom.
if [[ "${WRAPPED_NATIVE_ADDRESS,,}" == "0xd4949664cd82660aae99bedc034a0dea8a0bd517" ]]; then
	nura::die "WRAPPED_NATIVE_ADDRESS is cosmos/evm's example WEVMOS address. Choose your own."
fi

# The chain mints nothing after launch, so genesis is the only place the supply
# is ever decided. The whole allocation table is therefore built and reconciled
# against TOTAL_SUPPLY before any file is written: a table that does not add up
# must fail here, not become a permanent supply nobody can correct.
ALLOC_ADDRESSES=()
ALLOC_AMOUNTS=()
ALLOC_LABELS=()
ALLOCATED_TOTAL=0

nura::allocate() {
	local address="$1" amount="$2" label="$3" existing

	nura::validate_account_address "$address" "$label"
	nura::validate_token_amount "$amount" "$label amount"
	[[ "$amount" != "0" ]] || nura::die "$label allocates 0 tokens to $address. Remove the entry instead."

	# add-genesis-account fails on a repeated address anyway, but only after the
	# earlier accounts are already in the file, leaving a half-funded genesis.
	for existing in ${ALLOC_ADDRESSES[@]+"${ALLOC_ADDRESSES[@]}"}; do
		[[ "$existing" != "$address" ]] || nura::die "$address is allocated more than once."
	done

	ALLOC_ADDRESSES+=("$address")
	ALLOC_AMOUNTS+=("$amount")
	ALLOC_LABELS+=("$label")
	ALLOCATED_TOTAL=$(( ALLOCATED_TOTAL + amount ))
}

IFS=',' read -r -a validator_addresses <<< "$VALIDATOR_ADDRESSES"
for entry in ${validator_addresses[@]+"${validator_addresses[@]}"}; do
	entry="${entry//[[:space:]]/}"
	[[ -n "$entry" ]] || continue
	nura::allocate "$entry" "$GENESIS_BALANCE" "validator"
done
[[ "${#ALLOC_ADDRESSES[@]}" -gt 0 ]] || nura::die "VALIDATOR_ADDRESSES contains no addresses."

IFS=',' read -r -a genesis_allocations <<< "$GENESIS_ALLOCATIONS"
for entry in ${genesis_allocations[@]+"${genesis_allocations[@]}"}; do
	entry="${entry//[[:space:]]/}"
	[[ -n "$entry" ]] || continue
	# Bech32 addresses cannot contain ':', so it is unambiguous as a separator.
	[[ "$entry" == *:* ]] || nura::die "GENESIS_ALLOCATIONS entry '$entry' is not address:amount."
	nura::allocate "${entry%%:*}" "${entry##*:}" "allocation"
done

if [[ "$ALLOCATED_TOTAL" -ne "$TOTAL_SUPPLY" ]]; then
	nura::die "allocations total ${ALLOCATED_TOTAL} ${DISPLAY_DENOM} but TOTAL_SUPPLY is ${TOTAL_SUPPLY}.
${#ALLOC_ADDRESSES[@]} account(s): ${#validator_addresses[@]} validator(s) at ${GENESIS_BALANCE} each, plus GENESIS_ALLOCATIONS.
Nothing is minted after genesis, so the two must match exactly. Adjust
GENESIS_ALLOCATIONS, GENESIS_BALANCE, or TOTAL_SUPPLY until they do."
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
MAX_SUPPLY_BASE="$(nura::to_base_units "$TOTAL_SUPPLY" TOTAL_SUPPLY)"
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
	--arg max_supply "$MAX_SUPPLY_BASE" \
	--arg werc20 "$WRAPPED_NATIVE_ADDRESS" \
	--arg vesting "$VESTING_PRECOMPILE" '
  .app_state.staking.params.bond_denom = $denom |
  .app_state.mint.params.mint_denom = $denom |
  .app_state.mint.params.blocks_per_year = $blocks_per_year |

  # Fixed supply: x/mint must never create a token. Clamping both bounds to zero
  # pins NextInflationRate at zero whatever the bonded ratio does, and a zero
  # block provision is dropped by sdk.NewCoins, so BeginBlocker mints nothing.
  # goal_bonded stays non-zero because the params validator rejects zero; it is
  # inert once the bounds are zero.
  .app_state.mint.minter.inflation = "0.000000000000000000" |
  .app_state.mint.minter.annual_provisions = "0.000000000000000000" |
  .app_state.mint.params.inflation_rate_change = "0.000000000000000000" |
  .app_state.mint.params.inflation_max = "0.000000000000000000" |
  .app_state.mint.params.inflation_min = "0.000000000000000000" |

  # Second, independent guard. The SDK default of "0" means unlimited; a real
  # cap makes DefaultMintFn refuse to push the supply past it even if the
  # inflation params are ever changed.
  .app_state.mint.params.max_supply = $max_supply |

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

for index in "${!ALLOC_ADDRESSES[@]}"; do
	amount_base="$(nura::to_base_units "${ALLOC_AMOUNTS[$index]}" "${ALLOC_LABELS[$index]} amount")"
	nura::run_as evmd genesis add-genesis-account "${ALLOC_ADDRESSES[$index]}" \
		"${amount_base}${DENOM}" --home "$GENESIS_HOME"
done

nura::run_as evmd genesis validate-genesis --home "$GENESIS_HOME"

# add-genesis-account writes bank.supply as it funds each account, so this reads
# back what the chain will actually start with rather than what was intended.
GENESIS_SUPPLY="$(jq -r --arg denom "$DENOM" \
	'[.app_state.bank.supply[] | select(.denom == $denom) | .amount][0] // "0"' "$GENESIS")"
[[ "$GENESIS_SUPPLY" == "$MAX_SUPPLY_BASE" ]] ||
	nura::die "genesis supply is ${GENESIS_SUPPLY}${DENOM}, expected ${MAX_SUPPLY_BASE}${DENOM}."

# 03_create_gentx.sh signs against NODE_HOME's genesis, so the coordinator's own
# node gets the prepared file immediately. Without this the gentx would be
# signed against the stock `evmd init` genesis still sitting there.
if [[ -n "${NODE_HOME:-}" && -d "$NODE_HOME/config" ]]; then
	nura::install_genesis "$GENESIS" "$NODE_HOME/config/genesis.json"
fi

echo
echo "Prepared shared genesis at $GENESIS"
echo "  denom              ${DENOM} (display ${DISPLAY_DENOM}, 18 decimals)"
echo "  total supply       ${TOTAL_SUPPLY} ${DISPLAY_DENOM}, fixed (0% inflation, max_supply enforced)"
echo "  accounts           ${#ALLOC_ADDRESSES[@]}"
for index in "${!ALLOC_ADDRESSES[@]}"; do
	printf '    %-10s %s  %s %s\n' "${ALLOC_LABELS[$index]}" "${ALLOC_ADDRESSES[$index]}" \
		"${ALLOC_AMOUNTS[$index]}" "$DISPLAY_DENOM"
done
echo "  min gas price      ${MIN_GAS_PRICE_WEI}${DENOM} per gas (consensus-enforced)"
echo "  block max gas      ${BLOCK_MAX_GAS}"
echo "  blocks per year    ${BLOCKS_PER_YEAR} (at ${SECONDS_PER_BLOCK}s per block)"
echo "  wrapped native     ${WRAPPED_NATIVE_ADDRESS}"
echo "  gov min deposit    ${GOV_MIN_DEPOSIT} ${DISPLAY_DENOM}"
echo
echo "Validators earn transaction fees only. Nothing is minted after genesis."
