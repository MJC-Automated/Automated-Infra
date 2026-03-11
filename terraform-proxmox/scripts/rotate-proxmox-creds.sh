#!/usr/bin/env bash
# Rotate Proxmox API credentials and update Vault in one step.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

ENVIRONMENT="${ENVIRONMENT:-${1:-dev}}"
PROXMOX_USER="${PROXMOX_USER:-root}"
PROXMOX_HOST="${PROXMOX_HOST:-}"
TFVARS_FILE="${TFVARS_FILE:-${REPO_ROOT}/environments/${ENVIRONMENT}.tfvars}"
VAULT_PATH="${VAULT_PATH:-}"
VAULT_KV_MOUNT_PATH="${VAULT_KV_MOUNT_PATH:-}"
VAULT_SECRET_PREFIX="${VAULT_SECRET_PREFIX:-}"
REMOTE_SCRIPT_PATH="${REMOTE_SCRIPT_PATH:-/tmp/create-proxmox-api-user.sh}"
PASSWORD="${PROXMOX_API_USER_PASSWORD:-}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-10}"
REMOTE_EXEC_TIMEOUT_SEC="${REMOTE_EXEC_TIMEOUT_SEC:-180}"
SSH_OPTIONS_RAW="${SSH_OPTIONS:-}"
SSH_OPTS_DEFAULT=(-o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" -o ServerAliveInterval=15 -o ServerAliveCountMax=3)
SSH_OPTS=()
DEBUG_REMOTE_OUTPUT="${DEBUG_REMOTE_OUTPUT:-false}"

usage() {
  cat <<'EOF'
Usage:
  rotate-proxmox-creds.sh [environment]

Environment variables:
  ENVIRONMENT               Environment name (default: dev)
  PROXMOX_HOST              Proxmox host/IP (required if not in .env)
  PROXMOX_USER              SSH user (default: root)
  PROXMOX_API_USER_PASSWORD Optional password passed to create-proxmox-api-user.sh
  TFVARS_FILE               Path to environment tfvars (default: environments/<env>.tfvars)
  VAULT_KV_MOUNT_PATH       Optional KV mount override (default: from tfvars or 'secret')
  VAULT_SECRET_PREFIX       Optional secret prefix override (default: from tfvars or 'terraform')
  VAULT_PATH                Vault KV path (default: <mount>/<prefix>/<env>/creds)
  REMOTE_SCRIPT_PATH        Remote path for helper script (default: /tmp/create-proxmox-api-user.sh)
  SSH_CONNECT_TIMEOUT       SSH connect timeout seconds (default: 10)
  REMOTE_EXEC_TIMEOUT_SEC   Remote command timeout seconds (default: 180)
  SSH_OPTIONS               Extra ssh/scp options (default: -o StrictHostKeyChecking=accept-new)
  DEBUG_REMOTE_OUTPUT       true/false. Print redacted remote output on failure (default: false)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -n "${SSH_OPTIONS_RAW}" ]]; then
  # Handle values coming from .env/Makefile with surrounding quotes.
  case "${SSH_OPTIONS_RAW}" in
    \"*\") SSH_OPTIONS_RAW="${SSH_OPTIONS_RAW#\"}"; SSH_OPTIONS_RAW="${SSH_OPTIONS_RAW%\"}" ;;
    \'*\') SSH_OPTIONS_RAW="${SSH_OPTIONS_RAW#\'}"; SSH_OPTIONS_RAW="${SSH_OPTIONS_RAW%\'}" ;;
  esac
  # shellcheck disable=SC2206
  SSH_OPTS=(${SSH_OPTIONS_RAW})
else
  SSH_OPTS=("${SSH_OPTS_DEFAULT[@]}")
fi

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Error: required command not found: ${cmd}" >&2
    exit 1
  fi
}

require_cmd ssh
require_cmd scp
require_cmd vault
require_cmd jq

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

redact_remote_output() {
  sed -E \
    -e 's/("proxmox_config_api_token_secret"[[:space:]]*:[[:space:]]*")[^"]+/\1***REDACTED***/g' \
    -e 's/("value"[[:space:]]*:[[:space:]]*")[^"]+/\1***REDACTED***/g' \
    -e 's/(proxmox_config_api_token_secret=)[^[:space:]]+/\1***REDACTED***/g'
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

resolve_proxmox_host() {
  if [[ -n "${PROXMOX_HOST}" ]]; then
    printf '%s\n' "${PROXMOX_HOST}"
    return 0
  fi

  if [[ -f "${REPO_ROOT}/.env" ]]; then
    local host
    host="$(sed -n 's/^PROXMOX_HOST=//p' "${REPO_ROOT}/.env" | head -n 1)"
    if [[ -n "${host}" ]]; then
      printf '%s\n' "${host}"
      return 0
    fi

    local env_key
    env_key="$(echo "${ENVIRONMENT}" | tr '[:lower:]' '[:upper:]')"
    host="$(sed -n "s/^PROXMOX_HOST_${env_key}=//p" "${REPO_ROOT}/.env" | head -n 1)"
    if [[ -n "${host}" ]]; then
      printf '%s\n' "${host}"
      return 0
    fi
  fi

  return 1
}

if [[ -z "${VAULT_ADDR:-}" ]]; then
  echo "Error: VAULT_ADDR is not set." >&2
  exit 1
fi

ensure_vault_tls_env

if [[ -z "${VAULT_TOKEN:-}" ]]; then
  VAULT_TOKEN="$("${SCRIPT_DIR}/vault-auth.sh" --print-token)"
  export VAULT_TOKEN
fi

if [[ -z "${PROXMOX_HOST}" ]]; then
  PROXMOX_HOST="$(resolve_proxmox_host || true)"
fi
if [[ -z "${PROXMOX_HOST}" ]]; then
  echo "Error: PROXMOX_HOST is not set and could not be resolved from .env." >&2
  exit 1
fi

if [[ -z "${VAULT_PATH}" ]]; then
  if [[ -z "${VAULT_KV_MOUNT_PATH}" ]]; then
    VAULT_KV_MOUNT_PATH="$(read_tfvars_value "vault_kv_mount_path" "${TFVARS_FILE}" || true)"
  fi
  if [[ -z "${VAULT_SECRET_PREFIX}" ]]; then
    VAULT_SECRET_PREFIX="$(read_tfvars_value "vault_secret_prefix" "${TFVARS_FILE}" || true)"
  fi

  VAULT_KV_MOUNT_PATH="$(trim_slashes "${VAULT_KV_MOUNT_PATH:-secret}")"
  VAULT_SECRET_PREFIX="$(trim_slashes "${VAULT_SECRET_PREFIX:-terraform}")"
  VAULT_PATH="${VAULT_KV_MOUNT_PATH}/${VAULT_SECRET_PREFIX}/${ENVIRONMENT}/creds"
fi

echo "Rotating Proxmox API credentials on ${PROXMOX_USER}@${PROXMOX_HOST}..."

scp "${SSH_OPTS[@]}" "${SCRIPT_DIR}/create-proxmox-api-user.sh" "${PROXMOX_USER}@${PROXMOX_HOST}:${REMOTE_SCRIPT_PATH}"

remote_cmd="bash '${REMOTE_SCRIPT_PATH}' --json"
if [[ -n "${PASSWORD}" ]]; then
  pw_escaped="$(printf "%q" "${PASSWORD}")"
  remote_cmd="PROXMOX_API_USER_PASSWORD=${pw_escaped} ${remote_cmd}"
fi

echo "Executing remote Proxmox credential helper (this can take ~10-60s)..."
tmp_remote_log="$(mktemp)"
set +e
if command -v timeout >/dev/null 2>&1; then
  timeout "${REMOTE_EXEC_TIMEOUT_SEC}s" ssh "${SSH_OPTS[@]}" "${PROXMOX_USER}@${PROXMOX_HOST}" "${remote_cmd}" > "${tmp_remote_log}" 2>&1
  rc=$?
else
  ssh "${SSH_OPTS[@]}" "${PROXMOX_USER}@${PROXMOX_HOST}" "${remote_cmd}" > "${tmp_remote_log}" 2>&1
  rc=$?
fi
set -e

json_output="$(cat "${tmp_remote_log}")"
rm -f "${tmp_remote_log}"

if [[ ${rc} -ne 0 ]]; then
  if [[ ${rc} -eq 124 ]]; then
    echo "Error: remote credential helper timed out after ${REMOTE_EXEC_TIMEOUT_SEC}s." >&2
  else
    echo "Error: remote credential helper failed with exit code ${rc}." >&2
  fi
  if [[ "${DEBUG_REMOTE_OUTPUT}" == "true" ]]; then
    echo "Remote output (redacted):" >&2
    printf '%s\n' "${json_output}" | redact_remote_output >&2
  fi
  exit 1
fi

# Remote helper may emit informational logs before JSON. Extract the last JSON object line.
json_payload="$(printf '%s\n' "${json_output}" | awk '/^[[:space:]]*\{.*\}[[:space:]]*$/ {line=$0} END{print line}')"

if [[ -z "${json_payload}" ]]; then
  echo "Error: remote credential rotation did not return valid JSON." >&2
  if [[ "${DEBUG_REMOTE_OUTPUT}" == "true" ]]; then
    echo "Remote output (redacted):" >&2
    printf '%s\n' "${json_output}" | redact_remote_output >&2
  fi
  exit 1
fi

if ! echo "${json_payload}" | jq -e . >/dev/null 2>&1; then
  echo "Error: extracted JSON payload is invalid." >&2
  if [[ "${DEBUG_REMOTE_OUTPUT}" == "true" ]]; then
    echo "Payload (redacted):" >&2
    printf '%s\n' "${json_payload}" | redact_remote_output >&2
    echo "Full remote output (redacted):" >&2
    printf '%s\n' "${json_output}" | redact_remote_output >&2
  fi
  exit 1
fi

api_url="$(echo "${json_payload}" | jq -r '.proxmox_config_api_url')"
token_id="$(echo "${json_payload}" | jq -r '.proxmox_config_api_token_id')"
token_secret="$(echo "${json_payload}" | jq -r '.proxmox_config_api_token_secret')"
tls_insecure="$(echo "${json_payload}" | jq -r '.proxmox_config_tls_insecure')"

if [[ -z "${api_url}" || -z "${token_id}" || -z "${token_secret}" || "${api_url}" == "null" || "${token_id}" == "null" || "${token_secret}" == "null" ]]; then
  echo "Error: missing required credential fields from remote JSON output." >&2
  exit 1
fi

cas_enabled=false
cas_value=""
metadata_output=""
data_output=""

set +e
metadata_output="$(vault kv metadata get -format=json "${VAULT_PATH}" 2>&1)"
metadata_rc=$?
set -e

if [[ ${metadata_rc} -eq 0 ]]; then
  current_version="$(echo "${metadata_output}" | jq -r '.data.current_version // 0')"
  if [[ "${current_version}" =~ ^[0-9]+$ ]]; then
    cas_enabled=true
    cas_value="${current_version}"
  else
    echo "Warning: unable to parse current_version from metadata for ${VAULT_PATH}; continuing without CAS." >&2
  fi
elif grep -qi "No value found" <<< "${metadata_output}"; then
  # Secret does not exist yet; CAS=0 safely enforces create-only semantics.
  cas_enabled=true
  cas_value="0"
else
  # Fallback: try deriving version from kv get (works when data read is allowed but metadata read is denied).
  set +e
  data_output="$(vault kv get -format=json "${VAULT_PATH}" 2>&1)"
  data_rc=$?
  set -e

  if [[ ${data_rc} -eq 0 ]]; then
    current_version="$(echo "${data_output}" | jq -r '.data.metadata.version // empty')"
    if [[ "${current_version}" =~ ^[0-9]+$ ]]; then
      cas_enabled=true
      cas_value="${current_version}"
    fi
  elif grep -qi "No value found" <<< "${data_output}"; then
    cas_enabled=true
    cas_value="0"
  fi

  if [[ "${cas_enabled}" != "true" ]]; then
    # Some tokens can update data but cannot read metadata/data; don't force CAS=0 in that case.
    echo "Warning: unable to determine current KV version for ${VAULT_PATH}; attempting update without CAS guard." >&2
  fi
fi

put_output=""
put_rc=0
if [[ "${cas_enabled}" == "true" ]]; then
  echo "Updating Vault path ${VAULT_PATH} (CAS=${cas_value})..."
  set +e
  put_output="$(vault kv put -cas="${cas_value}" "${VAULT_PATH}" \
    proxmox_config_api_url="${api_url}" \
    proxmox_config_api_token_id="${token_id}" \
    proxmox_config_api_token_secret="${token_secret}" \
    proxmox_config_tls_insecure="${tls_insecure}" 2>&1)"
  put_rc=$?
  set -e
else
  echo "Updating Vault path ${VAULT_PATH} (CAS=disabled)..."
  set +e
  put_output="$(vault kv put "${VAULT_PATH}" \
    proxmox_config_api_url="${api_url}" \
    proxmox_config_api_token_id="${token_id}" \
    proxmox_config_api_token_secret="${token_secret}" \
    proxmox_config_tls_insecure="${tls_insecure}" 2>&1)"
  put_rc=$?
  set -e
fi

if [[ ${put_rc} -ne 0 ]]; then
  if grep -qi "check-and-set parameter required" <<< "${put_output}"; then
    cat >&2 <<EOF
Error: Vault KV path ${VAULT_PATH} requires CAS, but this token cannot determine the current secret version.
Grant read access on this secret's data/metadata paths, or use a token with those permissions.
EOF
  fi
  printf '%s\n' "${put_output}" >&2
  exit ${put_rc}
fi
printf '%s\n' "${put_output}"

vault kv get -field=proxmox_config_api_token_id "${VAULT_PATH}" >/dev/null
echo "Credential rotation complete for ENVIRONMENT=${ENVIRONMENT}."
echo "Vault updated: ${VAULT_PATH}"
