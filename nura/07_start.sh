#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
nura::load_env "$SCRIPT_DIR"

: "${NODE_HOME:?Set NODE_HOME}"

nura::require_cmd systemctl

[[ -f /etc/systemd/system/evmd.service ]] || nura::die "evmd.service is not installed. Run 06_install_service.sh first."

# A node started before its genesis is verified and its peers configured will
# either stall or, worse, fork onto its own chain.
[[ -f "$NODE_HOME/config/genesis.json" ]] || nura::die "missing $NODE_HOME/config/genesis.json."

systemctl restart evmd.service
sleep 3
systemctl --no-pager status evmd.service || true

cat <<'EOF'

Follow the logs with:
  journalctl -u evmd -f

Check sync status with:
  evmd status | jq '.sync_info'
EOF
