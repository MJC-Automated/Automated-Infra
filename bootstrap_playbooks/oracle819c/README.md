# Oracle 19c Ansible Playbook (`oracle819c`)

This playbook installs and configures Oracle Database 19c on hosts in the `database19c` inventory group.

## Current Desired-State Model

`bootstrap_playbooks/oracle819c/group_vars/oracle_servers.yml` is actively used.

`main.yml` preloads host-specific state with:
- `PRELOAD | Load host-specific desired state from oracle_servers map`

For each host, values are resolved in this order:
1. `oracle_servers.<inventory_hostname>` from `group_vars/oracle_servers.yml`
2. Fallback defaults from `vars/main.yml` (`oracle_databases` projection)
3. Controller `.env` values for base defaults

If a host key is missing from `oracle_servers.yml`, fallback logic still works, but that is no longer the recommended pattern.

## Where To Define Resources

Define CDBs/PDBs/listeners under the host key in:
- `bootstrap_playbooks/oracle819c/group_vars/oracle_servers.yml`

Example structure:

```yaml
oracle_servers:
  public-database19c-02:  # must match inventory_hostname exactly
    oracle_hostname: "public-database19c-03.example.internal"

    oracle_listeners:
      - name: "LISTENER"
        port: 1521
        host: "public-database19c-03.example.internal"

    oracle_cdbs:
      - global_db_name: "cdb1.example.internal"
        sid: "cdb1"
        data_dir: "/u02/oradata"
        listener_name: "LISTENER"
        listener_port: 1521

    oracle_pdbs:
      - cdb_sid: "cdb1"
        pdb_name: "pdb1"
        service_name: "pdb1"
        pdb_data_dir: "/u02/oradata/PDB1"
        cdb_data_dir: "/u02/oradata/CDB1"
```

Optional app SQL bootstrap for a host can also be defined there:

```yaml
oracle_servers:
  public-database19c-02:
    oracle_app_sql_enabled: true
    oracle_app_sql_targets:
      - cdb_sid: "cdb1"
        pdb_name: "pdb1"
        database_name: "pdb1"
        sql_id: "app_bootstrap"
        sql_template: "app_bootstrap_minimal.sql.j2"
```

## Add More CDBs/PDBs

To add a second CDB and PDB, extend both lists for the same host key:

```yaml
oracle_servers:
  public-database19c-02:
    oracle_cdbs:
      - global_db_name: "cdb1.example.internal"
        sid: "cdb1"
        data_dir: "/u02/oradata"
        listener_name: "LISTENER"
        listener_port: 1521
      - global_db_name: "cdb2.example.internal"
        sid: "cdb2"
        data_dir: "/u02/oradata"
        listener_name: "LISTENER"
        listener_port: 1521

    oracle_pdbs:
      - cdb_sid: "cdb1"
        pdb_name: "LIFECO_19C"
        service_name: "LIFECO_19C"
        pdb_data_dir: "/u02/oradata/LIFECO_19C"
        cdb_data_dir: "/u02/oradata/CDB1"
      - cdb_sid: "cdb2"
        pdb_name: "LIFECO_19C_2"
        service_name: "LIFECO_19C_2"
        pdb_data_dir: "/u02/oradata/LIFECO_19C_2"
        cdb_data_dir: "/u02/oradata/CDB2"
```

Notes:
- `cdb_sid` in each `oracle_pdbs` item must match one `oracle_cdbs[].sid`.
- If a host key is present in `oracle_servers`, those lists are authoritative for that host.
- `ORACLE_SID_2`/`ORACLE_PDB_NAME_2` fallback in `vars/main.yml` only applies when host-level lists are empty.

## App SQL Behavior

- `oracle_app_sql_enabled: true` enables bootstrap SQL execution.
- If `oracle_app_sql_targets` is explicitly set, only those targets run.
- If `oracle_app_sql_targets` is empty and `oracle_app_sql_defaults_from_pdbs: true` (default), one app SQL target is generated per `oracle_pdbs` item.
- A marker file under `{{ oracle_app_sql_stage_dir }}` prevents rerun per target unless `oracle_app_sql_force: true`.
- Before template SQL runs, the role ensures a `USERS` tablespace exists in the target PDB.

Template options:
- `app_bootstrap_full.sql.j2`: full `APP_*` users/tablespaces/grants bootstrap
- `app_bootstrap_minimal.sql.j2`: minimal bootstrap (core tablespaces + baseline user/grants)

## Mandatory Prerequisites

- Oracle OS user/group identity is fixed:
  - `oracle` user UID must be `54321`
  - `oinstall` group GID must be `54321`
- `DUMP_DIR` must be configured before DB runs that include app SQL:
  - If `oracle_dump_dir_path` is on NFS, each PDB uses: `<oracle_dump_dir_path>/DUMPS.<host_last_octet>/<PDBNAME>`
  - If not on NFS, each PDB uses local fallback: `<oracle_dump_dir_local_base>/<PDBNAME>` (default: `/u02/DUMP_DIR/<PDBNAME>`)
  - Ensure the selected base path is writable by `oracle:oinstall`

## Inventory

Preferred inventory is centralized in repo root `ansible.cfg`:
- `inventories/dev/inventory.ini`
- `inventories/aliases.ini`

## Python Environment

This project uses a shared pyenv virtualenv name:
- `v3.13.0-oracle`

Setup example:

```bash
pyenv install -s 3.13.0
pyenv virtualenv 3.13.0 v3.13.0-oracle

cd ~/IaC-Homelab/bootstrap_playbooks/oracle819c
pyenv local v3.13.0-oracle
pip install -r requirements.txt
```

## Run Commands

From repo root or this folder:

```bash
cd ~/IaC-Homelab/bootstrap_playbooks/oracle819c

# Full 19c run
ansible-playbook main.yml -l database19c --skip-tags artifacts

# PDB lifecycle + app SQL only
ansible-playbook main.yml -l database19c --tags pdb_create,pdb_state,pdb_post_config,app_sql

# Verification only
ansible-playbook main.yml -l database19c --tags verify
```

## CRUD Scenario

End-to-end DB CRUD (add CDB/PDB, listener/firewall checks, remote SYS and `APP_*` logins, delete/reconcile) plus WebLogic follow-up checks:
- Admin Console validation should target AdminServer ports.
- Managed-server `/console` endpoints returning HTTP `404` are expected.

- [`../../docs/oracle-db-weblogic-crud-scenario.md`](../../docs/oracle-db-weblogic-crud-scenario.md)

## Important Behavior

- This playbook intentionally scopes to `database19c` when that group exists.
  - Running it with `-l database21c` will result in a no-op by design.
- Short PDB service naming is preserved by default:
  - `oracle_post_pdb_db_domain: ""` in `vars/main.yml`
  - Example service: `pdb1` (not `pdb1.example.internal`)
- There is no implicit `LISTENER2`/second-CDB creation anymore:
  - a second CDB is only considered when `ORACLE_SID_2` is explicitly set, or when you declare it in `group_vars/oracle_servers.yml`.
- Listener cleanup is enabled by default (`oracle_listener_cleanup_unmanaged: true`), so unmanaged listeners can be removed from listener/tnsnames configs.
- Listener config tasks now enforce listener hostnames in `/etc/hosts` using `ansible_host`, preventing `lsnrctl start` hangs caused by unresolved listener hostnames.

## Cleanup Applied

The stale per-host `host_vars/databaseDot157.yml` and `host_vars/databaseDot158.yml` files were removed.
Use `group_vars/oracle_servers.yml` as the single source of host-specific DB topology.
