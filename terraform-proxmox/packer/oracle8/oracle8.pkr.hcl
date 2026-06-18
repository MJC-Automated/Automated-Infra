packer {
  required_plugins {
    proxmox = {
      version = "1.2.3"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

variable "proxmox_api_url" {
  type        = string
  description = "Proxmox API URL (e.g., https://proxmox:8006/api2/json)"
}

variable "proxmox_node" {
  type        = string
  description = "Target Proxmox node"
}

variable "proxmox_token" {
  type        = string
  description = "Proxmox API token secret"
  sensitive   = true
}

variable "proxmox_token_id" {
  type        = string
  description = "Proxmox API token ID"
}

variable "proxmox_tls_insecure" {
  type        = bool
  description = "Allow insecure TLS"
  default     = true
}

variable "template_name" {
  type        = string
  default     = "oracle8"
}

variable "vm_id" {
  type        = number
  description = "Proxmox VMID for the template"
  default     = 999999994
}

variable "clone_vm_id" {
  type        = number
  description = "Source VMID to clone (must be powered off)"
  default     = 999999991
}

variable "cpu_cores" {
  type        = number
  description = "vCPU cores for template build VM"
  default     = 8
}

variable "memory_mb" {
  type        = number
  description = "Memory (MB) for template build VM"
  default     = 10240
}

source "proxmox-clone" "oracle8" {
  proxmox_url              = var.proxmox_api_url
  // For token auth, username must be in the form user@realm!tokenid
  username                 = var.proxmox_token_id
  token                    = var.proxmox_token
  insecure_skip_tls_verify = var.proxmox_tls_insecure

  node         = var.proxmox_node
  vm_name      = var.template_name
  vm_id        = var.vm_id
  clone_vm_id  = var.clone_vm_id
  full_clone   = true
  communicator = "none"
  task_timeout = "15m"

  // Match the base VM hardware defaults
  os               = "l26"
  cpu_type         = "host"
  cores            = var.cpu_cores
  sockets          = 1
  memory           = var.memory_mb
  qemu_agent       = true
  scsi_controller  = "virtio-scsi-single"
  boot             = "order=scsi0"

  network_adapters {
    bridge = "vmbr0"
    model  = "virtio"
  }

  serials = ["socket"]
}

build {
  sources = ["source.proxmox-clone.oracle8"]
}
