# Keycloak Playbook (`keycloak`)

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
