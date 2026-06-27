# Oracle 19c on Oracle Linux 9 Ansible Playbook (`oracle919c`)

This playbook installs and configures Oracle Database 19c on Oracle Linux 9 hosts in the `database19c_ol9` inventory group.
It supports the normal RU-based install path and a throwaway unpatched POC mode for proving base 19c on OL9.

## Current Desired-State Model

`bootstrap_playbooks/oracle919c/group_vars/oracle_servers.yml` is actively used.

`main.yml` preloads host-specific state with:

- `PRELOAD | Load host-specific desired state from oracle_servers map`

For each host, values are resolved in this order:

1. `oracle_servers.<inventory_hostname>` from `group_vars/oracle_servers.yml`
2. Fallback defaults from `vars/main.yml` (`oracle_databases` projection)
3. Controller `.env` values for base defaults

If a host key is missing from `oracle_servers.yml`, fallback logic still works, but that is no longer the recommended pattern.

## Where To Define Resources

Define CDBs/PDBs/listeners under the host key in:

- `bootstrap_playbooks/oracle919c/group_vars/oracle_servers.yml`

Repository rule:

- The committed desired-state map tracks the requested `example` Oracle Linux 9 host key (`public-database19c-ol9-02`).
- For other environments, copy the same structure under that environment's exact `inventory_hostname`.

Example structure:

```yaml
oracle_servers:
  public-database19c-ol9-02:  # must match inventory_hostname exactly
    oracle_hostname: "public-database19c-ol9-03.example.internal"

    oracle_listeners:
      - name: "LISTENER"
        port: 1521
        host: "public-database19c-ol9-03.example.internal"

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
  public-database19c-ol9-02:
    oracle_app_sql_enabled: true
    oracle_app_sql_targets:
      - cdb_sid: "cdb1"
        pdb_name: "pdb1"
        database_name: "pdb1"
        sql_id: "tq_app_bootstrap"
        sql_template: "tq_app_bootstrap_minimal.sql.j2"
```

## Add More CDBs/PDBs

To add a second CDB and PDB, extend both lists for the same host key:

```yaml
oracle_servers:
  public-database19c-ol9-02:
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

- `tq_app_bootstrap_full.sql.j2`: full `TQ_*` users/tablespaces/grants bootstrap
- `tq_app_bootstrap_minimal.sql.j2`: minimal bootstrap (core tablespaces + baseline user/grants)

## Mandatory Prerequisites

- Oracle Database 19c on Oracle Linux 9 requires UEK7 and Database RU 19.19 or later.
- Set `ORACLE_RU_PATCH_ID` and `ORACLE_RU_PATCH_ZIP`; set `ORACLE_RU_PATCH_APPLY_DIR` when the RU zip extracts to a nested DB RU directory.
- `ORACLE_OPATCH_ZIP` is validated from `OPatch/version.txt`, not from the filename. A zip labeled `p6880880_121010_Linux-x86-64.zip` is acceptable if it reports OPatch `12.2.0.1.42` or later.
- Oracle OS user/group identity is fixed:
  - `oracle` user UID must be `54321`
  - `oinstall` group GID must be `54321`
- `DUMP_DIR` must be configured before DB runs that include app SQL:
  - If `oracle_dump_dir_path` is on NFS, each PDB uses: `<oracle_dump_dir_path>/DUMPS.<host_last_octet>/<PDBNAME>`
  - If not on NFS, each PDB uses local fallback: `<oracle_dump_dir_local_base>/<PDBNAME>` (default: `/u02/DUMP_DIR/<PDBNAME>`)
  - Ensure the selected base path is writable by `oracle:oinstall`

## Inventory

Preferred inventory is centralized in repo root `ansible.cfg`:

- `inventories/example/inventory.ini`
- `inventories/aliases.ini`

## Python Environment

This project uses a shared pyenv virtualenv name:

- `v3.13.0-oracle`

Setup example:

```bash
pyenv install -s 3.13.0
pyenv virtualenv 3.13.0 v3.13.0-oracle

cd ~/IaC-Homelab/bootstrap_playbooks/oracle919c
pyenv local v3.13.0-oracle
pip install -r requirements.txt
```

## Run Commands

From repo root or this folder:

```bash
cd ~/IaC-Homelab/bootstrap_playbooks/oracle919c

# Full 19c on OL9 run
ansible-playbook main.yml -l database19c_ol9 --skip-tags artifacts

# Throwaway POC only: install/run without RU or OPatch on OL9.
# This skips patch application and uses compatibility shims to prove the base installer path.
# It is not the supported target state.
ansible-playbook main.yml -l database19c_ol9 --skip-tags artifacts \
  -e oracle_ol9_allow_unpatched_poc=true

# PDB lifecycle + app SQL only
ansible-playbook main.yml -l database19c_ol9 --tags pdb_create,pdb_state,pdb_post_config,app_sql

# Verification only
ansible-playbook main.yml -l database19c_ol9 --tags verify
```

## CRUD Scenario

End-to-end DB CRUD (add CDB/PDB, listener/firewall checks, remote SYS and `TQ_*` logins, delete/reconcile) plus WebLogic follow-up checks:

- Admin Console validation should target AdminServer ports.
- Managed-server `/console` endpoints returning HTTP `404` are expected.

- [`../../docs/oracle-db-weblogic-crud-scenario.md`](../../docs/oracle-db-weblogic-crud-scenario.md)

## Storage Cleanup

Storage cleanup and disk space monitoring are natively integrated into the playbook and run by default at the end of execution.
- Generates `/home/oracle/scripts/cleanup_database.sh` to purge old `adump` audit files, ADRCI traces, and `cdump` cores.
- Deploys `logrotate` rules for listener logs (`/etc/logrotate.d/oracle_listener`).
- Creates a disk space monitoring cron job (`/home/oracle/scripts/check_disk.sh`) to warn if `/u01` or `/u02` cross an 80% threshold.

To run only the cleanup setup independently without the rest of the database logic:
```bash
ansible-playbook main.yml -l database19c_ol9 --tags cleanup
```

## RU Patching

RU patching is natively integrated and can be enabled or disabled:
- `oracle_patch_enabled: true` (default) enables checking and applying the target Release Update patch (`36582781`).
- The patching tasks are tagged with `oracle_patch`. Use `--skip-tags oracle_patch` or set `oracle_patch_enabled: false` to completely skip the patching phase.
- Before applying the patch, any running database instances and listener processes are gracefully stopped (using `/home/oracle/scripts/stop_all.sh` or immediate shutdown commands) to avoid file-in-use errors.
- `set -o pipefail` ensures OPatch command failures are properly reported to Ansible.
- On OL9, Oracle 19c requires an RU patch for compatibility. By default, `oracle_ol9_require_ru_patch: true` enforces this. For PoC/lab use without patch files, pass `-e oracle_ol9_allow_unpatched_poc=true` to bypass enforcement.

## Automated Time Zone Upgrades

To prevent `ORA-39405` errors during Data Pump operations where a source database has a newer timezone version (e.g. DSTv43) than the target container's default (DSTv32):
- `oracle_timezone_upgrade_enabled: true` (default) checks if the database timezone version is behind the latest version in the patched Oracle Home.
- If out of date, it automatically runs `@?/rdbms/admin/utltz_upg_check.sql` and `@?/rdbms/admin/utltz_upg_apply.sql` to upgrade CDB$ROOT and all pluggable databases.
- The upgrade automatically restarts the containers and saves their open states.
- Timezone upgrade tasks are tagged with `timezone_upgrade`.

## Database Backups & Restarts

Daily operation crontabs are deployed for the `oracle` user:
- **Daily Backups**: Scheduled at `0 0 * * *` (midnight), running `/home/oracle/scripts/backup_database.sh` to perform concurrent pluggable database exports via `expdp` and rotate old backups. The retention period is controlled by `oracle_backup_retention_days` (default: 7 days).
- **Daily Restarts**: Scheduled at `0 4 * * *` (4:00 AM) via `/home/oracle/scripts/restart_databases.sh` to gracefully recycle the databases and listeners.

## Important Behavior

- This playbook intentionally scopes to `database19c_ol9` when that group exists.
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
