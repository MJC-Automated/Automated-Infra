# Oracle WebLogic 12c Playbook (`oracle_weblogic12c`)

This playbook installs/configures WebLogic 12.2.1.4 on hosts in the `weblogic12c` group.

## Configuration Sources

Runtime values come from three layers:

1. Role defaults: `bootstrap_playbooks/oracle_weblogic12c/vars/weblogic_vars.yml`
2. Environment overrides (recommended): `inventories/<env>/group_vars/weblogic12c.yml`
3. Secret env vars (recommended): `bootstrap_playbooks/oracle_weblogic12c/.env` (copy from `.env.example`, chmod 600)

Use group vars for environment-specific domain names, ports, managed servers, and additional domains.

## Required Installer Archives

Place compressed installers on the control node under `/resources`:

- `jdk-8u411-linux-x64.tar.gz`
- `fmw_12.2.1.4.0_infrastructure_Disk1_1of1.zip`

The playbook copies installer payloads to target hosts and supports `.zip`, `.tar.gz`, or direct `.jar` for FMW.

## Defining Additional Resources

### Primary domain

Configure primary domain settings with:

- `domain_name`
- `domain_home`
- `admin_port`
- `weblogic_password`
- `managed_server_enable`
- `managed_servers`

`managed_server_enable` only controls managed-server automation. AdminServer automation remains independent.

Example (fresh VM, primary domain with two managed servers linked to AdminServer):

```yaml
managed_server_enable: true
managed_servers:
  - name: ms1
    listen_port: 8001
  - name: ms2
    listen_port: 8002
```

Managed server startup uses AdminServer URL `t3://<ansible_host>:<admin_port>` unless you set `admin_url` per managed server. The playbook ensures AdminServer is started before managed server setup.

### Additional domains on the same host

Define them with `additional_weblogic_domains` in inventory group vars.
For 12c, these entries are domain-creation aware:

- WLST scripts are generated per additional domain.
- Domain creation is idempotent (`creates: <domain_home>/config/config.xml`).
- After creation, admin/managed services, scripts, firewall, and cron can be managed.
Set `managed_server_enable: true` to manage additional-domain managed-server services.

```yaml
managed_server_enable: true

additional_weblogic_domains:
  - domain_name: CLIENT_A_domain2
    domain_home: "{{ oracle_middleware_home }}/user_projects/domains/CLIENT_A_domain2"
    admin_port: 8106
    managed_servers:
      - name: ms2
        listen_port: 8101
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

cd ~/IaC-Homelab/bootstrap_playbooks/oracle_weblogic12c
pyenv local v3.9.21-weblogic
pip install -r requirements.txt
```

## Run Commands

```bash
cd ~/IaC-Homelab/bootstrap_playbooks/oracle_weblogic12c

# Full run (canonical committed env: dev)
ansible-playbook -i ../../inventories/<env>/inventory.ini -i ../../inventories/aliases.ini main.yml -l weblogic12c

# CRUD/idempotency second pass
ansible-playbook -i ../../inventories/<env>/inventory.ini -i ../../inventories/aliases.ini main.yml -l weblogic12c

# Optional partial checks
ansible-playbook -i ../../inventories/<env>/inventory.ini -i ../../inventories/aliases.ini main.yml -l weblogic12c --tags firewall,summary
```

## Useful Tags

- `directories`
- `os_tune`
- `firewall`
- `jdk_install`
- `bash_profile`
- `fmw_install`
- `rcu`
- `domain_create`
- `systemd_service`
- `crontab`
- `summary`

## Defaults and Behavior

- Firewall management is enabled by default: `firewall_manage_enabled: true`
- Cron stop/start entries are enabled by default in `vars/weblogic_vars.yml`
- Node Manager is optional (`nodemanager_enabled: false` by default)
- `managed_server_enable` gates managed-server operations for both primary and additional domains
- Additional domains defined in `additional_weblogic_domains` are created idempotently, then managed
- GC log path is explicit and pre-created:
  - directory: `{{ logs_base_dir }}/{{ domain_name | upper }}_LOGS/gc`
  - file: `{{ weblogic_gc_log_file }}`
  - startup scripts now create/touch GC log targets before JVM launch.

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

## Storage Cleanup

Storage cleanup and disk space monitoring are natively integrated into the playbook and run by default at the end of execution.
- Generates `/home/oracle/scripts/cleanup_weblogic.sh` to purge old `*.out`, `*.log`, and `*.log0*` files older than 5 days.
- Creates a disk space monitoring cron job (`/home/oracle/scripts/check_disk.sh`) to warn if `/u01`, `/u02`, or `/Logs` cross an 80% threshold.

To run only the cleanup setup independently without the rest of the WebLogic logic:
```bash
ansible-playbook main.yml -l weblogic12c --tags cleanup
```

## Verification

```bash
# Service state (example names)
ssh ansible@<weblogic12c-host> "sudo systemctl status wlsCLIENT_ADOMAIN8006.service wlsCLIENT_ADOMAIN8001.service wlsCLIENT_ADOMAIN28106.service wlsCLIENT_ADOMAIN28101.service"

# Port checks (example)
ssh ansible@<weblogic12c-host> "sudo ss -ltnp | egrep ':8006|:8001|:8106|:8101'"

# Admin console reachability
curl -I http://<weblogic12c-host>:8006/console

# Managed-server /console is expected to return HTTP 404
curl -I http://<weblogic12c-host>:8001/console
```

## Scenario Runbook

DB-first CRUD and WebLogic validation runbook:

- [`../../docs/oracle-db-weblogic-crud-scenario.md`](../../docs/oracle-db-weblogic-crud-scenario.md)
