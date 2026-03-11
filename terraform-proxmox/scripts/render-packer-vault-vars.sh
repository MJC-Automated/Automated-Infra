#!/usr/bin/env bash
# Render a temporary Packer vars file from Vault credentials.
# Intended for use by Makefile packer-build targets.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
VAULT_AUTH_SCRIPT="${VAULT_AUTH_SCRIPT:-${REPO_ROOT}/scripts/vault-auth.sh}"

ENVIRONMENT="${ENVIRONMENT:-dev}"
VAULT_PATH="${VAULT_PATH:-}"
OUTPUT_FILE=""

usage() {
  cat <<'EOF'
Usage:
  render-packer-vault-vars.sh [options] <output-vars-file>
  render-packer-vault-vars.sh [options] --output <output-vars-file>

Options:
  --environment <name>  Environment name for default Vault path (default: dev).
  --vault-path <path>   Explicit Vault KV path (overrides --environment default).
  -o, --output <file>   Output .pkrvars.hcl file path.
  -h, --help            Show this help.

Environment:
  ENVIRONMENT           Default environment if --environment is not provided.
  VAULT_PATH            Default Vault path if --vault-path is not provided.
  VAULT_ADDR            Vault address (required).
  VAULT_TOKEN           Vault token (optional if vault-auth.sh can provide one).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --environment)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --environment requires a value." >&2
        exit 1
      fi
      ENVIRONMENT="$2"
      shift 2
      ;;
    --vault-path)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --vault-path requires a value." >&2
        exit 1
      fi
      VAULT_PATH="$2"
      shift 2
      ;;
    -o|--output)
      if [[ -z "${2:-}" ]]; then
        echo "Error: $1 requires a value." >&2
        exit 1
      fi
      OUTPUT_FILE="$2"
      shift 2
      ;;
    --output=*)
      OUTPUT_FILE="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    --*)
      echo "Error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -z "${OUTPUT_FILE}" ]]; then
        OUTPUT_FILE="$1"
        shift
      else
        echo "Error: unexpected positional argument: $1" >&2
        usage >&2
        exit 1
      fi
      ;;
  esac
done

if [[ $# -gt 0 ]]; then
  if [[ -z "${OUTPUT_FILE}" ]]; then
    OUTPUT_FILE="$1"
    shift
  fi
fi

if [[ $# -gt 0 ]]; then
  echo "Error: unexpected positional arguments: $*" >&2
  usage >&2
  exit 1
fi

if [[ -z "${OUTPUT_FILE}" ]]; then
  usage >&2
  exit 1
fi

if [[ -z "${VAULT_PATH}" ]]; then
  VAULT_PATH="secret/terraform/${ENVIRONMENT}/creds"
fi

if ! command -v vault >/dev/null 2>&1; then
  echo "Error: vault CLI not found in PATH." >&2
  exit 1
fi

if [[ -z "${VAULT_ADDR:-}" ]]; then
  echo "Error: VAULT_ADDR is not set." >&2
  exit 1
fi

if [[ -z "${VAULT_TOKEN:-}" ]]; then
  if [[ -x "${VAULT_AUTH_SCRIPT}" ]]; then
    VAULT_TOKEN="$("${VAULT_AUTH_SCRIPT}" --print-token)"
    export VAULT_TOKEN
  else
    echo "Error: VAULT_TOKEN is not set and ${VAULT_AUTH_SCRIPT} is not executable." >&2
    exit 1
  fi
fi

escape_hcl_string() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "${s}"
}

normalize_bool() {
  local v
  v="$(echo "$1" | tr '[:upper:]' '[:lower:]' | xargs)"
  case "${v}" in
    true|1|yes|y|on) echo "true" ;;
    false|0|no|n|off) echo "false" ;;
    *)
      echo "Error: invalid proxmox_config_tls_insecure value '${1}' in ${VAULT_PATH}" >&2
      exit 1
      ;;
  esac
}

api_url="$(vault kv get -field=proxmox_config_api_url "${VAULT_PATH}")"
token_id="$(vault kv get -field=proxmox_config_api_token_id "${VAULT_PATH}")"
token_secret="$(vault kv get -field=proxmox_config_api_token_secret "${VAULT_PATH}")"
tls_insecure_raw="$(vault kv get -field=proxmox_config_tls_insecure "${VAULT_PATH}")"
tls_insecure="$(normalize_bool "${tls_insecure_raw}")"

if [[ -z "${api_url}" || -z "${token_id}" || -z "${token_secret}" ]]; then
  echo "Error: missing required Proxmox credential fields in ${VAULT_PATH}." >&2
  exit 1
fi

umask 077
cat > "${OUTPUT_FILE}" <<EOF
# Generated from Vault path: ${VAULT_PATH}
proxmox_api_url      = "$(escape_hcl_string "${api_url}")"
proxmox_token_id     = "$(escape_hcl_string "${token_id}")"
proxmox_token        = "$(escape_hcl_string "${token_secret}")"
proxmox_tls_insecure = ${tls_insecure}
EOF

echo "Generated Packer Vault override vars: ${OUTPUT_FILE}"
