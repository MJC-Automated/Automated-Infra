# Oracle WebLogic 14c Playbook (`oracle_weblogic14c`)

This playbook installs/configures WebLogic 14.1.2 on hosts in the `weblogic14c` group.

## Configuration Sources

Runtime values come from two layers:

1. Role defaults: `bootstrap_playbooks/oracle_weblogic14c/vars/weblogic_vars.yml`
2. Environment overrides (recommended): `inventories/<env>/group_vars/weblogic14c.yml`

Use group vars for environment-specific domains, managed servers, and extra ports.

## Required Installer Archives

Place compressed installers on the control node under `/resources`:

- `jdk-17.0.12_linux-x64_bin.tar.gz` (default via `jdk_choice: "17"`)
- `fmw_14.1.2.0.0_infrastructure.tar.gz`

Optional JDK 8 fallback (if `jdk_choice: "8"`):

- `jdk-8u411-linux-x64.tar.gz`

## Defining Additional Resources

### Primary domain + managed servers

Set these in vars or inventory overrides:

- `domain_name`, `domain_home`, `admin_port`
- `managed_server_enable` (toggle managed server automation)
- `managed_servers` list
- `nodemanager_enabled` / `nodemanager_listen_port`

Example:

```yaml
managed_server_enable: true

managed_servers:
  - name: ManagedServer1
    listen_port: 8001
  - name: ManagedServer2
    listen_port: 8002
```

### Additional domains on the same host

`additional_weblogic_domains` supports domain-level and managed-server-level entries:

For 14c, additional-domain tasks are **manage-existing only**. Each additional domain is activated only when:

- `{{ item.domain_home }}/bin/startWebLogic.sh` exists.
- Then scripts/systemd/firewall/cron are managed for that domain.

```yaml
additional_weblogic_domains:
  - domain_name: WLS14C_APP1
    domain_home: "{{ domain_base }}/WLS14C_APP1"
    admin_port: 7008
    managed_servers:
      - name: ManagedServerA1
        listen_port: 8101
      - name: ManagedServerA2
        listen_port: 8102
```

## Inventory

Preferred inventory is centralized via repo root `ansible.cfg`:

- `inventories/<env>/inventory.ini`
- `inventories/aliases.ini`

## Python Environment

This project uses a shared pyenv virtualenv name:

- `v3.9.21-weblogic`

Setup example:

```bash
pyenv install -s 3.9.21
pyenv virtualenv 3.9.21 v3.9.21-weblogic

cd ~/IaC-Homelab/bootstrap_playbooks/oracle_weblogic14c
pyenv local v3.9.21-weblogic
pip install -r requirements.txt
```

## Run Commands

```bash
cd ~/IaC-Homelab/bootstrap_playbooks/oracle_weblogic14c

# Full run (canonical committed env: dev)
ansible-playbook -i ../../inventories/<env>/inventory.ini -i ../../inventories/aliases.ini main.yml -l weblogic14c

# CRUD/idempotency second pass
ansible-playbook -i ../../inventories/<env>/inventory.ini -i ../../inventories/aliases.ini main.yml -l weblogic14c

# Optional service/firewall checks
ansible-playbook -i ../../inventories/<env>/inventory.ini -i ../../inventories/aliases.ini main.yml -l weblogic14c --tags systemd_service
ansible-playbook -i ../../inventories/<env>/inventory.ini -i ../../inventories/aliases.ini main.yml -l weblogic14c --tags firewalld,summary
```

## Useful Tags

- `directories`
- `os_prereqs`
- `os_tune`
- `jdk_install`
- `fmw_install`
- `rcu`
- `domain_create`
- `boot_properties`
- `nodemanager`
- `systemd_service`
- `firewalld`
- `summary`

## Defaults and Behavior

- Managed server automation toggle: `managed_server_enable: true`
- Admin and managed server automation are independent (`manage_admin_systemd`, `manage_managed_systemd`, `managed_server_enable`)
- Managed services are auto-started by default: `auto_start_managed: true`
- Admin service auto-start is enabled by default: `auto_start_admin: true`
- Firewall management is enabled by default: `firewall_manage_enabled: true`
- Domain and applications are kept outside `ORACLE_HOME` (`/u02/domains`, `/Applications`)
- GC log path is explicit and pre-created:
  - directory: `{{ logs_base_dir }}/{{ domain_name }}/gc`
  - file: `{{ weblogic_gc_log_file }}`
  - startup scripts now create/touch GC log targets before JVM launch.
- The JVM warning about archived non-system classes when `java.system.class.loader` is set is expected with WebLogic launcher usage.

## Compact Domain Profile (ADF)

Domain creation now applies compact-domain profile templates by default (`compact_domain_profile_enabled: true`) using no-database-compatible templates (`Oracle Restricted JRF` + `Oracle Enterprise Manager-Restricted JRF`).

`Oracle JRF SOAPS/JMS Web Services [oracle_common]` is controlled by `compact_domain_enable_soapjms` and is disabled by default for no-database domains, because in this stack it requires the DB-backed/full JRF template path.

Manual interactive equivalent:

```bash
export CONFIG_JVM_ARGS="-Dcom.oracle.cie.config.showProfile=true"
$ORACLE_HOME/oracle_common/common/bin/config.sh
```

In the wizard choose:

1. `Create Domain`
2. `Create a Compact Domain without Database (Uses Embedded Database JavaDB)`
3. Enable EM/JRF profile options per your target mode (no-db restricted by default in automation).

## Verification

```bash
# Services
ssh ansible@<weblogic14c-host> "sudo systemctl status wlsWLS14CDOMAIN7001.service wlsWLS14CDOMAIN8001.service wlsWLS14CDOMAIN8002.service wlsWLS14CDOMAINNM.service"

# Listening ports
ssh ansible@<weblogic14c-host> "sudo ss -ltnp | egrep ':7001|:8001|:8002|:5556'"

# Console/admin endpoint (redirect to login is expected)
curl -I http://<weblogic14c-host>:7001/console

# Managed-server /console is expected to return HTTP 404
curl -I http://<weblogic14c-host>:8001/console
```

## Scenario Runbook

DB-first CRUD and WebLogic validation runbook:

- [`../../docs/oracle-db-weblogic-crud-scenario.md`](../../docs/oracle-db-weblogic-crud-scenario.md)
