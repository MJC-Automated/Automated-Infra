// variables.tf
// Root module variable definitions for Terraform Proxmox infrastructure

// Environment Identification
variable "environment_name" {
  description = "The name of the environment (for example: dev, testing, prod, qa)."
  type        = string
  default     = "dev"
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*$", var.environment_name))
    error_message = "Environment must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "cluster_name" {
  description = "A unique name for the cluster or stack in this environment."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.cluster_name))
    error_message = "Cluster name must contain only lowercase letters, numbers, and hyphens."
  }
}

// Tagging and Organization
variable "project_name" {
  description = "Name of the project for tagging and organization."
  type        = string
  default     = "ha-cluster"
}

variable "owner" {
  description = "Owner of the resources for tagging and organization."
  type        = string
  default     = "platform-team"
}

variable "cost_center" {
  description = "Cost center for resource allocation and billing."
  type        = string
  default     = "engineering"
}

variable "created_by" {
  description = "Tag for the creator of the resources."
  type        = string
  default     = "terraform-proxmox"
}

variable "build_date" {
  description = "Date of the build to ensure reproducibility (format: YYYY-MM-DD)."
  type        = string
  default     = ""
}

// OS Profile Configuration
variable "default_os_profile" {
  description = "Default OS profile to use when no group mapping or per-VM override is provided."
  type        = string
  default     = "ubuntu2404"
  validation {
    condition     = contains(keys(var.os_profiles), var.default_os_profile)
    error_message = "default_os_profile must be a key in os_profiles."
  }
}

variable "os_profiles" {
  description = "Map of OS profiles to template, filesystem defaults, and Ansible hints."
  type = map(object({
    clone_template             = string
    fs_type                    = string
    os_family                  = string
    ansible_python_interpreter = string
  }))
  default = {
    oracle8 = {
      clone_template             = "oracle8"
      fs_type                    = "xfs"
      os_family                  = "oracle"
      ansible_python_interpreter = "/usr/bin/python3"
    }
    oracle9 = {
      clone_template             = "oracle9"
      fs_type                    = "xfs"
      os_family                  = "oracle"
      ansible_python_interpreter = "/usr/bin/python3"
    }
    ubuntu2404 = {
      clone_template             = "ubuntu2404"
      fs_type                    = "ext4"
      os_family                  = "ubuntu"
      ansible_python_interpreter = "/usr/bin/python3"
    }
  }
}

variable "group_os_profile" {
  description = "Map of node group names to OS profile keys. Used for auto-selecting templates and filesystem defaults."
  type        = map(string)
  default = {
    database19c     = "oracle8"
    database19c_ol9 = "oracle9"
    database21c     = "oracle8"
    weblogic12c     = "oracle8"
    weblogic14c     = "oracle9"
    cicd            = "ubuntu2404"
    jenkins         = "ubuntu2404"
    zimbra          = "oracle9"
  }
  validation {
    condition     = alltrue([for v in values(var.group_os_profile) : contains(keys(var.os_profiles), v)])
    error_message = "All group_os_profile values must be keys in os_profiles."
  }
}

variable "data_disk_defaults" {
  description = "Defaults for the data disk used by partitioning when no additional_disks are provided."
  type = object({
    enabled = bool
    storage = string
    size    = string
    slot    = string
  })
  default = {
    enabled = true
    storage = ""
    size    = "50G"
    slot    = "virtio1"
  }
}

// Logging Configuration
variable "log_file_prefix" {
  description = "Prefix for log file naming."
  type        = string
  default     = "terraform-plugin-proxmox"
}

variable "log_level" {
  description = "Logging level for Terraform provider operations."
  type        = string
  default     = "info"
  validation {
    condition     = contains(["debug", "info", "warn", "error"], var.log_level)
    error_message = "Log level must be one of: debug, info, warn, error."
  }
}


// VM Default Configuration
variable "vm_defaults" {
  description = "Default configuration values for VMs across all node types."
  type = object({
    agent_enabled      = optional(number, 1)
    os_type            = optional(string, "cloud-init")
    cpu_type           = optional(string, "host")
    network_model      = optional(string, "virtio")
    scsihw             = optional(string, "virtio-scsi-single")
    boot_order         = optional(string, "order=scsi0;net0")
    boot_disk_device   = optional(string, "scsi0")
    bios               = optional(string, "ovmf")
    machine            = optional(string, "q35")
    ha_state           = optional(string, "")
    ha_group           = optional(string, "")
    vm_state           = optional(string, "running")
    start_at_node_boot = optional(bool, false)
    protection         = optional(bool, false)
    balloon            = optional(number, 0)
  })
  default = {}
  validation {
    condition     = contains(["running", "stopped"], trimspace(var.vm_defaults.vm_state))
    error_message = "vm_defaults.vm_state must be one of: running, stopped."
  }
}

variable "cloudinit_first_access_user" {
  description = "Cloud-init user for first SSH access when cloudinit_first_access_ssh_public_key is set."
  type        = string
  default     = "ansible"
  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]*[$]?$", var.cloudinit_first_access_user))
    error_message = "cloudinit_first_access_user must be a valid Linux username."
  }
}

variable "cloudinit_first_access_ssh_public_key" {
  description = "One or more SSH public keys (newline-separated) to inject for first access on cloned VMs. Leave empty to preserve template-inherited auth."
  type        = string
  default     = ""
  validation {
    condition = (
      trimspace(var.cloudinit_first_access_ssh_public_key) == "" ||
      alltrue([
        for key_line in split("\n", replace(trimspace(var.cloudinit_first_access_ssh_public_key), "\r", "")) :
        can(regex("^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521))\\s+\\S+(\\s+.*)?$", trimspace(key_line)))
      ])
    )
    error_message = "cloudinit_first_access_ssh_public_key must be empty or contain valid SSH public key line(s), one per line."
  }
}

// Node Groups Configuration
variable "node_groups" {
  description = "A map of node groups to provision (e.g., 'oracledb', 'weblogic', 'cicd', 'k8s'), value is a map of VM configurations."
  type = map(map(object({
    vmid               = number
    name               = string
    ipconfig0          = string
    cores              = number
    memory             = number // in MB
    disk_size          = string // e.g., "50G"
    vm_disk_storage    = optional(string, "")
    tags               = optional(string, "")
    clone_template     = optional(string, "")
    os_profile         = optional(string, "")
    ha_state           = optional(string, "")
    ha_group           = optional(string, "")
    vm_state           = optional(string, "")
    start_at_node_boot = optional(bool)
    protection         = optional(bool)
    balloon            = optional(number)
    data_disk = optional(object({
      size    = string
      storage = optional(string, "")
      slot    = optional(string, "")
    }), null)
    additional_disks = optional(list(object({
      storage = string
      size    = string
      slot    = string
    })), [])
    cicustom = optional(string, "")
    partitioning = optional(object({
      enabled     = optional(bool, true)
      disk_device = optional(string, "/dev/vdb")
      vg_name     = optional(string, "vgdata")
      fs_type     = optional(string, "ext4")
      mounts = list(object({
        mount   = string
        size_gb = string
        owner   = optional(string, "root")
        group   = optional(string, "root")
      }))
    }), null)
  })))
  default = {}

  validation {
    condition     = length(var.node_groups) > 0
    error_message = "At least one node group must be defined."
  }
  validation {
    condition = alltrue(flatten([
      for _, group in var.node_groups : [
        for _, vm in group : (
          try(vm.partitioning.enabled, false) ? (
            length(try(vm.additional_disks, [])) > 0 ||
            try(vm.data_disk.size, null) != null ||
            try(vm.data_disk.storage, null) != null ||
            try(vm.data_disk.slot, null) != null ||
            var.data_disk_defaults.enabled
          ) : true
        )
      ]
    ]))
    error_message = "partitioning.enabled requires additional_disks or data_disk (or enable data_disk_defaults)."
  }
  validation {
    condition = alltrue(flatten([
      for _, group in var.node_groups : [
        for _, vm in group : (
          try(vm.partitioning.enabled, false) ? length(try(vm.partitioning.mounts, [])) > 0 : true
        )
      ]
    ]))
    error_message = "partitioning.enabled requires at least one mount definition."
  }
  validation {
    condition = alltrue(flatten([
      for _, group in var.node_groups : [
        for _, vm in group : (
          trimspace(try(vm.vm_disk_storage, "")) == "" ||
          can(regex("^[A-Za-z0-9._-]+$", trimspace(vm.vm_disk_storage)))
        )
      ]
    ]))
    error_message = "node_groups.*.*.vm_disk_storage must be empty or a valid Proxmox storage name (letters, numbers, dot, underscore, hyphen)."
  }
  validation {
    condition = alltrue(flatten([
      for _, group in var.node_groups : [
        for _, vm in group : (
          try(vm.partitioning.enabled, false) ? trimspace(try(vm.cicustom, "")) == "" : true
        )
      ]
    ]))
    error_message = "partitioning.enabled cannot be combined with cicustom; the generated snippet uses cicustom."
  }
  validation {
    condition = alltrue(flatten([
      for _, group in var.node_groups : [
        for _, vm in group : (
          trimspace(try(vm.vm_state, "")) == "" ||
          contains(["running", "stopped"], trimspace(vm.vm_state))
        )
      ]
    ]))
    error_message = "node_groups.*.*.vm_state must be empty, running, or stopped."
  }
  validation {
    condition = alltrue(flatten([
      for _, group in var.node_groups : [
        for _, vm in group : (
          trimspace(try(vm.ha_group, "")) == "" ||
          trimspace(try(vm.ha_state, "")) != "" ||
          trimspace(var.vm_defaults.ha_state) != ""
        )
      ]
    ]))
    error_message = "node_groups.*.*.ha_group requires ha_state either per-VM or via vm_defaults.ha_state."
  }
}

// Vault Configuration
variable "vault_address" {
  description = "The address of the Vault server."
  type        = string
  sensitive   = true
}

variable "vault_token" {
  description = "The token to authenticate with Vault."
  type        = string
  default     = null
  sensitive   = true
  nullable    = true
  validation {
    condition = (
      (var.vault_auth_mode != "token" && !var.manage_vault_access) ||
      (var.vault_token != null && trimspace(var.vault_token) != "")
    )
    error_message = "vault_token must be set when vault_auth_mode is 'token' or manage_vault_access is true."
  }
}

variable "vault_auth_mode" {
  description = "Vault provider authentication mode: token or approle."
  type        = string
  default     = "token"
  validation {
    condition     = contains(["token", "approle"], var.vault_auth_mode)
    error_message = "vault_auth_mode must be 'token' or 'approle'."
  }
}

variable "vault_role_id" {
  description = "Vault AppRole role_id used when vault_auth_mode=approle."
  type        = string
  default     = null
  sensitive   = true
  nullable    = true
  validation {
    condition = (
      var.vault_auth_mode != "approle" ||
      var.manage_vault_access ||
      (var.vault_role_id != null && trimspace(var.vault_role_id) != "")
    )
    error_message = "vault_role_id must be set when vault_auth_mode is 'approle' unless manage_vault_access is true (bootstrap mode)."
  }
}

variable "vault_secret_id" {
  description = "Vault AppRole secret_id used when vault_auth_mode=approle."
  type        = string
  default     = null
  sensitive   = true
  nullable    = true
  validation {
    condition = (
      var.vault_auth_mode != "approle" ||
      var.manage_vault_access ||
      (var.vault_secret_id != null && trimspace(var.vault_secret_id) != "")
    )
    error_message = "vault_secret_id must be set when vault_auth_mode is 'approle' unless manage_vault_access is true (bootstrap mode)."
  }
}

variable "manage_vault_access" {
  description = "Whether Terraform should manage Vault mount/policy/approle resources."
  type        = bool
  default     = false
}

variable "vault_kv_mount_path" {
  description = "Vault KV v2 mount path used for Proxmox credentials."
  type        = string
  default     = "secret"
  validation {
    condition     = trim(var.vault_kv_mount_path, "/") != ""
    error_message = "vault_kv_mount_path must not be empty."
  }
}

variable "vault_secret_prefix" {
  description = "Prefix under the KV mount where per-workspace Proxmox credentials are stored."
  type        = string
  default     = "terraform"
  validation {
    condition     = trim(var.vault_secret_prefix, "/") != ""
    error_message = "vault_secret_prefix must not be empty."
  }
}

variable "vault_manage_kv_mount" {
  description = "Whether Vault governance should create/manage the KV mount resource. Null defaults to true."
  type        = bool
  default     = null
  nullable    = true
}

variable "vault_approle_bind_secret_id" {
  description = "Whether AppRole login requires secret_id."
  type        = bool
  default     = true
}

variable "vault_approle_secret_id_num_uses" {
  description = "Maximum uses per AppRole secret_id (0 means unlimited)."
  type        = number
  default     = 0
  validation {
    condition     = var.vault_approle_secret_id_num_uses >= 0
    error_message = "vault_approle_secret_id_num_uses must be >= 0."
  }
}

variable "vault_approle_secret_id_ttl_seconds" {
  description = "TTL for AppRole secret_id in seconds (0 means no expiry)."
  type        = number
  default     = 0
  validation {
    condition     = var.vault_approle_secret_id_ttl_seconds >= 0
    error_message = "vault_approle_secret_id_ttl_seconds must be >= 0."
  }
}

variable "vault_approle_secret_id_bound_cidrs" {
  description = "Allowed CIDR blocks for AppRole secret_id usage."
  type        = set(string)
  default     = []
}

variable "vault_approle_token_bound_cidrs" {
  description = "Allowed CIDR blocks for tokens issued by AppRole."
  type        = set(string)
  default     = []
}

variable "vault_approle_token_no_default_policy" {
  description = "Whether to omit Vault default policy from AppRole-issued tokens."
  type        = bool
  default     = false
}

variable "vault_approle_token_num_uses" {
  description = "Maximum uses for AppRole-issued tokens (0 means unlimited)."
  type        = number
  default     = 0
  validation {
    condition     = var.vault_approle_token_num_uses >= 0
    error_message = "vault_approle_token_num_uses must be >= 0."
  }
}

// Proxmox Configuration Variables
variable "target_node" {
  description = "The Proxmox node where VMs will be deployed."
  type        = string
}

variable "vm_pool" {
  description = "The Proxmox resource pool for the VMs."
  type        = string
}

variable "manage_vm_pool" {
  description = "Whether Terraform should manage the Proxmox VM pool resource."
  type        = bool
  default     = false
}

variable "vm_pool_comment" {
  description = "Comment for managed Proxmox VM pool."
  type        = string
  default     = "Managed by Terraform"
}

variable "clone_template" {
  description = "The name of the Proxmox VM template to clone."
  type        = string
}

variable "storage_pool" {
  description = "The Proxmox storage pool for VM disks and cloud-init."
  type        = string
}

variable "snippet_storage" {
  description = "The Proxmox storage that exposes snippets content for cicustom cloud-init data."
  type        = string
  default     = "local"
}

variable "network_bridge" {
  description = "The Proxmox network bridge to attach VMs to."
  type        = string
}

variable "timeout" {
  description = "Timeout for Proxmox API operations in seconds."
  type        = number
  default     = 300
}

variable "force_create" {
  description = "Whether to force creation of VMs even if the VMID is already in use."
  type        = bool
  default     = false
}
