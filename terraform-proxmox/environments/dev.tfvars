// environments/dev.tfvars
// Example environment for Oracle 8/9 and Ubuntu 24.04 workloads.

// Environment and Project Configuration
environment_name = "dev"
cluster_name     = "public-stack"
project_name     = "automated-infra"
owner            = "platform-team"
cost_center      = "engineering"

// Logging Configuration
log_file_prefix = "terraform-plugin-proxmox"
log_level       = "info"

// Proxmox Configuration
target_node    = "proxmox-node"
vm_pool        = "terraform"
manage_vm_pool = false
// Optional comment used only when manage_vm_pool=true.
vm_pool_comment = "Managed by Terraform"
// If enabling pool management for an existing pool, import first:
// terraform import 'module.vm_pool[0].proxmox_pool.this' terraform
clone_template = "ubuntu2404" // Fallback template (per-group OS profile overrides this)
// Keep OS/root disks on template storage; data disks can live elsewhere.
storage_pool    = "shared-storage"
snippet_storage = "local"
network_bridge  = "vmbr0"
timeout         = 300
force_create    = true

// Vault authentication mode and Vault governance module toggle.
// Keep token mode when manage_vault_access=true so governance operations use an admin-capable token.
vault_auth_mode     = "token"
manage_vault_access = true
vault_kv_mount_path = "secret"
vault_secret_prefix = "terraform"
// Optional: set false when reusing an existing KV mount managed outside Terraform.
// vault_manage_kv_mount = false

// AppRole example (for day-to-day secret reads, switch auth mode and typically disable governance management):
// vault_auth_mode = "approle"
// manage_vault_access = false
// vault_role_id   = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
// vault_secret_id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
//
// Enable Vault governance module (creates mount/policy/approle defaults):
// manage_vault_access = true
//
// Optional AppRole hardening examples:
vault_approle_secret_id_num_uses      = 0
vault_approle_secret_id_ttl_seconds   = 86400
vault_approle_secret_id_bound_cidrs   = ["198.51.100.0/24", "127.0.0.1"]
vault_approle_token_bound_cidrs       = ["198.51.100.0/24", "127.0.0.1"]
vault_approle_token_no_default_policy = true

// Optional multi-key template (uncomment and replace values if needed):
cloudinit_first_access_user           = "ansible"
cloudinit_first_access_ssh_public_key = <<-EOKEYS
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGeneratedForPublicDocs sanitized@example.invalid
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGeneratedForPublicDocs sanitized@example.invalid
EOKEYS

// Data disk defaults (used when per-VM data_disk only sets size)
data_disk_defaults = {
  enabled = true
  storage = "local-lvm"
  size    = "50G"
  slot    = "virtio1"
}

// VM Default Configuration
vm_defaults = {
  agent_enabled = 1
  os_type       = "cloud-init"
  cpu_type      = "host"
  network_model = "virtio"

  // HA/power/protection defaults for all VMs (optional):
  // ha_state           = ""
  // ha_group           = ""
  // vm_state           = "running"
  // start_at_node_boot = false
  // protection         = false
  // balloon            = 0
}

// Node Groups Configuration
node_groups = {
  // Oracle Linux 9: WebLogic 14c
  "weblogic14c" = {
    "weblogic14c-dot80" = {
      vmid      = 10000
      name      = "public-weblogic14c-01"
      ipconfig0 = "ip=203.0.113.0/24,gw=198.51.100.20"
      cores     = 8
      memory    = 10240
      disk_size = "50G"
      // Optional: place this VM's root/cloud-init disks on a different VM-disk pool.
      // vm_disk_storage = "local-zfs"
      // Optional HA/power/protection per-VM overrides:
      // ha_state           = "started"
      // ha_group           = "platform-ha"
      // vm_state           = "running"
      // start_at_node_boot = true
      // protection         = true
      // balloon            = 8192
      tags      = "weblogic14c"
      data_disk = { size = "200G" }
      partitioning = {
        enabled     = true
        disk_device = "/dev/vda"
        vg_name     = "vgdata"
        mounts = [
          { mount = "/u01", size_gb = "100", owner = "root", group = "root" },
          { mount = "/Logs", size_gb = "10", owner = "root", group = "root" },
          { mount = "/Applications", size_gb = "50", owner = "root", group = "root" },
          { mount = "/u02", size_gb = "AUTO", owner = "root", group = "root" }
        ]
      }
    }
  }

  // Oracle Linux 8: WebLogic 12c
  "weblogic12c" = {
    "weblogic12c-dot81" = {
      vmid      = 10001
      name      = "public-weblogic12c-01"
      ipconfig0 = "ip=192.0.2.0/24,gw=198.51.100.20"
      cores     = 8
      memory    = 10240
      disk_size = "50G"
      tags      = "weblogic12c"
      data_disk = { size = "200G" }
      partitioning = {
        enabled     = true
        disk_device = "/dev/vda"
        vg_name     = "vgdata"
        mounts = [
          { mount = "/u01", size_gb = "100", owner = "root", group = "root" },
          { mount = "/Logs", size_gb = "10", owner = "root", group = "root" },
          { mount = "/Applications", size_gb = "50", owner = "root", group = "root" },
          { mount = "/u02", size_gb = "AUTO", owner = "root", group = "root" }
        ]
      }
    }
  }

  // Oracle Linux 8: Database 19c
  "database19c" = {
    "database19c-dot82" = {
      vmid      = 10002
      name      = "public-database19c-01"
      ipconfig0 = "ip=192.0.2.0/24,gw=198.51.100.20"
      cores     = 8
      memory    = 10240
      disk_size = "50G"
      tags      = "database19c"
      data_disk = { size = "200G" }
      partitioning = {
        enabled     = true
        disk_device = "/dev/vda"
        vg_name     = "vgdata"
        mounts = [
          { mount = "/u01", size_gb = "100", owner = "root", group = "root" },
          { mount = "/u02", size_gb = "AUTO", owner = "root", group = "root" }
        ]
      }
    }
  }

  // Oracle Linux 8: Database 21c
  "database21c" = {
    "database21c-dot83" = {
      vmid      = 10003
      name      = "public-database21c-03"
      ipconfig0 = "ip=198.51.100.0/24,gw=198.51.100.20"
      cores     = 8
      memory    = 10240
      disk_size = "50G"
      tags      = "database21c"
      data_disk = { size = "200G" }
      partitioning = {
        enabled     = true
        disk_device = "/dev/vda"
        vg_name     = "vgdata"
        mounts = [
          { mount = "/u01", size_gb = "100", owner = "root", group = "root" },
          { mount = "/u02", size_gb = "AUTO", owner = "root", group = "root" }
        ]
      }
    }
  }

  // Ubuntu 24.04: Jenkins
  "jenkins" = {
    "jenkins-dot84" = {
      vmid      = 10004
      name      = "public-jenkins-02"
      ipconfig0 = "ip=203.0.113.0/24,gw=198.51.100.20"
      cores     = 8
      memory    = 10240
      disk_size = "50G"
      tags      = "jenkins"
      data_disk = { size = "300G" }
      partitioning = {
        enabled     = true
        disk_device = "/dev/vda"
        vg_name     = "vgdata"
        mounts = [
          { mount = "/versionControl", size_gb = "100", owner = "root", group = "root" },
          { mount = "/Logs", size_gb = "100", owner = "root", group = "root" },
          { mount = "/u01", size_gb = "AUTO", owner = "root", group = "root" }
        ]
      }
    }
  }
}
