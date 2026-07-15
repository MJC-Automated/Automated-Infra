locals {
  kv_mount_path_effective = var.create_kv_mount ? vault_mount.kv[0].path : var.kv_mount_path
}

moved {
  from = vault_mount.kv
  to   = vault_mount.kv[0]
}

resource "vault_mount" "kv" {
  count = var.create_kv_mount ? 1 : 0
  path  = var.kv_mount_path
  type  = "kv"
  options = {
    version = "2"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "vault_kv_secret_backend_v2" "kv_config" {
  mount                = local.kv_mount_path_effective
  max_versions         = var.kv_max_versions
  delete_version_after = var.kv_delete_version_after_seconds
  cas_required         = var.kv_cas_required

  lifecycle {
    prevent_destroy = true
  }
}

resource "vault_policy" "proxmox" {
  name   = var.policy_name
  policy = <<-EOT
path "${var.kv_mount_path}/data/${var.secret_prefix}/*" {
  capabilities = ["create", "update", "read"]
}

path "${var.kv_mount_path}/metadata/${var.secret_prefix}/*" {
  capabilities = ["read", "list"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}
EOT

  lifecycle {
    prevent_destroy = true
  }
}

resource "vault_auth_backend" "approle" {
  type = "approle"
  path = var.approle_path

  lifecycle {
    prevent_destroy = true
  }
}

resource "vault_approle_auth_backend_role" "terraform" {
  backend                 = vault_auth_backend.approle.path
  role_name               = var.approle_role_name
  bind_secret_id          = var.approle_bind_secret_id
  secret_id_num_uses      = var.approle_secret_id_num_uses
  secret_id_ttl           = var.approle_secret_id_ttl_seconds
  secret_id_bound_cidrs   = var.approle_secret_id_bound_cidrs
  token_bound_cidrs       = var.approle_token_bound_cidrs
  token_no_default_policy = var.approle_token_no_default_policy
  token_num_uses          = var.approle_token_num_uses
  token_policies          = [vault_policy.proxmox.name]
  token_ttl               = var.token_ttl_seconds
  token_max_ttl           = var.token_max_ttl_seconds

  lifecycle {
    prevent_destroy = true
  }
}
