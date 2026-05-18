#!/usr/bin/env bash
#
# setup.sh - one-time local bootstrap (regional-dr-example style).
#
# This stack runs entirely inside the runner container, so the only host
# prerequisites are podman (or docker) and a cluster-admin kubeconfig.
# This script just validates those and seeds the host_vars example file.
#
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENGINE="${CONTAINER_ENGINE:-podman}"
command -v "$ENGINE" >/dev/null 2>&1 || {
  echo "ERROR: '$ENGINE' not found. Install podman (or set CONTAINER_ENGINE=docker)." >&2
  exit 1
}

KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
if [[ ! -f "$KUBECONFIG" ]]; then
  echo "WARN: no kubeconfig at '$KUBECONFIG'. Export KUBECONFIG before deploying." >&2
fi

EX="$REPO_DIR/inventory/host_vars/cluster.yml.example"
DST="$REPO_DIR/inventory/host_vars/cluster.yml"
if [[ -f "$EX" && ! -f "$DST" ]]; then
  cp "$EX" "$DST"
  echo ">> Created inventory/host_vars/cluster.yml from example - edit overrides there."
fi

chmod +x "$REPO_DIR/ansible-runner.sh"
echo ">> Setup complete. Next: ./ansible-runner.sh deploy"
