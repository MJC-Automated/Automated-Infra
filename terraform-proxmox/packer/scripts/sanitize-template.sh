#!/usr/bin/env bash
set -euo pipefail

if ! command -v cloud-init >/dev/null 2>&1; then
  echo "cloud-init is required to sanitize reusable templates" >&2
  exit 1
fi

# Wait for cloud-init (including background OS updates / runcmd) before wiping
# instance state. Bound the wait so a stuck package refresh cannot hang Packer;
# a timeout or failed wait must fail the provisioner so we do not snapshot a
# half-initialized guest.
CLOUD_INIT_WAIT_TIMEOUT_SEC="${CLOUD_INIT_WAIT_TIMEOUT_SEC:-900}"
wait_cloud_init() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "${CLOUD_INIT_WAIT_TIMEOUT_SEC}" cloud-init status --wait
  else
    cloud-init status --wait
  fi
}

wait_rc=0
wait_cloud_init || wait_rc=$?
if [[ "${wait_rc}" -ne 0 ]]; then
  echo "cloud-init wait exited ${wait_rc} before clean acceptance; refusing to sanitize" >&2
  cloud-init status --long || true
  exit 1
fi

status_line="$(cloud-init status 2>/dev/null || true)"
if ! grep -Eq 'status:[[:space:]]*done' <<<"${status_line}"; then
  echo "cloud-init status is not done after wait: ${status_line:-unknown}" >&2
  exit 1
fi

# Remove per-instance state and force systemd to allocate a fresh identity to
# every clone on first boot.
cloud-init clean --logs --machine-id

machine_id="$(tr -d '[:space:]' </etc/machine-id 2>/dev/null || true)"
if [[ -n "${machine_id}" && "${machine_id}" != "uninitialized" ]]; then
  echo "template machine-id was not reset: ${machine_id}" >&2
  exit 1
fi

# Oracle images may lack /var/lib/dbus until dbus is installed; create it when
# needed so the machine-id symlink cannot fail the sanitize provisioner.
mkdir -p /var/lib/dbus
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id

sync
