#!/usr/bin/env bash
# Wrapper for cross-environment IP overlap and infrastructure conflict validation.
# Usage:
#   validate-ip-conflicts.sh [--environment <name>] [--repo-root <path>] [--skip-live-probe] [--warn-only]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENVIRONMENT="${ENVIRONMENT:-dev}"
SKIP_LIVE_PROBE="${SKIP_LIVE_PROBE:-false}"
ALLOW_IP_OVERLAP="${ALLOW_IP_OVERLAP:-false}"

ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --environment|-e)
      [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || { echo "Error: $1 requires a value" >&2; exit 2; }
      ENVIRONMENT="$2"
      shift 2
      ;;
    --repo-root|-r)
      [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || { echo "Error: $1 requires a value" >&2; exit 2; }
      REPO_ROOT="$2"
      shift 2
      ;;
    --skip-live-probe)
      SKIP_LIVE_PROBE=true
      shift
      ;;
    --warn-only|--allow-overlap)
      ALLOW_IP_OVERLAP=true
      shift
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

PASSTHROUGH_ARGS=("--environment" "${ENVIRONMENT}" "--repo-root" "${REPO_ROOT}")

if [[ "${SKIP_LIVE_PROBE}" == "true" ]]; then
  PASSTHROUGH_ARGS+=("--skip-live-probe")
fi

if [[ "${ALLOW_IP_OVERLAP}" == "true" ]]; then
  PASSTHROUGH_ARGS+=("--warn-only")
fi

if [[ ${#ARGS[@]} -gt 0 ]]; then
  PASSTHROUGH_ARGS+=("${ARGS[@]}")
fi

exec python3 "${SCRIPT_DIR}/validate-ip-conflicts.py" "${PASSTHROUGH_ARGS[@]}"
