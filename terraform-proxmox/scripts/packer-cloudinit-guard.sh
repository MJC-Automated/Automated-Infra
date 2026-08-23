#!/usr/bin/env bash
# Keep Packer's temporary Proxmox cloud-init input on the non-deprecated
# cloud-config users list, then remove every temporary host-side artifact.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  packer-cloudinit-guard.sh prepare
  packer-cloudinit-guard.sh cleanup
  packer-cloudinit-guard.sh verify

Required environment:
  PVE_HOST             Proxmox SSH host
  PVE_NODE             Expected live Proxmox node name
  SOURCE_VMID          Stopped Packer source VMID
  TARGET_VMID          Packer result VMID
  ENVIRONMENT          Environment name used in the owned snippet name
  SSH_USERNAME         Packer communicator user
  SSH_PUBLIC_KEY_FILE  Public key used by Packer's SSH communicator

Optional environment:
  SNIPPET_STORAGE      Proxmox snippets storage (default: local)
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_value() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "${name} is required"
}

[[ $# -eq 1 ]] || {
  usage >&2
  exit 1
}
ACTION="$1"
case "${ACTION}" in
  prepare|cleanup|verify) ;;
  *) usage >&2; exit 1 ;;
esac

for name in PVE_HOST PVE_NODE SOURCE_VMID TARGET_VMID ENVIRONMENT; do
  require_value "${name}"
done

[[ "${SOURCE_VMID}" =~ ^[1-9][0-9]*$ ]] || die "SOURCE_VMID must be a positive integer"
[[ "${TARGET_VMID}" =~ ^[1-9][0-9]*$ ]] || die "TARGET_VMID must be a positive integer"
[[ "${SOURCE_VMID}" != "${TARGET_VMID}" ]] || die "source and target VMIDs must differ"
[[ "${ENVIRONMENT}" =~ ^[A-Za-z0-9_-]+$ ]] || die "ENVIRONMENT contains unsupported characters"
if [[ "${ACTION}" == "prepare" ]]; then
  require_value SSH_USERNAME
  require_value SSH_PUBLIC_KEY_FILE
  [[ "${SSH_USERNAME}" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "SSH_USERNAME is not a valid Linux account name"
  [[ -s "${SSH_PUBLIC_KEY_FILE}" ]] || die "SSH public key is missing: ${SSH_PUBLIC_KEY_FILE}"
fi

SNIPPET_STORAGE="${SNIPPET_STORAGE:-local}"
[[ "${SNIPPET_STORAGE}" =~ ^[A-Za-z0-9_-]+$ ]] || die "SNIPPET_STORAGE contains unsupported characters"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)
SNIPPET_NAME="packer-${ENVIRONMENT}-${TARGET_VMID}-userdata.yaml"
SNIPPET_VOLID="${SNIPPET_STORAGE}:snippets/${SNIPPET_NAME}"

remote() {
  ssh "${SSH_OPTS[@]}" "root@${PVE_HOST}" "$@"
}

assert_node() {
  local actual
  actual="$(remote hostname)"
  [[ "${actual}" == "${PVE_NODE}" ]] || die "PVE node mismatch: expected ${PVE_NODE}, got ${actual}"
}

vm_exists() {
  local output
  if output="$(remote "qm status ${1}" 2>&1)"; then
    return 0
  fi
  if [[ "${output}" == *"does not exist"* ]]; then
    return 1
  fi
  die "could not determine whether VM ${1} exists: ${output}"
}

vm_config_value() {
  local vmid="$1"
  local key="$2"
  remote "qm config ${vmid}" | sed -n "s/^${key}: //p" | head -n 1
}

owned_cicustom_attached() {
  local vmid="$1"
  [[ "$(vm_config_value "${vmid}" cicustom || true)" == "user=${SNIPPET_VOLID}" ]]
}

assert_no_foreign_cicustom() {
  local vmid="$1"
  local current
  current="$(vm_config_value "${vmid}" cicustom || true)"
  [[ -z "${current}" || "${current}" == "user=${SNIPPET_VOLID}" ]] || \
    die "VM ${vmid} has a non-owned cicustom attachment: ${current}"
}

snippet_path() {
  remote "pvesm path ${SNIPPET_VOLID}"
}

prepare() (
  local source_status public_key snippet_file

  vm_exists "${SOURCE_VMID}" || die "source VM ${SOURCE_VMID} does not exist"
  if vm_exists "${TARGET_VMID}"; then
    die "target VM ${TARGET_VMID} already exists; remove or inspect it before building"
  fi

  source_status="$(remote "qm status ${SOURCE_VMID}" | awk '{print $2}')"
  [[ "${source_status}" == "stopped" ]] || die "source VM ${SOURCE_VMID} must be stopped (is ${source_status})"
  assert_no_foreign_cicustom "${SOURCE_VMID}"

  public_key="$(awk 'NF && $1 !~ /^#/ { print; exit }' "${SSH_PUBLIC_KEY_FILE}")"
  [[ "${public_key}" =~ ^(ssh-|ecdsa-|sk-) ]] || die "SSH public key has an unsupported format"

  snippet_file="$(mktemp)"
  trap 'rm -f "${snippet_file}"' EXIT
  chmod 600 "${snippet_file}"
  {
    printf '%s\n' '#cloud-config' 'preserve_hostname: false' 'users:' "  - name: ${SSH_USERNAME}" '    ssh_authorized_keys:'
    printf '      - %s\n' "${public_key}"
  } >"${snippet_file}"

  remote "install -d -m 0755 \"$(dirname "$(snippet_path)")\""
  scp "${SSH_OPTS[@]}" -q "${snippet_file}" "root@${PVE_HOST}:$(snippet_path).tmp"
  remote "install -o root -g root -m 0600 \"$(snippet_path).tmp\" \"$(snippet_path)\" && rm -f \"$(snippet_path).tmp\""
  remote "qm set ${SOURCE_VMID} --cicustom user=${SNIPPET_VOLID} >/dev/null && qm cloudinit update ${SOURCE_VMID} >/dev/null"

  owned_cicustom_attached "${SOURCE_VMID}" || die "temporary cicustom was not attached to source VM"
  remote "cat \"$(snippet_path)\"" | grep -qx 'users:' || \
    die "temporary user-data does not contain the users list"
  if remote "cat \"$(snippet_path)\"" | grep -Eq '^user:[[:space:]]'; then
    die "temporary user-data contains deprecated scalar user syntax"
  fi
  printf 'Prepared guarded Packer cloud-init input %s on source VM %s.\n' "${SNIPPET_VOLID}" "${SOURCE_VMID}"
)

cleanup() {
  local vmid current path
  for vmid in "${SOURCE_VMID}" "${TARGET_VMID}"; do
    if ! vm_exists "${vmid}"; then
      continue
    fi
    current="$(vm_config_value "${vmid}" cicustom || true)"
    if [[ -z "${current}" ]]; then
      continue
    fi
    if [[ "${current}" != "user=${SNIPPET_VOLID}" ]]; then
      printf 'Refusing to detach non-owned cicustom from VM %s: %s\n' "${vmid}" "${current}" >&2
      return 1
    fi
    remote "qm set ${vmid} --delete cicustom >/dev/null"
    if [[ "$(remote "qm status ${vmid}" | awk '{print $2}')" == "stopped" ]] && \
      remote "qm config ${vmid}" | grep -qE '^[^:]+: .*cloudinit,media=cdrom'; then
      remote "qm cloudinit update ${vmid} >/dev/null"
    fi
  done

  path="$(snippet_path)"
  remote "if [ -e \"${path}\" ]; then rm -f \"${path}\"; fi"

  for vmid in "${SOURCE_VMID}" "${TARGET_VMID}"; do
    if vm_exists "${vmid}" && owned_cicustom_attached "${vmid}"; then
      die "owned cicustom remains attached to VM ${vmid} after cleanup"
    fi
  done
  if remote "test -e \"${path}\""; then
    die "temporary snippet remains after cleanup: ${path}"
  fi
  printf 'Removed guarded Packer cloud-init input %s.\n' "${SNIPPET_VOLID}"
}

verify() {
  local config
  vm_exists "${SOURCE_VMID}" || die "source VM ${SOURCE_VMID} does not exist"
  vm_exists "${TARGET_VMID}" || die "Packer target VM ${TARGET_VMID} does not exist"

  config="$(remote "qm config ${TARGET_VMID}")"
  grep -qx 'template: 1' <<<"${config}" || die "Packer target ${TARGET_VMID} is not a template"
  for key in cicustom cipassword ciuser nameserver searchdomain sshkeys; do
    if grep -q "^${key}:" <<<"${config}"; then
      die "Packer target ${TARGET_VMID} retains transient ${key} configuration"
    fi
  done
  if grep -qE '^[^:]+: .*cloudinit,media=cdrom' <<<"${config}"; then
    die "Packer target ${TARGET_VMID} retains its transient cloud-init drive"
  fi
  if grep -q '^ipconfig[0-9]\+:' <<<"${config}"; then
    die "Packer target ${TARGET_VMID} retains transient cloud-init network configuration"
  fi
  printf 'Verified clean Packer template VM %s.\n' "${TARGET_VMID}"
}

assert_node
case "${ACTION}" in
  prepare) prepare ;;
  cleanup) cleanup ;;
  verify) verify ;;
esac
