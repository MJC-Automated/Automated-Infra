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
- `requirements.txt`: Python controller dependencies
- `requirements.yml`: Ansible collection dependencies
- `group_vars/observability_servers.yml`: defaults
- `roles/observability/`: install/configure/verify tasks

## Usage

```bash
ansible-playbook -i inventories/example/inventory.ini -i inventories/aliases.ini bootstrap_playbooks/observability/main.yml
```

## Python Environment

This project uses a dedicated pyenv virtualenv name:

- `v3.10.19-observability`

Setup example:

```bash
pyenv install -s 3.10.19
pyenv virtualenv 3.10.19 v3.10.19-observability

cd ~/IaC-Homelab/bootstrap_playbooks/observability
pyenv local v3.10.19-observability
pip install -r requirements.txt
ansible-galaxy collection install -r requirements.yml
```

## Notes

- Requires `observability_grafana_admin_password` (via `.env` or injected vars).
- Targets `observability_servers` alias group.
- Run twice for idempotency checks.
