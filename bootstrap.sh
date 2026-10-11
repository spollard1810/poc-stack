#!/usr/bin/env bash
# =============================================================================
#  PoC stack bootstrap: shared Postgres + Valkey, Gitea, NetBox, AWX (+ workers)
#  on a single-node k3s. Idempotent - safe to re-run at any time.
#
#  Usage: ./bootstrap.sh [all|preflight|data|apps|seed|status|info]
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
source lib/common.sh
source seed/seed.sh

SUDO=""; [[ $EUID -ne 0 ]] && SUDO="sudo"

# -----------------------------------------------------------------------------
port_in_use_by_other() {  # <port> -> true if a Service outside this stack already owns the NodePort
  kubectl get svc -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.spec.ports[*].nodePort}{"
"}{end}' 2>/dev/null     | awk -v p="$1" '$1 !~ /^(netbox|awx|gitea)$/ { for (i = 2; i <= NF; i++) if ($i == p) found = 1 } END { exit !found }'
}

preflight() {
  log "Preflight"
  local need=() c
  for c in curl jq git envsubst; do command -v "$c" >/dev/null || need+=("$c"); done
  if (( ${#need[@]} )); then
    log "Installing missing packages: ${need[*]}"
    need=("${need[@]/envsubst/gettext-base}")
    $SUDO apt-get update -qq && $SUDO apt-get install -y -qq "${need[@]}"
  fi

  if ! command -v helm >/dev/null; then
    log "Installing helm ${HELM_VERSION}"
    local arch tmp; arch=$(dpkg --print-architecture); tmp=$(mktemp -d)
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${arch}.tar.gz" | tar xz -C "$tmp"
    $SUDO install -m 0755 "$tmp/linux-${arch}/helm" /usr/local/bin/helm
    rm -rf "$tmp"
  fi

  kubectl get nodes >/dev/null 2>&1 || die "Cannot reach the cluster. Run with sudo, or:
    mkdir -p ~/.kube && sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config && sudo chown \$USER ~/.kube/config"
  kubectl get storageclass "$STORAGE_CLASS" >/dev/null 2>&1 || die "StorageClass '$STORAGE_CLASS' not found"

  local p
  for p in "$NETBOX_PORT" "$AWX_PORT" "$GITEA_PORT" "$GITEA_SSH_PORT"; do
    (( p >= 30000 && p <= 32767 )) || die "Port $p is outside the NodePort range 30000-32767 (see config.env)"
    if port_in_use_by_other "$p"; then die "NodePort $p is already used by another service (see config.env)"; fi
  done

  local cpus mem
  cpus=$(nproc); mem=$(awk '/MemTotal/ {print int($2/1024/1024)}' /proc/meminfo)
  (( cpus >= 4 && mem >= 15 )) || warn "Only ${cpus} vCPU / ${mem} GB RAM - 8 vCPU / 16+ GB recommended"
  ok "tools, cluster and storage OK (apps will be on ${NODE_IP})"
}

# -----------------------------------------------------------------------------
deploy_data() {
  log "Shared services: PostgreSQL + Valkey"
  kubectl apply -f manifests/namespaces.yaml >/dev/null
  kube_secret data postgres-superuser password="$PG_SUPERUSER_PASSWORD"
  kube_secret data valkey password="$VALKEY_PASSWORD"
  apply_tpl manifests/data/postgres.yaml >/dev/null
  apply_tpl manifests/data/valkey.yaml >/dev/null
  wait_rollout data statefulset/postgres
  wait_rollout data statefulset/valkey

  local app pw_var
  for app in netbox awx gitea; do
    pw_var="${app^^}_DB_PASSWORD"
    kubectl -n data exec -i postgres-0 -- psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<SQL
SELECT 'CREATE ROLE ${app} LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${app}')\gexec
ALTER ROLE ${app} WITH LOGIN PASSWORD '${!pw_var}';
SELECT 'CREATE DATABASE ${app} OWNER ${app}' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${app}')\gexec
SQL
  done
  ok "postgres databases: netbox, awx, gitea"
}

# -----------------------------------------------------------------------------
deploy_awx() {
  log "AWX operator ${AWX_OPERATOR_VERSION} + AWX instance"
  mkdir -p "$GEN_DIR/awx-operator"
  render manifests/awx/operator/kustomization.yaml >"$GEN_DIR/awx-operator/kustomization.yaml"
  kubectl apply -k "$GEN_DIR/awx-operator" >/dev/null
  kubectl wait --for=condition=established crd/awxs.awx.ansible.com --timeout=180s >/dev/null
  wait_rollout awx deployment/awx-operator-controller-manager

  kube_secret awx awx-admin-password password="$POC_ADMIN_PASSWORD"
  kube_secret awx awx-secret-key secret_key="$AWX_SECRET_KEY"
  kube_secret awx awx-postgres-configuration \
    host="$PG_HOST" port=5432 database=awx username=awx password="$AWX_DB_PASSWORD" \
    sslmode=prefer type=unmanaged
  apply_tpl manifests/awx/awx.yaml >/dev/null
  ok "AWX custom resource applied (the operator now builds it in the background)"
}

wait_awx() {
  log "Waiting for AWX deployments (first install runs DB migrations, ~5-10 min)"
  local t=0
  until kubectl -n awx get deploy awx-web awx-task >/dev/null 2>&1; do
    (( t >= 900 )) && die "AWX deployments never appeared - check: kubectl -n awx logs deploy/awx-operator-controller-manager -c awx-manager"
    sleep 10; t=$((t + 10))
  done
  wait_rollout awx deployment/awx-task 1200s
  wait_rollout awx deployment/awx-web 1200s
}

helm_app() {  # <release> <namespace> <chart> <repo> <version> <values-template>
  local rel=$1 ns=$2 chart=$3 repo=$4 ver=$5 tpl=$6
  local out="$GEN_DIR/$rel-values.yaml"
  mkdir -p "$GEN_DIR"; render "$tpl" >"$out"; chmod 600 "$out"
  log "Helm: $rel ($chart $ver)"
  helm upgrade --install "$rel" "$chart" --repo "$repo" --version "$ver" \
    -n "$ns" -f "$out" --wait --timeout 20m
}

deploy_apps() {
  deploy_awx   # start first; the operator works while the helm charts install
  helm_app gitea  gitea  gitea  https://dl.gitea.com/charts/                   "$GITEA_CHART_VERSION"  values/gitea.yaml
  helm_app netbox netbox netbox https://charts.netbox.oss.netboxlabs.com/      "$NETBOX_CHART_VERSION" values/netbox.yaml
  wait_awx
}

seed_all() {
  seed_gitea
  seed_netbox
  seed_awx
}

# -----------------------------------------------------------------------------
info() {
  local f="$GEN_DIR/ACCESS.txt"; mkdir -p "$GEN_DIR"
  cat >"$f" <<EOF
================================================================================
 PoC stack - access (node IP + port, no DNS)
================================================================================
 NetBox : ${NETBOX_URL}
 AWX    : ${AWX_URL}
 Gitea  : ${GITEA_URL}
          git clone ${GITEA_URL}/infra/playbooks.git
          ssh://git@${NODE_IP}:${GITEA_SSH_PORT}/infra/playbooks.git

 Login (all three) : ${POC_ADMIN_USER} / ${POC_ADMIN_PASSWORD}
 NetBox API token  : ${NETBOX_API_TOKEN:-<not provisioned yet - run ./bootstrap.sh seed>}

 Cluster-internal only (no external port)
   PostgreSQL : ${PG_HOST}:5432   (superuser: postgres / see .secrets.env)
   Valkey     : ${VALKEY_HOST}:6379 (password: see .secrets.env)
   Gitea      : ${GITEA_INTERNAL_URL}   (used by AWX)
   NetBox     : ${NETBOX_INTERNAL_URL}  (used by AWX)
   psql shell : kubectl -n data exec -it postgres-0 -- psql -U postgres
================================================================================
EOF
  chmod 600 "$f"; cat "$f"
}

status() {
  kubectl get pods -n data; echo
  kubectl get pods -n gitea; echo
  kubectl get pods -n netbox; echo
  kubectl get pods -n awx; echo
  kubectl get svc -n netbox netbox; kubectl get svc -n awx awx-service; kubectl get svc -n gitea gitea-http gitea-ssh
}

# -----------------------------------------------------------------------------
main() {
  local cmd=${1:-all}
  load_config
  ensure_secrets
  case $cmd in
    all)       preflight; deploy_data; deploy_apps; seed_all; info ;;
    preflight) preflight ;;
    data)      preflight; deploy_data ;;
    apps)      preflight; deploy_apps ;;
    seed)      seed_all; info ;;
    status)    status ;;
    info)      info ;;
    *) echo "usage: $0 [all|preflight|data|apps|seed|status|info]"; exit 1 ;;
  esac
}
main "$@"
