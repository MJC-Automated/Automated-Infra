# Proxmox VM Module

This module encapsulates a Proxmox QEMU VM and its cloud-init, network, disk,
backup, and lifecycle configuration. Its interface reference is generated from
the Terraform source; run `make docs-terraform` from `terraform-proxmox` after
changing this module.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.10.0 |
| <a name="requirement_proxmox"></a> [proxmox](#requirement\_proxmox) | 3.0.2-rc10 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_proxmox"></a> [proxmox](#provider\_proxmox) | 3.0.2-rc10 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [proxmox_vm_qemu.this](https://registry.terraform.io/providers/Telmate/proxmox/3.0.2-rc10/docs/resources/vm_qemu) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_additional_disks"></a> [additional\_disks](#input\_additional\_disks) | List of additional disks to attach to the VM. | <pre>list(object({<br/>    storage = string<br/>    size    = string<br/>    slot    = string<br/>  }))</pre> | `[]` | no |
| <a name="input_agent_enabled"></a> [agent\_enabled](#input\_agent\_enabled) | Enable QEMU Guest Agent (1 for enabled, 0 for disabled). | `number` | `1` | no |
| <a name="input_agent_timeout"></a> [agent\_timeout](#input\_agent\_timeout) | Timeout in seconds for Proxmox agent operations. | `number` | `200` | no |
| <a name="input_backup_enabled"></a> [backup\_enabled](#input\_backup\_enabled) | Include VM data disks in Proxmox backups. Cloud-init media is always excluded. | `bool` | `false` | no |
| <a name="input_balloon"></a> [balloon](#input\_balloon) | Balloon memory minimum in MB (0 disables dynamic ballooning). | `number` | `0` | no |
| <a name="input_bios"></a> [bios](#input\_bios) | The BIOS type (e.g., 'seabios' or 'ovmf'). | `string` | `"seabios"` | no |
| <a name="input_boot_disk_device"></a> [boot\_disk\_device](#input\_boot\_disk\_device) | The primary boot disk device (e.g., 'scsi0'). | `string` | `"scsi0"` | no |
| <a name="input_boot_order"></a> [boot\_order](#input\_boot\_order) | Boot device order (e.g., 'order=scsi0;net0'). | `string` | `"order=scsi0;net0"` | no |
| <a name="input_bootdisk_size"></a> [bootdisk\_size](#input\_bootdisk\_size) | Size of the primary boot disk (e.g., '20G'). | `string` | n/a | yes |
| <a name="input_bootdisk_storage"></a> [bootdisk\_storage](#input\_bootdisk\_storage) | The storage pool for the primary boot disk. | `string` | n/a | yes |
| <a name="input_cicustom"></a> [cicustom](#input\_cicustom) | Custom cloud-init configuration (e.g., 'vendor=local:snippets/my-config.yaml'). | `string` | `""` | no |
| <a name="input_clone_template"></a> [clone\_template](#input\_clone\_template) | The name of the existing VM template to clone from. | `string` | n/a | yes |
| <a name="input_cloudinit_first_access_ssh_public_key"></a> [cloudinit\_first\_access\_ssh\_public\_key](#input\_cloudinit\_first\_access\_ssh\_public\_key) | Single SSH public key to inject for first access. Leave empty to preserve template-inherited auth. | `string` | `""` | no |
| <a name="input_cloudinit_first_access_user"></a> [cloudinit\_first\_access\_user](#input\_cloudinit\_first\_access\_user) | Cloud-init user for first SSH access when cloudinit\_first\_access\_ssh\_public\_key is set. | `string` | `"ansible"` | no |
| <a name="input_cloudinit_storage"></a> [cloudinit\_storage](#input\_cloudinit\_storage) | The storage pool for the Cloud-Init disk. | `string` | n/a | yes |
| <a name="input_cpu_cores"></a> [cpu\_cores](#input\_cpu\_cores) | Number of CPU cores assigned to the VM. | `number` | `2` | no |
| <a name="input_cpu_numa"></a> [cpu\_numa](#input\_cpu\_numa) | Enable NUMA support. Set to true for dual CPU setups. | `bool` | `false` | no |
| <a name="input_cpu_sockets"></a> [cpu\_sockets](#input\_cpu\_sockets) | Number of CPU sockets assigned to the VM. | `number` | `1` | no |
| <a name="input_cpu_type"></a> [cpu\_type](#input\_cpu\_type) | CPU type to emulate (e.g., 'host' for host's CPU model). | `string` | `"host"` | no |
| <a name="input_cpu_vcores"></a> [cpu\_vcores](#input\_cpu\_vcores) | Number of virtual CPUs (vCPUs) assigned to the VM. 0 uses default. | `number` | `0` | no |
| <a name="input_description"></a> [description](#input\_description) | Description for the VM. | `string` | `"Managed by Terraform"` | no |
| <a name="input_efi_disk_enabled"></a> [efi\_disk\_enabled](#input\_efi\_disk\_enabled) | Create a persistent EFI variables disk when using OVMF. | `bool` | `true` | no |
| <a name="input_efi_disk_format"></a> [efi\_disk\_format](#input\_efi\_disk\_format) | EFI variables disk format. | `string` | `"raw"` | no |
| <a name="input_efi_disk_storage"></a> [efi\_disk\_storage](#input\_efi\_disk\_storage) | Storage pool for the EFI variables disk. Defaults to the boot disk storage when empty. | `string` | `""` | no |
| <a name="input_efi_disk_type"></a> [efi\_disk\_type](#input\_efi\_disk\_type) | EFI variables disk type supported by Proxmox, usually 4m for modern guests. | `string` | `"4m"` | no |
| <a name="input_efi_pre_enrolled_keys"></a> [efi\_pre\_enrolled\_keys](#input\_efi\_pre\_enrolled\_keys) | Whether to pre-enroll Secure Boot keys on the EFI disk. | `bool` | `false` | no |
| <a name="input_force_create"></a> [force\_create](#input\_force\_create) | Set to true to recycle existing VM IDs. | `bool` | `false` | no |
| <a name="input_force_recreate_on_change_of"></a> [force\_recreate\_on\_change\_of](#input\_force\_recreate\_on\_change\_of) | Arbitrary change trigger string that forces VM recreation when changed. | `string` | `""` | no |
| <a name="input_ha_group"></a> [ha\_group](#input\_ha\_group) | High availability group name. Requires ha\_state. | `string` | `""` | no |
| <a name="input_ha_state"></a> [ha\_state](#input\_ha\_state) | High availability state. Leave empty for no HA. | `string` | `""` | no |
| <a name="input_hotplug_devices"></a> [hotplug\_devices](#input\_hotplug\_devices) | Comma-separated list of devices that allow hotplugging (e.g., 'network,disk,usb'). | `string` | `"network,disk,usb"` | no |
| <a name="input_ipconfig0"></a> [ipconfig0](#input\_ipconfig0) | IP configuration string for the first network interface (e.g., 'ip=192.0.2.0/24,gw=198.51.100.22'). | `string` | n/a | yes |
| <a name="input_machine"></a> [machine](#input\_machine) | The machine type (e.g., 'i440fx' or 'q35'). | `string` | `""` | no |
| <a name="input_memory_mb"></a> [memory\_mb](#input\_memory\_mb) | Amount of RAM allocated to the VM in Megabytes. | `number` | `2048` | no |
| <a name="input_name"></a> [name](#input\_name) | The name of the Proxmox QEMU VM. | `string` | n/a | yes |
| <a name="input_nameserver"></a> [nameserver](#input\_nameserver) | DNS nameserver value to pass through cloud-init. | `string` | `""` | no |
| <a name="input_network_bridge"></a> [network\_bridge](#input\_network\_bridge) | The Proxmox network bridge to connect the VM to (e.g., 'vmbr0'). | `string` | n/a | yes |
| <a name="input_network_model"></a> [network\_model](#input\_network\_model) | Network card model (e.g., 'virtio' for high performance). | `string` | `"virtio"` | no |
| <a name="input_network_vlan"></a> [network\_vlan](#input\_network\_vlan) | Optional VLAN tag for the VM's primary NIC. Use 0 to disable VLAN tagging. | `number` | `0` | no |
| <a name="input_os_type"></a> [os\_type](#input\_os\_type) | Guest OS type for Proxmox optimizations (e.g., 'cloud-init'). | `string` | `"cloud-init"` | no |
| <a name="input_pool"></a> [pool](#input\_pool) | The resource pool to which the VM will be added. | `string` | `""` | no |
| <a name="input_power_state"></a> [power\_state](#input\_power\_state) | Desired VM power state. | `string` | `"running"` | no |
| <a name="input_protection"></a> [protection](#input\_protection) | Whether VM deletion protection is enabled in Proxmox. | `bool` | `false` | no |
| <a name="input_role"></a> [role](#input\_role) | The role of the VM, used for grouping and identification. | `string` | `"default"` | no |
| <a name="input_scsihw"></a> [scsihw](#input\_scsihw) | SCSI controller to emulate (e.g., 'virtio-scsi-single'). | `string` | `"virtio-scsi-single"` | no |
| <a name="input_searchdomain"></a> [searchdomain](#input\_searchdomain) | DNS search domain value to pass through cloud-init. | `string` | `""` | no |
| <a name="input_skip_ipv6"></a> [skip\_ipv6](#input\_skip\_ipv6) | Tell the provider not to wait for an IPv6 address from the QEMU guest agent. | `bool` | `false` | no |
| <a name="input_start_at_node_boot"></a> [start\_at\_node\_boot](#input\_start\_at\_node\_boot) | Whether VM should start when the Proxmox node boots. | `bool` | `false` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags to apply to the VM for organization and cost management. | `map(string)` | `{}` | no |
| <a name="input_target_node"></a> [target\_node](#input\_target\_node) | The Proxmox VE node where the VM will be placed. | `string` | n/a | yes |
| <a name="input_vmid"></a> [vmid](#input\_vmid) | The unique VMID for the Proxmox QEMU VM. | `number` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_full_object"></a> [full\_object](#output\_full\_object) | A structured VM summary without exposing deprecated provider attributes. |
| <a name="output_ipconfig0"></a> [ipconfig0](#output\_ipconfig0) | The ipconfig0 configuration string of the created Proxmox QEMU VM. |
| <a name="output_name"></a> [name](#output\_name) | The name of the created Proxmox QEMU VM. |
| <a name="output_role"></a> [role](#output\_role) | The role of the VM. |
| <a name="output_tags"></a> [tags](#output\_tags) | The tags applied to the VM. |
| <a name="output_vmid"></a> [vmid](#output\_vmid) | The VMID of the created Proxmox QEMU VM. |
<!-- END_TF_DOCS -->
