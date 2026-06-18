# Inventories

This directory is the central inventory location for all environments.

- Each environment has its own folder (e.g., `dev`, `testing`, `prod`).
- Terraform writes `inventory.ini` into the matching environment folder.
- The tracked inventory model comes from the committed 9-host `dev` scaffold in `terraform-proxmox/environments/dev.tfvars`; downstream environments should mirror that service layout and only change env-specific values.
- Ansible runs should point at:
  - `inventories/<env>/inventory.ini`
  - `inventories/aliases.ini` (group aliases used by app-specific playbooks)
- `inventories/aliases.ini` also contains helper hosts/groups (for example `ansible-control-node` in `ntp_servers`).
  It also contains cross-environment service aliases (for example `zimbra_servers` -> `zimbra`).
  `ntp_clients` is the repo-wide Chrony target group; when FreeIPA is part of an environment, keep it aligned with service aliases that need Kerberos-safe time sync, including `freeipa_servers`, `keycloak_servers`, and `observability_servers`.
  Playbooks that should only touch Terraform-managed VMs should target `all_nodes` (or use `--limit all_nodes`).

Example:

```text
ansible-inventory -i inventories/dev/inventory.ini -i inventories/aliases.ini --graph

For example: 
$ ansible-inventory -i ../inventories/dev/inventory.ini -i ../inventories/aliases.ini --graph
@all:
  |--@ungrouped:
  |--@all_nodes:
  |  |--public-database19c-01
  |  |--public-database21c-02
  |  |--public-freeipa-01
  |  |--public-keycloak-01
  |  |--public-observability-01
  |  |--public-weblogic12c-01
  |  |--public-weblogic14c-01
  |  |--public-zabbix-01
  |  |--public-zimbra-01
  |--@freeipa:
  |  |--public-freeipa-01
  |--@keycloak:
  |  |--public-keycloak-01
  |--@observability:
  |  |--public-observability-01
  |--@ntp_servers:
  |  |--ansible-control-node
  |--@ntp_clients:
  |  |--@freeipa_servers:
  |  |  |--@freeipa:
  |  |  |  |--public-freeipa-01
  |  |--@keycloak_servers:
  |  |  |--@keycloak:
  |  |  |  |--public-keycloak-01
  |  |--@observability_servers:
  |  |  |--@observability:
  |  |  |  |--public-observability-01
  |  |--@oracle_servers:
  |  |  |--@database19c:
  |  |  |  |--public-database19c-01
  |  |  |--@database21c:
  |  |  |  |--public-database21c-02
  |  |--@weblogic_servers:
  |  |  |--@weblogic12c:
  |  |  |  |--public-weblogic12c-01
  |  |  |--@weblogic14c:
  |  |  |  |--public-weblogic14c-01
  |  |--@zabbix_servers:
  |  |  |--@zabbix:
  |  |  |  |--public-zabbix-01
  |  |--@zimbra_servers:
  |  |  |--@zimbra:
  |  |  |  |--public-zimbra-01

```
