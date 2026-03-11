#!/usr/bin/env bash
# Validate local prerequisites for Vault/Terraform/Packer workflows.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"
MIN_TERRAFORM_VERSION="${MIN_TERRAFORM_VERSION:-1.10.0}"

usage() {
  cat <<'EOF'
Usage:
  check-tools.sh [options]

Options:
  --env-file <path>              Use a non-default .env file.
  --min-terraform-version <ver>  Required Terraform version (default: 1.10.0).
  -h, --help                     Show this help.

Environment:
  ENV_FILE                       Default env file path.
  MIN_TERRAFORM_VERSION          Default minimum Terraform version.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --env-file requires a value." >&2
        exit 1
      fi
      ENV_FILE="$2"
      shift 2
      ;;
    --min-terraform-version)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --min-terraform-version requires a value." >&2
        exit 1
      fi
      MIN_TERRAFORM_VERSION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      echo "Error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ $# -gt 0 ]]; then
  echo "Error: unexpected positional arguments: $*" >&2
  usage >&2
  exit 1
fi

PASS=0
WARN=0
FAIL=0

log_ok() {
  PASS=$((PASS + 1))
  printf '[OK] %s\n' "$*"
}

log_warn() {
  WARN=$((WARN + 1))
  printf '[WARN] %s\n' "$*"
}

log_fail() {
  FAIL=$((FAIL + 1))
  printf '[FAIL] %s\n' "$*"
}

ver_to_int() {
  local ver="$1"
  local major minor patch
  IFS='.' read -r major minor patch <<< "${ver}"
  major="${major:-0}"
  minor="${minor:-0}"
  patch="${patch:-0}"
  printf '%03d%03d%03d\n' "${major}" "${minor}" "${patch}"
}

extract_semver() {
  # Extract first x.y.z from input.
  sed -n 's/.*\([0-9]\+\.[0-9]\+\.[0-9]\+\).*/\1/p' | head -n 1
}

check_cmd() {
  local cmd="$1"
  if command -v "${cmd}" >/dev/null 2>&1; then
    log_ok "Found command: ${cmd} ($(command -v "${cmd}"))"
  else
    log_fail "Missing command: ${cmd}"
  fi
}

read_env_value() {
  local key="$1"
  local file="$2"
  local current="${!key:-}"
  if [[ -n "${current}" ]]; then
    printf '%s\n' "${current}"
    return 0
  fi
  [[ -f "${file}" ]] || return 0
  awk -F= -v k="${key}" '$1==k { sub(/^[^=]*=/, "", $0); print $0; exit }' "${file}"
}

printf 'Checking local toolchain and Vault/Packer/Terraform readiness...\n'

# Required commands.
check_cmd terraform
check_cmd packer
check_cmd vault
check_cmd ssh
check_cmd scp
check_cmd tflint
check_cmd tfsec

# Optional command.
if command -v jq >/dev/null 2>&1; then
  log_ok "Optional command found: jq"
else
  log_warn "Optional command missing: jq (needed for easier init/unseal key parsing)"
fi

# Terraform version gate.
if command -v terraform >/dev/null 2>&1; then
  tf_version="$(terraform version 2>/dev/null | head -n 1 | extract_semver || true)"
  if [[ -n "${tf_version}" ]]; then
    if [[ "$(ver_to_int "${tf_version}")" -ge "$(ver_to_int "${MIN_TERRAFORM_VERSION}")" ]]; then
      log_ok "Terraform version ${tf_version} satisfies minimum ${MIN_TERRAFORM_VERSION}"
    else
      log_fail "Terraform version ${tf_version} is below required ${MIN_TERRAFORM_VERSION}"
    fi
  else
    log_fail "Unable to determine Terraform version"
  fi
fi

# Validate key scripts exist.
for script in \
  "${REPO_ROOT}/scripts/vault-auth.sh" \
  "${REPO_ROOT}/scripts/vault-mode-switch.sh" \
  "${REPO_ROOT}/scripts/vault-regenerate-tls.sh" \
  "${REPO_ROOT}/scripts/vault-reinit.sh" \
  "${REPO_ROOT}/scripts/render-packer-vault-vars.sh" \
  "${REPO_ROOT}/scripts/rotate-proxmox-creds.sh" \
  "${REPO_ROOT}/scripts/with-vault-token.sh" \
  "${REPO_ROOT}/scripts/resolve-ansible-host.sh" \
  "${REPO_ROOT}/scripts/discover-proxmox-core.sh" \
  "${REPO_ROOT}/scripts/scaffold-env.sh" \
  "${REPO_ROOT}/scripts/setup-proxmox-root-ssh.sh" \
  "${REPO_ROOT}/scripts/create-base-vm-remote.sh"; do
  if [[ -x "${script}" ]]; then
    log_ok "Script is executable: ${script}"
  elif [[ -f "${script}" ]]; then
    log_warn "Script exists but is not executable: ${script}"
  else
    log_fail "Required script is missing: ${script}"
  fi
done

# Validate .env presence and key vars.
if [[ -f "${ENV_FILE}" ]]; then
  log_ok "Environment file found: ${ENV_FILE}"
  env_perms="$(stat -c '%a' "${ENV_FILE}" 2>/dev/null || stat -f '%Lp' "${ENV_FILE}" 2>/dev/null || echo '')"
  if [[ "${env_perms}" == "600" || "${env_perms}" == "400" ]]; then
    log_ok "${ENV_FILE} permissions are restricted (${env_perms})"
  elif [[ -n "${env_perms}" ]]; then
    log_fail "${ENV_FILE} permissions are too open (${env_perms}); run: chmod 600 ${ENV_FILE}"
  else
    log_warn "Could not determine permissions for ${ENV_FILE}"
  fi

  vault_addr="$(read_env_value VAULT_ADDR "${ENV_FILE}")"
  vault_token="$(read_env_value VAULT_TOKEN "${ENV_FILE}")"
  vault_role_id="$(read_env_value VAULT_ROLE_ID "${ENV_FILE}")"
  vault_secret_id="$(read_env_value VAULT_SECRET_ID "${ENV_FILE}")"
  vault_token_file="$(read_env_value VAULT_TOKEN_FILE "${ENV_FILE}")"
  if [[ -z "${vault_token_file}" ]]; then
    vault_token_file="${REPO_ROOT}/.vault-token"
  fi
  tf_vault_addr="$(read_env_value TF_VAR_vault_address "${ENV_FILE}")"
  packer_use_vault="$(read_env_value PACKER_USE_VAULT_CREDS "${ENV_FILE}")"
  auto_tfvars_file="${REPO_ROOT}/secrets.auto.tfvars"
  auto_tfvars_token=""
  auto_tfvars_addr=""

  if [[ -n "${vault_addr}" ]]; then
    log_ok "VAULT_ADDR is set in ${ENV_FILE}"
  else
    log_fail "VAULT_ADDR is not set in ${ENV_FILE}"
  fi

  if [[ -n "${vault_token}" ]]; then
    log_ok "VAULT_TOKEN is set in ${ENV_FILE}"
  elif [[ -n "${vault_role_id}" && -n "${vault_secret_id}" ]]; then
    log_ok "AppRole credentials are set in ${ENV_FILE} (VAULT_ROLE_ID + VAULT_SECRET_ID)"
  elif [[ -s "${vault_token_file}" ]]; then
    log_ok "Vault token cache file exists: ${vault_token_file}"
  else
    log_fail "No Vault auth source found (VAULT_TOKEN, AppRole, or token file)."
  fi

  if [[ -s "${vault_token_file}" ]]; then
    token_file_perms="$(stat -c '%a' "${vault_token_file}" 2>/dev/null || stat -f '%Lp' "${vault_token_file}" 2>/dev/null || echo '')"
    if [[ "${token_file_perms}" == "600" || "${token_file_perms}" == "400" ]]; then
      log_ok "Vault token cache permissions are restricted (${token_file_perms})"
    elif [[ -n "${token_file_perms}" ]]; then
      log_fail "Vault token cache permissions are too open (${token_file_perms}); run: chmod 600 ${vault_token_file}"
    fi
  fi

  if [[ -n "${tf_vault_addr}" ]]; then
    log_ok "TF_VAR_vault_address is set in ${ENV_FILE}"
  else
    log_warn "TF_VAR_vault_address is not set in ${ENV_FILE} (Terraform can still use secrets.auto.tfvars)"
  fi

  if [[ "${packer_use_vault,,}" == "true" ]]; then
    log_ok "PACKER_USE_VAULT_CREDS=true (credential rotation-ready)"
  elif [[ -z "${packer_use_vault}" ]]; then
    log_warn "PACKER_USE_VAULT_CREDS not set; Makefile default is true"
  else
    log_warn "PACKER_USE_VAULT_CREDS=${packer_use_vault} (Packer will not auto-hydrate rotated Vault credentials)"
  fi

  if [[ -f "${auto_tfvars_file}" ]]; then
    auto_tfvars_token="$(sed -n 's/^[[:space:]]*vault_token[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "${auto_tfvars_file}" | head -n1)"
    auto_tfvars_addr="$(sed -n 's/^[[:space:]]*vault_address[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "${auto_tfvars_file}" | head -n1)"

    if [[ -n "${auto_tfvars_token}" ]]; then
      log_warn "secrets.auto.tfvars sets vault_token and overrides TF_VAR_vault_token/.env during terraform plan/apply."
      if [[ -n "${vault_token}" && "${auto_tfvars_token}" != "${vault_token}" ]]; then
        log_warn "vault_token in secrets.auto.tfvars differs from VAULT_TOKEN in ${ENV_FILE}."
      fi
    fi
    if [[ -n "${auto_tfvars_addr}" && -n "${tf_vault_addr}" && "${auto_tfvars_addr}" != "${tf_vault_addr}" ]]; then
      log_warn "vault_address in secrets.auto.tfvars differs from TF_VAR_vault_address in ${ENV_FILE}."
    fi
  fi
else
  log_warn "Environment file not found: ${ENV_FILE}. Create it from .env.example."
fi

# Terraform + Packer syntax checks.
if command -v terraform >/dev/null 2>&1; then
  if terraform -chdir="${REPO_ROOT}" fmt -check -recursive >/dev/null 2>&1; then
    log_ok "Terraform formatting check passed"
  else
    log_warn "Terraform formatting differs from terraform fmt output"
  fi
fi

if command -v packer >/dev/null 2>&1; then
  for tpl in \
    "${REPO_ROOT}/packer/ubuntu-noble/ubuntu-noble.pkr.hcl" \
    "${REPO_ROOT}/packer/oracle8/oracle8.pkr.hcl" \
    "${REPO_ROOT}/packer/oracle9/oracle9.pkr.hcl"; do
    if packer validate -syntax-only "${tpl}" >/dev/null 2>&1; then
      log_ok "Packer syntax check passed: ${tpl##${REPO_ROOT}/}"
    else
      log_fail "Packer syntax check failed: ${tpl##${REPO_ROOT}/}"
    fi
  done
fi

printf '\nSummary: %d ok, %d warnings, %d failed\n' "${PASS}" "${WARN}" "${FAIL}"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
