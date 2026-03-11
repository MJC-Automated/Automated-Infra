#!/usr/bin/env bash
set -Eeuo pipefail

section() {
  echo
  echo "== $1 =="
}

run() {
  "$@" 2>/dev/null || true
}

section "Host"
run hostnamectl --static
if ! hostnamectl --static >/dev/null 2>&1; then
  hostname
fi

section "OS Info"
if [ -r /etc/os-release ]; then
  cat /etc/os-release
else
  echo "/etc/os-release not found"
fi

section "Kernel"
uname -a

section "Uptime"
run uptime

section "Block Devices"
if lsblk -o NAME,MAJ:MIN,RM,SIZE,RO,TYPE,MOUNTPOINTS,FSTYPE >/dev/null 2>&1; then
  lsblk -o NAME,MAJ:MIN,RM,SIZE,RO,TYPE,MOUNTPOINTS,FSTYPE
elif lsblk -o NAME,MAJ:MIN,RM,SIZE,RO,TYPE,MOUNTPOINT,FSTYPE >/dev/null 2>&1; then
  lsblk -o NAME,MAJ:MIN,RM,SIZE,RO,TYPE,MOUNTPOINT,FSTYPE
else
  lsblk
fi

section "Filesystems"
df -hT

section "LVM Summary"
if command -v pvs >/dev/null 2>&1; then
  pvs || true
  vgs || true
  lvs || true
else
  echo "LVM commands not found"
fi

section "blkid"
run blkid

section "FSTAB Entries (non-comment)"
if [ -r /etc/fstab ]; then
  grep -vE '^[[:space:]]*#|^[[:space:]]*$' /etc/fstab || true
else
  echo "/etc/fstab not found"
fi

section "Mount Verification"
if [ -r /etc/fstab ]; then
  mapfile -t fstab_mounts < <(awk '
    $1 !~ /^#/ && $2 != "none" && $3 != "swap" && $2 != "" {print $2}
  ' /etc/fstab)

  if [ "${#fstab_mounts[@]}" -eq 0 ]; then
    echo "No data mounts detected in /etc/fstab"
  else
    for mnt in "${fstab_mounts[@]}"; do
      if [ ! -d "$mnt" ]; then
        echo "MISSING_DIR $mnt"
        continue
      fi
      if command -v mountpoint >/dev/null 2>&1; then
        if mountpoint -q "$mnt"; then
          echo "MOUNTED $mnt"
        else
          echo "NOT_MOUNTED $mnt"
        fi
      else
        if findmnt -rn "$mnt" >/dev/null 2>&1; then
          echo "MOUNTED $mnt"
        else
          echo "NOT_MOUNTED $mnt"
        fi
      fi
    done
  fi
else
  echo "/etc/fstab not found"
fi

section "Marker File"
if [ -f /var/local/partitioning.done ]; then
  echo "partitioning marker present: /var/local/partitioning.done"
else
  echo "partitioning marker missing: /var/local/partitioning.done"
fi

section "Summary"
echo "Done. Review any NOT_MOUNTED/MISSING_DIR results above."
