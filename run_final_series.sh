#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_ENV_FILE="${ROOT_DIR}/.env"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="${ROOT_DIR}/test-runs/final-series-${RUN_ID}"
LOG_DIR="${RUN_DIR}/logs"
REPORT_DIR="${RUN_DIR}/reports"
PROGRESS_LOG="${RUN_DIR}/progress.log"
MASTER_LOG="${RUN_DIR}/master.log"

if [[ -f "${ROOT_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  set -a
  source "${ROOT_ENV_FILE}"
  set +a
fi

mkdir -p "${LOG_DIR}" "${REPORT_DIR}"
touch "${PROGRESS_LOG}" "${MASTER_LOG}"

exec > >(tee -a "${MASTER_LOG}") 2>&1

ANSIBLE_BIN="${ANSIBLE_BIN:-ansible-playbook}"
ANSIBLE_ADHOC_BIN="${ANSIBLE_ADHOC_BIN:-ansible}"
ANSIBLE_FORKS="${ANSIBLE_FORKS:-5}"
export ANSIBLE_BECOME_TIMEOUT="${ANSIBLE_BECOME_TIMEOUT:-300}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
STRICT_IDEMPOTENCY="${STRICT_IDEMPOTENCY:-false}"
TCP_WAIT_TIMEOUT="${TCP_WAIT_TIMEOUT:-3600}"
LOGIN_WAIT_TIMEOUT="${LOGIN_WAIT_TIMEOUT:-7200}"
READY_CHECK_INTERVAL="${READY_CHECK_INTERVAL:-10}"
TCP_PROBE_TIMEOUT="${TCP_PROBE_TIMEOUT:-10}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-20}"
HTTP_VERIFY_TIMEOUT="${HTTP_VERIFY_TIMEOUT:-30}"
SSH_STRICT_HOST_KEY_CHECKING="${SSH_STRICT_HOST_KEY_CHECKING:-accept-new}"

DB_SYS_PASSWORD="${DB_SYS_PASSWORD:-}"
APP_USER="${APP_USER:-APP_CRM}"
APP_USER_PASSWORD="${APP_USER_PASSWORD:-}"

HOST_DB19_IP="${HOST_DB19_IP:-198.51.100.10}"
HOST_DB21_IP="${HOST_DB21_IP:-198.51.100.11}"
HOST_WLS12_IP="${HOST_WLS12_IP:-198.51.100.12}"
HOST_WLS14_IP="${HOST_WLS14_IP:-198.51.100.13}"
HOST_UBUNTU_IP="${HOST_UBUNTU_IP:-198.51.100.14}"

HOST_DB19_FQDN="${HOST_DB19_FQDN:-oracle19c.example.internal}"
HOST_DB21_FQDN="${HOST_DB21_FQDN:-oracle21c.example.internal}"

DB19_ORACLE_HOME="${DB19_ORACLE_HOME:-/u01/app/oracle/product/19.0.0/dbhome_1}"
DB21_ORACLE_HOME="${DB21_ORACLE_HOME:-/u01/app/oracle/product/21.0.0/dbhome_1}"

INVENTORY_FILE="${ROOT_DIR}/inventories/${ENVIRONMENT}/inventory.ini"
INVENTORY_ALIAS_FILE="${ROOT_DIR}/inventories/aliases.ini"
MANAGED_HOST_LIMIT="${MANAGED_HOST_LIMIT:-public-weblogic14c-01,public-weblogic12c-01,public-database21c-01,public-database19c-01,public-jenkins-01}"
NFS_BOOTSTRAP_LIMIT="${NFS_BOOTSTRAP_LIMIT:-weblogic12c:weblogic14c:database19c:database21c}"
TIME_SYNC_LIMIT="${TIME_SYNC_LIMIT:-ntp_servers:ntp_clients}"

PASS_STATUS_TSV="${REPORT_DIR}/step_status.tsv"
IDEMPOTENCY_TSV="${REPORT_DIR}/idempotency.tsv"
PLAY_RECAP_TXT="${REPORT_DIR}/play_recaps.txt"

for required_secret in DB_SYS_PASSWORD APP_USER_PASSWORD; do
  if [[ -z "${!required_secret:-}" ]]; then
    echo "ERROR: ${required_secret} is not set. Configure ${ROOT_ENV_FILE} or export it." >&2
    exit 1
  fi
done
unset required_secret

cat > "${PASS_STATUS_TSV}" <<'EOF'
step|rc|log_file
EOF

cat > "${IDEMPOTENCY_TSV}" <<'EOF'
playbook|run|host|changed|failed|unreachable
EOF

touch "${PLAY_RECAP_TXT}"

progress() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "${PROGRESS_LOG}"
}

require_file() {
  local path="$1"
  if [[ ! -f "${path}" ]]; then
    progress "ERROR missing file: ${path}"
    exit 1
  fi
}

require_bin() {
  local bin_path="$1"
  if ! command -v "${bin_path}" >/dev/null 2>&1; then
    progress "ERROR executable not found in PATH: ${bin_path}"
    exit 1
  fi
}

has_python_version_marker() {
  local dir="$1"
  [[ -f "${dir}/.python-version" || -f "${dir}/.python_version" ]]
}

read_python_version_marker() {
  local dir="$1"
  local marker_file=""

  if [[ -f "${dir}/.python-version" ]]; then
    marker_file="${dir}/.python-version"
  elif [[ -f "${dir}/.python_version" ]]; then
    marker_file="${dir}/.python_version"
  fi

  if [[ -n "${marker_file}" ]]; then
    awk 'NF {print; exit}' "${marker_file}"
  fi
}

resolve_ansible_project_root() {
  local preferred_dir="${1:-${ROOT_DIR}}"
  local dir

  dir="$(cd "${preferred_dir}" 2>/dev/null && pwd)" || dir="${preferred_dir}"
  while true; do
    if has_python_version_marker "${dir}"; then
      printf '%s\n' "${dir}"
      return 0
    fi
    if [[ "${dir}" == "${ROOT_DIR}" || "${dir}" == "/" ]]; then
      break
    fi
    dir="$(dirname "${dir}")"
  done

  local marker_file
  marker_file="$(find "${ROOT_DIR}" -mindepth 2 -maxdepth 4 -type f \( -name '.python-version' -o -name '.python_version' \) | sort | head -n 1 || true)"
  if [[ -n "${marker_file}" ]]; then
    dirname "${marker_file}"
    return 0
  fi

  progress "ERROR no project root with .python-version/.python_version found under ${ROOT_DIR}"
  exit 1
}

require_bin_in_dir() {
  local bin_path="$1"
  local dir="$2"
  local pyenv_version
  pyenv_version="$(read_python_version_marker "${dir}")"

  if [[ -n "${pyenv_version}" ]]; then
    if ! (cd "${dir}" && PYENV_VERSION="${pyenv_version}" command -v "${bin_path}" >/dev/null 2>&1); then
      progress "ERROR executable not found in PATH from ${dir} with PYENV_VERSION=${pyenv_version}: ${bin_path}"
      exit 1
    fi
    return 0
  fi

  if ! (cd "${dir}" && command -v "${bin_path}" >/dev/null 2>&1); then
    progress "ERROR executable not found in PATH from ${dir}: ${bin_path}"
    exit 1
  fi
}

require_ansible_ipc() {
  local shm_dir="/dev/shm"
  local probe_file
  probe_file="${shm_dir}/.ansible-ipc-check-$$"

  if [[ ! -d "${shm_dir}" ]]; then
    progress "ERROR ${shm_dir} is missing; Ansible multiprocessing requires shared memory."
    exit 1
  fi

  if ! : > "${probe_file}" 2>/dev/null; then
    progress "ERROR ${shm_dir} is not writable by $(id -un); Ansible multiprocessing cannot start."
    progress "ERROR fix host permissions/mount options for ${shm_dir} and rerun."
    exit 1
  fi

  rm -f "${probe_file}" 2>/dev/null || true
}

run_ansible_adhoc() {
  local pyenv_version
  pyenv_version="$(read_python_version_marker "${ANSIBLE_PROJECT_ROOT}")"

  (
    cd "${ANSIBLE_PROJECT_ROOT}"
    if [[ -n "${pyenv_version}" ]]; then
      PYENV_VERSION="${pyenv_version}" "${ANSIBLE_ADHOC_BIN}" "$@"
    else
      "${ANSIBLE_ADHOC_BIN}" "$@"
    fi
  )
}

run_step() {
  local step_name="$1"
  shift
  local step_log="${LOG_DIR}/${step_name}.log"
  local rc

  progress "START ${step_name}"
  set +e
  {
    echo "===== ${step_name} START $(date -Is) ====="
    local cmd_rc=0
    if "$@"; then
      cmd_rc=0
    else
      cmd_rc=$?
    fi
    echo "===== ${step_name} END rc=${cmd_rc} $(date -Is) ====="
    exit "${cmd_rc}"
  } 2>&1 | tee "${step_log}"
  rc="${PIPESTATUS[0]}"
  set -e
  printf '%s|%s|%s\n' "${step_name}" "${rc}" "${step_log}" >> "${PASS_STATUS_TSV}"

  if [[ "${rc}" -ne 0 ]]; then
    progress "FAIL ${step_name} rc=${rc}"
    exit "${rc}"
  fi

  progress "DONE ${step_name}"
}

append_recap() {
  local playbook_name="$1"
  local run_name="$2"
  local log_file="$3"

  {
    echo
    echo "##### ${playbook_name} ${run_name} #####"
    awk '
      /PLAY RECAP/ {in_recap=1}
      in_recap {print}
      /TASKS RECAP/ {in_recap=0}
    ' "${log_file}"
  } >> "${PLAY_RECAP_TXT}"
}

collect_idempotency_row() {
  local playbook_name="$1"
  local run_name="$2"
  local log_file="$3"

  awk -v pb="${playbook_name}" -v rn="${run_name}" '
    /: ok=/ {
      host=$1
      changed=""; failed=""; unreachable=""
      if (match($0, /changed=[0-9]+/)) {
        changed=substr($0, RSTART+8, RLENGTH-8)
      }
      if (match($0, /failed=[0-9]+/)) {
        failed=substr($0, RSTART+7, RLENGTH-7)
      }
      if (match($0, /unreachable=[0-9]+/)) {
        unreachable=substr($0, RSTART+12, RLENGTH-12)
      }
      printf "%s|%s|%s|%s|%s|%s\n", pb, rn, host, changed, failed, unreachable
    }
  ' "${log_file}" >> "${IDEMPOTENCY_TSV}"
}

enforce_idempotency_zero_changed() {
  local playbook_name="$1"
  local rerun_log="$2"

  if awk '
    /: ok=/ {
      if (match($0, /changed=([0-9]+)/, m) && m[1] != "0") {
        bad=1
      }
    }
    END { exit bad ? 1 : 0 }
  ' "${rerun_log}"; then
    progress "IDEMPOTENCY OK ${playbook_name} (all changed=0 on rerun)"
    return 0
  fi

  if [[ "${STRICT_IDEMPOTENCY}" == "true" ]]; then
    progress "ERROR idempotency drift detected on ${playbook_name} rerun"
    exit 1
  fi

  progress "WARN idempotency drift detected on ${playbook_name} rerun"
}

run_playbook_twice() {
  local playbook_name="$1"
  local playbook_dir="$2"
  local limit_group="$3"
  local extra_args="${4:-}"

  local run1_log="${LOG_DIR}/${playbook_name}.run1.log"
  local run2_log="${LOG_DIR}/${playbook_name}.run2.log"
  local playbook_root
  local playbook_pyenv_version
  local pyenv_prefix=""

  playbook_root="$(resolve_ansible_project_root "${ROOT_DIR}/${playbook_dir}")"
  playbook_pyenv_version="$(read_python_version_marker "${playbook_root}")"
  if [[ -n "${playbook_pyenv_version}" ]]; then
    printf -v pyenv_prefix 'PYENV_VERSION=%q ' "${playbook_pyenv_version}"
  fi

  run_step "${playbook_name}_run1" bash -lc \
    "cd '${playbook_root}' && ${pyenv_prefix}'${ANSIBLE_BIN}' main.yml -i '${INVENTORY_FILE}' -i '${INVENTORY_ALIAS_FILE}' --limit '${limit_group}' --forks '${ANSIBLE_FORKS}' ${extra_args} > '${run1_log}' 2>&1"
  append_recap "${playbook_name}" "run1" "${run1_log}"
  collect_idempotency_row "${playbook_name}" "run1" "${run1_log}"

  run_step "${playbook_name}_run2" bash -lc \
    "cd '${playbook_root}' && ${pyenv_prefix}'${ANSIBLE_BIN}' main.yml -i '${INVENTORY_FILE}' -i '${INVENTORY_ALIAS_FILE}' --limit '${limit_group}' --forks '${ANSIBLE_FORKS}' ${extra_args} > '${run2_log}' 2>&1"
  append_recap "${playbook_name}" "run2" "${run2_log}"
  collect_idempotency_row "${playbook_name}" "run2" "${run2_log}"
  enforce_idempotency_zero_changed "${playbook_name}" "${run2_log}"
}

progress "Run directory: ${RUN_DIR}"
progress "STRICT_IDEMPOTENCY=${STRICT_IDEMPOTENCY}"
ANSIBLE_PROJECT_ROOT="$(resolve_ansible_project_root "${ROOT_DIR}/ansible_user_management")"
progress "Ansible execution root: ${ANSIBLE_PROJECT_ROOT}"
require_bin_in_dir "${ANSIBLE_BIN}" "${ANSIBLE_PROJECT_ROOT}"
require_bin_in_dir "${ANSIBLE_ADHOC_BIN}" "${ANSIBLE_PROJECT_ROOT}"
require_file "${ROOT_DIR}/terraform-proxmox/environments/${ENVIRONMENT}.tfvars"
require_file "${ROOT_DIR}/ansible_user_management/.vault_password"
require_file "${INVENTORY_ALIAS_FILE}"
require_ansible_ipc

run_step "terraform_destroy_${ENVIRONMENT}" bash -lc \
  "printf 'yes\n' | make -C '${ROOT_DIR}/terraform-proxmox' destroy ENVIRONMENT='${ENVIRONMENT}'"

run_step "terraform_apply_${ENVIRONMENT}" bash -lc \
  "make -C '${ROOT_DIR}/terraform-proxmox' apply ENVIRONMENT='${ENVIRONMENT}'"

require_file "${INVENTORY_FILE}"

run_step "wait_for_hosts_ready_all" bash -lc "
  set -Eeuo pipefail

  ips=(
    '${HOST_WLS14_IP}'
    '${HOST_WLS12_IP}'
    '${HOST_DB19_IP}'
    '${HOST_DB21_IP}'
    '${HOST_UBUNTU_IP}'
  )
  for ip in \"\${ips[@]}\"; do
    echo \"-- WAIT TCP/22 \${ip} (timeout ${TCP_WAIT_TIMEOUT}s) --\"
    waited=0
    until timeout ${TCP_PROBE_TIMEOUT} bash -lc \"</dev/tcp/\${ip}/22\" >/dev/null 2>&1; do
      sleep ${READY_CHECK_INTERVAL}
      waited=\$((waited+${READY_CHECK_INTERVAL}))
      if [ \"\${waited}\" -ge ${TCP_WAIT_TIMEOUT} ]; then
        echo \"TCP timeout: \${ip}\"
        exit 1
      fi
    done

    echo \"-- WAIT SSH login readiness \${ip} (timeout ${LOGIN_WAIT_TIMEOUT}s) --\"
    waited=0
    until ssh -o StrictHostKeyChecking=${SSH_STRICT_HOST_KEY_CHECKING} -o BatchMode=yes -o ConnectTimeout=${SSH_CONNECT_TIMEOUT} ansible@\"\${ip}\" \
      \"test ! -e /run/nologin && test ! -e /etc/nologin && (command -v cloud-init >/dev/null 2>&1 && cloud-init status --wait >/dev/null 2>&1 || true) && test ! -e /run/nologin && test ! -e /etc/nologin\" \
      >/dev/null 2>&1; do
      sleep ${READY_CHECK_INTERVAL}
      waited=\$((waited+${READY_CHECK_INTERVAL}))
      if [ \"\${waited}\" -ge ${LOGIN_WAIT_TIMEOUT} ]; then
        echo \"SSH login readiness timeout: \${ip}\"
        exit 1
      fi
    done

    echo \"HOST ready: \${ip}\"
  done
"

run_step "bootstrap_nfs_backup_share_all" run_ansible_adhoc "${NFS_BOOTSTRAP_LIMIT}" \
  -i "${INVENTORY_FILE}" -b -m shell -a \
  "set -euo pipefail; (command -v dnf >/dev/null 2>&1 && dnf -y -q install nfs-utils || yum -y -q install nfs-utils); mkdir -p /Backup-Share; modprobe nfs >/dev/null 2>&1 || true; modprobe nfs4 >/dev/null 2>&1 || true; systemctl enable --now rpcbind >/dev/null 2>&1 || true; grep -qE '^192\\.0\\.2\\.60:/mnt/HD/HD_a2/remotebackup[[:space:]]+/Backup-Share[[:space:]]+nfs' /etc/fstab || echo '198.51.100.15:/mnt/HD/HD_a2/remotebackup /Backup-Share nfs rw,_netdev,nofail,nfsvers=4.1,tcp 0 0' >> /etc/fstab; mountpoint -q /Backup-Share || (mount -t nfs -o rw,nfsvers=4.1,tcp 198.51.100.15:/mnt/HD/HD_a2/remotebackup /Backup-Share || mount -t nfs -o rw,nfsvers=3,tcp 198.51.100.15:/mnt/HD/HD_a2/remotebackup /Backup-Share); mountpoint /Backup-Share; df -hT /Backup-Share"

run_playbook_twice "time_sync" "time_sync" "${TIME_SYNC_LIMIT}"

progress "Waiting 1minute before next playbook..."
sleep 60

run_playbook_twice "oracle19c" "bootstrap_playbooks/oracle819c" "database19c"

progress "Waiting 1minute before next playbook..."
sleep 60

run_playbook_twice "oracle21c" "bootstrap_playbooks/oracle821c" "database21c"

progress "Waiting 1minute before next playbook..."
sleep 60

run_playbook_twice "weblogic12c" "bootstrap_playbooks/oracle_weblogic12c" "weblogic12c"

progress "Waiting 1minute before next playbook..."
sleep 60

run_playbook_twice "weblogic14c" "bootstrap_playbooks/oracle_weblogic14c" "weblogic14c"

progress "Waiting 1minute before next playbook..."
sleep 60

run_playbook_twice "user_management" "ansible_user_management" \
  "${MANAGED_HOST_LIMIT}" \
  "--vault-password-file .vault_password"

run_step "verify_db19_remote_login" ssh -o StrictHostKeyChecking="${SSH_STRICT_HOST_KEY_CHECKING}" "ansible@${HOST_DB19_IP}" "sudo -iu oracle bash -c \"export ORACLE_HOME=${DB19_ORACLE_HOME}; export PATH=\\\$ORACLE_HOME/bin:\\\$PATH; echo 'select global_name from global_name;' | sqlplus -s \\\"sys/${DB_SYS_PASSWORD}@//${HOST_DB19_FQDN}:1521/pdb1 as sysdba\\\"; echo 'select user from dual;' | sqlplus -s \\\"${APP_USER}/${APP_USER_PASSWORD}@//${HOST_DB19_FQDN}:1521/pdb1\\\"\""

run_step "verify_db21_remote_login" ssh -o StrictHostKeyChecking="${SSH_STRICT_HOST_KEY_CHECKING}" "ansible@${HOST_DB21_IP}" "sudo -iu oracle bash -c \"export ORACLE_HOME=${DB21_ORACLE_HOME}; export PATH=\\\$ORACLE_HOME/bin:\\\$PATH; echo 'select global_name from global_name;' | sqlplus -s \\\"sys/${DB_SYS_PASSWORD}@//${HOST_DB21_FQDN}:1521/pdb1 as sysdba\\\"; echo 'select user from dual;' | sqlplus -s \\\"${APP_USER}/${APP_USER_PASSWORD}@//${HOST_DB21_FQDN}:1521/pdb1\\\"\""

run_step "verify_db_firewall_and_listener" bash -lc "
  for target in ${HOST_DB19_IP} ${HOST_DB21_IP}; do
    echo \"=== \${target} ===\"
    ssh -o StrictHostKeyChecking=${SSH_STRICT_HOST_KEY_CHECKING} ansible@\${target} \"sudo bash -lc \\\"systemctl is-active firewalld; firewall-cmd --list-ports; ss -ltnp | egrep ':(1521|1522)' || true\\\"\"
  done
"

run_step "verify_weblogic12_services_and_ports" bash -lc "
  ssh -o StrictHostKeyChecking=${SSH_STRICT_HOST_KEY_CHECKING} ansible@${HOST_WLS12_IP} \"sudo bash -lc \\\"systemctl is-active wlsCLIENT_ADOMAIN8006.service; firewall-cmd --list-ports; ss -ltnp | egrep ':(7001|8006)' || true\\\"\"
  code=\$(curl -k -sS -o /dev/null -w '%{http_code}' --max-time ${HTTP_VERIFY_TIMEOUT} http://${HOST_WLS12_IP}:8006/console || true)
  echo \"WLS12 console HTTP status: \${code}\"
"

run_step "verify_weblogic14_services_and_managed_servers" bash -lc "
  ssh -o StrictHostKeyChecking=${SSH_STRICT_HOST_KEY_CHECKING} ansible@${HOST_WLS14_IP} \"sudo bash -lc \\\"systemctl is-active wlsWLS14CDOMAINNM.service; systemctl is-active wlsWLS14CDOMAIN7001.service; systemctl is-active wlsWLS14CDOMAIN8001.service; systemctl is-active wlsWLS14CDOMAIN8002.service; firewall-cmd --list-ports; ss -ltnp | egrep ':(5556|7001|8001|8002)' || true\\\"\"
  for url in http://${HOST_WLS14_IP}:7001/console http://${HOST_WLS14_IP}:8001 http://${HOST_WLS14_IP}:8002; do
    code=\$(curl -k -sS -o /dev/null -w '%{http_code}' --max-time ${HTTP_VERIFY_TIMEOUT} \"\$url\" || true)
    echo \"\$url -> HTTP_\${code}\"
  done
"

run_step "verify_user_management_vm_side" run_ansible_adhoc all -i "${INVENTORY_FILE}" \
  -l "${MANAGED_HOST_LIMIT}" \
  -b -m shell \
  -a 'set -eu; for u in user2 user1 user3 user4 user5; do id -u "$u"; chage -l "$u" | awk -F": " "/Maximum/{print \$2; exit}"; done; awk -F: "\$1==\"ansible\"{print \$2}" /etc/shadow | grep -E "^!|^\\*" >/dev/null'

progress "All steps completed successfully."
progress "Artifacts:"
progress "  ${MASTER_LOG}"
progress "  ${PROGRESS_LOG}"
progress "  ${PASS_STATUS_TSV}"
progress "  ${IDEMPOTENCY_TSV}"
progress "  ${PLAY_RECAP_TXT}"
