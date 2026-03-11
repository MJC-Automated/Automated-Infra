#!/usr/bin/env bash
# Resolve a Vault token from env/token-file/AppRole.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

TOKEN_FILE="${VAULT_TOKEN_FILE:-${REPO_ROOT}/.vault-token}"
APPROLE_PATH="${VAULT_APPROLE_PATH:-auth/approle/login}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"
VALIDATE_TOKEN="${VAULT_AUTH_VALIDATE_TOKEN:-false}"
USE_CACHE=true
FORCE_LOGIN=false
PRINT_MODE="token" # token | export

check_restricted_file_perms() {
  local file="$1"
  local perms
  [[ -f "${file}" ]] || return 0
  perms="$(stat -c '%a' "${file}" 2>/dev/null || stat -f '%Lp' "${file}" 2>/dev/null || echo '')"
  case "${perms}" in
    400|600) return 0 ;;
    *)
      echo "Error: insecure permissions on ${file} (${perms:-unknown}); expected 600 or 400." >&2
      return 1
      ;;
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

usage() {
  cat <<'EOF'
Usage:
  vault-auth.sh [--print-token|--print-export] [--force-login] [--no-cache] [--validate|--no-validate]

Options:
  --print-token   Print token only (default).
  --print-export  Print shell exports for VAULT_TOKEN and TF_VAR_vault_token.
  --force-login   Force AppRole login even if token env/file exists.
  --no-cache      Do not read/write token cache file.
  --validate      Validate token via 'vault token lookup'.
  --no-validate   Skip token validation (vault token lookup).
  -h, --help      Show this help.

Environment:
  VAULT_ADDR                Vault address (required).
  VAULT_CACERT / VAULT_SKIP_VERIFY  TLS settings for Vault CLI.
  VAULT_TOKEN               Existing token candidate.
  VAULT_ROLE_ID             AppRole role_id.
  VAULT_SECRET_ID           AppRole secret_id.
  VAULT_APPROLE_PATH        Login path (default: auth/approle/login).
  VAULT_TOKEN_FILE          Token cache file (default: .vault-token in repo root).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --print-token)
      PRINT_MODE="token"
      shift
      ;;
    --print-export)
      PRINT_MODE="export"
      shift
      ;;
    --force-login)
      FORCE_LOGIN=true
      shift
      ;;
    --no-cache)
      USE_CACHE=false
      shift
      ;;
    --validate)
      VALIDATE_TOKEN=true
      shift
      ;;
    --no-validate)
      VALIDATE_TOKEN=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if ! command -v vault >/dev/null 2>&1; then
  echo "Error: vault CLI not found in PATH." >&2
  exit 1
fi

if [[ -f "${ENV_FILE}" ]]; then
  check_restricted_file_perms "${ENV_FILE}"
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

validate_candidate() {
  local candidate="$1"
  [[ -n "${candidate}" ]] || return 1
  if [[ "${VALIDATE_TOKEN}" == false ]]; then
    return 0
  fi
  VAULT_TOKEN="${candidate}" vault token lookup >/dev/null 2>&1
}

emit_token() {
  local tok="$1"
  if [[ "${PRINT_MODE}" == "export" ]]; then
    printf 'export VAULT_TOKEN=%q\n' "${tok}"
    printf 'export TF_VAR_vault_token=%q\n' "${tok}"
  else
    printf '%s\n' "${tok}"
  fi
}

candidate=""
if [[ "${FORCE_LOGIN}" == false ]]; then
  candidate="${VAULT_TOKEN:-}"
  if validate_candidate "${candidate}"; then
    emit_token "${candidate}"
    exit 0
  fi

  if [[ "${USE_CACHE}" == true && -f "${TOKEN_FILE}" ]]; then
    check_restricted_file_perms "${TOKEN_FILE}"
    candidate="$(tr -d '\n' < "${TOKEN_FILE}" || true)"
    if validate_candidate "${candidate}"; then
      emit_token "${candidate}"
      exit 0
    fi
  fi
fi

if [[ -z "${VAULT_ROLE_ID:-}" || -z "${VAULT_SECRET_ID:-}" ]]; then
  echo "Error: no valid Vault token found and AppRole credentials are missing." >&2
  echo "Set VAULT_TOKEN or (VAULT_ROLE_ID + VAULT_SECRET_ID)." >&2
  exit 1
fi

new_token="$(vault write -field=token "${APPROLE_PATH}" role_id="${VAULT_ROLE_ID}" secret_id="${VAULT_SECRET_ID}")"
if [[ -z "${new_token}" ]]; then
  echo "Error: AppRole login succeeded but no token was returned." >&2
  exit 1
fi

if [[ "${USE_CACHE}" == true ]]; then
  umask 077
  printf '%s\n' "${new_token}" > "${TOKEN_FILE}"
fi

emit_token "${new_token}"
