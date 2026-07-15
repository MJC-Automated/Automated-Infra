# Inventories

This directory is the central inventory location for all environments.

- Each environment has its own folder (e.g., `dev`, `testing`, `prod`).
- Terraform writes `inventory.ini` into the matching environment folder.
- The desired tracked model comes from the committed 18-host `dev` scaffold in `terraform-proxmox/environments/dev.tfvars`; downstream environments should start from that service layout and change environment-specific values.
- `inventory.ini` is generated output and may lag its tfvars source until a reviewed Terraform apply. Compare the inventory graph with `node_groups` before configuration runs.
- Ansible runs should point at:
  - `inventories/<env>/inventory.ini`
  - `inventories/aliases.ini` (group aliases used by app-specific playbooks)
- `inventories/aliases.ini` also contains helper hosts/groups (for example `ansible-control-node` in `ntp_servers`).
  It also contains cross-environment service aliases (for example `zimbra_servers` -> `zimbra`).
  `ntp_clients` is the repo-wide Chrony target group; when FreeIPA is part of an environment, keep it aligned with service aliases that need Kerberos-safe time sync, including `freeipa_servers`, `keycloak_servers`, and `observability_servers`.
  Playbooks that should only touch Terraform-managed VMs should target `all_nodes` (or use `--limit all_nodes`).

Validate the current generated graph from the repository root:

```text
ansible-inventory -i inventories/example/inventory.ini -i inventories/aliases.ini --graph
```
