# Proxmox Pool Module

This module manages the optional Proxmox VM resource pool used by the root
configuration. Its interface reference is generated from the Terraform source;
run `make docs-terraform` from `terraform-proxmox` after changing this module.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.10.0 |
| <a name="requirement_proxmox"></a> [proxmox](#requirement\_proxmox) | 3.0.2-rc10 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_proxmox"></a> [proxmox](#provider\_proxmox) | 3.0.2-rc10 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [proxmox_pool.this](https://registry.terraform.io/providers/Telmate/proxmox/3.0.2-rc10/docs/resources/pool) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_comment"></a> [comment](#input\_comment) | Pool comment. | `string` | `"Managed by Terraform"` | no |
| <a name="input_poolid"></a> [poolid](#input\_poolid) | Pool identifier. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_poolid"></a> [poolid](#output\_poolid) | Managed pool identifier. |
<!-- END_TF_DOCS -->
