#!/usr/bin/env bash
# Install and verify local tooling for this repo.
# Supports Ubuntu/Debian via apt + HashiCorp repository.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

ASSUME_YES=false
CHECK_ONLY=false
FORCE_INSTALL=false

usage() {
  cat <<'EOF'
Usage:
  setup-tools.sh [--check-only] [--yes] [--force-install]

Options:
  --check-only    Skip package installation and only run checks.
  --yes           Non-interactive install (assume yes).
  --force-install Install packages even if required tools are already present.
  -h, --help      Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only)
      CHECK_ONLY=true
      shift
      ;;
    --yes|-y)
      ASSUME_YES=true
      shift
      ;;
    --force-install)
      FORCE_INSTALL=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

tools_already_present() {
  local missing=0

  for cmd in vault terraform packer; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      missing=1
    fi
  done

  for cmd in tflint tfsec terraform-docs; do
    if ! command -v "${cmd}" >/dev/null 2>&1 || \
      ! "${cmd}" --version 2>&1 | grep -Eq '[0-9]+\.[0-9]+\.[0-9]+'; then
      missing=1
    fi
  done

  if [[ "${missing}" -eq 0 ]]; then
    return 0
  fi
  return 1
}

install_terraform_helpers() {
  local arch terraform_docs_tag tfsec_tag tflint_tag tmpdir

  case "$(uname -m)" in
    x86_64|amd64)
      arch="amd64"
      ;;
    aarch64|arm64)
      arch="arm64"
      ;;
    *)
      echo "Unsupported architecture for Terraform helper auto-install: $(uname -m)" >&2
      exit 1
      ;;
  esac

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' RETURN

  tfsec_tag="$(curl -fsSL https://api.github.com/repos/aquasecurity/tfsec/releases/latest | jq -r '.tag_name')"
  if [[ -z "${tfsec_tag}" || "${tfsec_tag}" == "null" ]]; then
    echo "Error: unable to determine latest tfsec release." >&2
    exit 1
  fi
  curl -fsSL -o "${tmpdir}/tfsec" \
    "https://github.com/aquasecurity/tfsec/releases/download/${tfsec_tag}/tfsec-linux-${arch}"
  chmod +x "${tmpdir}/tfsec"
  sudo install -m 0755 "${tmpdir}/tfsec" /usr/local/bin/tfsec

  tflint_tag="$(curl -fsSL https://api.github.com/repos/terraform-linters/tflint/releases/latest | jq -r '.tag_name')"
  if [[ -z "${tflint_tag}" || "${tflint_tag}" == "null" ]]; then
    echo "Error: unable to determine latest tflint release." >&2
    exit 1
  fi
  curl -fsSL -o "${tmpdir}/tflint.zip" \
    "https://github.com/terraform-linters/tflint/releases/download/${tflint_tag}/tflint_linux_${arch}.zip"
  unzip -q "${tmpdir}/tflint.zip" -d "${tmpdir}"
  sudo install -m 0755 "${tmpdir}/tflint" /usr/local/bin/tflint

  terraform_docs_tag="$(curl -fsSL https://api.github.com/repos/terraform-docs/terraform-docs/releases/latest | jq -r '.tag_name')"
  if [[ -z "${terraform_docs_tag}" || "${terraform_docs_tag}" == "null" ]]; then
    echo "Error: unable to determine latest terraform-docs release." >&2
    exit 1
  fi
  curl -fsSL -o "${tmpdir}/terraform-docs.tar.gz" \
    "https://github.com/terraform-docs/terraform-docs/releases/download/${terraform_docs_tag}/terraform-docs-${terraform_docs_tag}-linux-${arch}.tar.gz"
  tar -xzf "${tmpdir}/terraform-docs.tar.gz" -C "${tmpdir}"
  sudo install -m 0755 "${tmpdir}/terraform-docs" /usr/local/bin/terraform-docs

  echo "Installed tfsec ${tfsec_tag}, tflint ${tflint_tag}, and terraform-docs ${terraform_docs_tag}"
}

install_tools_ubuntu_debian() {
  local apt_yes=()
  if [[ "${ASSUME_YES}" == true ]]; then
    apt_yes=(-y)
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    echo "Error: sudo is required for tool installation." >&2
    exit 1
  fi

  echo "Installing tools via apt (Ubuntu/Debian)..."
  sudo apt-get update
  sudo apt-get install "${apt_yes[@]}" wget gpg lsb-release ca-certificates jq unzip curl

  # HashiCorp repository keyring.
  if [[ ! -f /usr/share/keyrings/hashicorp-archive-keyring.gpg ]]; then
    wget -O - https://apt.releases.hashicorp.com/gpg \
      | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
  fi

  # HashiCorp apt source.
  codename="$(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || true)"
  if [[ -z "${codename}" ]]; then
    codename="$(lsb_release -cs)"
  fi
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${codename} main" \
    | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null

  sudo apt-get update
  sudo apt-get install "${apt_yes[@]}" vault terraform packer
  install_terraform_helpers
}

if [[ "${CHECK_ONLY}" == false ]]; then
  if [[ "${FORCE_INSTALL}" == false ]] && tools_already_present; then
    echo "Required tools already present (vault/terraform/packer/tflint/tfsec/terraform-docs). Skipping installation."
  else
    if [[ ! -r /etc/os-release ]]; then
      echo "Error: Cannot detect OS (/etc/os-release missing)." >&2
      exit 1
    fi

    # shellcheck disable=SC1091
    source /etc/os-release
    os_id="${ID:-}"
    os_like="${ID_LIKE:-}"

    if [[ "${os_id}" == "ubuntu" || "${os_id}" == "debian" || "${os_like}" == *"debian"* ]]; then
      install_tools_ubuntu_debian
    else
      echo "Unsupported OS for auto-install: ${os_id:-unknown}" >&2
      echo "Install vault/terraform/packer manually, then run: scripts/check-tools.sh" >&2
      exit 1
    fi
  fi
fi

"${REPO_ROOT}/scripts/check-tools.sh"
