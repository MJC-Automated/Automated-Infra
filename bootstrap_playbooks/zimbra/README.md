# Zimbra FOSS Playbook (`zimbra`)

Automates single-node Zimbra FOSS installation on Oracle Linux 9 using a local installer artifact.

- Target group: `zimbra_servers` (aliased to Terraform dynamic group `zimbra`)
- Artifact source: local controller file (default)
  - `/resources/zcs-10.1.15_GA_4200001.RHEL9_64.20260110181427.tgz`

## What It Does

- Validates OL9 target and local artifact availability.
- Prepares host requirements (`rsyslog`, `perl`, `p7zip-plugins`, hostname, `/etc/hosts`).
- Manages host firewall rules (`firewalld`) including admin UI (`7071/tcp`).
- Uses mounted `/zimbra` storage by default:
  - installer staging under `/zimbra/zimbra-installer`
  - bind mount `/zimbra/opt-zimbra` -> `/opt/zimbra`
- Uses Zimbra package repositories to resolve `*-components` dependencies not
  present in the local tarball.
- Renders a non-interactive Zimbra defaults file.
- Runs unattended installer from the uploaded artifact.
- Keeps `imapd` unchanged by default, but can auto-disable it only when
  `zmcontrol status` failure points to `imapd`.
- Verifies `zmcontrol status` and reports effective domain/admin data.

## Random Defaults

The role ships deterministic random-like defaults derived from `inventory_hostname` for:

- mail domain
- server FQDN
- admin email
- AV/SMTP notify emails
- admin + LDAP passwords

You can override any value via `.env`.

## Configuration

```bash
cp bootstrap_playbooks/zimbra/.env.example bootstrap_playbooks/zimbra/.env
chmod 600 bootstrap_playbooks/zimbra/.env
```

Important keys:

- `ZIMBRA_ARTIFACT_PATH`
- `ZIMBRA_USE_MOUNTED_DATA_DIR`, `ZIMBRA_DATA_MOUNT_PATH`, `ZIMBRA_DATA_ROOT`
- `ZIMBRA_PLATFORM_OVERRIDE` (keep `false` for Oracle Linux 9)
- `ZIMBRA_HOSTNAME`, `ZIMBRA_MAIL_DOMAIN`, `ZIMBRA_ADMIN_EMAIL`
- `ZIMBRA_ADMIN_PASSWORD` + LDAP password keys
- `ZIMBRA_MANAGE_FIREWALL`, `ZIMBRA_FIREWALL_ALLOWED_PORTS`
- `ZIMBRA_INSTALL_PACKAGES` (comma-separated)
- `ZIMBRA_USE_ZIMBRA_PACKAGE_SERVER` (default `yes`)
- `ZIMBRA_DISABLE_IMAPD_WHEN_MAILBOX` (default `false`)
- `ZIMBRA_IMAPD_AUTO_DISABLE_ON_FAILURE` (default `true`)

## Inventory Wiring

Use environment inventory + aliases:

- `inventories/example/inventory.ini`
- `inventories/aliases.ini`

`terraform-proxmox make apply ENVIRONMENT=example` generates `inventories/example/inventory.ini` with group `zimbra`.
`inventories/aliases.ini` maps `zimbra_servers` -> `zimbra`.

## Python Environment

This project uses a shared pyenv virtualenv name:

- `v3.10.19-zimbra`

Setup example:

```bash
pyenv install -s 3.10.19
pyenv virtualenv 3.10.19 v3.10.19-zimbra

cd ~/IaC-Homelab/bootstrap_playbooks/zimbra
pyenv local v3.10.19-zimbra
pip install -r requirements.txt
```

## Usage

From repo root:

```bash
ansible-playbook \
  -i inventories/example/inventory.ini \
  -i inventories/aliases.ini \
  bootstrap_playbooks/zimbra/main.yml
```

## Validation

```bash
ansible-playbook --syntax-check bootstrap_playbooks/zimbra/main.yml
ansible-inventory -i inventories/example/inventory.ini -i inventories/aliases.ini --graph
```

## Notes

- First install can take several minutes.
- Installer logs are available on target under `/tmp/install.log` and `/opt/zimbra/log/`.
- Re-runs are idempotent at the role level (`/opt/zimbra/bin/zmcontrol` gate skips reinstall).
- Operational notes from the first successful `example` deployment are in [`OPERATIONS.md`](./OPERATIONS.md).
