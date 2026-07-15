# Platform Architecture

## Primary Sources

- [README.md](../../README.md)
- [terraform-proxmox/Makefile](../../terraform-proxmox/Makefile)
- [terraform-proxmox/main.tf](../../terraform-proxmox/main.tf)
- [terraform-proxmox/templates/inventory.tpl](../../terraform-proxmox/templates/inventory.tpl)
- [inventories/aliases.ini](../../inventories/aliases.ini)
- [ansible/bootstrap_playbooks/README.md](../../ansible/bootstrap_playbooks/README.md)
- [ansible/user-man/README.md](../../ansible/user-man/README.md)
- [ansible/time_sync/README.md](../../ansible/time_sync/README.md)

## What This Repo Is

This monorepo is a layered automation platform with distinct ownership boundaries:

- `terraform-proxmox/` defines infrastructure state, workspace-aware environment scaffolding, snippet rendering, inventory generation, and Packer entrypoints.
- `inventories/` is the bridge between Terraform output and Ansible targeting.
- `ansible/bootstrap_playbooks/` holds service-specific automation for databases, middleware, identity, monitoring, and mail.
- `ansible/user-man/` and `ansible/time_sync/` are cross-cutting host baselines that sit underneath the service playbooks.
- The root and per-project READMEs explain operator entrypoints and conventions, while the Makefile and playbook `main.yml` files encode the executable flow.

## Layer Model

| Layer | Main repo locations | What it owns |
| --- | --- | --- |
| Operator and controller | `README.md`, per-project `.python-version`, `requirements*.txt` | local toolchain, pyenv runtime, local `.env` inputs |
| Secret and infrastructure control plane | `terraform-proxmox/`, Vault helper scripts | Vault auth, Proxmox API access, Terraform workspaces, Packer vars |
| Image and template substrate | `terraform-proxmox/scripts/`, `terraform-proxmox/packer/` | cloud images, base VMs, clone-based templates |
| Environment state model | `terraform-proxmox/environments/*.tfvars`, `terraform-proxmox/main.tf` | node groups, OS profiles, tags, networking, disks, snippets |
| Inventory bridge | `terraform-proxmox/templates/inventory.tpl`, `inventories/aliases.ini` | generated host map plus stable semantic groups |
| Host enablement | `ansible/user-man/`, `ansible/time_sync/` | account access, SSH baseline, sudo posture, Chrony baseline |
| Service bootstrap | `ansible/bootstrap_playbooks/*` | app, DB, identity, monitoring, and mail installation/configuration |
| Execution and verification | `terraform-proxmox/Makefile`, playbook `main.yml`, role `validate.yml` and `verify.yml` files | guardrails, prechecks, workflow entrypoints, generated logs and summaries |

## Architecture Diagram

```mermaid
flowchart LR
    subgraph Local[Operator and Control Node]
        A1[pyenv environments]
        A2[Local .env files]
        A3[Terraform, Packer, Ansible]
        A4[make targets and playbook entrypoints]
    end

    subgraph Secrets[Secret and API Control Plane]
        B1[Vault]
        B2[Proxmox API credentials]
    end

    subgraph Proxmox[Virtualization Substrate]
        C1[Cloud images]
        C2[Base VMs]
        C3[Packer templates]
        C4[Terraform-managed VMs]
        C5[Snippet storage]
    end

    subgraph Inventory[Inventory Layer]
        D1[Generated inventory.ini]
        D2[aliases.ini]
    end

    subgraph Automation[Ansible Projects]
        E1[user-man]
        E2[time_sync]
        E3[Oracle DB]
        E4[WebLogic]
        E5[FreeIPA]
        E6[Keycloak]
        E7[Observability]
        E8[Zabbix]
        E9[Zimbra]
    end

    A2 --> A3
    A3 --> B1
    B1 --> B2
    A3 --> C2
    C1 --> C2
    C2 --> C3
    C3 --> C4
    A3 --> C5
    A3 --> C4
    C4 --> D1
    D2 --> E1
    D2 --> E2
    D2 --> E3
    D2 --> E4
    D2 --> E5
    D2 --> E6
    D2 --> E7
    D2 --> E8
    D2 --> E9
    D1 --> E1
    D1 --> E2
    D1 --> E3
    D1 --> E4
    D1 --> E5
    D1 --> E6
    D1 --> E7
    D1 --> E8
    D1 --> E9
    A4 --> E1
    A4 --> E2
    A4 --> E3
    A4 --> E4
    A4 --> E5
```

## The Environment Model

`terraform-proxmox/main.tf` is the environment compiler. It flattens `node_groups`, resolves OS profiles, derives partitioning snippet paths, and emits inventory lines.

The result is:

- one Terraform workspace per environment
- one generated `inventories/<env>/inventory.ini`
- one static `inventories/aliases.ini` that maps logical playbook groups such as `oracle_servers`, `weblogic_servers`, `zimbra_servers`, `ntp_clients`, and `freeipa_clients`

The generated inventory carries:

- `ansible_user=ansible`
- `ansible_become=yes`
- environment tags
- an `[all_nodes]` group
- one group per Terraform `node_groups` key

That makes `inventory.ini` the runtime host map and `aliases.ini` the semantic grouping layer used by playbooks.

## Why Inventory Aliases Matter

The alias file is what allows:

- `oracle819c` and `oracle821c` to target `oracle_servers` children
- `time_sync` to define `ntp_servers` and `ntp_clients`
- `user-man` to deliberately target `all_nodes` and avoid alias-only controller hosts
- service projects to remain stable even if Terraform group composition changes

Without `aliases.ini`, the repo would have tightly coupled playbooks and environment-specific host names.

## Two Useful Ways to Read the Repo

1. Infrastructure path:
   environment tfvars -> base VMs -> Packer templates -> Terraform apply -> generated inventory.

2. Automation path:
   generated inventory + alias groups -> host enablement -> service playbooks -> role-level verification.

Both are valid views of the same codebase. The first explains how machines appear. The second explains how those machines become usable services.

## Architectural Limits of the Current Docs

The tracked files do not fully define:

- a full VLAN architecture
- HA cluster behavior for every service
- detailed capacity planning math
- one global orchestration script that drives every project

Those topics belong either in future work or in service-specific docs when the codebase grows them.
