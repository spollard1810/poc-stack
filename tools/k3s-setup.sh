#!/usr/bin/env bash
# =============================================================================
#  k3s for the PoC stack: installs k3s, or puts its pod/service networks right.
#  Kept apart from bootstrap.sh on purpose - this is the only script that can
#  delete the cluster, and it only does that after you type the server's name.
#
#    sudo ./tools/k3s-setup.sh --check   report only; exit 1 if k3s needs a change
#    sudo ./tools/k3s-setup.sh           install k3s, or show the plan and ask
#
#  Wanted settings come from config.env: POD_CIDR, SERVICE_CIDR, CLUSTER_DNS,
#  and K3S_VERSION (used only when k3s isn't installed yet).
#
#  Only k3s is touched. The VM, its OS, IP and network settings, SSH, users,
#  files and other services are left alone. Recreating the cluster deletes what
#  runs inside k3s (and its volumes); the k3s version and every other k3s
#  setting are kept, and the old settings are backed up first.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
source lib/common.sh

[[ $EUID -eq 0 ]] || die "run with sudo"
CHECK_ONLY=0
case ${1:-} in --check) CHECK_ONLY=1 ;; "") ;; *) die "usage: $0 [--check]" ;; esac
command -v systemctl >/dev/null || die "systemd is required"
load_config

CFG_DIR=/etc/rancher/k3s
CFG=$CFG_DIR/config.yaml
K3S_BIN=/usr/local/bin/k3s
NET_KEYS='cluster-cidr|service-cidr|cluster-dns'
export KUBECONFIG=$CFG_DIR/k3s.yaml

installed() { [[ -x $K3S_BIN ]] && systemctl cat k3s >/dev/null 2>&1; }

# ---- 1. never clash with the VM's own networks ---------------------------------
# A host address or route inside a cluster range (or a host subnet that contains
# one) would cut the server or its devices off. k3s's own interfaces don't count.
check_host_networks() {
  local bad=0 dev cidr dst range
  while read -r dev cidr; do
    [[ $dev =~ ^(lo|cni0|flannel|veth|kube) ]] && continue
    for range in "$POD_CIDR" "$SERVICE_CIDR"; do
      if in_cidr "${cidr%/*}" "$range" || in_cidr "${range%/*}" "$cidr"; then
        err "the server's interface $dev ($cidr) overlaps $range"; bad=1
      fi
    done
  done < <(ip -4 -o addr show | awk '{print $2, $4}')
  while read -r dst dev; do
    [[ $dst == default || $dst != */* || $dev =~ ^(cni0|flannel|veth|kube) ]] && continue
    for range in "$POD_CIDR" "$SERVICE_CIDR"; do
      if in_cidr "${dst%/*}" "$range" || in_cidr "${range%/*}" "$dst"; then
        err "the server has a route to $dst (via $dev) that overlaps $range"; bad=1
      fi
    done
  done < <(ip -4 route show | awk '{d=""; for (i=1;i<=NF;i++) if ($i=="dev") d=$(i+1); print $1, d}')
  (( bad == 0 )) || die "pick other ranges in config.env (POD_CIDR / SERVICE_CIDR) - these would break the server's networking"
  ok "no overlap with the server's own networks ($(hostname -I | awk '{print $1}'))"
}

# ---- 2. what k3s runs with now ---------------------------------------------------
read_cluster() {  # sets CUR_POD CUR_SVC CUR_DNS (empty if unknown)
  CUR_POD=$(kubectl get nodes -o jsonpath='{.items[0].spec.podCIDR}' 2>/dev/null || true)
  CUR_SVC=$(kubectl -n default get svc kubernetes -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
  CUR_DNS=$(kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
}
matches() {
  [[ -n $CUR_POD && -n $CUR_SVC ]] && in_cidr "${CUR_POD%/*}" "$POD_CIDR" \
    && in_cidr "$CUR_SVC" "$SERVICE_CIDR" && [[ -z $CUR_DNS || $CUR_DNS == "$CLUSTER_DNS" ]]
}
show_ranges() {
  printf '  %-9s %-22s %s\n' "" "now" "wanted" \
    "pods" "${CUR_POD:-?}" "$POD_CIDR" \
    "services" "${CUR_SVC:+${CUR_SVC%.*}.x}" "$SERVICE_CIDR" \
    "DNS" "${CUR_DNS:-?}" "$CLUSTER_DNS"
}

# k3s server arguments from the systemd unit, minus the three network flags
current_args() {
  local argv skip=0 out=() a
  argv=$(systemctl show k3s -p ExecStart --value | grep -o 'argv\[\]=[^;]*' | head -1 | sed 's/^argv\[\]=//')
  read -r -a argv <<<"$argv"
  for a in "${argv[@]:1}"; do                       # drop the binary path
    if (( skip )); then skip=0; continue; fi
    [[ $a == server ]] && continue
    [[ $a =~ ^--($NET_KEYS)=  ]] && continue
    [[ $a =~ ^--($NET_KEYS)$  ]] && { skip=1; continue; }
    out+=("$a")
  done
  echo "${out[*]}"
}

# config.yaml with the three network keys set and everything else kept
write_config() {  # <current file or ""> <output>
  local src=$1
  if [[ -n $src && -f $src ]] && grep -qE "^[[:space:]]*['\"]?($NET_KEYS)['\"]?[[:space:]]*:[[:space:]]*$" "$src"; then
    die "$src lists a network setting over several lines - set it by hand to: $POD_CIDR / $SERVICE_CIDR / $CLUSTER_DNS"
  fi
  { if [[ -n $src && -f $src ]]; then grep -vE "^[[:space:]]*['\"]?($NET_KEYS)['\"]?[[:space:]]*:" "$src" || true; fi
    printf 'cluster-cidr: "%s"\nservice-cidr: "%s"\ncluster-dns: "%s"\n' "$POD_CIDR" "$SERVICE_CIDR" "$CLUSTER_DNS"
  } >"$2"
}

check_dropins() {
  local f
  f=$(grep -lE "^[[:space:]]*['\"]?($NET_KEYS)['\"]?[[:space:]]*:" "$CFG_DIR"/config.yaml.d/*.yaml 2>/dev/null || true)
  [[ -z $f ]] || die "network settings are also in $f - remove them there first (k3s reads both files)"
}

wait_ready() {
  local t=0
  until kubectl get nodes 2>/dev/null | grep -q ' Ready' && [[ -n $(kubectl get nodes -o jsonpath='{.items[0].spec.podCIDR}' 2>/dev/null) ]] \
        && kubectl -n kube-system get svc kube-dns >/dev/null 2>&1; do
    (( t >= 300 )) && die "k3s didn't come up within 5 minutes - see: journalctl -u k3s -n 100"
    sleep 5; t=$((t + 5))
  done
}

verify() {
  wait_ready; read_cluster; show_ranges
  matches || die "k3s is running, but not with the wanted networks - see: journalctl -u k3s -n 100"
  ok "k3s $("$K3S_BIN" --version | awk 'NR==1{print $3}') is running with the wanted networks"
  cat <<EOF

Next:
  - if you use kubectl as your own user, copy the new kubeconfig:
      mkdir -p ~/.kube && sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config && sudo chown \$USER ~/.kube/config
  - install the stack:  sudo ./bootstrap.sh
EOF
}

# ---- 3a. fresh install -------------------------------------------------------------
install_fresh() {
  [[ -n ${K3S_VERSION:-} ]] || die "set K3S_VERSION in config.env"
  cat <<EOF

k3s isn't installed. Plan:
  - write $CFG with pods $POD_CIDR, services $SERVICE_CIDR, DNS $CLUSTER_DNS
    (any other settings already in that file are kept)
  - install k3s $K3S_VERSION with the official installer (get.k3s.io)
EOF
  read -r -p "Install? [y/N]: " a </dev/tty || a=""
  [[ ${a,,} == y* ]] || die "nothing changed"
  mkdir -p "$CFG_DIR"
  write_config "$CFG" "$CFG.new" && mv "$CFG.new" "$CFG"
  log "Installing k3s $K3S_VERSION"
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh - >/dev/null
  verify
}

# ---- 3b. recreate the cluster with the right networks -------------------------------
recreate() {
  local host ver args ns bk a
  [[ $(kubectl get nodes --no-headers 2>/dev/null | wc -l) -le 1 ]] \
    || die "this cluster has more than one node - change its networks with your cluster procedure, not this script"
  [[ -x /usr/local/bin/k3s-uninstall.sh ]] || die "k3s wasn't installed with the official installer (no k3s-uninstall.sh) - not changing it"
  check_dropins
  host=$(hostname); ver=$("$K3S_BIN" --version | awk 'NR==1{print $3}'); args=$(current_args)
  ns=$(kubectl get ns --no-headers 2>/dev/null | awk '$1 !~ /^(default|kube-system|kube-public|kube-node-lease)$/ {printf "%s ", $1}')
  bk=/root/k3s-backup-$(date +%Y%m%d-%H%M%S)
  cat <<EOF

k3s runs with other networks than wanted, and they can't be changed in place:
the cluster has to be recreated. Plan:
  1. back up k3s's settings, unit file and program to $bk
  2. uninstall k3s (official k3s-uninstall.sh) - this DELETES THE CLUSTER:
       namespaces: ${ns:-(none besides the system ones)}
       and their volumes (/var/lib/rancher/k3s/storage)
  3. reinstall the same k3s ($ver) from the saved program, with the same
     settings and arguments${args:+ ($args)}, only the three networks changed

Not touched: this VM and its OS, IP and network settings, SSH, users, files
outside k3s, and other services.
EOF
  read -r -p "Type this server's name ($host) to go ahead: " a </dev/tty || a=""
  [[ $a == "$host" ]] || die "nothing changed"

  mkdir -p "$bk"; chmod 700 "$bk"
  cp -a "$CFG_DIR" "$bk/etc-rancher-k3s"
  systemctl cat k3s >"$bk/k3s.service"
  [[ -f /etc/systemd/system/k3s.service.env ]] && cp -a /etc/systemd/system/k3s.service.env "$bk/"
  [[ -d /var/lib/rancher/k3s/server/manifests ]] && cp -a /var/lib/rancher/k3s/server/manifests "$bk/manifests"
  cp -a "$K3S_BIN" "$bk/k3s"
  log "Fetching the k3s installer before removing anything"
  curl -sfL https://get.k3s.io -o "$bk/install.sh" || die "can't download https://get.k3s.io - nothing changed"
  write_config "$CFG" "$bk/config.yaml.new"
  ok "backup in $bk"

  log "Uninstalling k3s"
  /usr/local/bin/k3s-uninstall.sh >"$bk/uninstall.log" 2>&1 || warn "uninstall reported errors - see $bk/uninstall.log"

  log "Reinstalling k3s $ver"
  mkdir -p "$CFG_DIR"
  cp -a "$bk/etc-rancher-k3s/." "$CFG_DIR/"
  rm -f "$CFG_DIR/k3s.yaml"                         # old cluster's kubeconfig
  cp "$bk/config.yaml.new" "$CFG"
  install -m 0755 "$bk/k3s" "$K3S_BIN"
  INSTALL_K3S_SKIP_DOWNLOAD=true INSTALL_K3S_SKIP_START=true INSTALL_K3S_VERSION="$ver" \
    INSTALL_K3S_EXEC="server${args:+ $args}" sh "$bk/install.sh" >"$bk/install.log" 2>&1 \
    || die "reinstall failed - see $bk/install.log (settings and program are in $bk)"
  [[ -f $bk/k3s.service.env ]] && cp -a "$bk/k3s.service.env" /etc/systemd/system/k3s.service.env
  systemctl daemon-reload; systemctl start k3s
  [[ -d $bk/manifests ]] && echo "  (auto-deploy manifests from before are in $bk/manifests - not restored)"
  verify
}

# ---- main ----------------------------------------------------------------------------------
log "k3s networks: pods $POD_CIDR, services $SERVICE_CIDR, DNS $CLUSTER_DNS"
in_cidr "$CLUSTER_DNS" "$SERVICE_CIDR" || die "CLUSTER_DNS ($CLUSTER_DNS) must be inside SERVICE_CIDR ($SERVICE_CIDR)"
check_host_networks
if ! installed; then
  systemctl cat k3s-agent >/dev/null 2>&1 && die "this server is a k3s agent - run this on the server node"
  (( CHECK_ONLY )) && { warn "k3s isn't installed"; exit 1; }
  install_fresh; exit 0
fi
systemctl is-active --quiet k3s || die "k3s is installed but not running - start it (sudo systemctl start k3s) and re-run"
wait_ready; read_cluster
if matches; then
  show_ranges; ok "k3s already uses the wanted networks - nothing to do"; exit 0
fi
show_ranges
(( CHECK_ONLY )) && { warn "k3s needs to be recreated to use these networks (run without --check)"; exit 1; }
recreate
