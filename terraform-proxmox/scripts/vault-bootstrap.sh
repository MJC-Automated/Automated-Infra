#!/usr/bin/env bash
# Bootstrap Vault resources required by Terraform Proxmox runs.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

ENVIRONMENT="${ENVIRONMENT:-${1:-dev}}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"
TFVARS_FILE="${TFVARS_FILE:-${REPO_ROOT}/environments/${ENVIRONMENT}.tfvars}"
VAULT_AUTH_SCRIPT="${VAULT_AUTH_SCRIPT:-${REPO_ROOT}/scripts/vault-auth.sh}"
ROTATE_PROXMOX_CREDS_SCRIPT="${ROTATE_PROXMOX_CREDS_SCRIPT:-${REPO_ROOT}/scripts/rotate-proxmox-creds.sh}"
RESOLVE_PROXMOX_HOST_SCRIPT="${RESOLVE_PROXMOX_HOST_SCRIPT:-${REPO_ROOT}/scripts/resolve-proxmox-host.sh}"
VAULT_APPROLE_NAME="${VAULT_APPROLE_NAME:-terraform-proxmox}"
VAULT_POLICY_NAME="${VAULT_POLICY_NAME:-${VAULT_APPROLE_NAME}}"
VAULT_PATH="${VAULT_PATH:-}"
VAULT_KV_MOUNT_PATH="${VAULT_KV_MOUNT_PATH:-}"
VAULT_SECRET_PREFIX="${VAULT_SECRET_PREFIX:-}"
VAULT_MANAGE_KV_MOUNT="${VAULT_MANAGE_KV_MOUNT:-}"
PROXMOX_HOST="${PROXMOX_HOST:-}"
PROXMOX_USER="${PROXMOX_USER:-root}"

usage() {
  cat <<'EOF'
Usage:
  vault-bootstrap.sh [environment]

Purpose:
  1) Recreate Vault governance resources (KV mount, policy, AppRole backend/role)
  2) Refresh AppRole role_id/secret_id in .env
  3) Rotate Proxmox API credentials into Vault for the environment
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Error: required command not found: ${cmd}" >&2
    exit 1
  fi
}

upsert_env_key() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp

  tmp="$(mktemp)"
  if [[ -f "${file}" ]]; then
    awk -v k="${key}" -v v="${value}" '
      BEGIN { done=0 }
      $0 ~ "^[[:space:]]*" k "=" {
        print k "=" v
        done=1
        next
      }
      { print }
      END {
        if (done == 0) {
          print k "=" v
        }
      }
    ' "${file}" > "${tmp}"
  else
    printf '%s=%s\n' "${key}" "${value}" > "${tmp}"
  fi
  mv "${tmp}" "${file}"
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

normalize_bool() {
  local value
  value="$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "${value}" in
    1|true|yes|on) printf 'true\n' ;;
    0|false|no|off) printf 'false\n' ;;
    *) printf '\n' ;;
  esac
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

terraform_state_has() {
  local address="$1"
  terraform state show "${address}" >/dev/null 2>&1
}

vault_mount_exists() {
  local path="$1"
  vault secrets list -format=json | jq -e --arg p "${path}/" 'has($p)' >/dev/null
}

vault_auth_backend_exists() {
  local path="$1"
  vault auth list -format=json | jq -e --arg p "${path}/" 'has($p)' >/dev/null
}

vault_approle_role_exists() {
  local role_name="$1"
  vault read -format=json "auth/approle/role/${role_name}" >/dev/null 2>&1
}

import_if_missing() {
  local address="$1"
  local import_id="$2"
  if terraform_state_has "${address}"; then
    return 0
  fi
  terraform import -var-file="${TFVARS_FILE}" "${address}" "${import_id}" >/dev/null
}

resolve_proxmox_host() {
  if [[ -n "${PROXMOX_HOST}" ]]; then
    return 0
  fi

  if [[ -x "${RESOLVE_PROXMOX_HOST_SCRIPT}" ]]; then
    PROXMOX_HOST="$(ENVIRONMENT="${ENVIRONMENT}" REPO_ROOT="${REPO_ROOT}" ENV_FILE="${ENV_FILE}" "${RESOLVE_PROXMOX_HOST_SCRIPT}" 2>/dev/null || true)"
  fi
}

token_has_any_capability() {
  local path="$1"
  shift
  local output normalized cap

  output="$(vault token capabilities "${path}" 2>/dev/null || true)"
  normalized="$(printf '%s\n' "${output}" | tr '[:upper:],\n\t' '[:lower:]   ')"

  [[ -n "${normalized// }" ]] || return 1
  for cap in "$@"; do
    if grep -Eq "(^|[[:space:]])${cap}([[:space:]]|$)" <<< "${normalized}"; then
      return 0
    fi
  done
  return 1
}

require_admin_token() {
  local missing=0
  local mount_capability_path policy_capability_path auth_capability_path

  mount_capability_path="sys/mounts/${VAULT_KV_MOUNT_PATH}"
  policy_capability_path="sys/policies/acl/${VAULT_POLICY_NAME}"
  auth_capability_path="sys/auth/approle"

  if [[ "${VAULT_MANAGE_KV_MOUNT}" == "true" ]]; then
    if ! token_has_any_capability "${mount_capability_path}" root sudo create update; then
      echo "Error: current Vault token lacks required capability for ${mount_capability_path} (need one of: root/sudo/create/update)." >&2
      missing=1
    fi
  fi
  if ! token_has_any_capability "${policy_capability_path}" root sudo create update; then
    echo "Error: current Vault token lacks required capability for ${policy_capability_path} (need one of: root/sudo/create/update)." >&2
    missing=1
  fi
  if ! token_has_any_capability "${auth_capability_path}" root sudo create update; then
    echo "Error: current Vault token lacks required capability for ${auth_capability_path} (need one of: root/sudo/create/update)." >&2
    missing=1
  fi

  if [[ "${missing}" -ne 0 ]]; then
    cat >&2 <<'EOF'
vault-bootstrap requires an admin-capable Vault token to manage governance resources.
Provide a privileged token via VAULT_TOKEN (and optionally TF_VAR_vault_token),
or refresh .env/token cache with an admin token, then rerun.
EOF
    exit 1
  fi
}

require_cmd terraform
require_cmd vault
require_cmd awk
require_cmd jq

if [[ ! -f "${TFVARS_FILE}" ]]; then
  echo "Error: tfvars file not found: ${TFVARS_FILE}" >&2
  exit 1
fi

explicit_vault_token="${VAULT_TOKEN:-}"
explicit_tf_vault_token="${TF_VAR_vault_token:-}"
if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi
if [[ -n "${explicit_vault_token}" ]]; then
  VAULT_TOKEN="${explicit_vault_token}"
fi
if [[ -n "${explicit_tf_vault_token}" ]]; then
  TF_VAR_vault_token="${explicit_tf_vault_token}"
fi
unset explicit_vault_token explicit_tf_vault_token

ensure_vault_tls_env

if [[ ! -x "${VAULT_AUTH_SCRIPT}" ]]; then
  echo "Error: vault-auth helper is not executable: ${VAULT_AUTH_SCRIPT}" >&2
  exit 1
fi
if [[ ! -x "${ROTATE_PROXMOX_CREDS_SCRIPT}" ]]; then
  echo "Error: rotate-proxmox-creds helper is not executable: ${ROTATE_PROXMOX_CREDS_SCRIPT}" >&2
  exit 1
fi

cd "${REPO_ROOT}"

if [[ -z "${VAULT_KV_MOUNT_PATH}" ]]; then
  VAULT_KV_MOUNT_PATH="$(read_tfvars_value "vault_kv_mount_path" "${TFVARS_FILE}" || true)"
fi
if [[ -z "${VAULT_SECRET_PREFIX}" ]]; then
  VAULT_SECRET_PREFIX="$(read_tfvars_value "vault_secret_prefix" "${TFVARS_FILE}" || true)"
fi
VAULT_KV_MOUNT_PATH="$(trim_slashes "${VAULT_KV_MOUNT_PATH:-secret}")"
VAULT_SECRET_PREFIX="$(trim_slashes "${VAULT_SECRET_PREFIX:-terraform}")"
if [[ -z "${VAULT_PATH}" ]]; then
  VAULT_PATH="${VAULT_KV_MOUNT_PATH}/${VAULT_SECRET_PREFIX}/${ENVIRONMENT}/creds"
fi

VAULT_MANAGE_KV_MOUNT="$(normalize_bool "${VAULT_MANAGE_KV_MOUNT}")"
if [[ -z "${VAULT_MANAGE_KV_MOUNT}" ]]; then
  VAULT_MANAGE_KV_MOUNT="$(normalize_bool "$(read_tfvars_value "vault_manage_kv_mount" "${TFVARS_FILE}" || true)")"
fi
VAULT_MANAGE_KV_MOUNT="${VAULT_MANAGE_KV_MOUNT:-true}"

echo "Resolving Vault token..."
vault_token="$("${VAULT_AUTH_SCRIPT}" --print-token --validate)"
export VAULT_TOKEN="${vault_token}"
export TF_VAR_vault_token="${vault_token}"
require_admin_token

resolve_proxmox_host

if [[ "${VAULT_MANAGE_KV_MOUNT}" == "true" ]] && vault_mount_exists "${VAULT_KV_MOUNT_PATH}"; then
  echo "Importing existing Vault KV mount/config state when missing..."
  import_if_missing "module.vault_proxmox_access[0].vault_mount.kv[0]" "${VAULT_KV_MOUNT_PATH}"
  import_if_missing "module.vault_proxmox_access[0].vault_kv_secret_backend_v2.kv_config" "${VAULT_KV_MOUNT_PATH}/config"
fi

if vault_auth_backend_exists "approle"; then
  echo "Importing existing Vault AppRole backend state when missing..."
  import_if_missing "module.vault_proxmox_access[0].vault_auth_backend.approle" "approle"
fi

if vault_approle_role_exists "${VAULT_APPROLE_NAME}"; then
  echo "Importing existing Vault AppRole role state when missing..."
  import_if_missing "module.vault_proxmox_access[0].vault_approle_auth_backend_role.terraform" "auth/approle/role/${VAULT_APPROLE_NAME}"
fi

echo "Applying Vault governance module for ${ENVIRONMENT}..."
terraform apply \
  -var-file="${TFVARS_FILE}" \
  -target="module.vault_proxmox_access[0]" \
  -auto-approve

echo "Refreshing AppRole credentials for role ${VAULT_APPROLE_NAME}..."
role_id="$(vault read -field=role_id "auth/approle/role/${VAULT_APPROLE_NAME}/role-id")"
secret_id="$(vault write -f -field=secret_id "auth/approle/role/${VAULT_APPROLE_NAME}/secret-id")"

if [[ ! -f "${ENV_FILE}" ]]; then
  umask 077
  : > "${ENV_FILE}"
fi
upsert_env_key "${ENV_FILE}" "VAULT_ROLE_ID" "${role_id}"
upsert_env_key "${ENV_FILE}" "VAULT_SECRET_ID" "${secret_id}"
upsert_env_key "${ENV_FILE}" "TF_VAR_vault_role_id" "${role_id}"
upsert_env_key "${ENV_FILE}" "TF_VAR_vault_secret_id" "${secret_id}"
chmod 600 "${ENV_FILE}"

export VAULT_ROLE_ID="${role_id}"
export VAULT_SECRET_ID="${secret_id}"
export TF_VAR_vault_role_id="${role_id}"
export TF_VAR_vault_secret_id="${secret_id}"

echo "Rotating Proxmox API credentials into Vault for ${ENVIRONMENT}..."
env ENVIRONMENT="${ENVIRONMENT}" TFVARS_FILE="${TFVARS_FILE}" PROXMOX_HOST="${PROXMOX_HOST}" PROXMOX_USER="${PROXMOX_USER}" VAULT_PATH="${VAULT_PATH}" "${ROTATE_PROXMOX_CREDS_SCRIPT}" "${ENVIRONMENT}"

echo "Vault bootstrap completed for ${ENVIRONMENT}."
