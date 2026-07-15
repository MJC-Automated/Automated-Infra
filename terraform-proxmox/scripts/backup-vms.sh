#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENVIRONMENT="${ENVIRONMENT:-${TF_WORKSPACE:-dev}}"
PROXMOX_HOST="${PROXMOX_HOST:-}"
PROXMOX_USER="${PROXMOX_USER:-root}"
BACKUP_VMIDS="${BACKUP_VMIDS:-}"
CONFIRM="${CONFIRM:-}"
DRY_RUN="${DRY_RUN:-false}"
PROTECTED="${PROTECTED:-false}"
SSH_STRICT_HOST_KEY_CHECKING="${SSH_STRICT_HOST_KEY_CHECKING:-accept-new}"

usage() {
  cat <<'EOF'
Usage: backup-vms.sh [--environment <name>] [--vmids <id,id>] [--dry-run]

Runs a one-shot Proxmox vzdump for Terraform VMs whose resolved backup policy
is enabled. Set CONFIRM=YES for a real run. BACKUP_VMIDS or --vmids limits the
run without changing the declared policy. Set PROTECTED=true only for a final
decommission archive that must remain exempt from automatic pruning.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --environment)
      ENVIRONMENT="${2:-}"
      shift 2
      ;;
    --vmids)
      BACKUP_VMIDS="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
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

for command in jq ssh terraform; do
  command -v "${command}" >/dev/null 2>&1 || {
    echo "Error: required command is missing: ${command}" >&2
    exit 1
  }
done

[[ "${ENVIRONMENT}" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "Error: invalid environment name: ${ENVIRONMENT}" >&2
  exit 1
}

cd "${REPO_ROOT}"
workspace="$(terraform workspace show)"
if [[ "${workspace}" != "${ENVIRONMENT}" ]]; then
  echo "Error: Terraform workspace '${workspace}' does not match ENVIRONMENT='${ENVIRONMENT}'." >&2
  exit 1
fi

if [[ -z "${PROXMOX_HOST}" ]]; then
  PROXMOX_HOST="$(ENVIRONMENT="${ENVIRONMENT}" "${SCRIPT_DIR}/resolve-proxmox-host.sh")"
fi
[[ -n "${PROXMOX_HOST}" ]] || {
  echo "Error: unable to resolve the Proxmox host for ${ENVIRONMENT}." >&2
  exit 1
}

if [[ "${DRY_RUN}" != "true" && "${CONFIRM}" != "YES" ]]; then
  echo "Error: real VM backups require CONFIRM=YES." >&2
  exit 1
fi

[[ "${PROTECTED}" == "true" || "${PROTECTED}" == "false" ]] || {
  echo "Error: PROTECTED must be true or false." >&2
  exit 1
}
protected_flag=0
[[ "${PROTECTED}" == "true" ]] && protected_flag=1

policy_json="$(terraform output -json vm_backup_policy)"
settings_json="$(terraform output -json backup_job_settings)"
mode="$(jq -r '.mode' <<<"${settings_json}")"
compress="$(jq -r '.compress' <<<"${settings_json}")"
bwlimit="$(jq -r '.bandwidth_limit_kib' <<<"${settings_json}")"
ionice="$(jq -r '.ionice' <<<"${settings_json}")"
prune_backups="$(jq -r '
  .retention
  | "keep-last=\(.keep_last),keep-daily=\(.keep_daily),keep-weekly=\(.keep_weekly),keep-monthly=\(.keep_monthly),keep-yearly=\(.keep_yearly)"
' <<<"${settings_json}")"
mapfile -t rows < <(
  jq -rc '
    to_entries
    | map(.value)
    | map(select(.enabled == true))
    | sort_by(.vmid)
    | .[]
  ' <<<"${policy_json}"
)

if [[ ${#rows[@]} -eq 0 ]]; then
  echo "No VMs have backup enabled in the ${ENVIRONMENT} policy."
  exit 0
fi

selected_vmid() {
  local vmid="$1"
  [[ -z "${BACKUP_VMIDS}" ]] && return 0
  [[ ",${BACKUP_VMIDS// /}," == *",${vmid},"* ]]
}

ssh_opts=(
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o "StrictHostKeyChecking=${SSH_STRICT_HOST_KEY_CHECKING}"
)

backed_up=0
for row in "${rows[@]}"; do
  vmid="$(jq -r '.vmid' <<<"${row}")"
  name="$(jq -r '.name' <<<"${row}")"
  storage="$(jq -r '.storage // empty' <<<"${row}")"

  selected_vmid "${vmid}" || continue
  [[ "${vmid}" =~ ^[0-9]+$ ]] || {
    echo "Error: invalid VMID in backup policy: ${vmid}" >&2
    exit 1
  }
  [[ "${storage}" =~ ^[A-Za-z0-9._-]+$ ]] || {
    echo "Error: invalid or empty backup storage for VMID ${vmid}." >&2
    exit 1
  }

  remote="${PROXMOX_USER}@${PROXMOX_HOST}"
  ssh "${ssh_opts[@]}" "${remote}" \
    "qm status '${vmid}' >/dev/null && pvesm status --content backup | awk 'NR > 1 {print \$1}' | grep -Fxq '${storage}'"

  if [[ "${DRY_RUN}" == "true" ]]; then
    printf 'DRY-RUN: %s VMID=%s name=%s storage=%s protected=%s\n' \
      "${remote}" "${vmid}" "${name}" "${storage}" "${PROTECTED}"
  else
    echo "Backing up VMID ${vmid} (${name}) to ${storage} on ${PROXMOX_HOST}..."
    ssh "${ssh_opts[@]}" "${remote}" \
      "vzdump '${vmid}' --storage '${storage}' --mode '${mode}' --compress '${compress}' --bwlimit '${bwlimit}' --ionice '${ionice}' --prune-backups '${prune_backups}' --remove 1 --protected '${protected_flag}' --notes-template 'IaC-Homelab ${ENVIRONMENT}: {{guestname}} ({{vmid}}) on {{node}}'"
  fi
  backed_up=$((backed_up + 1))
done

if [[ ${backed_up} -eq 0 ]]; then
  echo "Error: no enabled VM matched BACKUP_VMIDS='${BACKUP_VMIDS}'." >&2
  exit 1
fi

echo "Processed ${backed_up} VM backup target(s) for ${ENVIRONMENT}."
