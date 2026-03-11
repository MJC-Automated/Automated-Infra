#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
if [[ -f "${ENV_FILE}" ]]; then
  env_perms="$(stat -c '%a' "${ENV_FILE}" 2>/dev/null || stat -f '%Lp' "${ENV_FILE}" 2>/dev/null || echo '???')"
  if [[ "${env_perms}" != "600" && "${env_perms}" != "400" ]]; then
    echo "WARNING: ${ENV_FILE} permissions are ${env_perms}. Recommended: chmod 600 ${ENV_FILE}" >&2
  fi
  # shellcheck disable=SC1090
  set -a
  source "${ENV_FILE}"
  set +a
fi

################################################################################
#                                                                              #
#  Proxmox VM Provisioning Script - UNIVERSAL VERSION (EXTENDED)               #
#  Supports: Oracle Linux 8.x / Ubuntu 22.04+ / Rocky Linux 9 / AlmaLinux 9 /  #
#            Debian 12+ / Fedora Cloud 43                                      #
#                                                                              #
#  Key Features:                                                               #
#  - Multi-OS support with automatic package manager detection                 #
#  - Dynamic partition configuration using PARTITION_DEFS array                #
#  - Optional data disk toggle (DATA_DISK_ENABLED)                             #
#  - Auto-derived hostname from VM name                                        #
#  - OS-specific optimizations (filesystem, groups, packages)                  #
#  - Deterministic ordering (uses PART_ORDER array)                            #
#  - Safe LV / UUID variable naming for any mountpoint                         #
#  - Robust /etc/fstab managed block (idempotent reruns)                       #
#  - Btrfs support for Fedora root disk detection                              #
#                                                                              #
#  Usability/Reliability Improvements (added)                                  #
#  - Storage validation + storage suggestions on storage-related failures       #
#  - Avoid SIGPIPE/rc=141 failures with pipefail (no grep|head pipelines)       #
#  - Better OS disk resize reporting + optional verification                    #
#  - Swap verification tolerance for minor filesystem/utility rounding          #
#  - Always wait for cloud-init when swap/storage provisioning is expected      #
#  - Cloud-init userdata written to the correct SNIPPET_STORAGE when possible  #
################################################################################

################################################################################
# CONFIGURATION                                                                #
################################################################################

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ VM Configuration                                                        │
# └─────────────────────────────────────────────────────────────────────────┘
readonly VMID="99995"
readonly NAME="debian12-packer-base-80"
readonly DOMAIN="example.internal"     # Domain suffix (FQDN = ${NAME}.${DOMAIN})
readonly FORCE="1"                # 1 = destroy existing VM, 0 = abort if exists
readonly DRY_RUN="0"              # 1 = show what would happen without executing

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ Operating System Selection                                              │
# │ Options: oracle-linux, ubuntu, rocky-linux, alma-linux, debian, fedora  │
# └─────────────────────────────────────────────────────────────────────────┘
readonly OS_TYPE="debian"

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ Source Images - Configure paths for each OS type                        │
# └─────────────────────────────────────────────────────────────────────────┘
readonly ORACLE_LINUX_IMAGE="/var/lib/vz/template/iso/OL8U10_x86_64-kvm-b271.qcow2"
readonly UBUNTU_IMAGE="/var/lib/vz/template/iso/noble-server-cloudimg-amd64.img"
readonly ROCKY_LINUX_IMAGE="/var/lib/vz/template/iso/Rocky-9-GenericCloud.latest.x86_64.qcow2"
readonly ALMA_LINUX_IMAGE="/var/lib/vz/template/iso/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2"
readonly DEBIAN_IMAGE="/var/lib/vz/template/iso/debian-12-genericcloud-amd64.qcow2"
readonly FEDORA_IMAGE="/var/lib/vz/template/iso/Fedora-Cloud-Base-Generic-43-1.6.x86_64.qcow2"

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ Network Configuration                                                   │
# └─────────────────────────────────────────────────────────────────────────┘
readonly BRIDGE="vmbr0"
readonly IPCIDR="192.0.2.0/24"    # Use "dhcp" for DHCP or "10.x.x.x/24"
readonly GATEWAY="198.51.100.14"
readonly DNS="198.51.100.13"

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ Resource Allocation                                                     │
# └─────────────────────────────────────────────────────────────────────────┘
readonly CORES="8"
readonly MEM="8192"               # MB
readonly CPU_TYPE="host"

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ Proxmox Storage Backends                                                │
# └─────────────────────────────────────────────────────────────────────────┘
readonly OS_STORAGE="shared-storage"
readonly DATA_STORAGE="shared-storage"
readonly EFI_STORAGE="shared-storage"
readonly CI_STORAGE="local-lvm"
readonly SNIPPET_STORAGE="local"

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ Disk Sizes (GiB)                                                        │
# └─────────────────────────────────────────────────────────────────────────┘
readonly OS_DISK_SIZE="40"

# ============================================================================
# DATA DISK TOGGLE - Set to 0 to disable data disk and storage provisioning
# ============================================================================
readonly DATA_DISK_ENABLED="0"    # 1 = create data disk, 0 = root disk only
readonly DATA_DISK_SIZE="400"     # Only used if DATA_DISK_ENABLED=1

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ Cloud-Init User Configuration                                           │
# └─────────────────────────────────────────────────────────────────────────┘
readonly CIUSER="${CIUSER:-ansible}"
readonly PASSWORD="${PASSWORD:?Set PASSWORD in ${ENV_FILE} (or export PASSWORD) before running}" # Will be hashed for /etc/shadow
readonly SSH_KEYS_FILE="${SSH_KEYS_FILE:-/root/.ssh/authorized_keys}"

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ PARTITION CONFIGURATION - EASY TO CUSTOMIZE!                            │
# │                                                                         │
# │ Format: "mountpoint:size:user:group"                                    │
# │   - mountpoint: Where to mount (e.g., /u01, /data, /backup)             │
# │   - size: Size in GB, "AUTO" for remaining space, or "0" to skip        │
# │   - user/group: ownership (optional; defaults to CIUSER:CIUSER)         │
# │                                                                         │
# │ Only ONE partition can be "AUTO"                                        │
# │ NOTE: Only used if DATA_DISK_ENABLED=1                                  │
# └─────────────────────────────────────────────────────────────────────────┘
readonly PARTITION_DEFS=(
  "/u01:100"
  "/u02:100"
  "/u03:100"
  "/logs:10"
)

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ Optional OS Update                                                      │
# └─────────────────────────────────────────────────────────────────────────┘
readonly DO_OS_UPDATE="0"         # 1 = enable background update; 0 = skip (safer for templates)

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ Verification Timeouts (cloud-init wait is used for swap too)            │
# └─────────────────────────────────────────────────────────────────────────┘
readonly STORAGE_PROVISION_WAIT="900"
readonly STORAGE_PROVISION_POLL="10"
readonly CLOUDINIT_VERIFY_WAIT="900"
readonly CLOUDINIT_VERIFY_POLL="15"
readonly CLOUDINIT_STATUS_VERBOSE="0"

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ Remaining Space Handling (only used if DATA_DISK_ENABLED=1)             │
# │ Options: IGNORE | WARN | ERROR | AUTO_ASSIGN                            │
# └─────────────────────────────────────────────────────────────────────────┘
readonly REMAINING_SPACE_MODE="WARN"
readonly MIN_REMAINING_WARN="10"

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ Swap Configuration                                                      │
# │ Options: AUTO | 0 | <number in GB>                                      │
# └─────────────────────────────────────────────────────────────────────────┘
readonly SWAP_SIZE="AUTO"

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ Filesystem Configuration (only used if DATA_DISK_ENABLED=1)             │
# │ Set to "auto" to use OS-recommended (xfs for RHEL, ext4 for Ubuntu)     │
# └─────────────────────────────────────────────────────────────────────────┘
readonly FS_TYPE="auto"           # auto | ext4 | xfs
readonly XFS_LOGBSIZE_VALUE="256k"

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ LVM Volume Group Name                                                   │
# └─────────────────────────────────────────────────────────────────────────┘
readonly VG_NAME="vg_data"

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ Behavior Flags                                                          │
# └─────────────────────────────────────────────────────────────────────────┘
readonly BACKUP_CONFIG="1"
readonly WAIT_FOR_VM="1"
readonly WAIT_TIMEOUT="300"
readonly VERIFY_VM="1"
readonly VERIFY_TIMEOUT="600"
readonly VERIFY_RETRY_INTERVAL="15"

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ Logging Configuration                                                   │
# └─────────────────────────────────────────────────────────────────────────┘
readonly LOG_DIR="/var/log/proxmox-vm-provisioning"
readonly LOG_FILE="${LOG_DIR}/vm-${VMID}-$(date +%Y%m%d-%H%M%S).log"

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ Color Definitions                                                       │
# └─────────────────────────────────────────────────────────────────────────┘
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly NC='\033[0m'

################################################################################
# AUTO-DERIVED VARIABLES (DO NOT MODIFY)
################################################################################

readonly HOSTNAME_FQDN="${NAME}.${DOMAIN}"
readonly HOSTNAME_SHORT="${NAME}"

################################################################################
# GLOBAL VARIABLES
################################################################################

declare QCOW2=""
declare PKG_MANAGER=""
declare PKG_UPDATE_CMD=""
declare PKG_INSTALL_CMD=""
declare OS_USER_GROUPS=""        # wheel for RHEL, sudo for Ubuntu/Debian
declare ACTUAL_FS_TYPE=""         # Resolved filesystem type
declare OS_FAMILY=""              # rhel, debian, or fedora
declare CI_INTERFACE="ide2"       # Default cloud-init interface

declare -a PART_ORDER=()
declare -A PARTITIONS=()
declare -A PARTITION_OWNERS=()
declare -A PARTITION_SIZES_FINAL=()

declare TOTAL_PARTITION_SIZE=0
declare CALCULATED_SWAP_SIZE_MB=0
declare AUTO_PARTITION=""
declare REMAINING_SPACE_GB=0
declare VERIFICATION_FAILED=0

################################################################################
# LOGGING FUNCTIONS
################################################################################

setup_logging() {
  mkdir -p "$LOG_DIR"
  exec 1> >(tee -a "$LOG_FILE")
  exec 2>&1
  log_info "Logging to: $LOG_FILE"
}

log_section() {
  echo ""
  echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║${NC} $*"
  echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════════╝${NC}"
}

log_info()    { echo -e "${GREEN}✓${NC} $*"; }
log_warn()    { echo -e "${YELLOW}⚠${NC} $*"; }
log_error()   { echo -e "${RED}✗${NC} $*" >&2; }
log_debug()   { echo -e "${CYAN}[DEBUG]${NC} $*"; }
log_verify()  { echo -e "${MAGENTA}[VERIFY]${NC} $*"; }

die() {
  log_error "$*"
  exit 1
}

################################################################################
# STORAGE HELPERS (USABILITY)
################################################################################

print_storage_config() {
  echo ""
  echo "Configured storages:"
  echo "  OS_STORAGE      = ${OS_STORAGE}   (expects: images)"
  echo "  EFI_STORAGE     = ${EFI_STORAGE}  (expects: images)"
  echo "  CI_STORAGE      = ${CI_STORAGE}   (expects: images)"
  if [[ "$DATA_DISK_ENABLED" == "1" ]]; then
    echo "  DATA_STORAGE    = ${DATA_STORAGE} (expects: images)"
  else
    echo "  DATA_STORAGE    = ${DATA_STORAGE} (ignored; DATA_DISK_ENABLED=0)"
  fi
  echo "  SNIPPET_STORAGE = ${SNIPPET_STORAGE} (expects: snippets)"
}

list_all_storages() {
  echo ""
  echo "Available storages (pvesm status):"
  pvesm status || true
}

list_storages_for_content() {
  local content="$1"
  echo ""
  echo "Storages that support content '${content}':"
  pvesm status --content "$content" || true
}

maybe_hint_storage_failure() {
  local cmdline="$1"
  local output="${2:-}"

  # Heuristics: if command/output indicates storage/volume problems, print helpful storage info.
  if echo "$cmdline $output" | grep -qiE 'storage|pvesm|volid|volume|unable to parse|does not exist|no such|not found'; then
    echo ""
    log_warn "This looks like a storage/volume related failure. Here are your storages:"
    print_storage_config
    list_all_storages
    list_storages_for_content "images"
    list_storages_for_content "snippets"
    echo ""
    log_warn "Fix: ensure the storage names exist on THIS node and support the required content types."
  fi
}

validate_storage_for_content() {
  local storage="$1"
  local content="$2"

  if ! pvesm status --content "$content" 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$storage"; then
    log_error "Storage '${storage}' not found OR does not support content '${content}'."
    print_storage_config
    list_all_storages
    list_storages_for_content "$content"
    echo ""
    log_error "Fix the storage name/content in Proxmox (Datacenter → Storage) or update the variables above."
    die "Storage validation failed for '${storage}' (${content})."
  fi
}

userdata_volid() {
  # The volid we reference in cicustom
  echo "${SNIPPET_STORAGE}:snippets/${VMID}-userdata.yaml"
}

userdata_path() {
  # Best effort: ask Proxmox where the file should live.
  # If this fails (some storage types), fall back to local snippets dir.
  local vol
  vol="$(userdata_volid)"

  if pvesm path "$vol" >/dev/null 2>&1; then
    pvesm path "$vol"
    return 0
  fi

  echo "/var/lib/vz/snippets/${VMID}-userdata.yaml"
  return 0
}

################################################################################
# ERROR HANDLING
################################################################################

on_err() {
  local line="$1"
  local cmd="$2"

  log_error "Failure at line $line"
  log_error "Command: $cmd"
  log_error "Log: $LOG_FILE"

  # If a failure smells like Proxmox storage, show storage info.
  maybe_hint_storage_failure "$cmd" ""
}

trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR

################################################################################
# OS DETECTION AND CONFIGURATION
################################################################################

detect_os_config() {
  log_section "Detecting OS Configuration"

  case "${OS_TYPE,,}" in
    oracle-linux|oracle|ol)
      QCOW2="$ORACLE_LINUX_IMAGE"
      PKG_MANAGER="dnf"
      PKG_UPDATE_CMD="dnf -y update"
      PKG_INSTALL_CMD="dnf -y install"
      OS_USER_GROUPS="wheel"
      OS_FAMILY="rhel"
      ACTUAL_FS_TYPE="${FS_TYPE}"
      [[ "$FS_TYPE" == "auto" ]] && ACTUAL_FS_TYPE="xfs"
      log_info "OS Type: Oracle Linux"
      ;;
    ubuntu)
      QCOW2="$UBUNTU_IMAGE"
      PKG_MANAGER="apt"
      PKG_UPDATE_CMD="apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y upgrade"
      PKG_INSTALL_CMD="DEBIAN_FRONTEND=noninteractive apt-get -y install"
      OS_USER_GROUPS="sudo"
      OS_FAMILY="debian"
      ACTUAL_FS_TYPE="${FS_TYPE}"
      [[ "$FS_TYPE" == "auto" ]] && ACTUAL_FS_TYPE="ext4"
      log_info "OS Type: Ubuntu"
      ;;
    debian)
      QCOW2="$DEBIAN_IMAGE"
      PKG_MANAGER="apt"
      PKG_UPDATE_CMD="apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y upgrade"
      PKG_INSTALL_CMD="DEBIAN_FRONTEND=noninteractive apt-get -y install"
      OS_USER_GROUPS="sudo"
      OS_FAMILY="debian"
      ACTUAL_FS_TYPE="${FS_TYPE}"
      # Use SCSI for Cloud-Init on Debian to avoid IDE CD-ROM driver missing issues
      CI_INTERFACE="scsi10"
      [[ "$FS_TYPE" == "auto" ]] && ACTUAL_FS_TYPE="ext4"
      log_info "OS Type: Debian (Cloud-Init on scsi10)"
      ;;
    rocky-linux|rocky|rl)
      QCOW2="$ROCKY_LINUX_IMAGE"
      PKG_MANAGER="dnf"
      PKG_UPDATE_CMD="dnf -y update"
      PKG_INSTALL_CMD="dnf -y install"
      OS_USER_GROUPS="wheel"
      OS_FAMILY="rhel"
      ACTUAL_FS_TYPE="${FS_TYPE}"
      [[ "$FS_TYPE" == "auto" ]] && ACTUAL_FS_TYPE="xfs"
      log_info "OS Type: Rocky Linux"
      ;;
    alma-linux|alma|al)
      QCOW2="$ALMA_LINUX_IMAGE"
      PKG_MANAGER="dnf"
      PKG_UPDATE_CMD="dnf -y update"
      PKG_INSTALL_CMD="dnf -y install"
      OS_USER_GROUPS="wheel"
      OS_FAMILY="rhel"
      ACTUAL_FS_TYPE="${FS_TYPE}"
      [[ "$FS_TYPE" == "auto" ]] && ACTUAL_FS_TYPE="xfs"
      log_info "OS Type: AlmaLinux"
      ;;
    fedora)
      QCOW2="$FEDORA_IMAGE"
      PKG_MANAGER="dnf"
      PKG_UPDATE_CMD="dnf -y update"
      PKG_INSTALL_CMD="dnf -y install"
      OS_USER_GROUPS="wheel"
      OS_FAMILY="fedora"
      ACTUAL_FS_TYPE="${FS_TYPE}"
      [[ "$FS_TYPE" == "auto" ]] && ACTUAL_FS_TYPE="xfs"
      log_info "OS Type: Fedora"
      ;;
    *)
      die "Unknown OS_TYPE: $OS_TYPE (use: oracle-linux, ubuntu, rocky-linux, alma-linux, debian, fedora)"
      ;;
  esac

  log_info "Source image: $QCOW2"
  log_info "Package manager: $PKG_MANAGER"
  log_info "OS Family: $OS_FAMILY"
  log_info "Filesystem type: $ACTUAL_FS_TYPE"
  log_info "User groups: $OS_USER_GROUPS"
  log_info "Hostname: $HOSTNAME_FQDN (derived from: $NAME)"
}

################################################################################
# UTILITY FUNCTIONS
################################################################################

need() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

gb_to_mb() {
  echo $(( $1 * 1024 ))
}

mb_to_gb() {
  echo $(( $1 / 1024 ))
}

is_number() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

is_valid_mountpoint() {
  local mp="${1:-}"
  [[ -n "$mp" ]] || return 1
  [[ "$mp" == /* ]] || return 1
  [[ "$mp" != "/" ]] || return 1
  [[ "$mp" =~ [[:space:]] ]] && return 1
  return 0
}

mount_id_for() {
  local mp="${1#/}"
  mp="${mp//\//_}"
  mp="${mp//[^a-zA-Z0-9_]/_}"
  mp="${mp#_}"
  [[ -z "$mp" ]] && mp="data"
  printf '%s' "$mp"
}

lv_name_for_mount() {
  local id
  id="$(mount_id_for "$1")"
  printf 'lv_%s' "$id"
}

uuid_id_for_mount() {
  local id
  id="$(mount_id_for "$1")"
  printf '%s' "${id^^}"
}

sed_escape_repl() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//&/\\&}"
  printf '%s' "$s"
}

inject_block() {
  local placeholder="$1"
  local insert_file="$2"
  local target_file="$3"

  [[ -f "$insert_file" ]] || die "inject_block: missing insert file: $insert_file"
  [[ -f "$target_file" ]] || die "inject_block: missing target file: $target_file"

  grep -qE "^[[:space:]]*${placeholder}[[:space:]]*$" "$target_file" || \
    die "inject_block: placeholder '${placeholder}' not found in $target_file"

  awk -v ph="$placeholder" -v ins="$insert_file" '
    $0 ~ "^[[:space:]]*" ph "[[:space:]]*$" {
      while ((getline line < ins) > 0) print line
      close(ins)
      next
    }
    { print }
  ' "$target_file" > "${target_file}.tmp" && mv "${target_file}.tmp" "$target_file"
}

################################################################################
# COMMAND WRAPPERS (better failure hints)
################################################################################

run_or_die() {
  local desc="$1"; shift
  local cmdline
  cmdline="$*"

  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "[DRY-RUN] ${desc}: ${cmdline}"
    return 0
  fi

  if ! "$@"; then
    local rc=$?
    log_error "${desc} failed (exit ${rc})"
    maybe_hint_storage_failure "$cmdline" ""
    die "${desc} failed"
  fi
}

run_capture_or_die() {
  # Captures output (use only for short commands). Always echoes output to log.
  local desc="$1"; shift
  local cmdline
  cmdline="$*"

  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "[DRY-RUN] ${desc}: ${cmdline}"
    return 0
  fi

  local out rc
  out="$($@ 2>&1)"; rc=$?
  [[ -n "$out" ]] && echo "$out"

  if [[ $rc -ne 0 ]]; then
    log_error "${desc} failed (exit ${rc})"
    maybe_hint_storage_failure "$cmdline" "$out"
    die "${desc} failed"
  fi

  # Some Proxmox tools print 'failed:' while returning 0. Catch the obvious ones.
  if echo "$out" | grep -qiE "failed:|got timeout"; then
    log_warn "${desc} reported a problem (but exit code was 0)."
  fi

  return 0
}

################################################################################
# SSH HELPER FUNCTIONS
################################################################################

ssh_execute() {
  local cmd="$1"
  local ip="${IPCIDR%%/*}"

  local ssh_opts=(
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout=10
    -o BatchMode=yes
    -o PreferredAuthentications=publickey
    -o LogLevel=ERROR
    -o ServerAliveInterval=5
    -o ServerAliveCountMax=2
  )

  ssh "${ssh_opts[@]}" "${CIUSER}@${ip}" "$cmd" 2>&1
}

test_ssh() {
  local ip="${IPCIDR%%/*}"

  ssh \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=5 \
    -o BatchMode=yes \
    -o PreferredAuthentications=publickey \
    -o LogLevel=ERROR \
    "${CIUSER}@${ip}" \
    "exit 0" 2>/dev/null
}

################################################################################
# PARTITION VALIDATION FUNCTIONS
################################################################################

parse_partitions() {
  if [[ "$DATA_DISK_ENABLED" != "1" ]]; then
    log_debug "Data disk disabled - skipping partition configuration"
    return 0
  fi

  log_section "Parsing Partition Configuration"

  local auto_count=0
  TOTAL_PARTITION_SIZE=0
  AUTO_PARTITION=""

  PART_ORDER=()
  PARTITIONS=()
  PARTITION_OWNERS=()
  PARTITION_SIZES_FINAL=()

  for def in "${PARTITION_DEFS[@]}"; do
    local mountpoint size user group extra
    IFS=':' read -r mountpoint size user group extra <<< "$def"

    [[ -z "${extra:-}" ]] || die "Invalid partition def (too many fields): $def"
    is_valid_mountpoint "$mountpoint" || die "Invalid mountpoint: '$mountpoint'"

    user="${user:-$CIUSER}"
    group="${group:-$CIUSER}"

    if [[ "${size:-}" == "0" ]]; then
      log_debug "Skipping $mountpoint (size=0)"
      continue
    fi

    if [[ -n "${PARTITIONS[$mountpoint]+x}" ]]; then
      die "Duplicate mountpoint in PARTITION_DEFS: $mountpoint"
    fi

    if [[ "${size^^}" == "AUTO" ]]; then
      [[ $auto_count -gt 0 ]] && die "Only one partition can be AUTO"
      AUTO_PARTITION="$mountpoint"
      PARTITIONS[$mountpoint]="AUTO"
      PARTITION_OWNERS[$mountpoint]="$user:$group"
      PART_ORDER+=("$mountpoint")
      auto_count=$((auto_count + 1))
      log_debug "Partition $mountpoint: AUTO (owner: $user:$group)"
      continue
    fi

    is_number "$size" || die "Invalid size for $mountpoint: '$size'"
    [[ $size -ge 1 && $size -le 51200 ]] || \
      die "Invalid size for $mountpoint: ${size}GB (must be 1-51200)"

    PARTITIONS[$mountpoint]="$size"
    PARTITION_OWNERS[$mountpoint]="$user:$group"
    PART_ORDER+=("$mountpoint")

    TOTAL_PARTITION_SIZE=$((TOTAL_PARTITION_SIZE + size))
    log_debug "Partition $mountpoint: ${size}GB (owner: $user:$group)"
  done

  [[ ${#PART_ORDER[@]} -gt 0 ]] || die "No partitions defined"
  log_info "Parsed ${#PART_ORDER[@]} partition(s), fixed total: ${TOTAL_PARTITION_SIZE}GB"
}

calculate_swap() {

  log_section "Calculating Swap Space"

  if [[ "$SWAP_SIZE" == "AUTO" ]]; then
    local mem_mb="$MEM"
    # swap = (RAM/2) + 1.5GB
    local swap_mb=$(( (mem_mb / 2) + 1536 ))

    [[ $swap_mb -lt 256 ]] && swap_mb=256
    [[ $swap_mb -gt 16384 ]] && swap_mb=16384

    CALCULATED_SWAP_SIZE_MB="$swap_mb"
    log_info "Swap (AUTO): ${swap_mb}MB"
    return 0
  fi

  if [[ "$SWAP_SIZE" == "0" ]]; then
    CALCULATED_SWAP_SIZE_MB=0
    log_warn "Swap disabled"
    return 0
  fi

  is_number "$SWAP_SIZE" || die "Invalid SWAP_SIZE: '$SWAP_SIZE'"
  CALCULATED_SWAP_SIZE_MB="$(gb_to_mb "$SWAP_SIZE")"
  log_info "Swap (MANUAL): ${CALCULATED_SWAP_SIZE_MB}MB"
}

handle_remaining_space() {
  local remaining_mb="$1"
  local remaining_gb
  remaining_gb="$(mb_to_gb "$remaining_mb")"

  [[ $remaining_gb -gt 0 ]] || { REMAINING_SPACE_GB=0; return 0; }

  case "$REMAINING_SPACE_MODE" in
    IGNORE)
      REMAINING_SPACE_GB="$remaining_gb"
      if [[ $remaining_gb -ge $MIN_REMAINING_WARN ]]; then
        log_debug "Remaining: ${remaining_gb}GB (IGNORE)"
      fi
      ;;
    WARN)
      REMAINING_SPACE_GB="$remaining_gb"
      if [[ $remaining_gb -ge $MIN_REMAINING_WARN ]]; then
        log_warn "Remaining: ${remaining_gb}GB will be unused"
      else
        log_debug "Remaining: ${remaining_gb}GB (below warn threshold)"
      fi
      ;;
    ERROR)
      die "Remaining space: ${remaining_gb}GB (ERROR mode requires full allocation)"
      ;;
    AUTO_ASSIGN)
      local last_index=$(( ${#PART_ORDER[@]} - 1 ))
      local last_mp="${PART_ORDER[$last_index]}"
      local orig="${PARTITION_SIZES_FINAL[$last_mp]}"
      local new=$((orig + remaining_gb))
      PARTITION_SIZES_FINAL[$last_mp]="$new"
      REMAINING_SPACE_GB=0
      log_info "AUTO_ASSIGN: ${last_mp} ${orig}GB → ${new}GB"
      ;;
    *)
      die "Invalid REMAINING_SPACE_MODE: $REMAINING_SPACE_MODE"
      ;;
  esac
}

validate_disk_space() {
  if [[ "$DATA_DISK_ENABLED" != "1" ]]; then
    log_debug "Data disk disabled - skipping disk space validation"
    return 0
  fi

  log_section "Validating Disk Space Allocation"

  local data_disk_mb
  data_disk_mb="$(gb_to_mb "$DATA_DISK_SIZE")"

  local swap_mb="$CALCULATED_SWAP_SIZE_MB"
  local fixed_parts_mb
  fixed_parts_mb="$(gb_to_mb "$TOTAL_PARTITION_SIZE")"

  local used_mb=$((swap_mb + fixed_parts_mb))
  local remaining_mb=$((data_disk_mb - used_mb))

  if [[ $remaining_mb -lt 0 ]]; then
    die "Partition configuration exceeds DATA_DISK_SIZE (${DATA_DISK_SIZE}GB)"
  fi

  for mountpoint in "${PART_ORDER[@]}"; do
    if [[ "${PARTITIONS[$mountpoint]}" == "AUTO" ]]; then
      PARTITION_SIZES_FINAL[$mountpoint]=0
    else
      PARTITION_SIZES_FINAL[$mountpoint]="${PARTITIONS[$mountpoint]}"
    fi
  done

  REMAINING_SPACE_GB="$(mb_to_gb "$remaining_mb")"

  if [[ -n "$AUTO_PARTITION" ]]; then
    [[ $remaining_mb -ge 1024 ]] || die "Not enough space for AUTO partition"
    PARTITION_SIZES_FINAL[$AUTO_PARTITION]="$REMAINING_SPACE_GB"
    REMAINING_SPACE_GB=0
    log_info "AUTO partition $AUTO_PARTITION: ${PARTITION_SIZES_FINAL[$AUTO_PARTITION]}GB"
  else
    handle_remaining_space "$remaining_mb"
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "                          DISK SPACE ALLOCATION SUMMARY"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf "  %-40s %20s\n" "Total Data Disk:" "${DATA_DISK_SIZE}GB"

  if [[ $CALCULATED_SWAP_SIZE_MB -gt 0 ]]; then
    printf "  %-40s %20s\n" "Swap:" "$(mb_to_gb "$CALCULATED_SWAP_SIZE_MB")GB"
  fi

  echo ""
  echo "  Partitions:"
  for mountpoint in "${PART_ORDER[@]}"; do
    local owner="${PARTITION_OWNERS[$mountpoint]}"
    printf "    %-30s %12sGB    (owner: %s)\n" "$mountpoint:" "${PARTITION_SIZES_FINAL[$mountpoint]}" "$owner"
  done

  if [[ $REMAINING_SPACE_GB -gt 0 && -z "$AUTO_PARTITION" && "$REMAINING_SPACE_MODE" != "AUTO_ASSIGN" ]]; then
    echo "──────────────────────────────────────────────────────────────────────────────"
    printf "  %-40s %20s\n" "Unused:" "${REMAINING_SPACE_GB}GB"
  fi

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  log_info "Disk space validation passed"
}

################################################################################
# PREFLIGHT CHECKS
################################################################################

preflight_checks() {
  log_section "Running Preflight Checks"

  [[ $EUID -eq 0 ]] || die "This script must be run as root"

  for cmd in qm pvesm awk grep openssl sed ssh nc ping tee qemu-img; do
    need "$cmd"
  done

  detect_os_config

  [[ -f "$QCOW2" ]] || die "Cloud image not found: $QCOW2"
  [[ -f "$SSH_KEYS_FILE" ]] || die "SSH keys file not found: $SSH_KEYS_FILE"

  is_number "$OS_DISK_SIZE" || die "Invalid OS_DISK_SIZE"
  [[ -n "$PASSWORD" ]] || die "PASSWORD is empty"

  if [[ "$DATA_DISK_ENABLED" == "1" ]]; then
    is_number "$DATA_DISK_SIZE" || die "Invalid DATA_DISK_SIZE"
    log_info "Data disk: ENABLED (${DATA_DISK_SIZE}G)"
  else
    log_warn "Data disk: DISABLED (root disk only)"
  fi

  validate_storage_for_content "$OS_STORAGE" "images"
  validate_storage_for_content "$EFI_STORAGE" "images"
  validate_storage_for_content "$CI_STORAGE" "images"
  if [[ "$DATA_DISK_ENABLED" == "1" ]]; then
    validate_storage_for_content "$DATA_STORAGE" "images"
  fi
  validate_storage_for_content "$SNIPPET_STORAGE" "snippets"

  if qm status "$VMID" >/dev/null 2>&1; then
    if [[ "$FORCE" == "1" ]]; then
      log_warn "Destroying existing VM $VMID"
      if [[ "$DRY_RUN" != "1" ]]; then
        qm stop "$VMID" >/dev/null 2>&1 || true
        sleep 2
        qm destroy "$VMID" --purge 1 --destroy-unreferenced-disks 1
        sleep 2
      fi
    else
      die "VM $VMID already exists (set FORCE=1 to override)"
    fi
  fi

  parse_partitions
  calculate_swap
  validate_disk_space

  log_info "All preflight checks passed"
}

################################################################################
# CLOUD-INIT GENERATION
################################################################################

generate_lvm_sections() {
  local lvm_create_file="$1"
  local lvm_format_file="$2"
  local lvm_mkdir_file="$3"
  local lvm_fstab_file="$4"
  local lvm_chown_file="$5"

  : > "$lvm_create_file"
  : > "$lvm_format_file"
  : > "$lvm_mkdir_file"
  : > "$lvm_fstab_file"
  : > "$lvm_chown_file"

  if [[ $CALCULATED_SWAP_SIZE_MB -gt 0 ]]; then
    echo "      if [[ \"\${SWAP_MB}\" -gt 0 ]]; then lvcreate -y -n lv_swap -L \"\${SWAP_MB}M\" ${VG_NAME}; fi" >> "$lvm_create_file"
    echo "      if [[ \"\${SWAP_MB}\" -gt 0 ]]; then mkswap -f /dev/${VG_NAME}/lv_swap; fi" >> "$lvm_format_file"
    echo "      if [[ \"\${SWAP_MB}\" -gt 0 ]]; then UUID_SWAP=\$(blkid -s UUID -o value /dev/${VG_NAME}/lv_swap); printf 'UUID=%s  none  swap  sw,nofail  0 0\\n' \"\$UUID_SWAP\" >> /etc/fstab; fi" >> "$lvm_fstab_file"
  fi

  local mount_opts="defaults,noatime,nofail"
  local mkfs_force_flag="-F"

  if [[ "$ACTUAL_FS_TYPE" == "xfs" ]]; then
    mount_opts+=",logbsize=${XFS_LOGBSIZE_VALUE}"
    mkfs_force_flag="-f"
  fi

  for mountpoint in "${PART_ORDER[@]}"; do
    local size="${PARTITION_SIZES_FINAL[$mountpoint]}"
    local owner="${PARTITION_OWNERS[$mountpoint]}"

    local lv_name uuid_id
    lv_name="$(lv_name_for_mount "$mountpoint")"
    uuid_id="$(uuid_id_for_mount "$mountpoint")"

    if [[ "${PARTITIONS[$mountpoint]}" == "AUTO" ]]; then
      echo "      lvcreate -y -n ${lv_name} -l 100%FREE ${VG_NAME}" >> "$lvm_create_file"
    else
      echo "      lvcreate -y -n ${lv_name} -L ${size}G ${VG_NAME}" >> "$lvm_create_file"
    fi

    echo "      mkfs.${ACTUAL_FS_TYPE} ${mkfs_force_flag} /dev/${VG_NAME}/${lv_name}" >> "$lvm_format_file"
    echo "      mkdir -p ${mountpoint}" >> "$lvm_mkdir_file"
    echo "      UUID_${uuid_id}=\$(blkid -s UUID -o value /dev/${VG_NAME}/${lv_name})" >> "$lvm_fstab_file"
    echo "      printf 'UUID=%s  ${mountpoint}  ${ACTUAL_FS_TYPE}  ${mount_opts}  0 2\\n' \"\$UUID_${uuid_id}\" >> /etc/fstab" >> "$lvm_fstab_file"
    echo "      chown ${owner} ${mountpoint}" >> "$lvm_chown_file"
  done
}

get_base_packages() {
  case "$PKG_MANAGER" in
    apt)
      echo "qemu-guest-agent lvm2 gdisk parted xfsprogs e2fsprogs chrony nano wget curl rsync python3 sudo libpam-systemd"
      ;;
    dnf|yum)
      if [[ "$OS_FAMILY" == "fedora" ]]; then
        echo "qemu-guest-agent lvm2 gdisk parted xfsprogs e2fsprogs chrony nano wget curl rsync python3"
      else
        echo "qemu-guest-agent lvm2 gdisk parted xfsprogs e2fsprogs chrony nano wget curl rsync python39"
      fi
      ;;
  esac
}

create_cloudinit_config() {
  log_section "Preparing Cloud-Init Configuration"

  [[ "$DRY_RUN" == "1" ]] && {
    log_info "[DRY-RUN] Would create cloud-init userdata"
    return 0
  }

  local ssh_key
  ssh_key="$(awk '
    {
      sub(/\r$/, "");
      if ($0 ~ /^[[:space:]]*$/) next;
      if ($0 ~ /^[[:space:]]*#/) next;
      print; exit
    }
  ' "$SSH_KEYS_FILE")"
  [[ -n "$ssh_key" ]] || die "No SSH key found in $SSH_KEYS_FILE"

  local salt pass_hash
  salt="$(openssl rand -hex 8)"
  pass_hash="$(openssl passwd -6 -salt "$salt" "$PASSWORD")"

  local userdata_file
  userdata_file="$(userdata_path)"

  mkdir -p "$(dirname "$userdata_file")"

  if [[ -f "$userdata_file" && "$BACKUP_CONFIG" == "1" ]]; then
    cp "$userdata_file" "${userdata_file}.backup-$(date +%Y%m%d-%H%M%S)"
  fi

  if [[ "$DATA_DISK_ENABLED" == "1" ]]; then
    create_cloudinit_with_storage "$userdata_file" "$ssh_key" "$pass_hash"
  else
    create_cloudinit_minimal "$userdata_file" "$ssh_key" "$pass_hash"
  fi

  chmod 600 "$userdata_file"
  log_info "Cloud-init configuration created: $userdata_file"
}

create_cloudinit_minimal() {
  local userdata_file="$1"
  local ssh_key="$2"
  local pass_hash="$3"

  local base_packages
  base_packages="$(get_base_packages | tr ' ' '\n' | awk '{print "  - "$0}')"

  cat > "$userdata_file" <<'EOF'
#cloud-config
hostname: __HOSTNAME_FQDN__
fqdn: __HOSTNAME_FQDN__
preserve_hostname: false
ssh_pwauth: true

chpasswd:
  expire: false

timezone: Africa/Nairobi

users:
  - name: __CIUSER__
    groups: [__OS_USER_GROUPS__]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    lock_passwd: false
    passwd: "__PASS_HASH__"
    ssh_authorized_keys:
      - "__SSH_KEY__"

package_update: true

packages:
__BASE_PACKAGES__

write_files:
  - path: /usr/local/sbin/ensure-swap.sh
    permissions: '0755'
    owner: root:root
    content: |
      #!/usr/bin/env bash
      set -Eeuo pipefail

      LOG=/var/log/ensure-swap.log
      mkdir -p "$(dirname "${LOG}")"
      exec >>"${LOG}" 2>&1
      echo "=== ensure-swap $(date -Iseconds) ==="

      desired_mb="__SWAP_MB__"
      [[ "${desired_mb}" =~ ^[0-9]+$ ]] || exit 0
      [[ "${desired_mb}" -gt 0 ]] || exit 0

      existing_kib="$(awk 'NR>1{s+=$3} END{print s+0}' /proc/swaps 2>/dev/null || echo 0)"
      existing_mb=$(( existing_kib / 1024 ))

      # If the image already has enough swap (e.g., Fedora zram), do nothing.
      if [[ "${existing_mb}" -ge "${desired_mb}" ]]; then
        exit 0
      fi

      add_mb=$(( desired_mb - existing_mb ))

      # Round up to reduce fragmentation and avoid tiny swap files
      round=128
      add_mb=$(( (add_mb + round - 1) / round * round ))

      active_swaps="$(awk 'NR>1{print $1}' /proc/swaps 2>/dev/null || true)"
      swapfile=""
      for candidate in /swapfile /swapfile2 /swapfile3 /swapfile4; do
        if grep -qx "${candidate}" <<< "${active_swaps}"; then
          continue
        fi
        swapfile="${candidate}"
        break
      done
      [[ -n "${swapfile}" ]] || exit 0

      rm -f "${swapfile}" 2>/dev/null || true

      if command -v fallocate >/dev/null 2>&1; then
        fallocate -l "${add_mb}M" "${swapfile}"
      else
        dd if=/dev/zero of="${swapfile}" bs=1M count="${add_mb}" status=none
      fi

      chmod 600 "${swapfile}"
      mkswap -f "${swapfile}"

      grep -qE "^[[:space:]]*${swapfile}[[:space:]]" /etc/fstab || \
        echo "${swapfile} none swap sw,nofail 0 0" >> /etc/fstab

      swapon "${swapfile}"

runcmd:
  - [ udevadm, settle ]
  - [ /usr/local/sbin/ensure-swap.sh ]
  - [ systemctl, enable, --now, qemu-guest-agent ]
  - [ /bin/bash, -c, "if [[ '__DO_OS_UPDATE__' == '1' ]]; then nohup bash -c '__PKG_UPDATE_CMD__' &>/var/log/os-update.log & fi" ]

final_message: "Cloud-init finished. Root disk only configuration."
EOF

  # Replace __BASE_PACKAGES__ placeholder
  sed -i "/^__BASE_PACKAGES__$/r /dev/stdin" "$userdata_file" <<< "$base_packages"
  sed -i "/^__BASE_PACKAGES__$/d" "$userdata_file"

  # Variable substitution
  local esc

  esc="$(sed_escape_repl "$CIUSER")"
  sed -i "s|__CIUSER__|$esc|g" "$userdata_file"

  esc="$(sed_escape_repl "$OS_USER_GROUPS")"
  sed -i "s|__OS_USER_GROUPS__|$esc|g" "$userdata_file"

  esc="$(sed_escape_repl "$pass_hash")"
  sed -i "s|__PASS_HASH__|$esc|g" "$userdata_file"

  esc="$(sed_escape_repl "$ssh_key")"
  sed -i "s|__SSH_KEY__|$esc|g" "$userdata_file"

  esc="$(sed_escape_repl "$HOSTNAME_FQDN")"
  sed -i "s|__HOSTNAME_FQDN__|$esc|g" "$userdata_file"

  esc="$(sed_escape_repl "$CALCULATED_SWAP_SIZE_MB")"
  sed -i "s|__SWAP_MB__|$esc|g" "$userdata_file"

  esc="$(sed_escape_repl "$DO_OS_UPDATE")"
  sed -i "s|__DO_OS_UPDATE__|$esc|g" "$userdata_file"

  esc="$(sed_escape_repl "$PKG_UPDATE_CMD")"
  sed -i "s|__PKG_UPDATE_CMD__|$esc|g" "$userdata_file"
}


create_cloudinit_with_storage() {
  local userdata_file="$1"
  local ssh_key="$2"
  local pass_hash="$3"

  local mount_points=""
  for mountpoint in "${PART_ORDER[@]}"; do
    mount_points+=" ${mountpoint}"
  done

  local tmp_dir="/tmp/cloudinit-$$"
  mkdir -p "$tmp_dir"

  generate_lvm_sections \
    "$tmp_dir/lvm_create.tmp" \
    "$tmp_dir/lvm_format.tmp" \
    "$tmp_dir/lvm_mkdir.tmp" \
    "$tmp_dir/lvm_fstab.tmp" \
    "$tmp_dir/lvm_chown.tmp"

  local base_packages
  base_packages="$(get_base_packages | tr ' ' '\n' | awk '{print "  - "$0}')"

  cat > "$userdata_file" <<'EOF'
#cloud-config
hostname: __HOSTNAME_FQDN__
fqdn: __HOSTNAME_FQDN__
preserve_hostname: false
ssh_pwauth: true

chpasswd:
  expire: false

timezone: Africa/Nairobi

users:
  - name: __CIUSER__
    groups: [__OS_USER_GROUPS__]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    lock_passwd: false
    passwd: "__PASS_HASH__"
    ssh_authorized_keys:
      - "__SSH_KEY__"

package_update: true

packages:
__BASE_PACKAGES__

write_files:
  - path: /usr/local/sbin/provision_storage.sh
    permissions: '0755'
    content: |
      #!/usr/bin/env bash
      set -euo pipefail

      LOGFILE="/var/log/storage-provision.log"
      exec 1> >(tee -a "$LOGFILE")
      exec 2>&1
      set -x

      MARKER="/var/local/storage-provisioned"
      [[ -f "$MARKER" ]] && exit 0

      echo "═══════════════════════════════════════════════════════════════════════"
      echo " Storage Provisioning Starting"
      echo "═══════════════════════════════════════════════════════════════════════"
      date

      DESIRED_SWAP_MB="__SWAP_MB__"
      if [[ ! "${DESIRED_SWAP_MB}" =~ ^[0-9]+$ ]]; then DESIRED_SWAP_MB=0; fi
      existing_kib="$(awk 'NR>1{s+=$3} END{print s+0}' /proc/swaps 2>/dev/null || echo 0)"
      EXISTING_SWAP_MB=$(( existing_kib / 1024 ))
      NEED_SWAP_MB=$(( DESIRED_SWAP_MB - EXISTING_SWAP_MB ))
      [[ "${NEED_SWAP_MB}" -lt 0 ]] && NEED_SWAP_MB=0
      SWAP_MB="${NEED_SWAP_MB}"
      echo "Swap desired: ${DESIRED_SWAP_MB}MB, existing: ${EXISTING_SWAP_MB}MB, adding: ${SWAP_MB}MB"
      FS_TYPE="__FS_TYPE__"
      VG_NAME="__VG_NAME__"

      for i in {1..90}; do
        lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print $1; exit}' | grep -q . && break
        sleep 1
      done

      if vgs "$VG_NAME" >/dev/null 2>&1; then
        echo "$VG_NAME already exists; ensuring mounts are active..."
        mount -a || true
        swapon -a || true
        touch "$MARKER"
        exit 0
      fi

      find_root_disk() {
        local root_src root_disk pv_disk
        root_src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
        [[ -z "$root_src" ]] && return 1

        # FIX FOR FEDORA/BTRFS: Strip subvolume notation (e.g. /dev/sda4[/root] -> /dev/sda4)
        root_src="${root_src%\[*}"

        if [[ "$root_src" =~ ^/dev/mapper/ ]] || [[ "$root_src" =~ ^/dev/dm- ]]; then
          pv_disk="$(pvs --noheadings -o pv_name 2>/dev/null | awk 'NF{gsub(/ /, ""); print; exit}')"
          if [[ -n "$pv_disk" ]]; then
            root_disk="$(lsblk -no PKNAME "$pv_disk" 2>/dev/null | awk 'NF{print; exit}')"
            [[ -n "$root_disk" ]] && echo "/dev/$root_disk" && return 0
          fi
        fi

        root_disk="$(lsblk -no PKNAME "$root_src" 2>/dev/null | awk 'NF{print; exit}')"
        [[ -n "$root_disk" ]] && echo "/dev/$root_disk" && return 0
        return 1
      }

      find_data_disk() {
        local root_disk="$1"
        local data="" max=0

        while read -r name type size; do
          [[ "$type" != "disk" ]] && continue
          local dev="/dev/$name"
          [[ "$dev" == "$root_disk" ]] && continue

          local bytes
          bytes="$(numfmt --from=iec "$size" 2>/dev/null || echo 0)"
          if [[ $bytes -gt $max ]]; then
            max=$bytes
            data="$dev"
          fi
        done < <(lsblk -dn -o NAME,TYPE,SIZE)

        echo "$data"
      }

      udevadm settle || true
      sleep 2

      ROOT_DISK="$(find_root_disk)" || true
      [[ -n "$ROOT_DISK" ]] || {
        echo "ERROR: could not determine root disk"
        exit 1
      }
      echo "Root disk: $ROOT_DISK"

      DATA_DISK="$(find_data_disk "$ROOT_DISK")" || true
      [[ -n "$DATA_DISK" && -b "$DATA_DISK" ]] || {
        echo "ERROR: no data disk found"
        lsblk
        exit 1
      }
      echo "Data disk: $DATA_DISK"

      echo "Cleaning any previous $VG_NAME on $DATA_DISK..."
      vgchange -an "$VG_NAME" 2>/dev/null || true
      vgremove -ff "$VG_NAME" 2>/dev/null || true
      pvremove -ff "${DATA_DISK}"* 2>/dev/null || true
      wipefs -a -f "${DATA_DISK}"* 2>/dev/null || true
      sgdisk --zap-all "$DATA_DISK" 2>/dev/null || true
      udevadm settle || true
      partprobe "$DATA_DISK" 2>/dev/null || true
      sleep 2

      echo "Partitioning data disk..."
      sgdisk -n 1:0:0 -t 1:8e00 -c 1:"LVM Data" "$DATA_DISK"
      partprobe "$DATA_DISK" 2>/dev/null || true
      udevadm settle || true
      sleep 2

      PART=""
      if [[ "$DATA_DISK" =~ nvme ]]; then
        PART="${DATA_DISK}p1"
      else
        PART="${DATA_DISK}1"
      fi

      for i in {1..45}; do
        [[ -b "$PART" ]] && break
        sleep 1
      done

      [[ -b "$PART" ]] || {
        echo "ERROR: partition $PART not present"
        lsblk
        exit 1
      }

      echo "Creating PV/VG on $PART..."
      wipefs -a -f "$PART" 2>/dev/null || true

      ok=0
      for attempt in {1..8}; do
        if pvcreate -ff -y "$PART" 2>/dev/null; then
          ok=1
          break
        fi
        echo "pvcreate failed; retrying (attempt $attempt/8)"
        dmsetup remove_all 2>/dev/null || true
        sleep 2
        udevadm settle || true
      done

      [[ $ok -eq 1 ]] || {
        echo "FATAL: pvcreate failed"
        exit 1
      }

      vgcreate "$VG_NAME" "$PART"

      echo "Creating Logical Volumes..."
      __LVM_CREATE_SECTION__

      echo "Formatting filesystems..."
      __LVM_FORMAT_SECTION__

      echo "Creating mount points..."
      __LVM_MKDIR_SECTION__

      echo "Updating /etc/fstab (managed block)..."
      BEGIN="### BEGIN $VG_NAME managed"
      END="### END $VG_NAME managed"

      if grep -qF "$BEGIN" /etc/fstab; then
        awk -v b="$BEGIN" -v e="$END" '
          $0==b {in=1; next}
          $0==e {in=0; next}
          in==1 {next}
          {print}
        ' /etc/fstab > /etc/fstab.new && mv /etc/fstab.new /etc/fstab
      fi

      echo "$BEGIN" >> /etc/fstab
      __LVM_FSTAB_SECTION__
      echo "$END" >> /etc/fstab

      echo "Mounting filesystems..."
      mount -a

      swapon -a || true

      echo "Setting permissions..."
      chmod 775__MOUNT_POINTS__ || true
      __LVM_CHOWN_SECTION__

      echo "Verification..."
      lsblk
      df -h | grep -E "Filesystem|^/dev/mapper/${VG_NAME}" || true
      if [[ "$SWAP_MB" != "0" ]]; then
        swapon --show || true
      fi
      vgs "$VG_NAME" || true
      lvs -a || true

      touch "$MARKER"
      echo "═══════════════════════════════════════════════════════════════════════"
      echo " Storage Provisioning Complete"
      echo "═══════════════════════════════════════════════════════════════════════"
      date

runcmd:
  - [ udevadm, settle ]
  - [ systemctl, enable, --now, qemu-guest-agent ]
  - [ /bin/bash, -lc, "/usr/local/sbin/provision_storage.sh" ]
  - [ /bin/bash, -c, "if [[ '__DO_OS_UPDATE__' == '1' ]]; then nohup bash -c '__PKG_UPDATE_CMD__' &>/var/log/os-update.log & fi" ]

final_message: "Cloud-init finished. Storage provisioning complete."
EOF

  # Replace __BASE_PACKAGES__ placeholder
  sed -i "/^__BASE_PACKAGES__$/r /dev/stdin" "$userdata_file" <<< "$base_packages"
  sed -i "/^__BASE_PACKAGES__$/d" "$userdata_file"

  # Variable substitution
  local esc

  esc="$(sed_escape_repl "$CIUSER")"
  sed -i "s|__CIUSER__|$esc|g" "$userdata_file"

  esc="$(sed_escape_repl "$OS_USER_GROUPS")"
  sed -i "s|__OS_USER_GROUPS__|$esc|g" "$userdata_file"

  esc="$(sed_escape_repl "$pass_hash")"
  sed -i "s|__PASS_HASH__|$esc|g" "$userdata_file"

  esc="$(sed_escape_repl "$ssh_key")"
  sed -i "s|__SSH_KEY__|$esc|g" "$userdata_file"

  esc="$(sed_escape_repl "$HOSTNAME_FQDN")"
  sed -i "s|__HOSTNAME_FQDN__|$esc|g" "$userdata_file"

  esc="$(sed_escape_repl "$mount_points")"
  sed -i "s|__MOUNT_POINTS__|$esc|g" "$userdata_file"

  esc="$(sed_escape_repl "$ACTUAL_FS_TYPE")"
  sed -i "s|__FS_TYPE__|$esc|g" "$userdata_file"

  esc="$(sed_escape_repl "$VG_NAME")"
  sed -i "s|__VG_NAME__|$esc|g" "$userdata_file"

  esc="$(sed_escape_repl "$CALCULATED_SWAP_SIZE_MB")"
  sed -i "s|__SWAP_MB__|$esc|g" "$userdata_file"

  esc="$(sed_escape_repl "$DO_OS_UPDATE")"
  sed -i "s|__DO_OS_UPDATE__|$esc|g" "$userdata_file"

  esc="$(sed_escape_repl "$PKG_UPDATE_CMD")"
  sed -i "s|__PKG_UPDATE_CMD__|$esc|g" "$userdata_file"

  # Inject multi-line sections
  inject_block "__LVM_CREATE_SECTION__" "$tmp_dir/lvm_create.tmp" "$userdata_file"
  inject_block "__LVM_FORMAT_SECTION__" "$tmp_dir/lvm_format.tmp" "$userdata_file"
  inject_block "__LVM_MKDIR_SECTION__" "$tmp_dir/lvm_mkdir.tmp" "$userdata_file"
  inject_block "__LVM_FSTAB_SECTION__" "$tmp_dir/lvm_fstab.tmp" "$userdata_file"
  inject_block "__LVM_CHOWN_SECTION__" "$tmp_dir/lvm_chown.tmp" "$userdata_file"

  rm -rf "$tmp_dir"
}

################################################################################
# VM CREATION AND CONFIGURATION
################################################################################

create_vm() {
  log_section "Creating Virtual Machine"

  [[ "$DRY_RUN" == "1" ]] && {
    log_info "[DRY-RUN] Would create VM $VMID"
    return 0
  }

  run_or_die "qm create" qm create "$VMID" \
    --name "$NAME" \
    --cores "$CORES" \
    --memory "$MEM" \
    --cpu "$CPU_TYPE" \
    --net0 "virtio,bridge=$BRIDGE" \
    --ostype l26 \
    --machine q35 \
    --bios ovmf \
    --scsihw virtio-scsi-single \
    --serial0 socket \
    --vga serial0

  log_info "Virtual machine $VMID created successfully"
}

configure_disks() {
  log_section "Configuring Storage Disks"

  [[ "$DRY_RUN" == "1" ]] && {
    log_info "[DRY-RUN] Would configure disks for VM $VMID"
    return 0
  }

  run_or_die "Configure EFI disk" qm set "$VMID" --efidisk0 "${EFI_STORAGE}:1,format=raw,efitype=4m,pre-enrolled-keys=0"
  log_info "EFI disk configured"

  # Use OS-specific interface for Cloud-Init (IDE vs SCSI)
  run_or_die "Configure cloud-init disk" qm set "$VMID" --"${CI_INTERFACE}" "${CI_STORAGE}:cloudinit"
  log_info "Cloud-init drive configured on ${CI_INTERFACE}"

  log_info "Importing OS disk from cloud image..."

  # The import streams progress; don't capture.
  if qm disk import --help >/dev/null 2>&1; then
    run_or_die "Import OS disk" qm disk import "$VMID" "$QCOW2" "$OS_STORAGE" --format raw
  else
    run_or_die "Import OS disk" qm importdisk "$VMID" "$QCOW2" "$OS_STORAGE" --format raw
  fi

  local os_volid
  os_volid="$(qm config "$VMID" | awk -F': ' '/^unused0:/{print $2; exit}')"
  [[ -n "$os_volid" ]] || die "Could not find imported OS disk (unused0)"

  if ! qm set "$VMID" --scsi0 "$os_volid,discard=on,iothread=1,ssd=1,aio=io_uring"; then
    log_warn "io_uring not supported, using default AIO"
    run_or_die "Attach OS disk" qm set "$VMID" --scsi0 "$os_volid,discard=on,iothread=1,ssd=1"
  fi

  run_or_die "Set boot order" qm set "$VMID" --boot order=scsi0
  qm set "$VMID" --delete unused0 >/dev/null 2>&1 || true
  log_info "OS disk attached successfully"

  log_info "Resizing OS disk to ${OS_DISK_SIZE}G..."
  # Capture output to detect 'failed: got timeout' even if exit code is 0.
  run_capture_or_die "Resize OS disk" qm disk resize "$VMID" scsi0 "${OS_DISK_SIZE}G"

  # Best-effort verify virtual size using pvesm path + qemu-img info
  local os_path desired_bytes actual_bytes
  desired_bytes=$(( OS_DISK_SIZE * 1024 * 1024 * 1024 ))
  os_path="$(pvesm path "$os_volid" 2>/dev/null || true)"
  if [[ -n "$os_path" ]]; then
    actual_bytes="$(qemu-img info "$os_path" 2>/dev/null | sed -n 's/.*(\([0-9][0-9]*\) bytes).*/\1/p' | head -n1)"
    if [[ "$actual_bytes" =~ ^[0-9]+$ ]]; then
      if [[ "$actual_bytes" -ge "$desired_bytes" ]]; then
        log_info "OS disk resized successfully"
      else
        log_warn "OS disk resize may not have completed (virtual size bytes=${actual_bytes}, desired bytes=${desired_bytes})."
      fi
    else
      log_info "OS disk resize requested (could not verify size via qemu-img info)."
    fi
  else
    log_info "OS disk resize requested (could not resolve volume path for verification)."
  fi

  if [[ "$DATA_DISK_ENABLED" == "1" ]]; then
    log_info "Adding ${DATA_DISK_SIZE}G data disk..."

    if ! qm set "$VMID" --scsi1 "${DATA_STORAGE}:${DATA_DISK_SIZE},discard=on,iothread=1,ssd=1,aio=io_uring"; then
      log_warn "io_uring not supported for data disk, using default AIO"
      run_or_die "Attach data disk" qm set "$VMID" --scsi1 "${DATA_STORAGE}:${DATA_DISK_SIZE},discard=on,iothread=1,ssd=1"
    fi

    log_info "Data disk added successfully"
  else
    log_info "Data disk creation skipped (disabled)"
  fi

  log_info "Disk configuration complete"
}

setup_cloudinit() {
  log_section "Configuring Cloud-Init"

  [[ "$DRY_RUN" == "1" ]] && {
    log_info "[DRY-RUN] Would setup cloud-init for VM $VMID"
    return 0
  }

  run_or_die "Attach custom cloud-init" qm set "$VMID" --cicustom "user=$(userdata_volid)"
  log_info "Custom cloud-init userdata attached"

  if [[ "$IPCIDR" == "dhcp" || -z "$IPCIDR" ]]; then
    run_or_die "Set IP config" qm set "$VMID" --ipconfig0 "ip=dhcp" --nameserver "$DNS"
    log_info "Network configuration: DHCP"
  else
    run_or_die "Set IP config" qm set "$VMID" --ipconfig0 "ip=$IPCIDR,gw=$GATEWAY" --nameserver "$DNS"
    log_info "Network configuration: Static ($IPCIDR)"
  fi

  run_or_die "Enable guest agent" qm set "$VMID" --agent enabled=1
  log_info "QEMU guest agent enabled"

  qm cloudinit update "$VMID" >/dev/null 2>&1 || true
  log_info "Cloud-init configuration complete"
}

start_vm() {
  log_section "Starting Virtual Machine"

  [[ "$DRY_RUN" == "1" ]] && {
    log_info "[DRY-RUN] Would start VM $VMID"
    return 0
  }

  run_or_die "Start VM" qm start "$VMID"
  log_info "Virtual machine $VMID started successfully"
}

################################################################################
# WAIT AND VERIFICATION FUNCTIONS
################################################################################

wait_for_vm() {
  [[ "$WAIT_FOR_VM" == "1" ]] || return 0
  [[ "$DRY_RUN" == "1" ]] && return 0

  log_section "Waiting for VM to be Ready"

  if [[ "$IPCIDR" == "dhcp" ]]; then
    log_warn "DHCP configured: cannot auto-wait reliably (no static IP)"
    return 0
  fi

  local ip="${IPCIDR%%/*}"
  local elapsed=0

  while [[ $elapsed -lt $WAIT_TIMEOUT ]]; do
    if ping -c 1 -W 2 "$ip" >/dev/null 2>&1; then
      log_info "VM is reachable via ping"
      sleep 8

      if nc -z -w 5 "$ip" 22 >/dev/null 2>&1; then
        log_info "SSH port is open"
        return 0
      fi
    fi

    sleep 5
    elapsed=$((elapsed + 5))
    echo -n "."
  done

  echo ""
  log_warn "Timeout waiting for VM. Try: ssh ${CIUSER}@${ip}"
}

get_cloudinit_status() {
  ssh_execute "(sudo -n cloud-init status --long 2>&1) || \
               (sudo -n cloud-init status 2>&1) || \
               (cloud-init status --long 2>&1) || \
               (cloud-init status 2>&1)"
}

cloudinit_is_done() {
  local txt
  txt="$(cat)"
  echo "$txt" | grep -qiE 'status:[[:space:]]*done|\bdone\b'
}

print_cloudinit_poll_line() {
  local out="$1"

  if [[ "$CLOUDINIT_STATUS_VERBOSE" == "1" ]]; then
    echo "$out" | sed -n '1,22p'
    return 0
  fi

  # Avoid grep|head pipelines (SIGPIPE/rc=141 with pipefail). Use awk to take first 3 matches.
  local line
  line="$(echo "$out" | tr -d '\r' | awk '
    BEGIN{IGNORECASE=1; c=0}
    /status:|detail:|stage:|boot finished|done/ {
      gsub(/[[:space:]]+$/, "");
      lines[++c]=$0;
      if (c==3) exit
    }
    END{
      for (i=1; i<=c; i++) {
        printf "%s%s", lines[i], (i<c?" | ":"")
      }
    }
  ')"

  if [[ -n "$line" ]]; then
    log_verify "cloud-init: $line"
  else
    log_verify "cloud-init: $(echo "$out" | sed -n '1p')"
  fi
}

wait_for_cloudinit_done() {
  [[ "$DRY_RUN" == "1" ]] && return 0

  # Wait for cloud-init when:
  # - storage provisioning is enabled, OR
  # - swap is expected (ensure-swap runs in cloud-init for root-only)
  if [[ "$DATA_DISK_ENABLED" != "1" && "${CALCULATED_SWAP_SIZE_MB}" -le 0 ]]; then
    log_debug "Skipping cloud-init wait (no storage provisioning, swap disabled)"
    return 0
  fi

  log_verify "Waiting for cloud-init to finish (poll every ${CLOUDINIT_VERIFY_POLL}s, timeout ${CLOUDINIT_VERIFY_WAIT}s. You can tail -500f /var/log/cloud-init-output.log on the VM to follow)"

  local elapsed=0

  while [[ $elapsed -lt $CLOUDINIT_VERIFY_WAIT ]]; do
    local out

    if out="$(get_cloudinit_status)"; then
      print_cloudinit_poll_line "$out"

      if echo "$out" | cloudinit_is_done; then
        log_info "Cloud-init has completed successfully"
        return 0
      fi
    else
      log_warn "Could not query cloud-init (ssh): $(echo "${out:-}" | sed -n '1p')"
    fi

    sleep "$CLOUDINIT_VERIFY_POLL"
    elapsed=$((elapsed + CLOUDINIT_VERIFY_POLL))
    echo -n "."
  done

  echo ""
  log_warn "Timed out waiting for cloud-init after ${CLOUDINIT_VERIFY_WAIT}s"
  return 1
}

wait_for_storage_marker() {
  if [[ "$DATA_DISK_ENABLED" != "1" ]]; then
    return 0
  fi

  log_verify "Waiting for storage provisioning marker (/var/local/storage-provisioned)"

  local elapsed=0

  while [[ $elapsed -lt $STORAGE_PROVISION_WAIT ]]; do
    if ssh_execute "sudo -n test -f /var/local/storage-provisioned" >/dev/null 2>&1; then
      log_info "Storage provisioning marker detected"
      return 0
    fi

    sleep "$STORAGE_PROVISION_POLL"
    elapsed=$((elapsed + STORAGE_PROVISION_POLL))
    echo -n "."
  done

  echo ""
  log_warn "Timed out waiting for storage marker after ${STORAGE_PROVISION_WAIT}s"

  log_warn "Diagnostics: /var/log/storage-provision.log (tail 80) if present"
  ssh_execute "sudo -n tail -n 80 /var/log/storage-provision.log 2>/dev/null || true" || true
  log_warn "Diagnostics: cloud-init status --long"
  ssh_execute "sudo -n cloud-init status --long 2>/dev/null || true" || true
  return 1
}

run_verification() {
  [[ "$VERIFY_VM" == "1" ]] || return 0
  [[ "$DRY_RUN" == "1" ]] && return 0

  if [[ "$IPCIDR" == "dhcp" ]]; then
    log_warn "DHCP configured: skipping verification (no deterministic IP)"
    return 0
  fi

  log_section "Post-Provision Verification"

  local elapsed=0
  log_verify "Waiting for SSH authentication..."

  while [[ $elapsed -lt 180 ]]; do
    if test_ssh; then
      log_info "SSH authentication successful"
      break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  if [[ $elapsed -ge 180 ]]; then
    log_error "SSH authentication failed"
    VERIFICATION_FAILED=$((VERIFICATION_FAILED + 1))
    return 1
  fi

  wait_for_cloudinit_done || true

  if [[ "$DATA_DISK_ENABLED" == "1" ]]; then
    if ! wait_for_storage_marker; then
      log_warn "Proceeding with checks even though marker not observed yet"
    fi
  fi


  if [[ $CALCULATED_SWAP_SIZE_MB -gt 0 ]]; then
    log_verify "Checking swap size (>= ${CALCULATED_SWAP_SIZE_MB}MB, small rounding tolerated)."
    local swap_kib swap_mb
    swap_kib="$(ssh_execute "sudo -n awk 'NR>1{s+=\$3} END{print s+0}' /proc/swaps" 2>/dev/null || echo 0)"
    swap_kib="$(echo "$swap_kib" | tail -n1 | tr -dc '0-9' || true)"
    [[ -n "$swap_kib" ]] || swap_kib=0
    swap_mb=$(( swap_kib / 1024 ))

    local tol_mb=32
    local min_mb
    if [[ $CALCULATED_SWAP_SIZE_MB -gt $tol_mb ]]; then
      min_mb=$(( CALCULATED_SWAP_SIZE_MB - tol_mb ))
    else
      min_mb=$CALCULATED_SWAP_SIZE_MB
    fi

    if [[ $swap_mb -ge $min_mb ]]; then
      log_info "Swap OK: ${swap_mb}MB"
    else
      log_error "Swap LOW: ${swap_mb}MB (desired: ${CALCULATED_SWAP_SIZE_MB}MB)"
      VERIFICATION_FAILED=$((VERIFICATION_FAILED + 1))
    fi
  fi

  if [[ "$DATA_DISK_ENABLED" == "1" ]]; then
    log_verify "Checking mount points..."

    for mountpoint in "${PART_ORDER[@]}"; do
      if ssh_execute "sudo -n mountpoint -q ${mountpoint}" >/dev/null 2>&1; then
        log_info "${mountpoint} is mounted"
      else
        log_error "${mountpoint} is NOT mounted"
        VERIFICATION_FAILED=$((VERIFICATION_FAILED + 1))
      fi
    done

    log_verify "Checking volume group..."

    if ssh_execute "sudo -n vgs ${VG_NAME}" >/dev/null 2>&1; then
      log_info "${VG_NAME} exists"
    else
      log_error "${VG_NAME} is missing"
      VERIFICATION_FAILED=$((VERIFICATION_FAILED + 1))
    fi

  else
    log_info "Skipping storage verification (data disk disabled)"
  fi

  log_section "Verification Summary"

  if [[ $VERIFICATION_FAILED -eq 0 ]]; then
    log_info "All verification checks passed successfully"
  else
    log_error "${VERIFICATION_FAILED} verification check(s) failed"
    return 1
  fi
}

################################################################################
# FINAL SUMMARY
################################################################################

print_summary() {
  log_section "Provisioning Complete"

  local ip="${IPCIDR%%/*}"

  cat <<SUMMARY

╔════════════════════════════════════════════════════════════════════════════╗
║                          VM DETAILS                                        ║
╚════════════════════════════════════════════════════════════════════════════╝

  VMID:         $VMID
  Name:         $NAME
  Hostname:     $HOSTNAME_FQDN
  OS Type:      $OS_TYPE
  OS Family:    $OS_FAMILY
  Address:      $IPCIDR
  User:         $CIUSER

╔════════════════════════════════════════════════════════════════════════════╗
║                          STORAGE LAYOUT                                    ║
╚════════════════════════════════════════════════════════════════════════════╝

  OS Disk:      ${OS_DISK_SIZE}G (scsi0)
SUMMARY

  if [[ "$DATA_DISK_ENABLED" == "1" ]]; then
    echo "  Data Disk:    ${DATA_DISK_SIZE}G (scsi1) → ${VG_NAME}"
    echo "  Filesystem:   ${ACTUAL_FS_TYPE}"
    echo ""
    echo "  Mount Points:"
    for mountpoint in "${PART_ORDER[@]}"; do
      local size="${PARTITION_SIZES_FINAL[$mountpoint]}"
      local owner="${PARTITION_OWNERS[$mountpoint]}"
      printf "    %-20s %8sGB    (owner: %-15s)\n" "$mountpoint" "$size" "$owner"
    done
  else
    echo "  Data Disk:    DISABLED (root disk only)"
  fi

  cat <<SUMMARY

╔════════════════════════════════════════════════════════════════════════════╗
║                          ACCESS INFORMATION                                ║
╚════════════════════════════════════════════════════════════════════════════╝

  SSH Access:   ssh ${CIUSER}@${ip}

╔════════════════════════════════════════════════════════════════════════════╗
║                            LOG FILES                                       ║
╚════════════════════════════════════════════════════════════════════════════╝

  Host Log:     $LOG_FILE
SUMMARY

  if [[ "$DATA_DISK_ENABLED" == "1" ]]; then
    cat <<SUMMARY
  Guest Log:    ssh ${CIUSER}@${ip} 'sudo tail -200 /var/log/storage-provision.log'
SUMMARY
  fi

  echo ""
}

################################################################################
# MAIN EXECUTION
################################################################################

main() {
  echo ""
  echo "╔════════════════════════════════════════════════════════════════════════════╗"
  echo "║                                                                            ║"
  echo "║           Proxmox VM Provisioning - UNIVERSAL VERSION (EXTENDED)           ║"
  echo "║     Supports: Oracle Linux / Ubuntu / Rocky / AlmaLinux / Debian / Fedora  ║"
  echo "║                                                                            ║"
  echo "╚════════════════════════════════════════════════════════════════════════════╝"
  echo ""

  [[ "$DRY_RUN" == "1" ]] && echo -e "${YELLOW}═══ DRY-RUN MODE ENABLED ═══${NC}\n"

  setup_logging
  preflight_checks

  [[ "$DRY_RUN" == "1" ]] && {
    log_info "Dry-run validation complete"
    exit 0
  }

  create_cloudinit_config
  create_vm
  configure_disks
  setup_cloudinit
  start_vm
  wait_for_vm
  run_verification || true
  print_summary

  [[ "$VERIFY_VM" == "1" && $VERIFICATION_FAILED -gt 0 ]] && exit 1
  exit 0
}

main "$@"

################################################################################
# END OF SCRIPT
################################################################################
