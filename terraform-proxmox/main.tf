// main.tf
// Root module configuration for Terraform Proxmox infrastructure
// Uses workspace-based environment separation
// Local values for computed configurations and tags
locals {
  environment   = terraform.workspace == "default" ? var.environment_name : terraform.workspace
  inventory_dir = abspath("${path.module}/../inventories/${local.environment}")

  // Keep CreatedAt optional to avoid emitting placeholder values like "unknown".
  creation_timestamp = trimspace(var.build_date)

  common_tags = merge({
    Environment = local.environment
    ManagedBy   = "terraform"
    Project     = var.project_name
    Owner       = var.owner
    CostCenter  = var.cost_center
    CreatedBy   = var.created_by
    Workspace   = terraform.workspace
    }, local.creation_timestamp != "" ? {
    CreatedAt = local.creation_timestamp
  } : {})

  summary_tags = {
    for key in sort(keys(local.common_tags)) : key => local.common_tags[key]
  }

  log_config = {
    file   = "${var.log_file_prefix}-${local.environment}.log"
    level  = var.log_level
    format = "json"
  }

  vault_kv_mount_path_clean    = trim(var.vault_kv_mount_path, "/")
  vault_secret_prefix_clean    = trim(var.vault_secret_prefix, "/")
  vault_workspace_creds_secret = format("%s/%s/creds", local.vault_secret_prefix_clean, terraform.workspace)
  vault_manage_kv_mount_effective = (
    var.vault_manage_kv_mount != null ?
    var.vault_manage_kv_mount :
    true
  )

  all_vm_groups = var.node_groups

  summary_groups = {
    for group_key in sort(keys(local.all_vm_groups)) : group_key => {
      count = length(local.all_vm_groups[group_key])
      vms = {
        for vm_key in sort(keys(local.all_vm_groups[group_key])) : vm_key => {
          vmid = local.all_vm_groups[group_key][vm_key].vmid
          name = local.all_vm_groups[group_key][vm_key].name
        }
      }
    }
  }

  flattened_vms = merge([
    for group_key, group_vms in local.all_vm_groups : {
      for vm_key, vm_config in group_vms : "${group_key}-${vm_key}" => {
        group  = group_key
        key    = vm_key
        config = vm_config
      }
    }
  ]...)

  group_os_profile_inferred = {
    for group_name in keys(local.all_vm_groups) : group_name => (
      can(regex("weblogic[-_]?14", lower(group_name))) ? "oracle9" :
      can(regex("oracle9|ol9", lower(group_name))) ? "oracle9" :
      can(regex("weblogic[-_]?12", lower(group_name))) ? "oracle8" :
      can(regex("oracle8|ol8|database|oracledb|oracle", lower(group_name))) ? "oracle8" :
      var.default_os_profile
    )
  }

  vm_os_profile = {
    for key, vm in local.flattened_vms : key => (
      trimspace(try(vm.config.os_profile, "")) != "" ?
      vm.config.os_profile :
      lookup(var.group_os_profile, vm.group, local.group_os_profile_inferred[vm.group])
    )
  }

  vm_profile_data = {
    for key, profile in local.vm_os_profile :
    key => lookup(var.os_profiles, profile, var.os_profiles[var.default_os_profile])
  }

  vm_disk_storage = {
    for key, vm in local.flattened_vms : key => compact([
      trimspace(try(vm.config.vm_disk_storage, "")),
      var.storage_pool
    ])[0]
  }

  vm_additional_disks = {
    for key, vm in local.flattened_vms : key => (
      length(try(vm.config.additional_disks, [])) > 0 ?
      vm.config.additional_disks :
      (
        (
          try(vm.config.partitioning.enabled, false) ||
          trimspace(try(vm.config.data_disk.size, "")) != "" ||
          trimspace(try(vm.config.data_disk.storage, "")) != "" ||
          trimspace(try(vm.config.data_disk.slot, "")) != ""
        ) && var.data_disk_defaults.enabled
        ) ? [
        {
          storage = compact([
            trimspace(try(vm.config.data_disk.storage, "")),
            trimspace(try(vm.config.vm_disk_storage, "")),
            trimspace(var.data_disk_defaults.storage),
            var.storage_pool
          ])[0]
          size = compact([
            trimspace(try(vm.config.data_disk.size, "")),
            trimspace(var.data_disk_defaults.size)
          ])[0]
          slot = compact([
            trimspace(try(vm.config.data_disk.slot, "")),
            trimspace(var.data_disk_defaults.slot)
          ])[0]
        }
      ] : []
    )
  }

  partitioned_vms = {
    for key, vm in local.flattened_vms : key => vm
    if try(vm.config.partitioning.enabled, false)
  }

  partitioning_snippet_paths = {
    for key, vm in local.partitioned_vms :
    key => "snippets/${local.environment}-${vm.config.vmid}-${vm.config.name}-partitioning.yaml"
  }

  partitioning_cicustom = {
    for key, path in local.partitioning_snippet_paths :
    key => format("vendor=%s:snippets/%s", var.snippet_storage, basename(path))
  }

  vm_cicustom = {
    for key, vm in local.flattened_vms :
    key => (
      trimspace(try(vm.config.cicustom, "")) != "" ? vm.config.cicustom : lookup(local.partitioning_cicustom, key, "")
    )
  }

  vm_name_to_id = {
    for vm in module.proxmox_vms : vm.name => vm.vmid
  }
  vm_name_to_ip = {
    for vm in module.proxmox_vms : vm.name => vm.ipconfig0
  }
  sorted_vm_names = sort(keys(local.vm_name_to_id))

  inventory_header_lines = [
    "# Ansible inventory for ${local.environment}",
    format("# Generated by Terraform on %s", local.creation_timestamp != "" ? local.creation_timestamp : "unspecified"),
    "",
    "# Global Ansible variables",
    "[all:vars]",
    "ansible_user=${var.cloudinit_first_access_user}",
    "ansible_ssh_private_key_file=~/.ssh/id_rsa",
    "ansible_ssh_common_args='-o StrictHostKeyChecking=accept-new -o ControlMaster=auto -o ControlPersist=60s'",
    "ansible_python_interpreter=/usr/bin/python3",
    "ansible_become=yes",
    "ansible_become_method=sudo",
    "ansible_ssh_timeout=30",
    "ansible_gather_timeout=30",
    "",
    "# Environment and cluster metadata",
    "cluster_environment=${local.environment}",
    "cluster_name=${var.cluster_name}",
  ]

  inventory_tag_lines = length(local.common_tags) > 0 ? concat(
    ["# Cluster tags from Terraform"],
    [for key in sort(keys(local.common_tags)) : format("cluster_tag_%s=%s", lower(key), jsonencode(local.common_tags[key]))],
    [""]
  ) : [""]

  inventory_all_nodes_lines = concat(
    ["# All hosts", "[all_nodes]"],
    [
      for vm_key in sort(keys(local.flattened_vms)) : format(
        "%s ansible_host=%s vmid=%s node_role=%s os_profile=%s os_family=%s ansible_python_interpreter=%s cores=%s memory_mb=%s disk_size=%s",
        local.flattened_vms[vm_key].config.name,
        split("/", split("=", split(",", local.flattened_vms[vm_key].config.ipconfig0)[0])[1])[0],
        local.flattened_vms[vm_key].config.vmid,
        local.flattened_vms[vm_key].group,
        local.vm_os_profile[vm_key],
        local.vm_profile_data[vm_key].os_family,
        local.vm_profile_data[vm_key].ansible_python_interpreter,
        local.flattened_vms[vm_key].config.cores,
        local.flattened_vms[vm_key].config.memory,
        local.flattened_vms[vm_key].config.disk_size
      )
    ],
    [""]
  )

  inventory_group_lines = flatten([
    for group_name in sort(keys(local.all_vm_groups)) : concat(
      [format("[%s]", group_name)],
      [for vm_key in sort(keys(local.all_vm_groups[group_name])) : local.all_vm_groups[group_name][vm_key].name],
      [""]
    )
  ])

  inventory_lines = concat(
    local.inventory_header_lines,
    local.inventory_tag_lines,
    local.inventory_all_nodes_lines,
    ["# Dynamic groups based on 'group' property"],
    local.inventory_group_lines
  )
}

provider "vault" {
  address          = var.vault_address
  token            = var.vault_auth_mode == "token" ? var.vault_token : null
  skip_child_token = true

  dynamic "auth_login" {
    for_each = var.vault_auth_mode == "approle" ? [1] : []
    content {
      path = "auth/approle/login"
      parameters = {
        role_id   = var.vault_role_id
        secret_id = var.vault_secret_id
      }
    }
  }
}

provider "vault" {
  alias   = "admin"
  address = var.vault_address
  token   = var.vault_token
}

// Fetch Proxmox credentials from Vault using Ephemeral resource
ephemeral "vault_kv_secret_v2" "proxmox_creds" {
  mount = local.vault_kv_mount_path_clean
  name  = local.vault_workspace_creds_secret
}

provider "proxmox" {
  pm_api_url          = ephemeral.vault_kv_secret_v2.proxmox_creds.data.proxmox_config_api_url
  pm_api_token_id     = ephemeral.vault_kv_secret_v2.proxmox_creds.data.proxmox_config_api_token_id
  pm_api_token_secret = ephemeral.vault_kv_secret_v2.proxmox_creds.data.proxmox_config_api_token_secret
  pm_tls_insecure     = ephemeral.vault_kv_secret_v2.proxmox_creds.data.proxmox_config_tls_insecure
  pm_log_file         = local.log_config.file
  pm_log_levels = {
    _default    = local.log_config.level
    _capturelog = ""
  }
  pm_timeout = var.timeout
}

module "vm_pool" {
  source = "./modules/proxmox-pool"
  count  = var.manage_vm_pool ? 1 : 0

  poolid  = var.vm_pool
  comment = var.vm_pool_comment
}

module "vault_proxmox_access" {
  source = "./modules/vault-proxmox-access"
  count  = var.manage_vault_access ? 1 : 0
  providers = {
    vault = vault.admin
  }

  kv_mount_path                   = local.vault_kv_mount_path_clean
  create_kv_mount                 = local.vault_manage_kv_mount_effective
  secret_prefix                   = local.vault_secret_prefix_clean
  approle_bind_secret_id          = var.vault_approle_bind_secret_id
  approle_secret_id_num_uses      = var.vault_approle_secret_id_num_uses
  approle_secret_id_ttl_seconds   = var.vault_approle_secret_id_ttl_seconds
  approle_secret_id_bound_cidrs   = var.vault_approle_secret_id_bound_cidrs
  approle_token_bound_cidrs       = var.vault_approle_token_bound_cidrs
  approle_token_no_default_policy = var.vault_approle_token_no_default_policy
  approle_token_num_uses          = var.vault_approle_token_num_uses
}

module "proxmox_vms" {
  source = "./modules/proxmox-vm"

  for_each = local.flattened_vms

  vmid         = each.value.config.vmid
  force_create = var.force_create
  name         = each.value.config.name
  ipconfig0    = each.value.config.ipconfig0
  description  = "VM in group ${each.value.group}"
  target_node  = var.target_node
  pool         = var.vm_pool
  clone_template = compact([
    trimspace(try(each.value.config.clone_template, "")),
    trimspace(local.vm_profile_data[each.key].clone_template),
    trimspace(var.clone_template)
  ])[0]
  agent_enabled    = var.vm_defaults.agent_enabled
  os_type          = var.vm_defaults.os_type
  cpu_cores        = each.value.config.cores
  cpu_type         = var.vm_defaults.cpu_type
  memory_mb        = each.value.config.memory
  bios             = var.vm_defaults.bios
  machine          = var.vm_defaults.machine
  scsihw           = var.vm_defaults.scsihw
  boot_order       = var.vm_defaults.boot_order
  boot_disk_device = var.vm_defaults.boot_disk_device
  network_bridge   = var.network_bridge
  network_model    = var.vm_defaults.network_model
  ha_state = (
    trimspace(try(each.value.config.ha_state, "")) != "" ?
    trimspace(each.value.config.ha_state) :
    trimspace(var.vm_defaults.ha_state)
  )
  ha_group = (
    trimspace(try(each.value.config.ha_group, "")) != "" ?
    trimspace(each.value.config.ha_group) :
    trimspace(var.vm_defaults.ha_group)
  )
  vm_state = (
    trimspace(try(each.value.config.vm_state, "")) != "" ?
    trimspace(each.value.config.vm_state) :
    trimspace(var.vm_defaults.vm_state)
  )
  start_at_node_boot = coalesce(try(each.value.config.start_at_node_boot, null), var.vm_defaults.start_at_node_boot)
  protection         = coalesce(try(each.value.config.protection, null), var.vm_defaults.protection)
  balloon            = coalesce(try(each.value.config.balloon, null), var.vm_defaults.balloon)
  cloudinit_storage  = local.vm_disk_storage[each.key]
  bootdisk_storage   = local.vm_disk_storage[each.key]
  bootdisk_size      = each.value.config.disk_size
  role               = each.value.group

  additional_disks                      = local.vm_additional_disks[each.key]
  cicustom                              = local.vm_cicustom[each.key]
  cloudinit_first_access_user           = var.cloudinit_first_access_user
  cloudinit_first_access_ssh_public_key = var.cloudinit_first_access_ssh_public_key

  tags = merge(local.common_tags, {
    Role = each.value.group
    Name = each.value.key
  })

  depends_on = [module.vm_pool]
}

resource "local_file" "partitioning_snippet" {
  for_each = local.partitioned_vms

  filename = local.partitioning_snippet_paths[each.key]
  content = templatefile("${path.module}/templates/cloud-init-partition.yaml.tpl", {
    disk_device = try(each.value.config.partitioning.disk_device, "/dev/vdb")
    vg_name     = try(each.value.config.partitioning.vg_name, "vgdata")
    fs_type     = try(each.value.config.partitioning.fs_type, local.vm_profile_data[each.key].fs_type, "ext4")
    mounts = [
      for m in each.value.config.partitioning.mounts : {
        mount        = m.mount
        size_gb      = tostring(m.size_gb)
        size_is_auto = upper(tostring(m.size_gb)) == "AUTO"
        owner        = try(m.owner, "root")
        group        = try(m.group, "root")
        lv_name      = trim(replace(m.mount, "/", "_"), "_")
      }
    ]
  })
  file_permission = "0600"
}

resource "local_file" "ansible_inventory" {
  content         = join("\n", local.inventory_lines)
  filename        = "${local.inventory_dir}/inventory.ini"
  file_permission = "0600"
}

resource "local_file" "deployment_summary" {
  content = jsonencode({
    environment  = local.environment
    workspace    = terraform.workspace
    cluster_name = var.cluster_name
    deployment_info = merge({
      terraform_version = ">=1.0.0"
      provider_version  = "3.0.2-rc07"
      }, local.creation_timestamp != "" ? {
      timestamp = local.creation_timestamp
    } : {})
    infrastructure = {
      total_vms = length(local.flattened_vms)
      groups    = local.summary_groups
    }
    resource_allocation = {
      total_cpu_cores = sum([
        for vm in local.flattened_vms : vm.config.cores
      ])
      total_memory_gb = sum([
        for vm in local.flattened_vms : vm.config.memory
      ]) / 1024
    }
    network_config = {
      target_node    = var.target_node
      storage_pool   = var.storage_pool
      network_bridge = var.network_bridge
    }
    tags = local.summary_tags
  })
  filename        = "summaries/deployment-summary-${local.environment}.json"
  file_permission = "0644"
}
