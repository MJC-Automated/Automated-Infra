#!/usr/bin/env bash
# Discover core Proxmox settings required for environment bootstrap.

set -euo pipefail

PROXMOX_HOST="${PROXMOX_HOST:-}"
PROXMOX_USER="${PROXMOX_USER:-root}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-10}"
SSH_OPTIONS_RAW="${SSH_OPTIONS:-}"
OUTPUT_MODE="env" # env|export

SSH_OPTS_DEFAULT=(-o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" -o ServerAliveInterval=15 -o ServerAliveCountMax=3)
SSH_OPTS=()

usage() {
  cat <<'EOF'
Usage:
  discover-proxmox-core.sh [options]

Options:
  --host <ip-or-dns>    Proxmox host/IP (required if PROXMOX_HOST is not set).
  --user <name>         SSH user (default: root).
  --env                 Print KEY=VALUE lines (default).
  --export              Print shell export statements.
  -h, --help            Show this help.

Output keys:
  DISCOVERED_PROXMOX_HOST
  DISCOVERED_PROXMOX_NODE
  DISCOVERED_PROXMOX_API_URL
  DISCOVERED_ANSIBLE_HOST
  DISCOVERED_NETWORK_BRIDGE
  DISCOVERED_BRIDGE_IPCIDR
  DISCOVERED_PROXMOX_DEFAULT_GATEWAY
  DISCOVERED_STORAGE_POOL
  DISCOVERED_DATA_STORAGE
  DISCOVERED_BASE_VM_OS_STORAGE
  DISCOVERED_BASE_VM_DATA_STORAGE
  DISCOVERED_BASE_VM_EFI_STORAGE
  DISCOVERED_BASE_VM_CI_STORAGE
  DISCOVERED_BASE_VM_SNIPPET_STORAGE
  DISCOVERED_VMDISK_STORAGES
  DISCOVERED_SNIPPET_STORAGES
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
    --env)
      OUTPUT_MODE="env"
      shift
      ;;
    --export)
      OUTPUT_MODE="export"
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

discover_local_src_ip() {
  local target="$1"
  if command -v ip >/dev/null 2>&1; then
    ip -4 route get "${target}" 2>/dev/null | awk '{
      for (i = 1; i <= NF; i++) {
        if ($i == "src") {
          print $(i+1)
          exit
        }
      }
    }'
    return 0
  fi
  return 1
}

local_src_ip="$(discover_local_src_ip "${PROXMOX_HOST}" || true)"
if [[ -z "${local_src_ip}" ]]; then
  local_src_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
fi

remote_tmp="$(mktemp)"
cat > "${remote_tmp}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

list_storages_for_content() {
  local content="$1"
  pvesm status --content "${content}" 2>/dev/null | awk 'NR>1 && NF>0 {print $1}' | awk '!seen[$0]++' || true
}

list_to_csv() {
  local values="$1"
  if [[ -z "${values}" ]]; then
    printf '%s\n' ""
    return 0
  fi
  printf '%s\n' "${values}" | paste -sd',' -
}

pick_preferred_storage() {
  local storages="$1"
  shift
  local preferred=("$@")
  local storage
  if [[ -z "${storages}" ]]; then
    printf '%s\n' ""
    return 0
  fi
  for storage in "${preferred[@]}"; do
    if printf '%s\n' "${storages}" | grep -qx "${storage}"; then
      printf '%s\n' "${storage}"
      return 0
    fi
  done
  printf '%s\n' "${storages}" | head -n 1
}

pick_bridge() {
  local bridges bridge
  bridges="$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | awk '{print $1}' || true)"
  if [[ -z "${bridges}" ]]; then
    printf '%s\n' ""
    return 0
  fi
  for bridge in vmbr0 vmbr1; do
    if printf '%s\n' "${bridges}" | grep -qx "${bridge}"; then
      printf '%s\n' "${bridge}"
      return 0
    fi
  done
  printf '%s\n' "${bridges}" | head -n 1
}

node_name="$(hostname -s 2>/dev/null || hostname)"
bridge_name="$(pick_bridge)"
bridge_ipcidr=""
if [[ -n "${bridge_name}" ]]; then
  bridge_ipcidr="$(ip -4 -o addr show dev "${bridge_name}" 2>/dev/null | awk '{print $4; exit}' || true)"
fi
default_gw="$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}' || true)"

image_storages="$(list_storages_for_content images)"
snippet_storages="$(list_storages_for_content snippets)"
image_storage="$(pick_preferred_storage "${image_storages}" local-lvm local-zfs ceph-zpool rbd local)"
snippet_storage="$(pick_preferred_storage "${snippet_storages}" local local-lvm local-zfs ceph-zpool rbd)"

if [[ -z "${snippet_storage}" ]]; then
  # Safe fallback for many default installs where local supports snippets.
  snippet_storage="local"
fi
if [[ -z "${image_storage}" ]]; then
  # Last-resort fallback for minimal/atypical setups.
  image_storage="local-lvm"
fi

image_storages_csv="$(list_to_csv "${image_storages}")"
if [[ -z "${image_storages_csv}" ]]; then
  image_storages_csv="${image_storage}"
fi
snippet_storages_csv="$(list_to_csv "${snippet_storages}")"
if [[ -z "${snippet_storages_csv}" ]]; then
  snippet_storages_csv="${snippet_storage}"
fi

printf 'DISCOVERED_PROXMOX_NODE=%s\n' "${node_name}"
printf 'DISCOVERED_NETWORK_BRIDGE=%s\n' "${bridge_name}"
printf 'DISCOVERED_BRIDGE_IPCIDR=%s\n' "${bridge_ipcidr}"
printf 'DISCOVERED_PROXMOX_DEFAULT_GATEWAY=%s\n' "${default_gw}"
printf 'DISCOVERED_STORAGE_POOL=%s\n' "${image_storage}"
printf 'DISCOVERED_DATA_STORAGE=%s\n' "${image_storage}"
printf 'DISCOVERED_BASE_VM_OS_STORAGE=%s\n' "${image_storage}"
printf 'DISCOVERED_BASE_VM_DATA_STORAGE=%s\n' "${image_storage}"
printf 'DISCOVERED_BASE_VM_EFI_STORAGE=%s\n' "${image_storage}"
printf 'DISCOVERED_BASE_VM_CI_STORAGE=%s\n' "${image_storage}"
printf 'DISCOVERED_BASE_VM_SNIPPET_STORAGE=%s\n' "${snippet_storage}"
printf 'DISCOVERED_VMDISK_STORAGES=%s\n' "${image_storages_csv}"
printf 'DISCOVERED_SNIPPET_STORAGES=%s\n' "${snippet_storages_csv}"
EOF

remote_script_path="/tmp/discover-proxmox-core-$$.sh"
scp "${SSH_OPTS[@]}" "${remote_tmp}" "${PROXMOX_USER}@${PROXMOX_HOST}:${remote_script_path}" >/dev/null
remote_output="$(ssh "${SSH_OPTS[@]}" "${PROXMOX_USER}@${PROXMOX_HOST}" "bash '${remote_script_path}'; rm -f '${remote_script_path}'")"
rm -f "${remote_tmp}"

if [[ -z "${remote_output}" ]]; then
  echo "Error: failed to collect discovery data from ${PROXMOX_USER}@${PROXMOX_HOST}" >&2
  exit 1
fi

all_lines="$(
  {
    echo "DISCOVERED_PROXMOX_HOST=${PROXMOX_HOST}"
    echo "DISCOVERED_PROXMOX_API_URL=https://${PROXMOX_HOST}:8006/api2/json"
    echo "DISCOVERED_ANSIBLE_HOST=${local_src_ip}"
    printf '%s\n' "${remote_output}"
  }
)"

if [[ "${OUTPUT_MODE}" == "env" ]]; then
  printf '%s\n' "${all_lines}"
  exit 0
fi

# Convert KEY=VALUE lines into export statements.
while IFS='=' read -r key value; do
  [[ -n "${key}" ]] || continue
  printf 'export %s=%q\n' "${key}" "${value}"
done <<< "${all_lines}"
