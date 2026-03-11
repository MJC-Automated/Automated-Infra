#!/usr/bin/env bash
# Resolve Proxmox host for an environment using a consistent precedence model.
# Precedence:
# 1) Explicit env vars: PROXMOX_HOST, PVE_HOST
# 2) Env-scoped env vars: PVE_HOST_<ENV>, PROXMOX_HOST_<ENV>
# 3) .env file keys (same order as above)
# 4) Vault secret/terraform/<env>/creds -> proxmox_config_api_url
# 5) Packer vars.<env>.pkrvars.hcl -> proxmox_api_url

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_DEFAULT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

ENVIRONMENT="${ENVIRONMENT:-dev}"
REPO_ROOT="${REPO_ROOT:-${REPO_ROOT_DEFAULT}}"
ENV_FILE="${ENV_FILE:-}"
ALLOW_VAULT=true
ALLOW_PACKER=true
VAULT_AUTH_SCRIPT="${VAULT_AUTH_SCRIPT:-${REPO_ROOT_DEFAULT}/scripts/vault-auth.sh}"

usage() {
  cat <<'EOF'
Usage:
  resolve-proxmox-host.sh [options]

Options:
  --environment <name>   Environment name (default: ENVIRONMENT or dev).
  --repo-root <path>     Repo root containing .env and packer dirs.
  --env-file <path>      Explicit env file path (default: <repo-root>/.env).
  --no-vault             Skip Vault lookup.
  --no-packer            Skip Packer vars lookup.
  -h, --help             Show this help.

Output:
  Prints the resolved host to stdout and exits 0.
  Exits non-zero if no host can be resolved.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --environment)
      ENVIRONMENT="${2:-}"
      if [[ -z "${ENVIRONMENT}" ]]; then
        echo "Error: --environment requires a value." >&2
        exit 1
      fi
      shift 2
      ;;
    --repo-root)
      REPO_ROOT="${2:-}"
      if [[ -z "${REPO_ROOT}" ]]; then
        echo "Error: --repo-root requires a value." >&2
        exit 1
      fi
      shift 2
      ;;
    --env-file)
      ENV_FILE="${2:-}"
      if [[ -z "${ENV_FILE}" ]]; then
        echo "Error: --env-file requires a value." >&2
        exit 1
      fi
      shift 2
      ;;
    --no-vault)
      ALLOW_VAULT=false
      shift
      ;;
    --no-packer)
      ALLOW_PACKER=false
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

if [[ -z "${ENV_FILE}" ]]; then
  ENV_FILE="${REPO_ROOT}/.env"
fi

to_host_from_url() {
  local url="$1"
  # Strip scheme, path and port.
  printf '%s\n' "${url}" | sed -E 's#^[A-Za-z][A-Za-z0-9+.-]*://##; s#/.*$##; s#:[0-9]+$##'
}

read_env_file_value() {
  local key="$1"
  local file="$2"
  [[ -f "${file}" ]] || return 1
  sed -n "s/^${key}=//p" "${file}" | head -n 1
}

resolve_from_explicit_env() {
  local env_key="$1"
  for key in PROXMOX_HOST PVE_HOST "PVE_HOST_${env_key}" "PROXMOX_HOST_${env_key}"; do
    if [[ -n "${!key:-}" ]]; then
      printf '%s\n' "${!key}"
      return 0
    fi
  done
  return 1
}

resolve_from_env_file() {
  local env_key="$1"
  local host=""
  for key in PROXMOX_HOST PVE_HOST "PVE_HOST_${env_key}" "PROXMOX_HOST_${env_key}"; do
    host="$(read_env_file_value "${key}" "${ENV_FILE}" || true)"
    if [[ -n "${host}" ]]; then
      printf '%s\n' "${host}"
      return 0
    fi
  done
  return 1
}

resolve_from_vault() {
  local path="$1"

  if ! command -v vault >/dev/null 2>&1; then
    return 1
  fi
  if [[ -z "${VAULT_ADDR:-}" ]]; then
    return 1
  fi
  if [[ -z "${VAULT_TOKEN:-}" && -x "${VAULT_AUTH_SCRIPT}" ]]; then
    export VAULT_TOKEN="$("${VAULT_AUTH_SCRIPT}" --print-token 2>/dev/null || true)"
  fi
  if [[ -z "${VAULT_TOKEN:-}" ]]; then
    return 1
  fi

  local url
  url="$(vault kv get -field=proxmox_config_api_url "${path}" 2>/dev/null || true)"
  if [[ -n "${url}" ]]; then
    to_host_from_url "${url}"
    return 0
  fi
  return 1
}

resolve_from_packer_vars() {
  local env="$1"
  local vars_file
  for vars_file in \
    "${REPO_ROOT}/packer/ubuntu-noble/vars.${env}.pkrvars.hcl" \
    "${REPO_ROOT}/packer/oracle8/vars.${env}.pkrvars.hcl" \
    "${REPO_ROOT}/packer/oracle9/vars.${env}.pkrvars.hcl"; do
    if [[ -f "${vars_file}" ]]; then
      local url
      url="$(sed -n 's/^[[:space:]]*proxmox_api_url[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "${vars_file}" | head -n 1)"
      if [[ -n "${url}" ]]; then
        to_host_from_url "${url}"
        return 0
      fi
    fi
  done
  return 1
}

env_key="$(printf '%s' "${ENVIRONMENT}" | tr '[:lower:]' '[:upper:]')"
vault_path="secret/terraform/${ENVIRONMENT}/creds"

if host="$(resolve_from_explicit_env "${env_key}" || true)" && [[ -n "${host}" ]]; then
  printf '%s\n' "${host}"
  exit 0
fi

if host="$(resolve_from_env_file "${env_key}" || true)" && [[ -n "${host}" ]]; then
  printf '%s\n' "${host}"
  exit 0
fi

if [[ "${ALLOW_VAULT}" == "true" ]]; then
  if host="$(resolve_from_vault "${vault_path}" || true)" && [[ -n "${host}" ]]; then
    printf '%s\n' "${host}"
    exit 0
  fi
fi

if [[ "${ALLOW_PACKER}" == "true" ]]; then
  if host="$(resolve_from_packer_vars "${ENVIRONMENT}" || true)" && [[ -n "${host}" ]]; then
    printf '%s\n' "${host}"
    exit 0
  fi
fi

echo "Error: failed to resolve Proxmox host for ENVIRONMENT=${ENVIRONMENT}." >&2
echo "Checked: explicit env vars, ${ENV_FILE}, Vault (${vault_path}), and packer vars files." >&2
exit 1
