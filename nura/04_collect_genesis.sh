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

# After the copy loop, so relative paths in GENTX_FILES still resolve.
nura::enter_workdir "$GENESIS_HOME"

nura::run_as evmd genesis collect-gentxs --home "$GENESIS_HOME"
nura::run_as evmd genesis validate-genesis --home "$GENESIS_HOME"

CHECKSUM="$(nura::sha256 "$GENESIS")"

# collect-gentxs rewrote the genesis, so the copy 02_prepare_genesis.sh put in
# NODE_HOME is now stale. Refreshing it here is what keeps 05_configure_node.sh
# from failing its checksum check on the coordinator's own node.
if [[ -n "${NODE_HOME:-}" && -d "$NODE_HOME/config" ]]; then
	nura::install_genesis "$GENESIS" "$NODE_HOME/config/genesis.json"
fi

nura::set_env_var GENESIS_SHA256 "$CHECKSUM"

cat <<EOF

Final genesis: $GENESIS
SHA256:        $CHECKSUM

GENESIS_SHA256 has been set in this host's nura.env. Distribute the checksum to
every other validator alongside the genesis file. Each of them must set
GENESIS_SHA256 and GENESIS_SOURCE in their own nura.env so 05_configure_node.sh
can prove they hold a byte-identical genesis before the chain starts. A
validator running even a slightly different genesis will fail to reach
consensus.
EOF
