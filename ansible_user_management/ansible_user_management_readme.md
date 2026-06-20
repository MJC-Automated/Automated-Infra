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
- ✅ **Multi-OS Support**: Works with RHEL/CentOS, Ubuntu/Debian, and SUSE systems.
- ✅ **Python 2.7/3.x Compatible**: Supports legacy and modern Python environments.

## Project Structure

```tree
ansible_user_management/
├── .gitignore
├── ansible.cfg                  # Ansible configuration (e.g., inventory path)
├── ansible_user_management_readme.md
├── export_pubkeys.yml           # Playbook to export existing SSH public keys
├── group_vars/
│   ├── all.yml                  # User definitions and configuration
│   └── secret_vars.yml          # Encrypted variables (Ansible Vault)
├── inventory.ini                # Server inventory file
├── main.yml                     # Main playbook for user management
└── roles/
    └── user_management/
        ├── defaults/main.yml    # Default role variables
        ├── meta/main.yml        # Role metadata
        ├── tasks/
        │   ├── cleanup_users.yml # Tasks for removing users
        │   ├── create_groups.yml # Tasks for creating groups
        │   ├── main.yml          # Main task file for the role
        │   └── manage_users.yml  # Tasks for creating/updating users
        └── vars/main.yml         # Role-specific variables
```

## Quick Start

### Prerequisites

- Ansible 2.9+
- Python 2.7 or 3.x on target machines
- SSH access with `sudo` privileges to target servers

### Installation

1.  **Clone the repository:**
    ```bash
    git clone <repository-url>
    cd ansible_user_management
    ```

2.  **Install dependencies:**
    ```bash
      pyenv install 3.10.19
      pyenv activate v3.10.19-users-v1
      pip install -r requirements.txt
    ```
    *Note: The playbook is compatible with Ansible 2.9+ and has been tested on legacy systems running Python 2.7.*

### Configuration

1.  **Define Servers:** Edit `inventory.ini` to list your target servers.
2.  **Define Users:** Edit `group_vars/all.yml` to define the users you want to create, update, or remove.
3.  **(Optional) Encrypt Secrets:** For production, store sensitive data like passwords in `group_vars/secret_vars.yml` using Ansible Vault.
4.  **Ansible Config:** The `ansible.cfg` file is pre-configured to use the `inventory.ini` file.

### Usage

Execute the main playbook to apply changes:
```bash
# Create or update users
ansible-playbook main.yml

# Run on a specific group of servers
ansible-playbook main.yml --limit database_servers

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
1.  **Provide Keys:** Add public keys to the `ssh_keys` list for a user.
2.  **Generate Keys:** Set `generate_ssh_key: true` for a user to have a new key pair created on the target machine.
3.  **Export Keys:** Run the `export_pubkeys.yml` playbook to fetch existing public keys from servers.

## Inventory Configuration

The `inventory.ini` file defines your servers and connection parameters.

<details>
<summary><b>Example: `inventory.ini`</b></summary>

```ini
[database_servers]
db01 ansible_host=198.51.100.31
db02 ansible_host=198.51.100.32 ansible_python_interpreter=/usr/bin/python3

[web_servers]
web01 ansible_host=198.51.100.33
web02 ansible_host=198.51.100.34

[all:vars]
ansible_user=ansible
ansible_become=true
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
```
</details>

## Advanced Features

### OS-Specific Group Mapping

The role automatically translates the `wheel` group to `sudo` on Debian-based systems (like Ubuntu) to ensure consistent admin access across different OS families.

### Password Policies

Define global or per-user password expiration policies.

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

The `export_pubkeys.yml` playbook fetches existing SSH public keys from all users managed by this role on all servers in the inventory.

```bash
ansible-playbook export_pubkeys.yml
```

Keys are saved locally to the `./exported_keys/` directory, with each file named `HOSTNAME_USERNAME_KEYTYPE.pub`.

## Security Considerations

### Ansible Vault

For enhanced security, encrypt sensitive variables like passwords. The `ansible.cfg` is configured to look for a `.vault_password` file, or you can use `--ask-vault-pass`.

```bash
# Create a new encrypted file
ansible-vault create group_vars/secret_vars.yml

# Edit an existing encrypted file
ansible-vault edit group_vars/secret_vars.yml

# Run a playbook using the vault password
ansible-playbook main.yml --ask-vault-pass
```

### Best Practices

1.  **Use SSH keys** for authentication instead of passwords where possible.
2.  **Encrypt secrets** using Ansible Vault.
3.  **Set account expiration** for temporary users.
4.  **Enforce password rotation** using password policies.
5.  **Limit sudo access** to only necessary users.

## Compatibility

### Supported Operating Systems
- ✅ Red Hat Enterprise Linux 7, 8, 9
- ✅ CentOS 7, 8, 9
- ✅ Ubuntu 18.04, 20.04, 22.04+
- ✅ Debian 10, 11, 12
- ✅ SUSE Linux Enterprise Server

### Python Compatibility
- ✅ Python 2.7 (for legacy systems)
- ✅ Python 3.6+
- ✅ Automatic interpreter detection

### Ansible Versions
- ✅ Ansible 2.9+
- ✅ Compatible with Ansible Core 2.11+

## Troubleshooting

### Common Issues

-   **Python interpreter not found:** Specify the path in your inventory: `ansible_python_interpreter=/usr/bin/python3`.
-   **SSH connection issues:** For older systems, you may need to adjust SSH arguments in `inventory.ini` under `[all:vars]`: `ansible_ssh_common_args='-o StrictHostKeyChecking=no -o HostKeyAlgorithms=+ssh-rsa'`.
-   **Permission denied:** Ensure the `ansible_user` has `sudo` privileges and that `ansible_become=true` is set.

### Debug Mode

Run playbooks with increased verbosity (`-v`, `-vv`, or `-vvv`) to diagnose issues.
```bash
ansible-playbook main.yml -vvv
```

## Tags Reference

Use tags to run or skip specific parts of the playbook.

- `users`: All user-related tasks.
- `groups`: All group-related tasks.
- `create_users`: Only tasks for creating and updating users.
- `remove_users`: Only tasks for removing users.
- `ssh_keys`: Tasks related to managing SSH keys.
- `password_policy`: Tasks for setting password expiration.
- `cleanup`: Tasks for removing user directories.

**Example:**
```bash
# Run only user and group creation tasks
ansible-playbook main.yml --tags "create_users,create_groups"

# Run all user tasks but skip the removal part
ansible-playbook main.yml --tags "users" --skip-tags "remove_users"
```

## Contributing

1.  Fork the repository.
2.  Create a new feature branch.
3.  Test your changes thoroughly.
4.  Submit a pull request with a clear description of your changes.

## License

This project is licensed under the MIT License.

## Author

**Emmanuel Kirui**
*DevOps Engineer*

Modified: 2025-11-18

## Support

For issues and questions, please open an issue on the project's GitHub page.

## Version History

- **v2.0** (2025-07-24): Major refactor with Python 3 support, improved error handling, and OS-specific group mapping.
- **v1.0** (2025-01-15): Initial release with basic CRUD operations.

