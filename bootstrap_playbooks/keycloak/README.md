# Keycloak Playbook (`keycloak`)

Automates Keycloak on Ubuntu 24.04 with local PostgreSQL and systemd service management.

## Files

- `main.yml`: entry point
- `.env.example`: optional controller-side overrides
- `requirements.txt`: Python controller dependencies
- `requirements.yml`: Ansible collection dependencies
- `group_vars/keycloak_servers.yml`: defaults
- `roles/keycloak/`: install/configure/verify tasks

## Usage

```bash
ansible-playbook -i inventories/example/inventory.ini -i inventories/aliases.ini bootstrap_playbooks/keycloak/main.yml
```

## Python Environment

This project uses a dedicated pyenv virtualenv name:

- `v3.10.19-keycloak`

Setup example:

```bash
pyenv install -s 3.10.19
pyenv virtualenv 3.10.19 v3.10.19-keycloak

cd ~/IaC-Homelab/bootstrap_playbooks/keycloak
pyenv local v3.10.19-keycloak
pip install -r requirements.txt
ansible-galaxy collection install -r requirements.yml
```

## Notes

- Requires `keycloak_db_password` and `keycloak_admin_password` (via `.env` or injected vars).
- Set `KEYCLOAK_MANAGE_DATABASE=false` when the target database is prepared out of band.
- If `KEYCLOAK_DB_HOST` points to a remote PostgreSQL host and provisioning stays enabled, set `KEYCLOAK_DB_ADMIN_USER`/`KEYCLOAK_DB_ADMIN_PASSWORD` for remote admin access. `KEYCLOAK_DB_ADMIN_DATABASE` defaults to `postgres` for the remote maintenance connection.
- Targets `keycloak_servers` alias group.
- Run twice for idempotency checks.
