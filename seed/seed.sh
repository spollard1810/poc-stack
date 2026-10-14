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
  ok "netbox: API token valid"

  seed_netbox_discovery
}

# nb_ensure <endpoint> <query> <json>  -> prints object id (creates if missing)
nb_ensure() {
  local ep=$1 q=$2 body=$3 id
  id=$(api "$NETBOX_URL" GET "/api/${ep}/?${q}&limit=1" | jq -r '.results[0].id // empty')
  [[ -n $id ]] || id=$(api "$NETBOX_URL" POST "/api/${ep}/" "$body" | jq -r .id)
  [[ -n $id && $id != null ]] || { err "netbox: failed to ensure $ep ($q)"; return 1; }
  echo "$id"
}

# What "Add devices for discovery" needs that the device-type library doesn't
# provide: state tags, two custom fields, platforms with Ansible login settings,
# a placeholder type per vendor, the Unassigned site/role, and the script.
seed_netbox_discovery() {
  local t slug color desc
  for t in "discover|2196f3|Queued: AWX will log in and fill in this device" \
           "discovering|ff9800|AWX discovery is running" \
           "discovered|4caf50|Filled in by AWX discovery" \
           "discovery-failed|f44336|AWX could not discover this device - see its journal"; do
    IFS='|' read -r slug color desc <<<"$t"
    nb_ensure extras/tags "slug=$slug" "$(jq -nc --arg s "$slug" --arg c "$color" --arg d "$desc" \
      '{name:$s, slug:$s, color:$c, description:$d}')" >/dev/null
  done

  nb_ensure extras/custom-fields "name=os_version" \
    '{"name":"os_version","label":"OS version","type":"text","object_types":["dcim.device"],"group_name":"Discovery","description":"Read from the device by AWX discovery"}' >/dev/null
  nb_ensure extras/custom-fields "name=last_discovered" \
    '{"name":"last_discovered","label":"Last discovered","type":"datetime","object_types":["dcim.device"],"group_name":"Discovery"}' >/dev/null

  # Manufacturers come from the device-type library import. One not imported yet is
  # created with the library's own name/slug, so a later import merges into it.
  local p mslug mname pslug pname netos mfr plat
  for p in "cisco|Cisco|cisco-ios|Cisco IOS / IOS-XE|cisco.ios.ios" \
           "cisco|Cisco|cisco-nxos|Cisco NX-OS|cisco.nxos.nxos" \
           "arista|Arista|arista-eos|Arista EOS|arista.eos.eos" \
           "juniper|Juniper|juniper-junos|Juniper Junos|junipernetworks.junos.junos"; do
    IFS='|' read -r mslug mname pslug pname netos <<<"$p"
    mfr=$(nb_ensure dcim/manufacturers "slug=$mslug" "$(jq -nc --arg s "$mslug" --arg n "$mname" '{name:$n, slug:$s}')")
    nb_ensure dcim/device-types "slug=${mslug}-pending-discovery" "$(jq -nc --argjson m "$mfr" --arg s "${mslug}-pending-discovery" \
      '{manufacturer:$m, model:"Pending discovery", slug:$s, u_height:0,
        comments:"Placeholder until AWX discovery matches the real model (by part number) from the device-type library."}')" >/dev/null
    plat=$(nb_ensure dcim/platforms "slug=$pslug" "$(jq -nc --arg s "$pslug" --arg n "$pname" --argjson m "$mfr" \
      '{name:$n, slug:$s, manufacturer:$m}')")
    nb_ensure extras/config-contexts "name=$(urlenc "Ansible login: $pname")" "$(jq -nc --arg n "Ansible login: $pname" --argjson pl "$plat" --arg os "$netos" \
      '{name:$n, weight:1000, platforms:[$pl], description:"How AWX connects to devices on this platform",
        data:{ansible_network_os:$os, ansible_connection:"ansible.netcommon.network_cli"}}')" >/dev/null
  done
  nb_ensure dcim/sites "slug=unassigned" '{"name":"Unassigned","slug":"unassigned","status":"planned","description":"Devices waiting to be placed"}' >/dev/null
  nb_ensure dcim/device-roles "slug=unassigned" '{"name":"Unassigned","slug":"unassigned","color":"9e9e9e"}' >/dev/null

  # The custom script: update by file name, create on first install
  local f="$ROOT_DIR/netbox-scripts/discovery.py" code
  code=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH "${API_AUTH[@]}" \
    -F "file=@${f};filename=discovery.py" "${NETBOX_URL}/api/extras/scripts/upload/discovery.py/")
  if [[ $code == 404 ]]; then
    code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "${API_AUTH[@]}" \
      -F "file=@${f};filename=discovery.py" "${NETBOX_URL}/api/extras/scripts/upload/")
  fi
  [[ $code == 20[01] ]] || { err "netbox: uploading the discovery script failed (HTTP $code)"; return 1; }
  ok "netbox: discovery ready (state tags, 4 platforms with login settings, script 'Add devices for discovery')"
}

# NetBox -> AWX: launch discovery once when the script finishes, or when a device
# gets the "discover" tag. Runs after seed_awx (needs the job template and token).
seed_netbox_events() {
  log "Wiring NetBox events to AWX"
  nb_auth
  local launch_url body wh
  launch_url="http://awx-service.awx.svc.cluster.local/api/v2/job_templates/${AWX_DISCOVERY_JT_ID}/launch/"
  body=$(jq -nc --arg u "$launch_url" --arg h "Authorization: Bearer ${AWX_EVENTS_TOKEN}" \
    '{name:"AWX - launch discovery", payload_url:$u, http_method:"POST", http_content_type:"application/json",
      additional_headers:$h, body_template:"{}", ssl_verification:false, timeout:15,
      description:"Launches the AWX job template \"NetBox - Discover devices\""}')
  wh=$(api "$NETBOX_URL" GET "/api/extras/webhooks/?name=$(urlenc 'AWX - launch discovery')" | jq -r '.results[0].id // empty')
  if [[ -n $wh ]]; then api "$NETBOX_URL" PATCH "/api/extras/webhooks/${wh}/" "$body" >/dev/null
  else wh=$(api "$NETBOX_URL" POST /api/extras/webhooks/ "$body" | jq -r .id); fi

  nb_ensure extras/event-rules "name=$(urlenc 'Discovery: after Add devices script')" "$(jq -nc --argjson w "$wh" \
    '{name:"Discovery: after Add devices script", object_types:["extras.scriptmodule"], event_types:["job_completed"],
      action_type:"webhook", action_object_type:"extras.webhook", action_object_id:$w, enabled:true,
      description:"One AWX run per script run, however many devices were added"}')" >/dev/null
  nb_ensure extras/event-rules "name=$(urlenc 'Discovery: device tagged discover')" "$(jq -nc --argjson w "$wh" \
    '{name:"Discovery: device tagged discover", object_types:["dcim.device"], event_types:["object_updated"],
      conditions:{and:[{attr:"tags.slug", op:"contains", value:"discover"}]},
      action_type:"webhook", action_object_type:"extras.webhook", action_object_id:$w, enabled:true,
      description:"Re-run discovery for a device by adding the discover tag"}')" >/dev/null
  ok "netbox: event rules launch AWX discovery (script finished, or 'discover' tag added)"
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

  # Discovery: launched by NetBox events, plus a sweep every 30 minutes
  AWX_DISCOVERY_JT_ID=$(awx_ensure job_templates "NetBox - Discover devices" "$(jq -nc --argjson p "$proj" --argjson i "$inv" \
    '{name:"NetBox - Discover devices", description:"Fill in the empty fields of devices tagged discover in NetBox",
      project:$p, playbook:"netbox_discover.yml", inventory:$i, job_type:"run", allow_simultaneous:false}')")
  api "$AWX_URL" POST "/api/v2/job_templates/${AWX_DISCOVERY_JT_ID}/instance_groups/" "{\"id\":$ig}" >/dev/null 2>&1 || true
  for c in $cr_lab $cr_nb; do
    api "$AWX_URL" POST "/api/v2/job_templates/${AWX_DISCOVERY_JT_ID}/credentials/" "{\"id\":$c}" >/dev/null 2>&1 || true
  done
  if [[ $(api "$AWX_URL" GET "/api/v2/job_templates/${AWX_DISCOVERY_JT_ID}/schedules/" | jq -r .count) == 0 ]]; then
    api "$AWX_URL" POST "/api/v2/job_templates/${AWX_DISCOVERY_JT_ID}/schedules/" \
      '{"name":"Discovery sweep every 30 minutes","rrule":"DTSTART:20260101T000000Z RRULE:FREQ=MINUTELY;INTERVAL=30"}' >/dev/null
  fi

  # Least-privilege user NetBox launches it as: may only execute that one template
  local ev_user role tok
  ev_user=$(api "$AWX_URL" GET "/api/v2/users/?username=netbox-events" | jq -r '.results[0].id // empty')
  if [[ -z $ev_user ]]; then
    ev_user=$(api "$AWX_URL" POST /api/v2/users/ "$(jq -nc --arg p "$AWX_EVENTS_PASSWORD" \
      '{username:"netbox-events", password:$p, first_name:"NetBox", last_name:"event rules"}')" | jq -r .id)
  fi
  role=$(api "$AWX_URL" GET "/api/v2/job_templates/${AWX_DISCOVERY_JT_ID}/object_roles/" | jq -r '.results[] | select(.name=="Execute") | .id')
  api "$AWX_URL" POST "/api/v2/roles/${role}/users/" "{\"id\":$ev_user}" >/dev/null 2>&1 || true
  if [[ -z ${AWX_EVENTS_TOKEN:-} ]] || [[ $(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${AWX_EVENTS_TOKEN}" "$AWX_URL/api/v2/me/") != 200 ]]; then
    tok=$(curl -sS -u "netbox-events:${AWX_EVENTS_PASSWORD}" -H 'Content-Type: application/json' \
      -d '{"description":"NetBox event rules - launch discovery","scope":"write"}' "$AWX_URL/api/v2/tokens/" | jq -r '.token // empty')
    [[ -n $tok ]] || { err "awx: could not create the netbox-events token"; return 1; }
    save_secret AWX_EVENTS_TOKEN "$tok"
  fi
  ok "awx: job template 'NetBox - Discover devices' (+ 30-min sweep, launch-only user netbox-events)"

  log "Running smoke-test job"
  local job
  job=$(api "$AWX_URL" POST "/api/v2/job_templates/${jt_hello}/launch/" '{}' | jq -r .job)
  awx_wait "/api/v2/jobs/${job}/" 600 && ok "awx: 'Hello World' job #$job succeeded" || warn "awx: 'Hello World' job #$job failed"
  ok "awx: run 'NetBox Device Report' once you have added devices to NetBox"
}
