# PoC stack: NetBox + AWX on k3s, managed from Git

A network-automation platform on a single Ubuntu 26.04 node running k3s. **Everything is
defined in Git**: the bootstrap installs only Gitea and Argo CD, pushes the stack definitions
into Gitea, and Argo CD deploys and maintains the rest, including Gitea and itself.

```
                 ┌──────────── Gitea ────────────┐
   commit / PR ─►│ infra/stack      infra/playbooks │◄── AWX pulls playbooks
                 └──────┬───────────────────────┘
                        │ Argo CD syncs (and reverts manual changes)
        ┌───────────────┼──────────────────────────────────────────────┐
        ▼               ▼               ▼               ▼              ▼
 External Secrets   PostgreSQL +     NetBox          AWX + job pods   configure job
 (one secret store, Valkey          (source of      (ansible-workers) (AWX/NetBox/Gitea
  Delinea-ready)                     truth)                            settings from Git)
```

| URL (node IP + port, no DNS) | |
|---|---|
| NetBox `http://<NODE_IP>:30080` | AWX `http://<NODE_IP>:30081` |
| Gitea `http://<NODE_IP>:30082` | Argo CD `http://<NODE_IP>:30083` |

One login for all four: the admin account you choose during setup (default user `pocadmin`).
Nothing in any app is visible without logging in.

## Quick start

```bash
git clone <this repo> poc-stack && cd poc-stack
sudo ./bootstrap.sh               # asks a few questions, then ~25 min on first run
```

The first run walks you through setup step by step (Enter accepts the default):

1. **Platform:** node IP (auto-detected), admin username, email and password.
   Press Enter at the password to have a strong one generated.
2. **Device logins** (optional): read-only (discovery and reports) and change (future write jobs).
3. **SolarWinds** (optional): SWIS URL, read-only account, verify TLS or not.

Answers go to `config.local.env` (node IP, admin user/email) and `.secrets.env` (passwords).
Both are git-ignored and readable only by root. Anything you skip can be added later with
`sudo ./bootstrap.sh setup`. Run it unattended (no terminal) and it generates the admin
password and skips the optional logins. `sudo ./bootstrap.sh info` shows the URLs and login.

`config.env` (ports, sizes, versions) is optional to edit and contains no passwords.

Requirements: k3s with the `local-path` storage class, 8 vCPU / 16+ GB RAM, NodePorts
30080-30084 and 30022 free, outbound internet (images, charts, Ansible Galaxy, PyPI).

## How it's organised

| Layer | Lives in | Deployed by |
|---|---|---|
| Gitea, Argo CD | `stack/gitea`, `stack/argocd` | bootstrap once, then Argo CD (self-managed, never pruned) |
| Secret store + which secret each app gets | `stack/secrets` | Argo CD (External Secrets Operator) |
| PostgreSQL, Valkey, databases | `stack/data` | Argo CD |
| NetBox, AWX operator, AWX | `stack/netbox`, `stack/awx-operator`, `stack/awx` | Argo CD |
| Settings inside AWX, NetBox, Gitea | `stack/config/settings.yml` | Argo CD runs the configure job after every change |
| Device types (community library) | `stack/device-types/vendors.env` | Argo CD runs the import job after every change |
| Playbooks | `playbooks/` → Gitea `infra/playbooks` | AWX pulls on every job launch |

**Change anything by committing to Gitea** (`infra/stack` or `infra/playbooks`); Argo CD
applies it within ~3 minutes and reverts changes made by hand. This checkout is only the
bootstrap and disaster-recovery copy.

**Secrets never go into Git.** They live in one store (`secret-store/poc-secrets`, with a
local copy in `.secrets.env`); the stack references them by name through External Secrets.
To move to Delinea, change the store definition in `stack/secrets/store.yaml`. Nothing else
changes. API tokens the platform issues (NetBox, AWX, Gitea) are written back to the store.

## What's in AWX

**Read-only jobs** (read-only device account; they never change a device):

| Job | What you get |
|---|---|
| Inventory - Device list | Every NetBox device: site, role, model, OS, management IP |
| Inventory - Reachability check | Which devices answer on SSH and accept the read-only login |
| Compliance - NetBox drift report | Devices whose serial / OS / model differ from NetBox |
| Software - Version report | OS version per device vs. `data/software_baseline.yml` |
| Topology - Neighbors | LLDP/CDP neighbors |
| Config - Backup to Git | Running configs committed to Gitea `infra/config-backups` (nightly) |
| Show command runner | One approved show command, picked from a list |
| SolarWinds - Reconciliation report | What a SolarWinds import would change; writes nothing |

**Inventory into NetBox:**
- **Add devices for discovery** (NetBox → Customization → Scripts): hostname, IP, platform,
  or a pasted list. NetBox then launches **NetBox - Discover devices**, which logs in and
  fills in the empty fields (model by part number from the device-type library, serial, OS,
  interfaces, IPs). It never overwrites what you entered. A model that isn't in NetBox is
  reported in the device's journal: add its vendor to `stack/device-types/vendors.env`, then
  add the `discover` tag again.
- **SolarWinds - Sync** (workflow, nightly): **SolarWinds - Import inventory**, then discovery.
- **NetBox - Load devices**: devices defined in `data/netbox_devices.yml`.

## SolarWinds import

This uses the common single-source-of-truth sync pattern: **extract → normalize → reconcile**,
with NetBox staying authoritative.

1. **Extract:** reads `Orion.Nodes` through the SWIS REST API
   (`https://<server>:17774/SolarWinds/InformationService/v3/Json/Query`, SWQL, paged,
   read-only account). The scope is whatever that account can see.
2. **Normalize** with `playbooks/solarwinds/mapping.yml`:
   - Hostnames are lowercased and their domain is stripped.
   - Vendor maps to manufacturer, and vendor + model/OS map to platform.
   - SolarWinds Location maps to site, and hostname patterns map to role.
   - Servers, VMs and other non-network nodes are skipped, and the report gives the reason.
3. **Reconcile:** matches on the stored SolarWinds node ID, then on name, then on IP.
   - New devices are created and tagged `discover`, so discovery fills them in.
   - Existing devices only get empty fields filled.
   - Devices that disappear from SolarWinds are tagged `not-in-solarwinds`. **Nothing is ever deleted.**

Run **SolarWinds - Reconciliation report** first; it shows exactly what an import would do.
The query and every rule are in `mapping.yml`, so adapting to your SolarWinds schema is a
commit, not a code change.

## Commands

```bash
sudo ./bootstrap.sh                       # install / re-run (safe)
sudo ./bootstrap.sh setup                 # change device / SolarWinds logins step by step
sudo ./bootstrap.sh secret <name> <value> [...] # set values in the secret store + re-apply settings
sudo ./bootstrap.sh status                # Argo CD apps + pods
sudo ./bootstrap.sh info                  # URLs and logins
sudo ./bootstrap.sh recover               # break-glass: reinstall Gitea + Argo CD from this checkout
sudo ./destroy.sh [--purge]               # wipe everything (ALL DATA)
```

## Troubleshooting

| Symptom | Look at |
|---|---|
| An app isn't Synced/Healthy | Argo CD UI → the app → events |
| Settings not applied | `kubectl -n poc-config logs job/configure` (or the config app in Argo CD) |
| Device types missing | `kubectl -n netbox logs job/device-type-import` |
| A bad commit broke Gitea or Argo CD | `sudo ./bootstrap.sh recover`, then revert the commit |
| Discovery failed for a device | The device's journal in NetBox says why; add the `discover` tag to retry |
| SolarWinds import fails to connect | `curl -k -u user:pass "https://<server>:17774/SolarWinds/InformationService/v3/Json/Query?query=SELECT+TOP+1+NodeID+FROM+Orion.Nodes"` from the server |

## PoC caveats
- Plain HTTP and a single replica of everything, with node-local storage.
- Databases and Gitea data are not backed up yet. Git rebuilds the stack, but not NetBox's data.
- AWX 24.6.1 / operator 2.19.1 is the latest upstream AWX release.
