# GitLab Automation

Provisions and configures GitLab Community Edition (CE) server and dedicated GitLab Runner nodes on Ubuntu 24.04.

## Features

- GitLab Omnibus installation with small-instance performance tuning.
- GitLab Runner automated registration via GitLab API.
- Support for complete offline package bundles (`gitlab-runner` + `gitlab-runner-helper-images`).
- Strict version matching and SHA256 checksum validation for offline artifacts.
- Unconditional service state enforcement (`systemd: state: started enabled: true`) across runs.
- Post-registration and runtime daemon health verification using `gitlab-runner verify`.

## Configuration & Environment Variables

Copy `.env.example` to `.env` in this directory to customize runtime parameters:

```bash
cp .env.example .env
```

| Variable | Default | Description |
| --- | --- | --- |
| `GITLAB_VERSION` | `19.3.1-ce.0` | GitLab server package version |
| `GITLAB_RUNNER_VERSION` | `19.3.1-1` | GitLab runner package version |
| `GITLAB_RUNNER_PACKAGE_PATH` | `""` | Local `.deb` artifact path for `gitlab-runner` |
| `GITLAB_RUNNER_HELPER_IMAGES_PACKAGE_PATH` | `""` | Local `.deb` artifact path for `gitlab-runner-helper-images` |
| `GITLAB_RUNNER_PACKAGE_CHECKSUM` | `""` | SHA256 checksum for runner deb |
| `GITLAB_RUNNER_HELPER_IMAGES_PACKAGE_CHECKSUM` | `""` | SHA256 checksum for helper images deb |

## Offline Installation Note

Modern GitLab Runner packages strictly require `gitlab-runner-helper-images (= ${binary:Version})`. When using `GITLAB_RUNNER_PACKAGE_PATH`, you MUST also provide `GITLAB_RUNNER_HELPER_IMAGES_PACKAGE_PATH`. Both packages will be version-asserted and installed together as an offline bundle.

## Verification

Run syntax check:

```bash
ansible-playbook --syntax-check main.yml
```

Run regression checks:

```bash
python -m unittest discover -s ../../tests -p "test_service_upgrade_checks.py" -v
```
