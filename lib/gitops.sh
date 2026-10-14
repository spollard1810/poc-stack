# shellcheck shell=bash
# GitOps: Argo CD (foundation) + the infra/platform repo in Gitea, which Argo CD
# syncs NetBox and AWX from. Sourced by bootstrap.sh.

# --- Argo CD -------------------------------------------------------------------
deploy_argocd() {
  # bcrypt hash of the PoC admin password for Argo CD's local account
  # (recomputed only when the password changes, so sessions survive re-runs)
  local pw_sha
  pw_sha=$(printf '%s' "$POC_ADMIN_PASSWORD" | sha256sum | cut -c1-16)
  if [[ ${ARGOCD_ADMIN_PW_SHA:-} != "$pw_sha" || -z ${ARGOCD_ADMIN_HASH:-} ]]; then
    save_secret ARGOCD_ADMIN_HASH "$(htpasswd -nbBC 10 "" "$POC_ADMIN_PASSWORD" | tr -d ':\n' | sed 's/^\$2y/$2a/')"
    save_secret ARGOCD_ADMIN_PW_SHA "$pw_sha"
  fi
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  helm_app argocd argocd argo-cd https://argoproj.github.io/argo-helm "$ARGOCD_CHART_VERSION" values/argocd.yaml
}

# --- secrets the platform apps reference by name (never stored in Git) ---------
platform_secrets() {
  kube_secret netbox netbox-superuser-secret username="$POC_ADMIN_USER" password="$POC_ADMIN_PASSWORD" \
    email="$POC_ADMIN_EMAIL" api_token="$NETBOX_SUPERUSER_TOKEN"
  kube_secret netbox netbox-app-secret secret_key="$NETBOX_SECRET_KEY" \
    api_token_peppers="{\"1\": \"$NETBOX_PEPPER\"}" email_password="" ldap_bind_password=""
  kube_secret netbox netbox-db-secret password="$NETBOX_DB_PASSWORD"
  kube_secret netbox netbox-valkey-secret password="$VALKEY_PASSWORD"

  kube_secret awx awx-admin-password password="$POC_ADMIN_PASSWORD"
  kube_secret awx awx-secret-key secret_key="$AWX_SECRET_KEY"
  kube_secret awx awx-postgres-configuration \
    host="$PG_HOST" port=5432 database=awx username=awx password="$AWX_DB_PASSWORD" \
    sslmode=prefer type=unmanaged
  ok "platform secrets in place (referenced by name from the platform repo)"
}

# --- the infra/platform repo ---------------------------------------------------
# Rendered from platform/ (node IP, ports, versions filled in), pushed to Gitea.
# Later runs only add/update files that still match what bootstrap wrote, so
# changes made in Gitea win.
publish_platform_repo() {
  log "GitOps repo infra/platform"
  wait_http "$GITEA_URL" /api/healthz 900 || return 1
  API_AUTH=(-u "${POC_ADMIN_USER}:${POC_ADMIN_PASSWORD}")
  api "$GITEA_URL" GET /api/v1/orgs/infra >/dev/null 2>&1 || \
    api "$GITEA_URL" POST /api/v1/orgs '{"username":"infra","full_name":"Infrastructure","visibility":"private"}' >/dev/null
  api "$GITEA_URL" GET /api/v1/repos/infra/platform >/dev/null 2>&1 || \
    api "$GITEA_URL" POST /api/v1/orgs/infra/repos \
      '{"name":"platform","private":true,"default_branch":"main","description":"Platform config - Argo CD syncs the cluster from this repo"}' >/dev/null

  local out="$GEN_DIR/platform" f rel
  rm -rf "$out"; mkdir -p "$out"
  while IFS= read -r -d '' f; do
    rel=${f#platform/}; mkdir -p "$out/$(dirname "$rel")"
    render "$f" >"$out/$rel"
  done < <(find platform -type f -print0)
  bash tools/sync-repo.sh "$out" infra/platform
}

# Argo CD reads the repo as a dedicated, read-only Gitea user ("argocd"),
# restricted to the repos its team grants - only infra/platform.
argocd_repo_access() {
  API_AUTH=(-u "${POC_ADMIN_USER}:${POC_ADMIN_PASSWORD}")
  if ! api "$GITEA_URL" GET /api/v1/users/argocd >/dev/null 2>&1; then
    api "$GITEA_URL" POST /api/v1/admin/users "$(jq -nc --arg p "$GITEA_ARGOCD_PASSWORD" \
      '{username:"argocd", email:"argocd@poc.local", password:$p, must_change_password:false, restricted:true,
        full_name:"Argo CD (read-only)"}')" >/dev/null
  fi
  local team
  team=$(api "$GITEA_URL" GET "/api/v1/orgs/infra/teams/search?q=gitops-readers" | jq -r '.data[0].id // empty')
  if [[ -z $team ]]; then
    team=$(api "$GITEA_URL" POST /api/v1/orgs/infra/teams \
      '{"name":"gitops-readers","description":"Read-only access for Argo CD","permission":"read","units":["repo.code"],"includes_all_repositories":false}' | jq -r .id)
  fi
  api "$GITEA_URL" PUT "/api/v1/teams/${team}/members/argocd" >/dev/null
  api "$GITEA_URL" PUT "/api/v1/teams/${team}/repos/infra/platform" >/dev/null

  # read-only token, kept in .secrets.env; replaced if it stops working
  if [[ -z ${GITEA_ARGOCD_TOKEN:-} ]] || [[ $(curl -s -o /dev/null -w '%{http_code}' \
       -H "Authorization: token ${GITEA_ARGOCD_TOKEN}" "$GITEA_URL/api/v1/repos/infra/platform") != 200 ]]; then
    curl -s -u "argocd:${GITEA_ARGOCD_PASSWORD}" -X DELETE "$GITEA_URL/api/v1/users/argocd/tokens/argocd-read" >/dev/null || true
    local tok
    tok=$(curl -sS -u "argocd:${GITEA_ARGOCD_PASSWORD}" -H 'Content-Type: application/json' \
      -d '{"name":"argocd-read","scopes":["read:repository"]}' "$GITEA_URL/api/v1/users/argocd/tokens" | jq -r '.sha1 // empty')
    [[ -n $tok ]] || { err "gitea: could not create the argocd token"; return 1; }
    save_secret GITEA_ARGOCD_TOKEN "$tok"
  fi

  kubectl -n argocd create secret generic repo-platform \
    --from-literal=type=git --from-literal=url="$PLATFORM_REPO_URL" \
    --from-literal=username=argocd --from-literal=password="$GITEA_ARGOCD_TOKEN" \
    --dry-run=client -o yaml \
    | kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
    | kubectl apply -f - >/dev/null
  ok "argo cd: reads infra/platform as read-only Gitea user 'argocd'"
}

# --- hand NetBox and AWX to Argo CD --------------------------------------------
apply_root_app() {
  kubectl apply -f "$GEN_DIR/platform/root.yaml" >/dev/null
  ok "argo cd: root app 'platform' applied - NetBox and AWX are now managed from Git"
}

wait_argocd_apps() {
  log "Waiting for Argo CD to sync NetBox and AWX (first sync adopts what is already running)"
  local t=0 out bad
  while :; do
    out=$(kubectl -n argocd get applications.argoproj.io \
      -o jsonpath='{range .items[*]}{.metadata.name}={.status.sync.status}/{.status.health.status} {end}' 2>/dev/null || true)
    bad=$(tr ' ' '\n' <<<"$out" | grep -v '=Synced/Healthy$' | grep -c . || true)
    if [[ $(wc -w <<<"$out") -ge 4 && $bad == 0 ]]; then ok "argo cd: $out"; return 0; fi
    (( t >= 1500 )) && { err "argo cd apps not healthy after ${t}s: $out"; return 1; }
    sleep 10; t=$((t + 10))
    if (( t % 60 == 0 )); then log "  ${out:-waiting for applications}"; fi
  done
}
