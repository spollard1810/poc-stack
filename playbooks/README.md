# playbooks

Seeded by the PoC bootstrap. AWX syncs this repo as the **playbooks** project.

| File | Purpose |
|---|---|
| `inventory/netbox.yml` | Dynamic inventory from NetBox (used by the AWX "NetBox" inventory) |
| `collections/requirements.yml` | Collections AWX installs on project sync |
| `hello.yml` | Smoke test, runs on localhost in a job pod |
| `netbox_report.yml` | Prints NetBox data for every device in the inventory |

Add playbooks here, push, and AWX picks them up on the next project sync
(the project is set to update on launch).
