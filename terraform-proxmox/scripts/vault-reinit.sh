#!/usr/bin/env bash
# DESTRUCTIVE: Reinitialize Vault by wiping raft data and generating fresh recovery material.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"
VAULT_HCL="${VAULT_HCL:-/etc/vault.d/vault.hcl}"
VAULT_UNIT="${VAULT_UNIT:-vault}"
VAULT_ADDR="${VAULT_ADDR:-}"
VAULT_CACERT="${VAULT_CACERT:-}"
VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-}"

VAULT_INIT_SHARES="${VAULT_INIT_SHARES:-3}"
VAULT_INIT_THRESHOLD="${VAULT_INIT_THRESHOLD:-2}"
VAULT_RECOVERY_DIR="${VAULT_RECOVERY_DIR:-${HOME}/.vault-recovery}"
VAULT_RECOVERY_PASSPHRASE="${VAULT_RECOVERY_PASSPHRASE:-}"
VAULT_KV_MOUNT_PATH="${VAULT_KV_MOUNT_PATH:-secret}"

AUTO_UNSEAL=true
UPDATE_ENV_TOKEN=false
STORE_ROOT_TOKEN=false
BACKUP_RAFT=true
DRY_RUN=false
FORCE=false
CONFIRM=false

RAFT_PATH=""
BUNDLE_DIR=""
INIT_JSON=""
ROOT_TOKEN=""
UNSEAL_KEYS=()

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

is_true() {
  local v="${1:-}"
  [[ "${v,,}" == "true" || "${v}" == "1" || "${v,,}" == "yes" ]]
}

usage() {
  cat <<'EOF'
Usage:
  vault-reinit.sh [options]

Options:
  --yes-i-understand-data-loss  Required acknowledgement for destructive reinit.
  --vault-hcl <path>            Vault HCL config path (default: /etc/vault.d/vault.hcl).
  --vault-unit <unit>           systemd service unit (default: vault).
  --env-file <path>             Env file for Vault settings (default: terraform-proxmox/.env).
  --vault-addr <url>            Vault address override.
  --vault-cacert <path>         Vault CA cert override.
  --vault-skip-verify <bool>    Vault TLS verify override (true/false).
  --recovery-dir <path>         Directory for recovery artifacts (default: ~/.vault-recovery).
  --shares <n>                  Key shares for vault operator init (default: 3).
  --threshold <n>               Key threshold for vault operator init (default: 2).
  --skip-unseal                 Do not unseal automatically after init.
  --env-token-update            Write new root token into .env (default: disabled).
  --no-env-token-update         Do not write new root token into .env.
  --store-root-token            Persist root token artifacts in recovery bundle (default: disabled).
  --no-raft-backup              Skip pre-wipe raft tar backup.
  --force                       Continue even when pre-checks detect unusual state.
  --dry-run                     Print intended actions without changing system state.
  -h, --help                    Show this help.

Environment:
  VAULT_RECOVERY_PASSPHRASE     If set, also writes encrypted recovery archive (.tar.gz.enc).
  VAULT_KV_MOUNT_PATH           KV mount re-enabled after reinit (default: secret).
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

require_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || die "Required command not found: ${cmd}"
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

set_or_append_env_key() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp

  tmp="$(mktemp)"
  if [[ -f "${file}" ]]; then
    awk -v k="${key}" -v v="${value}" '
      BEGIN { done=0 }
      $0 ~ "^[[:space:]]*" k "=" {
        print k "=" v
        done=1
        next
      }
      { print }
      END {
        if (done == 0) {
          print k "=" v
        }
      }
    ' "${file}" > "${tmp}"
  else
    printf '%s=%s\n' "${key}" "${value}" > "${tmp}"
  fi
  mv "${tmp}" "${file}"
}

extract_hcl_value() {
  local file="$1"
  local key="$2"
  awk -F'"' -v k="${key}" '
    $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
      print $2
      exit
    }
  ' "${file}"
}

extract_raft_path() {
  local file="$1"
  awk -F'"' '
    BEGIN { in_raft=0 }
    /^[[:space:]]*storage[[:space:]]+"raft"[[:space:]]*\{/ { in_raft=1; next }
    in_raft && /^[[:space:]]*path[[:space:]]*=/ { print $2; exit }
    in_raft && /^[[:space:]]*}/ { in_raft=0 }
  ' "${file}"
}

validate_positive_int() {
  local v="$1"
  local label="$2"
  [[ "${v}" =~ ^[0-9]+$ ]] || die "${label} must be a positive integer."
  [[ "${v}" -ge 1 ]] || die "${label} must be >= 1."
}

wait_for_vault_api() {
  local retries delay attempt out rc
  retries="${VAULT_REINIT_WAIT_RETRIES:-30}"
  delay="${VAULT_REINIT_WAIT_DELAY_SEC:-2}"

  for attempt in $(seq 1 "${retries}"); do
    set +e
    out="$(vault status 2>&1)"
    rc=$?
    set -e

    if [[ ${rc} -eq 0 || ${rc} -eq 1 || ${rc} -eq 2 ]]; then
      if grep -q "x509: certificate is valid for" <<< "${out}"; then
        die "Vault API reachable but TLS hostname/SAN mismatch for ${VAULT_ADDR}. Details: ${out}"
      fi
      if grep -qi "x509: certificate signed by unknown authority" <<< "${out}"; then
        die "Vault API TLS trust failed for ${VAULT_ADDR}. Set VAULT_CACERT to a trusted cert file (for example /etc/vault.d/vault-cert.pem) or set VAULT_SKIP_VERIFY=true for lab use. Details: ${out}"
      fi
      if grep -qi "Error loading CA File" <<< "${out}"; then
        die "VAULT_CACERT is set but unreadable/invalid. Fix VAULT_CACERT path or unset it and use VAULT_SKIP_VERIFY=true for lab use. Details: ${out}"
      fi
      if ! grep -Eqi 'connection refused|dial tcp|context deadline exceeded|i/o timeout|no such host|EOF' <<< "${out}"; then
        return 0
      fi
    fi

    if [[ "${attempt}" -lt "${retries}" ]]; then
      sleep "${delay}"
      continue
    fi
    die "Vault API did not become reachable at ${VAULT_ADDR} after ${retries} attempts. Last error: ${out}"
  done
}

resolve_config_from_files() {
  local candidate

  if [[ -z "${VAULT_ADDR}" ]]; then
    VAULT_ADDR="$(read_env_key "${ENV_FILE}" "VAULT_ADDR")"
  fi
  if [[ -z "${VAULT_CACERT}" ]]; then
    VAULT_CACERT="$(read_env_key "${ENV_FILE}" "VAULT_CACERT")"
  fi
  if [[ -z "${VAULT_SKIP_VERIFY}" ]]; then
    VAULT_SKIP_VERIFY="$(read_env_key "${ENV_FILE}" "VAULT_SKIP_VERIFY")"
  fi
  if [[ -z "${VAULT_ADDR}" && -f "${VAULT_HCL}" ]]; then
    VAULT_ADDR="$(extract_hcl_value "${VAULT_HCL}" "api_addr")"
  fi
  if [[ -z "${VAULT_ADDR}" ]]; then
    VAULT_ADDR="https://127.0.0.1:8200"
  fi

  if [[ -n "${VAULT_CACERT}" && ! -r "${VAULT_CACERT}" ]]; then
    if is_true "${VAULT_SKIP_VERIFY}"; then
      warn "Configured VAULT_CACERT is not readable (${VAULT_CACERT}); continuing with VAULT_SKIP_VERIFY=${VAULT_SKIP_VERIFY}."
      VAULT_CACERT=""
    else
      die "Configured VAULT_CACERT is not readable: ${VAULT_CACERT}"
    fi
  fi

  if [[ -z "${VAULT_CACERT}" ]] && ! is_true "${VAULT_SKIP_VERIFY}" && [[ "${VAULT_ADDR}" == https://* ]]; then
    for candidate in /etc/vault.d/vault-cert.pem /etc/vault.d/tls/vault-cert.pem; do
      if [[ -r "${candidate}" ]]; then
        VAULT_CACERT="${candidate}"
        log "Using auto-detected VAULT_CACERT=${VAULT_CACERT}"
        break
      fi
    done
  fi

  export VAULT_ADDR
  if [[ -n "${VAULT_CACERT}" ]]; then
    export VAULT_CACERT
  fi
  if [[ -n "${VAULT_SKIP_VERIFY}" ]]; then
    export VAULT_SKIP_VERIFY
  fi
}

prepare_bundle() {
  local ts metadata_file
  ts="$(date +%Y%m%d-%H%M%S)"
  umask 077
  mkdir -p "${VAULT_RECOVERY_DIR}"
  chmod 700 "${VAULT_RECOVERY_DIR}" || true

  BUNDLE_DIR="${VAULT_RECOVERY_DIR}/vault-reinit-${ts}"
  mkdir -p "${BUNDLE_DIR}"
  chmod 700 "${BUNDLE_DIR}" || true

  metadata_file="${BUNDLE_DIR}/metadata.txt"
  cat > "${metadata_file}" <<EOF
created_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
hostname=$(hostname -f 2>/dev/null || hostname)
vault_addr=${VAULT_ADDR}
vault_hcl=${VAULT_HCL}
vault_unit=${VAULT_UNIT}
raft_path=${RAFT_PATH}
shares=${VAULT_INIT_SHARES}
threshold=${VAULT_INIT_THRESHOLD}
env_file=${ENV_FILE}
EOF
  chmod 600 "${metadata_file}"
}

backup_current_state() {
  local tmp_hcl

  if [[ -f "${ENV_FILE}" ]]; then
    cp "${ENV_FILE}" "${BUNDLE_DIR}/env.pre-reinit"
    chmod 600 "${BUNDLE_DIR}/env.pre-reinit"
  fi

  tmp_hcl="$(mktemp)"
  if [[ -r "${VAULT_HCL}" ]]; then
    cp "${VAULT_HCL}" "${tmp_hcl}"
  else
    run_privileged cp "${VAULT_HCL}" "${tmp_hcl}"
  fi
  cp "${tmp_hcl}" "${BUNDLE_DIR}/vault.hcl.pre-reinit"
  chmod 600 "${BUNDLE_DIR}/vault.hcl.pre-reinit"
  rm -f "${tmp_hcl}"

  if [[ "${BACKUP_RAFT}" == true && -d "${RAFT_PATH}" ]]; then
    run_privileged tar -C "$(dirname "${RAFT_PATH}")" -czf - "$(basename "${RAFT_PATH}")" > "${BUNDLE_DIR}/raft-before-reinit.tar.gz"
    chmod 600 "${BUNDLE_DIR}/raft-before-reinit.tar.gz"
  fi
}

wipe_and_restart() {
  log "Stopping Vault service (${VAULT_UNIT})..."
  run_privileged systemctl stop "${VAULT_UNIT}"

  log "Wiping raft storage contents under ${RAFT_PATH}..."
  run_privileged mkdir -p "${RAFT_PATH}"
  run_privileged find "${RAFT_PATH}" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +

  log "Starting Vault service (${VAULT_UNIT})..."
  run_privileged systemctl start "${VAULT_UNIT}"
}

initialize_vault() {
  local init_out rc key

  set +e
  init_out="$(vault operator init -key-shares="${VAULT_INIT_SHARES}" -key-threshold="${VAULT_INIT_THRESHOLD}" -format=json 2>&1)"
  rc=$?
  set -e
  if [[ ${rc} -ne 0 ]]; then
    die "Vault initialization failed. ${init_out}"
  fi
  INIT_JSON="${init_out}"

  ROOT_TOKEN="$(jq -r '.root_token' <<< "${INIT_JSON}")"
  [[ -n "${ROOT_TOKEN}" && "${ROOT_TOKEN}" != "null" ]] || die "Vault init output did not contain root_token."

  while IFS= read -r key; do
    [[ -n "${key}" ]] && UNSEAL_KEYS+=("${key}")
  done < <(jq -r '.unseal_keys_b64[]' <<< "${INIT_JSON}")

  [[ "${#UNSEAL_KEYS[@]}" -ge "${VAULT_INIT_THRESHOLD}" ]] || die "Vault init returned fewer keys than threshold."
}

persist_recovery_artifacts() {
  local init_file unseal_file root_file export_file sha_file archive enc_archive init_payload
  local idx

  init_file="${BUNDLE_DIR}/vault-init.json"
  unseal_file="${BUNDLE_DIR}/unseal-keys.txt"
  root_file="${BUNDLE_DIR}/root-token.txt"
  export_file="${BUNDLE_DIR}/vault-root-token.export"
  sha_file="${BUNDLE_DIR}/SHA256SUMS"

  init_payload="$(jq '.root_token = "REDACTED"' <<< "${INIT_JSON}")"
  printf '%s\n' "${init_payload}" > "${init_file}"
  chmod 600 "${init_file}"

  {
    printf '# generated_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for idx in "${!UNSEAL_KEYS[@]}"; do
      printf 'key_%d=%s\n' "$((idx + 1))" "${UNSEAL_KEYS[${idx}]}"
    done
  } > "${unseal_file}"
  chmod 600 "${unseal_file}"

  if [[ "${STORE_ROOT_TOKEN}" == true ]]; then
    printf '%s\n' "${ROOT_TOKEN}" > "${root_file}"
    chmod 600 "${root_file}"

    {
      printf 'export VAULT_TOKEN=%q\n' "${ROOT_TOKEN}"
      printf 'export TF_VAR_vault_token=%q\n' "${ROOT_TOKEN}"
    } > "${export_file}"
    chmod 600 "${export_file}"
  fi

  if [[ "${STORE_ROOT_TOKEN}" == true ]]; then
    (
      cd "${BUNDLE_DIR}"
      sha256sum vault-init.json unseal-keys.txt root-token.txt vault-root-token.export metadata.txt > "${sha_file##*/}"
    )
  else
    (
      cd "${BUNDLE_DIR}"
      sha256sum vault-init.json unseal-keys.txt metadata.txt > "${sha_file##*/}"
    )
  fi
  chmod 600 "${sha_file}"

  if [[ -n "${VAULT_RECOVERY_PASSPHRASE}" ]]; then
    require_cmd openssl
    archive="${BUNDLE_DIR}.tar.gz"
    enc_archive="${archive}.enc"
    tar -C "${VAULT_RECOVERY_DIR}" -czf "${archive}" "$(basename "${BUNDLE_DIR}")"
    VAULT_RECOVERY_PASSPHRASE="${VAULT_RECOVERY_PASSPHRASE}" \
      openssl enc -aes-256-cbc -pbkdf2 -salt -in "${archive}" -out "${enc_archive}" -pass env:VAULT_RECOVERY_PASSPHRASE
    chmod 600 "${enc_archive}"
    sha256sum "${enc_archive}" > "${enc_archive}.sha256"
    chmod 600 "${enc_archive}.sha256"
    rm -f "${archive}"
    log "Encrypted recovery archive written: ${enc_archive}"
  fi

  ln -sfn "$(basename "${BUNDLE_DIR}")" "${VAULT_RECOVERY_DIR}/latest"
}

auto_unseal_if_requested() {
  local i
  [[ "${AUTO_UNSEAL}" == true ]] || return 0
  for (( i=0; i<VAULT_INIT_THRESHOLD; i++ )); do
    vault operator unseal "${UNSEAL_KEYS[${i}]}" >/dev/null
  done
  log "Vault unsealed using threshold keys."
}

update_env_token_if_requested() {
  [[ "${UPDATE_ENV_TOKEN}" == true ]] || return 0
  set_or_append_env_key "${ENV_FILE}" "VAULT_TOKEN" "${ROOT_TOKEN}"
  set_or_append_env_key "${ENV_FILE}" "TF_VAR_vault_token" "${ROOT_TOKEN}"
  chmod 600 "${ENV_FILE}" 2>/dev/null || true
  log "Updated ${ENV_FILE} with new VAULT_TOKEN and TF_VAR_vault_token."
}

ensure_kv_mount() {
  local mount_key mounts_json rc retries delay attempt
  mount_key="${VAULT_KV_MOUNT_PATH}/"
  retries="${VAULT_KV_MOUNT_RETRIES:-20}"
  delay="${VAULT_KV_MOUNT_DELAY_SEC:-2}"

  if [[ "${AUTO_UNSEAL}" != true ]]; then
    warn "Skipped KV mount check because Vault was not auto-unsealed (--skip-unseal)."
    return 0
  fi

  export VAULT_TOKEN="${ROOT_TOKEN}"
  for attempt in $(seq 1 "${retries}"); do
    set +e
    mounts_json="$(vault secrets list -format=json 2>&1)"
    rc=$?
    set -e

    if [[ ${rc} -eq 0 ]]; then
      break
    fi

    if grep -Eqi "local node not active|active cluster node not found|connection refused|dial tcp|context deadline exceeded|i/o timeout" <<< "${mounts_json}"; then
      if [[ "${attempt}" -lt "${retries}" ]]; then
        sleep "${delay}"
        continue
      fi
      die "Unable to list Vault mounts after reinit (leader not active after ${retries} attempts). ${mounts_json}"
    fi

    die "Unable to list Vault mounts after reinit. ${mounts_json}"
  done

  if jq -e --arg mount "${mount_key}" '.[$mount] != null' <<< "${mounts_json}" >/dev/null; then
    log "Vault mount already present: ${mount_key}"
    return 0
  fi

  vault secrets enable -path="${VAULT_KV_MOUNT_PATH}" kv-v2 >/dev/null
  log "Enabled kv-v2 mount at ${mount_key}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes-i-understand-data-loss)
      CONFIRM=true
      shift
      ;;
    --vault-hcl)
      VAULT_HCL="${2:-}"
      shift 2
      ;;
    --vault-unit)
      VAULT_UNIT="${2:-}"
      shift 2
      ;;
    --env-file)
      ENV_FILE="${2:-}"
      shift 2
      ;;
    --vault-addr)
      VAULT_ADDR="${2:-}"
      shift 2
      ;;
    --vault-cacert)
      VAULT_CACERT="${2:-}"
      shift 2
      ;;
    --vault-skip-verify)
      VAULT_SKIP_VERIFY="${2:-true}"
      shift 2
      ;;
    --recovery-dir)
      VAULT_RECOVERY_DIR="${2:-}"
      shift 2
      ;;
    --shares)
      VAULT_INIT_SHARES="${2:-}"
      shift 2
      ;;
    --threshold)
      VAULT_INIT_THRESHOLD="${2:-}"
      shift 2
      ;;
    --skip-unseal)
      AUTO_UNSEAL=false
      shift
      ;;
    --env-token-update)
      UPDATE_ENV_TOKEN=true
      shift
      ;;
    --no-env-token-update)
      UPDATE_ENV_TOKEN=false
      shift
      ;;
    --store-root-token)
      STORE_ROOT_TOKEN=true
      shift
      ;;
    --no-raft-backup)
      BACKUP_RAFT=false
      shift
      ;;
    --force)
      FORCE=true
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

require_cmd vault
require_cmd jq
require_cmd tar
require_cmd sha256sum

[[ -f "${VAULT_HCL}" ]] || die "Vault config not found: ${VAULT_HCL}"
[[ -n "${VAULT_UNIT}" ]] || die "Vault unit name is empty."
[[ -n "${VAULT_RECOVERY_DIR}" ]] || die "Recovery directory is empty."

validate_positive_int "${VAULT_INIT_SHARES}" "shares"
validate_positive_int "${VAULT_INIT_THRESHOLD}" "threshold"
[[ "${VAULT_INIT_THRESHOLD}" -le "${VAULT_INIT_SHARES}" ]] || die "threshold must be <= shares."

RAFT_PATH="$(extract_raft_path "${VAULT_HCL}")"
[[ -n "${RAFT_PATH}" ]] || die "Could not detect raft storage path from ${VAULT_HCL}."

resolve_config_from_files

log "Vault reinit settings:"
log "  vault_addr=${VAULT_ADDR}"
log "  vault_hcl=${VAULT_HCL}"
log "  raft_path=${RAFT_PATH}"
log "  recovery_dir=${VAULT_RECOVERY_DIR}"
log "  shares=${VAULT_INIT_SHARES}, threshold=${VAULT_INIT_THRESHOLD}"
log "  auto_unseal=${AUTO_UNSEAL}, update_env_token=${UPDATE_ENV_TOKEN}, backup_raft=${BACKUP_RAFT}"
log "  store_root_token=${STORE_ROOT_TOKEN}"

if [[ "${CONFIRM}" != true ]]; then
  die "Refusing destructive action. Re-run with --yes-i-understand-data-loss."
fi

if [[ "${DRY_RUN}" == true ]]; then
  log "[dry-run] would create recovery bundle and wipe ${RAFT_PATH}"
  log "[dry-run] would run: systemctl stop ${VAULT_UNIT}, wipe raft, systemctl start ${VAULT_UNIT}"
  log "[dry-run] would run: vault operator init -key-shares=${VAULT_INIT_SHARES} -key-threshold=${VAULT_INIT_THRESHOLD}"
  exit 0
fi

set +e
status_before="$(vault status 2>&1)"
status_rc=$?
set -e
if grep -qi "not initialized" <<< "${status_before}" && [[ "${FORCE}" != true ]]; then
  die "Vault appears uninitialized already. Use 'vault operator init' directly, or pass --force."
fi
if grep -qi "Error loading CA File" <<< "${status_before}"; then
  die "VAULT_CACERT is invalid/unreadable. Fix VAULT_CACERT in ${ENV_FILE} (or pass --vault-cacert), then rerun."
fi
if grep -qi "x509: certificate signed by unknown authority" <<< "${status_before}" && ! is_true "${VAULT_SKIP_VERIFY}"; then
  die "TLS trust check failed before destructive reinit. Set VAULT_CACERT to a trusted cert file (for example /etc/vault.d/vault-cert.pem) or set VAULT_SKIP_VERIFY=true for lab use, then rerun."
fi
if grep -q "x509: certificate is valid for" <<< "${status_before}" && ! is_true "${VAULT_SKIP_VERIFY}"; then
  die "TLS SAN mismatch for ${VAULT_ADDR}. Set VAULT_CACERT/VAULT_SKIP_VERIFY or use --vault-addr matching certificate SAN."
fi

prepare_bundle
backup_current_state
wipe_and_restart
wait_for_vault_api
initialize_vault
persist_recovery_artifacts
auto_unseal_if_requested
update_env_token_if_requested
ensure_kv_mount

log "Vault reinitialization complete."
log "Recovery bundle: ${BUNDLE_DIR}"
log "Latest pointer: ${VAULT_RECOVERY_DIR}/latest"
if [[ "${STORE_ROOT_TOKEN}" != true ]]; then
  log "Root token was intentionally NOT persisted to disk. Capture it from current secure session if needed."
fi
log "IMPORTANT: Copy unseal keys (and root token if captured) to at least two independent secure locations."
