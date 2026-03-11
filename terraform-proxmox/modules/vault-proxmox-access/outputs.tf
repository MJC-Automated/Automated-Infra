output "kv_mount_path" {
  description = "Managed KV v2 mount path."
  value       = var.kv_mount_path
}

output "policy_name" {
  description = "Managed Vault policy name."
  value       = vault_policy.proxmox.name
}

output "approle_role_name" {
  description = "Managed AppRole role name."
  value       = vault_approle_auth_backend_role.terraform.role_name
}

output "approle_role_id" {
  description = "AppRole role_id for Terraform Proxmox role."
  value       = vault_approle_auth_backend_role.terraform.role_id
  sensitive   = true
}
