// outputs.tf
// Root module output definitions with enhanced formatting for CI/CD integration

// Comprehensive node summary with structured data
output "all_nodes_summary" {
  description = "A comprehensive summary of all nodes deployed in the environment."
  value = {
    for k, v in module.proxmox_vms : k => {
      vmid                       = v.vmid
      name                       = v.name
      ip                         = v.ipconfig0
      group                      = v.role
      os_profile                 = local.vm_os_profile[k]
      os_family                  = local.vm_profile_data[k].os_family
      ansible_python_interpreter = local.vm_profile_data[k].ansible_python_interpreter
      full_info                  = v.full_object
    }
  }
  sensitive = true
}

// Group-based summaries
output "node_groups_summary" {
  description = "Summary of nodes grouped by their role."
  value = {
    for group, nodes in var.node_groups : group => {
      for k, v in module.proxmox_vms : k => v if v.role == group
    }
  }
  sensitive = true
}

// Simple lists for automation and scripting
output "all_vm_names" {
  description = "Names of all VMs (sorted)."
  value       = local.sorted_vm_names
}

output "all_vm_ids" {
  description = "IDs of all VMs (corresponding to sorted names)."
  value       = [for name in local.sorted_vm_names : local.vm_name_to_id[name]]
}

output "all_vm_ips" {
  description = "ipconfig0 strings of all VMs (corresponding to sorted names)."
  value       = [for name in local.sorted_vm_names : local.vm_name_to_ip[name]]
}

output "all_vm_host_ips" {
  description = "Parsed host IP addresses (without CIDR/gateway) of all VMs (corresponding to sorted names)."
  value = [
    for name in local.sorted_vm_names :
    split("/", split("=", split(",", local.vm_name_to_ip[name])[0])[1])[0]
  ]
}

// File paths for automation tools
output "ansible_inventory_path" {
  description = "The path to the generated Ansible inventory file."
  value       = local_file.ansible_inventory.filename
}

output "deployment_summary_path" {
  description = "The path to the deployment summary JSON file for CI/CD integration."
  value       = local_file.deployment_summary.filename
}

// Environment information for CI/CD
output "environment_info" {
  description = "Structured environment information for CI/CD pipelines."
  value = {
    environment  = local.environment
    workspace    = terraform.workspace
    cluster_name = var.cluster_name
    project      = var.project_name
    owner        = var.owner
    cost_center  = var.cost_center
    tags         = local.common_tags
  }
}

// Infrastructure metrics for monitoring
output "infrastructure_metrics" {
  description = "Infrastructure metrics for monitoring and alerting."
  value = {
    total_vms = length(local.flattened_vms)
    group_counts = {
      for group, nodes in var.node_groups : group => length(nodes)
    }
    total_cpu_cores = sum([
      for vm in local.flattened_vms : vm.config.cores
    ])
    total_memory_gb = (sum([
      for vm in local.flattened_vms : vm.config.memory
    ])) / 1024
  }
}

// Connection information for tools like Ansible
output "connection_info" {
  description = "Connection information for configuration management tools."
  value = {
    inventory_file  = local_file.ansible_inventory.filename
    ssh_user        = var.cloudinit_first_access_user
    ssh_private_key = "~/.ssh/id_rsa"
    // Dynamic IP lists based on groups
    group_ips = {
      for group, nodes in var.node_groups : group => [
        for vm in local.flattened_vms : split("=", split(",", vm.config.ipconfig0)[0])[1] if vm.group == group
      ]
    }
    // Parsed host IP addresses (without CIDR) for direct SSH tooling.
    group_host_ips = {
      for group, nodes in var.node_groups : group => [
        for vm in local.flattened_vms : split("/", split("=", split(",", vm.config.ipconfig0)[0])[1])[0] if vm.group == group
      ]
    }
  }
}

// Workspace and environment information
output "workspace_info" {
  description = "Current workspace and environment information."
  value = {
    current_workspace    = terraform.workspace
    environment          = local.environment
    is_default_workspace = terraform.workspace == "default"
  }
}
