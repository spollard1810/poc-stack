#!/usr/bin/env bash
# =============================================================================
#  PoC stack bootstrap (single-node k3s). Idempotent - safe to re-run.
#
#  Installs only Gitea + Argo CD, pushes the stack definitions (stack/) and the
#  playbooks (playbooks/) into Gitea, and hands over to Argo CD, which deploys
#  everything else - and from then on also manages Gitea and itself:
#    External Secrets, PostgreSQL, Valkey, NetBox, AWX (+ workers), and the
#    settings inside AWX / NetBox / Gitea (stack/config/settings.yml).
#
#  Usage: ./bootstrap.sh [all|setup|preflight|status|info|publish|recover]
#         ./bootstrap.sh secret <name> <value> [...]   e.g. secret device_ro_username netops
#  The first run asks for the node IP, admin account and logins (see lib/setup.sh).
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
source lib/common.sh
source lib/setup.sh

SUDO=""; [[ $EUID -ne 0 ]] && SUDO="sudo"

# ------------------------------------------------------------------ preflight -
port_in_use_by_other() {  # <port> -> true if a Service outside this stack owns the NodePort
  kubectl get svc -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.spec.ports[*].nodePort}{"\n"}{end}' 2>/dev/null \
    | awk -v p="$1" '$1 !~ /^(netbox|awx|gitea|argocd)$/ { for (i = 2; i <= NF; i++) if ($i == p) found = 1 } END { exit !found }'
}

# The cluster must use the pod / service ranges in config.env (set when k3s is
# installed; bootstrap can't change them).
check_networks() {
  local pod_cidr svc_ip dns_ip bad=0
  pod_cidr=$(kubectl get nodes -o jsonpath='{.items[0].spec.podCIDR}')
  svc_ip=$(kubectl -n default get svc kubernetes -o jsonpath='{.spec.clusterIP}')
  dns_ip=$(kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
  in_cidr "${pod_cidr%/*}" "$POD_CIDR" || { err "pods use ${pod_cidr}, config.env says POD_CIDR=${POD_CIDR}"; bad=1; }
  in_cidr "$svc_ip" "$SERVICE_CIDR"    || { err "services use ${svc_ip%.*}.x, config.env says SERVICE_CIDR=${SERVICE_CIDR}"; bad=1; }
  [[ -z $dns_ip || $dns_ip == "$CLUSTER_DNS" ]] || { err "cluster DNS is ${dns_ip}, config.env says CLUSTER_DNS=${CLUSTER_DNS}"; bad=1; }
  if in_cidr "$NODE_IP" "$POD_CIDR" || in_cidr "$NODE_IP" "$SERVICE_CIDR"; then
    err "the server's IP ${NODE_IP} is inside the pod or service range"; bad=1
  fi
  (( bad == 0 )) || die "k3s network settings don't match config.env - see README \"Cluster networks\""
  ok "networks: pods ${POD_CIDR}, services ${SERVICE_CIDR}, DNS ${CLUSTER_DNS}, server ${NODE_IP}"
}

# Before hand-over, bootstrap itself only creates gitea, argocd and secret-store;
# netbox / awx / data come from Argo CD later. If they exist while Argo CD's root
# app doesn't, they're from an earlier install that was never wiped - stop.
check_leftovers() {
  local old
  kubectl -n argocd get applications.argoproj.io stack >/dev/null 2>&1 && return 0
  old=$(kubectl get ns --no-headers 2>/dev/null | awk '$1 ~ /^(netbox|awx|data|poc-config|external-secrets)$/ {printf "%s ", $1}')
  [[ -z $old ]] && return 0
  die "found an earlier install that wasn't wiped (namespaces: ${old% }).
    Installing on top of it fails (e.g. Gitea finds old repositories). Wipe it first:
      sudo ./destroy.sh --purge
    or, if this server runs nothing else in k3s, reset k3s (README \"Cluster networks\")."
}

preflight() {
  log "Preflight"
  local need=() c
  for c in curl jq git envsubst htpasswd; do command -v "$c" >/dev/null || need+=("$c"); done
  if (( ${#need[@]} )); then
    need=("${need[@]/envsubst/gettext-base}"); need=("${need[@]/htpasswd/apache2-utils}")
    log "Installing missing packages: ${need[*]}"
    $SUDO apt-get update -qq && $SUDO apt-get install -y -qq "${need[@]}" >/dev/null
  fi
  if ! command -v helm >/dev/null; then
    log "Installing helm ${HELM_VERSION}"
    local arch tmp; arch=$(dpkg --print-architecture); tmp=$(mktemp -d)
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${arch}.tar.gz" | tar xz -C "$tmp"
    $SUDO install -m 0755 "$tmp/linux-${arch}/helm" /usr/local/bin/helm; rm -rf "$tmp"
  fi
  kubectl get nodes >/dev/null 2>&1 || die "Cannot reach the cluster. Run with sudo, or:
    mkdir -p ~/.kube && sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config && sudo chown \$USER ~/.kube/config"
  kubectl get storageclass "$STORAGE_CLASS" >/dev/null 2>&1 || die "StorageClass '$STORAGE_CLASS' not found"
  check_networks
  check_leftovers
  local p
  for p in "$NETBOX_PORT" "$AWX_PORT" "$GITEA_PORT" "$GITEA_SSH_PORT" "$ARGOCD_PORT" "$ARGOCD_HTTPS_PORT"; do
    (( p >= 30000 && p <= 32767 )) || die "Port $p is outside the NodePort range 30000-32767 (see config.env)"
    if port_in_use_by_other "$p"; then die "NodePort $p is already used by another service (see config.env)"; fi
  done
  local cpus mem
  cpus=$(nproc); mem=$(awk '/MemTotal/ {print int($2/1024/1024)}' /proc/meminfo)
  (( cpus >= 4 && mem >= 15 )) || warn "Only ${cpus} vCPU / ${mem} GB RAM - 8 vCPU / 16+ GB recommended"
  ok "tools, cluster and storage OK (apps will be on ${NODE_IP})"
}

# --------------------------------------------------------------- secret store -
# Argo CD's login is a bcrypt hash (recomputed only when the password changes)
argocd_hash() {
  local pw_sha
  pw_sha=$(printf '%s' "$POC_ADMIN_PASSWORD" | sha256sum | cut -c1-16)
  if [[ ${ARGOCD_ADMIN_PW_SHA:-} != "$pw_sha" || -z ${ARGOCD_ADMIN_HASH:-} ]]; then
    save_secret ARGOCD_ADMIN_HASH "$(htpasswd -nbBC 10 "" "$POC_ADMIN_PASSWORD" | tr -d ':\n' | sed 's/^\$2y/$2a/')"
    save_secret ARGOCD_ADMIN_PW_SHA "$pw_sha"
  fi
}

# Copy .secrets.env + the admin account into secret-store/poc-secrets (merge: keys
# the configure job added, like issued API tokens, are kept).
store_sync() {
  local json='{}' k
  for k in $(grep -oE '^[A-Z0-9_]+' "$SECRETS_FILE" | grep -vE '^(POC_ADMIN_PASSWORD|SETUP_DONE)$'); do
    json=$(jq -c --arg k "${k,,}" --arg v "$(printf '%s' "${!k}" | base64 -w0)" '. + {($k): $v}' <<<"$json")
  done
  json=$(jq -c --arg u "$(printf '%s' "$POC_ADMIN_USER" | base64 -w0)" --arg p "$(printf '%s' "$POC_ADMIN_PASSWORD" | base64 -w0)" \
              --arg e "$(printf '%s' "$POC_ADMIN_EMAIL" | base64 -w0)" '. + {admin_user: $u, admin_password: $p, admin_email: $e}' <<<"$json")
  kubectl create namespace secret-store --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  if kubectl -n secret-store get secret poc-secrets >/dev/null 2>&1; then
    kubectl -n secret-store patch secret poc-secrets --type merge -p "{\"data\": $json}" >/dev/null
  else
    jq -n --argjson d "$json" '{apiVersion:"v1", kind:"Secret", type:"Opaque",
      metadata:{name:"poc-secrets", namespace:"secret-store"}, data:$d}' | kubectl apply -f - >/dev/null
  fi
  ok "secret store secret-store/poc-secrets up to date"
}

# Secrets Gitea and Argo CD need before External Secrets runs (it takes them over)
foundation_secrets() {
  local ns
  for ns in gitea argocd; do kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; done
  kube_secret gitea gitea-admin username="$POC_ADMIN_USER" password="$POC_ADMIN_PASSWORD"
  if ! kubectl -n argocd get secret argocd-secret >/dev/null 2>&1; then
    kubectl -n argocd create secret generic argocd-secret \
      --from-literal=server.secretkey="$ARGOCD_SERVER_SECRETKEY" \
      --from-literal="accounts.${POC_ADMIN_USER}.password=${ARGOCD_ADMIN_HASH}" >/dev/null
    kubectl -n argocd label secret argocd-secret app.kubernetes.io/part-of=argocd app.kubernetes.io/name=argocd-secret >/dev/null
  fi
}

# ------------------------------------------------------ Gitea + Argo CD (seed) -
argo_owns() { kubectl -n argocd get applications.argoproj.io "$1" >/dev/null 2>&1; }

helm_seed() {  # <release> <ns> <chart> <repo> <version> <values in stack/>  [force]
  local rel=$1 ns=$2 chart=$3 repo=$4 ver=$5 vals=$6 force=${7:-}
  if argo_owns "$rel" && [[ $force != force ]]; then
    ok "$rel: managed by Argo CD (from infra/stack)"; return 0
  fi
  local out="$GEN_DIR/$rel-values.yaml"
  mkdir -p "$GEN_DIR"; render "stack/$vals" >"$out"
  log "Helm: $rel ($chart $ver)"
  helm upgrade --install "$rel" "$chart" --repo "$repo" --version "$ver" -n "$ns" -f "$out" --wait --timeout 15m >/dev/null
  ok "$rel installed"
}

seed_gitea_argocd() {
  helm_seed gitea gitea gitea https://dl.gitea.com/charts/ "$GITEA_CHART_VERSION" gitea/values.yaml "${1:-}"
  helm_seed argocd argocd argo-cd https://argoproj.github.io/argo-helm "$ARGOCD_CHART_VERSION" argocd/values.yaml "${1:-}"
}

# ------------------------------------------------- repos in Gitea + Argo access -
publish_repos() {
  log "Pushing stack/ and playbooks/ to Gitea"
  wait_http "$GITEA_URL" /api/healthz 900 || die "Gitea did not come up"
  API_AUTH=(-u "${POC_ADMIN_USER}:${POC_ADMIN_PASSWORD}")
  api "$GITEA_URL" GET /api/v1/orgs/infra >/dev/null 2>&1 || \
    api "$GITEA_URL" POST /api/v1/orgs '{"username":"infra","full_name":"Infrastructure","visibility":"private"}' >/dev/null
  local r
  for r in "stack|Stack definitions - Argo CD deploys the platform from this repo" "playbooks|Ansible playbooks run by AWX"; do
    api "$GITEA_URL" GET "/api/v1/repos/infra/${r%%|*}" >/dev/null 2>&1 || \
      api "$GITEA_URL" POST /api/v1/orgs/infra/repos "$(jq -nc --arg n "${r%%|*}" --arg d "${r#*|}" \
        '{name:$n, description:$d, private:true, default_branch:"main"}')" >/dev/null
  done

  # stack/ is rendered (node IP, ports, versions); playbooks/ is pushed as-is
  local out="$GEN_DIR/stack" f rel
  rm -rf "$out"; mkdir -p "$out"
  while IFS= read -r -d '' f; do
    rel=${f#stack/}; mkdir -p "$out/$(dirname "$rel")"; render "$f" >"$out/$rel"
  done < <(find stack -type f -print0)
  bash tools/sync-repo.sh "$out" infra/stack
  bash tools/sync-repo.sh playbooks infra/playbooks
}

# Argo CD reads infra/stack as a restricted, read-only Gitea user
argocd_repo_access() {
  API_AUTH=(-u "${POC_ADMIN_USER}:${POC_ADMIN_PASSWORD}")
  api "$GITEA_URL" GET /api/v1/users/argocd >/dev/null 2>&1 || \
    api "$GITEA_URL" POST /api/v1/admin/users "$(jq -nc --arg p "$GITEA_ARGOCD_PASSWORD" \
      '{username:"argocd", email:"argocd@poc.local", password:$p, must_change_password:false, restricted:true, full_name:"Argo CD (read-only)"}')" >/dev/null
  local team
  team=$(api "$GITEA_URL" GET "/api/v1/orgs/infra/teams/search?q=gitops-readers" | jq -r '.data[0].id // empty')
  [[ -n $team ]] || team=$(api "$GITEA_URL" POST /api/v1/orgs/infra/teams \
    '{"name":"gitops-readers","description":"Read-only: Argo CD","permission":"read","units":["repo.code"],"includes_all_repositories":false}' | jq -r .id)
  api "$GITEA_URL" PUT "/api/v1/teams/${team}/members/argocd" >/dev/null
  api "$GITEA_URL" PUT "/api/v1/teams/${team}/repos/infra/stack" >/dev/null
  if [[ -z ${GITEA_ARGOCD_TOKEN:-} ]] || [[ $(curl -s -o /dev/null -w '%{http_code}' \
       -H "Authorization: token ${GITEA_ARGOCD_TOKEN}" "$GITEA_URL/api/v1/repos/infra/stack") != 200 ]]; then
    curl -s -u "argocd:${GITEA_ARGOCD_PASSWORD}" -X DELETE "$GITEA_URL/api/v1/users/argocd/tokens/argocd-read" >/dev/null || true
    local tok
    tok=$(curl -sS -u "argocd:${GITEA_ARGOCD_PASSWORD}" -H 'Content-Type: application/json' \
      -d '{"name":"argocd-read","scopes":["read:repository"]}' "$GITEA_URL/api/v1/users/argocd/tokens" | jq -r '.sha1 // empty')
    [[ -n $tok ]] || die "gitea: could not create the argocd token"
    save_secret GITEA_ARGOCD_TOKEN "$tok"
  fi
  if ! kubectl -n argocd get secret repo-stack >/dev/null 2>&1; then
    kubectl -n argocd create secret generic repo-stack --from-literal=type=git --from-literal=url="$STACK_REPO_URL" \
      --from-literal=username=argocd --from-literal=password="$GITEA_ARGOCD_TOKEN" >/dev/null
    kubectl -n argocd label secret repo-stack argocd.argoproj.io/secret-type=repository >/dev/null
  fi
  ok "argo cd reads infra/stack as read-only Gitea user 'argocd'"
}

# ---------------------------------------------------------------- hand over --
hand_over() {
  kubectl apply -f "$GEN_DIR/stack/root.yaml" >/dev/null
  ok "root app 'stack' applied - Argo CD now deploys everything from infra/stack"
}

wait_stack() {
  log "Waiting for Argo CD to deploy the stack (first run ~20-25 min: AWX migrations + configure job)"
  local t=0 out bad cfg
  while :; do
    out=$(kubectl -n argocd get applications.argoproj.io \
      -o jsonpath='{range .items[*]}{.metadata.name}={.status.sync.status}/{.status.health.status} {end}' 2>/dev/null || true)
    bad=$(tr ' ' '\n' <<<"$out" | grep -v '=Synced/Healthy$' | grep -c . || true)
    cfg=$(kubectl -n argocd get applications.argoproj.io config -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)
    if [[ $(wc -w <<<"$out") -ge 11 && $bad == 0 && $cfg == Succeeded ]]; then ok "argo cd: $out"; return 0; fi
    if [[ $cfg == Failed || $cfg == Error ]]; then
      err "the configure job failed - see: kubectl -n poc-config logs job/configure"; return 1
    fi
    (( t >= 3000 )) && { err "stack not ready after ${t}s: $out (config: ${cfg:-pending})"; return 1; }
    sleep 15; t=$((t + 15))
    if (( t % 60 == 0 )); then log "  ${out:-waiting for applications} config:${cfg:-pending}"; fi
  done
}

# Re-run the configure job now (instead of waiting for the next change)
resync_config() {
  kubectl -n argocd patch applications.argoproj.io config --type merge \
    -p '{"operation":{"initiatedBy":{"username":"bootstrap"},"sync":{"revision":"main"}}}' >/dev/null
}

# ------------------------------------------------------------------- secret --
# ./bootstrap.sh secret <name> <value> : set a value in the store, then re-apply settings
# set_secret <name> <value> [<name> <value> ...] - one configure run for all of them
set_secret() {
  (( $# >= 2 && $# % 2 == 0 )) || die "usage: secret <name> <value> [<name> <value> ...]"
  local names=() name value want t var
  while (( $# )); do
    name=$1 value=$2; shift 2
    [[ $name =~ ^[a-z0-9_]+$ ]] || die "use a lower-case name, e.g. device_ro_password"
    save_secret "${name^^}" "$value"; names+=("$name")
  done
  store_sync
  kubectl -n poc-config annotate externalsecret config-env force-sync="$(date +%s)" --overwrite >/dev/null 2>&1 || true
  for name in "${names[@]}"; do
    var=${name^^}; want=$(printf "%s" "${!var}" | base64 -w0); t=0
    until [[ $(kubectl -n poc-config get secret config-env -o jsonpath="{.data.${name}}" 2>/dev/null) == "$want" ]]; do
      (( t >= 120 )) && { warn "${name} not picked up yet - it will be within a few minutes"; break; }
      sleep 3; t=$((t + 3))
    done
  done
  resync_config
  ok "${names[*]} saved; Argo CD is re-applying the settings (configure job)"
}

# ------------------------------------------------------------------- output --
info() {
  local f="$GEN_DIR/ACCESS.txt"; mkdir -p "$GEN_DIR"
  cat >"$f" <<EOF
================================================================================
 PoC stack - access (node IP + port, no DNS)
================================================================================
 NetBox  : ${NETBOX_URL}
 AWX     : ${AWX_URL}
 Gitea   : ${GITEA_URL}        repos: infra/stack (platform), infra/playbooks
 Argo CD : ${ARGOCD_URL}

 Login (all four) : ${POC_ADMIN_USER} / ${POC_ADMIN_PASSWORD}

 Change the platform: commit to infra/stack in Gitea - Argo CD applies it.
 Device / SolarWinds logins: ./bootstrap.sh setup
================================================================================
EOF
  chmod 600 "$f"; cat "$f"
}

status() {
  kubectl -n argocd get applications.argoproj.io 2>/dev/null || echo "Argo CD not installed yet"
  echo; kubectl get pods -A --no-headers 2>/dev/null | awk '$1 ~ /^(argocd|gitea|external-secrets|data|netbox|awx|poc-config)$/'
}

# --------------------------------------------------------------------- main --
main() {
  local cmd=${1:-all}
  load_config
  case $cmd in
    all)
      ensure_secrets
      if setup_needed; then setup_wizard; fi
      preflight; argocd_hash
      store_sync; foundation_secrets
      seed_gitea_argocd
      publish_repos; argocd_repo_access; store_sync
      hand_over; wait_stack; info ;;
    recover)   # break-glass: re-install Gitea + Argo CD from this checkout
      ensure_secrets; [[ -n ${POC_ADMIN_PASSWORD:-} ]] || die "POC_ADMIN_PASSWORD missing from .secrets.env"
      preflight; argocd_hash; store_sync; foundation_secrets
      seed_gitea_argocd force; ok "Gitea and Argo CD restored from the local copy" ;;
    setup)     ensure_secrets; setup_wizard ;;
    secret)    shift; ensure_secrets; set_secret "$@" ;;
    publish)   # push this checkout's stack/ and playbooks/ to Gitea (files changed in Gitea are kept)
      ensure_secrets; publish_repos ;;
    preflight) ensure_secrets; preflight ;;
    status)    status ;;
    info)      info ;;
    *) echo "usage: $0 [all|setup|preflight|status|info|publish|recover] | secret <name> <value> [<name> <value> ...]"; exit 1 ;;
  esac
}
main "$@"
