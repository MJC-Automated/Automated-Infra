#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENVIRONMENT="${ENVIRONMENT:-${TF_WORKSPACE:-dev}}"
PROXMOX_HOST="${PROXMOX_HOST:-}"
PROXMOX_USER="${PROXMOX_USER:-root}"
CONFIRM="${CONFIRM:-}"
DRY_RUN="${DRY_RUN:-false}"
SSH_STRICT_HOST_KEY_CHECKING="${SSH_STRICT_HOST_KEY_CHECKING:-accept-new}"

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
  echo "Error: changing Proxmox backup jobs requires CONFIRM=YES." >&2
  exit 1
fi

policy_json="$(terraform output -json vm_backup_policy)"
settings_json="$(terraform output -json backup_job_settings)"
target_node="$(jq -r '.target_node' <<<"${settings_json}")"
schedule="$(jq -r '.schedule' <<<"${settings_json}")"
mode="$(jq -r '.mode' <<<"${settings_json}")"
compress="$(jq -r '.compress' <<<"${settings_json}")"
bwlimit="$(jq -r '.bandwidth_limit_kib' <<<"${settings_json}")"
ionice="$(jq -r '.ionice' <<<"${settings_json}")"
notification_mode="$(jq -r '.notification_mode' <<<"${settings_json}")"
repeat_missed="$(jq -r 'if .repeat_missed then 1 else 0 end' <<<"${settings_json}")"
prune_backups="$(jq -r '
  .retention
  | "keep-last=\(.keep_last),keep-daily=\(.keep_daily),keep-weekly=\(.keep_weekly),keep-monthly=\(.keep_monthly),keep-yearly=\(.keep_yearly)"
' <<<"${settings_json}")"

jobs_json="$(jq -cn --argjson policy "${policy_json}" '
  [
    $policy
    | to_entries[].value
    | select(.enabled == true)
    | select(.storage != null and .storage != "")
  ]
  | sort_by(.storage, .vmid)
  | group_by(.storage)
  | map({
      storage: .[0].storage,
      vmids: (map(.vmid) | sort | map(tostring) | join(","))
    })
')"

ssh_opts=(
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o "StrictHostKeyChecking=${SSH_STRICT_HOST_KEY_CHECKING}"
)
remote="${PROXMOX_USER}@${PROXMOX_HOST}"
marker="Managed by IaC-Homelab environment=${ENVIRONMENT}"
desired_ids=()

run_remote() {
  local command_line
  printf -v command_line '%q ' "$@"
  if [[ "${DRY_RUN}" == "true" ]]; then
    printf 'DRY-RUN %s: %s\n' "${remote}" "${command_line}"
  else
    ssh "${ssh_opts[@]}" "${remote}" "${command_line}"
  fi
}

while IFS= read -r job; do
  [[ -n "${job}" ]] || continue
  storage="$(jq -r '.storage' <<<"${job}")"
  vmids="$(jq -r '.vmids' <<<"${job}")"
  job_id="iac-${ENVIRONMENT}-${storage}"
  job_id="$(tr '[:upper:]_' '[:lower:]-' <<<"${job_id}" | tr -cd 'a-z0-9.-')"
  desired_ids+=("${job_id}")

  ssh "${ssh_opts[@]}" "${remote}" \
    "pvesm status --content backup | awk 'NR > 1 {print \$1}' | grep -Fxq '${storage}'"

  args=(
    --enabled 1
    --node "${target_node}"
    --storage "${storage}"
    --vmid "${vmids}"
    --schedule "${schedule}"
    --mode "${mode}"
    --compress "${compress}"
    --bwlimit "${bwlimit}"
    --ionice "${ionice}"
    --repeat-missed "${repeat_missed}"
    --notification-mode "${notification_mode}"
    --prune-backups "${prune_backups}"
    --remove 1
    --notes-template "IaC-Homelab ${ENVIRONMENT}: {{guestname}} ({{vmid}}) on {{node}}"
    --comment "${marker}; storage=${storage}"
  )

  if ssh "${ssh_opts[@]}" "${remote}" "pvesh get '/cluster/backup/${job_id}' >/dev/null 2>&1"; then
    run_remote pvesh set "/cluster/backup/${job_id}" "${args[@]}"
  else
    run_remote pvesh create /cluster/backup --id "${job_id}" "${args[@]}"
  fi
done < <(jq -c '.[]' <<<"${jobs_json}")

existing_json="$(ssh "${ssh_opts[@]}" "${remote}" 'pvesh get /cluster/backup --output-format json')"
while IFS= read -r stale_id; do
  [[ -n "${stale_id}" ]] || continue
  keep=false
  for desired_id in "${desired_ids[@]}"; do
    [[ "${stale_id}" == "${desired_id}" ]] && keep=true
  done
  if [[ "${keep}" == false ]]; then
    run_remote pvesh delete "/cluster/backup/${stale_id}"
  fi
done < <(
  jq -r --arg marker "${marker}" '.[] | select((.comment // "") | startswith($marker)) | .id' <<<"${existing_json}"
)

if [[ ${#desired_ids[@]} -eq 0 ]]; then
  echo "No enabled VM backup jobs are declared for ${ENVIRONMENT}."
else
  printf 'Reconciled backup job(s): %s\n' "${desired_ids[*]}"
fi
