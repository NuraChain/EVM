#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
nura::load_env "$SCRIPT_DIR"

cd "$ROOT_DIR"

if [[ "$(uname -s)" != "Linux" ]]; then
	nura::die "this script must run on the Linux VPS, not on Windows or macOS."
fi

# sudo resets PATH to secure_path, which excludes the conventional Go install
# location, so `sudo ./00_build.sh` would not find a toolchain that works fine
# in an interactive shell.
for go_bin in /usr/local/go/bin "${HOME}/go/bin"; do
	if [[ -x "$go_bin/go" && ":$PATH:" != *":$go_bin:"* ]]; then
		PATH="$PATH:$go_bin"
	fi
done
export PATH

nura::require_cmd go make gcc

# The build links go-ethereum's C secp256k1. Without CGO the compile fails on
# undefined secp256k1.RecoverPubkey.
[[ "$(go env CGO_ENABLED)" == "1" ]] || nura::die "CGO_ENABLED is $(go env CGO_ENABLED), must be 1."

echo "Building on $(go env GOOS)/$(go env GOARCH) with $(go version)"
make build

nura::require_root
install -m 0755 build/evmd /usr/local/bin/evmd

# Unprivileged service account. The node never needs a login shell or a home
# directory of its own beyond NODE_HOME.
if ! id -u "$NODE_USER" >/dev/null 2>&1; then
	useradd --system --shell /usr/sbin/nologin --no-create-home "$NODE_USER"
	echo "Created service user '$NODE_USER'"
fi

evmd version
echo
echo "Installed /usr/local/bin/evmd, service user '$NODE_USER' ready."
