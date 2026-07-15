#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENVIRONMENT="${ENVIRONMENT:-${TF_WORKSPACE:-dev}}"
PROXMOX_HOST="${PROXMOX_HOST:-}"
PROXMOX_USER="${PROXMOX_USER:-root}"
SOURCE_VMID="${SOURCE_VMID:-}"
RESTORE_VMID="${RESTORE_VMID:-}"
RESTORE_STORAGE="${RESTORE_STORAGE:-}"
CONFIRM="${CONFIRM:-}"
CLEANUP="${CLEANUP:-false}"

usage() {
  cat <<'EOF'
Usage: restore-drill.sh --source-vmid <id> --restore-vmid <99999998x> [options]

Options:
  --restore-storage <id>  Override the destination VM-disk storage.
  --cleanup               Destroy the stopped drill VM after config checks.

A real restore requires CONFIRM=YES. The restored VM is never started because
it retains the source guest's hostname and IP configuration.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-vmid)
      SOURCE_VMID="${2:-}"
      shift 2
      ;;
    --restore-vmid)
      RESTORE_VMID="${2:-}"
      shift 2
      ;;
    --restore-storage)
      RESTORE_STORAGE="${2:-}"
      shift 2
      ;;
    --cleanup)
      CLEANUP=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

[[ "${SOURCE_VMID}" =~ ^[0-9]+$ ]] || {
  echo "Error: --source-vmid must be numeric." >&2
  exit 1
}
[[ "${RESTORE_VMID}" =~ ^99999998[0-9]$ ]] || {
  echo "Error: restore drills are restricted to VMIDs 999999980-999999989." >&2
  exit 1
}
[[ "${CONFIRM}" == "YES" ]] || {
  echo "Error: restore drills require CONFIRM=YES." >&2
  exit 1
}

cd "${REPO_ROOT}"
[[ "$(terraform workspace show)" == "${ENVIRONMENT}" ]] || {
  echo "Error: select Terraform workspace ${ENVIRONMENT} first." >&2
  exit 1
}
if [[ -z "${PROXMOX_HOST}" ]]; then
  PROXMOX_HOST="$(ENVIRONMENT="${ENVIRONMENT}" "${SCRIPT_DIR}/resolve-proxmox-host.sh")"
fi

policy_json="$(terraform output -json vm_backup_policy)"
source_policy="$(jq -c --argjson vmid "${SOURCE_VMID}" '
  to_entries
  | map(.value)
  | map(select(.vmid == $vmid and .enabled == true))
  | first // empty
' <<<"${policy_json}")"
[[ -n "${source_policy}" ]] || {
  echo "Error: VMID ${SOURCE_VMID} is not enabled in the declared backup policy." >&2
  exit 1
}
backup_storage="$(jq -r '.storage' <<<"${source_policy}")"
if [[ -z "${RESTORE_STORAGE}" ]]; then
  RESTORE_STORAGE="$(terraform output -json all_nodes_summary | jq -r --argjson vmid "${SOURCE_VMID}" '
    to_entries | map(.value) | map(select(.vmid == $vmid)) | first.full_info.bootdisk_storage // empty
  ')"
fi
[[ "${RESTORE_STORAGE}" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "Error: unable to resolve a safe restore storage; set --restore-storage." >&2
  exit 1
}

remote="${PROXMOX_USER}@${PROXMOX_HOST}"
ssh -o BatchMode=yes "${remote}" bash -s -- \
  "${SOURCE_VMID}" "${RESTORE_VMID}" "${backup_storage}" "${RESTORE_STORAGE}" "${CLEANUP}" <<'REMOTE'
set -euo pipefail
source_vmid="$1"
restore_vmid="$2"
backup_storage="$3"
restore_storage="$4"
cleanup="$5"

if qm status "${restore_vmid}" >/dev/null 2>&1; then
  echo "Error: restore VMID ${restore_vmid} already exists." >&2
  exit 1
fi
backup_path="$(pvesh get "/storage/${backup_storage}" --output-format json | jq -r '.path // empty')"
[[ -n "${backup_path}" ]] || {
  echo "Error: backup storage ${backup_storage} is not a path-backed datastore." >&2
  exit 1
}
archive="$(find "${backup_path}/dump" -maxdepth 1 -type f -size +0c \
  \( -name "vzdump-qemu-${source_vmid}-*.vma" \
     -o -name "vzdump-qemu-${source_vmid}-*.vma.gz" \
     -o -name "vzdump-qemu-${source_vmid}-*.vma.lzo" \
     -o -name "vzdump-qemu-${source_vmid}-*.vma.zst" \) \
  -printf '%T@ %p\n' \
  | sort -nr | head -n 1 | cut -d' ' -f2-)"
[[ -n "${archive}" ]] || {
  echo "Error: no backup archive found for source VMID ${source_vmid}." >&2
  exit 1
}

echo "Restoring ${archive} to disposable VMID ${restore_vmid} on ${restore_storage}..."
qmrestore "${archive}" "${restore_vmid}" --storage "${restore_storage}" --unique 1
[[ "$(qm status "${restore_vmid}" | awk '{print $2}')" == "stopped" ]]
qm config "${restore_vmid}"

if [[ "${cleanup}" == "true" ]]; then
  qm destroy "${restore_vmid}" --purge 1 --destroy-unreferenced-disks 1
  echo "Restore drill passed and disposable VMID ${restore_vmid} was removed."
else
  echo "Restore drill VMID ${restore_vmid} remains stopped for inspection."
fi
REMOTE
