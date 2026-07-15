// modules/proxmox-vm/main.tf
// Defines a single Proxmox QEMU Virtual Machine resource.
// This module is designed to be reusable for any VM deployment.

locals {
  // Proxmox tags support a restricted character set. Normalize key/value pairs
  // to stable, lowercase tags so UI, API, and Terraform output stay aligned.
  proxmox_tag_key_values = [
    for key in sort(keys(var.tags)) : substr(
      trim(
        join("-", compact([
          lower(replace(replace(trimspace(key), "/[^0-9A-Za-z_.-]/", "-"), "/-{2,}/", "-")),
          lower(replace(replace(trimspace(lookup(var.tags, key, "")), "/[^0-9A-Za-z_.-]/", "-"), "/-{2,}/", "-"))
        ])),
        "-."
      ),
      0,
      63
    )
  ]

  proxmox_tags = join(";", distinct([
    for tag in local.proxmox_tag_key_values : tag
    if tag != ""
  ]))

  efi_disk_storage = trimspace(var.efi_disk_storage) != "" ? trimspace(var.efi_disk_storage) : var.bootdisk_storage
}

resource "proxmox_vm_qemu" "this" {
  // VMID is a required input for stability and idempotency.
  vmid = var.vmid

  // Force creation if VM already exists with this ID
  force_create     = var.force_create
  automatic_reboot = true
  // VM name, also a required input.
  name = var.name

  // General VM settings, passed as variables to allow customization.
  description = var.description
  target_node = var.target_node
  pool        = var.pool
  clone       = var.clone_template
  agent       = var.agent_enabled
  os_type     = var.os_type
  force_recreate_on_change_of = (
    trimspace(var.force_recreate_on_change_of) != "" ?
    var.force_recreate_on_change_of :
    null
  )
  // Use a lifecycle block to ignore changes to the 'name' attribute after creation
  // if Proxmox automatically appends something (e.g., "-clone") to the name.
  // This helps prevent unnecessary Terraform plans.
  lifecycle {
    ignore_changes = [
      name,
      pool,
      bootdisk
    ]
  }

  // CPU settings, configurable via variables.
  cpu {
    cores   = var.cpu_cores
    sockets = var.cpu_sockets
    vcores  = var.cpu_vcores
    type    = var.cpu_type
    numa    = var.cpu_numa
  }
  memory = var.memory_mb

  // Boot and virtualization settings.
  bios               = var.bios
  machine            = var.machine
  scsihw             = var.scsihw
  boot               = var.boot_order
  hotplug            = var.hotplug_devices
  bootdisk           = var.boot_disk_device
  hastate            = trimspace(var.ha_state) != "" ? trimspace(var.ha_state) : null
  hagroup            = trimspace(var.ha_group) != "" ? trimspace(var.ha_group) : null
  power_state        = var.power_state
  start_at_node_boot = var.start_at_node_boot
  protection         = var.protection
  balloon            = var.balloon
  agent_timeout      = var.agent_timeout

  dynamic "efidisk" {
    for_each = lower(trimspace(var.bios)) == "ovmf" && var.efi_disk_enabled ? [1] : []
    content {
      storage           = local.efi_disk_storage
      efitype           = var.efi_disk_type
      format            = var.efi_disk_format
      pre_enrolled_keys = var.efi_pre_enrolled_keys
    }
  }

  // Convert map of tags to a semicolon-separated key-value tag string.
  tags = local.proxmox_tags

  // Match Proxmox defaults to avoid perpetual startup/shutdown drift.
  startup_shutdown {
    order            = -1
    startup_delay    = -1
    shutdown_timeout = -1
  }

  // Network configuration.
  network {
    id     = 0 // Default network interface ID
    model  = var.network_model
    bridge = var.network_bridge
  }

  // IP configuration for the first network interface.
  ipconfig0    = var.ipconfig0
  nameserver   = trimspace(var.nameserver) != "" ? trimspace(var.nameserver) : null
  searchdomain = trimspace(var.searchdomain) != "" ? trimspace(var.searchdomain) : null
  skip_ipv6    = var.skip_ipv6

  // Custom Cloud-Init Configuration
  cicustom = var.cicustom
  ciuser   = trimspace(var.cloudinit_first_access_ssh_public_key) != "" ? var.cloudinit_first_access_user : null
  sshkeys  = trimspace(var.cloudinit_first_access_ssh_public_key) != "" ? trimspace(var.cloudinit_first_access_ssh_public_key) : null

  // Primary / Boot drive for the VM.
  disk {
    type    = "disk"
    storage = var.bootdisk_storage
    size    = var.bootdisk_size
    backup  = var.backup_enabled
    slot    = var.boot_disk_device
    // Add 'discard=on' for better performance.
    discard = "true"
    format  = "raw"
  }

  // Cloud-Init Disk configuration.
  // This disk is essential for passing initial configuration (like IP, hostname) to the VM.
  disk {
    type    = "cloudinit"
    storage = var.cloudinit_storage
    backup  = false // Cloud-init disk typically doesn't need backup
    slot    = "scsi1"
    // Add 'discard=on' for better performance with SSD/NVMe storage,
    // allowing the guest OS to reclaim unused blocks. Avoid this if using disk.type=cloudinit
    discard = "false"
  }

  // Dynamic block for additional disks
  dynamic "disk" {
    for_each = var.additional_disks
    content {
      type    = "disk"
      storage = disk.value.storage
      size    = disk.value.size
      slot    = disk.value.slot
      backup  = var.backup_enabled
      discard = "true"
      format  = "raw"
    }
  }

  // Serial Console for debugging and initial setup.
  serial {
    id   = 0
    type = "socket"
  }
}
