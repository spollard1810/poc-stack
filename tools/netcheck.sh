#!/usr/bin/env bash
# Read-only: show every place a network / CIDR can be defined on a k3s node.
#   sudo ./tools/netcheck.sh                  # full report
#   sudo ./tools/netcheck.sh 192.168.254.     # also search everything for this string
SEARCH=${1:-}
[[ -z ${KUBECONFIG:-} && ! -f $HOME/.kube/config ]] && export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
h() { printf '\n\e[1;34m=== %s ===\e[0m\n' "$*"; }

h "k3s config file(s)  (cluster-cidr / service-cidr / flannel / disable ...)"
cat /etc/rancher/k3s/config.yaml /etc/rancher/k3s/config.yaml.d/*.yaml 2>/dev/null || echo "(none - k3s defaults)"

h "k3s systemd unit flags + env"
systemctl cat k3s 2>/dev/null | sed -n '/^ExecStart=/,/^$/p' || echo "(no k3s unit)"
cat /etc/systemd/system/k3s.service.env 2>/dev/null

h "k3s args recorded on each node"
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.metadata.annotations.k3s\.io/node-args}{"\n"}{end}'

h "Nodes, IPs and pod CIDR  (k3s default pod CIDR: 10.42.0.0/16)"
kubectl get nodes -o custom-columns='NAME:.metadata.name,INTERNAL-IP:.status.addresses[?(@.type=="InternalIP")].address,POD-CIDRS:.spec.podCIDRs'

h "Service CIDR  (k3s default: 10.43.0.0/16)"
kubectl get servicecidrs 2>/dev/null \
  || echo "kubernetes svc IP: $(kubectl get svc kubernetes -n default -o jsonpath='{.spec.clusterIP}')"

h "Flannel subnet (this node)"
cat /run/flannel/subnet.env 2>/dev/null || echo "(not readable / not flannel)"

h "Network-related CRDs  (MetalLB, Multus, Calico, Cilium, kube-vip ...)"
kubectl get crd -o name | grep -iE 'ippool|ipaddresspool|network|l2adv|bgp|cilium|calico|kube-vip'   | grep -v 'gateway.networking.k8s.io' || echo "(none besides k3s built-ins)"
kubectl get ipaddresspools.metallb.io -A 2>/dev/null
kubectl get network-attachment-definitions -A 2>/dev/null

h "NetworkPolicies"
np=$(kubectl get networkpolicy -A 2>/dev/null); echo "${np:-(none)}"

h "Services exposed outside the cluster (NodePort / LoadBalancer)"
kubectl get svc -A | awk 'NR==1 || /NodePort|LoadBalancer/'

h "k3s auto-deploy manifests  (anything here is applied automatically)"
ls -la /var/lib/rancher/k3s/server/manifests/ 2>/dev/null

h "Host interfaces and routes"
if command -v ip >/dev/null; then ip -br addr; echo; ip route; else echo "(ip command not found)"; fi

h "Netplan (host network config)"
for f in /etc/netplan/*.yaml; do [[ -f $f ]] && { echo "--- $f"; cat "$f"; }; done

h "Docker / Podman networks (if installed)"
command -v docker >/dev/null && docker network ls || echo "(no docker)"

if [[ -n $SEARCH ]]; then
  h "Files containing '$SEARCH'"
  grep -rnF "$SEARCH" /etc/rancher /etc/netplan /etc/systemd/system /etc/cni \
    /var/lib/rancher/k3s/server/manifests /var/lib/rancher/k3s/agent/etc "$HOME" 2>/dev/null \
    | grep -v '/\.git/' || echo "(no files)"

  h "Kubernetes objects containing '$SEARCH'  (all namespaced + cluster resources, secrets excluded)"
  res=$(kubectl api-resources --verbs=list -o name | grep -vE '^(secrets|events|events\.events\.k8s\.io)$' | paste -sd, -)
  kubectl get "$res" -A -o json 2>/dev/null \
    | jq -r --arg s "$SEARCH" '.items[] | select(tostring | contains($s))
        | "\(.kind)\t\(.metadata.namespace // "-")/\(.metadata.name)"' \
    || echo "(needs jq)"
fi
