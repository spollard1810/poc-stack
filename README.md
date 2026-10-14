# PoC stack: NetBox + AWX + Gitea on k3s

One idempotent bootstrap script that stands up a pre-wired network-automation PoC
on a single Ubuntu 26.04 node that already runs k3s. NetBox and AWX are then managed
the GitOps way: by **Argo CD** from the Gitea repo **`infra/platform`** (see [GitOps](#gitops)).

```
            http://<NODE_IP>:30080  :30081  :30082 (+ ssh :30022)
                        │          │        │
        ┌───────────────┘          │        └──────────────┐
     NetBox  ◄──inventory──────── AWX ───project sync──►  Gitea
   (web+worker)            (web, task, operator)     (repos + registry)
        │                          │ launches               │
        │                  ansible-worker pods              │
        │                (container group, 1 pod/job)       │
        └────────────┬─────────────┴──────────┬─────────────┘
               PostgreSQL 16              Valkey 8
           (netbox, awx, gitea DBs)   (NetBox + Gitea cache/queues)
              namespace: data - cluster-internal only, no external port
```

| Component | Version | Namespace | How it's installed |
|---|---|---|---|
| PostgreSQL | 16 | `data` | plain StatefulSet (`manifests/data/postgres.yaml`) |
| Valkey (Redis-compatible) | 8.1 | `data` | plain StatefulSet (`manifests/data/valkey.yaml`) |
| Gitea | 1.27.0 (chart 12.7.0) | `gitea` | Helm |
| Argo CD | 3.5.3 (chart 10.9.4) | `argocd` | Helm |
| NetBox | 4.7.2 (chart 8.3.91) | `netbox` | **Argo CD** (Helm chart + values from `infra/platform`) |
| AWX | 24.6.1 (operator 2.19.1) | `awx` | **Argo CD** (awx-operator + `AWX` resource from `infra/platform`) |
| Ansible workers | awx-ee 24.6.1 | `awx` | AWX container group, one pod per job |

## Requirements

- Ubuntu 26.04 with k3s and the default `local-path` storage class
- NodePorts 30080-30084 and 30022 free on the node (you can change them in `config.env`)
- 8 vCPU / 16+ GB RAM / ~60 GB free disk (tested target: 8 vCPU / 32 GB)
- Outbound internet access (container images, Helm charts, Ansible Galaxy)
- `sudo` access (installs `helm`, `jq`, `gettext-base` if missing)

## Quick start

```bash
git clone <your-git-server>/poc-stack.git && cd poc-stack
vi config.env                    # optional: admin password, ports, sizes, NODE_IP
sudo ./bootstrap.sh              # ~15-20 min on first run
```

The script prints the URLs and logins at the end. Run `./bootstrap.sh info` to see them again.
They are also saved to `.generated/ACCESS.txt`.

**Default login for all four apps (NetBox, AWX, Gitea, Argo CD):** `pocadmin` / `ChangeMe-PoC-2026`. Change this in `config.env` before the first run.

### Access: node IP + port, no DNS
There is no DNS, no hostnames and no ingress. Each app is a Kubernetes NodePort service
on the machine's IP:

| App | URL |
|---|---|
| NetBox | `http://<NODE_IP>:30080` |
| AWX | `http://<NODE_IP>:30081` |
| Gitea | `http://<NODE_IP>:30082` (git over ssh: `ssh://git@<NODE_IP>:30022/...`) |
| Argo CD | `http://<NODE_IP>:30083` |

**Everything requires a login.** NetBox and Gitea show nothing to anonymous visitors (no
pages, no API, no repo or user lists); Gitea's only open endpoint is its health check.

PostgreSQL and Valkey have **no external port**. Only pods inside the cluster can reach them.
AWX reaches Gitea and NetBox over internal cluster addresses. For a database shell, run
`kubectl -n data exec -it postgres-0 -- psql -U postgres`.

## What comes pre-configured

**Gitea**
- Admin user `pocadmin`, open registration turned off, clone URLs use `http://<NODE_IP>:30082`
- Org `infra` with a private repo `infra/playbooks`, seeded from `seed/playbooks/`
- Built-in container registry turned on (for custom execution environments)
- SSH clone on NodePort `30022`

**NetBox**
- Superuser `pocadmin`
- An API token for AWX, stored in `.secrets.env` as `NETBOX_API_TOKEN`
- **No sites, devices or other data.** You add those yourself.

**AWX**
- Organization **PoC**
- Credentials:
  - **Gitea** (source control)
  - **NetBox** (custom *NetBox API* credential type that injects `NETBOX_API` and `NETBOX_TOKEN`)
  - **Lab devices** (machine credential with username `ansible`; this is a placeholder, so set the real credentials)
- Project **playbooks**, pulled from `infra/playbooks` in Gitea, updates on launch
- Inventory **NetBox**, built dynamically from `inventory/netbox.yml` in the repo with the `netbox.netbox.nb_inventory` plugin. It re-syncs every time a job launches.
- Instance group **ansible-workers**: a container group whose pod spec sets CPU/RAM limits
- Inventories **NetBox** (dynamic), **Local** (localhost) and **Onboarding** (`inventory/onboard.yml`)
- Job templates **Hello World**, **NetBox Device Report**, **NetBox - Load devices** and
  **NetBox - Onboard from devices**, all pinned to `ansible-workers`
- The bootstrap runs **Hello World** once as an end-to-end check

### Ansible workers
AWX on Kubernetes doesn't use long-running worker VMs. Each job runs in its own pod
(`automation-job-*` in the `awx` namespace), created from the execution environment image.
The `ansible-workers` container group sets those pods' resources. To change it, go to AWX → Instance
Groups → ansible-workers → Pod spec override. To watch the workers:
```bash
kubectl -n awx get pods -l app.kubernetes.io/component=ansible-worker -w
```
If you need execution nodes outside the cluster later (for example, close to the devices), AWX
supports adding them through receptor (AWX → Instances → Add).

## Getting devices into NetBox

**1. Import device types** from the community library (do this first). The maintained
fork works with NetBox 4.5+ tokens and runs as a one-off pod (nothing to install):
```bash
TOKEN=$(sudo grep '^NETBOX_API_TOKEN=' .secrets.env | cut -d= -f2-)
sudo kubectl -n netbox run nb-dt-import --rm -i --restart=Never --pod-running-timeout=5m   --image=ghcr.io/marcinpsk/device-type-library-import:latest   --env=NETBOX_URL=http://netbox.netbox.svc.cluster.local --env=NETBOX_TOKEN="$TOKEN"   -- --vendors cisco,arista,juniper
```

**2. Set the real device login** in AWX: Credentials → **Lab devices** (username plus
password or SSH key; privilege escalation method `enable` if your devices need it).

**3. Add devices for discovery** (the main way to add devices). In NetBox go to
Customization → Scripts → **Add devices for discovery** and enter hostname, management IP and
platform, or paste a list:

```
hostname,ip,platform,site
dc1-rtr01,192.168.254.11/24,cisco
dc1-sw01,192.168.254.21/24,arista
```

Platform can be `cisco` (IOS / IOS-XE), `nxos`, `arista` or `juniper`. Site is optional
(default **Unassigned**); so is role.

When the script finishes, NetBox launches **NetBox - Discover devices** in AWX once for the
whole batch. The job logs into each device and **fills in the empty fields**. It never
overwrites what you entered:

| Field | What discovery does |
|---|---|
| Name, site, role, platform, comments | Never touched |
| Device type | Replaced only while it's the **Pending discovery** placeholder, matched on the part number the device reports. The type's interfaces (correct names and types, from the library) are added to the device |
| Serial | Set only if empty |
| Status | `planned` → `active` only |
| OS version, last discovered | Always updated (custom fields, **Discovery** group) |
| Interfaces | Missing ones added (logical ones like VLANs, loopbacks and port-channels too); descriptions only where empty; nothing deleted |
| IP addresses | New ones added; the management IP moves from the placeholder interface to its real one and stays primary; addresses owned by other devices are left alone |

Progress shows as tags on the device: `discover` → `discovering` → `discovered` or
`discovery-failed`. Every run writes a **journal entry** on the device (what was found, or
why it failed). **To re-run discovery for a device, add the `discover` tag back.** A sweep
also runs every 30 minutes.

If the model isn't in NetBox yet, the device stays on **Pending discovery** and the journal
names the part number to import. Import it (step 1), then add the `discover` tag again.

**Other ways to load devices** (example job templates in AWX):

| Job template | Playbook | Use it when |
|---|---|---|
| **NetBox - Load devices** | `netbox_load_devices.yml` | You want devices defined in Git. Edit `data/netbox_devices.yml` in Gitea (sites, roles, platforms, devices, mgmt IP), commit, run. Safe to re-run; never deletes anything. |
| **NetBox - Onboard from devices** | `netbox_onboard_from_devices.yml` | One-off brownfield import from a static list in `inventory/onboard.yml`. |

All of them set the mgmt IP as the device's primary IPv4, which becomes `ansible_host` in the
AWX **NetBox** inventory. Run **NetBox Device Report** to check what AWX sees.

Notes:
- `device_type` in `data/netbox_devices.yml` is the **model name shown in NetBox** (e.g.
  `Catalyst 8300-1N1S-6T`). Discovery matches the SKU the device reports against the
  library's **part number**; override per host with `nb_device_type` if needed.
- The stock AWX job image has no `pynetbox`; `tasks/ensure_pynetbox.yml` installs it into
  the job pod at runtime (needs PyPI access). For production, build a custom execution
  environment from `ee/` instead.
- New examples added to this repo reach your Gitea with `sudo ./bootstrap.sh seed`
  (or `sudo ./tools/sync-playbooks.sh`). Files you edited in Gitea are never overwritten.
- How the trigger works: two NetBox event rules (**Discovery: after Add devices script**,
  **Discovery: device tagged discover**) call AWX through the webhook **AWX - launch
  discovery**. It authenticates as the AWX user `netbox-events`, which can only launch that
  one job template.
- Calls to NetBox's API in the playbooks use `no_log`, so the API token never appears in AWX
  job output.

## GitOps

```
 infra/platform (Gitea) ──► Argo CD ──► NetBox, AWX operator, AWX   (synced, self-healing)
        ▲                      │
   commit / PR                 └─ reverts manual changes in the cluster within ~3 min
```

| Layer | Managed by | What's in it |
|---|---|---|
| Foundation | `bootstrap.sh` | PostgreSQL, Valkey, Gitea, Argo CD. Argo CD pulls from Gitea, so Gitea can't depend on Argo CD |
| Platform | **Argo CD**, from `infra/platform` | NetBox, AWX operator, AWX |
| Secrets | `bootstrap.sh` (later: External Secrets + Delinea) | Kubernetes secrets the platform repo references **by name**. Nothing secret is ever in Git |
| App settings | `bootstrap.sh seed` (phase 2: config as code) | AWX orgs/credentials/templates, NetBox tags/platforms/event rules, Gitea orgs |

**Changing the platform**: edit `infra/platform` in Gitea (for example bump
`targetRevision` in `apps/netbox.yaml`, or change `netbox/values.yaml`), commit, and Argo
CD applies it. Watch it in the Argo CD UI. Don't `helm upgrade` or `kubectl edit` NetBox or
AWX: Argo CD puts it back.

- The bootstrap creates `infra/platform` from `platform/` on first run. Later runs add or
  update files only where they still match what the bootstrap wrote, so commits made in
  Gitea win.
- Argo CD reads the repo as the Gitea user **`argocd`**: restricted, read-only, and only on
  `infra/platform` (through the team `gitops-readers`).
- Argo CD's built-in `admin` is disabled; log in as `pocadmin`.
- Existing installs: the first GitOps run **adopts** the running NetBox and AWX (same names,
  same volumes). No data is moved or deleted.

## Commands

```bash
sudo ./bootstrap.sh            # everything (safe to re-run)
sudo ./bootstrap.sh data       # only Postgres + Valkey
sudo ./bootstrap.sh apps       # Gitea + Argo CD, publish infra/platform, wait for NetBox / AWX
sudo ./bootstrap.sh seed       # only (re-)apply the base configuration
sudo ./bootstrap.sh status     # pods + exposed ports
sudo ./bootstrap.sh info       # URLs + credentials
sudo ./destroy.sh [--purge]    # delete everything INCLUDING DATA
```

Re-running is safe. Secrets are generated once and kept in `.secrets.env`.
Existing objects get updated rather than duplicated. A repo that already has content is never overwritten.

## Repo layout

```
bootstrap.sh              entry point
destroy.sh                teardown
config.env                all tunables (domain, admin user, sizes, pinned versions)
lib/common.sh             helpers (config, secrets, templating, HTTP)
lib/gitops.sh             Argo CD, platform repo, secrets the platform references
seed/seed.sh              base configuration for Gitea / NetBox / AWX (via their APIs)
platform/                 initial content of the infra/platform GitOps repo (Argo CD apps, NetBox values, AWX)
seed/playbooks/           initial content of the infra/playbooks repo
netbox-scripts/           NetBox custom scripts (uploaded by the seed step)
tools/                    netcheck.sh (network overview), sync-repo.sh / sync-playbooks.sh
manifests/                namespaces, Postgres, Valkey
values/                   Helm values templates for the foundation (Gitea, Argo CD)
ee/                       optional custom execution environment definition
.secrets.env              generated - passwords/tokens (git-ignored)
.generated/               generated - rendered values, ACCESS.txt (git-ignored)
```

## Troubleshooting

| Symptom | Check |
|---|---|
| "Cannot reach the cluster" | Run with `sudo`, or copy `/etc/rancher/k3s/k3s.yaml` to `~/.kube/config` |
| AWX never comes up | `kubectl -n awx logs deploy/awx-operator-controller-manager -c awx-manager -f` |
| NetBox pod restarting | `kubectl -n netbox logs deploy/netbox` (first start runs DB migrations, which takes a few minutes) |
| Inventory sync fails | AWX → Jobs → the inventory update's output. Usually Galaxy can't be reached or the token is wrong |
| Page won't load | `sudo ./bootstrap.sh status`. Check the pods are Running and the NodePort shown matches. Also check the host firewall (`sudo ufw status`) |
| Changed the admin password | Edit `config.env`, then `sudo ./bootstrap.sh`. Gitea and AWX pick it up. In NetBox, change it in the UI |

## PoC caveats (not production)
- Plain HTTP and a single replica of everything; storage is node-local (`local-path`). No backups.
- AWX 24.6.1 / operator 2.19.1 is still the **latest upstream release**: the AWX project has paused releases during its refactor.
- Passwords live in `.secrets.env` and `.generated/` on the node, which are git-ignored. Don't commit them.
