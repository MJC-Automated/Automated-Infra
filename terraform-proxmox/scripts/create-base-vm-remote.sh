#!/usr/bin/env bash
# Run create-cloudinit-vm_stable.sh remotely on a Proxmox host with env overrides.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
CLOUD_IMAGE_CATALOG="${CLOUD_IMAGE_CATALOG:-${REPO_ROOT}/config/cloud-images.env}"
if [[ -r "${CLOUD_IMAGE_CATALOG}" ]]; then
  # shellcheck disable=SC1090
  source "${CLOUD_IMAGE_CATALOG}"
fi

PROXMOX_HOST="${PROXMOX_HOST:-}"
PROXMOX_USER="${PROXMOX_USER:-root}"
LOCAL_SCRIPT="${LOCAL_SCRIPT:-${REPO_ROOT}/scripts/create-cloudinit-vm_stable.sh}"
REMOTE_SCRIPT="${REMOTE_SCRIPT:-/tmp/create-cloudinit-vm_stable.sh}"
REMOTE_ENV_FILE="${REMOTE_ENV_FILE:-/root/scripts/.env}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-10}"
SSH_OPTIONS_RAW="${SSH_OPTIONS:-}"
AUTO_DOWNLOAD_IMAGE="${AUTO_DOWNLOAD_IMAGE:-true}"
UBUNTU_IMAGE_URL="${UBUNTU_IMAGE_URL:-${CLOUD_IMAGE_UBUNTU24_URL:-https://cloud-images.ubuntu.com/noble/20260826/noble-server-cloudimg-amd64.img}}"
UBUNTU24_IMAGE_URL="${UBUNTU24_IMAGE_URL:-${UBUNTU_IMAGE_URL}}"
ORACLE8_IMAGE_URL="${ORACLE8_IMAGE_URL:-${CLOUD_IMAGE_ORACLE8_URL:-https://yum.oracle.com/templates/OracleLinux/OL8/u10/x86_64/OL8U10_x86_64-kvm-b287.qcow2}}"
ORACLE9_IMAGE_URL="${ORACLE9_IMAGE_URL:-${CLOUD_IMAGE_ORACLE9_URL:-https://yum.oracle.com/templates/OracleLinux/OL9/u8/x86_64/OL9U8_x86_64-kvm-b293.qcow2}}"
DOWNLOAD_IMAGE_SCRIPT="${DOWNLOAD_IMAGE_SCRIPT:-${REPO_ROOT}/scripts/download-cloud-image.sh}"

ORACLE8_IMAGE_SHA256="${ORACLE8_IMAGE_SHA256:-${CLOUD_IMAGE_ORACLE8_SHA256:-}}"
ORACLE9_IMAGE_SHA256="${ORACLE9_IMAGE_SHA256:-${CLOUD_IMAGE_ORACLE9_SHA256:-}}"
UBUNTU24_IMAGE_SHA256="${UBUNTU24_IMAGE_SHA256:-${CLOUD_IMAGE_UBUNTU24_SHA256:-}}"

ORACLE8_CHECKSUM_URL="${ORACLE8_CHECKSUM_URL:-${CLOUD_IMAGE_ORACLE8_CHECKSUM_URL:-}}"
ORACLE9_CHECKSUM_URL="${ORACLE9_CHECKSUM_URL:-${CLOUD_IMAGE_ORACLE9_CHECKSUM_URL:-}}"
UBUNTU24_CHECKSUM_URL="${UBUNTU24_CHECKSUM_URL:-${CLOUD_IMAGE_UBUNTU24_CHECKSUM_URL:-}}"

SSH_OPTS_DEFAULT=(-o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" -o ServerAliveInterval=15 -o ServerAliveCountMax=3)
SSH_OPTS=()

usage() {
  cat <<'EOF'
Usage:
  create-base-vm-remote.sh [options]

Options:
  --host <ip-or-dns>      Proxmox host/IP (required if PROXMOX_HOST is not set).
  --user <name>           SSH user (default: root).
  --local-script <path>   Local create-cloudinit script path.
  --remote-script <path>  Remote temporary script path.
  --remote-env <path>     Existing root-only environment file on the PVE
                          (default: /root/scripts/.env).
  -h, --help              Show this help.

Required VM overrides (via env vars or current shell):
  VMID, NAME, OS_TYPE

Optional VM overrides:
  DOMAIN FORCE DRY_RUN
  SOURCE_IMAGE ORACLE_LINUX_IMAGE UBUNTU_IMAGE ROCKY_LINUX_IMAGE ALMA_LINUX_IMAGE DEBIAN_IMAGE FEDORA_IMAGE
  AUTO_DOWNLOAD_IMAGE
  ORACLE8_IMAGE_URL ORACLE9_IMAGE_URL UBUNTU24_IMAGE_URL
  ORACLE8_IMAGE_SHA256 ORACLE9_IMAGE_SHA256 UBUNTU24_IMAGE_SHA256
  ORACLE8_CHECKSUM_URL ORACLE9_CHECKSUM_URL UBUNTU24_CHECKSUM_URL
  BRIDGE NETWORK_VLAN IPCIDR GATEWAY DNS
  CORES MEM CPU_TYPE
  OS_STORAGE DATA_STORAGE EFI_STORAGE CI_STORAGE SNIPPET_STORAGE
  OS_DISK_SIZE DATA_DISK_ENABLED DATA_DISK_SIZE
  CIUSER PASSWORD SSH_KEYS_FILE
  ZABBIX_SERVER ZABBIX_SERVER_PASSIVE ZABBIX_SERVER_ACTIVE ZABBIX_AGENT_PORT
  DO_OS_UPDATE SANITIZE_TEMPLATE_BASE SHUTDOWN_FINAL_VM
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
    --local-script)
      LOCAL_SCRIPT="${2:-}"
      shift 2
      ;;
    --remote-script)
      REMOTE_SCRIPT="${2:-}"
      shift 2
      ;;
    --remote-env)
      REMOTE_ENV_FILE="${2:-}"
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

if [[ ! -f "${LOCAL_SCRIPT}" ]]; then
  echo "Error: local script not found: ${LOCAL_SCRIPT}" >&2
  exit 1
fi

for required_var in VMID NAME OS_TYPE; do
  if [[ -z "${!required_var:-}" ]]; then
    echo "Error: ${required_var} must be set." >&2
    exit 1
  fi
done

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

pass_vars=(
  VMID NAME DOMAIN FORCE DRY_RUN OS_TYPE ENV_FILE SOURCE_IMAGE
  ORACLE_LINUX_IMAGE UBUNTU_IMAGE ROCKY_LINUX_IMAGE ALMA_LINUX_IMAGE DEBIAN_IMAGE FEDORA_IMAGE
  BRIDGE NETWORK_VLAN IPCIDR GATEWAY DNS
  CORES MEM CPU_TYPE
  OS_STORAGE DATA_STORAGE EFI_STORAGE CI_STORAGE SNIPPET_STORAGE
  OS_DISK_SIZE DATA_DISK_ENABLED DATA_DISK_SIZE
  CIUSER PASSWORD SSH_KEYS_FILE
  ZABBIX_SERVER ZABBIX_SERVER_PASSIVE ZABBIX_SERVER_ACTIVE ZABBIX_AGENT_PORT
  DO_OS_UPDATE SANITIZE_TEMPLATE_BASE SHUTDOWN_FINAL_VM
)

build_remote_prefix() {
  local prefix=""
  local var_name value escaped
  for var_name in "${pass_vars[@]}"; do
    value="${!var_name:-}"
    if [[ -n "${value}" ]]; then
      escaped="$(printf '%q' "${value}")"
      prefix+="${var_name}=${escaped} "
    fi
  done
  printf '%s' "${prefix}"
}

remote_file_exists() {
  local path="$1"
  local escaped
  escaped="$(printf '%q' "${path}")"
  ssh "${SSH_OPTS[@]}" "${PROXMOX_USER}@${PROXMOX_HOST}" "test -f ${escaped}"
}

remote_file_readable() {
  local path="$1"
  local escaped
  escaped="$(printf '%q' "${path}")"
  ssh "${SSH_OPTS[@]}" "${PROXMOX_USER}@${PROXMOX_HOST}" "test -r ${escaped}"
}

resolve_required_image_path() {
  if [[ -n "${SOURCE_IMAGE:-}" ]]; then
    printf '%s\n' "${SOURCE_IMAGE}"
    return 0
  fi

  case "${OS_TYPE}" in
    ubuntu|ubuntu-24|ubuntu24)
      printf '%s\n' "${UBUNTU_IMAGE:-/var/lib/vz/template/iso/${CLOUD_IMAGE_UBUNTU24_FILENAME:-noble-server-cloudimg-amd64.img}}"
      ;;
    oracle-linux-8|oracle8|ol8)
      printf '%s\n' "${ORACLE_LINUX_IMAGE:-/var/lib/vz/template/iso/${CLOUD_IMAGE_ORACLE8_FILENAME:-OL8U10_x86_64-kvm-b287.qcow2}}"
      ;;
    oracle-linux|oracle-linux-9|oracle9|ol9)
      printf '%s\n' "${ORACLE_LINUX_IMAGE:-/var/lib/vz/template/iso/${CLOUD_IMAGE_ORACLE9_FILENAME:-OL9U8_x86_64-kvm-b293.qcow2}}"
      ;;
    rocky-linux)
      printf '%s\n' "${ROCKY_LINUX_IMAGE:-/var/lib/vz/template/iso/Rocky-9-GenericCloud.latest.x86_64.qcow2}"
      ;;
    alma-linux)
      printf '%s\n' "${ALMA_LINUX_IMAGE:-/var/lib/vz/template/iso/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2}"
      ;;
    debian)
      printf '%s\n' "${DEBIAN_IMAGE:-/var/lib/vz/template/iso/debian-12-genericcloud-amd64.qcow2}"
      ;;
    fedora)
      printf '%s\n' "${FEDORA_IMAGE:-/var/lib/vz/template/iso/Fedora-Cloud-Base-Generic-43-1.6.x86_64.qcow2}"
      ;;
    *)
      printf '%s\n' ""
      ;;
  esac
}

resolve_common_image_key() {
  local image_path="$1"
  local image_basename
  image_basename="$(basename "${image_path}")"

  case "${image_basename}" in
    noble-server-cloudimg-amd64.img) printf '%s\n' "ubuntu24" ;;
    OL8*_x86_64-kvm-*.qcow2) printf '%s\n' "oracle8" ;;
    OL9*_x86_64-kvm-*.qcow2) printf '%s\n' "oracle9" ;;
    *) return 1 ;;
  esac
}

ensure_remote_common_image() {
  local image_path="$1"
  local image_key="$2"
  local image_dir

  if [[ ! -x "${DOWNLOAD_IMAGE_SCRIPT}" ]]; then
    echo "Error: download image helper not executable: ${DOWNLOAD_IMAGE_SCRIPT}" >&2
    exit 1
  fi

  image_dir="$(dirname "${image_path}")"
  echo "Remote image missing. Syncing '${image_key}' to ${image_dir} on ${PROXMOX_HOST}..."

  PROXMOX_HOST="${PROXMOX_HOST}" \
  PROXMOX_USER="${PROXMOX_USER}" \
  SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT}" \
  SSH_OPTIONS="${SSH_OPTIONS_RAW}" \
  IMAGE_DIR="${image_dir}" \
  ORACLE8_IMAGE_URL="${ORACLE8_IMAGE_URL}" \
  ORACLE9_IMAGE_URL="${ORACLE9_IMAGE_URL}" \
  UBUNTU24_IMAGE_URL="${UBUNTU24_IMAGE_URL}" \
  ORACLE8_IMAGE_SHA256="${ORACLE8_IMAGE_SHA256}" \
  ORACLE9_IMAGE_SHA256="${ORACLE9_IMAGE_SHA256}" \
  UBUNTU24_IMAGE_SHA256="${UBUNTU24_IMAGE_SHA256}" \
  ORACLE8_CHECKSUM_URL="${ORACLE8_CHECKSUM_URL}" \
  ORACLE9_CHECKSUM_URL="${ORACLE9_CHECKSUM_URL}" \
  UBUNTU24_CHECKSUM_URL="${UBUNTU24_CHECKSUM_URL}" \
    "${DOWNLOAD_IMAGE_SCRIPT}" --host "${PROXMOX_HOST}" --user "${PROXMOX_USER}" --image-dir "${image_dir}" --images "${image_key}"

  remote_file_exists "${image_path}" || {
    echo "Error: required image is still missing after sync: ${image_path}" >&2
    exit 1
  }
}

required_image_path="$(resolve_required_image_path)"
if [[ -n "${required_image_path}" ]]; then
  if ! remote_file_exists "${required_image_path}"; then
    if [[ "${AUTO_DOWNLOAD_IMAGE,,}" != "true" ]]; then
      echo "Error: required image missing on ${PROXMOX_HOST}: ${required_image_path}" >&2
      echo "Set AUTO_DOWNLOAD_IMAGE=true or upload the image manually." >&2
      exit 1
    fi

    if image_key="$(resolve_common_image_key "${required_image_path}")"; then
      ensure_remote_common_image "${required_image_path}" "${image_key}"
    else
      echo "Error: required image missing on ${PROXMOX_HOST}: ${required_image_path}" >&2
      echo "Unable to map this path to built-in common images for auto-download." >&2
      echo "Set an explicit path to a pre-seeded image, or use a supported basename." >&2
      exit 1
    fi
  fi
fi

if [[ -n "${required_image_path}" ]] && ! remote_file_exists "${required_image_path}"; then
    echo "Error: required image missing on ${PROXMOX_HOST}: ${required_image_path}" >&2
    echo "Provide image path env override for ${OS_TYPE} or place the image on Proxmox before continuing." >&2
    exit 1
fi

SOURCE_IMAGE="${SOURCE_IMAGE:-${required_image_path}}"
ENV_FILE="${REMOTE_ENV_FILE}"

if ! remote_file_readable "${REMOTE_ENV_FILE}"; then
  echo "Error: remote environment file is not readable on ${PROXMOX_HOST}: ${REMOTE_ENV_FILE}" >&2
  echo "Create it from scripts/.env.example with mode 600 before running the builder." >&2
  exit 1
fi

remote_prefix="$(build_remote_prefix)"

echo "Copying ${LOCAL_SCRIPT} to ${PROXMOX_USER}@${PROXMOX_HOST}:${REMOTE_SCRIPT}..."
scp "${SSH_OPTS[@]}" "${LOCAL_SCRIPT}" "${PROXMOX_USER}@${PROXMOX_HOST}:${REMOTE_SCRIPT}"

echo "Running remote base VM build on ${PROXMOX_HOST} (VMID=${VMID}, NAME=${NAME}, OS_TYPE=${OS_TYPE})..."
ssh "${SSH_OPTS[@]}" "${PROXMOX_USER}@${PROXMOX_HOST}" "${remote_prefix}bash '${REMOTE_SCRIPT}'"

echo "Remote base VM build completed on ${PROXMOX_HOST}."
