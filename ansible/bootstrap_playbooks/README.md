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
- `jenkins/`: Jenkins LTS controller and SSH build agent provisioning/configuration on Ubuntu 24.04
- `gitlab/`: GitLab CE and GitLab Runner provisioning/configuration on Ubuntu 24.04

## Entry Points

- `ansible/bootstrap_playbooks/oracle819c/main.yml`
- `ansible/bootstrap_playbooks/oracle919c/main.yml`
- `ansible/bootstrap_playbooks/oracle821c/main.yml`
- `ansible/bootstrap_playbooks/oracle_weblogic12c/main.yml`
- `ansible/bootstrap_playbooks/oracle_weblogic14c/main.yml`
- `ansible/bootstrap_playbooks/zabbix_server/main.yml`
- `ansible/bootstrap_playbooks/zimbra/main.yml`
- `ansible/bootstrap_playbooks/freeipa/main.yml`
- `ansible/bootstrap_playbooks/keycloak/main.yml`
- `ansible/bootstrap_playbooks/observability/main.yml`
- `ansible/bootstrap_playbooks/jenkins/main.yml`
- `ansible/bootstrap_playbooks/gitlab/main.yml`

## Inventory Convention

From inside `ansible/bootstrap_playbooks/*`, committed defaults use the tracked `dev` inventory shape:

- `../../../inventories/example/inventory.ini`
- `../../../inventories/aliases.ini`

`dev` is the only tracked environment. Terraform-generated environments should clone the same group-vars/service layout, and local `ansible.cfg` files can be pointed at that generated inventory to keep commands short.

Run from the specific playbook directory when possible and let its local `ansible.cfg` supply inventory and vault-password defaults.

The desired source model is the 18-node `dev` scaffold in `terraform-proxmox/environments/dev.tfvars`. The committed generated inventory may lag the tfvars topology, so validate its graph before using newly added groups.

## Cross-Playbook Notes

- Typical repo execution order is:
  - `ansible/user-man/main.yml`
  - `ansible/time_sync/main.yml`
  - database/bootstrap services
  - dependent middleware/services
- Oracle DB playbooks should converge before the matching WebLogic playbooks.
- Run `ansible/time_sync/main.yml` before `ansible/bootstrap_playbooks/freeipa/main.yml` and before Kerberos-joined service playbooks such as Keycloak or observability. The repo expects `inventories/aliases.ini` to keep `ntp_clients` aligned with those service groups.
- `ansible/bootstrap_playbooks/freeipa/main.yml` supports two DNS modes:
  - Integrated DNS: `FREEIPA_SETUP_DNS=true`
  - External DNS: `FREEIPA_SETUP_DNS=false`
- External DNS mode does not retrofit records into an outside authority. Publish the required A, SRV, URI, and `ipa-ca` records in your zone before expecting FreeIPA verification to pass.
- If Pi-hole/dnsmasq is authoritative for the zone, manage those records as static dnsmasq entries. Pi-hole does not support `nsupdate`, so FreeIPA cannot push zone changes into it during playbook runs.
- Jenkins and GitLab are configured for local-network homelab use by default. Put pre-downloaded JDK, Jenkins, GitLab, GitLab Runner, and Jenkins plugin-manager artifacts under `/resources` and set the matching `.env` paths when you want to avoid live repository downloads.
- Jenkins standalone mode is supported: omit `jenkins_agent`/`jenkins_agents` inventory hosts, keep `JENKINS_AGENT_*` unset, or set `JENKINS_MANAGE_AGENTS=false`. Multiple Jenkins agents are supported by adding multiple hosts to `jenkins_agent` and overriding per-host values in `host_vars` when needed. Externally managed agents not present in inventory require `JENKINS_ALLOW_EXTERNAL_AGENTS=true`.
- GitLab standalone mode is supported: omit `gitlab_runner`/`gitlab_runners` inventory hosts. Multiple GitLab runner VMs are supported by adding multiple `gitlab_runner` hosts; runner names default to each inventory hostname unless overridden in host vars.
