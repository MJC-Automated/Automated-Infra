# Oracle DB + WebLogic CRUD Scenario

This scenario validates Oracle 19c desired-state CRUD and application bootstrap SQL, then checks WebLogic connectivity expectations.

## Scope

- Add/modify CDB and PDB topology using `bootstrap_playbooks/oracle819c/group_vars/oracle_servers.yml`
- Apply Oracle 19c playbook
- Verify CDB/PDB/listener state
- Verify app SQL users/tablespaces bootstrap
- Optionally remove PDB/CDB with delete lists
- Run WebLogic follow-up checks

## Prerequisites

- Inventory host key in `oracle_servers` must match `inventory_hostname` exactly.
- The tracked repo examples use the canonical `dev` host key (`public-database19c-01`). For other environments, copy the same structure under that environment's exact generated inventory hostname.
- Oracle DB admin password is set (`ORACLE_DB_ADMIN_PASSWORD` or vault variable).
- `DUMP_DIR` base path is available and writable by `oracle:oinstall`.

## 1) Define Desired State

Example for one host with two CDBs and two PDBs:

```yaml
oracle_servers:
  public-database19c-01:
    oracle_hostname: "public-database19c-02.example.internal"

    oracle_listeners:
      - name: "LISTENER"
        port: 1521
        host: "public-database19c-02.example.internal"

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

    oracle_app_sql_enabled: true
    oracle_app_sql_force: false
    oracle_app_sql_targets:
      - cdb_sid: "cdb1"
        pdb_name: "LIFECO_19C"
        database_name: "LIFECO_19C"
        sql_id: "tq_app_bootstrap"
        sql_template: "tq_app_bootstrap_full.sql.j2"
      - cdb_sid: "cdb2"
        pdb_name: "LIFECO_19C_2"
        database_name: "LIFECO_19C_2"
        sql_id: "tq_app_bootstrap"
        sql_template: "tq_app_bootstrap_full.sql.j2"
```

## 2) Apply Oracle 19c

Run from `bootstrap_playbooks/oracle819c`:

```bash
ansible-playbook -i ../../inventories/dev/inventory.ini -i ../../inventories/aliases.ini main.yml -l database19c --skip-tags artifacts
```

## 3) Verify Oracle State

```bash
ansible-playbook -i ../../inventories/dev/inventory.ini -i ../../inventories/aliases.ini main.yml -l database19c --tags verify
```

Expected:

- listener is running on target host
- each CDB in `oracle_cdbs` is present and open
- each PDB in `oracle_pdbs` is present and open

## 4) Verify App SQL Bootstrap

Bootstrap runs in `custom_sql` role when `oracle_app_sql_enabled: true`.

Behavior:

- if `oracle_app_sql_targets` is set, only listed targets run
- if empty and `oracle_app_sql_defaults_from_pdbs: true`, one target per `oracle_pdbs` is auto-generated
- `USERS` tablespace is ensured first in each target PDB
- marker files `.applied_<CDB>_<PDB>_<SQL_ID>.ok` prevent rerun unless forced

To force rerun:

```yaml
oracle_app_sql_force: true
```

Or run only SQL/bootstrap tags:

```bash
ansible-playbook -i ../../inventories/dev/inventory.ini -i ../../inventories/aliases.ini main.yml -l database19c --tags app_sql
```

## 5) Delete/Reconcile (Optional)

Set destructive lists for host-level desired deletes:

- `oracle_pdbs_delete` (delete PDBs first)
- `oracle_cdbs_delete` (delete CDBs after PDB deletes are clear)

Then run with delete tags:

```bash
ansible-playbook -i ../../inventories/dev/inventory.ini -i ../../inventories/aliases.ini main.yml -l database19c --tags pdb_delete
ansible-playbook -i ../../inventories/dev/inventory.ini -i ../../inventories/aliases.ini main.yml -l database19c --tags cdb_delete
```

## 6) WebLogic Follow-Up Checks

After DB changes, validate WebLogic connections as needed:

- Admin Console checks should target AdminServer ports.
- Managed server `/console` returning HTTP `404` is expected.
