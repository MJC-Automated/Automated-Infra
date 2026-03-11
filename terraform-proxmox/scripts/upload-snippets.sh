#!/bin/bash
# Uploads rendered cloud-init snippets from ./snippets/ to the Proxmox node.
set -euo pipefail

ENVIRONMENT="${ENVIRONMENT:-${TF_WORKSPACE:-dev}}"
PROXMOX_USER="${PROXMOX_USER:-root}"
PROXMOX_PASSWORD="${PROXMOX_PASSWORD:-}"
SNIPPET_STORAGE="${SNIPPET_STORAGE:-local}"
SNIPPETS_DIR="snippets"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
VAULT_AUTH_SCRIPT="${VAULT_AUTH_SCRIPT:-${REPO_ROOT}/scripts/vault-auth.sh}"
SSH_STRICT_HOST_KEY_CHECKING="${SSH_STRICT_HOST_KEY_CHECKING:-accept-new}"

resolve_proxmox_host() {
    if [[ -n "${PROXMOX_HOST:-}" ]]; then
        echo "${PROXMOX_HOST}"
        return 0
    fi

    # Check .env (optional), without sourcing it.
    if [[ -f .env ]]; then
        local host
        host="$(sed -n 's/^PROXMOX_HOST=//p' .env | head -n 1)"
        if [[ -n "${host}" ]]; then
            echo "${host}"
            return 0
        fi
        local env_key
        env_key="$(echo "${ENVIRONMENT}" | tr '[:lower:]' '[:upper:]')"
        host="$(sed -n "s/^PROXMOX_HOST_${env_key}=//p" .env | head -n 1)"
        if [[ -n "${host}" ]]; then
            echo "${host}"
            return 0
        fi
    fi

    # Try Vault (if configured) to pull proxmox_config_api_url.
    if command -v vault >/dev/null 2>&1 && [[ -n "${VAULT_ADDR:-}" ]]; then
        if [[ -z "${VAULT_TOKEN:-}" && -x "${VAULT_AUTH_SCRIPT}" ]]; then
            export VAULT_TOKEN="$("${VAULT_AUTH_SCRIPT}" --print-token 2>/dev/null || true)"
        fi
    fi
    if command -v vault >/dev/null 2>&1 && [[ -n "${VAULT_ADDR:-}" && -n "${VAULT_TOKEN:-}" ]]; then
        local url
        url="$(vault kv get -field=proxmox_config_api_url "secret/terraform/${ENVIRONMENT}/creds" 2>/dev/null || true)"
        if [[ -n "${url}" ]]; then
            echo "${url}" | sed -E 's#^https?://##; s#[:/].*$##'
            return 0
        fi
    fi

    # Try Packer vars for this environment.
    local vars_file
    for vars_file in \
        "packer/ubuntu-noble/vars.${ENVIRONMENT}.pkrvars.hcl" \
        "packer/oracle8/vars.${ENVIRONMENT}.pkrvars.hcl" \
        "packer/oracle9/vars.${ENVIRONMENT}.pkrvars.hcl"; do
        if [[ -f "${vars_file}" ]]; then
            local url
            url="$(sed -n 's/^[[:space:]]*proxmox_api_url[[:space:]]*=[[:space:]]*\"\(.*\)\"/\1/p' "${vars_file}" | head -n 1)"
            if [[ -n "${url}" ]]; then
                echo "${url}" | sed -E 's#^https?://##; s#[:/].*$##'
                return 0
            fi
        fi
    done

    return 1
}

PROXMOX_HOST="${PROXMOX_HOST:-$(resolve_proxmox_host || true)}"
if [[ -z "${PROXMOX_HOST}" ]]; then
    echo "Error: Failed to resolve Proxmox host for env=${ENVIRONMENT}."
    echo "Set PROXMOX_HOST or PROXMOX_HOST_<ENV> in .env."
    exit 1
fi

if [[ ! -d "$SNIPPETS_DIR" ]]; then
    echo "Error: Directory '$SNIPPETS_DIR' not found."
    exit 1
fi

if [[ ! "${SNIPPET_STORAGE}" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Error: SNIPPET_STORAGE contains invalid characters: ${SNIPPET_STORAGE}"
    exit 1
fi

# Use sshpass if available (for testing environment)
SSH_CMD="ssh"
SCP_CMD="scp"
if [[ -n "${PROXMOX_PASSWORD}" ]]; then
    if ! command -v sshpass &>/dev/null; then
        echo "Error: PROXMOX_PASSWORD was provided but sshpass is not installed."
        exit 1
    fi
    export SSHPASS="${PROXMOX_PASSWORD}"
    SSH_CMD="sshpass -e ssh"
    SCP_CMD="sshpass -e scp"
fi

available_snippet_storages="$($SSH_CMD -o StrictHostKeyChecking="${SSH_STRICT_HOST_KEY_CHECKING}" "$PROXMOX_USER@$PROXMOX_HOST" "pvesm status --content snippets | awk 'NR>1 && NF>0 {print \$1}'" || true)"
if [[ -z "${available_snippet_storages}" ]]; then
    echo "Error: No Proxmox storages expose content type 'snippets' on ${PROXMOX_HOST}."
    exit 1
fi
if ! printf '%s\n' "${available_snippet_storages}" | grep -qx "${SNIPPET_STORAGE}"; then
    echo "Error: SNIPPET_STORAGE='${SNIPPET_STORAGE}' does not support snippets on ${PROXMOX_HOST}."
    echo "Available snippet storages: $(echo "${available_snippet_storages}" | tr '\n' ' ' | sed 's/ *$//')"
    exit 1
fi

REMOTE_FILE_PROBE="$($SSH_CMD -o StrictHostKeyChecking="${SSH_STRICT_HOST_KEY_CHECKING}" "$PROXMOX_USER@$PROXMOX_HOST" "pvesm path ${SNIPPET_STORAGE}:snippets/.codex-snippet-path-probe.yaml" 2>/dev/null || true)"
if [[ -z "${REMOTE_FILE_PROBE}" ]]; then
    echo "Error: Failed to resolve snippet path for storage '${SNIPPET_STORAGE}' on ${PROXMOX_HOST}."
    exit 1
fi
REMOTE_PATH="$(dirname "${REMOTE_FILE_PROBE}")"

echo "Uploading snippets to ${PROXMOX_HOST} (env=${ENVIRONMENT}, storage=${SNIPPET_STORAGE}, path=${REMOTE_PATH})..."

# Ensure remote directory exists
$SSH_CMD -o StrictHostKeyChecking="${SSH_STRICT_HOST_KEY_CHECKING}" "$PROXMOX_USER@$PROXMOX_HOST" "mkdir -p $REMOTE_PATH"

shopt -s nullglob
snippet_files=("$SNIPPETS_DIR/${ENVIRONMENT}-"*.yaml)
if [[ ${#snippet_files[@]} -eq 0 ]]; then
    snippet_files=("$SNIPPETS_DIR"/*.yaml)
fi
if [[ ${#snippet_files[@]} -eq 0 ]]; then
    echo "Error: No snippet files found in '${SNIPPETS_DIR}'."
    exit 1
fi

for file in "${snippet_files[@]}"; do
    filename="$(basename "$file")"
    echo "Uploading ${filename}..."
    $SCP_CMD -o StrictHostKeyChecking="${SSH_STRICT_HOST_KEY_CHECKING}" "$file" "$PROXMOX_USER@$PROXMOX_HOST:$REMOTE_PATH/$filename"
done

echo "Snippets upload complete."
