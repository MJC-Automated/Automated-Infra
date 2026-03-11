#!/usr/bin/env bash
# Resolve Ansible/control host IP for an environment.
# Precedence:
# 1) Explicit env vars: ANSIBLE_HOST, ANSIBLE_HOST_<ENV>
# 2) .env file keys (same order)
# 3) Source IP chosen by kernel route to the Proxmox host for this environment
# 4) First IP from hostname -I

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_DEFAULT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

ENVIRONMENT="${ENVIRONMENT:-dev}"
REPO_ROOT="${REPO_ROOT:-${REPO_ROOT_DEFAULT}}"
ENV_FILE="${ENV_FILE:-}"
TARGET_HOST="${TARGET_HOST:-}"
ALLOW_ROUTE=true
ALLOW_FALLBACK=true
RESOLVE_PROXMOX_HOST_SCRIPT="${RESOLVE_PROXMOX_HOST_SCRIPT:-${REPO_ROOT_DEFAULT}/scripts/resolve-proxmox-host.sh}"

usage() {
  cat <<'EOF'
Usage:
  resolve-ansible-host.sh [options]

Options:
  --environment <name>   Environment name (default: ENVIRONMENT or dev).
  --repo-root <path>     Repo root containing .env and scripts.
  --env-file <path>      Explicit env file path (default: <repo-root>/.env).
  --target-host <host>   Route target host used for source-IP detection.
  --no-route             Skip route-based source-IP detection.
  --no-fallback          Skip hostname -I fallback.
  -h, --help             Show this help.

Output:
  Prints the resolved host/IP to stdout and exits 0.
  Exits non-zero if no value can be resolved.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --environment)
      ENVIRONMENT="${2:-}"
      [[ -n "${ENVIRONMENT}" ]] || { echo "Error: --environment requires a value." >&2; exit 1; }
      shift 2
      ;;
    --repo-root)
      REPO_ROOT="${2:-}"
      [[ -n "${REPO_ROOT}" ]] || { echo "Error: --repo-root requires a value." >&2; exit 1; }
      shift 2
      ;;
    --env-file)
      ENV_FILE="${2:-}"
      [[ -n "${ENV_FILE}" ]] || { echo "Error: --env-file requires a value." >&2; exit 1; }
      shift 2
      ;;
    --target-host)
      TARGET_HOST="${2:-}"
      [[ -n "${TARGET_HOST}" ]] || { echo "Error: --target-host requires a value." >&2; exit 1; }
      shift 2
      ;;
    --no-route)
      ALLOW_ROUTE=false
      shift
      ;;
    --no-fallback)
      ALLOW_FALLBACK=false
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

read_env_file_value() {
  local key="$1"
  local file="$2"
  [[ -f "${file}" ]] || return 1
  sed -n "s/^${key}=//p" "${file}" | head -n 1
}

resolve_ansible_from_explicit_env() {
  local env_key="$1"
  local key
  for key in ANSIBLE_HOST "ANSIBLE_HOST_${env_key}"; do
    if [[ -n "${!key:-}" ]]; then
      printf '%s\n' "${!key}"
      return 0
    fi
  done
  return 1
}

resolve_ansible_from_env_file() {
  local env_key="$1"
  local key host
  for key in ANSIBLE_HOST "ANSIBLE_HOST_${env_key}"; do
    host="$(read_env_file_value "${key}" "${ENV_FILE}" || true)"
    if [[ -n "${host}" ]]; then
      printf '%s\n' "${host}"
      return 0
    fi
  done
  return 1
}

resolve_route_target_from_env() {
  local env_key="$1"
  local key host

  if [[ -n "${TARGET_HOST}" ]]; then
    printf '%s\n' "${TARGET_HOST}"
    return 0
  fi

  for key in PROXMOX_HOST PVE_HOST "PVE_HOST_${env_key}" "PROXMOX_HOST_${env_key}"; do
    if [[ -n "${!key:-}" ]]; then
      printf '%s\n' "${!key}"
      return 0
    fi
  done

  for key in PROXMOX_HOST PVE_HOST "PVE_HOST_${env_key}" "PROXMOX_HOST_${env_key}"; do
    host="$(read_env_file_value "${key}" "${ENV_FILE}" || true)"
    if [[ -n "${host}" ]]; then
      printf '%s\n' "${host}"
      return 0
    fi
  done

  if [[ -x "${RESOLVE_PROXMOX_HOST_SCRIPT}" ]]; then
    host="$(ENVIRONMENT="${ENVIRONMENT}" REPO_ROOT="${REPO_ROOT}" ENV_FILE="${ENV_FILE}" "${RESOLVE_PROXMOX_HOST_SCRIPT}" 2>/dev/null || true)"
    if [[ -n "${host}" ]]; then
      printf '%s\n' "${host}"
      return 0
    fi
  fi

  return 1
}

detect_route_src_ip() {
  local target="$1"
  command -v ip >/dev/null 2>&1 || return 1
  ip -4 route get "${target}" 2>/dev/null | awk '{
    for (i = 1; i <= NF; i++) {
      if ($i == "src") {
        print $(i+1)
        exit
      }
    }
  }'
}

detect_first_local_ip() {
  hostname -I 2>/dev/null | awk '{print $1}'
}

env_key="$(printf '%s' "${ENVIRONMENT}" | tr '[:lower:]-' '[:upper:]_')"

if host="$(resolve_ansible_from_explicit_env "${env_key}" || true)" && [[ -n "${host}" ]]; then
  printf '%s\n' "${host}"
  exit 0
fi

if host="$(resolve_ansible_from_env_file "${env_key}" || true)" && [[ -n "${host}" ]]; then
  printf '%s\n' "${host}"
  exit 0
fi

if [[ "${ALLOW_ROUTE}" == "true" ]]; then
  route_target="$(resolve_route_target_from_env "${env_key}" || true)"
  if [[ -n "${route_target}" ]]; then
    if host="$(detect_route_src_ip "${route_target}" || true)" && [[ -n "${host}" ]]; then
      printf '%s\n' "${host}"
      exit 0
    fi
  fi
fi

if [[ "${ALLOW_FALLBACK}" == "true" ]]; then
  if host="$(detect_first_local_ip || true)" && [[ -n "${host}" ]]; then
    printf '%s\n' "${host}"
    exit 0
  fi
fi

echo "Error: failed to resolve Ansible/control host IP for ENVIRONMENT=${ENVIRONMENT}." >&2
echo "Checked: ANSIBLE_HOST env vars, ${ENV_FILE}, route source IP, and hostname -I." >&2
exit 1
