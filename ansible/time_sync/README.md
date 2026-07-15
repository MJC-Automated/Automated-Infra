# Time Synchronization Playbook (`time_sync`)

This playbook manages Chrony time synchronization with an internal NTP topology:

- `ntp_servers` contains the Ansible control node, which acts as the fallback NTP server.
- `ntp_clients` hosts sync from those internal servers.
- Optional public upstream/fallback sources are configurable.

This model supports air-gapped targets where VMs cannot directly reach public NTP.

## Features

- Internal server/client NTP model using inventory groups.
- Air-gapped friendly behavior with local clock fallback on NTP servers.
- Optional public fallback for clients in connected environments.
- Conflicting service cleanup (`ntpd`, `systemd-timesyncd`).
- Firewall rule support for NTP on server hosts.
- Idempotent runs with post-configuration verification.

## Project Structure

```tree
ansible/time_sync/
├── .env.example
├── main.yml
├── group_vars/
│   ├── ntp_servers.yml
│   └── ntp_clients.yml
└── roles/
    └── time_sync/
        ├── defaults/main.yml
        ├── tasks/
        └── templates/
```

## Configuration

### NTP server hosts (`ntp_servers`)

`group_vars/ntp_servers.yml` controls server behavior:

- `time_sync_public_servers`: Upstream sources used by the server (set `[]` when fully isolated).
- `time_sync_allowed_subnet`: CIDR allowed to query the server.
- `time_sync_server_advertise_ip`: Optional explicit address that clients should use.
- `time_sync_server_enable_local_fallback`: Keep serving time if upstream is unreachable.
- `time_sync_server_local_stratum`: Local fallback stratum (default `10`).

Inventory requirement:

- `ntp_servers` should point to the Ansible control node (not a VM in `all_nodes`).
- Example in `inventories/aliases.ini`:

```ini
[ntp_servers]
ansible-control-node ansible_connection=local ansible_python_interpreter=/usr/bin/python3
```

### NTP client hosts (`ntp_clients`)

`group_vars/ntp_clients.yml` controls client behavior:

- `time_sync_client_use_internal_servers`: Use hosts from the `ntp_servers` inventory group.
- `time_sync_client_add_public_fallback`: Append public sources on clients (`false` for air-gapped).
- `time_sync_client_ntp_servers`: Optional explicit list to override automatic source selection.

Repository convention:

- `ntp_clients` should include every host that depends on repo-managed Kerberos or service-to-service identity flows.
- For the current FreeIPA topology that means `oracle_servers`, `weblogic_servers`, `freeipa_servers`, `keycloak_servers`, and `observability_servers`.
- Keep `ntp_clients` in sync with new FreeIPA client/service aliases when adding more Kerberos-integrated hosts.

Current `inventories/aliases.ini` pattern:

```ini
[ntp_clients:children]
oracle_servers
weblogic_servers
freeipa_servers
keycloak_servers
observability_servers
```

Source selection order on clients:

1. `time_sync_client_ntp_servers` if defined.
2. `ntp_servers` group hosts, resolved in this order:
   `time_sync_server_advertise_ip` -> `ansible_host` -> `ansible_default_ipv4.address`.
3. Public fallback from `time_sync_public_servers` if enabled.

## Environment File

This playbook automatically reads optional overrides from `ansible/time_sync/.env`.

```bash
cp ansible/time_sync/.env.example ansible/time_sync/.env
```

Common keys:

- `TIME_SYNC_ALLOWED_SUBNET`
- `TIME_SYNC_SERVER_ADVERTISE_IP`
- `TIME_SYNC_PUBLIC_SERVERS` (comma-separated)
- `TIME_SYNC_CLIENT_NTP_SERVERS` (comma-separated)

## Python Environment and Dependencies

```bash
cd ~/IaC-Homelab/ansible
pyenv install -s 3.13.14
pyenv virtualenv 3.13.14 v3.13.14
pyenv local v3.13.14
python -m pip install --upgrade pip
pip install -r requirements.txt
ansible-galaxy collection install -r requirements.yml
```

## Usage

Run from the playbook directory. The local `ansible.cfg` supplies the default inventory and vault-password path.

```bash
cd ~/IaC-Homelab/ansible/time_sync
ansible-playbook main.yml
```

For targeted runs:

```bash
ansible-playbook main.yml --limit ntp_clients
```

The playbook delegates fact gathering to any `ntp_servers` host excluded by
`--limit`, so clients still resolve the server's routable address instead of
using its inventory alias as a Chrony source. Runtime synchronization checks
are intentionally skipped under `--check`; run an actual limited apply to
prove Chrony tracking and source selection.

Useful tags:

- `configuration`
- `verification`

## Verification

Manual checks after apply:

```bash
chronyc tracking
chronyc sources -v
```
