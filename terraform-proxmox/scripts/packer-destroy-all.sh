#!/usr/bin/env bash
set -euo pipefail

# Destroy Packer-generated VMs for a given environment by reading vm_id values
# from packer/*/vars.<env>.pkrvars.hcl and calling the Proxmox API.
#
# Usage:
#   ./scripts/packer-destroy-all.sh dev
#   ENVIRONMENT=dev ./scripts/packer-destroy-all.sh
#
# Optional env vars:
#   PACKER_ROOT=<path>   # default: <repo>/packer
#   DRY_RUN=1            # print actions only, no API calls
#   PACKER_USE_VAULT_CREDS=true|false # default: true
#   VAULT_PATH=<path>    # default: secret/terraform/<env>/creds
#   VAULT_AUTH_SCRIPT=<path> # default: <repo>/scripts/vault-auth.sh

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

PACKER_ROOT="${PACKER_ROOT:-${REPO_ROOT}/packer}"
ENVIRONMENT="${ENVIRONMENT:-${1:-dev}}"
DRY_RUN="${DRY_RUN:-0}"
PACKER_USE_VAULT_CREDS="${PACKER_USE_VAULT_CREDS:-true}"
VAULT_PATH="${VAULT_PATH:-secret/terraform/${ENVIRONMENT}/creds}"
VAULT_AUTH_SCRIPT="${VAULT_AUTH_SCRIPT:-${REPO_ROOT}/scripts/vault-auth.sh}"

if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is required." >&2
  exit 1
fi

hcl_get() {
  local file="$1"
  local key="$2"
  awk -v key="${key}" '
    match($0, "^[[:space:]]*" key "[[:space:]]*=") {
      line = $0
      sub(/^[[:space:]]*[^=]+=[[:space:]]*/, "", line)
      sub(/[[:space:]]*#.*/, "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line ~ /^".*"$/) {
        sub(/^"/, "", line)
        sub(/"$/, "", line)
      }
      print line
      exit
    }
  ' "${file}"
}

is_true() {
  local val="${1,,}"
  [[ "${val}" == "true" || "${val}" == "1" || "${val}" == "yes" ]]
}

VAULT_PROXMOX_API_URL=""
VAULT_PROXMOX_TOKEN_ID=""
VAULT_PROXMOX_TOKEN_SECRET=""
VAULT_PROXMOX_TLS_INSECURE=""

load_vault_credentials() {
  if ! command -v vault >/dev/null 2>&1; then
    echo "Error: vault CLI is required when PACKER_USE_VAULT_CREDS=true." >&2
    exit 1
  fi
  if [[ -z "${VAULT_ADDR:-}" ]]; then
    echo "Error: VAULT_ADDR is not set (required when PACKER_USE_VAULT_CREDS=true)." >&2
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

  VAULT_PROXMOX_API_URL="$(vault kv get -field=proxmox_config_api_url "${VAULT_PATH}")"
  VAULT_PROXMOX_TOKEN_ID="$(vault kv get -field=proxmox_config_api_token_id "${VAULT_PATH}")"
  VAULT_PROXMOX_TOKEN_SECRET="$(vault kv get -field=proxmox_config_api_token_secret "${VAULT_PATH}")"
  VAULT_PROXMOX_TLS_INSECURE="$(vault kv get -field=proxmox_config_tls_insecure "${VAULT_PATH}" 2>/dev/null || true)"

  if [[ -z "${VAULT_PROXMOX_API_URL}" || -z "${VAULT_PROXMOX_TOKEN_ID}" || -z "${VAULT_PROXMOX_TOKEN_SECRET}" ]]; then
    echo "Error: missing required Proxmox credential fields in ${VAULT_PATH}." >&2
    exit 1
  fi
}

normalize_api_url() {
  local url="${1%/}"
  if [[ "${url}" != */api2/json ]]; then
    url="${url}/api2/json"
  fi
  printf '%s\n' "${url}"
}

REQ_BODY=""
REQ_CODE=""
api_request() {
  local method="$1"
  local url="$2"
  local token_id="$3"
  local token_secret="$4"
  local tls_insecure="$5"
  local data="${6:-}"

  local -a cmd=(
    curl
    -sS
    -X "${method}"
    -H "Authorization: PVEAPIToken=${token_id}=${token_secret}"
  )
  if is_true "${tls_insecure}"; then
    cmd+=(-k)
  fi
  if [[ -n "${data}" ]]; then
    cmd+=(-H "Content-Type: application/x-www-form-urlencoded" --data "${data}")
  fi
  cmd+=(-w $'\n%{http_code}' "${url}")

  local resp
  if ! resp="$("${cmd[@]}")"; then
    REQ_BODY=""
    REQ_CODE="000"
    return 1
  fi

  REQ_CODE="${resp##*$'\n'}"
  REQ_BODY="${resp%$'\n'*}"
  return 0
}

json_status() {
  sed -n 's/.*"status":"\([^"]*\)".*/\1/p' | head -1
}

json_data_string() {
  sed -n 's/.*"data":"\([^"]*\)".*/\1/p' | head -1
}

json_exitstatus() {
  sed -n 's/.*"exitstatus":"\([^"]*\)".*/\1/p' | head -1
}

is_vm_absent_response() {
  [[ "${REQ_CODE}" == "404" ]] ||
    [[ "${REQ_CODE}" == "500" && "${REQ_BODY}" == *"does not exist"* ]]
}

wait_for_stopped() {
  local api_url="$1"
  local node="$2"
  local vm_id="$3"
  local token_id="$4"
  local token_secret="$5"
  local tls_insecure="$6"

  local status=""
  local status_url="${api_url}/nodes/${node}/qemu/${vm_id}/status/current"
  for _ in $(seq 1 30); do
    api_request GET "${status_url}" "${token_id}" "${token_secret}" "${tls_insecure}" || true
    if is_vm_absent_response; then
      printf 'absent\n'
      return 0
    fi
    if [[ "${REQ_CODE}" == "200" ]]; then
      status="$(printf '%s' "${REQ_BODY}" | json_status)"
      if [[ "${status}" == "stopped" ]]; then
        printf 'stopped\n'
        return 0
      fi
    fi
    sleep 2
  done

  printf 'timeout\n'
  return 0
}

wait_for_task_completion() {
  local api_url="$1"
  local node="$2"
  local upid="$3"
  local token_id="$4"
  local token_secret="$5"
  local tls_insecure="$6"

  local task_url="${api_url}/nodes/${node}/tasks/${upid}/status"
  local task_state=""
  local task_exitstatus=""

  for _ in $(seq 1 150); do
    api_request GET "${task_url}" "${token_id}" "${token_secret}" "${tls_insecure}" || true
    if [[ "${REQ_CODE}" == "404" ]]; then
      printf 'missing\n'
      return 0
    fi
    if [[ "${REQ_CODE}" == "200" ]]; then
      task_state="$(printf '%s' "${REQ_BODY}" | json_status)"
      if [[ "${task_state}" == "stopped" ]]; then
        task_exitstatus="$(printf '%s' "${REQ_BODY}" | json_exitstatus)"
        if [[ -z "${task_exitstatus}" || "${task_exitstatus}" == "OK" ]]; then
          printf 'ok\n'
        else
          printf 'error:%s\n' "${task_exitstatus}"
        fi
        return 0
      fi
    fi
    sleep 2
  done

  printf 'timeout\n'
  return 0
}

wait_for_absent() {
  local api_url="$1"
  local node="$2"
  local vm_id="$3"
  local token_id="$4"
  local token_secret="$5"
  local tls_insecure="$6"

  local status_url="${api_url}/nodes/${node}/qemu/${vm_id}/status/current"
  for _ in $(seq 1 120); do
    api_request GET "${status_url}" "${token_id}" "${token_secret}" "${tls_insecure}" || true
    if is_vm_absent_response; then
      return 0
    fi
    sleep 2
  done
  return 1
}

shopt -s nullglob
declare -a var_files=("${PACKER_ROOT}"/*/vars."${ENVIRONMENT}".pkrvars.hcl)
shopt -u nullglob

if [[ "${#var_files[@]}" -eq 0 ]]; then
  echo "No packer vars files found for ENVIRONMENT=${ENVIRONMENT} under ${PACKER_ROOT}" >&2
  exit 1
fi

declare -A seen_targets=()
declare -a targets=()

if is_true "${PACKER_USE_VAULT_CREDS}"; then
  load_vault_credentials
  echo "Using Proxmox API credentials from Vault path ${VAULT_PATH}."
fi

for var_file in "${var_files[@]}"; do
  proxmox_api_url="$(hcl_get "${var_file}" proxmox_api_url)"
  proxmox_node="$(hcl_get "${var_file}" proxmox_node)"
  proxmox_token_id="$(hcl_get "${var_file}" proxmox_token_id)"
  proxmox_token="$(hcl_get "${var_file}" proxmox_token)"
  proxmox_tls_insecure="$(hcl_get "${var_file}" proxmox_tls_insecure)"
  vm_id="$(hcl_get "${var_file}" vm_id)"
  template_name="$(hcl_get "${var_file}" template_name)"

  if is_true "${PACKER_USE_VAULT_CREDS}"; then
    proxmox_api_url="${VAULT_PROXMOX_API_URL}"
    proxmox_token_id="${VAULT_PROXMOX_TOKEN_ID}"
    proxmox_token="${VAULT_PROXMOX_TOKEN_SECRET}"
    if [[ -n "${VAULT_PROXMOX_TLS_INSECURE}" ]]; then
      proxmox_tls_insecure="${VAULT_PROXMOX_TLS_INSECURE}"
    fi
  fi

  if [[ -z "${proxmox_api_url}" || -z "${proxmox_node}" || -z "${proxmox_token_id}" || -z "${proxmox_token}" || -z "${vm_id}" ]]; then
    echo "Warning: skipping ${var_file} (missing one of proxmox_api_url/proxmox_node/proxmox_token_id/proxmox_token/vm_id)" >&2
    continue
  fi

  api_url="$(normalize_api_url "${proxmox_api_url}")"
  tls_mode="${proxmox_tls_insecure:-false}"
  label="${template_name:-$(basename "$(dirname "${var_file}")")}"

  key="${api_url}|${proxmox_node}|${vm_id}|${proxmox_token_id}"
  if [[ -n "${seen_targets["${key}"]+x}" ]]; then
    continue
  fi
  seen_targets["${key}"]=1
  targets+=("${api_url}|${proxmox_node}|${vm_id}|${proxmox_token_id}|${proxmox_token}|${tls_mode}|${label}|${var_file}")
done

if [[ "${#targets[@]}" -eq 0 ]]; then
  echo "No valid packer destroy targets discovered for ENVIRONMENT=${ENVIRONMENT}." >&2
  exit 1
fi

echo "Packer destroy targets for ENVIRONMENT=${ENVIRONMENT}:"
for target in "${targets[@]}"; do
  IFS='|' read -r api_url node vm_id _ _ _ label var_file <<< "${target}"
  echo "  - ${label} vmid=${vm_id} node=${node} api=${api_url} (from ${var_file})"
done

if is_true "${DRY_RUN}"; then
  echo "DRY_RUN=1 set; no API calls made."
  exit 0
fi

errors=0
deleted=0
skipped=0
pending=0

for target in "${targets[@]}"; do
  IFS='|' read -r api_url node vm_id token_id token_secret tls_mode label _ <<< "${target}"
  base="${api_url}/nodes/${node}/qemu/${vm_id}"
  status_url="${base}/status/current"

  echo ""
  echo "Processing ${label} (vmid=${vm_id}, node=${node})"

  if ! api_request GET "${status_url}" "${token_id}" "${token_secret}" "${tls_mode}"; then
    echo "  Error: unable to reach Proxmox API for vmid=${vm_id}" >&2
    errors=$((errors + 1))
    continue
  fi

  if is_vm_absent_response; then
    echo "  VM not found, skipping."
    skipped=$((skipped + 1))
    continue
  fi
  if [[ "${REQ_CODE}" != "200" ]]; then
    echo "  Error: status lookup failed (HTTP ${REQ_CODE})" >&2
    errors=$((errors + 1))
    continue
  fi

  status="$(printf '%s' "${REQ_BODY}" | json_status)"
  if [[ -z "${status}" ]]; then
    status="unknown"
  fi
  echo "  Current status: ${status}"

  if [[ "${status}" != "stopped" ]]; then
    if ! api_request POST "${base}/status/stop" "${token_id}" "${token_secret}" "${tls_mode}"; then
      echo "  Error: failed to stop vmid=${vm_id}" >&2
      errors=$((errors + 1))
      continue
    fi
    if [[ "${REQ_CODE}" != "200" ]]; then
      if [[ "${REQ_BODY}" == *"not running"* ]]; then
        echo "  Stop request returned not running; continuing."
      else
        echo "  Error: stop request failed (HTTP ${REQ_CODE})" >&2
        errors=$((errors + 1))
        continue
      fi
    else
      echo "  Stop requested."
    fi

    wait_result="$(wait_for_stopped "${api_url}" "${node}" "${vm_id}" "${token_id}" "${token_secret}" "${tls_mode}")"
    if [[ "${wait_result}" == "timeout" ]]; then
      echo "  Warning: timed out waiting for vmid=${vm_id} to stop; proceeding with delete." >&2
    else
      echo "  VM state after stop wait: ${wait_result}"
    fi
  fi

  if ! api_request DELETE "${base}?purge=1" "${token_id}" "${token_secret}" "${tls_mode}"; then
    echo "  Error: delete request failed for vmid=${vm_id}" >&2
    errors=$((errors + 1))
    continue
  fi

  if is_vm_absent_response; then
    echo "  VM already absent."
    skipped=$((skipped + 1))
    continue
  fi
  if [[ "${REQ_CODE}" != "200" ]]; then
    echo "  Error: delete request failed (HTTP ${REQ_CODE})" >&2
    errors=$((errors + 1))
    continue
  fi

  delete_upid="$(printf '%s' "${REQ_BODY}" | json_data_string)"
  if [[ -n "${delete_upid}" ]]; then
    echo "  Delete task accepted: ${delete_upid}"
    delete_task_result="$(wait_for_task_completion "${api_url}" "${node}" "${delete_upid}" "${token_id}" "${token_secret}" "${tls_mode}")"
    case "${delete_task_result}" in
      ok)
        echo "  Delete task finished: OK"
        echo "  VM destroyed."
        deleted=$((deleted + 1))
        continue
        ;;
      error:*)
        echo "  Error: delete task failed (${delete_task_result#error:})." >&2
        errors=$((errors + 1))
        continue
        ;;
      timeout)
        echo "  Warning: timed out waiting for delete task completion; checking VM presence." >&2
        ;;
      missing)
        echo "  Warning: delete task status endpoint returned 404; checking VM presence." >&2
        ;;
    esac
  fi

  if wait_for_absent "${api_url}" "${node}" "${vm_id}" "${token_id}" "${token_secret}" "${tls_mode}"; then
    echo "  VM destroyed."
    deleted=$((deleted + 1))
  else
    echo "  Warning: delete accepted, but VM still present after wait (likely still in progress)." >&2
    pending=$((pending + 1))
  fi
done

echo ""
echo "Summary: deleted=${deleted} skipped=${skipped} pending=${pending} errors=${errors}"
if [[ "${errors}" -gt 0 ]]; then
  exit 1
fi

exit 0
