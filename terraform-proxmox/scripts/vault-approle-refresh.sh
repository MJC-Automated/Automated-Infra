#!/usr/bin/env bash
# Refresh only the local Vault AppRole runtime credentials.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"
VAULT_AUTH_SCRIPT="${VAULT_AUTH_SCRIPT:-${REPO_ROOT}/scripts/vault-auth.sh}"
VAULT_APPROLE_NAME="${VAULT_APPROLE_NAME:-terraform-proxmox}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Error: required command not found: $1" >&2
    exit 1
  }
}

is_true() {
  local value="${1:-}"
  [[ "${value,,}" == "true" || "${value}" == "1" || "${value,,}" == "yes" ]]
}

ensure_vault_tls_env() {
  local candidate

  [[ "${VAULT_ADDR:-}" == https://* ]] || return 0

  if [[ -n "${VAULT_CACERT:-}" && ! -r "${VAULT_CACERT}" ]]; then
    if is_true "${VAULT_SKIP_VERIFY:-}"; then
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

check_env_file() {
  local mode

  [[ -f "${ENV_FILE}" ]] || return 0
  mode="$(stat -c '%a' "${ENV_FILE}" 2>/dev/null || stat -f '%Lp' "${ENV_FILE}" 2>/dev/null || true)"
  case "${mode}" in
    400|600) ;;
    *)
      echo "Error: insecure permissions on ${ENV_FILE} (${mode:-unknown}); expected 600 or 400." >&2
      exit 1
      ;;
  esac
}

write_runtime_ids() {
  local role_id="$1"
  local secret_id="$2"
  local tmp line
  local seen_role=0 seen_secret=0 seen_tf_role=0 seen_tf_secret=0

  umask 077
  tmp="$(mktemp "${ENV_FILE}.tmp.XXXXXX")"
  trap 'rm -f "${tmp:-}"' RETURN

  if [[ -f "${ENV_FILE}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      case "${line}" in
        VAULT_ROLE_ID=*)
          if [[ "${seen_role}" -eq 0 ]]; then
            printf 'VAULT_ROLE_ID=%s\n' "${role_id}" >> "${tmp}"
            seen_role=1
          fi
          ;;
        VAULT_SECRET_ID=*)
          if [[ "${seen_secret}" -eq 0 ]]; then
            printf 'VAULT_SECRET_ID=%s\n' "${secret_id}" >> "${tmp}"
            seen_secret=1
          fi
          ;;
        TF_VAR_vault_role_id=*)
          if [[ "${seen_tf_role}" -eq 0 ]]; then
            printf 'TF_VAR_vault_role_id=%s\n' "${role_id}" >> "${tmp}"
            seen_tf_role=1
          fi
          ;;
        TF_VAR_vault_secret_id=*)
          if [[ "${seen_tf_secret}" -eq 0 ]]; then
            printf 'TF_VAR_vault_secret_id=%s\n' "${secret_id}" >> "${tmp}"
            seen_tf_secret=1
          fi
          ;;
        *) printf '%s\n' "${line}" >> "${tmp}" ;;
      esac
    done < "${ENV_FILE}"
  fi

  [[ "${seen_role}" -eq 1 ]] || printf 'VAULT_ROLE_ID=%s\n' "${role_id}" >> "${tmp}"
  [[ "${seen_secret}" -eq 1 ]] || printf 'VAULT_SECRET_ID=%s\n' "${secret_id}" >> "${tmp}"
  [[ "${seen_tf_role}" -eq 1 ]] || printf 'TF_VAR_vault_role_id=%s\n' "${role_id}" >> "${tmp}"
  [[ "${seen_tf_secret}" -eq 1 ]] || printf 'TF_VAR_vault_secret_id=%s\n' "${secret_id}" >> "${tmp}"

  chmod 600 "${tmp}"
  mv -f "${tmp}" "${ENV_FILE}"
  trap - RETURN
}

require_cmd vault
require_cmd stat

[[ "${VAULT_APPROLE_NAME}" =~ ^[A-Za-z0-9_-]+$ ]] || {
  echo "Error: invalid VAULT_APPROLE_NAME: ${VAULT_APPROLE_NAME}" >&2
  exit 1
}
[[ -x "${VAULT_AUTH_SCRIPT}" ]] || {
  echo "Error: Vault auth helper is not executable: ${VAULT_AUTH_SCRIPT}" >&2
  exit 1
}

check_env_file
caller_token="${VAULT_TOKEN:-}"
if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi
[[ -n "${caller_token}" ]] && export VAULT_TOKEN="${caller_token}"

[[ -n "${VAULT_ADDR:-}" ]] || {
  echo "Error: VAULT_ADDR is not set." >&2
  exit 1
}
ensure_vault_tls_env

admin_token="$("${VAULT_AUTH_SCRIPT}" --print-token --validate)"
role_path="auth/approle/role/${VAULT_APPROLE_NAME}"
capabilities="$(VAULT_TOKEN="${admin_token}" vault token capabilities "${role_path}/secret-id")"
if ! grep -Eq '(^|[[:space:],])(root|sudo|create|update)([[:space:],]|$)' <<< "${capabilities}"; then
  echo "Error: current Vault token cannot mint a SecretID at ${role_path}/secret-id." >&2
  exit 1
fi

role_id="$(VAULT_TOKEN="${admin_token}" vault read -field=role_id "${role_path}/role-id")"
secret_id="$(VAULT_TOKEN="${admin_token}" vault write -f -field=secret_id "${role_path}/secret-id")"
[[ -n "${role_id}" && -n "${secret_id}" ]] || {
  echo "Error: Vault returned an empty AppRole credential." >&2
  exit 1
}

runtime_token="$(env -u VAULT_TOKEN -u TF_VAR_vault_token vault write -field=token auth/approle/login role_id="${role_id}" secret_id="${secret_id}")"
[[ -n "${runtime_token}" ]] || {
  echo "Error: new AppRole credentials did not return a runtime token." >&2
  exit 1
}
VAULT_TOKEN="${runtime_token}" vault token lookup >/dev/null
VAULT_TOKEN="${admin_token}" vault token revoke "${runtime_token}" >/dev/null

write_runtime_ids "${role_id}" "${secret_id}"
echo "Vault AppRole runtime credentials refreshed and validated in ${ENV_FILE}."
echo "Existing SecretIDs were not enumerated or revoked by this endpoint."
