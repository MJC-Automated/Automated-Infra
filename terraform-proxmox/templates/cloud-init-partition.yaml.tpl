#cloud-config
runcmd:
  - |
      set -eu
      MARKER="/var/local/partitioning.done"
      if [ -f "$MARKER" ]; then
        exit 0
      fi

      DISK="${disk_device}"
      if [ ! -b "$DISK" ]; then
        echo "Disk $DISK not found" >&2
        exit 1
      fi

      if ! command -v pvcreate >/dev/null 2>&1 || ! command -v parted >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
          apt-get update -y
          apt-get install -y lvm2 parted
        elif command -v dnf >/dev/null 2>&1; then
          dnf install -y lvm2 parted
        elif command -v yum >/dev/null 2>&1; then
          yum install -y lvm2 parted
        else
          echo "No supported package manager found (apt/dnf/yum)" >&2
          exit 1
        fi
      fi

      wipefs -a "$DISK" || true
      parted -s "$DISK" mklabel gpt
      parted -s "$DISK" mkpart primary 0% 100%
      partprobe "$DISK" || true
      udevadm settle || true
      sleep 2

      case "$DISK" in
        *[0-9]) PART="$${DISK}p1" ;;
        *) PART="$${DISK}1" ;;
      esac

      # Wait for partition device to be ready
      for i in $(seq 1 45); do
        if [ -b "$PART" ]; then
          break
        fi
        sleep 1
      done

      if [ ! -b "$PART" ]; then
        echo "ERROR: partition $PART not present after 45s" >&2
        exit 1
      fi

      # Retry pvcreate to avoid race conditions/locks
      pv_created=0
      for attempt in $(seq 1 8); do
        if pvcreate -ff -y "$PART"; then
          pv_created=1
          break
        fi
        echo "pvcreate failed; retrying (attempt $attempt/8)..." >&2
        if command -v dmsetup >/dev/null 2>&1; then
          dmsetup remove_all 2>/dev/null || true
        fi
        sleep 2
        udevadm settle || true
      done

      if [ "$pv_created" -ne 1 ]; then
        echo "FATAL: pvcreate failed after 8 attempts" >&2
        exit 1
      fi

      vgcreate "${vg_name}" "$PART"

%{ for m in mounts ~}
      if [ "${m.size_is_auto}" = "true" ]; then
        lvcreate --yes --wipesignatures y -l 100%FREE -n ${m.lv_name} ${vg_name}
      else
        lvcreate --yes --wipesignatures y -L ${m.size_gb}G -n ${m.lv_name} ${vg_name}
      fi
      LV_PATH="/dev/${vg_name}/${m.lv_name}"
      wipefs -a "$LV_PATH"
      mkfs -t ${fs_type} "$LV_PATH"
      mkdir -p "${m.mount}"
      echo "$LV_PATH ${m.mount} ${fs_type} defaults 0 2" >> /etc/fstab
      chown ${m.owner}:${m.group} "${m.mount}"

%{ endfor ~}
      mount -a
      touch "$MARKER"
