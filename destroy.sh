#!/usr/bin/env bash
# Tear down the PoC stack. ALL DATA (Postgres, Gitea repos, NetBox) IS DELETED.
#   ./destroy.sh          remove everything from the cluster, keep .secrets.env
#   ./destroy.sh --purge  also delete .secrets.env and .generated/
set -euo pipefail
cd "$(dirname "$0")"
source lib/common.sh
load_config

read -r -p "This deletes NetBox, AWX, Gitea, Postgres and Valkey INCLUDING DATA. Type 'yes': " a
[[ $a == yes ]] || { echo "aborted"; exit 1; }

log "Stopping Argo CD from managing the platform (otherwise it recreates what we delete)"
kubectl -n argocd delete applications.argoproj.io --all --ignore-not-found --wait=true --timeout=120s 2>/dev/null || true

log "Removing AWX"
kubectl -n awx delete awx awx --ignore-not-found --wait=true --timeout=300s || true
[[ -d $GEN_DIR/platform/awx-operator ]] && kubectl delete -k "$GEN_DIR/platform/awx-operator" --ignore-not-found || true

log "Removing helm releases"
helm uninstall netbox -n netbox 2>/dev/null || true   # only exists on installs from before GitOps
helm uninstall gitea -n gitea 2>/dev/null || true
helm uninstall argocd -n argocd 2>/dev/null || true
kubectl delete namespace argocd --ignore-not-found --wait=true || true

log "Deleting namespaces (and their volumes)"
kubectl delete -f manifests/namespaces.yaml --ignore-not-found --wait=true

if [[ ${1:-} == --purge ]]; then
  rm -rf "$SECRETS_FILE" "$GEN_DIR"
  ok "purged .secrets.env and .generated/"
fi
ok "done"
