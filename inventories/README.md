# Inventories

This directory is the central inventory location for all environments.

- Each environment has its own folder (e.g., `dev`, `testing`, `prod`).
- Terraform writes `inventory.ini` into the matching environment folder.
- Ansible runs should point at:
  - `inventories/<env>/inventory.ini`
  - `inventories/aliases.ini` (group aliases used by app-specific playbooks)

Example:

```
ansible-inventory -i inventories/dev/inventory.ini -i inventories/aliases.ini --graph

For example: 
$ ansible-inventory -i ../inventories/dev/inventory.ini -i ../inventories/aliases.ini --graph
@all:
  |--@ungrouped:
  |--@all_nodes:
  |  |--public-database19c-01
  |  |--public-database21c-01
  |  |--public-jenkins-01
  |  |--public-weblogic12c-01
  |  |--public-weblogic14c-01
  |--@jenkins:
  |  |--public-jenkins-01
  |--@ntp_servers:
  |  |--ansible-control-node
  |--@ntp_clients:
  |  |--@oracle_servers:
  |  |  |--@database19c:
  |  |  |  |--public-database19c-01
  |  |  |--@database21c:
  |  |  |  |--public-database21c-01
  |  |--@weblogic_servers:
  |  |  |--@weblogic12c:
  |  |  |  |--public-weblogic12c-01
  |  |  |--@weblogic14c:
  |  |  |  |--public-weblogic14c-01

```
