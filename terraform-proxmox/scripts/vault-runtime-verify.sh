#!/usr/bin/env bash
# Verify day-to-day Vault AppRole access without using an admin token.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

ENVIRONMENT="${ENVIRONMENT:-dev}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"
TFVARS_FILE="${TFVARS_FILE:-${REPO_ROOT}/environments/${ENVIRONMENT}.tfvars}"
VAULT_PATH="${VAULT_PATH:-}"
RUN_TERRAFORM_PLAN="${RUN_TERRAFORM_PLAN:-true}"
PLAN_FILE="${PLAN_FILE:-/tmp/iac-vault-runtime-${ENVIRONMENT}.$$}.tfplan"

usage() {
  cat <<'EOF'
Usage:
  vault-runtime-verify.sh [options]

Options:
  --environment <env>       Environment name (default: ENVIRONMENT or dev).
  --tfvars <path>           Terraform tfvars file.
  --vault-path <path>       Explicit KV path to Proxmox creds.
  --skip-terraform-plan     Skip the AppRole-backed Terraform plan check.
  -h, --help                Show this help.

Purpose:
  Verifies that AppRole can log in, read the environment Proxmox credential
  secret, render Packer credentials, and optionally run a Terraform plan with
  manage_vault_access=false.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --environment)
      ENVIRONMENT="$2"
      TFVARS_FILE="${REPO_ROOT}/environments/${ENVIRONMENT}.tfvars"
      shift 2
      ;;
    --tfvars)
      TFVARS_FILE="$2"
      shift 2
      ;;
    --vault-path)
      VAULT_PATH="$2"
      shift 2
      ;;
    --skip-terraform-plan)
      RUN_TERRAFORM_PLAN=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Error: required command not found: ${cmd}" >&2
    exit 1
  fi
}

trim_slashes() {
  local value="$1"
  value="${value#/}"
  value="${value%/}"
  printf '%s\n' "${value}"
}

read_tfvars_value() {
  local key="$1"
  local file="$2"

  [[ -f "${file}" ]] || return 1
  awk -F= -v k="${key}" '
    $1 ~ "^[[:space:]]*" k "[[:space:]]*$" {
      value = $2
      sub(/[[:space:]]*(\/\/|#).*/, "", value)
      sub(/[[:space:]]*\/\*.*\*\/[[:space:]]*$/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      sub(/^"/, "", value)
      sub(/"$/, "", value)
      print value
      exit
    }
  ' "${file}"
}

is_true() {
  local v="${1:-}"
  [[ "${v,,}" == "true" || "${v}" == "1" || "${v,,}" == "yes" ]]
}

ensure_vault_tls_env() {
  local candidate

  if [[ "${VAULT_ADDR:-}" != https://* ]]; then
    return 0
  fi

  if [[ -n "${VAULT_CACERT:-}" && ! -r "${VAULT_CACERT}" ]]; then
    if is_true "${VAULT_SKIP_VERIFY:-}"; then
      echo "Warning: VAULT_CACERT is unreadable (${VAULT_CACERT}); continuing with VAULT_SKIP_VERIFY=${VAULT_SKIP_VERIFY}." >&2
      unset VAULT_CACERT
    else
      echo "Error: VAULT_CACERT is unreadable: ${VAULT_CACERT}" >&2
      exit 1
    fi
  fi

  if [[ -z "${VAULT_CACERT:-}" ]] && ! is_true "${VAULT_SKIP_VERIFY:-}"; then
    for candidate in /etc/vault.d/vault-cert.pem /etc/vault.d/tls/vault-cert.pem; do
      if [[ -r "${candidate}" ]]; then
        export VAULT_CACERT="${candidate}"
        break
      fi
    done
  fi
}

require_cmd vault
require_cmd terraform

if [[ ! -f "${TFVARS_FILE}" ]]; then
  echo "Error: tfvars file not found: ${TFVARS_FILE}" >&2
  exit 1
fi

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  set -a
  source "${ENV_FILE}"
  set +a
fi

if [[ -z "${VAULT_ADDR:-}" ]]; then
  echo "Error: VAULT_ADDR is not set." >&2
  exit 1
fi
if [[ -z "${VAULT_ROLE_ID:-}" || -z "${VAULT_SECRET_ID:-}" ]]; then
  echo "Error: VAULT_ROLE_ID and VAULT_SECRET_ID are required for runtime AppRole verification." >&2
  exit 1
fi

ensure_vault_tls_env

kv_mount="$(trim_slashes "$(read_tfvars_value "vault_kv_mount_path" "${TFVARS_FILE}" || true)")"
secret_prefix="$(trim_slashes "$(read_tfvars_value "vault_secret_prefix" "${TFVARS_FILE}" || true)")"
kv_mount="${kv_mount:-secret}"
secret_prefix="${secret_prefix:-terraform}"
if [[ -z "${VAULT_PATH}" ]]; then
  VAULT_PATH="${kv_mount}/${secret_prefix}/${ENVIRONMENT}/creds"
fi

echo "Verifying Vault AppRole runtime access for ${ENVIRONMENT}..."
runtime_token="$(env -u VAULT_TOKEN -u TF_VAR_vault_token vault write -field=token auth/approle/login role_id="${VAULT_ROLE_ID}" secret_id="${VAULT_SECRET_ID}")"
if [[ -z "${runtime_token}" ]]; then
  echo "Error: AppRole login returned an empty token." >&2
  exit 1
fi
echo "AppRole login: ok"

VAULT_TOKEN="${runtime_token}" vault token lookup >/dev/null
echo "Runtime token lookup: ok"

api_url="$(VAULT_TOKEN="${runtime_token}" vault kv get -field=proxmox_config_api_url "${VAULT_PATH}")"
VAULT_TOKEN="${runtime_token}" vault kv get -field=proxmox_config_api_token_id "${VAULT_PATH}" >/dev/null
VAULT_TOKEN="${runtime_token}" vault kv get -field=proxmox_config_api_token_secret "${VAULT_PATH}" >/dev/null
VAULT_TOKEN="${runtime_token}" vault kv get -field=proxmox_config_tls_insecure "${VAULT_PATH}" >/dev/null
echo "Vault credential read: ok (${VAULT_PATH}, host=$(printf '%s' "${api_url}" | sed -E 's#^https?://##; s#[:/].*$##'))"

tmp_packer_vars="$(mktemp --suffix=.pkrvars.hcl)"
trap 'rm -f "${tmp_packer_vars}" "${PLAN_FILE}"' EXIT
VAULT_TOKEN="${runtime_token}" "${REPO_ROOT}/scripts/render-packer-vault-vars.sh" --vault-path "${VAULT_PATH}" --output "${tmp_packer_vars}" >/dev/null
if [[ "$(stat -c '%a' "${tmp_packer_vars}" 2>/dev/null || stat -f '%Lp' "${tmp_packer_vars}" 2>/dev/null)" != "600" ]]; then
  echo "Error: rendered Packer Vault vars are not mode 600." >&2
  exit 1
fi
echo "Packer Vault render: ok"

if [[ "${RUN_TERRAFORM_PLAN}" == "true" ]]; then
  echo "Terraform AppRole runtime plan: starting"
  (
    cd "${REPO_ROOT}"
    env -u VAULT_TOKEN -u TF_VAR_vault_token \
      TF_VAR_vault_role_id="${VAULT_ROLE_ID}" \
      TF_VAR_vault_secret_id="${VAULT_SECRET_ID}" \
      terraform plan \
      -refresh=false \
      -target=module.proxmox_vms \
      -var-file="${TFVARS_FILE}" \
      -var="vault_auth_mode=approle" \
      -var="manage_vault_access=false" \
      -out="${PLAN_FILE}" \
      -input=false \
      -no-color >/dev/null
  )
  echo "Terraform AppRole runtime plan: ok"
fi

echo "Vault runtime verification completed for ${ENVIRONMENT}."
