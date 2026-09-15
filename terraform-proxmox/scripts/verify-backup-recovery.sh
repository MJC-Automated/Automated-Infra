#!/usr/bin/env bash
# Verification of Proxmox VM backup jobs, storage pools, and recovery readiness.
# Usage:
#   verify-backup-recovery.sh --environment <name> [--json]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ENVIRONMENT="dev"
OUTPUT_JSON="${OUTPUT_JSON:-false}"
REQUIRE_BACKUP=false

if [[ $# -gt 0 && "$1" != -* ]]; then
  ENVIRONMENT="$1"
  shift
fi

ALLOW_UNVERIFIED_STORAGE="${ALLOW_UNVERIFIED_BACKUP_STORAGE:-false}"
ALLOW_STALE="${ALLOW_STALE_BACKUPS:-false}"
ALLOW_EMPTY="${ALLOW_EMPTY_BACKUP_STORAGE:-false}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --environment|-e)
      ENVIRONMENT="$2"
      shift 2
      ;;
    --json)
      OUTPUT_JSON=true
      shift
      ;;
    --require-backup)
      REQUIRE_BACKUP=true
      shift
      ;;
    --allow-unverified-storage)
      ALLOW_UNVERIFIED_STORAGE=true
      shift
      ;;
    --allow-stale-backups)
      ALLOW_STALE=true
      shift
      ;;
    --allow-empty-storage)
      ALLOW_EMPTY=true
      shift
      ;;
    --tfvars)
      TFVARS_FILE="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

TFVARS_FILE="${TFVARS_FILE:-${REPO_ROOT}/terraform-proxmox/environments/${ENVIRONMENT}.tfvars}"
if [ ! -r "${TFVARS_FILE}" ]; then
  echo "Error: tfvars file not readable at ${TFVARS_FILE}" >&2
  exit 1
fi

# Buffer content once to support process substitution and pipes
TFVARS_CONTENT="$(cat "${TFVARS_FILE}")"

# Parse backup configuration from tfvars buffer
BACKUP_ENABLED=$(echo "${TFVARS_CONTENT}" | grep -A 15 'backup_defaults' | grep -E '^\s*enabled\s*=' | awk -F= '{gsub(/[ "]/, "", $2); print $2}' | head -n 1)
BACKUP_STORAGE=$(echo "${TFVARS_CONTENT}" | grep -A 15 'backup_defaults' | grep -E '^\s*storage\s*=' | awk -F= '{gsub(/[ "]/, "", $2); print $2}' | head -n 1)
BACKUP_SCHEDULE=$(echo "${TFVARS_CONTENT}" | grep -A 15 'backup_defaults' | grep -E '^\s*schedule\s*=' | awk -F= '{gsub(/[ "]/, "", $2); print $2}' | head -n 1)
MAX_BACKUP_AGE_HOURS=$(echo "${TFVARS_CONTENT}" | grep -A 15 'backup_defaults' | grep -E '^\s*max_backup_age_hours\s*=' | awk -F= '{gsub(/[ "]/, "", $2); print $2}' | head -n 1)

BACKUP_ENABLED="${BACKUP_ENABLED:-false}"
BACKUP_STORAGE="${BACKUP_STORAGE:-backups}"
BACKUP_SCHEDULE="${BACKUP_SCHEDULE:-03:30}"
MAX_BACKUP_AGE_HOURS="${MAX_BACKUP_AGE_HOURS:-36}"

if [ -z "${PROXMOX_HOST:-}" ]; then
  if [ "${ENVIRONMENT}" == "example" ]; then
    PROXMOX_HOST="198.51.100.22"
  elif [ "${ENVIRONMENT}" == "optiplex" ]; then
    PROXMOX_HOST="198.51.100.47"
  else
    PROXMOX_HOST="198.51.100.22"
  fi
fi

REPORT_STATUS="PASSED"
STATUS_NOTE="Backup policy defined"
ERROR_MSG=""
WARNING_MSG=""
ARCHIVE_COUNT=0
FRESH_ARCHIVE_COUNT=0
NEWEST_AGE_HOURS=0.0
VMID_COLLISION_COUNT=0
COLLIDING_VMIDS="[]"

if [ "${BACKUP_ENABLED}" != "true" ]; then
  if [ "${REQUIRE_BACKUP}" == "true" ]; then
    REPORT_STATUS="FAILED"
    ERROR_MSG="VM backups are disabled in tfvars, but --require-backup was specified."
    STATUS_NOTE="${ERROR_MSG}"
  elif [ "${ALLOW_NO_BACKUP:-false}" == "true" ]; then
    REPORT_STATUS="PASSED_WITH_WAIVER"
    STATUS_NOTE="Backups are disabled with explicit approval (ALLOW_NO_BACKUP=true)"
  else
    REPORT_STATUS="FAILED"
    ERROR_MSG="VM backups are disabled in tfvars. Set ALLOW_NO_BACKUP=true to explicitly approve running without backups."
    STATUS_NOTE="${ERROR_MSG}"
  fi
else
  # Verify storage pool via SSH
  if ssh -o BatchMode=yes -o ConnectTimeout=5 root@"${PROXMOX_HOST}" pvesm status 2>/dev/null | grep -q "${BACKUP_STORAGE}"; then
    # Audit backup archives via pvesh content API with structured JSON output
    ARCHIVES_AUDIT=$(ssh -o BatchMode=yes -o ConnectTimeout=5 root@"${PROXMOX_HOST}" "
      pvesh get /nodes/\$(hostname)/storage/${BACKUP_STORAGE}/content --output-format json 2>/dev/null || pvesh get /storage/${BACKUP_STORAGE}/content --output-format json 2>/dev/null || true
    " | python3 -c '
import json, sys, time
try:
    data = json.load(sys.stdin)
    backups = [b for b in data if isinstance(b, dict) and (b.get("content") == "backup" or "backup/" in str(b.get("volid", "")))]
except Exception:
    backups = []

now = time.time()
newest_ctime = max((int(b.get("ctime", 0)) for b in backups), default=0)
newest_age_hours = round((now - newest_ctime) / 3600.0, 1) if newest_ctime > 0 else 999999.0
fresh_count = sum(1 for b in backups if (now - int(b.get("ctime", 0))) <= 86400)

print(json.dumps({
    "total": len(backups),
    "fresh_24h": fresh_count,
    "newest_age_hours": newest_age_hours,
    "newest_ctime": newest_ctime
}))
' 2>/dev/null || echo '{"total":0,"fresh_24h":0,"newest_age_hours":999999.0,"newest_ctime":0}')

    ARCHIVE_COUNT=$(python3 -c "import json, sys; print(json.loads(sys.argv[1]).get('total', 0))" "${ARCHIVES_AUDIT}")
    FRESH_ARCHIVE_COUNT=$(python3 -c "import json, sys; print(json.loads(sys.argv[1]).get('fresh_24h', 0))" "${ARCHIVES_AUDIT}")
    NEWEST_AGE_HOURS=$(python3 -c "import json, sys; print(json.loads(sys.argv[1]).get('newest_age_hours', 999999.0))" "${ARCHIVES_AUDIT}")

    # Audit reserved recovery VMID range (20000-29999) using JSON output format
    VMID_AUDIT=$(ssh -o BatchMode=yes -o ConnectTimeout=5 root@"${PROXMOX_HOST}" "
      pvesh get /cluster/resources --type vm --output-format json 2>/dev/null || true
    " | python3 -c '
import json, sys
try:
    vms = json.load(sys.stdin)
    colliding = [int(vm["vmid"]) for vm in vms if isinstance(vm, dict) and 20000 <= int(vm.get("vmid", 0)) <= 29999]
except Exception:
    colliding = []

print(json.dumps({
    "collision_count": len(colliding),
    "colliding_vmids": sorted(colliding)
}))
' 2>/dev/null || echo '{"collision_count":0,"colliding_vmids":[]}')

    VMID_COLLISION_COUNT=$(python3 -c "import json, sys; print(json.loads(sys.argv[1]).get('collision_count', 0))" "${VMID_AUDIT}")
    COLLIDING_VMIDS=$(python3 -c "import json, sys; print(json.loads(sys.argv[1]).get('colliding_vmids', []))" "${VMID_AUDIT}")

    # Enforce recovery gates:
    # Gate 1: Check for VMID collisions in reserved recovery range (20000-29999)
    if [ "${VMID_COLLISION_COUNT}" -gt 0 ]; then
      REPORT_STATUS="FAILED"
      ERROR_MSG="Collision in reserved recovery VMID range (20000-29999): VMID(s) ${COLLIDING_VMIDS} are already assigned on the cluster."
      STATUS_NOTE="${ERROR_MSG}"
    # Gate 2: Check that backup archives exist
    elif [ "${ARCHIVE_COUNT}" -eq 0 ]; then
      if [ "${ALLOW_EMPTY}" == "true" ]; then
        REPORT_STATUS="PASSED_WITH_WAIVER"
        WARNING_MSG="WARNING: Backup storage pool '${BACKUP_STORAGE}' contains 0 backup archives (waived via ALLOW_EMPTY_BACKUP_STORAGE=true)."
        STATUS_NOTE="Backup storage pool verified (0 archives, approved via waiver)"
      else
        REPORT_STATUS="FAILED"
        ERROR_MSG="Backup recovery gate FAILED: storage pool '${BACKUP_STORAGE}' contains 0 backup archives. Existing recovery points are required for recovery readiness (set ALLOW_EMPTY_BACKUP_STORAGE=true to waive)."
        STATUS_NOTE="${ERROR_MSG}"
      fi
    # Gate 3: Check archive freshness against configured max_backup_age_hours
    elif python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) <= float(sys.argv[2]) else 1)" "${NEWEST_AGE_HOURS}" "${MAX_BACKUP_AGE_HOURS}" 2>/dev/null; then
      REPORT_STATUS="PASSED"
      STATUS_NOTE="Backup storage '${BACKUP_STORAGE}' verified on ${PROXMOX_HOST} (${ARCHIVE_COUNT} archives, newest: ${NEWEST_AGE_HOURS}h old <= ${MAX_BACKUP_AGE_HOURS}h max); recovery VMID range (20000-29999) available."
    else
      if [ "${ALLOW_STALE}" == "true" ]; then
        REPORT_STATUS="PASSED_WITH_WAIVER"
        WARNING_MSG="WARNING: Newest backup archive is ${NEWEST_AGE_HOURS}h old, exceeding max allowed age of ${MAX_BACKUP_AGE_HOURS}h (waived via ALLOW_STALE_BACKUPS=true)."
        STATUS_NOTE="Backup storage verified (${ARCHIVE_COUNT} archives, stale backup approved via waiver)"
      else
        REPORT_STATUS="FAILED"
        ERROR_MSG="Backup freshness check FAILED: newest archive on '${BACKUP_STORAGE}' is ${NEWEST_AGE_HOURS}h old, exceeding max allowed age of ${MAX_BACKUP_AGE_HOURS}h. Set ALLOW_STALE_BACKUPS=true to waive."
        STATUS_NOTE="${ERROR_MSG}"
      fi
    fi
  else
    if [ "${ALLOW_UNVERIFIED_STORAGE}" == "true" ]; then
      REPORT_STATUS="PASSED_WITH_WAIVER"
      WARNING_MSG="WARNING: Backup storage pool '${BACKUP_STORAGE}' could not be verified on ${PROXMOX_HOST} via SSH. Approved via waiver."
      STATUS_NOTE="Backup policy defined (storage unverified, approved via waiver)"
    else
      REPORT_STATUS="FAILED"
      ERROR_MSG="Backup storage pool '${BACKUP_STORAGE}' could not be verified on ${PROXMOX_HOST} via SSH. Set ALLOW_UNVERIFIED_BACKUP_STORAGE=true or pass --allow-unverified-storage to waive."
      STATUS_NOTE="${ERROR_MSG}"
    fi
  fi
fi

if [ -n "${WARNING_MSG}" ]; then
  echo "${WARNING_MSG}" >&2
fi

if [ "${OUTPUT_JSON}" == "true" ]; then
  cat <<EOF
{
  "environment": "${ENVIRONMENT}",
  "status": "${REPORT_STATUS}",
  "backup_enabled": ${BACKUP_ENABLED},
  "storage_target": "${BACKUP_STORAGE}",
  "schedule": "${BACKUP_SCHEDULE}",
  "max_backup_age_hours": ${MAX_BACKUP_AGE_HOURS},
  "recovery_reserved_vmid_range": "20000-29999",
  "archive_count": ${ARCHIVE_COUNT},
  "fresh_archive_count": ${FRESH_ARCHIVE_COUNT},
  "newest_archive_age_hours": ${NEWEST_AGE_HOURS},
  "vmid_collision_count": ${VMID_COLLISION_COUNT},
  "colliding_vmids": ${COLLIDING_VMIDS},
  "note": "${STATUS_NOTE}",
  "error": "${ERROR_MSG}",
  "warning": "${WARNING_MSG}"
}
EOF
else
  echo "=== Backup & Disaster Recovery Gate Report ==="
  echo "Environment: ${ENVIRONMENT}"
  echo "Status: ${REPORT_STATUS}"
  echo "Backup Enabled: ${BACKUP_ENABLED}"
  echo "Storage Target: ${BACKUP_STORAGE}"
  echo "Schedule: ${BACKUP_SCHEDULE}"
  echo "Reserved Recovery VMID Range: 20000-29999 (Collisions: ${VMID_COLLISION_COUNT})"
  if [ "${BACKUP_ENABLED}" == "true" ]; then
    echo "Backup Archives: ${ARCHIVE_COUNT} total (${FRESH_ARCHIVE_COUNT} in last 24h, newest: ${NEWEST_AGE_HOURS}h old, max allowed: ${MAX_BACKUP_AGE_HOURS}h)"
  fi
  echo "Policy Note: ${STATUS_NOTE}"
fi

if [ "${REPORT_STATUS}" == "FAILED" ]; then
  exit 1
fi
