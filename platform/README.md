# platform

The PoC platform, managed by Argo CD. **This repo is the source of truth**: change the
platform by committing here (ideally through a pull request). Argo CD syncs every change
within about 3 minutes and reverts changes made by hand in the cluster.

| Path | What it is |
|---|---|
| `root.yaml` | The root Application ("app of apps"); applied once by bootstrap |
| `apps/` | One Argo CD Application per component |
| `netbox/values.yaml` | NetBox Helm values |
| `awx-operator/` | AWX operator (kustomize) |
| `awx/awx.yaml` | The AWX instance |

**Common changes**

- Upgrade NetBox: change `targetRevision` in `apps/netbox.yaml`.
- Change NetBox settings: edit `netbox/values.yaml`.
- Resize AWX: edit the resource requirements in `awx/awx.yaml`.

**Not in this repo, on purpose**

- **Secrets.** Values reference Kubernetes secrets by name (for example
  `netbox-db-secret`). The bootstrap creates them today; External Secrets from Delinea
  will later.
- **The foundation:** PostgreSQL, Valkey, Gitea and Argo CD itself. Argo CD pulls this
  repo from Gitea, so Gitea can't depend on Argo CD. Those are managed by `bootstrap.sh`.
- **App settings inside AWX / NetBox / Gitea** (organizations, credentials, job
  templates, tags…). Today the bootstrap's seed step applies them; moving them here
  as config-as-code is phase 2.

Argo CD UI: http://${NODE_IP}:${ARGOCD_PORT} (same login as the other apps).
