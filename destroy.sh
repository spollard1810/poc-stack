#!/usr/bin/env bash
# Wipe the whole PoC stack from the cluster. ALL DATA IS DELETED (NetBox, AWX,
# Gitea repos, databases). The k3s cluster itself is left alone.
#   ./destroy.sh          keep .secrets.env (a later ./bootstrap.sh reuses it)
#   ./destroy.sh --purge  also delete .secrets.env and .generated/
set -euo pipefail
cd "$(dirname "$0")"
source lib/common.sh
load_config

read -r -p "This deletes NetBox, AWX, Gitea, Argo CD and all their data. Type 'yes': " a
[[ $a == yes ]] || { echo "aborted"; exit 1; }

log "Stopping Argo CD (otherwise it recreates what we delete)"
kubectl -n argocd scale deploy,statefulset --all --replicas=0 >/dev/null 2>&1 || true
kubectl -n argocd delete applications.argoproj.io --all --wait=false >/dev/null 2>&1 || true
kubectl -n argocd get applications.argoproj.io -o name 2>/dev/null \
  | xargs -r -I{} kubectl -n argocd patch {} --type merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true

log "Removing AWX (lets the operator clean up)"
kubectl -n awx delete awx --all --wait=true --timeout=300s >/dev/null 2>&1 || true

log "Removing External Secrets objects (while their operator still runs)"
kubectl delete externalsecrets.external-secrets.io -A --all --timeout=120s >/dev/null 2>&1 || true
# If the operator is already gone, nothing removes their cleanup finalizer - drop it
kubectl get externalsecrets.external-secrets.io -A -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' 2>/dev/null \
  | while read -r ns name; do
      kubectl -n "$ns" patch externalsecrets.external-secrets.io "$name" --type merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
    done || true   # no External Secrets installed (e.g. an older stack): nothing to do
# Its admission webhooks would block deleting the other namespaces once it is gone
kubectl get validatingwebhookconfiguration,mutatingwebhookconfiguration -o name 2>/dev/null \
  | grep -E 'externalsecret|secretstore|external-secrets' | xargs -r kubectl delete >/dev/null 2>&1 || true

log "Deleting namespaces and their volumes"
for ns in poc-config awx netbox data external-secrets secret-store gitea argocd; do
  kubectl delete namespace "$ns" --ignore-not-found --wait=false >/dev/null
done
kubectl delete clustersecretstore poc-store --ignore-not-found >/dev/null 2>&1 || true
for ns in poc-config awx netbox data external-secrets secret-store gitea argocd; do
  kubectl wait --for=delete "namespace/$ns" --timeout=600s >/dev/null 2>&1 || true
done
left=$(kubectl get ns --no-headers 2>/dev/null \
  | awk '$1 ~ /^(poc-config|awx|netbox|data|external-secrets|secret-store|gitea|argocd)$/ {print $1}' | tr '\n' ' ')
if [[ -n $left ]]; then
  for ns in $left; do
    err "namespace $ns is still there: $(kubectl get ns "$ns" -o jsonpath='{.status.phase}: {.status.conditions[?(@.status=="True")].message}' 2>/dev/null)"
  done
  die "not everything was deleted - re-run ./destroy.sh, and if it stays stuck, send the lines above"
fi
ok "namespaces and their volumes deleted"

log "Removing cluster-wide leftovers (CRDs, cluster roles)"
kubectl get crd -o name | grep -E 'argoproj.io|external-secrets.io|generators.external-secrets.io|awx.ansible.com' \
  | xargs -r kubectl delete --wait=false >/dev/null 2>&1 || true
kubectl get clusterrole,clusterrolebinding -o name | grep -E 'argocd|external-secrets|awx-operator|store-reader' \
  | xargs -r kubectl delete >/dev/null 2>&1 || true

if [[ ${1:-} == --purge ]]; then
  rm -rf "$SECRETS_FILE" "$GEN_DIR"
  ok "purged .secrets.env and .generated/"
fi
ok "done - the cluster is empty of the PoC stack"
