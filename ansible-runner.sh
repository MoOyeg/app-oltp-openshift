#!/usr/bin/env bash
#
# ansible-runner.sh - containerized entrypoint (regional-dr-example style).
#
# Builds a small Podman image containing ansible-core + kubernetes.core +
# the OpenShift `oc` client, then runs the requested playbook inside it with
# the repo and KUBECONFIG mounted in. No local ansible install required.
#
# Usage:
#   ./ansible-runner.sh deploy                 # full stack
#   ./ansible-runner.sh destroy                # tear everything down
#   ./ansible-runner.sh validate               # post-deploy checks
#   ./ansible-runner.sh deploy --tags tempo    # run a subset
#   ./ansible-runner.sh deploy -e otel_environment_name=staging
#
# Environment:
#   KUBECONFIG   path to a kubeconfig with cluster-admin (default: ~/.kube/config)
#   IMAGE_NAME   override built image name (default: app-oltp-runner:latest)
#   CONTAINER_ENGINE  podman (default) or docker
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="${CONTAINER_ENGINE:-podman}"
IMAGE_NAME="${IMAGE_NAME:-app-oltp-runner:latest}"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

ACTION="${1:-deploy}"
shift || true

case "$ACTION" in
  deploy)   PLAYBOOK="deploy.yml" ;;
  destroy)  PLAYBOOK="destroy.yml" ;;
  validate) PLAYBOOK="validate.yml" ;;
  site)     PLAYBOOK="site.yml" ;;
  *)        PLAYBOOK="$ACTION" ;;   # allow an explicit playbook name
esac

if [[ ! -f "$KUBECONFIG" ]]; then
  echo "ERROR: KUBECONFIG not found at '$KUBECONFIG'." >&2
  echo "       Point KUBECONFIG at a cluster-admin kubeconfig and retry." >&2
  exit 1
fi

echo ">> Building runner image ($IMAGE_NAME) with $ENGINE ..."
"$ENGINE" build -t "$IMAGE_NAME" -f "$REPO_DIR/Containerfile" "$REPO_DIR"

echo ">> Running $PLAYBOOK $* ..."
# Optional Datadog fan-out: if DATADOG_API_KEY is in the host env, plumb it
# through as an extra-var so the datadog role can create the Secret. Never
# echo the key. The user can also pass `-e datadog_api_key=...` explicitly.
DD_EXTRA=()
if [[ -n "${DATADOG_API_KEY:-}" ]]; then
  DD_EXTRA+=(-e "datadog_enabled=true" -e "datadog_api_key=${DATADOG_API_KEY}")
fi

exec "$ENGINE" run --rm -it \
  --userns=keep-id \
  -v "$REPO_DIR":/work:Z \
  -v "$KUBECONFIG":/work/.kubeconfig:ro,Z \
  -e KUBECONFIG=/work/.kubeconfig \
  -e ANSIBLE_CONFIG=/work/ansible.cfg \
  -w /work \
  "$IMAGE_NAME" \
  ansible-playbook -i inventory/hosts "$PLAYBOOK" "${DD_EXTRA[@]}" "$@"
