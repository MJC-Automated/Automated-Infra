#!/usr/bin/env bash
# Enable a Vault file audit device after explicit confirmation.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"
VAULT_AUTH_SCRIPT="${VAULT_AUTH_SCRIPT:-${REPO_ROOT}/scripts/vault-auth.sh}"
VAULT_AUDIT_PATH="${VAULT_AUDIT_PATH:-file}"
VAULT_AUDIT_FILE_PATH="${VAULT_AUDIT_FILE_PATH:-/var/log/vault_audit.log}"
CONFIRM="${CONFIRM:-}"

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

if [[ "${CONFIRM}" != "ENABLE_AUDIT" ]]; then
  echo "Refusing to enable Vault audit logging. Re-run with CONFIRM=ENABLE_AUDIT." >&2
  exit 1
fi

if ! command -v vault >/dev/null 2>&1; then
  echo "Error: vault CLI not found in PATH." >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required for audit device parsing." >&2
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

ensure_vault_tls_env

if [[ -z "${VAULT_TOKEN:-}" ]]; then
  if [[ ! -x "${VAULT_AUTH_SCRIPT}" ]]; then
    echo "Error: VAULT_TOKEN is not set and ${VAULT_AUTH_SCRIPT} is not executable." >&2
    exit 1
  fi
  VAULT_TOKEN="$("${VAULT_AUTH_SCRIPT}" --print-token --validate)"
  export VAULT_TOKEN
fi

if vault audit list -format=json | jq -e --arg p "${VAULT_AUDIT_PATH}/" 'has($p)' >/dev/null; then
  echo "Vault audit device already enabled at ${VAULT_AUDIT_PATH}/."
  exit 0
fi

audit_dir="$(dirname "${VAULT_AUDIT_FILE_PATH}")"
if [[ ! -d "${audit_dir}" ]]; then
  if command -v sudo >/dev/null 2>&1; then
    sudo -n install -d -o vault -g vault -m 0750 "${audit_dir}" 2>/dev/null || true
  fi
fi
if [[ ! -e "${VAULT_AUDIT_FILE_PATH}" ]] && command -v sudo >/dev/null 2>&1; then
  sudo -n install -o vault -g vault -m 0600 /dev/null "${VAULT_AUDIT_FILE_PATH}" 2>/dev/null || true
fi

vault audit enable -path="${VAULT_AUDIT_PATH}" file "file_path=${VAULT_AUDIT_FILE_PATH}"
echo "Vault audit device enabled at ${VAULT_AUDIT_PATH}/ (${VAULT_AUDIT_FILE_PATH})."
