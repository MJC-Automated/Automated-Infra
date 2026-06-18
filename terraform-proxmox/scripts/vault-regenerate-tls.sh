#!/usr/bin/env bash
# Regenerate Vault listener TLS certificate with loopback + LAN SANs.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

LAN_IP="${LAN_IP:-}"
LAN_HOST="${LAN_HOST:-}"
VAULT_HCL="${VAULT_HCL:-/etc/vault.d/vault.hcl}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"
VAULT_UNIT="${VAULT_UNIT:-vault}"
DAYS="${DAYS:-365}"
RESTART_VAULT=true
VERIFY=true
DRY_RUN=false

TMP_DIR=""
TMP_CERT=""
TMP_KEY=""

log() {
  printf '%s\n' "$*"
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

detect_route_src_ip() {
  local target="${1:-198.51.100.82}"
  command -v ip >/dev/null 2>&1 || return 1
  ip -4 route get "${target}" 2>/dev/null | awk '{
    for (i = 1; i <= NF; i++) {
      if ($i == "src") {
        print $(i+1)
        exit
      }
    }
  }'
}

auto_detect_lan_ip() {
  local target detected
  target="${PROXMOX_HOST:-198.51.100.82}"

  detected="$(detect_route_src_ip "${target}" || true)"
  if [[ -n "${detected}" ]]; then
    printf '%s\n' "${detected}"
    return 0
  fi

  if [[ "${target}" != "198.51.100.82" ]]; then
    detected="$(detect_route_src_ip "198.51.100.82" || true)"
    if [[ -n "${detected}" ]]; then
      printf '%s\n' "${detected}"
      return 0
    fi
  fi

  detected="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  if [[ -n "${detected}" ]]; then
    printf '%s\n' "${detected}"
    return 0
  fi

  return 1
}

usage() {
  cat <<'EOF'
Usage:
  vault-regenerate-tls.sh [options]

Options:
  --lan-ip <ip>         LAN IP included in SAN (default: auto-detected source IP)
  --lan-host <host>     LAN host (IP or DNS) included in SAN (default: LAN IP)
  --vault-hcl <path>    Vault config path (default: /etc/vault.d/vault.hcl)
  --env-file <path>     Env file for VAULT_CACERT lookup (default: terraform-proxmox/.env)
  --vault-unit <name>   systemd unit name (default: vault)
  --days <n>            Certificate validity days (default: 365)
  --no-restart          Regenerate files only; do not restart Vault
  --no-verify           Skip SAN verification
  --dry-run             Print intended actions without writing files
  -h, --help            Show this help

Behavior:
  - Reads tls_cert_file/tls_key_file from listener "tcp" in vault.hcl.
  - Generates a new self-signed cert with SANs for:
      * DNS:localhost
      * IP:127.0.0.1
      * IP:<lan-ip>
      * <lan-host> as DNS or IP depending on format
  - If VAULT_CACERT is set in env file and differs from listener cert path,
    copies the cert to that CA path as well.
EOF
}

run_privileged() {
  if [[ "${DRY_RUN}" == true ]]; then
    log "[dry-run] sudo $*"
    return 0
  fi

  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
    return 0
  fi

  command -v sudo >/dev/null 2>&1 || die "sudo is required for: $*"
  sudo "$@"
}

read_env_key() {
  local file="$1"
  local key="$2"
  [[ -f "${file}" ]] || return 0
  awk -F= -v k="${key}" '
    $1==k {
      sub(/^[^=]*=/, "", $0)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      gsub(/^"|"$/, "", $0)
      print $0
      exit
    }
  ' "${file}"
}

extract_listener_value() {
  local file="$1"
  local key="$2"
  awk -F'"' -v k="${key}" '
    BEGIN { in_listener=0 }
    /^[[:space:]]*listener[[:space:]]+"tcp"[[:space:]]*\{/ { in_listener=1; next }
    in_listener && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" { print $2; exit }
    in_listener && /^[[:space:]]*}/ { in_listener=0 }
  ' "${file}"
}

is_ipv4() {
  local ip="$1"
  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

is_positive_int() {
  [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 ]]
}

backup_file() {
  local file="$1"
  local ts backup
  [[ -f "${file}" ]] || return 0
  ts="$(date +%Y%m%d-%H%M%S-%N)"
  backup="${file}.bak.${ts}"
  if [[ "${DRY_RUN}" == true ]]; then
    log "[dry-run] backup ${file} -> ${backup}"
    return 0
  fi
  if [[ -w "${file}" ]]; then
    cp "${file}" "${backup}"
  else
    run_privileged cp "${file}" "${backup}"
  fi
  log "Backup saved: ${backup}"
}

install_preserve_meta() {
  local src="$1"
  local dst="$2"
  local default_mode="$3"
  local default_owner="$4"
  local default_group="$5"
  local mode owner group

  if [[ -f "${dst}" ]]; then
    mode="$(stat -c '%a' "${dst}")"
    owner="$(stat -c '%u' "${dst}")"
    group="$(stat -c '%g' "${dst}")"
  else
    mode="${default_mode}"
    owner="${default_owner}"
    group="${default_group}"
  fi

  if [[ "${DRY_RUN}" == true ]]; then
    log "[dry-run] install -m ${mode} -o ${owner} -g ${group} ${src} ${dst}"
    return 0
  fi

  if [[ -w "$(dirname "${dst}")" && ( ! -e "${dst}" || -w "${dst}" ) ]]; then
    install -m "${mode}" -o "${owner}" -g "${group}" "${src}" "${dst}"
  else
    run_privileged install -m "${mode}" -o "${owner}" -g "${group}" "${src}" "${dst}"
  fi
}

verify_san_contains() {
  local cert="$1"
  local required_lan_ip="$2"
  local required_lan_host="$3"
  local san_text expected

  san_text="$(openssl x509 -in "${cert}" -noout -text | awk '/Subject Alternative Name/{getline; print}')"
  [[ -n "${san_text}" ]] || die "Generated certificate has no SAN extension."

  for expected in "DNS:localhost" "IP Address:127.0.0.1" "IP Address:${required_lan_ip}"; do
    if ! grep -Fq "${expected}" <<< "${san_text}"; then
      die "Generated certificate SAN is missing ${expected}."
    fi
  done

  if is_ipv4 "${required_lan_host}"; then
    if ! grep -Fq "IP Address:${required_lan_host}" <<< "${san_text}"; then
      die "Generated certificate SAN is missing IP Address:${required_lan_host}."
    fi
  else
    if ! grep -Fq "DNS:${required_lan_host}" <<< "${san_text}"; then
      die "Generated certificate SAN is missing DNS:${required_lan_host}."
    fi
  fi
}

cleanup() {
  if [[ -n "${TMP_DIR}" ]]; then
    rm -rf "${TMP_DIR}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lan-ip)
      LAN_IP="${2:-}"
      shift 2
      ;;
    --lan-host)
      LAN_HOST="${2:-}"
      shift 2
      ;;
    --vault-hcl)
      VAULT_HCL="${2:-}"
      shift 2
      ;;
    --env-file)
      ENV_FILE="${2:-}"
      shift 2
      ;;
    --vault-unit)
      VAULT_UNIT="${2:-}"
      shift 2
      ;;
    --days)
      DAYS="${2:-}"
      shift 2
      ;;
    --no-restart)
      RESTART_VAULT=false
      shift
      ;;
    --no-verify)
      VERIFY=false
      shift
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
      die "Unknown option: $1"
      ;;
  esac
done

if [[ -z "${LAN_IP}" ]]; then
  LAN_IP="$(auto_detect_lan_ip || true)"
  if [[ -z "${LAN_IP}" ]]; then
    LAN_IP="127.0.0.1"
    warn "Could not auto-detect LAN IP; falling back to ${LAN_IP}."
  fi
fi
if [[ -z "${LAN_HOST}" ]]; then
  LAN_HOST="${LAN_IP}"
fi

command -v openssl >/dev/null 2>&1 || die "openssl is required."
[[ -f "${VAULT_HCL}" ]] || die "Vault config not found: ${VAULT_HCL}"
is_positive_int "${DAYS}" || die "--days must be a positive integer."
is_ipv4 "${LAN_IP}" || die "--lan-ip must be an IPv4 address."

TLS_CERT_FILE="$(extract_listener_value "${VAULT_HCL}" "tls_cert_file")"
TLS_KEY_FILE="$(extract_listener_value "${VAULT_HCL}" "tls_key_file")"

[[ -n "${TLS_CERT_FILE}" ]] || die "Could not read tls_cert_file from ${VAULT_HCL}"
[[ -n "${TLS_KEY_FILE}" ]] || die "Could not read tls_key_file from ${VAULT_HCL}"

VAULT_CACERT_PATH="$(read_env_key "${ENV_FILE}" "VAULT_CACERT")"
if [[ -z "${VAULT_CACERT_PATH}" ]]; then
  VAULT_CACERT_PATH="/etc/vault.d/vault-cert.pem"
fi

if id -u vault >/dev/null 2>&1; then
  KEY_OWNER_DEFAULT="$(id -u vault)"
  KEY_GROUP_DEFAULT="$(id -g vault)"
else
  KEY_OWNER_DEFAULT="$(id -u)"
  KEY_GROUP_DEFAULT="$(id -g)"
fi

TMP_DIR="$(mktemp -d)"
TMP_CERT="${TMP_DIR}/vault-cert.pem"
TMP_KEY="${TMP_DIR}/vault-key.pem"

SAN_LIST="DNS:localhost,IP:127.0.0.1,IP:${LAN_IP}"
if is_ipv4 "${LAN_HOST}"; then
  if [[ "${LAN_HOST}" != "${LAN_IP}" ]]; then
    SAN_LIST="${SAN_LIST},IP:${LAN_HOST}"
  fi
else
  SAN_LIST="${SAN_LIST},DNS:${LAN_HOST}"
fi

log "Regenerating Vault TLS certificate..."
log "  vault.hcl: ${VAULT_HCL}"
log "  listener cert: ${TLS_CERT_FILE}"
log "  listener key: ${TLS_KEY_FILE}"
log "  VAULT_CACERT copy: ${VAULT_CACERT_PATH}"
log "  SANs: ${SAN_LIST}"

if [[ "${DRY_RUN}" == true ]]; then
  log "[dry-run] openssl req -x509 -newkey rsa:4096 -sha256 -days ${DAYS} ..."
else
  openssl req -x509 -newkey rsa:4096 -sha256 -days "${DAYS}" \
    -nodes \
    -keyout "${TMP_KEY}" \
    -out "${TMP_CERT}" \
    -subj "/CN=${LAN_HOST}" \
    -addext "subjectAltName=${SAN_LIST}" >/dev/null 2>&1
fi

if [[ "${VERIFY}" == true && "${DRY_RUN}" != true ]]; then
  verify_san_contains "${TMP_CERT}" "${LAN_IP}" "${LAN_HOST}"
fi

backup_file "${TLS_CERT_FILE}"
backup_file "${TLS_KEY_FILE}"

if [[ "${VAULT_CACERT_PATH}" != "${TLS_CERT_FILE}" ]]; then
  backup_file "${VAULT_CACERT_PATH}"
fi

install_preserve_meta "${TMP_CERT}" "${TLS_CERT_FILE}" "0644" "$(id -u)" "$(id -g)"
install_preserve_meta "${TMP_KEY}" "${TLS_KEY_FILE}" "0600" "${KEY_OWNER_DEFAULT}" "${KEY_GROUP_DEFAULT}"

if [[ "${VAULT_CACERT_PATH}" != "${TLS_CERT_FILE}" ]]; then
  install_preserve_meta "${TMP_CERT}" "${VAULT_CACERT_PATH}" "0644" "$(id -u)" "$(id -g)"
fi

if [[ "${RESTART_VAULT}" == true ]]; then
  log "Restarting ${VAULT_UNIT}..."
  run_privileged systemctl restart "${VAULT_UNIT}"
else
  log "Skipping restart (--no-restart)."
fi

log "Vault TLS regeneration complete."
log "If clients are remote, copy ${VAULT_CACERT_PATH} to each client and point VAULT_CACERT to the local copy."
