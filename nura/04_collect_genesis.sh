#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
nura::load_env "$SCRIPT_DIR"

: "${GENESIS_HOME:?Set GENESIS_HOME}"
: "${GENTX_FILES:?Set GENTX_FILES as comma-separated paths}"

nura::require_cmd evmd

GENESIS="$GENESIS_HOME/config/genesis.json"
[[ -f "$GENESIS" ]] || nura::die "missing $GENESIS. Run 02_prepare_genesis.sh first."

mkdir -p "$GENESIS_HOME/config/gentx"
IFS=',' read -r -a files <<< "$GENTX_FILES"
for file in "${files[@]}"; do
	file="${file//[[:space:]]/}"
	[[ -f "$file" ]] || nura::die "gentx not found: $file"
	cp "$file" "$GENESIS_HOME/config/gentx/"
done

chown -R "$NODE_USER:$NODE_USER" "$GENESIS_HOME/config/gentx" 2>/dev/null || true

nura::run_as evmd genesis collect-gentxs --home "$GENESIS_HOME"
nura::run_as evmd genesis validate-genesis --home "$GENESIS_HOME"

CHECKSUM="$(nura::sha256 "$GENESIS")"

cat <<EOF

Final genesis: $GENESIS
SHA256:        $CHECKSUM

Distribute this checksum to every validator alongside the genesis file. Each
validator must set GENESIS_SHA256 in their nura.env so 05_configure_node.sh can
prove they hold a byte-identical genesis before the chain starts. A validator
running even a slightly different genesis will fail to reach consensus.
EOF
