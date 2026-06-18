# Zabbix Server Playbook (`zabbix_server`)

Scalable, role-based automation for Zabbix 7.0 server deployment on:

- Ubuntu 24.04
- Oracle Linux 9

The design follows a "service plugin" pattern so future services (Jenkins, PostgreSQL, MySQL, etc.) can reuse the same structure without creating a single monolithic playbook.

## Technique Used (Scalable Pattern)

- One service per project (`bootstrap_playbooks/zabbix_server/`, `jenkins/`, `postgresql/`, ...).
- One role per service with task modules split by responsibility:
  - `validate.yml`
  - `repo.yml`
  - `packages.yml`
  - `database.yml`
  - `config.yml`
  - `service.yml`
  - `firewall.yml`
- `.env` as operator interface (no secrets in committed vars files).
- Group-level defaults in `group_vars/` for non-secret behavior.
- Centralized inventory aliases in `inventories/aliases.ini`.

This keeps onboarding new app/db/service automations additive and low-risk.

## Project Structure

```tree
bootstrap_playbooks/zabbix_server/
├── .env.example
├── ansible.cfg
├── main.yml
├── requirements.txt
├── group_vars/
│   └── zabbix_servers.yml
└── roles/
    └── zabbix_server/
        ├── defaults/main.yml
        ├── handlers/main.yml
        └── tasks/
            ├── main.yml
            ├── validate.yml
            ├── repo.yml
            ├── packages.yml
            ├── database.yml
            ├── config.yml
            ├── firewall.yml
            └── service.yml
```

## DB Modes

- `internal`: installs/manages local PostgreSQL on the Zabbix host.
- `external`: connects to remote PostgreSQL (`ZABBIX_DB_HOST`).

Both modes support optional bootstrap of DB user/database and optional schema import.

## Environment File

```bash
cp bootstrap_playbooks/zabbix_server/.env.example bootstrap_playbooks/zabbix_server/.env
chmod 600 bootstrap_playbooks/zabbix_server/.env
```

Important keys:

- `ZABBIX_DB_MODE=internal|external`
- `ZABBIX_DB_HOST`, `ZABBIX_DB_PORT`, `ZABBIX_DB_NAME`, `ZABBIX_DB_USER`, `ZABBIX_DB_PASSWORD`
- `ZABBIX_DB_SCHEMA` (leave empty for default PostgreSQL `public` schema)
- `ZABBIX_DB_CREDENTIALS_STORE=plaintext|hashicorp`
- `ZABBIX_DB_VAULT_URL`, `ZABBIX_DB_VAULT_PREFIX`, `ZABBIX_DB_VAULT_DB_PATH`, `ZABBIX_DB_VAULT_TOKEN`, `ZABBIX_DB_VAULT_CACHE`
- `ZABBIX_DB_MANAGE_USER_AND_DB=true|false`
- `ZABBIX_DB_IMPORT_SCHEMA=true|false`
- `ZABBIX_DB_ADMIN_USER`, `ZABBIX_DB_ADMIN_PASSWORD` (for external bootstrap)
- `ZABBIX_FRONTEND_SERVER_NAME` (optional UI display label)
- `ZABBIX_BACKUP_ENABLED=true|false`
- `ZABBIX_BACKUP_MOUNT_POINT=/custom/mount`
- `ZABBIX_BACKUP_DIR=/custom/mount/zabbix-data`
- `ZABBIX_BACKUP_KEEP_ARCHIVED=2`
- `ZABBIX_BACKUP_KEEP_MAX=3`
- `ZABBIX_BACKUP_SCHEDULE_HOUR=2`
- `ZABBIX_BACKUP_SCHEDULE_MINUTE=15`
- `ZABBIX_BACKUP_REQUIRE_MOUNT=true|false`

## Backup and Retention Policy

When backups are enabled, the role installs `/usr/local/bin/zabbix-db-backup.sh`
and a daily cron job. The script:

- Takes a fresh PostgreSQL dump of `zabbix` data.
- Keeps the newest dump as raw `.sql` for fast restore.
- Compresses older dumps into `archive/` as `.sql.gz`.
- Keeps only the latest `2` archived dumps.
- Enforces a global max of `3` total backups (raw + archived).

Default path is `/var/backups/zabbix-data`, but you can point this to a custom
mount point with `ZABBIX_BACKUP_MOUNT_POINT` and/or `ZABBIX_BACKUP_DIR`.
Set `ZABBIX_BACKUP_REQUIRE_MOUNT=true` to fail fast when the mount is missing.

## Frontend DB Credentials Store Toggle

You can control the "Store credentials in" behavior from `.env`:

- `ZABBIX_DB_CREDENTIALS_STORE=plaintext`
  - writes `DB['USER']` and `DB['PASSWORD']` to `zabbix.conf.php`
- `ZABBIX_DB_CREDENTIALS_STORE=hashicorp`
  - writes `DB['VAULT']='HashiCorp'` and Vault settings
  - frontend reads DB credentials from Vault secret keys `username` and `password`

For HashiCorp mode you must set:

- `ZABBIX_DB_VAULT_URL`
- `ZABBIX_DB_VAULT_DB_PATH`
- `ZABBIX_DB_VAULT_TOKEN`

`ZABBIX_DB_VAULT_PREFIX` is optional (empty is supported).

## Inventory Wiring

Add your hosts to `zabbix_servers` in:

- `inventories/aliases.ini`
- and ensure real host definitions exist in `inventories/<env>/inventory.ini`

## Usage

From repo root:

```bash
ansible-playbook -i inventories/dev/inventory.ini -i inventories/aliases.ini bootstrap_playbooks/zabbix_server/main.yml
```

Example: external DB mode with pre-existing DB:

```bash
ZABBIX_DB_MODE=external
ZABBIX_DB_HOST=198.51.100.86
ZABBIX_DB_MANAGE_USER_AND_DB=false
ZABBIX_DB_IMPORT_SCHEMA=false
```

## Validation

```bash
ansible-playbook --syntax-check bootstrap_playbooks/zabbix_server/main.yml
ansible-inventory -i inventories/dev/inventory.ini -i inventories/aliases.ini --graph
```

## Troubleshooting

- If the installer reports `dbversion` table not found, do not set schema to `zabbix`
  unless you imported into that schema explicitly.
- For default automation imports, keep `ZABBIX_DB_SCHEMA=` (empty), which targets `public`.

## Source Alignment

Package/repository commands are aligned with Zabbix official 7.0 package instructions for:

- Ubuntu 24.04 + PostgreSQL + Apache
- Oracle Linux 9 + PostgreSQL + Apache
