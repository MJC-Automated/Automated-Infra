# Observability Playbook (`observability`)

Deploys a unified observability stack on Ubuntu 24.04 using Docker:

- Grafana
- Prometheus
- Loki
- Tempo
- OpenTelemetry Collector
- Node Exporter

## Files

- `main.yml`: entry point
- `.env.example`: local secret/non-secret overrides
- Controller dependencies are managed from `ansible/requirements.txt` and `ansible/requirements.yml`.
- `group_vars/observability_servers.yml`: defaults
- `roles/observability/`: install/configure/verify tasks

## Usage

```bash
cd ~/IaC-Homelab/ansible/bootstrap_playbooks/observability
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

- Uses an injected `observability_grafana_admin_password` when supplied; otherwise it persists a generated credential in the ignored mode-`0600` `files/` directory.
- Targets `observability_servers` alias group.
- Run twice for idempotency checks.
