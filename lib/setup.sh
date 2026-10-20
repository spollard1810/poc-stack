# shellcheck shell=bash
# Step-by-step setup: node IP, admin account, device and SolarWinds logins.
#   ./bootstrap.sh setup     run (or re-run) it any time
# The first ./bootstrap.sh runs it automatically when started from a terminal;
# without a terminal it generates the admin password and skips the optional logins.
#
# Where the answers go (both files are git-ignored):
#   config.local.env  node IP, admin user and email (overrides config.env)
#   .secrets.env      every password, then copied into the in-cluster secret store

has_tty() { ( exec </dev/tty ) 2>/dev/null; }   # a terminal we can ask on
stack_deployed() { kubectl -n argocd get applications.argoproj.io stack >/dev/null 2>&1; }

gen_password() {  # 20 letters/digits: safe in every app and in shell, JSON and URLs
  local p=""
  while (( ${#p} < 20 )); do p+=$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9'); done
  printf '%s' "${p:0:20}"
}

# ask <prompt> <default> -> REPLY (Enter keeps the default)
ask() {
  local hint=""; [[ -n $2 ]] && hint=" [$2]"
  read -r -p "  $1$hint: " REPLY </dev/tty
  [[ -n $REPLY ]] || REPLY=$2
}

# ask_pw <prompt> <current> -> REPLY ; Enter keeps the current value (if any)
ask_pw() {
  local hint=" (Enter = skip)" a b; [[ -n $2 ]] && hint=" (Enter = keep current)"
  while :; do
    read -r -s -p "  $1$hint: " a </dev/tty; echo >/dev/tty
    [[ -z $a ]] && { REPLY=$2; return; }
    read -r -s -p "  again: " b </dev/tty; echo >/dev/tty
    [[ $a == "$b" ]] && { REPLY=$a; return; }
    warn "the two entries differ - try again"
  done
}

ask_yn() {  # ask_yn <prompt> <y|n default> -> exit status
  local d=$2 a; read -r -p "  $1 [$( [[ $d == y ]] && echo Y/n || echo y/N )]: " a </dev/tty
  a=${a:-$d}; [[ ${a,,} == y* ]]
}

save_local() {  # persist a non-secret setting into config.local.env
  local k=$1 v=$2 tmp; touch "$LOCAL_CONFIG"; chmod 600 "$LOCAL_CONFIG"; tmp=$(mktemp)
  grep -v "^$k=" "$LOCAL_CONFIG" >"$tmp" || true
  printf '%s=%q\n' "$k" "$v" >>"$tmp"; cat "$tmp" >"$LOCAL_CONFIG"; rm -f "$tmp"
  export "$k=$v"
}

setup_needed() { [[ -z ${POC_ADMIN_PASSWORD:-} || -z ${SETUP_DONE:-} ]]; }

# Unattended first run: generate what's required, leave the optional logins empty
setup_auto() {
  if [[ -z ${POC_ADMIN_PASSWORD:-} ]]; then
    stack_deployed && die "POC_ADMIN_PASSWORD is missing from .secrets.env but the stack is installed.
    Add the current admin password:  echo 'POC_ADMIN_PASSWORD=<password>' | sudo tee -a .secrets.env"
    save_secret POC_ADMIN_PASSWORD "$(gen_password)"
    ok "generated the admin password (shown at the end, and by ./bootstrap.sh info)"
  fi
  save_secret SETUP_DONE auto
}

setup_wizard() {
  has_tty || { warn "no terminal - generating defaults instead of asking"; setup_auto; return; }
  local deployed=0 pairs=() k v i
  stack_deployed && deployed=1
  cat >/dev/tty <<EOF

${c_blu}PoC stack setup${c_off}  -  press Enter to accept the value in [brackets].
Passwords are never shown or stored in Git: they go to .secrets.env and the
in-cluster secret store. Re-run any time with: ./bootstrap.sh setup

EOF
  # ---- 1. platform --------------------------------------------------------------
  echo "1) Platform" >/dev/tty
  if (( deployed )); then
    echo "   Already installed - node IP and admin account stay as they are (${POC_ADMIN_USER} @ ${NODE_IP})." >/dev/tty
    [[ -n ${POC_ADMIN_PASSWORD:-} ]] || setup_auto
  else
    ask "Node IP the apps will be reached on" "$NODE_IP"; save_local NODE_IP "$REPLY"
    while :; do
      ask "Admin username (NetBox, AWX, Gitea, Argo CD)" "$POC_ADMIN_USER"
      [[ $REPLY =~ ^[a-z][a-z0-9._-]{2,31}$ && $REPLY != admin ]] && break
      warn "3-32 lower-case letters, digits, . _ - ; 'admin' is reserved in Gitea"
    done
    save_local POC_ADMIN_USER "$REPLY"
    ask "Admin email" "$POC_ADMIN_EMAIL"; save_local POC_ADMIN_EMAIL "$REPLY"
    while :; do
      ask_pw "Admin password, 12+ characters (Enter = generate one)" "${POC_ADMIN_PASSWORD:-}"
      [[ -z $REPLY ]] && { REPLY=$(gen_password); echo "   generated - shown at the end of the install" >/dev/tty; break; }
      [[ ${#REPLY} -ge 12 && $REPLY != *[[:space:]]* ]] && break
      warn "use at least 12 characters and no spaces"
    done
    save_secret POC_ADMIN_PASSWORD "$REPLY"
  fi

  # ---- 2. device logins -----------------------------------------------------------
  cat >/dev/tty <<EOF

2) Device logins (optional - Enter skips; AWX jobs need them to log in to devices)
   Read-only: used by discovery and every report.  Change: reserved for future write jobs.
EOF
  ask "Read-only username" "${DEVICE_RO_USERNAME:-}"; pairs+=(device_ro_username "$REPLY")
  ask_pw "Read-only password" "${DEVICE_RO_PASSWORD:-}"; pairs+=(device_ro_password "$REPLY")
  ask "Change (read-write) username" "${DEVICE_RW_USERNAME:-}"; pairs+=(device_rw_username "$REPLY")
  ask_pw "Change password" "${DEVICE_RW_PASSWORD:-}"; pairs+=(device_rw_password "$REPLY")

  # ---- 3. SolarWinds -------------------------------------------------------------
  cat >/dev/tty <<EOF

3) SolarWinds (optional - Enter skips). Use a read-only account; the import sees
   exactly the nodes that account can see.
EOF
  ask "SWIS URL, e.g. https://solarwinds.example:17774" "${SOLARWINDS_URL:-}"; pairs+=(solarwinds_url "${REPLY%/}")
  if [[ -n $REPLY ]]; then
    ask "Username" "${SOLARWINDS_USERNAME:-}"; pairs+=(solarwinds_username "$REPLY")
    ask_pw "Password" "${SOLARWINDS_PASSWORD:-}"; pairs+=(solarwinds_password "$REPLY")
    if ask_yn "Verify its TLS certificate? (No for a self-signed certificate)" "$( [[ ${SOLARWINDS_VERIFY_SSL:-} == true ]] && echo y || echo n )"; then
      pairs+=(solarwinds_verify_ssl true); else pairs+=(solarwinds_verify_ssl false); fi
  fi

  # ---- save ----------------------------------------------------------------------
  local changed=()
  for ((i = 0; i < ${#pairs[@]}; i += 2)); do
    k=${pairs[i]^^} v=${pairs[i+1]}
    [[ ${!k-} == "$v" ]] || changed+=("${pairs[i]}" "$v")
  done
  if (( deployed && ${#changed[@]} )); then
    set_secret "${changed[@]}"           # saves, updates the store, re-runs the configure job
  else
    for ((i = 0; i < ${#changed[@]}; i += 2)); do save_secret "${changed[i]^^}" "${changed[i+1]}"; done
  fi
  save_secret SETUP_DONE "$(date +%F)"
  echo >/dev/tty; ok "setup saved ($(( ${#changed[@]} / 2 )) login value(s) changed)"
  load_config                                # node IP / URLs may have changed
}
