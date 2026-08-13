#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
nura::load_env "$SCRIPT_DIR"

: "${NODE_HOME:?Set NODE_HOME}"
: "${PRUNING:=default}"

nura::require_root
nura::require_cmd systemctl

UNIT="/etc/systemd/system/evmd.service"

# The node reads minimum-gas-prices, pruning and the EVM chain ID from app.toml,
# which 05_configure_node.sh writes. Passing them again on the command line would
# create a second source of truth that silently overrides the file.
cat > "$UNIT" <<EOF
[Unit]
Description=Nura ($CHAIN_ID) validator node
After=network-online.target
Wants=network-online.target

[Service]
User=$NODE_USER
Group=$NODE_USER
# evmd builds a temp app whose upgrade keeper does mkdir("data") relative to the
# working directory. systemd defaults to /, which ProtectSystem=strict mounts
# read-only, so without this the node panics before it starts.
WorkingDirectory=$NODE_HOME
ExecStart=/usr/local/bin/evmd start --home $NODE_HOME --chain-id $CHAIN_ID --log_level info
Restart=on-failure
RestartSec=5
# The node keeps a file descriptor per peer, per RPC connection and per open
# LevelDB/PebbleDB table; the default of 1024 is exhausted quickly.
LimitNOFILE=65535
TimeoutStopSec=120
KillSignal=SIGTERM

# Hardening. The node only ever writes inside NODE_HOME.
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=false
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
ReadWritePaths=$NODE_HOME

[Install]
WantedBy=multi-user.target
EOF

chmod 0644 "$UNIT"
systemctl daemon-reload
systemctl enable evmd.service

echo "Installed $UNIT"
echo "Logs will go to the journal: journalctl -u evmd -f"
