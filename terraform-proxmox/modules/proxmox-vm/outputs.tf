// modules/proxmox-vm/outputs.tf
// Defines output values for the proxmox-vm module.

output "vmid" {
  description = "The VMID of the created Proxmox QEMU VM."
  value       = proxmox_vm_qemu.this.vmid
}

output "name" {
  description = "The name of the created Proxmox QEMU VM."
  value       = proxmox_vm_qemu.this.name
}

output "ipconfig0" {
  description = "The ipconfig0 configuration string of the created Proxmox QEMU VM."
  value       = proxmox_vm_qemu.this.ipconfig0
}

output "full_object" {
  description = "A structured VM summary without exposing deprecated provider attributes."
  value = {
    vmid                        = proxmox_vm_qemu.this.vmid
    name                        = proxmox_vm_qemu.this.name
    ipconfig0                   = proxmox_vm_qemu.this.ipconfig0
    tags                        = proxmox_vm_qemu.this.tags
    role                        = var.role
    description                 = var.description
    target_node                 = var.target_node
    pool                        = var.pool
    clone_template              = var.clone_template
    agent_enabled               = var.agent_enabled
    os_type                     = var.os_type
    cpu_cores                   = var.cpu_cores
    cpu_sockets                 = var.cpu_sockets
    cpu_vcores                  = var.cpu_vcores
    cpu_type                    = var.cpu_type
    cpu_numa                    = var.cpu_numa
    memory_mb                   = var.memory_mb
    bios                        = var.bios
    machine                     = var.machine
    scsihw                      = var.scsihw
    boot_order                  = var.boot_order
    hotplug_devices             = var.hotplug_devices
    boot_disk_device            = var.boot_disk_device
    ha_state                    = var.ha_state
    ha_group                    = var.ha_group
    vm_state                    = var.vm_state
    start_at_node_boot          = var.start_at_node_boot
    protection                  = var.protection
    balloon                     = var.balloon
    agent_timeout               = var.agent_timeout
    network_bridge              = var.network_bridge
    network_model               = var.network_model
    cloudinit_storage           = var.cloudinit_storage
    bootdisk_storage            = var.bootdisk_storage
    bootdisk_size               = var.bootdisk_size
    additional_disks            = var.additional_disks
    cicustom                    = var.cicustom
    cloudinit_first_access_user = var.cloudinit_first_access_user
  }
}

output "tags" {
  description = "The tags applied to the VM."
  value       = proxmox_vm_qemu.this.tags
}

output "role" {
  description = "The role of the VM."
  value       = var.role
}
