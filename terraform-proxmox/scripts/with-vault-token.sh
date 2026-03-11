#!/usr/bin/env bash
# Run a command after ensuring VAULT_TOKEN and TF_VAR_vault_token are set.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
VAULT_AUTH_SCRIPT="${VAULT_AUTH_SCRIPT:-${REPO_ROOT}/scripts/vault-auth.sh}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"

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

usage() {
  cat <<'EOF'
Usage:
  with-vault-token.sh <command> [args...]
  with-vault-token.sh -- <command> [args...]

Behavior:
  Ensures VAULT_TOKEN and TF_VAR_vault_token are set before executing the command.
  If either variable is missing, vault-auth.sh is used to fetch a token.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "${1:-}" == "--" ]]; then
  shift
fi

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 1
fi

if [[ -f "${ENV_FILE}" ]]; then
  if [[ -z "${VAULT_ADDR:-}" || ( -z "${VAULT_TOKEN:-}" && -z "${VAULT_ROLE_ID:-}" ) ]]; then
    # shellcheck disable=SC1090
    set -a
    source "${ENV_FILE}"
    set +a
  fi
fi

if [[ -z "${VAULT_ADDR:-}" ]]; then
  echo "Error: VAULT_ADDR is not set." >&2
  exit 1
fi

ensure_vault_tls_env

need_token_refresh=false
if [[ -z "${VAULT_TOKEN:-}" || -z "${TF_VAR_vault_token:-}" ]]; then
  need_token_refresh=true
elif command -v vault >/dev/null 2>&1 && [[ -n "${VAULT_ADDR:-}" ]]; then
  if ! VAULT_TOKEN="${VAULT_TOKEN}" vault token lookup >/dev/null 2>&1; then
    need_token_refresh=true
  fi
fi

if [[ "${need_token_refresh}" == true ]]; then
  if [[ ! -x "${VAULT_AUTH_SCRIPT}" ]]; then
    echo "Error: ${VAULT_AUTH_SCRIPT} is not executable." >&2
    exit 1
  fi
  set +e
  token="$("${VAULT_AUTH_SCRIPT}" --print-token --validate 2>/dev/null)"
  rc=$?
  set -e
  if [[ ${rc} -ne 0 || -z "${token}" ]]; then
    # If inherited VAULT_TOKEN is stale, retry auth resolution without it so .env/cache can be used.
    token="$(VAULT_TOKEN="" TF_VAR_vault_token="" "${VAULT_AUTH_SCRIPT}" --print-token --validate)"
  fi
  export VAULT_TOKEN="${token}"
  export TF_VAR_vault_token="${token}"
fi

exec "$@"
