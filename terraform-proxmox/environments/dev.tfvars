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
vault_approle_secret_id_bound_cidrs   = ["192.0.2.0/24", "127.0.0.1"]
vault_approle_token_bound_cidrs       = ["192.0.2.0/24", "127.0.0.1"]
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
      ipconfig0 = "ip=192.0.2.0/24,gw=198.51.100.27"
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
      data_disk = { size = "60G" }
      partitioning = {
        enabled     = true
        disk_device = "/dev/vda"
        vg_name     = "vgdata"
        mounts = [
          { mount = "/u01", size_gb = "30", owner = "root", group = "root" },
          { mount = "/Logs", size_gb = "10", owner = "root", group = "root" },
          { mount = "/Applications", size_gb = "10", owner = "root", group = "root" },
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
      ipconfig0 = "ip=203.0.113.0/24,gw=198.51.100.27"
      cores     = 8
      memory    = 10240
      disk_size = "50G"
      tags      = "weblogic12c"
      data_disk = { size = "55G" }
      partitioning = {
        enabled     = true
        disk_device = "/dev/vda"
        vg_name     = "vgdata"
        mounts = [
          { mount = "/u01", size_gb = "30", owner = "root", group = "root" },
          { mount = "/Logs", size_gb = "10", owner = "root", group = "root" },
          { mount = "/Applications", size_gb = "6", owner = "root", group = "root" },
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
      ipconfig0 = "ip=198.51.100.0/24,gw=198.51.100.27"
      cores     = 8
      memory    = 10240
      disk_size = "50G"
      tags      = "database19c"
      data_disk = { size = "65G" }
      partitioning = {
        enabled     = true
        disk_device = "/dev/vda"
        vg_name     = "vgdata"
        mounts = [
          { mount = "/u01", size_gb = "30", owner = "root", group = "root" },
          { mount = "/u02", size_gb = "AUTO", owner = "root", group = "root" }
        ]
      }
    }
  }

  // Oracle Linux 8: Database 21c
  "database21c" = {
    "database21c-dot83" = {
      vmid      = 10003
      name      = "public-database21c-02"
      ipconfig0 = "ip=192.0.2.0/24,gw=198.51.100.27"
      cores     = 8
      memory    = 10240
      disk_size = "50G"
      tags      = "database21c"
      data_disk = { size = "65G" }
      partitioning = {
        enabled     = true
        disk_device = "/dev/vda"
        vg_name     = "vgdata"
        mounts = [
          { mount = "/u01", size_gb = "30", owner = "root", group = "root" },
          { mount = "/u02", size_gb = "AUTO", owner = "root", group = "root" }
        ]
      }
    }
  }

  // Ubuntu 24.04: Zabbix
  "zabbix" = {
    "zabbix-dot84" = {
      vmid      = 10004
      name      = "public-zabbix-01"
      ipconfig0 = "ip=198.51.100.0/24,gw=198.51.100.92"
      cores     = 8
      memory    = 10240
      disk_size = "50G"
      tags      = "zabbix"
      data_disk = { size = "8G" }
      partitioning = {
        enabled     = true
        disk_device = "/dev/vda"
        vg_name     = "vgdata"
        mounts = [
          { mount = "/zabbix", size_gb = "6", owner = "root", group = "root" },
        ]
      }
    }
  }

  // Oracle Linux 9: FreeIPA
  "freeipa" = {
    "freeipa-dot85" = {
      vmid       = 10005
      name       = "public-freeipa-01"
      ipconfig0  = "ip=203.0.113.0/24,gw=198.51.100.92"
      os_profile = "oracle9"
      cores      = 4
      memory     = 8192
      disk_size  = "50G"
      tags       = "freeipa"
      data_disk  = { size = "30G" }
      partitioning = {
        enabled     = true
        disk_device = "/dev/vda"
        vg_name     = "vgdata"
        mounts = [
          { mount = "/var/lib/dirsrv", size_gb = "10", owner = "root", group = "root" },
          { mount = "/var/lib/ipa", size_gb = "10", owner = "root", group = "root" },
          { mount = "/var/log", size_gb = "AUTO", owner = "root", group = "root" }
        ]
      }
    }
  }

  // Ubuntu 24.04: Keycloak
  "keycloak" = {
    "keycloak-dot86" = {
      vmid       = 10006
      name       = "public-keycloak-01"
      ipconfig0  = "ip=192.0.2.0/24,gw=198.51.100.92"
      os_profile = "ubuntu2404"
      cores      = 4
      memory     = 8192
      disk_size  = "50G"
      tags       = "keycloak,sso"
      data_disk  = { size = "20G" }
      partitioning = {
        enabled     = true
        disk_device = "/dev/vda"
        vg_name     = "vgdata"
        mounts = [
          { mount = "/opt/keycloak", size_gb = "6", owner = "root", group = "root" },
          { mount = "/var/lib/postgresql", size_gb = "6", owner = "root", group = "root" },
          { mount = "/var/log/keycloak", size_gb = "AUTO", owner = "root", group = "root" }
        ]
      }
    }
  }

  // Ubuntu 24.04: Unified observability core (Prometheus, Loki, Grafana)
  "observability" = {
    "observability-dot87" = {
      vmid       = 10007
      name       = "public-observability-01"
      ipconfig0  = "ip=198.51.100.0/24,gw=198.51.100.92"
      os_profile = "ubuntu2404"
      cores      = 6
      memory     = 16384
      disk_size  = "50G"
      tags       = "observability,monitoring"
      data_disk  = { size = "30G" }
      partitioning = {
        enabled     = true
        disk_device = "/dev/vda"
        vg_name     = "vgdata"
        mounts = [
          { mount = "/var/lib/prometheus", size_gb = "8", owner = "root", group = "root" },
          { mount = "/var/lib/loki", size_gb = "8", owner = "root", group = "root" },
          { mount = "/var/lib/grafana", size_gb = "8", owner = "root", group = "root" },
          { mount = "/var/log/observability", size_gb = "AUTO", owner = "root", group = "root" }
        ]
      }
    }
  }

  // Oracle Linux 9: Zimbra Collaboration Suite
  "zimbra" = {
    "zimbra-dot88" = {
      vmid       = 10008
      name       = "public-zimbra-01"
      ipconfig0  = "ip=203.0.113.0/24,gw=198.51.100.92"
      os_profile = "oracle9"
      cores      = 6
      memory     = 16384
      disk_size  = "50G"
      tags       = "zimbra,mail"
      data_disk  = { size = "15G" }
      partitioning = {
        enabled     = true
        disk_device = "/dev/vda"
        vg_name     = "vgdata"
        mounts = [
          { mount = "/zimbra", size_gb = "AUTO", owner = "root", group = "root" },
        ]
      }
    }
  }

  // =========================================================================
  // Kubernetes Cluster (Kubespray-managed)
  // 1 control-plane/etcd + 2 worker nodes on Ubuntu 24.04
  // Deploy with: cd /home/kirui/kubespray && ansible-playbook \
  //   -i inventory/dev-k8s/inventory.ini --become -u ansible cluster.yml
  // =========================================================================

  // Kubernetes: Control Plane + etcd
  "k8s_control_plane" = {
    "public-cp-01" = {
      vmid       = 10010
      name       = "public-k8s-cp-02"
      ipconfig0  = "ip=192.0.2.0/24,gw=198.51.100.92"
      os_profile = "ubuntu2404"
      cores      = 4
      memory     = 4096
      disk_size  = "50G"
      tags       = "kubernetes,k8s,control-plane,etcd"
    }
  }

  // Example: Unstacked etcd Topology
  // For production, you may want to run etcd on dedicated nodes.
  // "k8s_etcd" = {
  //   "public-etcd-01" = {
  //     vmid       = 10013
  //     name       = "public-k8s-etcd-01"
  //     ipconfig0  = "ip=198.51.100.0/24,gw=198.51.100.92"
  //     os_profile = "ubuntu2404"
  //     cores      = 2
  //     memory     = 4096
  //     disk_size  = "50G"
  //     tags       = "kubernetes,k8s,etcd"
  //   }
  // }

  // Kubernetes: Worker Nodes
  "k8s_workers" = {
    "public-worker-01" = {
      vmid       = 10011
      name       = "public-k8s-worker-03"
      ipconfig0  = "ip=203.0.113.0/24,gw=198.51.100.92"
      os_profile = "ubuntu2404"
      cores      = 2
      memory     = 4096
      disk_size  = "50G"
      tags       = "kubernetes,k8s,worker"
    }
    "public-worker-02" = {
      vmid       = 10012
      name       = "public-k8s-worker-04"
      ipconfig0  = "ip=192.0.2.0/24,gw=198.51.100.92"
      os_profile = "ubuntu2404"
      cores      = 2
      memory     = 4096
      disk_size  = "50G"
      tags       = "kubernetes,k8s,worker"
    }
  }
}
