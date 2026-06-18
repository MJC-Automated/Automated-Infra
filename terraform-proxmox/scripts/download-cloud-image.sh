#!/usr/bin/env bash
# scripts/download-cloud-image.sh
# Ensure supported cloud images exist on a Proxmox host with checksum verification.

set -euo pipefail

PROXMOX_HOST="${PROXMOX_HOST:-}"
PROXMOX_USER="${PROXMOX_USER:-root}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-10}"
SSH_OPTIONS_RAW="${SSH_OPTIONS:-}"
IMAGE_DIR="${IMAGE_DIR:-/var/lib/vz/template/iso}"
IMAGES="${IMAGES:-common}"
FORCE="${FORCE:-false}"
LOCAL_RUN="false"

ORACLE9_IMAGE_URL="${ORACLE9_IMAGE_URL:-https://yum.oracle.com/templates/OracleLinux/OL9/u7/x86_64/OL9U7_x86_64-kvm-b289.qcow2}"
ORACLE8_IMAGE_URL="${ORACLE8_IMAGE_URL:-https://yum.oracle.com/templates/OracleLinux/OL8/u10/x86_64/OL8U10_x86_64-kvm-b287.qcow2}"
UBUNTU22_IMAGE_URL="${UBUNTU22_IMAGE_URL:-https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img}"
UBUNTU24_IMAGE_URL="${UBUNTU24_IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"
DEBIAN12_IMAGE_URL="${DEBIAN12_IMAGE_URL:-https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2}"
ROCKY9_IMAGE_URL="${ROCKY9_IMAGE_URL:-https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2}"
ALMA9_IMAGE_URL="${ALMA9_IMAGE_URL:-https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2}"
FEDORA43_IMAGE_URL="${FEDORA43_IMAGE_URL:-https://download.fedoraproject.org/pub/fedora/linux/releases/43/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-43-1.6.x86_64.qcow2}"

ORACLE9_CHECKSUM_URL="${ORACLE9_CHECKSUM_URL:-https://yum.oracle.com/templates/OracleLinux/ol9-template.json}"
ORACLE8_CHECKSUM_URL="${ORACLE8_CHECKSUM_URL:-https://yum.oracle.com/templates/OracleLinux/ol8-template.json}"
UBUNTU22_CHECKSUM_URL="${UBUNTU22_CHECKSUM_URL:-https://cloud-images.ubuntu.com/jammy/current/SHA256SUMS}"
UBUNTU24_CHECKSUM_URL="${UBUNTU24_CHECKSUM_URL:-}"
DEBIAN12_CHECKSUM_URL="${DEBIAN12_CHECKSUM_URL:-https://cloud.debian.org/images/cloud/bookworm/latest/SHA512SUMS}"
ROCKY9_CHECKSUM_URL="${ROCKY9_CHECKSUM_URL:-https://dl.rockylinux.org/pub/rocky/9/images/x86_64/CHECKSUM}"
ALMA9_CHECKSUM_URL="${ALMA9_CHECKSUM_URL:-https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/CHECKSUM}"
FEDORA43_CHECKSUM_URL="${FEDORA43_CHECKSUM_URL:-https://download.fedoraproject.org/pub/fedora/linux/releases/43/Cloud/x86_64/images/Fedora-Cloud-43-1.6-x86_64-CHECKSUM}"

ORACLE9_IMAGE_SHA256="${ORACLE9_IMAGE_SHA256:-}"
ORACLE8_IMAGE_SHA256="${ORACLE8_IMAGE_SHA256:-}"
UBUNTU22_IMAGE_SHA256="${UBUNTU22_IMAGE_SHA256:-}"
UBUNTU24_IMAGE_SHA256="${UBUNTU24_IMAGE_SHA256:-}"
DEBIAN12_IMAGE_SHA512="${DEBIAN12_IMAGE_SHA512:-}"
ROCKY9_IMAGE_SHA256="${ROCKY9_IMAGE_SHA256:-}"
ALMA9_IMAGE_SHA256="${ALMA9_IMAGE_SHA256:-}"
FEDORA43_IMAGE_SHA256="${FEDORA43_IMAGE_SHA256:-}"

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
  --images <list>        Comma-separated list:
                         ubuntu22,ubuntu24,debian12,oracle8,oracle9,
                         rocky9,alma9,fedora43,common,all.
  --force                Re-download even when local checksum already matches.
  --no-force             Disable forced re-downloads.
  -h, --help             Show this help text.

Environment overrides:
  *_IMAGE_URL
  *_CHECKSUM_URL
  *_IMAGE_SHA256
  DEBIAN12_IMAGE_SHA512

Notes:
  - Checksum verification is mandatory for every download.
  - SHA256 is used for most upstreams; Debian 12 uses SHA512.
  - If an explicit checksum is not supplied, the script attempts to discover
    checksum metadata from upstream checksum files.
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
    ubuntu22|ubuntu-22|ubuntu2204|jammy) printf '%s\n' "ubuntu22" ;;
    ubuntu|ubuntu24|ubuntu-24|ubuntu2404|noble) printf '%s\n' "ubuntu24" ;;
    debian12|debian-12|bookworm) printf '%s\n' "debian12" ;;
    oracle8|ol8|oracle-linux-8|oraclelinux8) printf '%s\n' "oracle8" ;;
    oracle9|ol9|oracle-linux-9|oraclelinux9) printf '%s\n' "oracle9" ;;
    rocky9|rocky-9|rocky-linux-9|rocky|rl) printf '%s\n' "rocky9" ;;
    alma9|alma-9|alma-linux-9|almalinux9|almalinux-9|alma) printf '%s\n' "alma9" ;;
    fedora43|fedora-43|fedora) printf '%s\n' "fedora43" ;;
    common) printf '%s\n' "common" ;;
    all) printf '%s\n' "all" ;;
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

    if [[ "${key}" == "all" ]]; then
      for key in ubuntu22 ubuntu24 debian12 oracle8 oracle9 rocky9 alma9 fedora43; do
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

checksum_hex_len() {
  case "${1,,}" in
    sha256) printf '%s\n' "64" ;;
    sha512) printf '%s\n' "128" ;;
    *)
      echo "Error: unsupported checksum algorithm '${1}'." >&2
      return 1
      ;;
  esac
}

checksum_command_for_algo() {
  case "${1,,}" in
    sha256) printf '%s\n' "sha256sum" ;;
    sha512) printf '%s\n' "sha512sum" ;;
    *)
      echo "Error: unsupported checksum algorithm '${1}'." >&2
      return 1
      ;;
  esac
}

checksum_matches_algo() {
  local checksum_value="${1,,}"
  local checksum_algo="${2,,}"
  local expected_len

  expected_len="$(checksum_hex_len "${checksum_algo}")" || return 1
  [[ "${#checksum_value}" -eq "${expected_len}" ]] || return 1
  [[ "${checksum_value}" =~ ^[0-9a-f]+$ ]]
}

if [[ "${LOCAL_RUN}" != "true" && -n "${PROXMOX_HOST}" ]]; then
  parse_ssh_options

  remote_args=(--local-run --images "${IMAGES}" --image-dir "${IMAGE_DIR}")
  if is_true "${FORCE}"; then
    remote_args+=(--force)
  fi

  remote_cmd=""
  for var_name in \
    ORACLE9_IMAGE_URL ORACLE8_IMAGE_URL \
    UBUNTU22_IMAGE_URL UBUNTU24_IMAGE_URL \
    DEBIAN12_IMAGE_URL ROCKY9_IMAGE_URL ALMA9_IMAGE_URL FEDORA43_IMAGE_URL \
    ORACLE9_CHECKSUM_URL ORACLE8_CHECKSUM_URL \
    UBUNTU22_CHECKSUM_URL UBUNTU24_CHECKSUM_URL \
    DEBIAN12_CHECKSUM_URL ROCKY9_CHECKSUM_URL ALMA9_CHECKSUM_URL FEDORA43_CHECKSUM_URL \
    ORACLE9_IMAGE_SHA256 ORACLE8_IMAGE_SHA256 \
    UBUNTU22_IMAGE_SHA256 UBUNTU24_IMAGE_SHA256 \
    DEBIAN12_IMAGE_SHA512 ROCKY9_IMAGE_SHA256 ALMA9_IMAGE_SHA256 FEDORA43_IMAGE_SHA256; do
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
  local checksum_algo="${3,,}"
  local checksum_hex_length

  checksum_hex_length="$(checksum_hex_len "${checksum_algo}")" || return 1

  printf '%s\n' "${checksum_text}" | awk -v target="${target_file}" -v algo="${checksum_algo}" -v hex_len="${checksum_hex_length}" '
    function is_hex(v, len, copy) {
      if (length(v) != len) {
        return 0
      }
      copy = v
      gsub(/[0-9A-Fa-f]/, "", copy)
      return length(copy) == 0
    }
    {
      gsub(/\r/, "")

      if (index($0, "\"image\"") > 0 && index($0, target) > 0) {
        json_target_found = 1
        next
      }

      if (json_target_found && index(tolower($0), "\"" algo "\"") > 0) {
        value = $0
        sub(/^.*:[[:space:]]*"/, "", value)
        sub(/".*$/, "", value)
        if (is_hex(value, hex_len)) {
          print tolower(value)
          exit
        }
      }

      if (json_target_found && index($0, "}") > 0) {
        json_target_found = 0
      }

      if (NF == 1 && is_hex($1, hex_len)) {
        print tolower($1)
        exit
      }

      if (NF >= 2 && is_hex($1, hex_len)) {
        name = $NF
        gsub(/^\*/, "", name)
        sub(/^.*\//, "", name)
        if (name == target) {
          print tolower($1)
          exit
        }
      }

      if (index(toupper($0), toupper(algo)) == 1 && index($0, target) > 0) {
        value = $NF
        if (is_hex(value, hex_len)) {
          print tolower(value)
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
  local checksum_algo="${5,,}"
  local checksum_text checksum_value candidate
  local -a checksum_candidates=()
  local -A seen=()

  if [[ -n "${explicit_checksum}" ]]; then
    if ! checksum_matches_algo "${explicit_checksum}" "${checksum_algo}"; then
      echo "Error: explicit checksum for '${image_file}' does not match ${checksum_algo^^} format." >&2
      return 1
    fi
    printf '%s\n' "${explicit_checksum,,}"
    return 0
  fi

  if [[ -n "${preferred_checksum_url}" ]]; then
    checksum_candidates+=("${preferred_checksum_url}")
  fi

  case "${checksum_algo}" in
    sha256)
      checksum_candidates+=(
        "${image_url}.sha256"
        "${image_url}.sha256sum"
        "${image_url}.sha256.txt"
        "$(dirname "${image_url}")/SHA256SUMS"
        "$(dirname "${image_url}")/SHA256SUMS.txt"
        "$(dirname "${image_url}")/sha256sums"
      )
      ;;
    sha512)
      checksum_candidates+=(
        "${image_url}.sha512"
        "${image_url}.sha512sum"
        "${image_url}.sha512.txt"
        "$(dirname "${image_url}")/SHA512SUMS"
        "$(dirname "${image_url}")/SHA512SUMS.txt"
        "$(dirname "${image_url}")/sha512sums"
      )
      ;;
    *)
      echo "Error: unsupported checksum algorithm '${checksum_algo}'." >&2
      return 1
      ;;
  esac

  checksum_candidates+=(
    "$(dirname "${image_url}")/CHECKSUM"
    "$(dirname "${image_url}")/CHECKSUMS"
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

    checksum_value="$(extract_checksum_from_text "${checksum_text}" "${image_file}" "${checksum_algo}")"
    if [[ -n "${checksum_value}" ]]; then
      printf '%s\n' "${checksum_value,,}"
      return 0
    fi
  done

  return 1
}

checksum_file() {
  local file_path="$1"
  local checksum_algo="${2,,}"
  local checksum_cmd

  checksum_cmd="$(checksum_command_for_algo "${checksum_algo}")" || return 1
  if ! command -v "${checksum_cmd}" >/dev/null 2>&1; then
    echo "Error: ${checksum_cmd} is required on target host." >&2
    return 1
  fi

  "${checksum_cmd}" "${file_path}" | awk '{print tolower($1)}'
}

sync_image() {
  local key="$1"
  local image_url="$2"
  local explicit_checksum="$3"
  local checksum_url="$4"
  local checksum_algo="${5,,}"

  local image_file destination expected_checksum actual_checksum temp_file checksum_env_suffix

  image_file="$(basename "${image_url}")"
  destination="${IMAGE_DIR%/}/${image_file}"
  checksum_env_suffix="$(printf '%s' "${checksum_algo}" | tr '[:lower:]' '[:upper:]')"

  expected_checksum="$(resolve_expected_checksum "${image_url}" "${image_file}" "${explicit_checksum}" "${checksum_url}" "${checksum_algo}")" || {
    echo "Error: unable to resolve ${checksum_algo^^} checksum for '${key}' (${image_url})." >&2
    echo "Set ${key^^}_IMAGE_${checksum_env_suffix} or ${key^^}_CHECKSUM_URL and retry." >&2
    exit 1
  }

  if [[ -f "${destination}" ]] && ! is_true "${FORCE}"; then
    actual_checksum="$(checksum_file "${destination}" "${checksum_algo}")"
    if [[ "${actual_checksum}" == "${expected_checksum}" ]]; then
      echo "[${key}] Present and ${checksum_algo^^} verified: ${destination}"
      return 0
    fi
    echo "[${key}] Existing file checksum mismatch; re-downloading: ${destination}"
  fi

  mkdir -p "${IMAGE_DIR}"
  temp_file="${destination}.part.$$"

  echo "[${key}] Downloading ${image_url} -> ${destination}"
  download_to_file "${image_url}" "${temp_file}"

  actual_checksum="$(checksum_file "${temp_file}" "${checksum_algo}")"
  if [[ "${actual_checksum}" != "${expected_checksum}" ]]; then
    rm -f "${temp_file}"
    echo "Error: checksum mismatch for '${key}'." >&2
    echo "Expected: ${expected_checksum}" >&2
    echo "Actual:   ${actual_checksum}" >&2
    exit 1
  fi

  mv -f "${temp_file}" "${destination}"
  chmod 0644 "${destination}" || true
  echo "[${key}] Download complete and ${checksum_algo^^} verified: ${destination}"
}

if ! mkdir -p "${IMAGE_DIR}"; then
  echo "Error: unable to create image directory '${IMAGE_DIR}'." >&2
  exit 1
fi

for image_key in "${SELECTED_IMAGES[@]}"; do
  case "${image_key}" in
    oracle8)
      sync_image "oracle8" "${ORACLE8_IMAGE_URL}" "${ORACLE8_IMAGE_SHA256}" "${ORACLE8_CHECKSUM_URL}" "sha256"
      ;;
    oracle9)
      sync_image "oracle9" "${ORACLE9_IMAGE_URL}" "${ORACLE9_IMAGE_SHA256}" "${ORACLE9_CHECKSUM_URL}" "sha256"
      ;;
    ubuntu22)
      sync_image "ubuntu22" "${UBUNTU22_IMAGE_URL}" "${UBUNTU22_IMAGE_SHA256}" "${UBUNTU22_CHECKSUM_URL}" "sha256"
      ;;
    ubuntu24)
      sync_image "ubuntu24" "${UBUNTU24_IMAGE_URL}" "${UBUNTU24_IMAGE_SHA256}" "${UBUNTU24_CHECKSUM_URL}" "sha256"
      ;;
    debian12)
      sync_image "debian12" "${DEBIAN12_IMAGE_URL}" "${DEBIAN12_IMAGE_SHA512}" "${DEBIAN12_CHECKSUM_URL}" "sha512"
      ;;
    rocky9)
      sync_image "rocky9" "${ROCKY9_IMAGE_URL}" "${ROCKY9_IMAGE_SHA256}" "${ROCKY9_CHECKSUM_URL}" "sha256"
      ;;
    alma9)
      sync_image "alma9" "${ALMA9_IMAGE_URL}" "${ALMA9_IMAGE_SHA256}" "${ALMA9_CHECKSUM_URL}" "sha256"
      ;;
    fedora43)
      sync_image "fedora43" "${FEDORA43_IMAGE_URL}" "${FEDORA43_IMAGE_SHA256}" "${FEDORA43_CHECKSUM_URL}" "sha256"
      ;;
    *)
      echo "Error: internal image key '${image_key}' is not supported." >&2
      exit 1
      ;;
  esac
done

echo "All requested cloud images are synchronized and checksum-verified in ${IMAGE_DIR}."
