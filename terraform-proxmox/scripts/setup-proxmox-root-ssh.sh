#!/usr/bin/env bash
# Ensure key-based SSH access from this host to a Proxmox root account.

set -euo pipefail

PROXMOX_HOST="${PROXMOX_HOST:-}"
PROXMOX_USER="${PROXMOX_USER:-root}"
PUBLIC_KEY_FILE="${PUBLIC_KEY_FILE:-}"
PROXMOX_PASSWORD="${PROXMOX_PASSWORD:-}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-10}"
SSH_OPTIONS_RAW="${SSH_OPTIONS:-}"
SSH_STRICT_HOST_KEY_CHECKING="${SSH_STRICT_HOST_KEY_CHECKING:-accept-new}"

SSH_OPTS_DEFAULT=(-o StrictHostKeyChecking="${SSH_STRICT_HOST_KEY_CHECKING}" -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}")
SSH_OPTS=()

usage() {
  cat <<'EOF'
Usage:
  setup-proxmox-root-ssh.sh [options]

Options:
  --host <ip-or-dns>      Proxmox host (required if PROXMOX_HOST is not set).
  --user <name>           SSH user (default: root).
  --public-key <path>     Public key file (default: ~/.ssh/id_ed25519.pub, then ~/.ssh/id_rsa.pub).
  --password <password>   Use password mode via sshpass (optional).
  -h, --help              Show this help.

Environment:
  PROXMOX_HOST, PROXMOX_USER, PUBLIC_KEY_FILE, PROXMOX_PASSWORD, SSH_OPTIONS
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      PROXMOX_HOST="${2:-}"
      shift 2
      ;;
    --user)
      PROXMOX_USER="${2:-}"
      shift 2
      ;;
    --public-key)
      PUBLIC_KEY_FILE="${2:-}"
      shift 2
      ;;
    --password)
      PROXMOX_PASSWORD="${2:-}"
      shift 2
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

if [[ -z "${PROXMOX_HOST}" ]]; then
  echo "Error: PROXMOX_HOST is required." >&2
  exit 1
fi

if [[ -n "${SSH_OPTIONS_RAW}" ]]; then
  case "${SSH_OPTIONS_RAW}" in
    \"*\") SSH_OPTIONS_RAW="${SSH_OPTIONS_RAW#\"}"; SSH_OPTIONS_RAW="${SSH_OPTIONS_RAW%\"}" ;;
    \'*\') SSH_OPTIONS_RAW="${SSH_OPTIONS_RAW#\'}"; SSH_OPTIONS_RAW="${SSH_OPTIONS_RAW%\'}" ;;
  esac
  # shellcheck disable=SC2206
  SSH_OPTS=(${SSH_OPTIONS_RAW})
else
  SSH_OPTS=("${SSH_OPTS_DEFAULT[@]}")
fi

if [[ -z "${PUBLIC_KEY_FILE}" ]]; then
  if [[ -f "${HOME}/.ssh/id_ed25519.pub" ]]; then
    PUBLIC_KEY_FILE="${HOME}/.ssh/id_ed25519.pub"
  elif [[ -f "${HOME}/.ssh/id_rsa.pub" ]]; then
    PUBLIC_KEY_FILE="${HOME}/.ssh/id_rsa.pub"
  else
    echo "Error: no public key found. Provide --public-key or create ~/.ssh/id_ed25519.pub." >&2
    exit 1
  fi
fi

if [[ ! -f "${PUBLIC_KEY_FILE}" ]]; then
  echo "Error: public key file not found: ${PUBLIC_KEY_FILE}" >&2
  exit 1
fi

pubkey="$(cat "${PUBLIC_KEY_FILE}")"
if [[ -z "${pubkey}" ]]; then
  echo "Error: public key file is empty: ${PUBLIC_KEY_FILE}" >&2
  exit 1
fi

echo "Configuring key-based SSH for ${PROXMOX_USER}@${PROXMOX_HOST} using ${PUBLIC_KEY_FILE}..."

if [[ -n "${PROXMOX_PASSWORD}" ]]; then
  if ! command -v sshpass >/dev/null 2>&1; then
    echo "Error: PROXMOX_PASSWORD was provided but sshpass is not installed." >&2
    exit 1
  fi
  key_escaped="$(printf "%s" "${pubkey}" | sed "s/'/'\"'\"'/g")"
  remote_cmd="umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; grep -qxF '${key_escaped}' ~/.ssh/authorized_keys || echo '${key_escaped}' >> ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys"
  SSHPASS="${PROXMOX_PASSWORD}" sshpass -e ssh "${SSH_OPTS[@]}" -o PubkeyAuthentication=no "${PROXMOX_USER}@${PROXMOX_HOST}" "${remote_cmd}"
else
  if command -v ssh-copy-id >/dev/null 2>&1; then
    ssh-copy-id "${SSH_OPTS[@]}" -i "${PUBLIC_KEY_FILE}" "${PROXMOX_USER}@${PROXMOX_HOST}"
  else
    key_escaped="$(printf "%s" "${pubkey}" | sed "s/'/'\"'\"'/g")"
    remote_cmd="umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; grep -qxF '${key_escaped}' ~/.ssh/authorized_keys || echo '${key_escaped}' >> ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys"
    ssh "${SSH_OPTS[@]}" "${PROXMOX_USER}@${PROXMOX_HOST}" "${remote_cmd}"
  fi
fi

ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${PROXMOX_USER}@${PROXMOX_HOST}" "echo 'SSH key access verified.'" >/dev/null
echo "SSH key access is ready for ${PROXMOX_USER}@${PROXMOX_HOST}."
