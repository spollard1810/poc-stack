# shellcheck shell=bash
# Shared helpers for bootstrap.sh and the seed scripts.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GEN_DIR="$ROOT_DIR/.generated"
SECRETS_FILE="$ROOT_DIR/.secrets.env"

# ---- logging -----------------------------------------------------------------
c_blu=$'\e[34m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_red=$'\e[31m'; c_off=$'\e[0m'
log()  { printf '%s==>%s %s\n' "$c_blu" "$c_off" "$*"; }
ok()   { printf '%s ✔%s  %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '%s !%s  %s\n' "$c_ylw" "$c_off" "$*" >&2; }
err()  { printf '%s ✘%s  %s\n' "$c_red" "$c_off" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---- config ------------------------------------------------------------------
load_config() {
  # shellcheck disable=SC1091
  set -a
  source "$ROOT_DIR/config.env"
  [[ -f $SECRETS_FILE ]] && source "$SECRETS_FILE"
  set +a

  if [[ -z ${KUBECONFIG:-} && ! -f $HOME/.kube/config ]]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  fi

  if [[ -z ${NODE_IP:-} ]]; then
    NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
    [[ -n $NODE_IP ]] || NODE_IP=$(hostname -I | awk '{print $1}')
  fi
  # External URLs: node IP + NodePort (no DNS, no ingress)
  NETBOX_URL="http://${NODE_IP}:${NETBOX_PORT}"
  AWX_URL="http://${NODE_IP}:${AWX_PORT}"
  GITEA_URL="http://${NODE_IP}:${GITEA_PORT}"

  # In-cluster service addresses
  PG_HOST="postgres.data.svc.cluster.local"
  VALKEY_HOST="valkey.data.svc.cluster.local"
  GITEA_INTERNAL_URL="http://gitea-http.gitea.svc.cluster.local:3000"
  NETBOX_INTERNAL_URL="http://netbox.netbox.svc.cluster.local"

  export NODE_IP NETBOX_URL AWX_URL GITEA_URL PG_HOST VALKEY_HOST \
         GITEA_INTERNAL_URL NETBOX_INTERNAL_URL
}

# Generate random secrets once; re-runs reuse them.
rand_hex() { od -An -tx1 -N"${1:-16}" /dev/urandom | tr -d ' \n'; }
ensure_secrets() {
  local changed=0
  touch "$SECRETS_FILE"; chmod 600 "$SECRETS_FILE"
  local k
  for k in PG_SUPERUSER_PASSWORD NETBOX_DB_PASSWORD AWX_DB_PASSWORD GITEA_DB_PASSWORD VALKEY_PASSWORD AWX_EVENTS_PASSWORD; do
    grep -q "^$k=" "$SECRETS_FILE" || { echo "$k=$(rand_hex 16)" >>"$SECRETS_FILE"; changed=1; }
  done
  for k in NETBOX_SECRET_KEY NETBOX_PEPPER AWX_SECRET_KEY; do
    grep -q "^$k=" "$SECRETS_FILE" || { echo "$k=$(rand_hex 32)" >>"$SECRETS_FILE"; changed=1; }
  done
  grep -q "^NETBOX_SUPERUSER_TOKEN=" "$SECRETS_FILE" || { echo "NETBOX_SUPERUSER_TOKEN=$(rand_hex 20)" >>"$SECRETS_FILE"; changed=1; }
  (( changed )) && ok "generated secrets in .secrets.env"
  set -a; source "$SECRETS_FILE"; set +a
}

# Persist a value into .secrets.env (replace if present).
save_secret() {
  local k=$1 v=$2
  if grep -q "^$k=" "$SECRETS_FILE"; then
    sed -i "s|^$k=.*|$k=$v|" "$SECRETS_FILE"
  else
    echo "$k=$v" >>"$SECRETS_FILE"
  fi
  export "$k=$v"
}

# ---- templating / kube -------------------------------------------------------
# render <template>  -> prints file with only ${VARS} that appear in it substituted
render() {
  local f=$1 vars
  vars=$(grep -oE '\$\{[A-Z0-9_]+\}' "$f" | sort -u | tr '\n' ' ')
  envsubst "$vars" <"$f"
}

# apply_tpl <template> : render and kubectl apply
apply_tpl() { render "$1" | kubectl apply -f -; }

# kube_secret <ns> <name> key=value [key=value...]   (idempotent)
kube_secret() {
  local ns=$1 name=$2; shift 2
  local args=() kv
  for kv in "$@"; do args+=("--from-literal=$kv"); done
  kubectl -n "$ns" create secret generic "$name" "${args[@]}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

# wait_rollout <ns> <kind/name> [timeout]
wait_rollout() { kubectl -n "$1" rollout status "$2" --timeout="${3:-600s}"; }

# ---- HTTP to the apps via NODE_IP:NodePort -----------------------------------
# Callers set API_AUTH=( -u user:pass ) or ( -H "Authorization: ..." )
API_AUTH=()
# api <base-url> <METHOD> <path> [json-body]   -> prints body; non-zero on HTTP >= 400
api() {
  local base=$1 method=$2 path=$3 data=${4:-}
  local args=(-sS --max-time 120 -X "$method" -H "Accept: application/json" "${API_AUTH[@]}")
  [[ -n $data ]] && args+=(-H "Content-Type: application/json" --data "$data")
  local out code
  out=$(curl "${args[@]}" -w $'\n%{http_code}' "${base}${path}") || return 1
  code=${out##*$'\n'}; out=${out%$'\n'*}
  if (( code >= 400 )); then
    err "$method ${base}${path} -> HTTP $code: ${out:0:400}"
    return 1
  fi
  printf '%s' "$out"
}

# wait_http <base-url> <path> <timeout-seconds>  : wait for HTTP 200
wait_http() {
  local base=$1 path=$2 timeout=${3:-900} t=0 code
  while :; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${base}${path}" || true)
    [[ $code == 200 ]] && return 0
    (( t >= timeout )) && { err "timeout waiting for ${base}${path} (last HTTP $code)"; return 1; }
    sleep 10; t=$((t + 10))
    if (( t % 60 == 0 )); then log "  still waiting for ${base}${path} (HTTP $code, ${t}s)"; fi
  done
}
