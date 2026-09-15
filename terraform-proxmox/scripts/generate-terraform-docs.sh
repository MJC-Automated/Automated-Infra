#!/usr/bin/env bash
# Regenerate Terraform module interface references embedded in README files.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

module_dirs=(
  "${TERRAFORM_ROOT}"
  "${TERRAFORM_ROOT}/modules/proxmox-vm"
  "${TERRAFORM_ROOT}/modules/proxmox-pool"
  "${TERRAFORM_ROOT}/modules/vault-proxmox-access"
)

if ! command -v terraform-docs >/dev/null 2>&1; then
  echo "Error: terraform-docs is required. Run make setup-tools first." >&2
  exit 1
fi

for module_dir in "${module_dirs[@]}"; do
  readme="${module_dir}/README.md"
  if ! grep -Fqx '<!-- BEGIN_TF_DOCS -->' "${readme}" || \
    ! grep -Fqx '<!-- END_TF_DOCS -->' "${readme}"; then
    echo "Error: ${readme} is missing terraform-docs markers." >&2
    exit 1
  fi

  (
    cd "${module_dir}"
    terraform-docs markdown table --output-file README.md --output-mode inject .
  )
done

echo "Terraform module references regenerated."
