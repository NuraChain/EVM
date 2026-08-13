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
	# Exported so nura::set_env_var can write derived values (the genesis
	# checksum) back into the same file the scripts read.
	NURA_ENV_FILE="$env_file"
	export NURA_ENV_FILE

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

# The bech32 data charset excludes 1, b, i, and o. A 20-byte account address is
# always 38 characters after the "nura1" separator. Catches the common mistake
# of pasting an 0x address, a validator operator address, or a key name where a
# genesis account address belongs.
nura::validate_account_address() {
	[[ "$1" =~ ^nura1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{38}$ ]] ||
		nura::die "$2='$1' is not a nura bech32 account address."
}

# Whole-token amounts are summed with bash arithmetic, which is 64-bit and wraps
# silently on overflow. Capping each amount at 15 digits keeps any realistic
# total far below that limit, so an allocation table can never wrap into a
# smaller number that happens to match TOTAL_SUPPLY.
nura::validate_token_amount() {
	nura::validate_uint "$1" "$2"
	[[ "${#1}" -le 15 ]] || nura::die "$2='$1' exceeds the 999999999999999 whole-token limit."
	# A leading zero is a typo, and it would also survive into the base-unit
	# string that the final supply is compared against byte for byte.
	[[ "$1" == "0" || "${1:0:1}" != "0" ]] || nura::die "$2='$1' has a leading zero."
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

# Every evmd invocation pre-instantiates the app to build its CLI, and that temp
# app is constructed with empty app options, so its upgrade keeper resolves the
# home directory to "" and calls mkdir("data") relative to the current working
# directory. Run evmd from a directory NODE_USER owns, otherwise even
# `evmd version` panics with `could not create directory "data"`.
nura::enter_workdir() {
	local dir="$1"
	[[ -d "$dir" ]] || nura::die "working directory $dir does not exist."
	cd "$dir" || nura::die "cannot enter $dir."
}

nura::require_root() {
	[[ "$(id -u)" -eq 0 ]] || nura::die "this script must run as root (use sudo)."
}

nura::sha256() {
	nura::require_cmd sha256sum
	sha256sum "$1" | cut -d' ' -f1
}

# Rewrites KEY="value" in nura.env, appending it when absent. Used so derived
# values the operator would otherwise transcribe by hand (the genesis checksum)
# land in the file the other scripts read. Writes through `cat` so the env
# file's existing ownership and 0600 permissions survive.
nura::set_env_var() {
	local key="$1" value="$2" tmp
	nura::require_cmd awk
	[[ -f "${NURA_ENV_FILE:-}" ]] || nura::die "NURA_ENV_FILE is not set; call nura::load_env first."
	tmp="$(mktemp)"
	awk -v key="$key" -v value="$value" '
		BEGIN { done = 0 }
		!done && $0 ~ "^[[:space:]]*" key "=" {
			printf "%s=\"%s\"\n", key, value
			done = 1
			next
		}
		{ print }
		END { if (!done) printf "%s=\"%s\"\n", key, value }
	' "$NURA_ENV_FILE" > "$tmp" || { rm -f "$tmp"; nura::die "failed to set $key in $NURA_ENV_FILE"; }
	cat "$tmp" > "$NURA_ENV_FILE"
	rm -f "$tmp"
	echo "Set $key in $NURA_ENV_FILE"
}

# Installs a genesis file into a node home. The copy is staged and renamed so a
# node can never read a half-written genesis, and ownership is set before the
# rename so the service account can always read the result.
nura::install_genesis() {
	local src="$1" dst="$2" dst_dir tmp
	[[ -f "$src" ]] || nura::die "genesis source not found: $src"
	dst_dir="$(dirname "$dst")"
	[[ -d "$dst_dir" ]] || nura::die "missing $dst_dir. Run 01_init_node.sh first."
	# Nothing to do when the coordinator's GENESIS_HOME is the node home itself.
	if [[ "$src" -ef "$dst" ]]; then
		return 0
	fi
	tmp="$dst.installing.$$"
	cp "$src" "$tmp"
	chown "$NODE_USER:$NODE_USER" "$tmp" 2>/dev/null || true
	chmod 0644 "$tmp"
	mv "$tmp" "$dst"
	echo "Installed genesis into $dst (sha256 $(nura::sha256 "$dst"))"
}

# Ensures NODE_HOME holds the genesis this validator should run, so no step of
# the workflow depends on the operator remembering to copy the file. A stale
# copy left in NODE_HOME is the cause of both the "not the coordinator's
# genesis" gentx failure and the post-collect checksum mismatch, so an
# authoritative source always overwrites what is already there.
nura::sync_genesis() {
	: "${NODE_HOME:?Set NODE_HOME}"
	local dst="$NODE_HOME/config/genesis.json"

	# The file the coordinator sent wins; GENESIS_HOME only exists on the
	# coordinator itself, where it is the file being published.
	if [[ -n "${GENESIS_SOURCE:-}" ]]; then
		nura::install_genesis "$GENESIS_SOURCE" "$dst"
	elif [[ -n "${GENESIS_HOME:-}" && -f "$GENESIS_HOME/config/genesis.json" ]]; then
		nura::install_genesis "$GENESIS_HOME/config/genesis.json" "$dst"
	elif [[ ! -f "$dst" ]]; then
		nura::die "missing $dst.
Set GENESIS_SOURCE in nura.env to the genesis file the coordinator sent you, or
run 02_prepare_genesis.sh if this host is the coordinator."
	fi
}
