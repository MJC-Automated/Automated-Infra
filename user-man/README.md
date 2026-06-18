# Ansible User Management - CRUD Operations

A comprehensive Ansible role for managing Linux users with full CRUD (Create, Read, Update, Delete) operations across multiple servers. This project supports SSH key management, group assignments, password policies, and user cleanup operations.

## Table of Contents

- [Features](#features)
- [Project Structure](#project-structure)
- [Quick Start](#quick-start)
  - [Prerequisites](#prerequisites)
  - [Installation](#installation)
  - [Configuration](#configuration)
  - [Usage](#usage)
- [Configuration Details](#configuration-details)
  - [User Definitions](#user-definitions)
  - [User Removal](#user-removal)
  - [Password Generation](#password-generation)
  - [SSH Key Management](#ssh-key-management)
- [Inventory Configuration](#inventory-configuration)
- [Advanced Features](#advanced-features)
  - [OS-Specific Group Mapping](#os-specific-group-mapping)
  - [Password Policies](#password-policies)
  - [SSH Key Export](#ssh-key-export)
- [Security Considerations](#security-considerations)
  - [Ansible Vault](#ansible-vault)
  - [Best Practices](#best-practices)
- [Compatibility](#compatibility)
- [Troubleshooting](#troubleshooting)
- [Tags Reference](#tags-reference)
- [Contributing](#contributing)
- [License](#license)
- [Author](#author)
- [Support](#support)
- [Version History](#version-history)

## Features

- ✅ **User Creation**: Create users with custom UIDs, groups, and SSH keys.
- ✅ **User Updates**: Modify existing user attributes and group memberships.
- ✅ **User Removal**: Clean removal of users with home directory cleanup.
- ✅ **SSH Key Management**: Generate, manage, and export SSH key pairs.
- ✅ **Group Management**: Automatic group creation and OS-specific group mapping.
- ✅ **Password Policies**: Set password expiration and security policies.
- ✅ **Idempotent by Default**: Converged reruns stay stable (`changed=0`) across hosts.
- ✅ **Automation Account Hardening**: Lock automation account password and enforce SSH key-only login.
- ✅ **Custom Home Support**: Automation-account hardening resolves home paths from `getent` (not hardcoded `/home`).
- ✅ **Lower Runtime Overhead**: User/shadow discovery uses host-wide lookups to avoid per-user command churn.
- ✅ **Key-Only Prerequisite Guard**: Prevents password-auth hardening when `authorized_keys` is missing/empty.
- ✅ **SSH Login Allowlist Enforcement**: Writes deterministic `AllowUsers` policy drop-ins.
- ✅ **Unmanaged Account Detection/Control**: Detect, lock, or remove interactive users not in allowlists.
- ✅ **Password Reuse Controls**: Enforces PAM password history and optional inventory-declared reuse checks.
- ✅ **Multi-OS Support**: Works with RHEL/CentOS, Ubuntu/Debian, and SUSE systems.
- ✅ **Python 3.9+ Compatible**: Uses modern Python runtimes on managed hosts.

## Project Structure

```tree
user-man/
├── .gitignore
├── ansible.cfg                  # Ansible configuration (e.g., inventory path)
├── README.md
├── requirements.txt             # Python controller dependencies
├── requirements.yml             # Ansible collection dependencies
├── export_pubkeys.yml           # Playbook to export existing SSH public keys
├── group_vars/
│   ├── all.yml                  # User definitions and configuration
│   └── secret_vars.yml          # Encrypted variables (Ansible Vault)
├── inventory.ini                # Legacy reference (Terraform now generates inventories)
├── main.yml                     # Main playbook for user management
└── roles/
    └── user_management/
        ├── defaults/main.yml    # Default role variables
        ├── handlers/main.yml    # Service reload handlers
        ├── meta/main.yml        # Role metadata
        ├── tasks/
        │   ├── cleanup_users.yml # Tasks for removing users
        │   ├── create_groups.yml # Tasks for creating groups
        │   ├── enforce_account_baseline.yml # Detect/lock/remove unmanaged interactive users
        │   ├── enforce_password_history.yml # PAM password history enforcement
        │   ├── harden_automation_account.yml # Automation account hardening
        │   ├── main.yml          # Main task file for the role
        │   └── manage_users.yml  # Tasks for creating/updating users
        └── vars/main.yml         # Role-specific variables
```

## Quick Start

### Prerequisites

- Ansible Core 2.17+ (recommended for newer Python runtimes)
- Python 3.9+ on target machines
- SSH access with `sudo` privileges to target servers

### Installation

1. **Clone the repository:**

    ```bash
    git clone <repository-url>
    cd user-man
    pip install -r requirements.txt
    ansible-galaxy collection install -r requirements.yml
    ```

2. **Install dependencies:**
    The project uses `requirements.txt` for Python packages and `requirements.yml` for Ansible collections.

    ```bash
    pip install -r requirements.txt
    ansible-galaxy collection install -r requirements.yml
    ```

    *Note: This setup targets modern hosts and is aligned for newer Python runtimes.*

### Configuration

1. **Define Servers:** Inventory is generated by Terraform under `../inventories/<env>/inventory.ini`.
2. **Define Users:** Edit `group_vars/all.yml` to define the users you want to create, update, or remove.
3. **(Optional) Encrypt Secrets:** For production, store sensitive data like passwords in `group_vars/secret_vars.yml` using Ansible Vault.
4. **Do not store automation account passwords in vault:** Keep `ansible` key-based only.
5. **Ansible Config:** The `ansible.cfg` file is pre-configured to use the centralized inventory and `../inventories/aliases.ini`.
6. **Vault password file hygiene:** If you use `.vault_password`, keep it untracked and restricted (`chmod 600 .vault_password`).
<<<<<<< HEAD:ansible_user_management/README.md
=======
7. **Host targeting:** `main.yml` and `export_pubkeys.yml` target `all_nodes` (Terraform-managed hosts). This avoids running against alias-only hosts such as `ansible-control-node`.
>>>>>>> terraform-proxmox-automated-infra:user-man/README.md

### Usage

Execute the main playbook to apply changes:

```bash
# Explicit inventory (recommended when not using dev default)
ansible-playbook -i ../inventories/<env>/inventory.ini -i ../inventories/aliases.ini main.yml -J

# Create or update users
ansible-playbook main.yml

# Or explicitly point at the Terraform-generated inventory
ansible-playbook -i ../inventories/dev/inventory.ini -i ../inventories/aliases.ini main.yml

# Run on Oracle DB servers (aliases.ini -> oracle_servers)
ansible-playbook main.yml --limit oracle_servers

# Export existing SSH public keys from servers
ansible-playbook export_pubkeys.yml

# Run only specific tasks using tags
ansible-playbook main.yml --tags remove_users
```

## Configuration Details

### User Definitions

Define users in `group_vars/all.yml`.

<details>
<summary><b>Example: `group_vars/all.yml`</b></summary>

```yaml
users:
  - name: johndoe
    state: present
    uid: 1100
    groups:
      - wheel        # Automatically maps to 'sudo' on Debian/Ubuntu
      - docker
    comment: "John Doe - DevOps Engineer"
    password: "$6$encrypted_password_hash"  # Use 'openssl passwd -6' to generate
    expires: -1      # Never expires. Can also be an epoch timestamp.
    ssh_keys:
      - "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGeneratedForPublicDocs sanitized@example.invalid
      - "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGeneratedForPublicDocs sanitized@example.invalid

remove_users:
  - name: olduser
    state: absent
    remove_home: true
    force: true
    additional_cleanup_paths:
      - /opt/olduser_data
      - /var/log/olduser
```

</details>

### User Lifecycle Guidelines

Use these steps to **add** or **remove** accounts safely:

1. **Add a user**
   - Add a new entry under `users:` in `group_vars/all.yml`.
   - Add matching secrets in `group_vars/secret_vars.yml` under `users_secrets.<username>`:
     - `password` (hashed)
     - `ssh_keys` (list)
     - optional `ssh_key_passphrase`
   - Re-run:

     ```bash
     ansible-playbook -J main.yml --limit <group>
     ```

2. **Remove a user**
   - Add the user under `remove_users:` in `group_vars/all.yml` with `state: absent`.
   - Optionally set `remove_home: true` and add `additional_cleanup_paths`.
   - Re-run:

     ```bash
     ansible-playbook -J main.yml --limit <group>
     ```

3. **Default automation account**
   - The recommended control user is `ansible`, provisioned by cloud-init (outside this role).
   - Keep inventories pointing to `ansible` and manage additional users here (e.g., `user1`, `user2`, etc.).

### Secure Team Baseline (5-user scenario)

For a team of five managed users:

- Keep all five users under `users:` with hashed passwords in `secret_vars.yml`.
- Password max age is 31 days by default (`default_user_settings.password_expire_max: 31`).
- Keep `automation_account_hardening_enabled: true` and `automation_account_usernames: [ansible]`.
- Do not define a reusable password for `ansible` in `users:`/vault data.
- The role locks the `ansible` account password and enforces SSH key-only auth for that account to prevent password-based backdoor logins.
- Keep `managed_accounts_key_only: true`, `enforce_sshd_allowlist: true`, and `password_history_enforcement_enabled: true`.
- Keep `account_enforcement_enabled: true` with `account_enforcement_mode: fail` to detect unmanaged interactive accounts.
- Explicitly approve unavoidable host-local users (for example `oracle`, `ubuntu`) via:
  - `allowed_unmanaged_accounts`
  - `allowed_unmanaged_accounts_by_host`
- Repository rule: committed `allowed_unmanaged_accounts_by_host` entries intentionally cover only the tracked `dev-*` hosts.
- For `example` or other environments, extend host-specific exceptions locally or in environment-specific inventory/group vars instead of adding more tracked non-dev hostnames here.

### New Host Onboarding (Without Lockout)

When onboarding a fresh host where managed users do not yet have `authorized_keys`, use this flow:

1. Pre-seed SSH keys for managed users (recommended), then run normally.
2. If pre-seeding is not yet done, set `key_only_prereq_mode: warn` temporarily.
3. Run playbook once to create users and push keys.
4. Set `key_only_prereq_mode: fail` again and rerun.

This prevents accidental lockout while still enforcing key-only posture after onboarding.

### User Removal

To remove users, define them in the `remove_users` list. The playbook will terminate their processes and optionally remove their home directories and other specified paths.

### Password Generation

Generate secure SHA512 password hashes for the `password` field.

```bash
# Using openssl
openssl passwd -6 'your_super_secret_password'

# Using Python
python -c "import crypt; print(crypt.crypt('your_password', crypt.mksalt(crypt.METHOD_SHA512)))"
```

### SSH Key Management

The role supports multiple SSH key strategies:

1. **Provide Keys:** Add public keys to the `ssh_keys` list for a user.
2. **Generate Keys:** Set `generate_ssh_key: true` for a user to have a new key pair created on the target machine.
3. **Export Keys:** Run the `export_pubkeys.yml` playbook to fetch existing public keys from servers.

## Inventory Configuration

Inventory is generated by Terraform under `../inventories/<env>/inventory.ini` and should not be edited by hand. The `ansible.cfg` in this project already points at the generated inventory and also includes `../inventories/aliases.ini` for app-specific group aliases.
The user-management playbooks deliberately target `all_nodes`, so `ansible-control-node` from alias groups (for example `ntp_servers`) is excluded by default.

## Advanced Features

### OS-Specific Group Mapping

The role automatically translates the `wheel` group to `sudo` on Debian-based systems (like Ubuntu) to ensure consistent admin access across different OS families.

### Password Policies

Define global or per-user password expiration policies. The role default is a 31-day max age.

<details>
<summary><b>Example: Password Policy in `group_vars/all.yml`</b></summary>

```yaml
default_user_settings:
  password_expire_max: 90      # Max days between password changes
  password_expire_min: 7       # Min days between password changes
  password_expire_warn: 14     # Days before expiration to warn user
  password_expire_account_disable: 7  # Days after expiration to disable account
```

</details>

### SSH Key Export

The `export_pubkeys.yml` playbook fetches existing SSH public keys from all users managed by this role on `all_nodes` (Terraform-managed hosts).

```bash
ansible-playbook export_pubkeys.yml
```

Keys are saved locally to the `./exported_keys/` directory, with each file named `HOSTNAME_USERNAME_KEYTYPE.pub`.

## Security Considerations

### Ansible Vault

For enhanced security, encrypt sensitive variables like passwords. Do not commit vault password files.

```bash
# Create a new encrypted file
ansible-vault create group_vars/secret_vars.yml

# Edit an existing encrypted file
ansible-vault edit group_vars/secret_vars.yml

# Recommended: prompt for vault password
ansible-playbook main.yml -J

# Or set once per terminal session
export ANSIBLE_VAULT_PASSWORD_FILE="$HOME/.ansible/vault_user_mgmt.pass"
ansible-playbook main.yml
```

### Best Practices

1. **Use SSH keys** for authentication instead of passwords where possible.
2. **Encrypt secrets** using Ansible Vault.
3. **Never store the `ansible` SSH password in vault**; keep automation account key-only.
4. **Set account expiration** for temporary users.
5. **Enforce password rotation** using password policies.
6. **Limit sudo access** to only necessary users.
7. **Keep account baseline enforcement enabled** and whitelist only approved unmanaged accounts.
8. **Prefer `key_only_prereq_mode: fail`** except during controlled first-time host onboarding.

## Compatibility

### Supported Operating Systems

- ✅ Oracle Linux 8, 9
- ✅ Red Hat Enterprise Linux 8, 9
- ✅ Ubuntu 20.04, 22.04, 24.04+
- ✅ Debian 11, 12
- ✅ SUSE Linux Enterprise Server 15+

### Python Compatibility

- ✅ Python 3.9+
- ✅ Automatic interpreter detection (defaults to system `python3`)

### Ansible Versions

- ✅ Ansible Core 2.17+
- ✅ Compatible with newer Python controller runtimes

## Validation Snapshot (2026-02-16)

<<<<<<< HEAD:ansible_user_management/README.md
Validated against 5 hosts:
=======
Current tracked dev topology spans 9 hosts:
>>>>>>> terraform-proxmox-automated-infra:user-man/README.md

- `public-weblogic14c-01`
- `public-weblogic12c-01`
- `public-database21c-02`
- `public-database19c-01`
- `public-zabbix-01`
- `public-freeipa-01`
- `public-keycloak-01`
- `public-observability-01`
- `public-zimbra-01`

The original idempotency snapshot below predates the topology expansion; `dev` is now the canonical 9-node scaffold for growing bootstrap coverage.

Execution results:

- Pass 1: all hosts successful (`failed=0`, `unreachable=0`) after convergence.
- Pass 2: fully idempotent on all hosts (`changed=0`, `failed=0`, `unreachable=0`).
- Post-checks:
  - managed users present with password-age policy applied
  - `ansible` account password locked
  - key-only hardening drop-in active at `/etc/ssh/sshd_config.d/99-key-only-account-hardening.conf`
  - SSH allowlist drop-in active at `/etc/ssh/sshd_config.d/98-account-allowlist.conf`
  - PAM password-history entries present in platform-appropriate PAM files

## Troubleshooting

### Common Issues

- **Python interpreter not found:** Ensure Python 3.9+ is installed, or set `ansible_python_interpreter=/usr/bin/python3` in the Terraform inventory output if you must override.
- **SSH connection issues:** Adjust `ansible_ssh_common_args` via Terraform inventory inputs or in `ansible.cfg` if you need legacy SSH algorithms.
- **Permission denied:** Ensure the `ansible_user` has `sudo` privileges and that `ansible_become=true` is set.
- **`Refusing key-only hardening because authorized_keys is missing/empty`:**
  - pre-seed user keys, or
  - temporarily set `key_only_prereq_mode: warn`, run once, then revert to `fail`.
- **`Unmanaged interactive users detected`:**
  - add intentional local users to `allowed_unmanaged_accounts` or `allowed_unmanaged_accounts_by_host`, or
  - remove/lock them by changing `account_enforcement_mode` as needed.

### Debug Mode

Run playbooks with increased verbosity (`-v`, `-vv`, or `-vvv`) to diagnose issues.

```bash
ansible-playbook main.yml -vvv
```

If you need to troubleshoot password-policy tasks, temporarily disable `no_log` for that section:

```bash
ansible-playbook main.yml -e password_policy_no_log=false -vv
```

Default remains secure (`password_policy_no_log: true`).

## Tags Reference

Use tags to run or skip specific parts of the playbook.

- `users`: All user-related tasks.
- `groups`: All group-related tasks.
- `create_users`: Only tasks for creating and updating users.
- `remove_users`: Only tasks for removing users.
- `ssh_keys`: Tasks related to managing SSH keys.
- `password_policy`: Tasks for setting password expiration.
- `security`: Automation-account hardening and security controls.
- `automation_account`: Only automation-account hardening tasks.
- `cleanup`: Tasks for removing user directories.

**Example:**

```bash
# Run only user and group creation tasks
ansible-playbook main.yml --tags "create_users,create_groups"

# Run all user tasks but skip the removal part
ansible-playbook main.yml --tags "users" --skip-tags "remove_users"
```

## Contributing

1. Fork the repository.
2. Create a new feature branch.
3. Test your changes thoroughly.
4. Submit a pull request with a clear description of your changes.

## License

This project is licensed under the MIT License.

## Author

**Example Maintainer**
*DevOps Engineer*

Modified: 2026-02-16

## Support

For issues and questions, please open an issue on the project's GitHub page.

## Version History

- **v2.0** (2025-07-24): Major refactor with Python 3 support, improved error handling, and OS-specific group mapping.
- **v1.0** (2025-01-15): Initial release with basic CRUD operations.
