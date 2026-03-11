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
  description = "The full proxmox_vm_qemu object for advanced referencing."
  value       = proxmox_vm_qemu.this
}

output "tags" {
  description = "The tags applied to the VM."
  value       = proxmox_vm_qemu.this.tags
}

output "role" {
  description = "The role of the VM."
  value       = var.role
}
