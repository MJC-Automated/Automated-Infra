# Proxmox Infrastructure Automation Platform

An operator guide for the Proxmox VE Terraform, Packer, cloud-init, and Vault
workflow in this repository. Start with a scenario below; the numbered
reference chapters remain available for first-time platform setup and recovery.

## Overview

This platform provisions and manages VM infrastructure on Proxmox VE. It is optimized for node-group patterns (database, weblogic, CI/CD, Kubernetes, etc.) and generates a shared Ansible inventory for each environment.

Key capabilities:

- Generic node groups with per-group or per-VM overrides.
- Vault-backed secrets for Proxmox API credentials.
- Multi-environment support via Terraform workspaces.
- Packer template build path for Ubuntu 24.04, Oracle Linux 8, and Oracle Linux 9.
- Checksum-verified cloud-image sync helper for Ubuntu 22.04, Ubuntu 24.04, Debian 12, Oracle Linux 8/9, Rocky Linux 9, AlmaLinux 9, and Fedora 43.
- Automatic cloud-init snippets for data-disk partitioning.
- Environment-scoped PVE backup schedules, archive verification, and a
  stopped-VM restore drill.

## Start With the Outcome

Run commands from this directory. Replace `<env>` with the Terraform workspace
and `ENVIRONMENT` name (for example, `example`). Use explicit
`ENVIRONMENT=<env>` in automation; a missing value otherwise follows the
selected workspace and falls back to `dev`.

| I want to… | Start here | What it does | Before you run it |
| --- | --- | --- | --- |
| Check an existing environment | `make fmt validate ENVIRONMENT=<env>` | Formats and validates the Terraform configuration. | This is local validation; use `make plan` to inspect real changes. |
| Preview infrastructure changes | `make plan ENVIRONMENT=<env>` | Selects the workspace and writes `plans/<env>.tfplan`. | Confirm the workspace, tfvars, Vault auth, and PVE endpoint agree. |
| Apply a reviewed change | `make apply ENVIRONMENT=<env>` | Renders/uploads snippets, plans, applies, then generates inventory. | Review the plan first. |
| Provision a new environment | `make env-bootstrap ENVIRONMENT=<env> ...` | Scaffolds inputs, prepares SSH/Vault, base VM(s), Packer templates, snippets, and stops at a plan. | Review generated files and the plan before applying. |
| Rebuild the reusable image substrate | `make env-base-vms …` then `make packer-build-* …` | Recreates source base VMs and turns them into cloneable templates. | This can replace reserved base/template VMIDs. |
| Refresh only a Packer template | `make packer-build-ubuntu2404 ENVIRONMENT=<env>` | Builds one template from its prepared base VM. | Ensure the matching base VM is healthy and stopped. |
| Reconcile PVE backups | `make backup-jobs ENVIRONMENT=<env> CONFIRM=YES` | Creates or updates policy-owned PVE schedules. | Run the `DRY_RUN=true` form first. |
| Verify or drill recovery | `make verify-backups …` / `make restore-drill …` | Checks archive freshness or restores one archive into a stopped reserved VM. | A restore drill requires `CONFIRM=YES`; see the recovery section. |
| Retire workload VMs | `make destroy-workloads ENVIRONMENT=<env>` | Backs up state then destroys workload resources while retaining Vault governance. | Requires two interactive confirmation phrases. |

### Safe Day-to-Day Loop

```bash
cd terraform-proxmox
make fmt validate ENVIRONMENT=example
make plan ENVIRONMENT=example
# Review plans/example.tfplan and the generated plan log.
make apply ENVIRONMENT=example
ansible-inventory -i ../inventories/example/inventory.ini -i ../inventories/aliases.ini --graph
```

`apply` owns the snippet render/upload sequence. Do not run raw `terraform
apply` as a substitute when a change can affect generated partitioning or
first-access cloud-init inputs.

### New Environment: Stop at a Reviewable Plan

```bash
make env-template \
  ENVIRONMENT=qa \
  TEMPLATE_ENV=dev \
  PROXMOX_HOST=<pve-address> \
  PROXMOX_NODE=<pve-node> \
  AUTO_DISCOVER=true

# Review environments/qa.tfvars, environments/qa.bootstrap.env, and packer vars.
make env-bootstrap ENVIRONMENT=qa
make apply ENVIRONMENT=qa
```

`env-bootstrap` is intentionally a *plan-first* workflow. It creates the
required substrate and finishes with `make plan`; it does not apply unless you
choose `env-bootstrap-apply`.

### Rebuild Base VMs and Templates

The base-VM path is destructive to its reserved VMIDs. It reads the existing
root-only remote PVE environment file (`/root/scripts/.env` by default) and
does not copy it to `/tmp`. Explicit Make values override that remote file.

```bash
# Ubuntu 24.04 plus Oracle Linux 8/9 source VMs. This replaces the reserved
# base VMIDs when BASE_VM_FORCE=1 (the default).
make env-base-vms ENVIRONMENT=example BASE_VM_BUILD_ORACLE=true \
  BASE_VM_IPCIDR=198.51.100.0/24 BASE_VM_GATEWAY=198.51.100.18

# Build the matching templates only after the bases are accepted.
make packer-build-all ENVIRONMENT=example
```

`BASE_VM_IPCIDR` can be `dhcp` (the default) or a static IPv4 CIDR. Set
`BASE_VM_DNS`, storage values, `BASE_VM_CORES`, and `BASE_VM_MEM` explicitly
when the target differs from the generated bootstrap defaults. Packer bases
must keep `BASE_VM_DO_OS_UPDATE=0`; base acceptance requires a final stopped
VM with bootstrap `cicustom` state removed and `ciupgrade=0`.

### VLAN-Aware Environments

Set `NETWORK_VLAN` to an integer from `1` through `4094` to tag the primary
NICs of both generated base VMs and Terraform-managed workloads. `0` is the
default and leaves NICs untagged. The scaffold writes `network_vlan = <id>` to
the environment tfvars and `BASE_VM_VLAN=<id>` to its bootstrap file; Make
forwards the latter as `NETWORK_VLAN` to the remote base builder.

```bash
make env-template ENVIRONMENT=qa TEMPLATE_ENV=dev \
  PROXMOX_HOST=<pve-address> PROXMOX_NODE=<pve-node> \
  NETWORK_BRIDGE=vmbr0 NETWORK_VLAN=120 AUTO_DISCOVER=true

# Existing environment/base refresh.
make env-base-vms ENVIRONMENT=example BASE_VM_BUILD_ORACLE=true \
  BASE_VM_VLAN=120 BASE_VM_IPCIDR=198.51.100.0/24 \
  BASE_VM_GATEWAY=198.51.100.18
```

Terraform rejects decimal, negative, and out-of-range values; the builder also
validates its received value. The Proxmox bridge must be VLAN-aware and
upstream switching must carry the tag—this repository intentionally does not
configure either of those site-network prerequisites.

## Quick Start Summary

1. Install Vault, Terraform, and Packer.
2. Set up Vault and store Proxmox API credentials.
3. Create base VMs on Proxmox using reserved VMIDs (`999999990+`).
4. Build Packer templates.
5. Generate/edit environment config from the committed `dev` seed (`make env-template ENVIRONMENT=<env> ...` then review `environments/<env>.tfvars`).
6. Render and upload cloud-init snippets.
7. Run `make deploy ENVIRONMENT=<env>`.

The detailed steps below are intended to be followed top to bottom.

For a scenario-oriented entry point, use [Start With the Outcome](#start-with-the-outcome).

## Table of Contents

- [Overview](#overview)
- [Start With the Outcome](#start-with-the-outcome)
- [Quick Start Summary](#quick-start-summary)
- [Prerequisites](#prerequisites)
- [1. Install Vault Terraform and Packer](#1-install-vault-terraform-and-packer)
- [2. Self-Managed Vault Server TLS and Raft](#2-self-managed-vault-server-tls-and-raft)
- [3. Configure Terraform and Vault Environment](#3-configure-terraform-and-vault-environment)
- [3.1 Recreate Env After make clean-all (dev defaults)](#31-recreate-env-after-make-clean-all-dev-defaults)
- [3.2 Obtain Required Secret and Env Values](#32-obtain-required-secret-and-env-values)
- [3.3 Workspace and ENVIRONMENT Defaults](#33-workspace-and-environment-defaults)
- [3.4 Switch Vault Access Mode (loopback or LAN)](#34-switch-vault-access-mode-loopback-or-lan)
- [3.5 Disaster Recovery Reinit (lost unseal key)](#35-disaster-recovery-reinit-lost-unseal-key)
- [3.6 Post-clean-all Recovery Runbook](#36-post-clean-all-recovery-runbook)
- [4. Create Proxmox API Credentials in Vault](#4-create-proxmox-api-credentials-in-vault)
- [5. Prepare Base VMs for Packer](#5-prepare-base-vms-for-packer)
- [6. Configure Packer Variables](#6-configure-packer-variables)
- [7. Build Packer Templates](#7-build-packer-templates)
- [8. Configure Terraform Environment](#8-configure-terraform-environment)
- [9. Render and Upload Partitioning Snippets](#9-render-and-upload-partitioning-snippets)
- [10. Deploy Infrastructure](#10-deploy-infrastructure)
- [11. Verify Partitioning on VMs](#11-verify-partitioning-on-vms)
- [12. Onboard a New Environment](#12-onboard-a-new-environment)
- [12.1 Auto-Discover Core Settings and Generate Template](#121-auto-discover-core-settings-and-generate-template)
- [12.2 Review and Edit Before Provisioning](#122-review-and-edit-before-provisioning)
- [12.3 Bootstrap End-to-End Until Plan](#123-bootstrap-end-to-end-until-plan)
- [12.4 Apply](#124-apply)
- [Generated Terraform Module Reference](#generated-terraform-module-reference)
- [Architecture and Concepts](#architecture-and-concepts)
- [Makefile Targets (Common)](#makefile-targets-common)
- [Repo Hygiene](#repo-hygiene)
- [Troubleshooting](#troubleshooting)
- [Support and Maintenance](#support-and-maintenance)

## Prerequisites

- Proxmox VE 8+ with API access enabled.
- SSH access to the Proxmox node as root (for snippet upload and API user creation).
- Vault server (self-managed recommended).
- Local tools: Terraform 1.10+, Packer, Vault CLI, TFLint, tfsec, SSH/SCP.
- Optional: `jq` for parsing `vault-init.json`.
- Know your Proxmox node name (example: `proxmox` or `proxmox-node`) and storage pools.

### Provider Compatibility

Terraform configuration pins Telmate Proxmox to `3.0.2-rc10` in the root
module and both Proxmox child modules, alongside Vault `5.11.0` and Local
`2.9.0`. The tested controller baseline is Terraform `1.16.1`. Run
`terraform init -backend=false` and `terraform validate` after a provider
change before using an environment plan. The Telmate provider is
community-signed; verify the provider source and signing key reported by
Terraform during initialization.

The local verification baseline is TFLint `0.64.0`, tfsec `1.28.14`, and
terraform-docs `0.24.0`. `make setup-tools` discovers the latest helper
releases when it installs them; run `make check-tools` to verify the active
toolchain before planning changes.

## Generated Terraform Module Reference

This reference is generated from Terraform source. Regenerate it after an
interface, provider, resource, input, or output change with
`make docs-terraform` from this directory. CI verifies that the generated
content is current.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.10.0 |
| <a name="requirement_local"></a> [local](#requirement\_local) | 2.9.0 |
| <a name="requirement_proxmox"></a> [proxmox](#requirement\_proxmox) | 3.0.2-rc10 |
| <a name="requirement_vault"></a> [vault](#requirement\_vault) | 5.11.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_local"></a> [local](#provider\_local) | 2.9.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_proxmox_vms"></a> [proxmox\_vms](#module\_proxmox\_vms) | ./modules/proxmox-vm | n/a |
| <a name="module_vault_proxmox_access"></a> [vault\_proxmox\_access](#module\_vault\_proxmox\_access) | ./modules/vault-proxmox-access | n/a |
| <a name="module_vm_pool"></a> [vm\_pool](#module\_vm\_pool) | ./modules/proxmox-pool | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [local_file.ansible_inventory](https://registry.terraform.io/providers/hashicorp/local/2.9.0/docs/resources/file) | resource |
| [local_file.cloudinit_first_access_snippet](https://registry.terraform.io/providers/hashicorp/local/2.9.0/docs/resources/file) | resource |
| [local_file.deployment_summary](https://registry.terraform.io/providers/hashicorp/local/2.9.0/docs/resources/file) | resource |
| [local_file.partitioning_snippet](https://registry.terraform.io/providers/hashicorp/local/2.9.0/docs/resources/file) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_backup_defaults"></a> [backup\_defaults](#input\_backup\_defaults) | Default Proxmox VM backup policy. Per-VM backup and backup\_storage values override these settings. | <pre>object({<br/>    enabled              = optional(bool, false)<br/>    storage              = optional(string, "")<br/>    schedule             = optional(string, "03:30")<br/>    mode                 = optional(string, "snapshot")<br/>    compress             = optional(string, "zstd")<br/>    bandwidth_limit_kib  = optional(number, 51200)<br/>    ionice               = optional(number, 8)<br/>    repeat_missed        = optional(bool, false)<br/>    notification_mode    = optional(string, "notification-system")<br/>    max_backup_age_hours = optional(number, 36)<br/>    retention = optional(object({<br/>      keep_last    = optional(number, 2)<br/>      keep_daily   = optional(number, 3)<br/>      keep_weekly  = optional(number, 2)<br/>      keep_monthly = optional(number, 1)<br/>      keep_yearly  = optional(number, 0)<br/>    }), {})<br/>  })</pre> | `{}` | no |
| <a name="input_build_date"></a> [build\_date](#input\_build\_date) | Date of the build to ensure reproducibility (format: YYYY-MM-DD). | `string` | `""` | no |
| <a name="input_clone_template"></a> [clone\_template](#input\_clone\_template) | The name of the Proxmox VM template to clone. | `string` | n/a | yes |
| <a name="input_cloudinit_first_access_ssh_public_key"></a> [cloudinit\_first\_access\_ssh\_public\_key](#input\_cloudinit\_first\_access\_ssh\_public\_key) | One or more SSH public keys (newline-separated) to inject for first access on cloned VMs. Leave empty to preserve template-inherited auth. | `string` | `""` | no |
| <a name="input_cloudinit_first_access_user"></a> [cloudinit\_first\_access\_user](#input\_cloudinit\_first\_access\_user) | Cloud-init user for first SSH access when cloudinit\_first\_access\_ssh\_public\_key is set. | `string` | `"ansible"` | no |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | A unique name for the cluster or stack in this environment. | `string` | n/a | yes |
| <a name="input_cost_center"></a> [cost\_center](#input\_cost\_center) | Cost center for resource allocation and billing. | `string` | `"engineering"` | no |
| <a name="input_created_by"></a> [created\_by](#input\_created\_by) | Tag for the creator of the resources. | `string` | `"terraform-proxmox"` | no |
| <a name="input_data_disk_defaults"></a> [data\_disk\_defaults](#input\_data\_disk\_defaults) | Defaults for the data disk used by partitioning when no additional\_disks are provided. | <pre>object({<br/>    enabled = bool<br/>    storage = string<br/>    size    = string<br/>    slot    = string<br/>  })</pre> | <pre>{<br/>  "enabled": true,<br/>  "size": "50G",<br/>  "slot": "virtio1",<br/>  "storage": ""<br/>}</pre> | no |
| <a name="input_default_os_profile"></a> [default\_os\_profile](#input\_default\_os\_profile) | Default OS profile to use when no group mapping or per-VM override is provided. | `string` | `"ubuntu2404"` | no |
| <a name="input_environment_name"></a> [environment\_name](#input\_environment\_name) | The name of the environment (for example: dev, testing, prod, qa). | `string` | `"dev"` | no |
| <a name="input_force_create"></a> [force\_create](#input\_force\_create) | Whether to force creation of VMs even if the VMID is already in use. | `bool` | `false` | no |
| <a name="input_force_recreate_on_partitioning_change"></a> [force\_recreate\_on\_partitioning\_change](#input\_force\_recreate\_on\_partitioning\_change) | Whether generated partitioning cloud-init snippet content changes should force VM recreation. | `bool` | `false` | no |
| <a name="input_group_os_profile"></a> [group\_os\_profile](#input\_group\_os\_profile) | Map of node group names to OS profile keys. Used for auto-selecting templates and filesystem defaults. | `map(string)` | <pre>{<br/>  "cicd": "ubuntu2404",<br/>  "database19c": "oracle8",<br/>  "database19c_ol9": "oracle9",<br/>  "database21c": "oracle8",<br/>  "gitlab": "ubuntu2404",<br/>  "gitlab_runner": "ubuntu2404",<br/>  "jenkins": "ubuntu2404",<br/>  "jenkins_agent": "ubuntu2404",<br/>  "weblogic12c": "oracle8",<br/>  "weblogic14c": "oracle9",<br/>  "zimbra": "oracle9"<br/>}</pre> | no |
| <a name="input_log_file_prefix"></a> [log\_file\_prefix](#input\_log\_file\_prefix) | Prefix for log file naming. | `string` | `"terraform-plugin-proxmox"` | no |
| <a name="input_log_level"></a> [log\_level](#input\_log\_level) | Logging level for Terraform provider operations. | `string` | `"info"` | no |
| <a name="input_manage_vault_access"></a> [manage\_vault\_access](#input\_manage\_vault\_access) | Whether Terraform should manage Vault mount/policy/approle resources. | `bool` | `false` | no |
| <a name="input_manage_vm_pool"></a> [manage\_vm\_pool](#input\_manage\_vm\_pool) | Whether Terraform should manage the Proxmox VM pool resource. | `bool` | `false` | no |
| <a name="input_network_bridge"></a> [network\_bridge](#input\_network\_bridge) | The Proxmox network bridge to attach VMs to. | `string` | n/a | yes |
| <a name="input_network_vlan"></a> [network\_vlan](#input\_network\_vlan) | Optional VLAN tag for primary workload NICs. Set 0 to leave NICs untagged. | `number` | `0` | no |
| <a name="input_node_groups"></a> [node\_groups](#input\_node\_groups) | A map of node groups to provision (e.g., 'oracledb', 'weblogic', 'cicd', 'k8s'), value is a map of VM configurations. | <pre>map(map(object({<br/>    vmid                        = number<br/>    name                        = string<br/>    ipconfig0                   = string<br/>    cores                       = number<br/>    memory                      = number // in MB<br/>    disk_size                   = string // e.g., "50G"<br/>    vm_disk_storage             = optional(string, "")<br/>    tags                        = optional(string, "")<br/>    clone_template              = optional(string, "")<br/>    os_profile                  = optional(string, "")<br/>    ha_state                    = optional(string, "")<br/>    ha_group                    = optional(string, "")<br/>    efi_disk_enabled            = optional(bool)<br/>    efi_disk_storage            = optional(string, "")<br/>    efi_disk_type               = optional(string, "")<br/>    efi_disk_format             = optional(string, "")<br/>    efi_pre_enrolled_keys       = optional(bool)<br/>    power_state                 = optional(string, "")<br/>    start_at_node_boot          = optional(bool)<br/>    protection                  = optional(bool)<br/>    backup                      = optional(bool)<br/>    backup_storage              = optional(string, "")<br/>    balloon                     = optional(number)<br/>    nameserver                  = optional(string, "")<br/>    searchdomain                = optional(string, "")<br/>    skip_ipv6                   = optional(bool)<br/>    network_vlan                = optional(number)<br/>    monitoring_enabled          = optional(bool, true)<br/>    monitoring_profile          = optional(string, "")<br/>    monitoring_expected_up      = optional(bool)<br/>    force_recreate_on_change_of = optional(string, "")<br/>    data_disk = optional(object({<br/>      size    = string<br/>      storage = optional(string, "")<br/>      slot    = optional(string, "")<br/>    }), null)<br/>    additional_disks = optional(list(object({<br/>      storage = string<br/>      size    = string<br/>      slot    = string<br/>    })), [])<br/>    cicustom = optional(string, "")<br/>    partitioning = optional(object({<br/>      enabled     = optional(bool, true)<br/>      disk_device = optional(string, "/dev/vdb")<br/>      vg_name     = optional(string, "vgdata")<br/>      fs_type     = optional(string, "ext4")<br/>      mounts = list(object({<br/>        mount   = string<br/>        size_gb = string<br/>        owner   = optional(string, "root")<br/>        group   = optional(string, "root")<br/>      }))<br/>    }), null)<br/>  })))</pre> | `{}` | no |
| <a name="input_os_profiles"></a> [os\_profiles](#input\_os\_profiles) | Map of OS profiles to template, filesystem defaults, and Ansible hints. | <pre>map(object({<br/>    clone_template             = string<br/>    fs_type                    = string<br/>    os_family                  = string<br/>    ansible_python_interpreter = string<br/>  }))</pre> | <pre>{<br/>  "oracle8": {<br/>    "ansible_python_interpreter": "/usr/bin/python3.9",<br/>    "clone_template": "oracle8",<br/>    "fs_type": "xfs",<br/>    "os_family": "oracle"<br/>  },<br/>  "oracle9": {<br/>    "ansible_python_interpreter": "/usr/bin/python3",<br/>    "clone_template": "oracle9",<br/>    "fs_type": "xfs",<br/>    "os_family": "oracle"<br/>  },<br/>  "ubuntu2404": {<br/>    "ansible_python_interpreter": "/usr/bin/python3",<br/>    "clone_template": "ubuntu2404",<br/>    "fs_type": "ext4",<br/>    "os_family": "ubuntu"<br/>  }<br/>}</pre> | no |
| <a name="input_owner"></a> [owner](#input\_owner) | Owner of the resources for tagging and organization. | `string` | `"platform-team"` | no |
| <a name="input_project_name"></a> [project\_name](#input\_project\_name) | Name of the project for tagging and organization. | `string` | `"ha-cluster"` | no |
| <a name="input_proxmox_debug"></a> [proxmox\_debug](#input\_proxmox\_debug) | Whether to enable verbose proxmox-api-go debug output. | `bool` | `false` | no |
| <a name="input_proxmox_log_enable"></a> [proxmox\_log\_enable](#input\_proxmox\_log\_enable) | Whether to enable Telmate Proxmox provider logging. | `bool` | `true` | no |
| <a name="input_proxmox_minimum_permission_check"></a> [proxmox\_minimum\_permission\_check](#input\_proxmox\_minimum\_permission\_check) | Whether the Proxmox provider should check minimum API token permissions. | `bool` | `true` | no |
| <a name="input_proxmox_minimum_permission_list"></a> [proxmox\_minimum\_permission\_list](#input\_proxmox\_minimum\_permission\_list) | Optional override for the Proxmox provider minimum permission check list. | `list(string)` | `[]` | no |
| <a name="input_proxmox_parallel"></a> [proxmox\_parallel](#input\_proxmox\_parallel) | Allowed simultaneous Proxmox provider operations. | `number` | `1` | no |
| <a name="input_snippet_storage"></a> [snippet\_storage](#input\_snippet\_storage) | The Proxmox storage that exposes snippets content for cicustom cloud-init data. | `string` | `"local"` | no |
| <a name="input_storage_pool"></a> [storage\_pool](#input\_storage\_pool) | The Proxmox storage pool for VM disks and cloud-init. | `string` | n/a | yes |
| <a name="input_target_node"></a> [target\_node](#input\_target\_node) | The Proxmox node where VMs will be deployed. | `string` | n/a | yes |
| <a name="input_timeout"></a> [timeout](#input\_timeout) | Timeout for Proxmox API operations in seconds. | `number` | `300` | no |
| <a name="input_vault_address"></a> [vault\_address](#input\_vault\_address) | The address of the Vault server. | `string` | n/a | yes |
| <a name="input_vault_approle_bind_secret_id"></a> [vault\_approle\_bind\_secret\_id](#input\_vault\_approle\_bind\_secret\_id) | Whether AppRole login requires secret\_id. | `bool` | `true` | no |
| <a name="input_vault_approle_secret_id_bound_cidrs"></a> [vault\_approle\_secret\_id\_bound\_cidrs](#input\_vault\_approle\_secret\_id\_bound\_cidrs) | Allowed CIDR blocks for AppRole secret\_id usage. | `set(string)` | `[]` | no |
| <a name="input_vault_approle_secret_id_num_uses"></a> [vault\_approle\_secret\_id\_num\_uses](#input\_vault\_approle\_secret\_id\_num\_uses) | Maximum uses per AppRole secret\_id (0 means unlimited). | `number` | `0` | no |
| <a name="input_vault_approle_secret_id_ttl_seconds"></a> [vault\_approle\_secret\_id\_ttl\_seconds](#input\_vault\_approle\_secret\_id\_ttl\_seconds) | TTL for AppRole secret\_id in seconds (0 means no expiry). | `number` | `0` | no |
| <a name="input_vault_approle_token_bound_cidrs"></a> [vault\_approle\_token\_bound\_cidrs](#input\_vault\_approle\_token\_bound\_cidrs) | Allowed CIDR blocks for tokens issued by AppRole. | `set(string)` | `[]` | no |
| <a name="input_vault_approle_token_no_default_policy"></a> [vault\_approle\_token\_no\_default\_policy](#input\_vault\_approle\_token\_no\_default\_policy) | Whether to omit Vault default policy from AppRole-issued tokens. | `bool` | `false` | no |
| <a name="input_vault_approle_token_num_uses"></a> [vault\_approle\_token\_num\_uses](#input\_vault\_approle\_token\_num\_uses) | Maximum uses for AppRole-issued tokens (0 means unlimited). | `number` | `0` | no |
| <a name="input_vault_auth_mode"></a> [vault\_auth\_mode](#input\_vault\_auth\_mode) | Vault provider authentication mode: token or approle. | `string` | `"token"` | no |
| <a name="input_vault_kv_mount_path"></a> [vault\_kv\_mount\_path](#input\_vault\_kv\_mount\_path) | Vault KV v2 mount path used for Proxmox credentials. | `string` | `"secret"` | no |
| <a name="input_vault_manage_kv_mount"></a> [vault\_manage\_kv\_mount](#input\_vault\_manage\_kv\_mount) | Whether Vault governance should create/manage the KV mount resource. Null defaults to true. | `bool` | `null` | no |
| <a name="input_vault_role_id"></a> [vault\_role\_id](#input\_vault\_role\_id) | Vault AppRole role\_id used when vault\_auth\_mode=approle. | `string` | `null` | no |
| <a name="input_vault_secret_id"></a> [vault\_secret\_id](#input\_vault\_secret\_id) | Vault AppRole secret\_id used when vault\_auth\_mode=approle. | `string` | `null` | no |
| <a name="input_vault_secret_prefix"></a> [vault\_secret\_prefix](#input\_vault\_secret\_prefix) | Prefix under the KV mount where per-workspace Proxmox credentials are stored. | `string` | `"terraform"` | no |
| <a name="input_vault_token"></a> [vault\_token](#input\_vault\_token) | The token to authenticate with Vault. | `string` | `null` | no |
| <a name="input_vm_defaults"></a> [vm\_defaults](#input\_vm\_defaults) | Default configuration values for VMs across all node types. | <pre>object({<br/>    agent_enabled         = optional(number, 1)<br/>    os_type               = optional(string, "cloud-init")<br/>    cpu_type              = optional(string, "host")<br/>    network_model         = optional(string, "virtio")<br/>    scsihw                = optional(string, "virtio-scsi-single")<br/>    boot_order            = optional(string, "order=scsi0;net0")<br/>    boot_disk_device      = optional(string, "scsi0")<br/>    bios                  = optional(string, "ovmf")<br/>    machine               = optional(string, "q35")<br/>    efi_disk_enabled      = optional(bool, true)<br/>    efi_disk_storage      = optional(string, "")<br/>    efi_disk_type         = optional(string, "4m")<br/>    efi_disk_format       = optional(string, "raw")<br/>    efi_pre_enrolled_keys = optional(bool, false)<br/>    ha_state              = optional(string, "")<br/>    ha_group              = optional(string, "")<br/>    power_state           = optional(string, "running")<br/>    start_at_node_boot    = optional(bool, false)<br/>    protection            = optional(bool, false)<br/>    balloon               = optional(number, 0)<br/>    nameserver            = optional(string, "")<br/>    searchdomain          = optional(string, "")<br/>    skip_ipv6             = optional(bool, false)<br/>    network_vlan          = optional(number, null)<br/>  })</pre> | `{}` | no |
| <a name="input_vm_pool"></a> [vm\_pool](#input\_vm\_pool) | The Proxmox resource pool for the VMs. | `string` | n/a | yes |
| <a name="input_vm_pool_comment"></a> [vm\_pool\_comment](#input\_vm\_pool\_comment) | Comment for managed Proxmox VM pool. | `string` | `"Managed by Terraform"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_all_nodes_summary"></a> [all\_nodes\_summary](#output\_all\_nodes\_summary) | A comprehensive summary of all nodes deployed in the environment. |
| <a name="output_all_vm_host_ips"></a> [all\_vm\_host\_ips](#output\_all\_vm\_host\_ips) | Parsed host IP addresses (without CIDR/gateway) of all VMs (corresponding to sorted names). |
| <a name="output_all_vm_ids"></a> [all\_vm\_ids](#output\_all\_vm\_ids) | IDs of all VMs (corresponding to sorted names). |
| <a name="output_all_vm_ips"></a> [all\_vm\_ips](#output\_all\_vm\_ips) | ipconfig0 strings of all VMs (corresponding to sorted names). |
| <a name="output_all_vm_names"></a> [all\_vm\_names](#output\_all\_vm\_names) | Names of all VMs (sorted). |
| <a name="output_all_vm_vlans"></a> [all\_vm\_vlans](#output\_all\_vm\_vlans) | Effective VLAN tags for all VMs (0 = untagged). |
| <a name="output_ansible_inventory_path"></a> [ansible\_inventory\_path](#output\_ansible\_inventory\_path) | The path to the generated Ansible inventory file. |
| <a name="output_backup_job_settings"></a> [backup\_job\_settings](#output\_backup\_job\_settings) | Environment-level schedule, performance, notification, and retention settings for Proxmox backup jobs. |
| <a name="output_connection_info"></a> [connection\_info](#output\_connection\_info) | Connection information for configuration management tools. |
| <a name="output_deployment_summary_path"></a> [deployment\_summary\_path](#output\_deployment\_summary\_path) | The path to the deployment summary JSON file for CI/CD integration. |
| <a name="output_environment_info"></a> [environment\_info](#output\_environment\_info) | Structured environment information for CI/CD pipelines. |
| <a name="output_infrastructure_metrics"></a> [infrastructure\_metrics](#output\_infrastructure\_metrics) | Infrastructure metrics for monitoring and alerting. |
| <a name="output_node_groups_summary"></a> [node\_groups\_summary](#output\_node\_groups\_summary) | Summary of nodes grouped by their role. |
| <a name="output_vm_backup_policy"></a> [vm\_backup\_policy](#output\_vm\_backup\_policy) | Per-VM Proxmox backup inclusion and destination policy. |
| <a name="output_workspace_info"></a> [workspace\_info](#output\_workspace\_info) | Current workspace and environment information. |
<!-- END_TF_DOCS -->

Quick local bootstrap (recommended):

```bash
cd terraform-proxmox
make setup-tools      # Ubuntu/Debian auto-install + validation
make check-tools      # Re-run readiness checks anytime
make tf_scan          # Run custom policy scan + tflint + tfsec
make vault-login      # Optional: prefetch/cached token (supports AppRole)
```

For non-Ubuntu/Debian systems, install tools manually and then run `make check-tools`.
`check-tools` requires `tflint`, `tfsec`, and `terraform-docs` to return
semantic versions; a placeholder executable that only exists on `PATH` is
rejected. Run the configured hooks from this directory with
`pre-commit run --all-files`; install `pre-commit` in the active Python
environment first when needed.

## 1. Install Vault Terraform and Packer

Ubuntu/Debian example (recommended for this repo):

```bash
sudo apt-get update
sudo apt-get install -y wget gpg
wget -O - https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor --yes -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update
sudo apt-get install -y vault terraform packer jq
```

For other OSes, use the official HashiCorp install docs.

## 2. Self-Managed Vault Server TLS and Raft

This follows the official Vault tutorial (TLS + raft storage). It is suitable for lab use. Harden and use HA for production.

1. Create directories:

```bash
sudo install -d -m 0750 -o vault -g vault /var/lib/vault
sudo install -d -m 0755 -o root -g root /etc/vault.d
sudo install -d -m 0750 -o vault -g vault /etc/vault.d/tls
```

1. Generate TLS certs (include localhost + LAN SANs):

```bash
VAULT_DNS_NAME="<vault-lan-dns>"   # DNS name clients use on your LAN
VAULT_LAN_IP="<vault-lan-ip>"      # Vault server LAN IP

sudo openssl req -x509 -newkey rsa:4096 -sha256 -days 365 \
  -nodes -keyout /etc/vault.d/tls/vault-key.pem -out /etc/vault.d/tls/vault-cert.pem \
  -subj "/CN=${VAULT_DNS_NAME}" \
  -addext "subjectAltName=DNS:${VAULT_DNS_NAME},DNS:localhost,IP:${VAULT_LAN_IP},IP:127.0.0.1"
sudo chown vault:vault /etc/vault.d/tls/vault-key.pem
sudo chmod 600 /etc/vault.d/tls/vault-key.pem
sudo install -m 0644 -o root -g root /etc/vault.d/tls/vault-cert.pem /etc/vault.d/vault-cert.pem
```

1. Create `/etc/vault.d/vault.hcl`:

```hcl
api_addr     = "https://<vault-lan-dns-or-ip>:8200"
cluster_addr = "https://<vault-lan-ip>:8201"
cluster_name = "learn-vault-cluster"
disable_mlock = true
ui = true

listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "/etc/vault.d/tls/vault-cert.pem"
  tls_key_file  = "/etc/vault.d/tls/vault-key.pem"
}

storage "raft" {
  path    = "/var/lib/vault"
  node_id = "learn-vault-server"
}
```

If you want loopback-only Vault, set `api_addr`, `cluster_addr`, and listener `address` back to `127.0.0.1`.

1. Optional CLI defaults:

```bash
cat <<'EOF' | sudo tee /etc/vault.d/vault.env >/dev/null
VAULT_ADDR=https://<vault-lan-dns-or-ip>:8200
VAULT_CACERT=/etc/vault.d/vault-cert.pem
EOF
```

1. Restrict Vault port to trusted LAN CIDRs (example with UFW):

```bash
sudo ufw allow from <trusted-lan-cidr> to any port 8200 proto tcp
```

1. Start Vault:

```bash
sudo systemctl enable --now vault
```

1. Initialize and unseal:

```bash
export VAULT_ADDR=https://<vault-lan-dns-or-ip>:8200
export VAULT_CACERT=/etc/vault.d/vault-cert.pem
vault operator init -key-shares=3 -key-threshold=2 -format=json | tee ~/vault-init.json
UNSEAL_KEY_1="$(jq -r '.unseal_keys_b64[0]' ~/vault-init.json)"
UNSEAL_KEY_2="$(jq -r '.unseal_keys_b64[1]' ~/vault-init.json)"
vault operator unseal "$UNSEAL_KEY_1"
vault operator unseal "$UNSEAL_KEY_2"
```

1. Ensure KV v2 is available at your configured mount (`vault_kv_mount_path`, default `secret`):

```bash
vault secrets enable -path=<vault_kv_mount_path> kv-v2
```

Notes:

- Prefer `VAULT_CACERT` over `VAULT_SKIP_VERIFY`.
- On remote Terraform/workstation clients, copy `vault-cert.pem` and set `VAULT_CACERT` to the local path on that machine.
- If `jq` is not installed, install it or copy the first unseal key manually from `~/vault-init.json`.
- If the KV mount already exists, skip the command above.
- If this repo manages Vault governance (`manage_vault_access=true`), you can run `make vault-bootstrap` to import/reconcile existing Vault resources before planning.

## 3. Configure Terraform and Vault Environment

Terraform reads Vault credentials from variables. Set them via `.env` (preferred) or `secrets.auto.tfvars`.

Option A: `.env` (auto-loaded by the Makefile):

```bash
TF_VAR_vault_address=https://<vault-lan-dns-or-ip>:8200

VAULT_ADDR=https://<vault-lan-dns-or-ip>:8200

# Self-signed TLS (choose one)
VAULT_CACERT=/path/to/vault-cert.pem
# VAULT_SKIP_VERIFY=true
```

Vault auth in `.env` (choose one):

```bash
# Static token (required when manage_vault_access=true; bootstrap/governance path)
VAULT_TOKEN=<vault-token>

# AppRole (recommended for day-to-day secret reads when manage_vault_access=false)
VAULT_ROLE_ID=<approle-role-id>
VAULT_SECRET_ID=<approle-secret-id>
# Optional token cache file
VAULT_TOKEN_FILE=.vault-token
```

Recommended auth/governance combinations:

- `vault_auth_mode="token"` + `manage_vault_access=true`: use an admin-capable `VAULT_TOKEN` (required to manage Vault mount/policy/auth backend resources).
- `vault_auth_mode="approle"` + `manage_vault_access=false`: use AppRole credentials for routine Terraform/Packer secret access after governance is already in place.
- If you switch back to governance management, provide a privileged `VAULT_TOKEN` again and rerun `make vault-bootstrap`.
- When `.env` contains both `VAULT_TOKEN` and AppRole values, helper flows prefer the token unless a runtime verifier explicitly clears it. Use `make vault-runtime-verify ENVIRONMENT=<env>` to prove the AppRole-only path still works.

Option B: `secrets.auto.tfvars`:

```hcl
vault_address = "https://<vault-lan-dns-or-ip>:8200"
vault_token   = "<vault-token>"
```

Important token-precedence note:

- `secrets.auto.tfvars` has higher precedence than `TF_VAR_*` environment variables.
- If `vault_token` is present in `secrets.auto.tfvars`, it overrides token values from `.env` and `vault-auth.sh`.
- After token rotation or `make vault-reinit`, either update or remove `vault_token` in `secrets.auto.tfvars` to avoid `403 permission denied / invalid token` during `make plan`.

If Terraform runs on the same host as Vault and Vault is loopback-only, use `https://127.0.0.1:8200`.

Both files are ignored by git and should remain local.

### 3.1 Recreate Env After make clean-all (dev defaults)

`make clean-all` removes local auth/config files including `.env` and `secrets.auto.tfvars`.
To restore a runnable local setup for `dev`, use documented defaults first:

```bash
cd terraform-proxmox
cp .env.example .env
chmod 600 .env
```

Documented concrete defaults in this repo:

- `TF_VAR_vault_address=https://198.51.100.10:8200`
- `VAULT_ADDR=https://198.51.100.10:8200`
- `PROXMOX_USER=root`
- `PROXMOX_HOST_DEV=198.51.100.12`
- `PROXMOX_HOST_PROD=198.51.100.11`
- `PROXMOX_HOST_TESTING=198.51.100.13`

Required values intentionally not documented as concrete literals:

- `VAULT_TOKEN` (and `TF_VAR_vault_token` when using token mode)
- `VAULT_ROLE_ID` / `VAULT_SECRET_ID` (when using AppRole mode)
- `VAULT_CACERT` local path (site-specific)

For this repo’s committed `environments/dev.tfvars` (`vault_auth_mode="token"` + `manage_vault_access=true`), use an admin-capable `VAULT_TOKEN`.
If `VAULT_CACERT` and `VAULT_SKIP_VERIFY` are both unset, repo scripts auto-detect a local cert from `/etc/vault.d/vault-cert.pem` or `/etc/vault.d/tls/vault-cert.pem`.

Recovery sequence after `make clean-all` (full runnable order):

```bash
cd terraform-proxmox
cp .env.example .env
chmod 600 .env
bash -n .env

make vault-reinit-dry-run
make vault-reinit CONFIRM=YES

make init ENVIRONMENT=dev
make rotate-proxmox-creds ENVIRONMENT=dev
make vault-bootstrap ENVIRONMENT=dev
make vault-login ENVIRONMENT=dev
make vault-mode-verify ENVIRONMENT=dev
make vault-mode-status ENVIRONMENT=dev
```

AppRole auth validation route (instead of static token in `.env`):

```bash
cd terraform-proxmox
cp .env .env.bak.approle-test
sed -i '/^VAULT_TOKEN=/d; /^TF_VAR_vault_token=/d' .env
# Ensure vault-auth does not silently reuse an old admin token cache.
rm -f .vault-token

make vault-login ENVIRONMENT=dev
./scripts/vault-auth.sh --force-login --validate --print-token >/dev/null
./scripts/with-vault-token.sh vault kv get secret/terraform/dev/creds >/dev/null

mv .env.bak.approle-test .env
rm -f .vault-token
```

Note: with `environments/dev.tfvars` (`manage_vault_access=true`), governance operations still require an admin token.
AppRole-only `.env` works for runtime secret reads/login flow, but `make plan` / `make apply` will fail during governance refresh with errors like:
`failed to create limited child token ... POST /v1/auth/token/create ... permission denied`.
If you want to keep AppRole values in `.env` but run a one-off governance apply, inject a temporary admin token only for that command:

```bash
ROOT_TOKEN="$(tr -d '\n' < ~/.vault-recovery/latest/root-token.txt)"
VAULT_TOKEN="$ROOT_TOKEN" TF_VAR_vault_token="$ROOT_TOKEN" make apply ENVIRONMENT=<env>
```

For full Terraform AppRole mode (non-governance), set `vault_auth_mode="approle"` and `manage_vault_access=false` in `environments/<env>.tfvars`.

### 3.2 Obtain Required Secret and Env Values

Use this checklist when `.env` was removed (for example after `make clean-all`).

1. `VAULT_ADDR` and `TF_VAR_vault_address`

```bash
# Use the same reachable endpoint for both variables.
# This repo documents a LAN default of 198.51.100.10 for dev examples.
VAULT_ADDR=https://198.51.100.10:8200
TF_VAR_vault_address=https://198.51.100.10:8200
```

1. `VAULT_TOKEN` / `TF_VAR_vault_token` (token mode, admin/governance workflows)

```bash
# If you used this repo's Vault reinit workflow:
export VAULT_TOKEN="$(tr -d '\n' < ~/.vault-recovery/latest/root-token.txt)"
export TF_VAR_vault_token="$VAULT_TOKEN"

# Validate token + connectivity:
vault token lookup
```

Alternative sources:

- Existing local token cache: `~/.vault-token` (validate with `vault token lookup`)
- Fresh login using your org's Vault auth method, then export resulting token

1. `VAULT_ROLE_ID` and `VAULT_SECRET_ID` (AppRole mode)

```bash
# Requires admin-capable token to read role_id / mint secret_id.
vault read -field=role_id auth/approle/role/terraform-proxmox/role-id
vault write -f -field=secret_id auth/approle/role/terraform-proxmox/secret-id
```

1. `VAULT_CACERT` (recommended) or `VAULT_SKIP_VERIFY`

```bash
# Preferred: copy the Vault server cert locally and trust it explicitly.
VAULT_CACERT=/path/to/local/vault-cert.pem

# Last-resort lab fallback (less secure):
VAULT_SKIP_VERIFY=true
```

1. Write values into local `.env` (never commit)

```bash
chmod 600 terraform-proxmox/.env
```

AppRole login helper:

```bash
make vault-login
```

For manual Terraform CLI usage (outside Makefile targets), you can export a token via:

```bash
eval "$(./scripts/vault-auth.sh --print-export)"
```

Vault governance bootstrap helper (recommended when `manage_vault_access=true`):

```bash
make vault-bootstrap ENVIRONMENT=dev
```

This helper:

- validates that the active Vault token can manage `sys/mounts`, `sys/policies/acl`, and `sys/auth`
- imports existing Vault KV mount/config, AppRole backend, and AppRole role into Terraform state when present
- applies the Vault governance module
- refreshes AppRole `role_id`/`secret_id` into `.env`
- rotates Proxmox credentials into `<vault_kv_mount_path>/<vault_secret_prefix>/<env>/creds` (defaults to `secret/terraform/<env>/creds`)

After bootstrap, verify the non-governance runtime path:

```bash
make vault-runtime-verify ENVIRONMENT=dev
```

This logs in with AppRole, reads the configured credential path, renders a
temporary Packer override file, and runs a Terraform plan with
`vault_auth_mode=approle` and `manage_vault_access=false`.

If the role is healthy but its local SecretID has expired, refresh only the
runtime pair with an admin-capable token, then repeat the verifier:

```bash
VAULT_TOKEN="$(tr -d '\n' < ~/.vault-recovery/latest/root-token.txt)" \
  make vault-approle-refresh ENVIRONMENT=dev
make vault-runtime-verify ENVIRONMENT=dev
```

`vault-approle-refresh` reads the live role ID, mints and validates one new
SecretID, revokes its short-lived validation token with the admin token, and
atomically updates only `VAULT_ROLE_ID`, `VAULT_SECRET_ID`, and their two
`TF_VAR_` counterparts in the mode-`0600` `.env`. It does not apply Vault
governance, rotate Proxmox credentials, or enumerate/revoke other SecretIDs.

Check Vault audit logging before governance changes:

```bash
make vault-audit-check
```

If no audit device is enabled on the local Vault server, enable the standard
file audit device:

```bash
make vault-audit-enable-file CONFIRM=ENABLE_AUDIT
make vault-audit-check
```

`make plan` also auto-runs `make vault-bootstrap` once and retries when it detects common bootstrap conditions (`manage_vault_access=true` and AppRole bootstrap or "path is already in use" conflicts).

### 3.3 Workspace and ENVIRONMENT Defaults

`make` now derives its default `ENVIRONMENT` from the currently selected Terraform workspace:

- if workspace is `prod`, `make plan` defaults to `ENVIRONMENT=prod`
- if workspace is `testing`, `make plan` defaults to `ENVIRONMENT=testing`
- if workspace is `default` (or unset), it falls back to `ENVIRONMENT=dev`

Examples:

```bash
make workspace-select ENVIRONMENT=prod
make plan   # uses prod by default

make workspace-select ENVIRONMENT=dev
make plan   # uses dev by default
```

Use explicit `ENVIRONMENT=<env>` in automation/CI for clarity.

`plan`, `apply`, `render-snippets`, and `vault-bootstrap` pin `TF_WORKSPACE`
to that environment, including recursive Vault bootstrap commands and after
the bootstrap script loads `.env`. When this binding is present,
the workspace helpers verify an existing workspace without changing Terraform's
shared local selection. Creating a missing workspace still requires
`terraform workspace new` with the binding temporarily removed, which updates
the local selection; create new workspaces before starting concurrent runs.
Bootstrap and the retried plan remain pinned to the requested environment.

### 3.4 Switch Vault Access Mode (loopback or LAN)

Use the included switch helper. It updates both:

- `/etc/vault.d/vault.hcl` (`api_addr`, `cluster_addr`, listener address)
- `terraform-proxmox/.env` (`VAULT_ADDR`, `TF_VAR_vault_address`)

Then it restarts Vault and verifies:

- Vault health (`vault status`)
- Vault secret read for the selected env (default check path: `secret/terraform/<env>/creds`)
- Terraform wiring (`terraform validate`)
- Packer syntax (`packer validate -syntax-only`)

By default, LAN IP/host are auto-detected from the machine running `make` (route source IP), so manual `VAULT_LAN_IP` is usually not required.

```bash
# Show current mode and addresses
make vault-mode-status ENVIRONMENT=dev

# Switch to LAN mode (listener 0.0.0.0:8200, api_addr uses detected local IP)
make vault-mode-lan ENVIRONMENT=dev

# Switch to LAN mode with automated TLS SAN regeneration (recommended)
make vault-mode-lan-auto ENVIRONMENT=dev

# Switch back to loopback mode (listener 127.0.0.1:8200)
make vault-mode-loopback ENVIRONMENT=dev

# Re-run verification only
make vault-mode-verify ENVIRONMENT=dev
```

Optional overrides:

```bash
make vault-mode-lan ENVIRONMENT=dev VAULT_LAN_IP=198.51.100.10 VAULT_LAN_HOST=198.51.100.10

# Regenerate Vault cert only (adds SANs for 127.0.0.1 + LAN host/IP)
make vault-tls-regenerate VAULT_LAN_IP=198.51.100.10 VAULT_LAN_HOST=198.51.100.10
```

If your host has multiple NICs and LAN switch verification fails with `no route to host` or `connection refused`, pin the exact source IP:

```bash
# Detect the actual source IP used to reach your Proxmox/Vault network
LAN_IP="$(ip -4 route get <proxmox-ip> | awk '{for(i=1;i<=NF;i++) if($i==\"src\"){print $(i+1); exit}}')"
make vault-mode-lan-auto ENVIRONMENT=<env> VAULT_LAN_IP="$LAN_IP" VAULT_LAN_HOST="$LAN_IP"
```

Quick unseal help (when Vault reports `sealed`):

```bash
make vault-unseal-help
```

This prints where unseal keys are stored (`~/.vault-recovery/latest/unseal-keys.txt`) and threshold-safe unseal commands (it iterates all available keys, so no manual `KEYS[1]` guesswork).

Notes:

- You do not need to edit `vault.service` for this mode switch; config changes in `vault.hcl` + service restart are sufficient.
- `daemon-reload` is only needed if the systemd unit file itself changes.
- `vault-mode-lan-auto` is the safest path when cert SAN mismatch blocks LAN mode verification.
- Mode switches auto-attempt unseal by default using `~/.vault-recovery/latest/unseal-keys.txt` (`VAULT_AUTO_UNSEAL=true`; set `VAULT_AUTO_UNSEAL=false` to disable).
- Mode switches now reset failed systemd state before restart and fall back to `start` if `restart` fails (`start-limit-hit` recovery).

### 3.5 Disaster Recovery Reinit (lost unseal key)

If Vault is initialized but the unseal key is unrecoverable, the only recovery path is destructive reinitialization.

What `make vault-reinit` does:

- Stops Vault.
- Backs up current raft data and config to a timestamped local recovery bundle.
- Wipes raft storage.
- Starts Vault and runs `vault operator init`.
- Re-enables `secret/` as KV v2 (if missing).
- Optionally unseals automatically.
- By default, writes new root token to `.env` (`VAULT_TOKEN` and `TF_VAR_vault_token`) and stores root token artifacts in the recovery bundle.
- Redacts root token in `vault-init.json` (the token is stored in `root-token.txt` and `vault-root-token.export`).

Run:

```bash
make vault-reinit-dry-run
make vault-reinit CONFIRM=YES
```

Useful overrides:

```bash
# Stronger key distribution (recommended for multi-admin ops)
make vault-reinit CONFIRM=YES VAULT_INIT_SHARES=3 VAULT_INIT_THRESHOLD=2

# Store recovery bundle under a custom path
make vault-reinit CONFIRM=YES VAULT_RECOVERY_DIR=/secure/path/vault-recovery

# Disable root token persistence + .env token update
make vault-reinit CONFIRM=YES VAULT_REINIT_OPTS='--no-env-token-update'

# Also emit encrypted archive (AES-256) alongside plain bundle
make vault-reinit CONFIRM=YES VAULT_RECOVERY_PASSPHRASE='change-this-passphrase'
```

Inspect generated recovery artifacts:

```bash
make vault-recovery-list
```

Important:

- This process permanently deletes existing Vault data.
- `vault operator init` cannot regenerate old keys on an already-initialized Vault; it only creates new keys after reinit.
- Store unseal keys and root token in at least two independent secure locations (for example password manager + offline encrypted backup).
- Re-seed required secrets after reinit (for this repo, run `make rotate-proxmox-creds ENVIRONMENT=dev` and repeat for each environment).
- Post-reinit order for this repo:
  1. `make init ENVIRONMENT=<env>`
  2. `make rotate-proxmox-creds ENVIRONMENT=<env>`
  3. `make vault-bootstrap ENVIRONMENT=<env>`
  4. `make vault-mode-verify ENVIRONMENT=<env>`

### 3.6 Post-clean-all Recovery Runbook

Use this exact sequence for `dev` when local Terraform files and Vault recovery artifacts were removed.

1. Recreate `.env` and make it private.

```bash
cd terraform-proxmox
cp .env.example .env
chmod 600 .env
bash -n .env
```

1. Edit `.env` and set only valid shell values.

- Do not leave placeholder values like `<vault-token>` uncommented.
- If you use `VAULT_SKIP_VERIFY=true`, keep `VAULT_CACERT` commented.
- If you use `VAULT_CACERT`, set it to a real local file path and keep `VAULT_SKIP_VERIFY` commented.

Minimum required keys for this repo:

```bash
TF_VAR_vault_address=https://198.51.100.10:8200
VAULT_ADDR=https://198.51.100.10:8200
VAULT_SKIP_VERIFY=true
```

1. Load `.env` and check Vault reachability.

```bash
set -a; source .env; set +a
vault status
```

1. Decide how you will authenticate.

- If you already have an admin token: set `VAULT_TOKEN` and `TF_VAR_vault_token` in `.env`, then continue.
- If token auth is unavailable but AppRole is available: set `VAULT_ROLE_ID` and `VAULT_SECRET_ID`, then run `make vault-login ENVIRONMENT=dev`.
- If Vault is sealed and `~/.vault-recovery` was deleted: continue to step 5 (destructive reinit).

1. Reinitialize Vault only when recovery keys are gone (destructive).

```bash
make vault-reinit-dry-run
make vault-reinit CONFIRM=YES
```

1. Recreate Terraform local metadata.

```bash
make init ENVIRONMENT=dev
```

1. Re-seed Proxmox API credentials into Vault.

```bash
make rotate-proxmox-creds ENVIRONMENT=dev
```

1. Reconcile/import Vault governance resources.

```bash
make vault-bootstrap ENVIRONMENT=dev
```

1. Verify all Vault helper targets.

```bash
make vault-login ENVIRONMENT=dev
make vault-mode-verify ENVIRONMENT=dev
make vault-mode-status ENVIRONMENT=dev
```

Expected end state:

- `bash -n .env` passes (no parse errors)
- `vault status` shows `Sealed false`
- `make vault-bootstrap` succeeds
- `make vault-mode-verify` succeeds
- `~/.vault-recovery/latest/{unseal-keys.txt,root-token.txt}` exists

## 4. Create Proxmox API Credentials in Vault

Run the helper script on the Proxmox host. It creates or updates
`terraform-prov@pve`, applies a version-specific PVE 8 or PVE 9 least-privilege
role, and can emit JSON credentials for secure ingestion. Existing users are
not deleted. The generated API token is privilege-separated and receives its
own ACL in addition to the parent-user ACL required by the provider.

From your workstation (from the `terraform-proxmox` directory):

```bash
scp scripts/create-proxmox-api-user.sh root@<proxmox-ip>:/root/
ssh root@<proxmox-ip> 'bash /root/create-proxmox-api-user.sh'
```

On the Terraform workstation, write credentials directly to Vault (preferred via helper script). Path format is `<vault_kv_mount_path>/<vault_secret_prefix>/<env>/creds` (default `secret/terraform/<env>/creds`).
Example manual format:

```bash
vault kv put <vault_kv_mount_path>/<vault_secret_prefix>/dev/creds \
  proxmox_config_api_url="https://<proxmox-ip>:8006/api2/json" \
  proxmox_config_api_token_id="terraform-prov@pve!token-name" \
  proxmox_config_api_token_secret="<token-secret>" \
  proxmox_config_tls_insecure=true
```

Repeat for `testing` and `prod` if needed.

Automated rotation (recommended):

```bash
make rotate-proxmox-creds ENVIRONMENT=dev
```

This runs Proxmox token rotation remotely and updates Vault path `<vault_kv_mount_path>/<vault_secret_prefix>/dev/creds` (default `secret/terraform/dev/creds`) in one step, without printing secrets to stdout.
The rotation helper uses KV CAS when it can read the current version (metadata first, then data fallback). If the backend enforces CAS and the token cannot read version metadata/data, the helper exits with an explicit permission guidance message.

After updating Vault, no further credential edits are required:

- Terraform reads Proxmox credentials directly from `<vault_kv_mount_path>/<vault_secret_prefix>/<workspace>/creds`.
- `make packer-build-*` auto-loads Proxmox credentials from the environment path resolved from `environments/<env>.tfvars` (`vault_kv_mount_path` + `vault_secret_prefix`).

Credential rotation quick check:

```bash
make vault-mode-verify ENVIRONMENT=dev
make packer-build-ubuntu2404 ENVIRONMENT=dev
```

## 5. Prepare Base VMs for Packer

Packer clones three reusable base/source VMs. Preferred method in this repo:

```bash
# Optional: sync required cloud images first
make env-cloud-images ENVIRONMENT=<env> BASE_VM_BUILD_ORACLE=true

# Create base/source VMs using repo defaults
make env-base-vm-ubuntu2404 ENVIRONMENT=<env>
make env-base-vm-oracle8 ENVIRONMENT=<env>
make env-base-vm-oracle9 ENVIRONMENT=<env>
```

You can also run `make env-base-vms ENVIRONMENT=<env> BASE_VM_BUILD_ORACLE=true` to do this in one command.

For a static address during the example base rebuild, the complete command is:

```bash
make env-base-vms ENVIRONMENT=example BASE_VM_BUILD_ORACLE=true \
  BASE_VM_IPCIDR=198.51.100.0/24 BASE_VM_GATEWAY=198.51.100.18
```

This command replaces reusable base VMIDs when `BASE_VM_FORCE=1` (the
default), and it builds Ubuntu 24.04 plus both Oracle bases. It does **not**
run Packer; follow it with `make packer-build-all ENVIRONMENT=example` after
the bases are verified. The `.80` address is reserved for builder testing and
must be active on only one PVE host at a time.

Scope note:

- `env-base-vm-*` and `packer-build-*` currently build templates only for `ubuntu24`, `oracle8`, and `oracle9`.
- `make env-cloud-images` supports a broader image matrix for direct cloud-init validation and future expansion, but those additional images are not yet wired into the Packer template build targets.

Base VM requirements:

- VMIDs: `999999990` (oracle9), `999999991` (oracle8), `999999992` (ubuntu2404)
- Names: `oracle9-packer-base`, `oracle8-packer-base`, `ubuntu2404-packer-base`
- OS disk: 50G
- CPU: 8 cores
- RAM: 10GB
- No data disk (data disks are attached by Terraform)
- Existing root-only builder environment: `/root/scripts/.env` on the target
  PVE by default; override with `BASE_VM_REMOTE_ENV_FILE` when the file lives
  elsewhere

Explicit Make/wrapper environment values take precedence over the remote
environment file. The file supplies only values the invocation did not set,
so `BASE_VM_DO_OS_UPDATE=0`, storage, image, network, and finalization choices
cannot be silently reversed by stale PVE-local defaults.

The Make targets pass the exact catalog-selected source image into the remote
builder, clean per-instance cloud-init state, detach bootstrap-only userdata,
set Proxmox `ciupgrade=0`, assert the regenerated standard user-data does not
request `package_upgrade: true`, and shut each base VM down before Packer.
`DO_OS_UPDATE` is therefore the only builder OS-upgrade control; detaching the
custom user-data cannot trigger an implicit upgrade on Packer's next boot. Set
`BASE_VM_SANITIZE_TEMPLATE_BASE=0` only for a direct disposable VM test that is
not going to be cloned as a base.

The pinned OL8.10 b287 image currently contains Oracle's
`cloud-init-23.4-7.0.4.el8_10.12`, whose sysconfig renderer calls the absent
`cloudinit.util.load_text_file` API when PVE supplies DNS. For the initial OL8
boot only, the builder attaches temporary DNS-free network-data (PVE otherwise
inherits host DNS even when `nameserver` is unset), repairs that exact call to
the package's available `load_file` API, supplies bootstrap DNS, persists the
declared resolver through a bounded NetworkManager readiness/reapply loop, and
verifies repository resolution.
It refreshes the resolver again at the start of `runcmd` because NetworkManager
rewrites the bootstrap file after the package stage, then deletes the temporary
network-data and restores PVE's standard network generation so Packer and
Terraform clones exercise the repaired renderer.
Terminal cloud-init errors, failed systemd units, and an inactive Zabbix Agent
2 are acceptance failures; they are not tolerated as package-download warnings.
The OL8 Zabbix path retains the fresh cloud-init DNF metadata cache and the
verifier waits, for at most five minutes and only while the installer process
exists, before judging the service. A failure prints the preserved installer
tail. On OL8, `firewall-cmd` can hang under cloud-init's SELinux domain even
while firewalld serves interactive clients. The bootstrap therefore removes
broad and stale Agent 2 rules from every zone with `firewall-offline-cmd`, adds
only the declared sources, validates the persistent configuration, and restarts
firewalld once. Post-cloud-init SSH acceptance then proves the exact permanent
and runtime rule sets and rejects any extra TCP/10050 accept.
The UFW path removes every existing Agent 2 allow command, including broad,
CIDR-shaped, duplicate, and stale-source forms, then proves that `ufw show
added` contains exactly the declared source set. The base builder does not
implicitly enable an inactive UFW policy; acceptance reports whether the
verified rules are live or persisted for later activation.
On failure, the builder stops the VM but preserves guest logs and bootstrap
snippets and refuses reusable-base finalization so the root cause remains
inspectable. The next accepted attempt must force-recreate the VM.

Reserved Packer template outputs (definitive names + high VMIDs):

- `999999993` -> `oracle9`
- `999999994` -> `oracle8`
- `999999995` -> `ubuntu2404`

If you use a custom/manual script instead, keep the same VMIDs and names above.

## 5.1 Cloud Image Matrix and Validation

The image sync helper can be driven directly with:

```bash
make env-cloud-images ENVIRONMENT=<env> CLOUD_IMAGES=all
```

Supported `CLOUD_IMAGES` keys:

- `ubuntu22`
- `ubuntu24`
- `debian12`
- `oracle8`
- `oracle9`
- `rocky9`
- `alma9`
- `fedora43`
- `common`
- `all`

Selection behavior:

- `common` resolves to `ubuntu24` during default bootstrap runs.
- `common` expands to `ubuntu24,oracle8,oracle9` when `BASE_VM_BUILD_ORACLE=true`.
- `all` expands to the full supported matrix above.

Checksum behavior:

- SHA256: Ubuntu, Oracle Linux, Rocky Linux, AlmaLinux, Fedora
- SHA512: Debian 12
- Oracle Linux checksum discovery uses Oracle's official template metadata JSON.
- The Packer input set is pinned in `config/cloud-images.env`; Make and the
  Bash image/builder helpers consume that one catalog while allowing explicit
  runtime overrides.
- Current pins are Oracle Linux 8.10 `b287`, Oracle Linux 9.8 `b293`, and the
  Ubuntu Noble `20260826` daily image. Upgrade the URL, filename, and checksum
  atomically, then repeat the two-PVE builder acceptance.

The builder validates `CORES` against the target node's `nproc` value before
creating or replacing a VM because current PVE rejects a per-VM vCPU request
above that node limit. Eight cores is the example default; pass
`BASE_VM_CORES=6` (or direct `CORES=6`) on a six-CPU builder sandbox.

Current live validation status on Proxmox:

- Root-disk cloud-init smoke tests passed for Debian 12, Ubuntu 24.04, and Fedora 43.
- Data-disk and LVM provisioning passed for Debian 12, Ubuntu 24.04, AlmaLinux 9, and Rocky Linux 9.
- Swap policy validation passed across Debian 12, Ubuntu 22.04/24.04, Oracle Linux 8/9, AlmaLinux 9, Rocky Linux 9, and Fedora 43.
- Fedora 43 intentionally satisfies the swap target through distro-provided `zram`, so the builder tops up only when required instead of forcing a replacement swap layout.

## 6. Configure Packer Variables

For each OS, copy the example vars and set your values:

```bash
cp packer/ubuntu-noble/vars.example.pkrvars.hcl packer/ubuntu-noble/vars.dev.pkrvars.hcl
cp packer/oracle8/vars.example.pkrvars.hcl packer/oracle8/vars.dev.pkrvars.hcl
cp packer/oracle9/vars.example.pkrvars.hcl packer/oracle9/vars.dev.pkrvars.hcl
```

For new environments, `make env-template` can generate these files automatically:

```bash
make env-template ENVIRONMENT=qa TEMPLATE_ENV=dev PROXMOX_HOST=<pve-ip> PROXMOX_NODE=<pve-node>
```

Required values:

- `proxmox_node` (your Proxmox node name)
- `clone_vm_id` (base VMID)
- `vm_id` (template VMID to create)
- `template_name` (template name, should match the Terraform `clone_template` / `os_profiles` values you use for that environment)

Default reserved mapping used by the repo (and by `make env-template` scaffolding):

- Oracle 9: `clone_vm_id=999999990`, `vm_id=999999993`, `template_name="oracle9"`
- Oracle 8: `clone_vm_id=999999991`, `vm_id=999999994`, `template_name="oracle8"`
- Ubuntu 24.04: `clone_vm_id=999999992`, `vm_id=999999995`, `template_name="ubuntu2404"`

Credential behavior for Packer build/destroy:

- Default (`PACKER_USE_VAULT_CREDS=true`): `proxmox_api_url`, `proxmox_token_id`, and `proxmox_token` are read from the environment Vault path `<vault_kv_mount_path>/<vault_secret_prefix>/<env>/creds` (default `secret/terraform/<env>/creds`).
- Optional fallback (`PACKER_USE_VAULT_CREDS=false`): provide `proxmox_api_url`, `proxmox_token_id`, and `proxmox_token` in `vars.<env>.pkrvars.hcl`.

The templates use `ssh_timeout = 20m` and `task_timeout = 15m`. Increase either if first-boot cloud-init or Proxmox storage is slow. Packer authenticates as `ansible` with `ssh_private_key_file` (default `~/.ssh/id_rsa`). The builder's first boot installs the matching public key, then template-base finalization removes the bootstrap-only `cicustom` attachment and snippet while preserving the provisioned account/key in the stopped base disk.

Before each clone, Make resolves `clone_vm_id`, `vm_id`, `proxmox_node`,
`ssh_username`, and `ssh_private_key_file` through `packer console`, and derives
the public key from that selected private key. It then uses
`scripts/packer-cloudinit-guard.sh` to attach a unique, mode-`0600` temporary
`users:`-list cloud-config snippet to the stopped source VM. This avoids the
deprecated scalar `user` generated by Proxmox when the Packer plugin supplies
its temporary `ciuser` and `sshkeys`. One exit trap removes both the Vault
override and the owned cloud-init attachment/snippet on success or failure.
Successful builds additionally fail unless the result is a stopped template
with no `cicustom`, cloud-init drive, `ciuser`, `sshkeys`, DNS, or temporary
network fields. A pre-existing target VMID or a foreign `cicustom` attachment
is never replaced by this guard.

Make defaults `PACKER_ON_ERROR=cleanup`. For a bounded diagnostic that must
preserve the failed build VM, use `PACKER_ON_ERROR=abort`; inspect and remove
that reserved build VM before retrying. The target accepts only `cleanup`,
`abort`, or `run-cleanup-provisioner`, and its Vault override remains a trapped
mode-`0600` temporary file in every mode. `abort` preserves the failed VM for
diagnosis but still detaches the owned snippet, so the source and failed target
cannot retain a reference to a deleted temporary file.

Base-VM Zabbix passive targets must be comma-separated IPv4 addresses or CIDRs.
The builder rejects invalid sources before VM creation, removes the legacy broad
Agent 2 port rule, and configures TCP/10050 only from those sources through the
guest's firewalld, UFW, or iptables path. Firewalld is verified live; an
inactive UFW installation is verified through its exact persisted rule set and
left inactive for the environment policy to activate. Environment monitoring
roles still reconcile and verify the final runtime firewall policy after
cloning.
Ubuntu bases install the NFS client (`nfs-common`) only; an NFS server is a
service-level decision and is not enabled in every clone.

## 7. Build Packer Templates

```bash
make packer-build-all ENVIRONMENT=dev
make packer-build-ubuntu2404 ENVIRONMENT=dev
make packer-build-oracle8 ENVIRONMENT=dev
make packer-build-oracle9 ENVIRONMENT=dev
```

By default, each build pulls current Proxmox API credentials from Vault, so key/token rotation is automatically picked up.
You can override the Vault path if needed, for example:

```bash
make packer-build-ubuntu2404 ENVIRONMENT=dev PACKER_VAULT_PATH=kv-team/platform/dev/creds
```

With the committed defaults, these generate templates named `ubuntu2404`, `oracle8`, and `oracle9`, which Terraform clones through OS profiles.

When `cloudinit_first_access_ssh_public_key` is non-empty, Terraform renders a
mode-`0600` `<environment>-<vmid>-<name>-first-access-user.yaml` file for each
managed VM. Each file declares the VM hostname and FQDN, disables distro FQDN
preference, manages the hosts file, and supplies the configured
`cloudinit_first_access_user` and public key list. Generated VM
`cicustom` values compose the matching `user=` file with any generated
partitioning `vendor=` file. Per-VM user-data is required because PVE emits
only an `instance-id` in NoCloud metadata when custom user-data is attached;
without the hostname in primary user-data, a clone retains its Packer source
hostname. Oracle cloud-init also prefers the FQDN, so omitting an explicit
`fqdn` makes it select that same datasource fallback. This keeps first access
key-only and avoids Proxmox's deprecated
scalar `user` cloud-config. Explicit per-VM `cicustom` remains authoritative
and is not rewritten. Use `make snippets`/`make apply` so every referenced file
is uploaded before a VM's first boot, then require the guest hostname to match
the Terraform VM name.

## 8. Configure Terraform Environment

Update `environments/<env>.tfvars`:

- `environments/dev.tfvars` is the only committed environment seed and defines the current 18-node service, CI/CD, and Kubernetes topology used to scaffold other environments.
- `target_node` should match the Proxmox node name.
- `storage_pool` should match your root/template storage.
- `data_disk_defaults.storage` should match the data-disk pool (e.g., `local-lvm`).
- Use per-VM `vm_disk_storage` when you want specific VMs on different VM-disk pools (root/cloud-init and default data-disk fallback).
- Define your `node_groups` and per-VM settings.
- Use per-VM `monitoring_enabled` to control membership in the generated
  `monitoring_clients` group. `monitoring_profile` defaults to the node-group
  name, while `monitoring_expected_up` defaults from the resolved desired power
  state when it is not set explicitly.

Example node group for Oracle DB (single large data disk, `/u01` fixed, `/u02` auto-grow):

```hcl
node_groups = {
  "database19c" = {
    "database19c-dot82" = {
      vmid      = 10002
      name      = "public-database19c-01"
      ipconfig0 = "ip=203.0.113.0/24,gw=198.51.100.19"
      cores     = 8
      memory    = 10240
      disk_size = "50G"
      vm_disk_storage = "local-zfs" # Optional per-VM VM-disk pool override
      data_disk = { size = "1000G" }
      partitioning = {
        enabled     = true
        disk_device = "/dev/vda"
        vg_name     = "vgdata"
        mounts      = [
          { mount = "/u01",  size_gb = "100", owner = "root", group = "root" },
          { mount = "/u02",  size_gb = "AUTO", owner = "root", group = "root" }
        ]
      }
    }
  }
}
```

Notes on `disk_device`:

- If the OS disk is `scsi0` (default), the data disk attached on `virtio1` is often `/dev/vda`.
- If your OS disk is virtio, the data disk may be `/dev/vdb`.
- Use `lsblk` on a VM to confirm the correct device.

First-access SSH key (recommended):

```hcl
cloudinit_first_access_user           = "ansible"
cloudinit_first_access_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGeneratedForPublicDocs sanitized@example.invalid
```

Multiple keys (laptop + ansible server):

```hcl
cloudinit_first_access_ssh_public_key = <<-EOKEYS
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGeneratedForPublicDocs sanitized@example.invalid
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGeneratedForPublicDocs sanitized@example.invalid
EOKEYS
```

Behavior:

- If `cloudinit_first_access_ssh_public_key` is set, Terraform injects these key(s) into every cloned VM.
- If it is empty, clone auth is inherited from the source template.
- The base image script (`scripts/create-cloudinit-vm_stable.sh`) currently takes the first key from `/root/.ssh/authorized_keys` on the Proxmox host when building the base VM.

## 9. Render and Upload Partitioning Snippets

```bash
make snippets ENVIRONMENT=dev
```

This renders `snippets/<env>-<vmid>-<vmname>-partitioning.yaml` and uploads to the Proxmox storage defined by `snippet_storage` in `environments/<env>.tfvars` (default `local`).

Both `*-partitioning.yaml` and `*-first-access-user.yaml` are generated local
Terraform artifacts and are ignored by Git. Do not hand-edit, commit, or
manually purge snippets for declared VMs. Terraform creates and removes them
with their `local_file` resources; delete only a proven orphan that no longer
exists in the authoritative environment model.

Example in `environments/<env>.tfvars`:

```hcl
storage_pool    = "local-lvm"
snippet_storage = "local"
```

Host resolution for snippet upload:

1. `PROXMOX_HOST` in the environment
2. `.env` (`PROXMOX_HOST` or `PROXMOX_HOST_<ENV>`)
3. Vault `<vault_kv_mount_path>/<vault_secret_prefix>/<env>/creds` (`proxmox_config_api_url`; default `secret/terraform/<env>/creds`)
4. Packer `vars.<env>.pkrvars.hcl`
5. If unresolved, command exits with an explicit error (no hardcoded host fallback)

Environment-name note:

- Hyphenated environments are normalized for env-var lookup, so `ENVIRONMENT=qa-west` maps to `PROXMOX_HOST_QA_WEST`.
- Vault lookup derives its path from `vault_kv_mount_path` and `vault_secret_prefix` in `environments/<env>.tfvars`; it is not hardcoded to `secret/terraform/<env>/creds`.

Override defaults in `.env` if needed:

```bash
PROXMOX_USER=root
PROXMOX_HOST_DEV=198.51.100.12
PROXMOX_HOST_PROD=198.51.100.11
PROXMOX_HOST_TESTING=198.51.100.13
# Additional environments:
# PROXMOX_HOST_QA=198.51.100.14
# PROXMOX_NODE_QA=proxmox
# ANSIBLE_HOST_QA=198.51.100.15
# NETWORK_CIDR_QA=192.0.2.0/24
# NETWORK_GW_QA=198.51.100.16
# STORAGE_POOL_QA=local-lvm
# DATA_STORAGE_QA=local-lvm
AUTO_DISCOVER=true
```

If you change partitioning, re-run `make snippets` and re-run cloud-init on the VM:

```bash
sudo cloud-init clean --logs
sudo rm -f /var/local/partitioning.done
sudo reboot
```

## 10. Deploy Infrastructure

```bash
make deploy ENVIRONMENT=dev
```

The deploy target runs `fmt`, `init`, `validate`, workspace setup, `plan`, and `apply`.
For security/lint onboarding, run `make tf_scan` before `make deploy`.

Ansible inventory is generated at:

- `../inventories/<env>/inventory.ini`

`main.tf` is the sole inventory renderer. Each host line includes its resolved
backup and monitoring policy, and enabled hosts are added to the exact
`monitoring_clients` group consumed by the unified monitoring playbook. The
deployment summary contains the same monitoring policy map for review.

Common Terraform outputs after apply:

```bash
terraform output all_vm_names
terraform output all_vm_ips
terraform output all_vm_host_ips
terraform output -json connection_info
```

- `all_vm_ips`: raw `ipconfig0` strings.
- `all_vm_host_ips`: parsed host IPs (without CIDR/gateway).
- `connection_info.group_host_ips`: host IP map keyed by node group.

## 11. Verify Partitioning on VMs

Use the included verification script on each VM:

```bash
./verify-partitioning.sh
```

Script location in this repo:

- `terraform-proxmox/scripts/verify-partitioning.sh`

It checks block devices, LVM, fstab, mountpoints, and the marker file `/var/local/partitioning.done`.

## 12. Onboard a New Environment

You can now scaffold and bootstrap a brand-new environment name (for example `qa`) with `make`.
The repository keeps a single committed env seed (`environments/dev.tfvars`); additional env tfvars are scaffolded locally.

Important before first bootstrap on a fresh control node:

- Ensure `terraform-proxmox/.env` already has Vault connectivity/auth (`VAULT_ADDR` and either `VAULT_TOKEN` or AppRole values).
- `make env-template` writes env-scoped Proxmox keys (for example `PROXMOX_HOST_<ENV>`) but does not populate Vault auth values.
- If `VAULT_ADDR` is missing, `make env-bootstrap` will stop at `make rotate-proxmox-creds` with `Error: VAULT_ADDR is not set.`

Quick baseline:

```bash
cd terraform-proxmox
cp .env.example .env
chmod 600 .env
# Edit .env with real Vault/auth values before running env-bootstrap.
```

### 12.1 Auto-Discover Core Settings and Generate Template

From `terraform-proxmox/`:

```bash
# Optional: inspect discovered values first
make env-discover ENVIRONMENT=qa PROXMOX_HOST=198.51.100.14

# Scaffold using discovery (default AUTO_DISCOVER=true)
make env-template \
  ENVIRONMENT=qa \
  TEMPLATE_ENV=dev \
  PROXMOX_HOST=198.51.100.14 \
  AUTO_DISCOVER=true
```

If files already exist and you want to regenerate, use:

```bash
make env-template ENVIRONMENT=qa TEMPLATE_ENV=dev ENV_TEMPLATE_FORCE=true
```

This generates:

- `environments/qa.tfvars`
- `environments/qa.bootstrap.env`
- `environments/qa.autodiscover.env`
- `packer/ubuntu-noble/vars.qa.pkrvars.hcl`
- `packer/oracle8/vars.qa.pkrvars.hcl`
- `packer/oracle9/vars.qa.pkrvars.hcl`

Scaffolded Packer vars are normalized to the reserved template policy:

- Base/source VMIDs: `999999990` (oracle9), `999999991` (oracle8), `999999992` (ubuntu2404)
- Template VMIDs: `999999993` (`oracle9`), `999999994` (`oracle8`), `999999995` (`ubuntu2404`)

Auto-discovery fills and persists values such as:

- Proxmox node name (`target_node`, `proxmox_node`)
- storage selections (`storage_pool`, `data_disk_defaults.storage`, base-VM storages)
- all VM-disk capable pools on the host (`DISCOVERED_VMDISK_STORAGES`, comma-separated)
- network bridge and gateway defaults
- local source IP (used as `ANSIBLE_HOST_<ENV>` when not set explicitly)

It also writes env-scoped keys into `.env` (for example `PROXMOX_HOST_QA=...`).

### 12.2 Review and Edit Before Provisioning

Review these files and adjust values for your new stack:

- `environments/qa.tfvars` (VMIDs, node groups, storage, IPs)
- `packer/*/vars.qa.pkrvars.hcl` (`proxmox_node`, VM/template IDs)
- `environments/qa.bootstrap.env` (host/network/base-VM defaults)
- `environments/qa.autodiscover.env` (captured discovery snapshot)

Preflight checklist (recommended before first `plan`/`apply`):

1. Update first-access SSH keys in `environments/<env>.tfvars`.
   - Set `cloudinit_first_access_user` and `cloudinit_first_access_ssh_public_key` to include all required public keys (for example laptop + automation/Ansible host).
   - Ensure your Ansible run uses the matching private key for those injected keys.
2. Confirm Terraform clone template names match what exists on the target Proxmox.
   - Defaults come from `os_profiles` / per-VM `clone_template`.
   - If your Packer vars override the committed `oracle8`, `oracle9`, or `ubuntu2404` names, keep Terraform aligned with those exact overrides.
   - If your templates are named differently, set per-VM `clone_template` in `node_groups` or override `os_profiles` in `environments/<env>.tfvars`.
   - Verify existing templates with `ssh root@<pve-ip> "qm list"`.
3. Confirm target VMIDs are free on that Proxmox node before apply.
   - Example: `ssh root@<pve-ip> "qm list"`.
4. Confirm Vault is reachable/unsealed and env credentials exist.
   - Verify `.env` contains Vault settings (`VAULT_ADDR` + token/AppRole) before running `env-bootstrap`.
   - Run `make vault-login`.
   - Run `make rotate-proxmox-creds ENVIRONMENT=<env>` to seed `<vault_kv_mount_path>/<vault_secret_prefix>/<env>/creds` (default `secret/terraform/<env>/creds`).
5. Confirm snippet storage supports `snippets`.
   - Keep `snippet_storage` aligned with a storage that supports snippets (for example `local` on many installs).
   - Verify on Proxmox: `pvesm status --content snippets`.
6. Use per-VM disk pool overrides if needed to avoid filling one pool.
   - Set `vm_disk_storage = "<pool>"` per VM for root/cloud-init placement (and default data disk unless `data_disk.storage` is set).
   - Use discovered options from `DISCOVERED_VMDISK_STORAGES` in `environments/<env>.autodiscover.env`.
7. Confirm the Proxmox node vCPU cap for cloned VMs, then set Packer build CPU accordingly.
   - If the node enforces a limit (for example `MAX 6 vcpus allowed per VM on this node`), set `cpu_cores = 6` in:
     - `packer/ubuntu-noble/vars.<env>.pkrvars.hcl`
     - `packer/oracle8/vars.<env>.pkrvars.hcl`
     - `packer/oracle9/vars.<env>.pkrvars.hcl`

If you need a specific VM IP window, edit `ipconfig0` entries in `environments/<env>.tfvars`.
Also verify `snippet_storage` matches a storage that supports `snippets` on the target Proxmox.
Example for `198.51.100.20-130`:

- `ip=192.0.2.0/24,gw=198.51.100.21`
- `ip=198.51.100.0/24,gw=198.51.100.21`
- `ip=203.0.113.0/24,gw=198.51.100.21`
- `ip=192.0.2.0/24,gw=198.51.100.21`
- `ip=198.51.100.0/24,gw=198.51.100.21`

If you already have base/source VMs for Packer, set `clone_vm_id` in each env Packer vars file:

```hcl
# packer/oracle8/vars.<env>.pkrvars.hcl
clone_vm_id = 999999991

# packer/oracle9/vars.<env>.pkrvars.hcl
clone_vm_id = 999999990

# packer/ubuntu-noble/vars.<env>.pkrvars.hcl
clone_vm_id = 999999992
```

Concrete example (dev-like stack on `198.51.100.13` with IPs `198.51.100.20-130`):

```bash
make env-template ENVIRONMENT=testing TEMPLATE_ENV=dev PROXMOX_HOST=198.51.100.13 ENV_TEMPLATE_FORCE=true

# Edit environments/testing.tfvars:
# - ipconfig0 values to 198.51.100.20-129
# - cloudinit_first_access_ssh_public_key with required public keys
# - clone_template values (or os_profiles override) if template names differ on Proxmox
# Edit packer/*/vars.testing.pkrvars.hcl clone_vm_id values to 999999991/999999990/999999992
# If Proxmox enforces per-VM vCPU caps, set packer cpu_cores accordingly (for example cpu_cores=6)

make vault-login
make rotate-proxmox-creds ENVIRONMENT=testing
make workspace-create ENVIRONMENT=testing
make plan ENVIRONMENT=testing
```

Concrete example (`example` cloned from the tracked `dev` scaffold, subnet `203.0.113.0/24`, Proxmox host `198.51.100.22`, control node `198.51.100.23`):

```bash
make env-discover ENVIRONMENT=example PROXMOX_HOST=198.51.100.22

make env-template \
  ENVIRONMENT=example \
  TEMPLATE_ENV=dev \
  PROXMOX_HOST=198.51.100.22 \
  PROXMOX_NODE=proxmox \
  ANSIBLE_HOST=198.51.100.23 \
  NETWORK_CIDR=203.0.113.0/24 \
  NETWORK_GW=198.51.100.18 \
  AUTO_DISCOVER=true \
  ENV_TEMPLATE_FORCE=true

# Then review environments/example.tfvars and adjust env-specific values:
# - cluster_name = "public-stack"
# - vault_approle_*_bound_cidrs include 203.0.113.0/24
# - ipconfig0 entries stay in 203.0.113.0/24

make env-bootstrap ENVIRONMENT=example
# If bootstrap reaches plan successfully, deploy:
make apply ENVIRONMENT=example
```

If discovery picked values you want to override, pass them explicitly:

```bash
make env-template ENVIRONMENT=qa PROXMOX_HOST=198.51.100.14 \
  PROXMOX_NODE=proxmox STORAGE_POOL=local-zfs DATA_STORAGE=local-lvm \
  NETWORK_CIDR=192.0.2.0/24 NETWORK_GW=198.51.100.16 ENV_TEMPLATE_FORCE=true
```

### 12.3 Bootstrap End-to-End Until Plan

```bash
make env-bootstrap ENVIRONMENT=qa
```

`env-bootstrap` automatically loads `environments/<env>.bootstrap.env` when present, so manual `source` is no longer required.

What `make env-bootstrap` does:

1. Scaffolds files (if `environments/<env>.tfvars` does not already exist).
2. Loads `environments/<env>.bootstrap.env` defaults (if present).
3. Configures key-based SSH from this machine to Proxmox root.
4. Creates/selects Terraform workspace `<env>`.
5. Rotates Proxmox API token and writes Vault secret `<vault_kv_mount_path>/<vault_secret_prefix>/<env>/creds` (default `secret/terraform/<env>/creds`).
6. Builds base VM(s) on Proxmox remotely (reserved VMIDs `999999990-999999992`; Ubuntu by default).
7. Syncs checksum-verified cloud images on Proxmox into `/var/lib/vz/template/iso` when `AUTO_DOWNLOAD_IMAGE=true`:
   - default bootstrap path: `ubuntu24`
   - adds `oracle8` and `oracle9` when `BASE_VM_BUILD_ORACLE=true`
   - standalone helper support also exists for `ubuntu22`, `debian12`, `rocky9`, `alma9`, and `fedora43`
8. Runs Packer build(s) for `<env>` (Ubuntu by default).
9. Renders/uploads snippets.
10. Runs `make plan ENVIRONMENT=<env>`.

Optional Oracle base/template build:

```bash
make env-bootstrap ENVIRONMENT=qa BASE_VM_BUILD_ORACLE=true
```

If you want to require pre-seeded images (no automatic download/sync on Proxmox):

```bash
make env-bootstrap ENVIRONMENT=qa AUTO_DOWNLOAD_IMAGE=false
```

If base VMs already exist and you want to skip remote base-VM provisioning:

```bash
make env-bootstrap ENVIRONMENT=qa SKIP_BASE_VM_SETUP=true
```

### 12.4 Apply

```bash
make apply ENVIRONMENT=qa
# or
make env-bootstrap-apply ENVIRONMENT=qa
```

`make apply` runs:

1. `make snippets ENVIRONMENT=<env>`
2. `make plan ENVIRONMENT=<env>`
3. `terraform apply plans/<env>.tfplan`

Notes:

- `workspace-select` does not make Terraform workspace `default`; it selects your env workspace (`qa`, `prod`, etc.). `is_default_workspace=false` is expected outside the literal `default` workspace.
- Vault must be reachable/unsealed and token precedence must be clean (`secrets.auto.tfvars` must not pin a stale `vault_token`).
- If `manage_vault_access=true`, Terraform operations that reconcile Vault governance require an admin-capable token.

## Architecture and Concepts

### Project Structure

```text
.
├── environments/           # Environment-specific variables (*.tfvars)
├── logs/                   # Centralized execution & provider logs (terraform-plugin-proxmox-<env>.log, init, plan, apply)
├── modules/
│   └── proxmox-vm/         # Core QEMU VM provisioning logic
├── packer/                 # Packer templates for Proxmox VM images
├── plans/                  # Compiled Terraform plans (.tfplan)
├── summaries/              # Deployment JSON summaries
├── snippets/               # Cloud-init snippets (generated)
├── backups/                # State and artifact backup archives
├── scripts/                # Setup and automation utilities
├── templates/              # Cloud-init and environment templates
├── Makefile                # Unified entry point
└── main.tf                 # Root module
```

### OS Profiles and Auto-Selection

Default OS profiles (can be overridden in `.tfvars`):

```hcl
os_profiles = {
  oracle8    = { clone_template = "oracle8",    fs_type = "xfs",  ansible_python_interpreter = "/usr/bin/python3.9" }
  oracle9    = { clone_template = "oracle9",    fs_type = "xfs",  ansible_python_interpreter = "/usr/bin/python3" }
  ubuntu2404 = { clone_template = "ubuntu2404", fs_type = "ext4", ansible_python_interpreter = "/usr/bin/python3" }
}

group_os_profile = {
  database19c = "oracle8"
  database21c = "oracle8"
  weblogic12c = "oracle8"
  weblogic14c = "oracle9"
  zimbra      = "oracle9"
}
```

> **Note:** `oracle8` targets use `/usr/bin/python3.9` from the AppStream `python39` package to support modern `ansible-core 2.17+` controllers without altering the underlying OS platform Python.

Automatic inference is used when a group is not in `group_os_profile`:

- `weblogic14*` or `oracle9*` -> `oracle9`
- `weblogic12*`, `database*`, `oracledb*`, `oracle*` -> `oracle8`
- anything else -> `default_os_profile` (default `ubuntu2404`)

Per-VM overrides:

- `os_profile = "oracle9"`
- `clone_template = "custom-template"`
- `vm_disk_storage = "local-zfs"` (VM disk pool override for that VM)

If your Packer vars use different template VM names, keep `os_profiles` or per-VM `clone_template` aligned with those actual Proxmox template names.

If you want ext4 on Oracle data disks, set `partitioning.fs_type = "ext4"` or override `os_profiles` in your `.tfvars`.

### Partitioning (Data Disk Only)

Partitioning is always applied to the data disk, not the OS/root disk.

Rules:

- `partitioning.enabled = true` requires a data disk (`data_disk` or `additional_disks`).
- Only one mount can use `size_gb = "AUTO"`.
- Snippets install `lvm2` and `parted` if missing.
- Recommended for Oracle DB nodes: use a large data disk (for example `1000G`) with `/u01=100G` and `/u02=AUTO`.
- Keep database files under `/u02/oradata/<CDB>/<PDB>/...` so growth is centralized on one LVM-backed mount.
- To expand later, increase `data_disk.size` in `environments/<env>.tfvars` and apply (or use `qm resize`), then extend the PV/LV/filesystem in-guest.

## Makefile Targets (Common)

The outcome-based command map at the beginning of this guide is the preferred
operator interface. This list is a compact index; run `make help` for the
current target descriptions and defaults.

- `make setup-tools`
- `make check-tools`
- `make docs-terraform`
- `make env-discover ENVIRONMENT=<env> PROXMOX_HOST=<ip>`
- `make env-template ENVIRONMENT=<env> TEMPLATE_ENV=dev PROXMOX_HOST=<ip> AUTO_DISCOVER=true`
- `make env-ssh-access ENVIRONMENT=<env>`
- `make env-cloud-images ENVIRONMENT=<env>`
- `make env-cloud-images ENVIRONMENT=<env> CLOUD_IMAGES=all`
- `make env-base-vms ENVIRONMENT=<env>`
- `make env-base-vms ENVIRONMENT=<env> BASE_VM_BUILD_ORACLE=true BASE_VM_IPCIDR=<ip/prefix> BASE_VM_GATEWAY=<gateway>`
- `make env-bootstrap ENVIRONMENT=<env>`
- `make env-bootstrap-apply ENVIRONMENT=<env>`
- `make deploy ENVIRONMENT=dev`
- `make plan ENVIRONMENT=dev`
- `make apply ENVIRONMENT=dev`
- `make vault-login`
- `make rotate-proxmox-creds ENVIRONMENT=dev`
- `make render-snippets ENVIRONMENT=dev`
- `make upload-snippets ENVIRONMENT=dev`
- `make snippets ENVIRONMENT=dev`
- `make packer-build-all ENVIRONMENT=dev`
- `make packer-build-ubuntu2404 ENVIRONMENT=dev`
- `make packer-build-oracle8 ENVIRONMENT=dev`
- `make packer-build-oracle9 ENVIRONMENT=dev`
- `make packer-destroy-all ENVIRONMENT=dev` (requires `red alert <env>` and then `packer-destroy-all <env>`)
- `../scripts/verify-resources.sh` (installer checksum governance; not a Make target)
- `make vault-runtime-verify ENVIRONMENT=dev`
- `make vault-approle-refresh ENVIRONMENT=dev` (requires an admin-capable token)
- `make vault-audit-check`
- `make vault-audit-enable-file CONFIRM=ENABLE_AUDIT`
- `make backup ENVIRONMENT=dev`
- `make backup-jobs ENVIRONMENT=dev DRY_RUN=true`
- `make backup-jobs ENVIRONMENT=dev CONFIRM=YES`
- `make backup-vms ENVIRONMENT=dev BACKUP_VMIDS=<vmid> CONFIRM=YES`
- `make backup-vms ENVIRONMENT=dev BACKUP_VMIDS=<vmid> PROTECTED=true CONFIRM=YES` (final decommission archive only)
- `make verify-backups ENVIRONMENT=dev`
- `make restore-drill ENVIRONMENT=dev SOURCE_VMID=<vmid> RESTORE_VMID=999999980 RESTORE_STORAGE=<storage> CONFIRM=YES`
- `make destroy-workloads ENVIRONMENT=dev`
- `make destroy-governance ENVIRONMENT=dev` (requires separate review and `prevent_destroy` removal)
- `make clean` (generated artifacts; retained backups and `logs/acceptance/` are preserved)
- `make clean-backups CONFIRM=DELETE_BACKUPS` (explicitly delete retained state archives)
- `make clean-all` (local artifacts + state; retained backups are preserved)

VM backup behavior is declared in `backup_defaults` plus per-VM `backup` and
`backup_storage` values. `backup-jobs` creates one PVE schedule per resolved
backup datastore and applies the configured PVE retention expression. The
Terraform input model rejects backup-enabled VMs without a resolved datastore
and retention policies that keep no archives. The
one-shot and freshness commands use the same Terraform outputs, so the disk
backup flags, schedule, storage destination, and verification set cannot drift
silently. Restores are restricted to VMIDs `999999980-999999989` and remain
stopped because a restored guest retains the source hostname and static IP.
Freshness and restore selection accept only non-empty completed `.vma`, `.vma.gz`,
`.vma.lzo`, or `.vma.zst` archives; PVE `.notes` sidecars and in-progress
`.vma.dat` files are ignored.
An active `vzdump` owns the VM's `backup` lock. Wait for it to finish before
starting the guest or running configuration; do not manually clear the lock.

`make backup` pulls remote workspace state (`terraform state pull`) and archives
it with related environment artifacts. It is a prerequisite of destroy targets.
Archives and SHA-256 sidecars are mode `0600`, kept for 30 days with at least
the newest five preserved, and are not removed by routine `make clean`.
`STATE_BACKUP_RETENTION_DAYS` and `STATE_BACKUP_KEEP_MIN` configure those two
limits; the minimum set is retained even after it exceeds the age limit.

`make destroy-workloads` removes the environment workload VMs plus generated
local Terraform files and deliberately retains the shared Vault KV mount,
policy, AppRole backend, and AppRole role. It requires two prompts: first the
red-alert phrase `red alert <env>`, then `destroy-workloads <env>`.

`make destroy-governance` targets only the Vault governance module. It is a
separate endpoint because deleting governance can remove the credential source,
break Terraform/Packer auth, invalidate AppRole logins, and damage shared Vault
mounts. The target still respects Terraform `prevent_destroy`; actually
removing those resources requires a separate reviewed lifecycle change and
recovery plan. It requires two prompts: first the red-alert phrase
`red alert <env>`, then `destroy-governance <env>`.

PVE-protected backups are exempt from pruning and therefore require a separate
operator review. Use `PROTECTED=true` only for the documented final
decommission hold, then unprotect or delete the archive after that hold expires.

## Repo Hygiene

- `.env` and `secrets.auto.tfvars` hold secrets and should remain uncommitted.
- Packer `vars.<env>.pkrvars.hcl` files are ignored by git.
- `environments/dev.tfvars` is the only committed env seed; scaffolded `environments/<env>.tfvars` and generated `environments/*.bootstrap.env` / `environments/*.autodiscover.env` stay local and should not be staged.
- Installer integrity is enforced by `../scripts/verify-resources.sh` using
  `../ansible/resources.sha256`; only the two exact Oracle patch archives listed
  in `resources-checksum-exceptions.txt` are exempted.

## Troubleshooting

Issue: Partitioning did not apply and `/var/local/partitioning.done` is missing.
Fix: Re-run cloud-init and reboot:

```bash
sudo cloud-init clean --logs
sudo rm -f /var/local/partitioning.done
sudo reboot
```

Issue: `Disk /dev/vda not found` in the partitioning log.
Fix: Confirm the data disk device with `lsblk` and update `partitioning.disk_device` to match (`/dev/vda` or `/dev/vdb`). Re-run `make snippets` and cloud-init.

Issue: Packer build times out or fails to clone.
Fix: Ensure the base VM is shut down and increase `task_timeout` in `packer/*/*.pkr.hcl` (default is `15m`).

Issue: Packer fails with `MAX <n> vcpus allowed per VM on this node`.
Fix: Set `cpu_cores` in `packer/*/vars.<env>.pkrvars.hcl` to a compliant value (for example `cpu_cores = 6`), then rerun the build.

Issue: Proxmox API auth errors in Terraform or Packer.
Fix: Re-run `scripts/create-proxmox-api-user.sh` on the Proxmox host, then update `vault kv put <vault_kv_mount_path>/<vault_secret_prefix>/<env>/creds` with the new token (default `secret/terraform/<env>/creds`).

Issue: `make vault-mode-verify` fails with `No value found at secret/data/terraform/<env>/creds`.
Fix: Seed or rotate environment credentials:

```bash
make rotate-proxmox-creds ENVIRONMENT=<env>
vault kv get <vault_kv_mount_path>/<vault_secret_prefix>/<env>/creds
```

Issue: Vault unseal fails with `invalid key` / `cipher: message authentication failed`.
Fix: The current raft data does not match the key in `~/.vault-recovery/latest`.

1. Try unseal keys from older bundles under `~/.vault-recovery/*/unseal-keys.txt`.
2. If one works, use root token from the same bundle and repoint `~/.vault-recovery/latest` to that bundle.
3. If none work, run destructive recovery: `make vault-reinit CONFIRM=YES`, then re-seed secrets (for example `make rotate-proxmox-creds ENVIRONMENT=<env>`).

Issue: `terraform plan` fails with Vault `403 permission denied` / `invalid token` after reinit or token rotation.
Fix: Remove stale `vault_token` from `secrets.auto.tfvars` (or update it), because it overrides `.env` token values:

```hcl
# keep this
vault_address = "https://<vault-ip>:8200"

# remove or keep updated if intentionally pinned
# vault_token = "..."
```

Issue: `make vault-bootstrap` fails with missing `sys/mounts`, `sys/policies/acl`, or `sys/auth` capabilities.
Fix: provide an admin-capable `VAULT_TOKEN` (and optionally `TF_VAR_vault_token`) before rerunning bootstrap. AppRole runtime tokens are intentionally scoped and are not sufficient for governance apply/import actions.

Issue: `make plan` / `make apply` fails with `failed to create limited child token` and `POST ... /v1/auth/token/create ... permission denied` while using AppRole-only `.env`.
Fix: this is expected when `manage_vault_access=true` because Vault governance resources are in scope.

1. For governance runs, use an admin token (`VAULT_TOKEN` and `TF_VAR_vault_token`) and rerun.
   - One-off command without editing `.env`: `ROOT_TOKEN="$(tr -d '\n' < ~/.vault-recovery/latest/root-token.txt)"; VAULT_TOKEN="$ROOT_TOKEN" TF_VAR_vault_token="$ROOT_TOKEN" make apply ENVIRONMENT=<env>`
2. For full AppRole Terraform runs, set `vault_auth_mode="approle"` and `manage_vault_access=false` in `environments/<env>.tfvars`.
3. When switching auth modes, clear stale local token cache: `rm -f .vault-token`.

Issue: `make vault-bootstrap` fails with `Unable to Read Resource from Vault` and `Vault response was nil` (or creds path read failure after reinit).
Fix: seed Proxmox credentials first, then rerun bootstrap.

```bash
make rotate-proxmox-creds ENVIRONMENT=<env>
make vault-bootstrap ENVIRONMENT=<env>
```

Issue: `make vault-bootstrap` fails with `local_secret_ids can only be modified during role creation`.
Fix: current `make vault-bootstrap` auto-imports existing AppRole roles. If you hit this on an older checkout (or by running direct Terraform without bootstrap), import the role manually, then rerun bootstrap/apply.

```bash
cd terraform-proxmox
terraform import -var-file="environments/<env>.tfvars" \
  'module.vault_proxmox_access[0].vault_approle_auth_backend_role.terraform' \
  'auth/approle/role/terraform-proxmox'
```

Issue: `make rotate-proxmox-creds` fails with `check-and-set parameter required`.
Fix: this Vault path has CAS enforcement enabled and the token cannot read current version metadata/data. Grant read access on `<vault_kv_mount_path>/metadata/<vault_secret_prefix>/*` and `<vault_kv_mount_path>/data/<vault_secret_prefix>/*` (or use a token with equivalent access), then retry.

Issue: `make vault-mode-verify` (or mode switch commands) fails with `Terraform vault provider does not use var.vault_token.`
Fix: update to the latest `scripts/vault-mode-switch.sh`; current checks support conditional token expressions in provider config.

Issue: `make vault-reinit` fails with TLS trust errors (`x509: certificate signed by unknown authority` or `Error loading CA File`).
Fix: set valid TLS trust settings in `.env`, then rerun.

```bash
cd terraform-proxmox
cp .env.example .env 2>/dev/null || true
chmod 600 .env

# choose one:
# 1) trusted cert path (preferred)
export VAULT_CACERT=/etc/vault.d/vault-cert.pem

# or 2) lab fallback
# export VAULT_SKIP_VERIFY=true

make vault-reinit-dry-run
make vault-reinit CONFIRM=YES
```

The Vault helper scripts also auto-detect `/etc/vault.d/vault-cert.pem` and `/etc/vault.d/tls/vault-cert.pem` when TLS vars are unset.

Issue: `make vault-mode-lan-auto` fails with `Job for vault.service failed` / `start-limit-hit`.
Fix: reset failed state, start Vault, then rerun mode switch.

```bash
sudo systemctl reset-failed vault
sudo systemctl start vault
make vault-mode-lan-auto ENVIRONMENT=<env>
```

Issue: Snippet upload fails or goes to the wrong host.
Fix: Set `PROXMOX_HOST` or `PROXMOX_HOST_<ENV>` in `.env` and confirm SSH access to the Proxmox node.

Issue: Terraform apply fails with `volume '<storage>:snippets/<file>.yaml' does not exist`.
Fix: Ensure snippets are uploaded to the same storage referenced by Terraform:

1. Set `snippet_storage` in `environments/<env>.tfvars` to a storage that supports `snippets`.
2. Re-run `make snippets ENVIRONMENT=<env>` (or just re-run `make apply ENVIRONMENT=<env>`, which now runs snippets automatically).

Issue: Oracle base VM fails to boot after Packer build.
Fix: Ensure OS updates complete before shutdown and avoid background updates during image creation. Verify boot order is `scsi0`.

Issue: Terraform complains that partitioning requires a data disk.
Fix: Add `data_disk` or `additional_disks` for the VM, or enable `data_disk_defaults`.

Issue: Inventory not generated after apply.
Fix: Confirm `make apply ENVIRONMENT=<env>` completed successfully and check `../inventories/<env>/inventory.ini`.

Issue: VM clone is up but SSH key login fails (locked out).
Fix:

```bash
# Run on the Proxmox host
qm set <vmid> --ciuser ansible --sshkeys /root/.ssh/id_ed25519.pub
qm cloudinit update <vmid>
qm reboot <vmid>
```

If cloud-init has already completed and does not pick up the new key, use VM console and re-run cloud-init:

```bash
sudo cloud-init clean --logs
sudo reboot
```

## Support and Maintenance

Maintained by the DevOps team.
Last Updated: February 2026
Version: 3.4.0
