# playbooks

The AWX project. AWX pulls this repo on every job launch, so a commit is live for the next job.
The job templates that use these playbooks are defined in `infra/stack` →
`config/settings.yml`.

| Path | Job template(s) |
|---|---|
| `readonly/` | Read-only reports: device list, reachability, drift, versions, neighbors, config backup, show commands |
| `netbox_discover.yml` | NetBox - Discover devices (fills in devices tagged `discover`) |
| `solarwinds/` | SolarWinds - Reconciliation report / Import inventory (`mapping.yml` = rules) |
| `netbox_load_devices.yml` + `data/netbox_devices.yml` | NetBox - Load devices |
| `data/software_baseline.yml` | Minimum OS versions for the version report |
| `inventory/netbox.yml` | The AWX "NetBox" inventory (devices, grouped by site, role, platform, tag) |
| `hello.yml` | Smoke test |
