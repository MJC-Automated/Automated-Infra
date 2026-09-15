# Vault Proxmox Access Module

This module manages the optional Vault KV, policy, and AppRole resources used
for Proxmox credentials. Its interface reference is generated from the
Terraform source; run `make docs-terraform` from `terraform-proxmox` after
changing this module.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.10.0 |
| <a name="requirement_vault"></a> [vault](#requirement\_vault) | 5.11.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_vault"></a> [vault](#provider\_vault) | 5.11.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [vault_approle_auth_backend_role.terraform](https://registry.terraform.io/providers/hashicorp/vault/5.11.0/docs/resources/approle_auth_backend_role) | resource |
| [vault_auth_backend.approle](https://registry.terraform.io/providers/hashicorp/vault/5.11.0/docs/resources/auth_backend) | resource |
| [vault_kv_secret_backend_v2.kv_config](https://registry.terraform.io/providers/hashicorp/vault/5.11.0/docs/resources/kv_secret_backend_v2) | resource |
| [vault_mount.kv](https://registry.terraform.io/providers/hashicorp/vault/5.11.0/docs/resources/mount) | resource |
| [vault_policy.proxmox](https://registry.terraform.io/providers/hashicorp/vault/5.11.0/docs/resources/policy) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_approle_bind_secret_id"></a> [approle\_bind\_secret\_id](#input\_approle\_bind\_secret\_id) | Whether AppRole login requires a secret\_id. | `bool` | `true` | no |
| <a name="input_approle_path"></a> [approle\_path](#input\_approle\_path) | Auth path where AppRole backend is enabled. | `string` | `"approle"` | no |
| <a name="input_approle_role_name"></a> [approle\_role\_name](#input\_approle\_role\_name) | AppRole role name for Terraform Proxmox operations. | `string` | `"terraform-proxmox"` | no |
| <a name="input_approle_secret_id_bound_cidrs"></a> [approle\_secret\_id\_bound\_cidrs](#input\_approle\_secret\_id\_bound\_cidrs) | CIDR blocks allowed to use the secret\_id. | `set(string)` | `[]` | no |
| <a name="input_approle_secret_id_num_uses"></a> [approle\_secret\_id\_num\_uses](#input\_approle\_secret\_id\_num\_uses) | Maximum number of times a secret\_id can be used (0 means unlimited). | `number` | `0` | no |
| <a name="input_approle_secret_id_ttl_seconds"></a> [approle\_secret\_id\_ttl\_seconds](#input\_approle\_secret\_id\_ttl\_seconds) | Secret ID TTL in seconds (0 means no expiry). | `number` | `0` | no |
| <a name="input_approle_token_bound_cidrs"></a> [approle\_token\_bound\_cidrs](#input\_approle\_token\_bound\_cidrs) | CIDR blocks allowed to use tokens issued by this AppRole. | `set(string)` | `[]` | no |
| <a name="input_approle_token_no_default_policy"></a> [approle\_token\_no\_default\_policy](#input\_approle\_token\_no\_default\_policy) | If true, tokens do not include Vault default policy. | `bool` | `false` | no |
| <a name="input_approle_token_num_uses"></a> [approle\_token\_num\_uses](#input\_approle\_token\_num\_uses) | Maximum uses for tokens issued by this AppRole (0 means unlimited). | `number` | `0` | no |
| <a name="input_create_kv_mount"></a> [create\_kv\_mount](#input\_create\_kv\_mount) | Whether to create/manage the KV mount resource. | `bool` | `true` | no |
| <a name="input_kv_cas_required"></a> [kv\_cas\_required](#input\_kv\_cas\_required) | Require CAS for writes to KV v2 keys. | `bool` | `true` | no |
| <a name="input_kv_delete_version_after_seconds"></a> [kv\_delete\_version\_after\_seconds](#input\_kv\_delete\_version\_after\_seconds) | Seconds after which secret versions are deleted. | `number` | `2592000` | no |
| <a name="input_kv_max_versions"></a> [kv\_max\_versions](#input\_kv\_max\_versions) | Maximum number of secret versions kept per key. | `number` | `20` | no |
| <a name="input_kv_mount_path"></a> [kv\_mount\_path](#input\_kv\_mount\_path) | KV v2 mount path used for Terraform environment secrets. | `string` | `"secret"` | no |
| <a name="input_policy_name"></a> [policy\_name](#input\_policy\_name) | Vault policy name for Terraform Proxmox credential reads. | `string` | `"terraform-proxmox"` | no |
| <a name="input_secret_prefix"></a> [secret\_prefix](#input\_secret\_prefix) | Prefix under KV v2 mount containing per-environment credential paths. | `string` | `"terraform"` | no |
| <a name="input_token_max_ttl_seconds"></a> [token\_max\_ttl\_seconds](#input\_token\_max\_ttl\_seconds) | Maximum AppRole token TTL in seconds. | `number` | `86400` | no |
| <a name="input_token_ttl_seconds"></a> [token\_ttl\_seconds](#input\_token\_ttl\_seconds) | Default AppRole token TTL in seconds. | `number` | `3600` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_approle_role_id"></a> [approle\_role\_id](#output\_approle\_role\_id) | AppRole role\_id for Terraform Proxmox role. |
| <a name="output_approle_role_name"></a> [approle\_role\_name](#output\_approle\_role\_name) | Managed AppRole role name. |
| <a name="output_kv_mount_path"></a> [kv\_mount\_path](#output\_kv\_mount\_path) | Managed KV v2 mount path. |
| <a name="output_policy_name"></a> [policy\_name](#output\_policy\_name) | Managed Vault policy name. |
<!-- END_TF_DOCS -->
