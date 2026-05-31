# Bootstrap Playbooks

Service bootstrap playbooks are grouped here to keep app/db automation modular and scalable.

## Current Services

- `oracle819c/`: Oracle 19c provisioning/configuration
- `oracle821c/`: Oracle 21c provisioning/configuration
- `oracle_weblogic12c/`: WebLogic 12c provisioning/configuration
- `oracle_weblogic14c/`: WebLogic 14c provisioning/configuration
- `zabbix_server/`: Zabbix 7.0 server provisioning/configuration

## Entry Points

- `bootstrap_playbooks/oracle819c/main.yml`
- `bootstrap_playbooks/oracle821c/main.yml`
- `bootstrap_playbooks/oracle_weblogic12c/main.yml`
- `bootstrap_playbooks/oracle_weblogic14c/main.yml`
- `bootstrap_playbooks/zabbix_server/main.yml`

## Inventory Convention

From inside `bootstrap_playbooks/*`, `ansible.cfg` points to:

- `../../inventories/dev/inventory.ini`
- `../../inventories/aliases.ini`

Run from repo root when possible and pass explicit `-i` for non-dev environments.
