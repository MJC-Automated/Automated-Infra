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

      case "$DISK" in
        *[0-9]) PART="$${DISK}p1" ;;
        *) PART="$${DISK}1" ;;
      esac

      pvcreate -ff -y "$PART"
      vgcreate "${vg_name}" "$PART"

%{ for m in mounts ~}
      if [ "${m.size_is_auto}" = "true" ]; then
        lvcreate -l 100%FREE -n ${m.lv_name} ${vg_name}
      else
        lvcreate -L ${m.size_gb}G -n ${m.lv_name} ${vg_name}
      fi
      mkfs -t ${fs_type} "/dev/${vg_name}/${m.lv_name}"
      mkdir -p "${m.mount}"
      echo "/dev/${vg_name}/${m.lv_name} ${m.mount} ${fs_type} defaults 0 2" >> /etc/fstab
      chown ${m.owner}:${m.group} "${m.mount}"

%{ endfor ~}
      mount -a
      touch "$MARKER"
