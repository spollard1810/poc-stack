# shellcheck shell=bash
# Seed functions (sourced by bootstrap.sh). Every step is idempotent.

urlenc() { jq -rn --arg s "$1" '$s|@uri'; }

# =============================================================================
# Gitea: org "infra", private repo "infra/playbooks" with the sample content
# =============================================================================
seed_gitea() {
  log "Seeding Gitea"
  wait_http "$GITEA_URL" /api/healthz 900 || return 1
  API_AUTH=(-u "${POC_ADMIN_USER}:${POC_ADMIN_PASSWORD}")

  if ! api "$GITEA_URL" GET /api/v1/orgs/infra >/dev/null 2>&1; then
    api "$GITEA_URL" POST /api/v1/orgs \
      '{"username":"infra","full_name":"Infrastructure","visibility":"private"}' >/dev/null
    ok "gitea: created org infra"
  fi

  if ! api "$GITEA_URL" GET /api/v1/repos/infra/playbooks >/dev/null 2>&1; then
    api "$GITEA_URL" POST /api/v1/orgs/infra/repos \
      '{"name":"playbooks","private":true,"default_branch":"main","description":"Ansible playbooks used by AWX"}' >/dev/null
    ok "gitea: created repo infra/playbooks"
  fi

  if [[ $(api "$GITEA_URL" GET /api/v1/repos/infra/playbooks | jq -r .empty) == true ]]; then
    local tmp auth
    tmp=$(mktemp -d)
    cp -r "$ROOT_DIR/seed/playbooks/." "$tmp/"
    auth=$(printf '%s:%s' "$POC_ADMIN_USER" "$POC_ADMIN_PASSWORD" | base64 -w0)
    git -C "$tmp" init -q -b main
    git -C "$tmp" add -A
    git -C "$tmp" -c user.name="PoC Bootstrap" -c user.email="$POC_ADMIN_EMAIL" commit -q -m "Initial playbooks"
    git -C "$tmp" -c http.extraHeader="Authorization: Basic ${auth}" \
      push -q "${GITEA_URL}/infra/playbooks.git" main
    rm -rf "$tmp"
    ok "gitea: pushed sample playbooks"
  else
    # Bring in new/updated examples; files edited in Gitea are left alone
    bash "$ROOT_DIR/tools/sync-playbooks.sh"
  fi
}

# =============================================================================
# NetBox: API token for AWX (no demo data - devices are added by you)
# =============================================================================
nb_auth() {
  if [[ $NETBOX_API_TOKEN == nbt_* ]]; then
    API_AUTH=(-H "Authorization: Bearer ${NETBOX_API_TOKEN}")
  else
    API_AUTH=(-H "Authorization: Token ${NETBOX_API_TOKEN}")
  fi
}

seed_netbox() {
  log "Seeding NetBox"
  wait_http "$NETBOX_URL" /api/status/ 1200 || return 1

  # --- API token (provisioned once, stored in .secrets.env) ---
  if [[ -n ${NETBOX_API_TOKEN:-} ]]; then
    nb_auth
    api "$NETBOX_URL" GET /api/users/config/ >/dev/null 2>&1 || NETBOX_API_TOKEN=""
  fi
  if [[ -z ${NETBOX_API_TOKEN:-} ]]; then
    local resp key tok
    API_AUTH=()
    resp=$(api "$NETBOX_URL" POST /api/users/tokens/provision/ "$(jq -nc \
      --arg u "$POC_ADMIN_USER" --arg p "$POC_ADMIN_PASSWORD" \
      '{username:$u, password:$p, description:"poc-bootstrap (AWX inventory)", write_enabled:true}')") || return 1
    key=$(jq -r '.key // empty' <<<"$resp"); tok=$(jq -r '.token // empty' <<<"$resp")
    [[ -n $tok ]] || { err "netbox: token provisioning returned no token: $resp"; return 1; }
    if [[ -n $key ]]; then save_secret NETBOX_API_TOKEN "nbt_${key}.${tok}"   # v2 token
    else save_secret NETBOX_API_TOKEN "$tok"; fi                            # v1 token
    ok "netbox: provisioned API token"
  fi
  nb_auth
  api "$NETBOX_URL" GET /api/users/config/ >/dev/null || { err "netbox: API token check failed"; return 1; }
  ok "netbox: API token valid (no demo data created - add your own devices)"
}

# =============================================================================
# AWX: org, credentials, project, NetBox inventory, worker container group,
#      job templates; then run the smoke tests.
# =============================================================================
# awx_ensure <endpoint> <name> <json> [create-only] -> prints id
awx_ensure() {
  local ep=$1 name=$2 body=$3 mode=${4:-} id
  id=$(api "$AWX_URL" GET "/api/v2/${ep}/?name=$(urlenc "$name")" | jq -r '.results[0].id // empty')
  if [[ -n $id ]]; then
    [[ $mode == create-only ]] || api "$AWX_URL" PATCH "/api/v2/${ep}/${id}/" "$body" >/dev/null
  else
    id=$(api "$AWX_URL" POST "/api/v2/${ep}/" "$body" | jq -r .id)
  fi
  [[ -n $id && $id != null ]] || { err "awx: failed to ensure $ep/$name"; return 1; }
  echo "$id"
}

# awx_wait <api-path-of-job> [timeout] : wait for a job/update to finish
awx_wait() {
  local path=$1 timeout=${2:-900} t=0 status
  while :; do
    status=$(api "$AWX_URL" GET "$path" | jq -r .status)
    case $status in
      successful) return 0 ;;
      failed|error|canceled) err "awx: $path finished with status $status"; return 1 ;;
    esac
    (( t >= timeout )) && { err "awx: timeout waiting for $path ($status)"; return 1; }
    sleep 5; t=$((t + 5))
  done
}

awx_cred_type_id() {  # <kind> e.g. scm, ssh
  api "$AWX_URL" GET "/api/v2/credential_types/?kind=$1&managed=true" | jq -r '.results[0].id'
}

seed_awx() {
  log "Seeding AWX (waiting for AWX to finish its first start - can take ~10 min)"
  wait_http "$AWX_URL" /api/v2/ping/ 1800 || return 1
  API_AUTH=(-u "${POC_ADMIN_USER}:${POC_ADMIN_PASSWORD}")
  local t=0
  until api "$AWX_URL" GET /api/v2/me/ >/dev/null 2>&1; do
    (( t >= 900 )) && { err "awx: admin login never succeeded"; return 1; }
    sleep 10; t=$((t + 10))
  done

  local org ct_nb ct_scm ct_ssh cr_gitea cr_nb proj inv src ig jt_hello upd body pod_spec
  local name pb desc id

  org=$(awx_ensure organizations "PoC" '{"name":"PoC","description":"PoC organization"}')
  # Without a Galaxy credential on the org, AWX skips collections/requirements.yml
  local galaxy
  galaxy=$(api "$AWX_URL" GET "/api/v2/credentials/?credential_type__kind=galaxy&managed=true" | jq -r '.results[0].id // empty')
  if [[ -n $galaxy ]]; then
    api "$AWX_URL" POST "/api/v2/organizations/${org}/galaxy_credentials/" "{\"id\":$galaxy}" >/dev/null 2>&1 || true
  else
    warn "awx: no managed Ansible Galaxy credential found - collections will not be installed"
  fi

  ct_nb=$(awx_ensure credential_types "NetBox API" '{
    "name":"NetBox API","kind":"cloud",
    "description":"Injects NETBOX_API / NETBOX_TOKEN for the netbox.netbox inventory plugin",
    "inputs":{"fields":[
      {"id":"NETBOX_API","label":"NetBox URL","type":"string"},
      {"id":"NETBOX_TOKEN","label":"NetBox API token","type":"string","secret":true}],
      "required":["NETBOX_API","NETBOX_TOKEN"]},
    "injectors":{"env":{"NETBOX_API":"{{ NETBOX_API }}","NETBOX_TOKEN":"{{ NETBOX_TOKEN }}"}}}' create-only)
  ct_scm=$(awx_cred_type_id scm)
  ct_ssh=$(awx_cred_type_id ssh)

  cr_gitea=$(awx_ensure credentials "Gitea" "$(jq -nc --argjson o "$org" --argjson t "$ct_scm" \
    --arg u "$POC_ADMIN_USER" --arg p "$POC_ADMIN_PASSWORD" \
    '{name:"Gitea",organization:$o,credential_type:$t,inputs:{username:$u,password:$p}}')")
  cr_nb=$(awx_ensure credentials "NetBox" "$(jq -nc --argjson o "$org" --argjson t "$ct_nb" \
    --arg url "$NETBOX_INTERNAL_URL" --arg tok "$NETBOX_API_TOKEN" \
    '{name:"NetBox",organization:$o,credential_type:$t,inputs:{NETBOX_API:$url,NETBOX_TOKEN:$tok}}')")
  local cr_lab
  cr_lab=$(awx_ensure credentials "Lab devices" "$(jq -nc --argjson o "$org" --argjson t "$ct_ssh" \
    '{name:"Lab devices",organization:$o,credential_type:$t,description:"Placeholder - set real device creds",inputs:{username:"ansible"}}')" create-only)
  ok "awx: org + credentials (Gitea, NetBox, Lab devices)"

  proj=$(awx_ensure projects "playbooks" "$(jq -nc --argjson o "$org" --argjson c "$cr_gitea" \
    --arg url "${GITEA_INTERNAL_URL}/infra/playbooks.git" \
    '{name:"playbooks",organization:$o,scm_type:"git",scm_url:$url,scm_branch:"main",credential:$c,
      scm_update_on_launch:true,scm_update_cache_timeout:0}')")
  upd=$(api "$AWX_URL" POST "/api/v2/projects/${proj}/update/" '{}' | jq -r .project_update)
  awx_wait "/api/v2/project_updates/${upd}/" || return 1
  ok "awx: project 'playbooks' synced from Gitea"

  inv=$(awx_ensure inventories "NetBox" "$(jq -nc --argjson o "$org" \
    '{name:"NetBox",organization:$o,description:"Dynamic inventory from NetBox"}')")
  src=$(awx_ensure inventory_sources "netbox" "$(jq -nc --argjson i "$inv" --argjson p "$proj" --argjson c "$cr_nb" \
    '{name:"netbox",inventory:$i,source:"scm",source_project:$p,source_path:"inventory/netbox.yml",
      credential:$c,overwrite:true,overwrite_vars:true,update_on_launch:true}')")
  upd=$(api "$AWX_URL" POST "/api/v2/inventory_sources/${src}/update/" '{}' | jq -r .inventory_update)
  awx_wait "/api/v2/inventory_updates/${upd}/" || warn "awx: NetBox inventory sync failed - check the job output in AWX"
  ok "awx: inventory 'NetBox' ($(api "$AWX_URL" GET "/api/v2/inventories/${inv}/" | jq -r .total_hosts) hosts - re-syncs on every job launch)"

  # Static localhost inventory so the smoke test does not depend on NetBox
  local inv_local
  inv_local=$(awx_ensure inventories "Local" "$(jq -nc --argjson o "$org" \
    '{name:"Local",organization:$o,description:"localhost only - for smoke tests"}')")
  if [[ $(api "$AWX_URL" GET "/api/v2/inventories/${inv_local}/hosts/?name=localhost" | jq -r .count) == 0 ]]; then
    api "$AWX_URL" POST "/api/v2/inventories/${inv_local}/hosts/" \
      '{"name":"localhost","variables":"ansible_connection: local\nansible_python_interpreter: \"{{ ansible_playbook_python }}\""}' >/dev/null
  fi
  ok "awx: inventory 'Local' (localhost)"

  # Static list of devices to discover/onboard, kept in Git (inventory/onboard.yml)
  local inv_onb src_onb
  inv_onb=$(awx_ensure inventories "Onboarding" "$(jq -nc --argjson o "$org" \
    '{name:"Onboarding",organization:$o,description:"Devices to discover - edit inventory/onboard.yml in Gitea"}')")
  src_onb=$(awx_ensure inventory_sources "onboard-file" "$(jq -nc --argjson i "$inv_onb" --argjson p "$proj" \
    '{name:"onboard-file",inventory:$i,source:"scm",source_project:$p,source_path:"inventory/onboard.yml",
      overwrite:true,overwrite_vars:true,update_on_launch:true}')")
  upd=$(api "$AWX_URL" POST "/api/v2/inventory_sources/${src_onb}/update/" '{}' | jq -r .inventory_update)
  awx_wait "/api/v2/inventory_updates/${upd}/" || warn "awx: Onboarding inventory sync failed"
  ok "awx: inventory 'Onboarding' (from inventory/onboard.yml)"

  # Ansible workers: every job runs as its own pod in the awx namespace
  pod_spec=$(cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  namespace: awx
  labels:
    app.kubernetes.io/component: ansible-worker
spec:
  serviceAccountName: default
  automountServiceAccountToken: false
  containers:
    - image: ${AWX_EE_IMAGE}
      name: worker
      args: ['ansible-runner', 'worker', '--private-data-dir=/runner']
      resources:
        requests: { cpu: 250m, memory: 256Mi }
        limits: { cpu: '2', memory: 2Gi }
EOF
)
  ig=$(awx_ensure instance_groups "ansible-workers" "$(jq -nc --arg spec "$pod_spec" \
    '{name:"ansible-workers",is_container_group:true,pod_spec_override:$spec,max_concurrent_jobs:10}')")
  ok "awx: container group 'ansible-workers'"

  # name | playbook | description | inventory | credentials (space-separated ids)
  local jt_inv jt_creds c
  for body in \
    "Hello World|hello.yml|Smoke test - runs on localhost in a worker pod|$inv_local|" \
    "NetBox Device Report|netbox_report.yml|Prints NetBox data for every device|$inv|" \
    "NetBox - Load devices|netbox_load_devices.yml|Create/update devices in NetBox from data/netbox_devices.yml|$inv_local|$cr_nb" \
    "NetBox - Onboard from devices|netbox_onboard_from_devices.yml|SSH to devices in inventory/onboard.yml and add them to NetBox|$inv_onb|$cr_lab $cr_nb"; do
    IFS='|' read -r name pb desc jt_inv jt_creds <<<"$body"
    id=$(awx_ensure job_templates "$name" "$(jq -nc --arg n "$name" --arg pb "$pb" --arg d "$desc" \
      --argjson p "$proj" --argjson i "$jt_inv" '{name:$n,description:$d,project:$p,playbook:$pb,inventory:$i,job_type:"run"}')")
    api "$AWX_URL" POST "/api/v2/job_templates/${id}/instance_groups/" "{\"id\":$ig}" >/dev/null 2>&1 || true
    for c in $jt_creds; do
      api "$AWX_URL" POST "/api/v2/job_templates/${id}/credentials/" "{\"id\":$c}" >/dev/null 2>&1 || true
    done
    if [[ $pb == hello.yml ]]; then jt_hello=$id; fi
  done
  ok "awx: job templates 'Hello World', 'NetBox Device Report', 'NetBox - Load devices', 'NetBox - Onboard from devices'"

  log "Running smoke-test job"
  local job
  job=$(api "$AWX_URL" POST "/api/v2/job_templates/${jt_hello}/launch/" '{}' | jq -r .job)
  awx_wait "/api/v2/jobs/${job}/" 600 && ok "awx: 'Hello World' job #$job succeeded" || warn "awx: 'Hello World' job #$job failed"
  ok "awx: run 'NetBox Device Report' once you have added devices to NetBox"
}
