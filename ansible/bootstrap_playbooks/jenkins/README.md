# Jenkins Automation

Provisions and configures a Jenkins LTS controller and optional SSH build agents on Ubuntu 24.04.

## Features
- Jenkins LTS package installation via modern flat APT deb822 repository specification (`suites: binary/` without components).
- Automatic cleanup of legacy `/etc/apt/sources.list.d/jenkins.list` and malformed `.sources` files with empty `Components:` directives.
- Support for offline local package installation (`JENKINS_PACKAGE_PATH` / `jenkins_package_path`).
- Automated Java OpenJDK installation with verification.
- JCasC (Jenkins Configuration as Code) declarative configuration.
- SSH build agent pairing and verification.

## Configuration & Environment Variables
Copy `.env.example` to `.env` in this directory to customize runtime parameters:

```bash
cp .env.example .env
```

| Variable | Default | Description |
|---|---|---|
| `JENKINS_VERSION` | `""` (latest LTS) | Pinned package version (e.g., `2.504.1`) |
| `JENKINS_PACKAGE_PATH` | `""` | Local `.deb` artifact path for offline installations |
| `JENKINS_HTTP_PORT` | `8080` | Jenkins web listen port |
| `JENKINS_MANAGE_AGENTS` | `true` | Whether to automatically configure SSH agent nodes |

## Verification
Run syntax check:
```bash
ansible-playbook --syntax-check main.yml
```
Run regression checks:
```bash
python -m unittest discover -s ../../tests -p "test_service_upgrade_checks.py" -v
```
