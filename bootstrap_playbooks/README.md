# Bootstrap Playbooks

Service bootstrap playbooks are grouped here to keep app/db automation modular and scalable.

## Current Services

- `oracle819c/`: Oracle 19c provisioning/configuration on Oracle Linux 8
- `oracle919c/`: Oracle 19c provisioning/configuration on Oracle Linux 9, including the supported RU path and a throwaway unpatched POC mode
- `oracle821c/`: Oracle 21c provisioning/configuration
- `oracle_weblogic12c/`: WebLogic 12c provisioning/configuration
- `oracle_weblogic14c/`: WebLogic 14c provisioning/configuration
- `zabbix_server/`: Zabbix 7.0 server provisioning/configuration
- `zimbra/`: Zimbra FOSS 10.x provisioning/configuration on Oracle Linux 9
- `freeipa/`: FreeIPA identity platform provisioning/configuration on Oracle Linux 9
- `keycloak/`: Keycloak SSO/OIDC provisioning/configuration on Ubuntu 24.04
- `observability/`: Unified observability stack provisioning/configuration on Ubuntu 24.04

## Entry Points

- `bootstrap_playbooks/oracle819c/main.yml`
- `bootstrap_playbooks/oracle919c/main.yml`
- `bootstrap_playbooks/oracle821c/main.yml`
- `bootstrap_playbooks/oracle_weblogic12c/main.yml`
- `bootstrap_playbooks/oracle_weblogic14c/main.yml`
- `bootstrap_playbooks/zabbix_server/main.yml`
- `bootstrap_playbooks/zimbra/main.yml`
- `bootstrap_playbooks/freeipa/main.yml`
- `bootstrap_playbooks/keycloak/main.yml`
- `bootstrap_playbooks/observability/main.yml`

## Inventory Convention

From inside `bootstrap_playbooks/*`, `ansible.cfg` points to:

- `../../inventories/example/inventory.ini`
- `../../inventories/aliases.ini`

Run from repo root when possible and pass explicit `-i` for non-dev environments.

The committed inventory shape is the 9-node `dev` scaffold from `terraform-proxmox/environments/dev.tfvars`. Treat that layout as the source model for growing bootstrap coverage in other environments.

## Cross-Playbook Notes

- Typical repo execution order is:
  - `user-man/main.yml`
  - `time_sync/main.yml`
  - database/bootstrap services
  - dependent middleware/services
- Oracle DB playbooks should converge before the matching WebLogic playbooks.
- Run `time_sync/main.yml` before `bootstrap_playbooks/freeipa/main.yml` and before Kerberos-joined service playbooks such as Keycloak or observability. The repo expects `inventories/aliases.ini` to keep `ntp_clients` aligned with those service groups.
- `bootstrap_playbooks/freeipa/main.yml` supports two DNS modes:
  - Integrated DNS: `FREEIPA_SETUP_DNS=true`
  - External DNS: `FREEIPA_SETUP_DNS=false`
- External DNS mode does not retrofit records into an outside authority. Publish the required A, SRV, URI, and `ipa-ca` records in your zone before expecting FreeIPA verification to pass.
- If Pi-hole/dnsmasq is authoritative for the zone, manage those records as static dnsmasq entries. Pi-hole does not support `nsupdate`, so FreeIPA cannot push zone changes into it during playbook runs.
