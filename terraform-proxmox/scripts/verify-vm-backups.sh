#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENVIRONMENT="${ENVIRONMENT:-${TF_WORKSPACE:-dev}}"
PROXMOX_HOST="${PROXMOX_HOST:-}"
PROXMOX_USER="${PROXMOX_USER:-root}"
BACKUP_VMIDS="${BACKUP_VMIDS:-}"

cd "${REPO_ROOT}"
[[ "$(terraform workspace show)" == "${ENVIRONMENT}" ]] || {
  echo "Error: select Terraform workspace ${ENVIRONMENT} first." >&2
  exit 1
}
if [[ -z "${PROXMOX_HOST}" ]]; then
  PROXMOX_HOST="$(ENVIRONMENT="${ENVIRONMENT}" "${SCRIPT_DIR}/resolve-proxmox-host.sh")"
fi

policy_json="$(terraform output -json vm_backup_policy)"
settings_json="$(terraform output -json backup_job_settings)"
max_age_hours="$(jq -r '.max_backup_age_hours' <<<"${settings_json}")"
now_epoch="$(date +%s)"
failures=0
checked=0

selected_vmid() {
  local vmid="$1"
  [[ -z "${BACKUP_VMIDS}" ]] || [[ ",${BACKUP_VMIDS// /}," == *",${vmid},"* ]]
}

while IFS= read -r row; do
  vmid="$(jq -r '.vmid' <<<"${row}")"
  name="$(jq -r '.name' <<<"${row}")"
  storage="$(jq -r '.storage' <<<"${row}")"
  selected_vmid "${vmid}" || continue
  checked=$((checked + 1))

  latest_epoch="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "${PROXMOX_USER}@${PROXMOX_HOST}" bash -s -- "${storage}" "${vmid}" <<'REMOTE'
set -euo pipefail
storage="$1"
vmid="$2"
path="$(pvesh get "/storage/${storage}" --output-format json | jq -r '.path // empty')"
[[ -n "${path}" ]] || exit 2
find "${path}/dump" -maxdepth 1 -type f -size +0c \
  \( -name "vzdump-qemu-${vmid}-*.vma" \
     -o -name "vzdump-qemu-${vmid}-*.vma.gz" \
     -o -name "vzdump-qemu-${vmid}-*.vma.lzo" \
     -o -name "vzdump-qemu-${vmid}-*.vma.zst" \) \
  -printf '%T@\n' 2>/dev/null \
  | sort -nr \
  | head -n 1 \
  | cut -d. -f1
REMOTE
)"

  if [[ -z "${latest_epoch}" ]]; then
    echo "FAIL: no VM backup found for ${name} (VMID ${vmid}) on ${storage}." >&2
    failures=$((failures + 1))
    continue
  fi

  age_hours=$(((now_epoch - latest_epoch) / 3600))
  if (( age_hours > max_age_hours )); then
    echo "FAIL: latest backup for ${name} is ${age_hours}h old; policy maximum is ${max_age_hours}h." >&2
    failures=$((failures + 1))
  else
    echo "PASS: ${name} VMID=${vmid} storage=${storage} age=${age_hours}h"
  fi
done < <(jq -c 'to_entries | map(.value) | map(select(.enabled == true)) | sort_by(.vmid) | .[]' <<<"${policy_json}")

if [[ ${checked} -eq 0 ]]; then
  echo "Error: no enabled backup target matched BACKUP_VMIDS='${BACKUP_VMIDS}'." >&2
  exit 1
fi
if [[ ${failures} -ne 0 ]]; then
  echo "Backup freshness verification failed for ${failures} of ${checked} target(s)." >&2
  exit 1
fi
echo "Backup freshness verification passed for ${checked} target(s)."
