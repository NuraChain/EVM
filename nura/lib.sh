#!/usr/bin/env bash
# Shared helpers for the Nura bootstrap scripts. This file is sourced, not executed.

nura::die() {
	echo "error: $*" >&2
	exit 1
}

nura::load_env() {
	local script_dir env_file
	script_dir="$1"
	env_file="${NURA_ENV_FILE:-$script_dir/nura.env}"
	[[ -f "$env_file" ]] || nura::die "missing $env_file. Copy nura.env.example to nura.env and edit it."
	# shellcheck disable=SC1090
	source "$env_file"

	: "${CHAIN_ID:?Set CHAIN_ID}"
	: "${DENOM:=anura}"
	: "${DISPLAY_DENOM:=nura}"
	: "${NODE_USER:=evmd}"
	: "${KEYRING_BACKEND:=file}"
	: "${MIN_GAS_PRICE_WEI:=1000000000}"

	[[ "$KEYRING_BACKEND" != "test" ]] || nura::die "KEYRING_BACKEND=test is not allowed on a production host."

	nura::validate_denom "$DENOM" "DENOM"
	nura::validate_denom "$DISPLAY_DENOM" "DISPLAY_DENOM"
	nura::validate_uint "$MIN_GAS_PRICE_WEI" "MIN_GAS_PRICE_WEI"

	# The node-local minimum-gas-prices is derived from the same value that the
	# consensus-enforced feemarket floor uses, so the two can never drift apart.
	MIN_GAS_PRICES="${MIN_GAS_PRICE_WEI}${DENOM}"
	export MIN_GAS_PRICES
}

nura::require_cmd() {
	local command_name
	for command_name in "$@"; do
		command -v "$command_name" >/dev/null 2>&1 || nura::die "missing required command: $command_name"
	done
}

nura::validate_denom() {
	[[ "$1" =~ ^[a-zA-Z][a-zA-Z0-9/:._-]{2,127}$ ]] || nura::die "$2='$1' is not a valid Cosmos denom."
}

nura::validate_uint() {
	[[ "$1" =~ ^[0-9]+$ ]] || nura::die "$2='$1' must be a non-negative integer."
}

nura::validate_hex_address() {
	[[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]] || nura::die "$2='$1' is not a 20-byte hex address."
}

# Converts a whole-token amount to base units. Done by string append because
# 18-decimal amounts overflow bash's 64-bit integers.
nura::to_base_units() {
	nura::validate_uint "$1" "$2"
	echo "${1}000000000000000000"
}

# Renders a base-unit integer as a cosmossdk.io/math.LegacyDec JSON string.
nura::to_legacy_dec() {
	nura::validate_uint "$1" "$2"
	echo "${1}.000000000000000000"
}

# Runs a command as NODE_USER. Runs directly when already that user, so the
# scripts work both under sudo and as the service account itself.
nura::run_as() {
	if [[ "$(id -un)" == "$NODE_USER" ]]; then
		"$@"
	else
		nura::require_cmd sudo
		sudo -u "$NODE_USER" -- "$@"
	fi
}

nura::require_root() {
	[[ "$(id -u)" -eq 0 ]] || nura::die "this script must run as root (use sudo)."
}

nura::sha256() {
	nura::require_cmd sha256sum
	sha256sum "$1" | cut -d' ' -f1
}
