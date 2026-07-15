#!/usr/bin/env bash
# Switch Vault listener mode between loopback and LAN.
# Also keeps terraform-proxmox/.env VAULT_ADDR and TF_VAR_vault_address aligned.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

MODE="${1:-}"
shift || true

LAN_IP="${LAN_IP:-}"
LAN_HOST="${LAN_HOST:-}"
VAULT_PORT="${VAULT_PORT:-8200}"
VAULT_CLUSTER_PORT="${VAULT_CLUSTER_PORT:-8201}"
VAULT_HCL="${VAULT_HCL:-/etc/vault.d/vault.hcl}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"
VAULT_UNIT="${VAULT_UNIT:-vault}"
ENVIRONMENT="${ENVIRONMENT:-dev}"

RESTART_VAULT=true
RUN_VERIFY=true
DRY_RUN=false
AUTO_UNSEAL="${VAULT_AUTO_UNSEAL:-true}"

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
  local target="${1:-198.51.100.23}"
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
  target="${PROXMOX_HOST:-198.51.100.23}"

  detected="$(detect_route_src_ip "${target}" || true)"
  if [[ -n "${detected}" ]]; then
    printf '%s\n' "${detected}"
    return 0
  fi

  if [[ "${target}" != "198.51.100.23" ]]; then
    detected="$(detect_route_src_ip "198.51.100.23" || true)"
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

unseal_quick_help() {
  local recovery_dir key_file root_file
  recovery_dir="${VAULT_RECOVERY_DIR:-${HOME}/.vault-recovery}"
  key_file="${recovery_dir}/latest/unseal-keys.txt"
  root_file="${recovery_dir}/latest/root-token.txt"

  cat <<EOF
Unseal quick help:
  Unseal keys file: ${key_file}
  Root token file:  ${root_file}
  Example:
    mapfile -t KEYS < <(sed -n 's/^key_[0-9]\+=//p' "${key_file}")
    for key in "\${KEYS[@]}"; do vault operator unseal "\${key}"; done
EOF
}

usage() {
  cat <<'EOF'
Usage:
  vault-mode-switch.sh <loopback|lan|status|verify> [options]

Commands:
  loopback      Set Vault to listen on 127.0.0.1 only.
  lan           Set Vault listener to LAN mode (0.0.0.0:8200).
  status        Print detected mode and key config values.
  verify        Verify Vault + Terraform + Packer integration settings.

Options:
  --lan-ip <ip>               LAN IP used for cluster_addr (default: auto-detected source IP)
  --lan-host <host-or-ip>     Host used in VAULT_ADDR/api_addr (default: LAN IP)
  --vault-hcl <path>          Vault config path (default: /etc/vault.d/vault.hcl)
  --env-file <path>           Environment file to update (default: terraform-proxmox/.env)
  --vault-unit <unit>         systemd unit name (default: vault)
  --environment <name>        Workspace/env for Vault KV checks (default: dev)
  --auto-unseal               Auto-unseal with keys from ~/.vault-recovery/latest (default: true)
  --no-auto-unseal            Do not auto-unseal if Vault is sealed.
  --no-restart                Do not restart Vault after mode switch.
  --no-verify                 Skip post-switch verification.
  --dry-run                   Show intended actions only.
  -h, --help                  Show this help.
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

  command -v sudo >/dev/null 2>&1 || die "sudo is required for privileged operation: $*"
  sudo "$@"
}

write_file_preserve_meta() {
  local src="$1"
  local dst="$2"
  local mode owner group

  if [[ -f "${dst}" ]]; then
    mode="$(stat -c '%a' "${dst}")"
    owner="$(stat -c '%u' "${dst}")"
    group="$(stat -c '%g' "${dst}")"
  else
    mode="0644"
    owner="$(id -u)"
    group="$(id -g)"
  fi

  if [[ "${DRY_RUN}" == true ]]; then
    log "[dry-run] install -m ${mode} -o ${owner} -g ${group} ${src} ${dst}"
    return 0
  fi

  if [[ -w "${dst}" || ! -e "${dst}" ]]; then
    install -m "${mode}" -o "${owner}" -g "${group}" "${src}" "${dst}"
  else
    run_privileged install -m "${mode}" -o "${owner}" -g "${group}" "${src}" "${dst}"
  fi
}

backup_file() {
  local file="$1"
  local backup_path="$2"

  if [[ ! -f "${file}" ]]; then
    return 0
  fi

  if [[ "${DRY_RUN}" == true ]]; then
    log "[dry-run] backup ${file} -> ${backup_path}"
    return 0
  fi

  if [[ -w "${file}" ]]; then
    cp "${file}" "${backup_path}"
  else
    run_privileged cp "${file}" "${backup_path}"
  fi
}

set_or_append_hcl_key() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp

  tmp="$(mktemp)"
  awk -v k="${key}" -v v="${value}" '
    BEGIN { done=0 }
    $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
      print k " = \"" v "\""
      done=1
      next
    }
    { print }
    END {
      if (done == 0) {
        print k " = \"" v "\""
      }
    }
  ' "${file}" > "${tmp}"
  mv "${tmp}" "${file}"
}

set_listener_tcp_address() {
  local file="$1"
  local value="$2"
  local tmp

  tmp="$(mktemp)"
  if ! awk -v v="${value}" '
    BEGIN { in_listener=0; changed=0 }
    /^[[:space:]]*listener[[:space:]]+"tcp"[[:space:]]*\{/ {
      in_listener=1
    }
    in_listener && /^[[:space:]]*address[[:space:]]*=/ && changed==0 {
      print "  address       = \"" v "\""
      changed=1
      next
    }
    in_listener && /^[[:space:]]*}/ {
      in_listener=0
    }
    { print }
    END {
      if (changed == 0) {
        exit 2
      }
    }
  ' "${file}" > "${tmp}"; then
    rm -f "${tmp}"
    die "Could not find listener \"tcp\" address in ${file}"
  fi
  mv "${tmp}" "${file}"
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
  write_file_preserve_meta "${tmp}" "${file}"
  rm -f "${tmp}"
}

read_env_key() {
  local file="$1"
  local key="$2"
  [[ -f "${file}" ]] || return 0
  awk -F= -v k="${key}" '
    $1==k {
      sub(/^[^=]*=/, "", $0)
      print $0
      exit
    }
  ' "${file}"
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

detect_mode() {
  local file="$1"
  local listener
  listener="$(awk -F'"' '
    BEGIN { in_listener=0 }
    /^[[:space:]]*listener[[:space:]]+"tcp"[[:space:]]*\{/ { in_listener=1 }
    in_listener && /^[[:space:]]*address[[:space:]]*=/ { print $2; exit }
    in_listener && /^[[:space:]]*}/ { in_listener=0 }
  ' "${file}")"

  case "${listener}" in
    "127.0.0.1:${VAULT_PORT}") echo "loopback" ;;
    "0.0.0.0:${VAULT_PORT}") echo "lan" ;;
    *) echo "unknown" ;;
  esac
}

restart_vault_service() {
  log "Restarting ${VAULT_UNIT} service..."
  run_privileged systemctl reset-failed "${VAULT_UNIT}" || true
  if ! run_privileged systemctl restart "${VAULT_UNIT}"; then
    warn "systemctl restart ${VAULT_UNIT} failed; attempting reset-failed + start fallback."
    run_privileged systemctl reset-failed "${VAULT_UNIT}" || true
    run_privileged systemctl start "${VAULT_UNIT}"
  fi
}

vault_status_check() {
  local addr="$1"
  local cacert skip_verify token rc secret_path vault_err auth_script
  local retries delay attempt status_json sealed auto_unseal_attempted

  retries="${VAULT_STATUS_RETRIES:-12}"
  delay="${VAULT_STATUS_DELAY_SEC:-2}"
  auto_unseal_attempted=false
  cacert="$(read_env_key "${ENV_FILE}" "VAULT_CACERT")"
  skip_verify="$(read_env_key "${ENV_FILE}" "VAULT_SKIP_VERIFY")"
  token="$(read_env_key "${ENV_FILE}" "VAULT_TOKEN")"
  secret_path="secret/terraform/${ENVIRONMENT}/creds"
  auth_script="${REPO_ROOT}/scripts/vault-auth.sh"

  export VAULT_ADDR="${addr}"
  if [[ -n "${cacert}" ]]; then
    export VAULT_CACERT="${cacert}"
  fi
  if [[ -n "${skip_verify}" ]]; then
    export VAULT_SKIP_VERIFY="${skip_verify}"
  fi
  if [[ -n "${token}" ]]; then
    export VAULT_TOKEN="${token}"
  elif [[ -n "${VAULT_TOKEN:-}" ]]; then
    export VAULT_TOKEN="${VAULT_TOKEN}"
  elif [[ -x "${auth_script}" ]]; then
    set +e
    token="$("${auth_script}" --print-token 2>/dev/null)"
    rc=$?
    set -e
    if [[ ${rc} -eq 0 && -n "${token}" ]]; then
      export VAULT_TOKEN="${token}"
    fi
  fi

  if [[ "${DRY_RUN}" == true ]]; then
    log "[dry-run] vault status (VAULT_ADDR=${VAULT_ADDR})"
    log "[dry-run] vault kv get -field=proxmox_config_api_url ${secret_path}"
    return 0
  fi

  if ! command -v vault >/dev/null 2>&1; then
    warn "vault CLI not installed; skipping live Vault status check."
    return 0
  fi

  for attempt in $(seq 1 "${retries}"); do
    set +e
    status_json="$(vault status -format=json 2>&1)"
    rc=$?
    set -e

    if [[ ${rc} -eq 0 || ${rc} -eq 2 ]]; then
      sealed="$(printf '%s' "${status_json}" | sed -n 's/.*"sealed":[[:space:]]*\(true\|false\).*/\1/p' | head -n1)"
      if [[ ${rc} -eq 2 ]]; then
        if [[ "${AUTO_UNSEAL}" == true && "${auto_unseal_attempted}" == false ]]; then
          auto_unseal_attempted=true
          if auto_unseal_from_recovery; then
            continue
          fi
        fi
        die "Vault is reachable at ${VAULT_ADDR} but sealed. Unseal Vault, then rerun this command.
$(unseal_quick_help)"
      fi
      if [[ "${sealed}" == "true" ]]; then
        if [[ "${AUTO_UNSEAL}" == true && "${auto_unseal_attempted}" == false ]]; then
          auto_unseal_attempted=true
          if auto_unseal_from_recovery; then
            continue
          fi
        fi
        die "Vault is reachable at ${VAULT_ADDR} but sealed. Unseal Vault, then rerun this command.
$(unseal_quick_help)"
      fi
      log "Vault status check passed (${VAULT_ADDR})."
      break
    fi

    vault_err="${status_json}"
    if grep -q "x509: certificate is valid for" <<< "${vault_err}"; then
      die "Vault status check failed for ${VAULT_ADDR}. TLS hostname/SAN mismatch detected. Regenerate cert SANs for this host/IP or set VAULT_SKIP_VERIFY=true in ${ENV_FILE} (lab only). Details: ${vault_err}"
    fi

    if [[ "${attempt}" -lt "${retries}" ]]; then
      sleep "${delay}"
      continue
    fi

    die "Vault status check failed for ${VAULT_ADDR}. ${vault_err}"
  done

  set +e
  vault_err="$(vault kv get -field=proxmox_config_api_url "${secret_path}" 2>&1)"
  rc=$?
  set -e
  if [[ ${rc} -ne 0 ]]; then
    if grep -q "sealed" <<< "${vault_err}"; then
      die "Vault became sealed while checking ${secret_path}. Unseal Vault and rerun.
$(unseal_quick_help)"
    fi
    die "Vault is reachable but ${secret_path} cannot be read. Check token policy/path for ENVIRONMENT=${ENVIRONMENT}. Details: ${vault_err}"
  fi
  log "Vault secret check passed (${secret_path})."
}

auto_unseal_from_recovery() {
  local recovery_dir key_file key status_json sealed rc out
  local -a keys=()

  recovery_dir="${VAULT_RECOVERY_DIR:-${HOME}/.vault-recovery}"
  key_file="${recovery_dir}/latest/unseal-keys.txt"

  if [[ ! -f "${key_file}" ]]; then
    warn "Auto-unseal is enabled but key file was not found: ${key_file}"
    return 1
  fi

  mapfile -t keys < <(sed -n 's/^key_[0-9]\+=//p' "${key_file}")
  if [[ ${#keys[@]} -eq 0 ]]; then
    warn "Auto-unseal is enabled but no keys were found in ${key_file}"
    return 1
  fi

  log "Vault is sealed; attempting automatic unseal using ${key_file}..."
  for key in "${keys[@]}"; do
    [[ -n "${key}" ]] || continue

    set +e
    out="$(vault operator unseal "${key}" 2>&1)"
    rc=$?
    set -e
    if [[ ${rc} -ne 0 ]] && ! grep -qi "already unsealed" <<< "${out}"; then
      warn "Unseal attempt failed with one key: ${out}"
      continue
    fi

    set +e
    status_json="$(vault status -format=json 2>&1)"
    rc=$?
    set -e
    if [[ ${rc} -eq 0 || ${rc} -eq 2 ]]; then
      sealed="$(printf '%s' "${status_json}" | sed -n 's/.*"sealed":[[:space:]]*\(true\|false\).*/\1/p' | head -n1)"
      if [[ "${sealed}" == "false" ]]; then
        log "Vault unsealed automatically."
        return 0
      fi
    fi
  done

  warn "Automatic unseal did not complete."
  return 1
}

verify_terraform_config() {
  local tf_file="${REPO_ROOT}/main.tf"
  local vault_block
  [[ -f "${tf_file}" ]] || die "Terraform root file not found: ${tf_file}"

  vault_block="$(awk '
    /^[[:space:]]*provider[[:space:]]+"vault"[[:space:]]*\{/ { in_block=1 }
    in_block { print }
    in_block && /^[[:space:]]*}/ { exit }
  ' "${tf_file}")"

  [[ -n "${vault_block}" ]] || die "Terraform is missing provider \"vault\" block."
  grep -Eq 'address[[:space:]]*=[[:space:]]*var\.vault_address' <<< "${vault_block}" || die "Terraform vault provider does not use var.vault_address."
  grep -Eq 'token[[:space:]]*=[[:space:]].*var\.vault_token' <<< "${vault_block}" || die "Terraform vault provider does not use var.vault_token."

  if [[ "${DRY_RUN}" == true ]]; then
    log "[dry-run] terraform validate"
    return 0
  fi

  if command -v terraform >/dev/null 2>&1; then
    terraform -chdir="${REPO_ROOT}" validate >/dev/null
    log "Terraform validation passed."
  else
    warn "terraform CLI not installed; skipped terraform validate."
  fi
}

verify_packer_config() {
  local templates=(
    "${REPO_ROOT}/packer/ubuntu-noble/ubuntu-noble.pkr.hcl"
    "${REPO_ROOT}/packer/oracle8/oracle8.pkr.hcl"
    "${REPO_ROOT}/packer/oracle9/oracle9.pkr.hcl"
  )
  local tpl

  if [[ "${DRY_RUN}" == true ]]; then
    log "[dry-run] packer validate -syntax-only <template>"
    return 0
  fi

  if ! command -v packer >/dev/null 2>&1; then
    warn "packer CLI not installed; skipped Packer syntax validation."
    return 0
  fi

  for tpl in "${templates[@]}"; do
    [[ -f "${tpl}" ]] || die "Missing Packer template: ${tpl}"
    packer validate -syntax-only "${tpl}" >/dev/null
  done
  log "Packer syntax validation passed."
}

status_report() {
  local mode api_addr cluster_addr listener_addr env_addr tf_env_addr
  [[ -f "${VAULT_HCL}" ]] || die "Vault config not found: ${VAULT_HCL}"

  mode="$(detect_mode "${VAULT_HCL}")"
  api_addr="$(extract_hcl_value "${VAULT_HCL}" "api_addr")"
  cluster_addr="$(extract_hcl_value "${VAULT_HCL}" "cluster_addr")"
  listener_addr="$(awk -F'"' '
    BEGIN { in_listener=0 }
    /^[[:space:]]*listener[[:space:]]+"tcp"[[:space:]]*\{/ { in_listener=1 }
    in_listener && /^[[:space:]]*address[[:space:]]*=/ { print $2; exit }
    in_listener && /^[[:space:]]*}/ { in_listener=0 }
  ' "${VAULT_HCL}")"

  env_addr="$(read_env_key "${ENV_FILE}" "VAULT_ADDR")"
  tf_env_addr="$(read_env_key "${ENV_FILE}" "TF_VAR_vault_address")"

  log "Vault mode: ${mode}"
  log "  vault.hcl: ${VAULT_HCL}"
  log "  api_addr: ${api_addr}"
  log "  cluster_addr: ${cluster_addr}"
  log "  listener address: ${listener_addr}"
  log "  .env file: ${ENV_FILE}"
  log "  VAULT_ADDR: ${env_addr:-<unset>}"
  log "  TF_VAR_vault_address: ${tf_env_addr:-<unset>}"
  log "  auto-unseal: ${AUTO_UNSEAL}"
}

verify_mode_settings() {
  local expected_addr="$1"
  local mode tf_addr vault_addr
  mode="$(detect_mode "${VAULT_HCL}")"

  if [[ "${MODE}" == "loopback" && "${mode}" != "loopback" ]]; then
    die "vault.hcl listener is not in loopback mode."
  fi
  if [[ "${MODE}" == "lan" && "${mode}" != "lan" ]]; then
    die "vault.hcl listener is not in LAN mode."
  fi

  tf_addr="$(read_env_key "${ENV_FILE}" "TF_VAR_vault_address")"
  vault_addr="$(read_env_key "${ENV_FILE}" "VAULT_ADDR")"

  [[ -n "${tf_addr}" ]] || die "TF_VAR_vault_address is missing in ${ENV_FILE}."
  [[ -n "${vault_addr}" ]] || die "VAULT_ADDR is missing in ${ENV_FILE}."
  [[ "${tf_addr}" == "${vault_addr}" ]] || die "TF_VAR_vault_address and VAULT_ADDR differ in ${ENV_FILE}."
  [[ "${tf_addr}" == "${expected_addr}" ]] || die "Expected ${expected_addr} in ${ENV_FILE}, found ${tf_addr}."
}

apply_mode() {
  local desired_mode="$1"
  local api_addr cluster_addr listener_addr backup ts tmp

  [[ -f "${VAULT_HCL}" ]] || die "Vault config not found: ${VAULT_HCL}"

  if [[ "${desired_mode}" == "loopback" ]]; then
    api_addr="https://127.0.0.1:${VAULT_PORT}"
    cluster_addr="https://127.0.0.1:${VAULT_CLUSTER_PORT}"
    listener_addr="127.0.0.1:${VAULT_PORT}"
  else
    api_addr="https://${LAN_HOST}:${VAULT_PORT}"
    cluster_addr="https://${LAN_IP}:${VAULT_CLUSTER_PORT}"
    listener_addr="0.0.0.0:${VAULT_PORT}"
  fi

  ts="$(date +%Y%m%d-%H%M%S-%N)"
  backup="${VAULT_HCL}.bak.${ts}"
  backup_file "${VAULT_HCL}" "${backup}"
  log "Backup saved: ${backup}"

  tmp="$(mktemp)"
  cp "${VAULT_HCL}" "${tmp}"

  set_or_append_hcl_key "${tmp}" "api_addr" "${api_addr}"
  set_or_append_hcl_key "${tmp}" "cluster_addr" "${cluster_addr}"
  set_listener_tcp_address "${tmp}" "${listener_addr}"

  write_file_preserve_meta "${tmp}" "${VAULT_HCL}"
  rm -f "${tmp}"
  log "Updated ${VAULT_HCL} for mode: ${desired_mode}"

  set_or_append_env_key "${ENV_FILE}" "VAULT_ADDR" "${api_addr}"
  set_or_append_env_key "${ENV_FILE}" "TF_VAR_vault_address" "${api_addr}"
  log "Updated ${ENV_FILE} (VAULT_ADDR and TF_VAR_vault_address)."

  if [[ "${RESTART_VAULT}" == true ]]; then
    restart_vault_service
  else
    log "Skipped Vault restart (--no-restart)."
  fi

  if [[ "${RUN_VERIFY}" == true ]]; then
    if [[ "${DRY_RUN}" == true ]]; then
      log "Skipped verification in dry-run mode."
      return 0
    fi
    verify_mode_settings "${api_addr}"
    vault_status_check "${api_addr}"
    verify_terraform_config
    verify_packer_config
    log "Verification passed for mode: ${desired_mode}"
  else
    log "Skipped verification (--no-verify)."
  fi
}

run_verify_only() {
  local current_mode api_addr
  [[ -f "${VAULT_HCL}" ]] || die "Vault config not found: ${VAULT_HCL}"

  current_mode="$(detect_mode "${VAULT_HCL}")"
  api_addr="$(extract_hcl_value "${VAULT_HCL}" "api_addr")"
  [[ -n "${api_addr}" ]] || die "api_addr not found in ${VAULT_HCL}"

  if [[ "${current_mode}" == "unknown" ]]; then
    warn "Vault listener mode is unknown; verification continues with api_addr=${api_addr}"
  fi

  MODE="${current_mode}"
  verify_mode_settings "${api_addr}"
  vault_status_check "${api_addr}"
  verify_terraform_config
  verify_packer_config
  log "Verification passed."
}

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
    --environment)
      ENVIRONMENT="${2:-}"
      shift 2
      ;;
    --auto-unseal)
      AUTO_UNSEAL=true
      shift
      ;;
    --no-auto-unseal)
      AUTO_UNSEAL=false
      shift
      ;;
    --no-restart)
      RESTART_VAULT=false
      shift
      ;;
    --no-verify)
      RUN_VERIFY=false
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

case "${MODE}" in
  loopback)
    apply_mode "loopback"
    ;;
  lan)
    apply_mode "lan"
    ;;
  status)
    status_report
    ;;
  verify)
    run_verify_only
    ;;
  ""|-h|--help)
    usage
    exit 0
    ;;
  *)
    die "Unknown command: ${MODE}"
    ;;
esac
