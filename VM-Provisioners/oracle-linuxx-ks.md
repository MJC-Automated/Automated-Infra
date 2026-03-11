# Host Facts: ol8-19

## System Overview

* **OS**: Oracle Linux 8 (OL8)
* **Hostname**: ol8.example.internal
* **Installation Method**: Kickstart (anaconda-ks.cfg)
* **Installation Type**: Graphical Server Environment
* **Firewall**: Disabled
* **SELinux**: Disabled
* **Timezone**: Africa/Nairobi

## Hardware Summary

* **Total Disk Size**: 200 GiB (/dev/sda)
* **Memory (RAM)**: 7.5 GiB
* **Swap Space**: 9 GiB

## Disk Layout (fdisk)

| Device    | Size   | Type                     |
| --------- | ------ | ------------------------ |
| /dev/sda1 | 2M     | BIOS boot                |
| /dev/sda2 | 2G     | Linux filesystem (/boot) |
| /dev/sda3 | 200M   | EFI System (/boot/efi)   |
| /dev/sda4 | 197.8G | Linux LVM (vg_root)      |

### LVM Volumes

| Logical Volume | Mount Point | Size   | Filesystem |
| -------------- | ----------- | ------ | ---------- |
| lv_root        | /           | 30 GiB | ext4       |
| lv_var         | /var        | 4 GiB  | ext4       |
| lv_u01         | /u01        | 50 GiB | ext4       |
| lv_u02         | /u02        | 50 GiB | ext4       |
| lv_swap        | swap        | 10 GiB | swap       |

## Filesystem Usage (df -h)

| Mount Point | Size | Used | Avail | Use% | Device                      |
| ----------- | ---- | ---- | ----- | ---- | --------------------------- |
| /           | 30G  | 8.2G | 20G   | 29%  | /dev/mapper/vg_root-lv_root |
| /boot       | 2.0G | 503M | 1.3G  | 28%  | /dev/sda2                   |
| /boot/efi   | 200M | 8.0K | 200M  | 1%   | /dev/sda3                   |
| /u01        | 49G  | 11G  | 37G   | 22%  | /dev/mapper/vg_root-lv_u01  |
| /u02        | 49G  | 26G  | 21G   | 55%  | /dev/mapper/vg_root-lv_u02  |
| /var        | 3.9G | 2.1G | 1.6G  | 57%  | /dev/mapper/vg_root-lv_var  |

## Memory Usage (free -hg)

| Type | Total   | Used    | Free    | Buff/Cache | Available |
| ---- | ------- | ------- | ------- | ---------- | --------- |
| RAM  | 7.5 GiB | 456 MiB | 3.5 GiB | 3.6 GiB    | 6.9 GiB   |
| Swap | 9 GiB   | 0 B     | 9 GiB   | -          | -         |

## Network Configuration

| Setting       | Value         |
| ------------- | ------------- |
| Device        | enp6s18       |
| Boot Protocol | Static        |
| IP Address    | 198.51.100.10 |
| Netmask       | 198.51.100.11 |
| Gateway       | 198.51.100.12   |
| DNS           | 198.51.100.13       |

## Installed Package Groups

* Graphical Server Environment
* Base
* Compatibility Libraries
* Development Tools
* Directory Client
* Fonts
* Graphical Admin Tools
* Input Methods
* Internet Browser
* Large Systems
* System Admin Tools
* X11
* Additional packages: `gcc`, `kernel-devel`, `kernel-headers`, `kexec-tools`

## Kickstart Notes

* Uses local CD-ROM repo: `/run/install/sources/mount-0000-cdrom/AppStream`
* Clears all partitions and initializes GPT label
* Configures LVM with `vg_root`
* Auto reboot after installation

****
