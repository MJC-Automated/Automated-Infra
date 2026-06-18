// modules/proxmox-vm/variables.tf
// Defines input variables for the proxmox-vm module with enhanced tagging support.

// Core VM Identification
variable "vmid" {
  description = "The unique VMID for the Proxmox QEMU VM."
  type        = number
}

variable "force_create" {
  description = "Set to true to recycle existing VM IDs."
  type        = bool
  default     = false
}

variable "name" {
  description = "The name of the Proxmox QEMU VM."
  type        = string
}

// Tagging and Organization
variable "tags" {
  description = "Tags to apply to the VM for organization and cost management."
  type        = map(string)
  default     = {}
}

variable "role" {
  description = "The role of the VM, used for grouping and identification."
  type        = string
  default     = "default"
}

// General VM Settings
variable "description" {
  description = "Description for the VM."
  type        = string
  default     = "Managed by Terraform"
}

variable "target_node" {
  description = "The Proxmox VE node where the VM will be placed."
  type        = string
}

variable "pool" {
  description = "The resource pool to which the VM will be added."
  type        = string
  default     = ""
}

variable "clone_template" {
  description = "The name of the existing VM template to clone from."
  type        = string
}

variable "agent_enabled" {
  description = "Enable QEMU Guest Agent (1 for enabled, 0 for disabled)."
  type        = number
  default     = 1
}

variable "os_type" {
  description = "Guest OS type for Proxmox optimizations (e.g., 'cloud-init')."
  type        = string
  default     = "cloud-init"
}

// CPU and Memory Settings
variable "cpu_cores" {
  description = "Number of CPU cores assigned to the VM."
  type        = number
  default     = 2
}

variable "cpu_sockets" {
  description = "Number of CPU sockets assigned to the VM."
  type        = number
  default     = 1
}

variable "cpu_vcores" {
  description = "Number of virtual CPUs (vCPUs) assigned to the VM. 0 uses default."
  type        = number
  default     = 0
}

variable "cpu_type" {
  description = "CPU type to emulate (e.g., 'host' for host's CPU model)."
  type        = string
  default     = "host"
}

variable "cpu_numa" {
  description = "Enable NUMA support. Set to true for dual CPU setups."
  type        = bool
  default     = false
}

variable "memory_mb" {
  description = "Amount of RAM allocated to the VM in Megabytes."
  type        = number
  default     = 2048
}

// Boot and Virtualization Settings
variable "bios" {
  description = "The BIOS type (e.g., 'seabios' or 'ovmf')."
  type        = string
  default     = "seabios"
}

variable "machine" {
  description = "The machine type (e.g., 'i440fx' or 'q35')."
  type        = string
  default     = ""
}

variable "scsihw" {
  description = "SCSI controller to emulate (e.g., 'virtio-scsi-single')."
  type        = string
  default     = "virtio-scsi-single"
}

variable "boot_order" {
  description = "Boot device order (e.g., 'order=scsi0;net0')."
  type        = string
  default     = "order=scsi0;net0"
}

variable "hotplug_devices" {
  description = "Comma-separated list of devices that allow hotplugging (e.g., 'network,disk,usb')."
  type        = string
  default     = "network,disk,usb"
}

variable "boot_disk_device" {
  description = "The primary boot disk device (e.g., 'scsi0')."
  type        = string
  default     = "scsi0"
}

variable "ha_state" {
  description = "High availability state. Leave empty for no HA."
  type        = string
  default     = ""
  validation {
    condition = (
      trimspace(var.ha_state) == "" ||
      contains(["started", "stopped", "enabled", "disabled", "ignored"], trimspace(var.ha_state))
    )
    error_message = "ha_state must be empty or one of: started, stopped, enabled, disabled, ignored."
  }
}

variable "ha_group" {
  description = "High availability group name. Requires ha_state."
  type        = string
  default     = ""
  validation {
    condition     = trimspace(var.ha_group) == "" || trimspace(var.ha_state) != ""
    error_message = "ha_group requires ha_state."
  }
}

variable "vm_state" {
  description = "Desired VM power state."
  type        = string
  default     = "running"
  validation {
    condition     = contains(["running", "stopped"], trimspace(var.vm_state))
    error_message = "vm_state must be one of: running, stopped."
  }
}

variable "start_at_node_boot" {
  description = "Whether VM should start when the Proxmox node boots."
  type        = bool
  default     = false
}

variable "protection" {
  description = "Whether VM deletion protection is enabled in Proxmox."
  type        = bool
  default     = false
}

variable "balloon" {
  description = "Balloon memory minimum in MB (0 disables dynamic ballooning)."
  type        = number
  default     = 0
}

variable "agent_timeout" {
  description = "Timeout in seconds for Proxmox agent operations."
  type        = number
  default     = 200
}

// Network Settings
variable "network_bridge" {
  description = "The Proxmox network bridge to connect the VM to (e.g., 'vmbr0')."
  type        = string
}

variable "network_model" {
  description = "Network card model (e.g., 'virtio' for high performance)."
  type        = string
  default     = "virtio"
}

// Disk Settings
variable "cloudinit_storage" {
  description = "The storage pool for the Cloud-Init disk."
  type        = string
}

variable "bootdisk_storage" {
  description = "The storage pool for the primary boot disk."
  type        = string
}

variable "bootdisk_size" {
  description = "Size of the primary boot disk (e.g., '20G')."
  type        = string
}

variable "additional_disks" {
  description = "List of additional disks to attach to the VM."
  type = list(object({
    storage = string
    size    = string
    slot    = string
  }))
  default = []
}

variable "ipconfig0" {
  description = "IP configuration string for the first network interface (e.g., 'ip=203.0.113.0/24,gw=198.51.100.16')."
  type        = string
}

variable "cicustom" {
  description = "Custom cloud-init configuration (e.g., 'vendor=local:snippets/my-config.yaml')."
  type        = string
  default     = ""
}

variable "cloudinit_first_access_user" {
  description = "Cloud-init user for first SSH access when cloudinit_first_access_ssh_public_key is set."
  type        = string
  default     = "ansible"
}

variable "cloudinit_first_access_ssh_public_key" {
  description = "Single SSH public key to inject for first access. Leave empty to preserve template-inherited auth."
  type        = string
  default     = ""
}
