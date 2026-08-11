#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
nura::load_env "$SCRIPT_DIR"

: "${SSH_PORT:=22}"

nura::require_root
nura::require_cmd ufw
nura::validate_uint "$SSH_PORT" "SSH_PORT"

# Resetting discards every existing ufw rule on the host, which is the right
# thing on a fresh VPS and the wrong thing anywhere else.
if ufw status 2>/dev/null | grep -q "^Status: active" && [[ "${1:-}" != "--force" ]]; then
	nura::die "ufw is already active and this script resets all rules. Re-run with --force to replace them."
fi

# 05_configure_node.sh binds CometBFT RPC, the REST API, gRPC and JSON-RPC to
# loopback, so this only has to expose P2P. Both layers matter: a future config
# edit that rebinds a service to 0.0.0.0 should still hit a closed port.
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT/tcp" comment 'ssh'
ufw allow 26656/tcp comment 'cometbft p2p'
ufw --force enable
ufw status verbose

cat <<'EOF'

Only P2P (26656) and SSH are reachable from the internet.

Deliberately NOT exposed:
  26657  CometBFT RPC   - unauthenticated; can be used to query and broadcast
  1317   REST API       - unauthenticated
  9090   gRPC           - unauthenticated
  8545   EVM JSON-RPC   - unauthenticated
  8546   EVM WebSocket  - unauthenticated
  26660  Prometheus     - leaks validator identity and peer topology

To serve public RPC, do it from a separate non-validator node behind an
authenticated TLS reverse proxy. Never expose a validator's RPC directly.
EOF
