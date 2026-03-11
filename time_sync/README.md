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
time_sync/
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

Source selection order on clients:
1. `time_sync_client_ntp_servers` if defined.
2. `ntp_servers` group hosts, resolved in this order:
   `time_sync_server_advertise_ip` -> `ansible_host` -> `ansible_default_ipv4.address`.
3. Public fallback from `time_sync_public_servers` if enabled.

## Environment File

This playbook automatically reads optional overrides from `time_sync/.env`.

```bash
cp time_sync/.env.example time_sync/.env
```

Common keys:
- `TIME_SYNC_ALLOWED_SUBNET`
- `TIME_SYNC_SERVER_ADVERTISE_IP`
- `TIME_SYNC_PUBLIC_SERVERS` (comma-separated)
- `TIME_SYNC_CLIENT_NTP_SERVERS` (comma-separated)

## Python Environment and Dependencies

```bash
cd ~/IaC-Homelab/time_sync
pyenv install -s 3.10.19
pyenv virtualenv 3.10.19 v3.10.19-users
pyenv local v3.10.19-users
python -m pip install --upgrade pip
pip install -r requirements.txt
```

## Usage

Run from the repository root:

```bash
ansible-playbook -i inventories/dev/inventory.ini -i inventories/aliases.ini time_sync/main.yml
```

For a specific environment:

```bash
ansible-playbook -i inventories/testing/inventory.ini -i inventories/aliases.ini time_sync/main.yml
```

Useful tags:
- `configuration`
- `verification`

## Verification

Manual checks after apply:

```bash
chronyc tracking
chronyc sources -v
```
