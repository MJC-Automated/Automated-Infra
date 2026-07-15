# Oracle WebLogic 14c Playbook (`oracle_weblogic14c`)

This playbook installs/configures WebLogic 14.1.2 on hosts in the `weblogic14c` group.

## Configuration Sources

Runtime values come from two layers:

1. Role defaults: `ansible/bootstrap_playbooks/oracle_weblogic14c/vars/weblogic_vars.yml`
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

For 14c, additional-domain tasks are domain-creation aware:

- WLST scripts are generated per additional domain.
- Domain creation is idempotent (`creates: <domain_home>/config/config.xml`).
- After creation, admin/managed services, scripts, firewall, cron, cleanup, and remote-console deployment can be managed.
- Set `managed_server_enable: true` to manage additional-domain managed-server services.

```yaml
additional_weblogic_domains:
  - domain_name: WLS14C_APP1
    domain_home: "{{ domain_base }}/WLS14C_APP1"
    admin_port: 7008
    coherence_port: 7575
    managed_servers:
      - name: ManagedServerA1
        listen_port: 8101
      - name: ManagedServerA2
        listen_port: 8102
```

Each additional domain can override `weblogic_user_mem_args`, `weblogic_gc_log_dir`, `weblogic_gc_log_file`, `admin_url`, `admin_server_name`, and `coherence_port`. Generated start/stop scripts use those per-domain values with primary-domain fallbacks.

Generated WebLogic startup scripts also set Coherence runtime flags for single-host dev environments where multicast is unavailable: IPv4 is preferred, `coherence.wka` defaults to the host address, and `coherence.localport` is auto-adjusted.

## Inventory

Preferred inventory is centralized via repo root `ansible.cfg`:

- `inventories/<env>/inventory.ini`
- `inventories/aliases.ini`

## Python Environment

This project uses the repository-wide pyenv virtualenv from `ansible/.python-version`:

- `v3.13.14`

Setup example:

```bash
cd ~/IaC-Homelab/ansible
pyenv install -s 3.13.14
pyenv virtualenv 3.13.14 v3.13.14
pyenv local v3.13.14
python -m pip install --upgrade pip
pip install -r requirements.txt
ansible-galaxy collection install -r requirements.yml
```

## Run Commands

```bash
cd ~/IaC-Homelab/ansible/bootstrap_playbooks/oracle_weblogic14c

# Full run (canonical committed env: dev)
ansible-playbook main.yml -l weblogic14c

# CRUD/idempotency second pass
ansible-playbook main.yml -l weblogic14c

# Optional service/firewall checks
ansible-playbook main.yml -l weblogic14c --tags systemd_service
ansible-playbook main.yml -l weblogic14c --tags firewalld,summary
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
- Additional domains defined in `additional_weblogic_domains` are created idempotently, then managed
- Per-domain `coherence_port` is applied during domain creation and injected into server startup scripts
- Coherence startup uses WKA/localport auto-adjust runtime flags so multiple same-host domain members can start without multicast
- GC log path is explicit and pre-created:
  - directory: `{{ logs_base_dir }}/{{ domain_name }}/gc`
  - file: `{{ weblogic_gc_log_file }}`
  - startup scripts now create/touch GC log targets before JVM launch.
- JRF shared-library targeting filters by known JRF/ADF prefixes (e.g. `adf.oracle.*`, `oracle.adf.*`, `oracle.jsp*`) and merges missing targets without removing existing ones.
- WLST scripts rendered for JRF targeting and Remote Console deployment contain credentials; they are written with mode `0600` and deleted immediately after execution.
- Remote Console redeployment is triggered when either the WLST check detects a missing/changed deployment or when the `plan.xml` template content changes.
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

## Storage Cleanup

Storage cleanup and disk space monitoring are natively integrated into the playbook and run by default at the end of execution.

- Generates `/home/oracle/scripts/cleanup_weblogic.sh` to purge old `*.out`, `*.log`, and `*.log0*` files older than 5 days.
- Creates a disk space monitoring cron job (`/home/oracle/scripts/check_disk.sh`) to warn if `/u01`, `/u02`, or `/Logs` cross an 80% threshold.

To run only the cleanup setup independently without the rest of the WebLogic logic:

```bash
ansible-playbook main.yml -l weblogic14c --tags cleanup
```

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
