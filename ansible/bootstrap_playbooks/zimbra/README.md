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
- Renders a root-only non-interactive defaults file and deletes it after a
  successful installation so bootstrap credentials do not remain at rest.
- Runs unattended installer from the uploaded artifact.
- Keeps `imapd` unchanged by default, but can auto-disable it only when
  `zmcontrol status` failure points to `imapd`.
- Verifies `zmcontrol status` and reports effective domain/admin data.

## Random Defaults

The role derives deterministic non-secret identity defaults from
`inventory_hostname` for:

- mail domain
- server FQDN
- admin email
- AV/SMTP notify emails

Admin and LDAP passwords are instead derived from a persistent random seed.

You can override any value via `.env`. Without one, the playbook persists a random ignored password seed under `files/`; predictable hostname-derived passwords are not used.

## Configuration

```bash
cp ansible/bootstrap_playbooks/zimbra/.env.example ansible/bootstrap_playbooks/zimbra/.env
chmod 600 ansible/bootstrap_playbooks/zimbra/.env
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

## Usage

From repo root:

```bash
cd ~/IaC-Homelab/ansible/bootstrap_playbooks/zimbra
ansible-playbook main.yml
```

## Validation

```bash
cd ~/IaC-Homelab/ansible/bootstrap_playbooks/zimbra
ansible-playbook --syntax-check main.yml
ansible-inventory --graph
```

## Notes

- First install can take several minutes.
- Installer logs are available on target under `/tmp/install.log` and `/opt/zimbra/log/`.
- Re-runs are idempotent at the role level (`/opt/zimbra/bin/zmcontrol` gate skips reinstall).
- Operational notes from the first successful `example` deployment are in [`OPERATIONS.md`](./OPERATIONS.md).
