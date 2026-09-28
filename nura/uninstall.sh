#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
nura::load_env "$SCRIPT_DIR"

: "${NODE_HOME:?Set NODE_HOME}"

nura::require_root
nura::require_cmd systemctl pgrep

UNIT="/etc/systemd/system/evmd.service"

# Nothing is deleted. NODE_HOME holds the consensus key and the keyring, and
# 01_init_node.sh reuses whatever it finds there, so the old chain has to be
# moved out of the way; a lost key cannot be recovered afterwards.
BACKUP="${NODE_HOME%/}.removed-$(date -u +%Y%m%dT%H%M%SZ)"

if [[ "${1:-}" != "--yes" ]]; then
	cat <<EOF
This stops and removes evmd.service and moves
  $NODE_HOME
to
  $BACKUP
so the next 01_init_node.sh starts a brand-new chain with new keys.
Back up the chain first if you may need it again. Re-run with --yes to proceed.
EOF
	exit 1
fi

if [[ -f "$UNIT" ]]; then
	systemctl disable --now evmd.service
	rm -f "$UNIT"
	systemctl daemon-reload
fi

# Moving the home out from under a node started by hand would corrupt its data.
if pgrep -x evmd >/dev/null; then
	nura::die "an evmd process is still running outside the service. Stop it first."
fi

if [[ -d "$NODE_HOME" ]]; then
	mv "$NODE_HOME" "$BACKUP"
	echo "Moved $NODE_HOME to $BACKUP"
fi

cat <<EOF

The previous chain is removed. The evmd binary and the $NODE_USER user are kept.
Refresh nura.env from nura.env.example, then run 01_init_node.sh.
Once the new chain is running, delete the old copy with:
  rm -rf $BACKUP
EOF
