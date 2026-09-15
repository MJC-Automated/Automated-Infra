# Keycloak Playbook (`keycloak`)

## Upgrade Safety

The selected Keycloak archive is SHA-256 verified. Before a minor or major
upgrade, stop all Keycloak nodes using the database and back up both PostgreSQL
and the active installation. The role copies `providers/` and `themes/`
(including hidden files) into the extracted new distribution **before**
replacing a mounted installation or switching a version symlink. A failed
preservation copy aborts before replacement. The new distribution is rebuilt
with the preserved providers before the service restarts; a same-version
rerun does not invalidate its optimized build.

Preservation does not make old extensions compatible automatically. Migrate
custom code/templates as required by the [Keycloak upgrade guide](https://www.keycloak.org/docs/latest/upgrading/)
and test health, login, hostname/proxy behavior, and custom providers/themes
before promotion. A database rollback requires restoring the pre-upgrade
backup; retaining the old binaries alone is insufficient. See the repository [service upgrade
compatibility runbook](../../../docs/service-upgrade-compatibility.md) for the
reviewed target and artifact requirements.

Automates Keycloak on Ubuntu 24.04 with local PostgreSQL and systemd service management.

## Files

- `main.yml`: entry point
- `.env.example`: optional controller-side overrides
- Controller dependencies are managed from `ansible/requirements.txt` and `ansible/requirements.yml`.
- `group_vars/keycloak_servers.yml`: defaults
- `roles/keycloak/`: install/configure/verify tasks

## Usage

```bash
cd ~/IaC-Homelab/ansible/bootstrap_playbooks/keycloak
ansible-playbook main.yml
```

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

## Notes

- Uses injected `keycloak_db_password` and `keycloak_admin_password` when supplied; otherwise it persists distinct generated credentials in the ignored mode-`0600` `files/` directory.
- Set `KEYCLOAK_MANAGE_DATABASE=false` when the target database is prepared out of band.
- If `KEYCLOAK_DB_HOST` points to a remote PostgreSQL host and provisioning stays enabled, set `KEYCLOAK_DB_ADMIN_USER`/`KEYCLOAK_DB_ADMIN_PASSWORD` for remote admin access. `KEYCLOAK_DB_ADMIN_DATABASE` defaults to `postgres` for the remote maintenance connection.
- Targets `keycloak_servers` alias group.
- Run twice for idempotency checks.
