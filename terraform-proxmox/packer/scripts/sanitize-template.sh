#!/usr/bin/env bash
set -euo pipefail

if ! command -v cloud-init >/dev/null 2>&1; then
  echo "cloud-init is required to sanitize reusable templates" >&2
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

if [[ -d /var/lib/dbus ]]; then
  rm -f /var/lib/dbus/machine-id
  ln -s /etc/machine-id /var/lib/dbus/machine-id
fi

sync
