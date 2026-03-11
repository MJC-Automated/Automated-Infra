#!/usr/bin/env bash
# scripts/download-cloud-image.sh
# Ensure common cloud images exist on a Proxmox host with SHA256 verification.

set -euo pipefail

PROXMOX_HOST="${PROXMOX_HOST:-}"
PROXMOX_USER="${PROXMOX_USER:-root}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-10}"
SSH_OPTIONS_RAW="${SSH_OPTIONS:-}"
IMAGE_DIR="${IMAGE_DIR:-/var/lib/vz/template/iso}"
IMAGES="${IMAGES:-common}"
FORCE="${FORCE:-false}"
LOCAL_RUN="false"

ORACLE9_IMAGE_URL="${ORACLE9_IMAGE_URL:-https://yum.oracle.com/templates/OracleLinux/OL9/u7/x86_64/OL9U7_x86_64-kvm-b269.qcow2}"
ORACLE8_IMAGE_URL="${ORACLE8_IMAGE_URL:-https://yum.oracle.com/templates/OracleLinux/OL8/u10/x86_64/OL8U10_x86_64-kvm-b271.qcow2}"
UBUNTU24_IMAGE_URL="${UBUNTU24_IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"

ORACLE9_CHECKSUM_URL="${ORACLE9_CHECKSUM_URL:-}"
ORACLE8_CHECKSUM_URL="${ORACLE8_CHECKSUM_URL:-}"
UBUNTU24_CHECKSUM_URL="${UBUNTU24_CHECKSUM_URL:-}"

ORACLE9_IMAGE_SHA256="${ORACLE9_IMAGE_SHA256:-}"
ORACLE8_IMAGE_SHA256="${ORACLE8_IMAGE_SHA256:-}"
UBUNTU24_IMAGE_SHA256="${UBUNTU24_IMAGE_SHA256:-}"

SSH_OPTS_DEFAULT=(-o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" -o ServerAliveInterval=15 -o ServerAliveCountMax=3)
SSH_OPTS=()

usage() {
  cat <<'USAGE'
Usage:
  download-cloud-image.sh [options]

Options:
  --host <ip-or-dns>     Proxmox host/IP. If omitted, runs on the current host.
  --user <name>          SSH user for remote execution (default: root).
  --image-dir <path>     Destination directory on Proxmox (default: /var/lib/vz/template/iso).
  --images <list>        Comma-separated list: ubuntu24,oracle8,oracle9,common,all.
  --force                Re-download even when local checksum already matches.
  --no-force             Disable forced re-downloads.
  -h, --help             Show this help text.

Environment overrides:
  ORACLE8_IMAGE_URL, ORACLE9_IMAGE_URL, UBUNTU24_IMAGE_URL
  ORACLE8_IMAGE_SHA256, ORACLE9_IMAGE_SHA256, UBUNTU24_IMAGE_SHA256
  ORACLE8_CHECKSUM_URL, ORACLE9_CHECKSUM_URL, UBUNTU24_CHECKSUM_URL

Notes:
  - SHA256 verification is mandatory.
  - If *_IMAGE_SHA256 is not supplied, the script attempts to discover checksum
    metadata from checksum files hosted next to the image URL.
USAGE
}

is_true() {
  case "${1,,}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_image_key() {
  case "${1,,}" in
    ubuntu|ubuntu24|ubuntu-24|ubuntu2404|noble) printf '%s\n' "ubuntu24" ;;
    oracle8|ol8|oracle-linux-8|oraclelinux8) printf '%s\n' "oracle8" ;;
    oracle9|ol9|oracle-linux-9|oraclelinux9) printf '%s\n' "oracle9" ;;
    common|all) printf '%s\n' "common" ;;
    *) return 1 ;;
  esac
}

build_selected_images() {
  local raw_images="$1"
  local token key
  local -a requested=()
  local -a expanded=()
  local -A seen=()

  IFS=',' read -r -a requested <<<"${raw_images}"
  if [[ ${#requested[@]} -eq 0 ]]; then
    requested=("common")
  fi

  for token in "${requested[@]}"; do
    token="${token//[[:space:]]/}"
    [[ -n "${token}" ]] || continue
    key="$(normalize_image_key "${token}")" || {
      echo "Error: unsupported image key '${token}'." >&2
      exit 1
    }

    if [[ "${key}" == "common" ]]; then
      for key in ubuntu24 oracle8 oracle9; do
        if [[ -z "${seen[${key}]:-}" ]]; then
          seen["${key}"]=1
          expanded+=("${key}")
        fi
      done
      continue
    fi

    if [[ -z "${seen[${key}]:-}" ]]; then
      seen["${key}"]=1
      expanded+=("${key}")
    fi
  done

  if [[ ${#expanded[@]} -eq 0 ]]; then
    echo "Error: no images selected after parsing --images='${raw_images}'." >&2
    exit 1
  fi

  printf '%s\n' "${expanded[@]}"
}

parse_ssh_options() {
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
    --image-dir)
      IMAGE_DIR="${2:-}"
      shift 2
      ;;
    --images)
      IMAGES="${2:-}"
      shift 2
      ;;
    --force)
      FORCE="true"
      shift
      ;;
    --no-force)
      FORCE="false"
      shift
      ;;
    --local-run)
      LOCAL_RUN="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown option '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "${UBUNTU24_CHECKSUM_URL}" ]]; then
  UBUNTU24_CHECKSUM_URL="$(dirname "${UBUNTU24_IMAGE_URL}")/SHA256SUMS"
fi

if [[ "${LOCAL_RUN}" != "true" && -n "${PROXMOX_HOST}" ]]; then
  parse_ssh_options

  remote_args=(--local-run --images "${IMAGES}" --image-dir "${IMAGE_DIR}")
  if is_true "${FORCE}"; then
    remote_args+=(--force)
  fi

  remote_cmd=""
  for var_name in \
    ORACLE9_IMAGE_URL ORACLE8_IMAGE_URL UBUNTU24_IMAGE_URL \
    ORACLE9_CHECKSUM_URL ORACLE8_CHECKSUM_URL UBUNTU24_CHECKSUM_URL \
    ORACLE9_IMAGE_SHA256 ORACLE8_IMAGE_SHA256 UBUNTU24_IMAGE_SHA256; do
    var_value="${!var_name:-}"
    if [[ -n "${var_value}" ]]; then
      remote_cmd+="${var_name}=$(printf '%q' "${var_value}") "
    fi
  done

  remote_cmd+="bash -s --"
  for arg in "${remote_args[@]}"; do
    remote_cmd+=" $(printf '%q' "${arg}")"
  done

  echo "Executing image sync on Proxmox host ${PROXMOX_USER}@${PROXMOX_HOST}..."
  ssh "${SSH_OPTS[@]}" "${PROXMOX_USER}@${PROXMOX_HOST}" "${remote_cmd}" < "$0"
  echo "Image sync completed on ${PROXMOX_HOST}."
  exit 0
fi

mapfile -t SELECTED_IMAGES < <(build_selected_images "${IMAGES}")

if ! command -v sha256sum >/dev/null 2>&1; then
  echo "Error: sha256sum is required on target host." >&2
  exit 1
fi

download_to_file() {
  local url="$1"
  local out_file="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -o "${out_file}" "${url}"
    return 0
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -q --show-progress -O "${out_file}" "${url}"
    return 0
  fi

  echo "Error: neither curl nor wget is installed on target host." >&2
  return 1
}

fetch_url_text() {
  local url="$1"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 2 --retry-delay 1 --connect-timeout 15 "${url}"
    return $?
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -qO- "${url}"
    return $?
  fi

  return 1
}

extract_checksum_from_text() {
  local checksum_text="$1"
  local target_file="$2"

  printf '%s\n' "${checksum_text}" | awk -v target="${target_file}" '
    function is_hex64(v) { return v ~ /^[0-9A-Fa-f]{64}$/ }
    {
      gsub(/\r/, "")

      if (NF == 1 && is_hex64($1)) {
        print tolower($1)
        exit
      }

      if (NF >= 2 && is_hex64($1)) {
        name = $NF
        gsub(/^\*/, "", name)
        sub(/^.*\//, "", name)
        if (name == target) {
          print tolower($1)
          exit
        }
      }

      if ($0 ~ /^SHA256\(/ && index($0, target) > 0) {
        if (match($0, /[0-9A-Fa-f]{64}/)) {
          print tolower(substr($0, RSTART, RLENGTH))
          exit
        }
      }
    }
  '
}

resolve_expected_checksum() {
  local image_url="$1"
  local image_file="$2"
  local explicit_checksum="$3"
  local preferred_checksum_url="$4"
  local checksum_text checksum_value candidate
  local -a checksum_candidates=()
  local -A seen=()

  if [[ -n "${explicit_checksum}" ]]; then
    printf '%s\n' "${explicit_checksum,,}"
    return 0
  fi

  if [[ -n "${preferred_checksum_url}" ]]; then
    checksum_candidates+=("${preferred_checksum_url}")
  fi

  checksum_candidates+=(
    "${image_url}.sha256"
    "${image_url}.sha256sum"
    "${image_url}.sha256.txt"
    "$(dirname "${image_url}")/SHA256SUMS"
    "$(dirname "${image_url}")/SHA256SUMS.txt"
    "$(dirname "${image_url}")/CHECKSUM"
    "$(dirname "${image_url}")/CHECKSUMS"
    "$(dirname "${image_url}")/sha256sums"
    "$(dirname "${image_url}")/checksums.txt"
  )

  for candidate in "${checksum_candidates[@]}"; do
    [[ -n "${candidate}" ]] || continue
    if [[ -n "${seen[${candidate}]:-}" ]]; then
      continue
    fi
    seen["${candidate}"]=1

    if ! checksum_text="$(fetch_url_text "${candidate}" 2>/dev/null)"; then
      continue
    fi

    checksum_value="$(extract_checksum_from_text "${checksum_text}" "${image_file}")"
    if [[ -n "${checksum_value}" ]]; then
      printf '%s\n' "${checksum_value,,}"
      return 0
    fi
  done

  return 1
}

sha256_file() {
  local file_path="$1"
  sha256sum "${file_path}" | awk '{print tolower($1)}'
}

sync_image() {
  local key="$1"
  local image_url="$2"
  local explicit_checksum="$3"
  local checksum_url="$4"

  local image_file destination expected_checksum actual_checksum temp_file

  image_file="$(basename "${image_url}")"
  destination="${IMAGE_DIR%/}/${image_file}"

  expected_checksum="$(resolve_expected_checksum "${image_url}" "${image_file}" "${explicit_checksum}" "${checksum_url}")" || {
    echo "Error: unable to resolve SHA256 checksum for '${key}' (${image_url})." >&2
    echo "Set ${key^^}_IMAGE_SHA256 or ${key^^}_CHECKSUM_URL and retry." >&2
    exit 1
  }

  if [[ -f "${destination}" ]] && ! is_true "${FORCE}"; then
    actual_checksum="$(sha256_file "${destination}")"
    if [[ "${actual_checksum}" == "${expected_checksum}" ]]; then
      echo "[${key}] Present and checksum verified: ${destination}"
      return 0
    fi
    echo "[${key}] Existing file checksum mismatch; re-downloading: ${destination}"
  fi

  mkdir -p "${IMAGE_DIR}"
  temp_file="${destination}.part.$$"

  echo "[${key}] Downloading ${image_url} -> ${destination}"
  download_to_file "${image_url}" "${temp_file}"

  actual_checksum="$(sha256_file "${temp_file}")"
  if [[ "${actual_checksum}" != "${expected_checksum}" ]]; then
    rm -f "${temp_file}"
    echo "Error: checksum mismatch for '${key}'." >&2
    echo "Expected: ${expected_checksum}" >&2
    echo "Actual:   ${actual_checksum}" >&2
    exit 1
  fi

  mv -f "${temp_file}" "${destination}"
  chmod 0644 "${destination}" || true
  echo "[${key}] Download complete and checksum verified: ${destination}"
}

if ! mkdir -p "${IMAGE_DIR}"; then
  echo "Error: unable to create image directory '${IMAGE_DIR}'." >&2
  exit 1
fi

for image_key in "${SELECTED_IMAGES[@]}"; do
  case "${image_key}" in
    oracle8)
      sync_image "oracle8" "${ORACLE8_IMAGE_URL}" "${ORACLE8_IMAGE_SHA256}" "${ORACLE8_CHECKSUM_URL}"
      ;;
    oracle9)
      sync_image "oracle9" "${ORACLE9_IMAGE_URL}" "${ORACLE9_IMAGE_SHA256}" "${ORACLE9_CHECKSUM_URL}"
      ;;
    ubuntu24)
      sync_image "ubuntu24" "${UBUNTU24_IMAGE_URL}" "${UBUNTU24_IMAGE_SHA256}" "${UBUNTU24_CHECKSUM_URL}"
      ;;
    *)
      echo "Error: internal image key '${image_key}' is not supported." >&2
      exit 1
      ;;
  esac
done

echo "All requested cloud images are synchronized and checksum-verified in ${IMAGE_DIR}."
