# Enhanced Makefile for Root Module Pattern
# Terraform Proxmox infrastructure deployment with workspace-based environments

.PHONY: help setup setup-tools check-tools vault-login vault-bootstrap rotate-proxmox-creds env-discover env-template env-ssh-access env-cloud-images env-base-vm env-base-vm-ubuntu2404 env-base-vm-oracle8 env-base-vm-oracle9 env-base-vms env-bootstrap env-bootstrap-apply init validate fmt plan apply deploy destroy workspace-create workspace-select workspace-list create-dirs tf-security-scan tfsec tflint tf_scan render-snippets upload-snippets snippets packer-build packer-build-all packer-destroy-all vault-mode-status vault-mode-loopback vault-mode-lan vault-mode-lan-auto vault-mode-verify vault-unseal-help vault-tls-regenerate vault-reinit-dry-run vault-reinit vault-recovery-list clean clean-all clean-legacy-inventory check-env

# Default environment follows the currently selected Terraform workspace.
# Falls back to dev when workspace is unset or still "default".
CURRENT_WORKSPACE := $(shell terraform workspace show 2>/dev/null || true)
DEFAULT_ENVIRONMENT := $(if $(CURRENT_WORKSPACE),$(if $(filter default,$(CURRENT_WORKSPACE)),dev,$(CURRENT_WORKSPACE)),dev)
ENVIRONMENT ?= $(DEFAULT_ENVIRONMENT)
MAKEFILE_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

# Define colors for output
GREEN := \033[0;32m
YELLOW := \033[0;33m
RED := \033[0;31m
BLUE := \033[0;34m
CYAN := \033[0;36m
NC := \033[0m # No Color

TFSEC_MIN_SEVERITY ?= HIGH
TFLINT_MIN_FAILURE_SEVERITY ?= error
TF_INIT_UPGRADE ?= -upgrade

# Directory structure
DIRS := plans summaries logs backups snippets
PLAN_DIR := plans
INVENTORY_ROOT := $(abspath $(MAKEFILE_DIR)/../inventories)
INVENTORY_DIR := $(INVENTORY_ROOT)/$(ENVIRONMENT)
INVENTORY_FILE := $(INVENTORY_DIR)/inventory.ini
LEGACY_INVENTORY_DIR := $(abspath $(MAKEFILE_DIR)/inventories)
SUMMARY_DIR := summaries
LOG_DIR := logs
BACKUP_DIR := backups

# External dependencies
KUBESPRAY_DIR ?= $(HOME)/kubespray
RESOLVE_PROXMOX_HOST_SCRIPT ?= ./scripts/resolve-proxmox-host.sh
RESOLVE_ANSIBLE_HOST_SCRIPT ?= ./scripts/resolve-ansible-host.sh
DISCOVER_PROXMOX_CORE_SCRIPT ?= ./scripts/discover-proxmox-core.sh
SCAFFOLD_ENV_SCRIPT ?= ./scripts/scaffold-env.sh
PROXMOX_SSH_SETUP_SCRIPT ?= ./scripts/setup-proxmox-root-ssh.sh
REMOTE_BASE_VM_SCRIPT ?= ./scripts/create-base-vm-remote.sh

# Packer configuration
PACKER_DIR ?= packer/ubuntu-noble
PACKER_TEMPLATE ?= ubuntu-noble.pkr.hcl
PACKER_VARS ?= $(PACKER_DIR)/vars.$(ENVIRONMENT).pkrvars.hcl
PACKER_USE_VAULT_CREDS ?= true
PACKER_VAULT_RENDER_SCRIPT ?= ./scripts/render-packer-vault-vars.sh

TFVARS_FILE_FOR_ENV = environments/$(ENVIRONMENT).tfvars
VAULT_KV_MOUNT_PATH_FOR_ENV = $(if $(VAULT_KV_MOUNT_PATH),$(VAULT_KV_MOUNT_PATH),$(shell awk -F= '/^[[:space:]]*vault_kv_mount_path[[:space:]]*=/{val=$$2; sub(/[[:space:]]*(\/\/|#).*$$/,"",val); sub(/[[:space:]]*\/\*.*\*\/[[:space:]]*$$/,"",val); gsub(/^[[:space:]]+|[[:space:]]+$$/,"",val); sub(/^"/,"",val); sub(/"$$/,"",val); print val; exit}' "$(TFVARS_FILE_FOR_ENV)" 2>/dev/null || true))
VAULT_SECRET_PREFIX_FOR_ENV = $(if $(VAULT_SECRET_PREFIX),$(VAULT_SECRET_PREFIX),$(shell awk -F= '/^[[:space:]]*vault_secret_prefix[[:space:]]*=/{val=$$2; sub(/[[:space:]]*(\/\/|#).*$$/,"",val); sub(/[[:space:]]*\/\*.*\*\/[[:space:]]*$$/,"",val); gsub(/^[[:space:]]+|[[:space:]]+$$/,"",val); sub(/^"/,"",val); sub(/"$$/,"",val); print val; exit}' "$(TFVARS_FILE_FOR_ENV)" 2>/dev/null || true))
VAULT_KV_MOUNT_PATH_EFFECTIVE = $(if $(VAULT_KV_MOUNT_PATH_FOR_ENV),$(VAULT_KV_MOUNT_PATH_FOR_ENV),secret)
VAULT_SECRET_PREFIX_EFFECTIVE = $(if $(VAULT_SECRET_PREFIX_FOR_ENV),$(VAULT_SECRET_PREFIX_FOR_ENV),terraform)
VAULT_CREDS_PATH_FOR_ENV = $(VAULT_KV_MOUNT_PATH_EFFECTIVE)/$(VAULT_SECRET_PREFIX_EFFECTIVE)/$(ENVIRONMENT)/creds
PACKER_VAULT_PATH ?= $(VAULT_CREDS_PATH_FOR_ENV)

# Proxmox snippet upload defaults (override via .env if needed)
PROXMOX_USER ?= root
PROXMOX_HOST_FOR_ENV = $(if $(PROXMOX_HOST),$(PROXMOX_HOST),$(shell ENVIRONMENT="$(ENVIRONMENT)" REPO_ROOT="$(MAKEFILE_DIR)" ENV_FILE="$(ENV_FILE)" TFVARS_FILE="$(TFVARS_FILE_FOR_ENV)" VAULT_KV_MOUNT_PATH="$(VAULT_KV_MOUNT_PATH_EFFECTIVE)" VAULT_SECRET_PREFIX="$(VAULT_SECRET_PREFIX_EFFECTIVE)" "$(RESOLVE_PROXMOX_HOST_SCRIPT)" 2>/dev/null || true))
ANSIBLE_HOST_FOR_ENV = $(if $(ANSIBLE_HOST),$(ANSIBLE_HOST),$(shell ENVIRONMENT="$(ENVIRONMENT)" REPO_ROOT="$(MAKEFILE_DIR)" ENV_FILE="$(ENV_FILE)" TARGET_HOST="$(PROXMOX_HOST_FOR_ENV)" "$(RESOLVE_ANSIBLE_HOST_SCRIPT)" 2>/dev/null || true))
SNIPPET_STORAGE_FOR_ENV = $(if $(SNIPPET_STORAGE),$(SNIPPET_STORAGE),$(shell awk -F= '/^[[:space:]]*snippet_storage[[:space:]]*=/{val=$$2; sub(/[[:space:]]*(\/\/|#).*$$/,"",val); sub(/[[:space:]]*\/\*.*\*\/[[:space:]]*$$/,"",val); gsub(/^[[:space:]]+|[[:space:]]+$$/,"",val); sub(/^"/,"",val); sub(/"$$/,"",val); print val; exit}' "environments/$(ENVIRONMENT).tfvars" 2>/dev/null || true))

# New environment scaffold defaults
TEMPLATE_ENV ?= dev
ENV_TEMPLATE_FORCE ?= false
AUTO_DISCOVER ?= true
PROXMOX_NODE ?=
ANSIBLE_HOST ?=
NETWORK_CIDR ?=
NETWORK_GW ?=
NETWORK_BRIDGE ?=
STORAGE_POOL ?=
DATA_STORAGE ?=

# Remote base VM defaults (used by env-base-vm* targets)
BASE_VM_BRIDGE ?= vmbr0
BASE_VM_IPCIDR ?= dhcp
BASE_VM_GATEWAY ?=
BASE_VM_DNS ?= 198.51.100.11
BASE_VM_OS_STORAGE ?= local-lvm
BASE_VM_DATA_STORAGE ?= local-lvm
BASE_VM_EFI_STORAGE ?= local-lvm
BASE_VM_CI_STORAGE ?= local-lvm
BASE_VM_SNIPPET_STORAGE ?= local
BASE_VM_CORES ?= 8
BASE_VM_MEM ?= 10240
BASE_VM_OS_DISK_SIZE ?= 50
BASE_VM_CIUSER ?= ansible
BASE_VM_SSH_KEYS_FILE ?= /root/.ssh/authorized_keys
BASE_VM_FORCE ?= 1
BASE_VM_DRY_RUN ?= 0
BASE_VM_BUILD_ORACLE ?= false
SKIP_BASE_VM_SETUP ?= false
AUTO_DOWNLOAD_IMAGE ?= true
DOWNLOAD_CLOUD_IMAGE_SCRIPT ?= ./scripts/download-cloud-image.sh
PVE_IMAGE_DIR ?= /var/lib/vz/template/iso
CLOUD_IMAGES ?= common

# Reserved VMID/name policy for reusable base VMs (upper ID range).
BASE_VMID_ORACLE9 ?= 999999990
BASE_VMID_ORACLE8 ?= 999999991
BASE_VMID_UBUNTU2404 ?= 999999992
BASE_VM_NAME_ORACLE9 ?= oracle9-packer-base
BASE_VM_NAME_ORACLE8 ?= oracle8-packer-base
BASE_VM_NAME_UBUNTU2404 ?= ubuntu2404-packer-base

ORACLE8_IMAGE_URL ?= https://yum.oracle.com/templates/OracleLinux/OL8/u10/x86_64/OL8U10_x86_64-kvm-b271.qcow2
ORACLE9_IMAGE_URL ?= https://yum.oracle.com/templates/OracleLinux/OL9/u7/x86_64/OL9U7_x86_64-kvm-b269.qcow2
UBUNTU22_IMAGE_URL ?= https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img
UBUNTU24_IMAGE_URL ?= https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
DEBIAN12_IMAGE_URL ?= https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2
ROCKY9_IMAGE_URL ?= https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2
ALMA9_IMAGE_URL ?= https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2
FEDORA43_IMAGE_URL ?= https://download.fedoraproject.org/pub/fedora/linux/releases/43/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-43-1.6.x86_64.qcow2
UBUNTU_IMAGE_URL ?= $(UBUNTU24_IMAGE_URL)

ORACLE8_CHECKSUM_URL ?= https://yum.oracle.com/templates/OracleLinux/ol8-template.json
ORACLE9_CHECKSUM_URL ?= https://yum.oracle.com/templates/OracleLinux/ol9-template.json
UBUNTU22_CHECKSUM_URL ?= https://cloud-images.ubuntu.com/jammy/current/SHA256SUMS
UBUNTU24_CHECKSUM_URL ?=
DEBIAN12_CHECKSUM_URL ?= https://cloud.debian.org/images/cloud/bookworm/latest/SHA512SUMS
ROCKY9_CHECKSUM_URL ?= https://dl.rockylinux.org/pub/rocky/9/images/x86_64/CHECKSUM
ALMA9_CHECKSUM_URL ?= https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/CHECKSUM
FEDORA43_CHECKSUM_URL ?= https://download.fedoraproject.org/pub/fedora/linux/releases/43/Cloud/x86_64/images/Fedora-Cloud-43-1.6-x86_64-CHECKSUM

ORACLE8_IMAGE_SHA256 ?=
ORACLE9_IMAGE_SHA256 ?=
UBUNTU22_IMAGE_SHA256 ?=
UBUNTU24_IMAGE_SHA256 ?=
DEBIAN12_IMAGE_SHA512 ?=
ROCKY9_IMAGE_SHA256 ?=
ALMA9_IMAGE_SHA256 ?=
FEDORA43_IMAGE_SHA256 ?=

BASE_VM_UBUNTU_IMAGE ?= $(PVE_IMAGE_DIR)/noble-server-cloudimg-amd64.img
BASE_VM_ORACLE8_IMAGE ?= $(PVE_IMAGE_DIR)/OL8U10_x86_64-kvm-b271.qcow2
BASE_VM_ORACLE9_IMAGE ?= $(PVE_IMAGE_DIR)/OL9U7_x86_64-kvm-b269.qcow2

# Vault mode switching defaults
VAULT_MODE_SCRIPT ?= ./scripts/vault-mode-switch.sh
VAULT_LAN_IP ?= $(ANSIBLE_HOST_FOR_ENV)
VAULT_LAN_HOST ?= $(VAULT_LAN_IP)
VAULT_HCL ?= /etc/vault.d/vault.hcl
VAULT_UNIT ?= vault
VAULT_AUTH_SCRIPT ?= ./scripts/vault-auth.sh
WITH_VAULT_TOKEN_SCRIPT ?= ./scripts/with-vault-token.sh
ROTATE_PROXMOX_CREDS_SCRIPT ?= ./scripts/rotate-proxmox-creds.sh
VAULT_BOOTSTRAP_SCRIPT ?= ./scripts/vault-bootstrap.sh
VAULT_TLS_SCRIPT ?= ./scripts/vault-regenerate-tls.sh
VAULT_TLS_DAYS ?= 365
VAULT_REINIT_SCRIPT ?= ./scripts/vault-reinit.sh
VAULT_RECOVERY_DIR ?= $(HOME)/.vault-recovery
VAULT_INIT_SHARES ?= 3
VAULT_INIT_THRESHOLD ?= 2
VAULT_REINIT_OPTS ?= --store-root-token --env-token-update

# Check if .env file exists and load it
ENV_FILE := .env
ifneq ($(wildcard $(ENV_FILE)),)
	include $(ENV_FILE)
	export
endif

# Create directory structure
create-dirs:
	    @echo "${CYAN}--- Creating organized directory structure ---${NC}"
	    @for dir in $(DIRS); do \
	            if [ ! -d "$$dir" ]; then \
	              mkdir -p "$$dir"; \
	              echo "Created directory: $$dir"; \
	            fi; \
	    done
	    @mkdir -p "$(INVENTORY_DIR)"
	    @if [ -d "$(LEGACY_INVENTORY_DIR)" ]; then \
	            if [ -z "$$(ls -A "$(LEGACY_INVENTORY_DIR)" 2>/dev/null)" ]; then \
	                    rmdir "$(LEGACY_INVENTORY_DIR)" 2>/dev/null || true; \
	            else \
	                    echo "${YELLOW}Warning: legacy inventory directory detected at $(LEGACY_INVENTORY_DIR).${NC}"; \
	                    echo "${YELLOW}Run 'make clean-legacy-inventory' to remove stale local inventory files.${NC}"; \
	            fi; \
	    fi
	    @echo "${GREEN}✓ Directory structure ready${NC}"

help:
	    @echo "${GREEN}Terraform Proxmox Infrastructure - Root Module Pattern${NC}"
	    @echo "${YELLOW}Usage:${NC}"
	    @echo "  make <command> [ENVIRONMENT=<env>]"
	    @echo ""
	    @echo "${YELLOW}Setup Commands:${NC}"
	    @echo "  ${GREEN}setup${NC}            : Sync common cloud images and create base VM (local Proxmox mode)"
	    @echo "  ${GREEN}setup-tools${NC}      : Install vault/terraform/packer/jq (Ubuntu/Debian) and run checks"
	    @echo "  ${GREEN}check-tools${NC}      : Validate local toolchain + Vault/Packer/Terraform readiness"
	    @echo "  ${GREEN}vault-login${NC}      : Authenticate to Vault (AppRole/token) and cache token locally"
	    @echo "  ${GREEN}vault-bootstrap${NC}  : Recreate Vault module resources + refresh AppRole IDs + rotate Proxmox creds"
	    @echo "  ${GREEN}rotate-proxmox-creds${NC} : Rotate Proxmox API token and update Vault for ENVIRONMENT"
	    @echo "  ${GREEN}env-discover${NC}     : Discover Proxmox node/storage/bridge defaults + local source IP"
	    @echo "  ${GREEN}env-template${NC}     : Scaffold tfvars/packer vars/.env entries for a new ENVIRONMENT"
	    @echo "  ${GREEN}env-ssh-access${NC}   : Configure key-based SSH from this host to Proxmox root"
	    @echo "  ${GREEN}env-cloud-images${NC} : Download and checksum-verify common cloud images on Proxmox"
	    @echo "  ${GREEN}env-base-vms${NC}     : Create required base VMs on the target Proxmox host (remote)"
	    @echo "  ${GREEN}env-bootstrap${NC}    : End-to-end onboarding flow from scaffold to Terraform plan"
	    @echo "  ${GREEN}env-bootstrap-apply${NC}: Same as env-bootstrap, then run apply"
	    @echo "  ${GREEN}create-dirs${NC}      : Create organized directory structure"
	    @echo "  ${GREEN}render-snippets${NC}  : Render partitioning snippets from .tfvars"
	    @echo "  ${GREEN}upload-snippets${NC}  : Upload snippets to the Proxmox node"
	    @echo "  ${GREEN}snippets${NC}         : Render + upload snippets for ENVIRONMENT"
	    @echo "  ${GREEN}packer-build${NC}     : Build the Proxmox template with Packer for ENVIRONMENT"
	    @echo "  ${GREEN}packer-build-all${NC} : Build all Packer templates for ENVIRONMENT"
	    @echo "  ${GREEN}packer-build-ubuntu2404${NC} : Build Ubuntu 24.04 template"
	    @echo "  ${GREEN}packer-build-oracle8${NC}    : Build Oracle Linux 8 template"
	    @echo "  ${GREEN}packer-build-oracle9${NC}    : Build Oracle Linux 9 template"
	    @echo "  ${GREEN}packer-destroy-all${NC}      : Destroy all packer-generated VMs for ENVIRONMENT"
	    @echo ""
	    @echo "${YELLOW}New Environment Overrides:${NC}"
	    @echo "  TEMPLATE_ENV=$(TEMPLATE_ENV)"
	    @echo "  ENV_TEMPLATE_FORCE=$(ENV_TEMPLATE_FORCE)"
	    @echo "  AUTO_DISCOVER=$(AUTO_DISCOVER)"
	    @echo "  PROXMOX_NODE=$(PROXMOX_NODE)"
	    @echo "  BASE_VM_BUILD_ORACLE=$(BASE_VM_BUILD_ORACLE)"
	    @echo "  SKIP_BASE_VM_SETUP=$(SKIP_BASE_VM_SETUP)"
	    @echo "  AUTO_DOWNLOAD_IMAGE=$(AUTO_DOWNLOAD_IMAGE)"
	    @echo "  CLOUD_IMAGES=$(CLOUD_IMAGES)"
	    @echo "  PVE_IMAGE_DIR=$(PVE_IMAGE_DIR)"
	    @echo ""
	    @echo "${YELLOW}Packer Overrides:${NC}"
	    @echo "  PACKER_DIR=$(PACKER_DIR)"
	    @echo "  PACKER_TEMPLATE=$(PACKER_TEMPLATE)"
	    @echo "  PACKER_VARS=$(PACKER_VARS)"
	    @echo "  PACKER_USE_VAULT_CREDS=$(PACKER_USE_VAULT_CREDS)"
	    @echo "  PACKER_VAULT_PATH=$(PACKER_VAULT_PATH)"
	    @echo "  TF_INIT_UPGRADE=$(TF_INIT_UPGRADE)"
	    @echo ""
	    @echo "${YELLOW}Workspace Management:${NC}"
	    @echo "  ${GREEN}workspace-create${NC}  : Create a new workspace for the environment"
	    @echo "  ${GREEN}workspace-select${NC}  : Select workspace for the environment"
	    @echo "  ${GREEN}workspace-list${NC}    : List all workspaces"
	    @echo ""
	    @echo "${YELLOW}Development Workflow:${NC}"
		@echo "  ${GREEN}tf-security-scan${NC} : Scan Terraform function usage policy (custom Python scanner)"
		@echo "  ${GREEN}tflint${NC}           : Run Terraform lint checks (recursive)"
		@echo "  ${GREEN}tfsec${NC}            : Run tfsec security checks"
		@echo "  ${GREEN}tf_scan${NC}          : Run tf-security-scan + tflint + tfsec"
	    @echo "  ${GREEN}validate${NC}         : Validate Terraform configuration files"
	    @echo "  ${GREEN}fmt${NC}              : Format Terraform configuration files"
	    @echo "  ${GREEN}init${NC}             : Initialize Terraform"
	    @echo "  ${GREEN}plan${NC}             : Generate a Terraform execution plan"
	    @echo "  ${GREEN}apply${NC}            : Apply the Terraform plan to create/update resources"
	    @echo "  ${GREEN}deploy${NC}           : Run complete deployment workflow"
	    @echo ""
	@echo "${YELLOW}Operations:${NC}"
	@echo "  ${GREEN}destroy${NC}          : Destroy all Terraform-managed resources"
	@echo "  ${GREEN}clean${NC}            : Remove generated artifacts (plans, logs, inventories, summaries, backups)"
	@echo "  ${GREEN}clean-all${NC}        : Remove ALL local artifacts + Terraform state/workspaces"
	@echo "  ${GREEN}clean-legacy-inventory${NC} : Remove deprecated terraform-proxmox/inventories directory"
	@echo "  ${GREEN}backup${NC}           : Backup current environment state"
	@echo ""
	    @echo "${YELLOW}Utility Commands:${NC}"
	    @echo "  ${GREEN}tree${NC}             : Show organized project structure"
	    @echo "  ${GREEN}vault-mode-status${NC}   : Show current Vault access mode and address settings"
	    @echo "  ${GREEN}vault-mode-loopback${NC} : Switch Vault to loopback mode, restart, and verify"
	    @echo "  ${GREEN}vault-mode-lan${NC}      : Switch Vault to LAN mode, restart, and verify"
	    @echo "  ${GREEN}vault-mode-lan-auto${NC} : Regenerate cert SANs for LAN + switch/verify LAN mode"
	    @echo "  ${GREEN}vault-mode-verify${NC}   : Verify Vault + Terraform + Packer wiring"
	    @echo "  ${GREEN}vault-unseal-help${NC}   : Show unseal key locations and unseal commands"
	    @echo "  ${GREEN}vault-tls-regenerate${NC} : Regenerate Vault TLS cert with loopback + LAN SANs"
	    @echo "  ${GREEN}vault-reinit-dry-run${NC} : Preview destructive Vault reinit workflow"
	    @echo "  ${GREEN}vault-reinit${NC}        : DESTRUCTIVE reset/init + recovery bundle + .env token update (requires CONFIRM=YES)"
	    @echo "  ${GREEN}vault-recovery-list${NC} : List local Vault recovery bundles"
	    @echo ""
	    @echo "${YELLOW}Quick Workspace Switchers:${NC}"
	    @echo "  ${GREEN}dev${NC}              : Switch to dev environment"
	    @echo "  ${GREEN}prod${NC}             : Switch to prod environment"
	    @echo "  ${GREEN}testing${NC}          : Switch to testing environment"
	    @echo ""
	    @echo "${YELLOW}Examples:${NC}"
	    @echo "  make deploy ENVIRONMENT=dev"
	    @echo "  make plan ENVIRONMENT=prod"
	    @echo "  make env-discover ENVIRONMENT=qa PROXMOX_HOST=198.51.100.17"
	    @echo "  make env-template ENVIRONMENT=qa TEMPLATE_ENV=dev PROXMOX_HOST=198.51.100.17 AUTO_DISCOVER=true"
	    @echo "  make env-bootstrap ENVIRONMENT=qa PROXMOX_HOST=198.51.100.17 PROXMOX_NODE=proxmox"
	    @echo "  make workspace-create ENVIRONMENT=testing"
	    @echo "  make backup ENVIRONMENT=prod"
	    @echo "  make tree"
	    @echo ""
	    @echo "${YELLOW}Current Configuration:${NC}"
	    @echo "  Environment: ${ENVIRONMENT}"
	    @echo "  Current Workspace: $$(terraform workspace show 2>/dev/null || echo 'default')"
	    @echo "  Resolved Proxmox host: $(if $(PROXMOX_HOST_FOR_ENV),$(PROXMOX_HOST_FOR_ENV),<unresolved>)"
	    @echo "  Resolved control host IP: $(if $(ANSIBLE_HOST_FOR_ENV),$(ANSIBLE_HOST_FOR_ENV),<unresolved>)"
	    @echo ""
	    @echo "${CYAN}Directory Structure:${NC}"
	    @echo "  📁 plans/           - Terraform execution plans"
	    @echo "  📁 $(INVENTORY_ROOT)/<env>/ - Ansible inventory files"
	    @echo "  📁 summaries/       - Deployment summaries"
	    @echo "  📁 logs/            - Log files"
	    @echo "  📁 backups/         - State backups"

# Setup: Sync cloud images and create base VM for Packer
setup: create-dirs
	    @echo "${YELLOW}--- Running initial setup ---${NC}"
	    @echo "Synchronizing common cloud images into $(PVE_IMAGE_DIR)"
	    @IMAGE_DIR="$(PVE_IMAGE_DIR)" IMAGES="common" ORACLE8_IMAGE_URL="$(ORACLE8_IMAGE_URL)" ORACLE9_IMAGE_URL="$(ORACLE9_IMAGE_URL)" UBUNTU24_IMAGE_URL="$(UBUNTU24_IMAGE_URL)" ORACLE8_IMAGE_SHA256="$(ORACLE8_IMAGE_SHA256)" ORACLE9_IMAGE_SHA256="$(ORACLE9_IMAGE_SHA256)" UBUNTU24_IMAGE_SHA256="$(UBUNTU24_IMAGE_SHA256)" ORACLE8_CHECKSUM_URL="$(ORACLE8_CHECKSUM_URL)" ORACLE9_CHECKSUM_URL="$(ORACLE9_CHECKSUM_URL)" UBUNTU24_CHECKSUM_URL="$(UBUNTU24_CHECKSUM_URL)" "$(DOWNLOAD_CLOUD_IMAGE_SCRIPT)" --image-dir "$(PVE_IMAGE_DIR)" --images "common"
	    sudo ./scripts/create-cloudinit-vm_stable.sh
	    @echo "${GREEN}✓ Setup completed${NC}"

setup-tools:
	    @echo "${YELLOW}--- Installing/validating local tooling ---${NC}"
	    @./scripts/setup-tools.sh --yes
	    @echo "${GREEN}✓ Tool installation/check complete${NC}"

check-tools:
	    @echo "${YELLOW}--- Checking local tooling and readiness ---${NC}"
	    @./scripts/check-tools.sh
	    @echo "${GREEN}✓ Tooling checks passed${NC}"

vault-login:
	    @echo "${YELLOW}--- Authenticating to Vault ---${NC}"
	    @$(VAULT_AUTH_SCRIPT) --print-token >/dev/null
	    @echo "${GREEN}✓ Vault token ready${NC}"

vault-bootstrap: workspace-create workspace-select
	    @echo "${YELLOW}--- Bootstrapping Vault integration for ${ENVIRONMENT} ---${NC}"
	    @ENVIRONMENT="$(ENVIRONMENT)" ENV_FILE="$(ENV_FILE)" TFVARS_FILE="$(TFVARS_FILE_FOR_ENV)" PROXMOX_HOST="$(PROXMOX_HOST_FOR_ENV)" PROXMOX_USER="$(PROXMOX_USER)" VAULT_PATH="$(VAULT_CREDS_PATH_FOR_ENV)" VAULT_AUTH_SCRIPT="$(VAULT_AUTH_SCRIPT)" ROTATE_PROXMOX_CREDS_SCRIPT="$(ROTATE_PROXMOX_CREDS_SCRIPT)" "$(VAULT_BOOTSTRAP_SCRIPT)"
	    @echo "${GREEN}✓ Vault bootstrap completed for $(ENVIRONMENT)${NC}"

rotate-proxmox-creds:
	    @echo "${YELLOW}--- Rotating Proxmox API credentials for ${ENVIRONMENT} ---${NC}"
	    @if [ -z "$(PROXMOX_HOST_FOR_ENV)" ]; then \
	            echo "${RED}Error: failed to resolve Proxmox host for ENVIRONMENT=$(ENVIRONMENT).${NC}"; \
	            echo "${YELLOW}Hint:${NC} set PROXMOX_HOST or PROXMOX_HOST_<ENV> in .env."; \
	            exit 1; \
	    fi
	    @ENVIRONMENT="$(ENVIRONMENT)" TFVARS_FILE="$(TFVARS_FILE_FOR_ENV)" PROXMOX_HOST="$(PROXMOX_HOST_FOR_ENV)" PROXMOX_USER="$(PROXMOX_USER)" VAULT_PATH="$(VAULT_CREDS_PATH_FOR_ENV)" "$(ROTATE_PROXMOX_CREDS_SCRIPT)"
	    @echo "${GREEN}✓ Proxmox credentials rotated and Vault updated for $(ENVIRONMENT)${NC}"

env-discover:
	    @echo "${YELLOW}--- Discovering Proxmox core settings for ${ENVIRONMENT} ---${NC}"
	    @if [ -z "$(PROXMOX_HOST_FOR_ENV)" ]; then \
	            echo "${RED}Error: failed to resolve Proxmox host for ENVIRONMENT=$(ENVIRONMENT).${NC}"; \
	            echo "${YELLOW}Hint:${NC} set PROXMOX_HOST or PROXMOX_HOST_<ENV> in .env."; \
	            exit 1; \
	    fi
	    @DISCOVERY_FILE="environments/$(ENVIRONMENT).autodiscover.env"; \
	    PROXMOX_HOST="$(PROXMOX_HOST_FOR_ENV)" PROXMOX_USER="$(PROXMOX_USER)" "$(DISCOVER_PROXMOX_CORE_SCRIPT)" --env > "$$DISCOVERY_FILE"; \
	    echo "Discovery snapshot written: $$DISCOVERY_FILE"; \
	    cat "$$DISCOVERY_FILE"
	    @echo "${GREEN}✓ Discovery completed for $(ENVIRONMENT)${NC}"

env-template:
	    @echo "${YELLOW}--- Scaffolding new environment: ${ENVIRONMENT} (template: ${TEMPLATE_ENV}) ---${NC}"
	    @if [ "$(AUTO_DISCOVER)" = "true" ] && [ -z "$(PROXMOX_HOST_FOR_ENV)" ]; then \
	            echo "${RED}Error: AUTO_DISCOVER=true requires PROXMOX_HOST (or PROXMOX_HOST_<ENV> in .env).${NC}"; \
	            exit 1; \
	    fi
	    @FORCE_ARG=""; \
	    if [ "$(ENV_TEMPLATE_FORCE)" = "true" ]; then FORCE_ARG="--force"; fi; \
	    ENVIRONMENT="$(ENVIRONMENT)" TEMPLATE_ENV="$(TEMPLATE_ENV)" AUTO_DISCOVER="$(AUTO_DISCOVER)" PROXMOX_HOST="$(PROXMOX_HOST_FOR_ENV)" PROXMOX_USER="$(PROXMOX_USER)" PROXMOX_NODE="$(PROXMOX_NODE)" ANSIBLE_HOST="$(ANSIBLE_HOST_FOR_ENV)" NETWORK_CIDR="$(NETWORK_CIDR)" NETWORK_GW="$(NETWORK_GW)" NETWORK_BRIDGE="$(NETWORK_BRIDGE)" STORAGE_POOL="$(STORAGE_POOL)" DATA_STORAGE="$(DATA_STORAGE)" "$(SCAFFOLD_ENV_SCRIPT)" $$FORCE_ARG
	    @echo "${GREEN}✓ Environment scaffold ready for $(ENVIRONMENT)${NC}"

env-ssh-access:
	    @echo "${YELLOW}--- Configuring key-based SSH access to Proxmox for ${ENVIRONMENT} ---${NC}"
	    @if [ -z "$(PROXMOX_HOST_FOR_ENV)" ]; then \
	            echo "${RED}Error: failed to resolve Proxmox host for ENVIRONMENT=$(ENVIRONMENT).${NC}"; \
	            echo "${YELLOW}Hint:${NC} set PROXMOX_HOST or PROXMOX_HOST_<ENV> in .env."; \
	            exit 1; \
	    fi
	    @PROXMOX_HOST="$(PROXMOX_HOST_FOR_ENV)" PROXMOX_USER="$(PROXMOX_USER)" PUBLIC_KEY_FILE="$(PUBLIC_KEY_FILE)" PROXMOX_PASSWORD="$(PROXMOX_PASSWORD)" "$(PROXMOX_SSH_SETUP_SCRIPT)"
	    @echo "${GREEN}✓ Proxmox SSH key access ready${NC}"

env-cloud-images:
	    @echo "${YELLOW}--- Syncing cloud images on target Proxmox for ${ENVIRONMENT} ---${NC}"
	    @if [ -z "$(PROXMOX_HOST_FOR_ENV)" ]; then \
	            echo "${RED}Error: failed to resolve Proxmox host for ENVIRONMENT=$(ENVIRONMENT).${NC}"; \
	            echo "${YELLOW}Hint:${NC} set PROXMOX_HOST or PROXMOX_HOST_<ENV> in .env."; \
	            exit 1; \
	    fi
	    @IMAGE_SET="$(CLOUD_IMAGES)"; \
	    if [ "$$IMAGE_SET" = "common" ] && [ "$(BASE_VM_BUILD_ORACLE)" != "true" ]; then IMAGE_SET="ubuntu24"; fi; \
	    echo "Syncing image set '$$IMAGE_SET' to $(PVE_IMAGE_DIR) on $(PROXMOX_HOST_FOR_ENV)"; \
	    PROXMOX_HOST="$(PROXMOX_HOST_FOR_ENV)" PROXMOX_USER="$(PROXMOX_USER)" IMAGE_DIR="$(PVE_IMAGE_DIR)" IMAGES="$$IMAGE_SET" \
	    ORACLE8_IMAGE_URL="$(ORACLE8_IMAGE_URL)" ORACLE9_IMAGE_URL="$(ORACLE9_IMAGE_URL)" \
	    UBUNTU22_IMAGE_URL="$(UBUNTU22_IMAGE_URL)" UBUNTU24_IMAGE_URL="$(UBUNTU24_IMAGE_URL)" \
	    DEBIAN12_IMAGE_URL="$(DEBIAN12_IMAGE_URL)" ROCKY9_IMAGE_URL="$(ROCKY9_IMAGE_URL)" \
	    ALMA9_IMAGE_URL="$(ALMA9_IMAGE_URL)" FEDORA43_IMAGE_URL="$(FEDORA43_IMAGE_URL)" \
	    ORACLE8_IMAGE_SHA256="$(ORACLE8_IMAGE_SHA256)" ORACLE9_IMAGE_SHA256="$(ORACLE9_IMAGE_SHA256)" \
	    UBUNTU22_IMAGE_SHA256="$(UBUNTU22_IMAGE_SHA256)" UBUNTU24_IMAGE_SHA256="$(UBUNTU24_IMAGE_SHA256)" \
	    DEBIAN12_IMAGE_SHA512="$(DEBIAN12_IMAGE_SHA512)" ROCKY9_IMAGE_SHA256="$(ROCKY9_IMAGE_SHA256)" \
	    ALMA9_IMAGE_SHA256="$(ALMA9_IMAGE_SHA256)" FEDORA43_IMAGE_SHA256="$(FEDORA43_IMAGE_SHA256)" \
	    ORACLE8_CHECKSUM_URL="$(ORACLE8_CHECKSUM_URL)" ORACLE9_CHECKSUM_URL="$(ORACLE9_CHECKSUM_URL)" \
	    UBUNTU22_CHECKSUM_URL="$(UBUNTU22_CHECKSUM_URL)" UBUNTU24_CHECKSUM_URL="$(UBUNTU24_CHECKSUM_URL)" \
	    DEBIAN12_CHECKSUM_URL="$(DEBIAN12_CHECKSUM_URL)" ROCKY9_CHECKSUM_URL="$(ROCKY9_CHECKSUM_URL)" \
	    ALMA9_CHECKSUM_URL="$(ALMA9_CHECKSUM_URL)" FEDORA43_CHECKSUM_URL="$(FEDORA43_CHECKSUM_URL)" \
	    "$(DOWNLOAD_CLOUD_IMAGE_SCRIPT)" --host "$(PROXMOX_HOST_FOR_ENV)" --user "$(PROXMOX_USER)" --image-dir "$(PVE_IMAGE_DIR)" --images "$$IMAGE_SET"
	    @echo "${GREEN}✓ Cloud images synchronized on $(PROXMOX_HOST_FOR_ENV)${NC}"

env-base-vm:
	    @echo "${YELLOW}--- Creating remote base VM (${BASE_VM_OS_TYPE}) for ${ENVIRONMENT} ---${NC}"
	    @if [ -z "$(BASE_VM_OS_TYPE)" ] || [ -z "$(BASE_VM_VMID)" ] || [ -z "$(BASE_VM_NAME)" ]; then \
	            echo "${RED}Error: BASE_VM_OS_TYPE, BASE_VM_VMID, and BASE_VM_NAME are required.${NC}"; \
	            exit 1; \
	    fi
	    @if [ -z "$(PROXMOX_HOST_FOR_ENV)" ]; then \
	            echo "${RED}Error: failed to resolve Proxmox host for ENVIRONMENT=$(ENVIRONMENT).${NC}"; \
	            echo "${YELLOW}Hint:${NC} set PROXMOX_HOST or PROXMOX_HOST_<ENV> in .env."; \
	            exit 1; \
	    fi
	    @PROXMOX_HOST="$(PROXMOX_HOST_FOR_ENV)" PROXMOX_USER="$(PROXMOX_USER)" \
	            VMID="$(BASE_VM_VMID)" NAME="$(BASE_VM_NAME)" OS_TYPE="$(BASE_VM_OS_TYPE)" \
	            FORCE="$(BASE_VM_FORCE)" DRY_RUN="$(BASE_VM_DRY_RUN)" \
	            BRIDGE="$(BASE_VM_BRIDGE)" IPCIDR="$(BASE_VM_IPCIDR)" GATEWAY="$(BASE_VM_GATEWAY)" DNS="$(BASE_VM_DNS)" \
	            OS_STORAGE="$(BASE_VM_OS_STORAGE)" DATA_STORAGE="$(BASE_VM_DATA_STORAGE)" EFI_STORAGE="$(BASE_VM_EFI_STORAGE)" \
	            CI_STORAGE="$(BASE_VM_CI_STORAGE)" SNIPPET_STORAGE="$(BASE_VM_SNIPPET_STORAGE)" \
	            CORES="$(BASE_VM_CORES)" MEM="$(BASE_VM_MEM)" OS_DISK_SIZE="$(BASE_VM_OS_DISK_SIZE)" \
	            CIUSER="$(BASE_VM_CIUSER)" SSH_KEYS_FILE="$(BASE_VM_SSH_KEYS_FILE)" \
	            ORACLE_LINUX_IMAGE="$(ORACLE_LINUX_IMAGE)" UBUNTU_IMAGE="$(UBUNTU_IMAGE)" \
	            AUTO_DOWNLOAD_IMAGE="$(AUTO_DOWNLOAD_IMAGE)" UBUNTU_IMAGE_URL="$(UBUNTU_IMAGE_URL)" UBUNTU24_IMAGE_URL="$(UBUNTU24_IMAGE_URL)" ORACLE8_IMAGE_URL="$(ORACLE8_IMAGE_URL)" ORACLE9_IMAGE_URL="$(ORACLE9_IMAGE_URL)" ORACLE8_IMAGE_SHA256="$(ORACLE8_IMAGE_SHA256)" ORACLE9_IMAGE_SHA256="$(ORACLE9_IMAGE_SHA256)" UBUNTU24_IMAGE_SHA256="$(UBUNTU24_IMAGE_SHA256)" ORACLE8_CHECKSUM_URL="$(ORACLE8_CHECKSUM_URL)" ORACLE9_CHECKSUM_URL="$(ORACLE9_CHECKSUM_URL)" UBUNTU24_CHECKSUM_URL="$(UBUNTU24_CHECKSUM_URL)" DOWNLOAD_IMAGE_SCRIPT="$(DOWNLOAD_CLOUD_IMAGE_SCRIPT)" \
	            "$(REMOTE_BASE_VM_SCRIPT)"
	    @echo "${GREEN}✓ Base VM created: $(BASE_VM_NAME) (VMID=$(BASE_VM_VMID))${NC}"

env-base-vm-ubuntu2404:
	    @$(MAKE) env-base-vm ENVIRONMENT=$(ENVIRONMENT) BASE_VM_OS_TYPE=ubuntu BASE_VM_VMID=$(BASE_VMID_UBUNTU2404) BASE_VM_NAME=$(BASE_VM_NAME_UBUNTU2404) UBUNTU_IMAGE="$(BASE_VM_UBUNTU_IMAGE)"

env-base-vm-oracle8:
	    @$(MAKE) env-base-vm ENVIRONMENT=$(ENVIRONMENT) BASE_VM_OS_TYPE=oracle-linux BASE_VM_VMID=$(BASE_VMID_ORACLE8) BASE_VM_NAME=$(BASE_VM_NAME_ORACLE8) ORACLE_LINUX_IMAGE="$(BASE_VM_ORACLE8_IMAGE)"

env-base-vm-oracle9:
	    @$(MAKE) env-base-vm ENVIRONMENT=$(ENVIRONMENT) BASE_VM_OS_TYPE=oracle-linux BASE_VM_VMID=$(BASE_VMID_ORACLE9) BASE_VM_NAME=$(BASE_VM_NAME_ORACLE9) ORACLE_LINUX_IMAGE="$(BASE_VM_ORACLE9_IMAGE)"

env-base-vms:
	    @echo "${YELLOW}--- Creating base VMs on target Proxmox for ${ENVIRONMENT} ---${NC}"
	    @if [ "$(AUTO_DOWNLOAD_IMAGE)" = "true" ]; then \
	            $(MAKE) env-cloud-images ENVIRONMENT=$(ENVIRONMENT) BASE_VM_BUILD_ORACLE="$(BASE_VM_BUILD_ORACLE)"; \
	    else \
	            echo "${YELLOW}Skipping image sync on Proxmox (AUTO_DOWNLOAD_IMAGE=false).${NC}"; \
	    fi
	    @$(MAKE) env-base-vm-ubuntu2404 ENVIRONMENT=$(ENVIRONMENT)
	    @if [ "$(BASE_VM_BUILD_ORACLE)" = "true" ]; then \
	            $(MAKE) env-base-vm-oracle8 ENVIRONMENT=$(ENVIRONMENT); \
	            $(MAKE) env-base-vm-oracle9 ENVIRONMENT=$(ENVIRONMENT); \
	    else \
	            echo "${YELLOW}Skipping Oracle base VMs (set BASE_VM_BUILD_ORACLE=true to enable).${NC}"; \
	    fi
	    @echo "${GREEN}✓ Base VM provisioning complete for $(ENVIRONMENT)${NC}"

env-bootstrap:
	    @echo "${YELLOW}--- Running end-to-end environment bootstrap for ${ENVIRONMENT} ---${NC}"
	    @set -e; \
	    BOOTSTRAP_FILE="environments/$(ENVIRONMENT).bootstrap.env"; \
	    if [ ! -f "environments/$(ENVIRONMENT).tfvars" ] || [ ! -f "packer/ubuntu-noble/vars.$(ENVIRONMENT).pkrvars.hcl" ] || [ ! -f "packer/oracle8/vars.$(ENVIRONMENT).pkrvars.hcl" ] || [ ! -f "packer/oracle9/vars.$(ENVIRONMENT).pkrvars.hcl" ]; then \
	            $(MAKE) env-template ENVIRONMENT=$(ENVIRONMENT) TEMPLATE_ENV=$(TEMPLATE_ENV) AUTO_DISCOVER="$(AUTO_DISCOVER)" PROXMOX_HOST="$(PROXMOX_HOST_FOR_ENV)" PROXMOX_NODE="$(PROXMOX_NODE)" ANSIBLE_HOST="$(ANSIBLE_HOST_FOR_ENV)" NETWORK_CIDR="$(NETWORK_CIDR)" NETWORK_GW="$(NETWORK_GW)" NETWORK_BRIDGE="$(NETWORK_BRIDGE)" STORAGE_POOL="$(STORAGE_POOL)" DATA_STORAGE="$(DATA_STORAGE)"; \
	    else \
	            echo "${YELLOW}Environment files already exist; skipping scaffold step.${NC}"; \
	    fi; \
	    if [ -f "$$BOOTSTRAP_FILE" ]; then \
	            echo "${CYAN}Loading $$BOOTSTRAP_FILE defaults for bootstrap run...${NC}"; \
	            set -a; . "$$BOOTSTRAP_FILE"; set +a; \
	    fi; \
	    $(MAKE) env-ssh-access ENVIRONMENT=$(ENVIRONMENT); \
	    $(MAKE) workspace-create ENVIRONMENT=$(ENVIRONMENT); \
	    $(MAKE) workspace-select ENVIRONMENT=$(ENVIRONMENT); \
	    $(MAKE) rotate-proxmox-creds ENVIRONMENT=$(ENVIRONMENT); \
	    if [ "$(SKIP_BASE_VM_SETUP)" = "true" ]; then \
	            echo "${YELLOW}Skipping base VM provisioning (SKIP_BASE_VM_SETUP=true).${NC}"; \
	    else \
	            $(MAKE) env-base-vms ENVIRONMENT=$(ENVIRONMENT) BASE_VM_BUILD_ORACLE="$(BASE_VM_BUILD_ORACLE)"; \
	    fi; \
	    $(MAKE) packer-build-ubuntu2404 ENVIRONMENT=$(ENVIRONMENT); \
	    if [ "$(BASE_VM_BUILD_ORACLE)" = "true" ]; then \
	            $(MAKE) packer-build-oracle8 ENVIRONMENT=$(ENVIRONMENT); \
	            $(MAKE) packer-build-oracle9 ENVIRONMENT=$(ENVIRONMENT); \
	    else \
	            echo "${YELLOW}Skipping Oracle Packer templates (set BASE_VM_BUILD_ORACLE=true to enable).${NC}"; \
	    fi; \
	    $(MAKE) snippets ENVIRONMENT=$(ENVIRONMENT); \
	    $(MAKE) plan ENVIRONMENT=$(ENVIRONMENT); \
	    echo "${GREEN}✓ Bootstrap finished for $(ENVIRONMENT). Run 'make apply ENVIRONMENT=$(ENVIRONMENT)' when ready.${NC}"

env-bootstrap-apply: env-bootstrap
	    @$(MAKE) apply ENVIRONMENT=$(ENVIRONMENT)
	    @echo "${GREEN}✓ Bootstrap + apply completed for $(ENVIRONMENT)${NC}"

# Workspace management
workspace-create: create-dirs
	    @echo "${YELLOW}--- Creating workspace: ${ENVIRONMENT} ---${NC}"
	    @terraform workspace new $(ENVIRONMENT) 2>/dev/null || echo "Workspace $(ENVIRONMENT) may already exist"
	    @echo "${GREEN}✓ Workspace $(ENVIRONMENT) ready${NC}"

workspace-select: create-dirs
	    @echo "${YELLOW}--- Selecting workspace: ${ENVIRONMENT} ---${NC}"
	    @terraform workspace select $(ENVIRONMENT)
	    @echo "${GREEN}✓ Selected workspace: $(ENVIRONMENT)${NC}"

workspace-list:
	    @echo "${YELLOW}--- Available workspaces ---${NC}"
	    @terraform workspace list

# Scan the terraform project for security vulnerabilities on functions used.
tf-security-scan:
	    @echo "${YELLOW}--- Validating Terraform configuration ---${NC}"
	    @/bin/bash -lc 'set -o pipefail; terraform metadata functions -json | python3 tf_security_scan.py - . --policy whitelist.yml --output text --fail-on CRITICAL'
	    @echo "${GREEN}✓ Terraform security scan done${NC}"

tflint:
	    @echo "${YELLOW}--- Running TFLint checks ---${NC}"
	    @tflint --init
	    @tflint --recursive --minimum-failure-severity "$(TFLINT_MIN_FAILURE_SEVERITY)"
	    @echo "${GREEN}✓ TFLint checks passed${NC}"

tfsec:
	    @echo "${YELLOW}--- Running tfsec checks ---${NC}"
	    @/bin/bash -lc 'set -euo pipefail; \
	      TFVARS_FILE="environments/$(ENVIRONMENT).tfvars"; \
	      TFSEC_ARGS=(. --minimum-severity "$(TFSEC_MIN_SEVERITY)" --ignore-hcl-errors); \
	      if [ -f "$$TFVARS_FILE" ]; then \
	        TFSEC_ARGS+=(--tfvars-file "$$TFVARS_FILE"); \
	      fi; \
	      tfsec "$${TFSEC_ARGS[@]}"'
	    @echo "${GREEN}✓ tfsec checks passed${NC}"

tf_scan: tf-security-scan tflint tfsec
	    @echo "${GREEN}✓ Combined Terraform scan complete${NC}"

# Validate Terraform configuration
validate:
	    @echo "${YELLOW}--- Validating Terraform configuration ---${NC}"
	    @terraform validate
	    @echo "${GREEN}✓ Terraform configuration is valid${NC}"

# Format Terraform files
fmt:
	    @echo "${YELLOW}--- Formatting Terraform files ---${NC}"
	    @terraform fmt -recursive -write=true .
	    @echo "${GREEN}✓ Terraform files formatted${NC}"

# Initialize Terraform
init: create-dirs
	    @echo "${YELLOW}--- Initializing Terraform ---${NC}"
	    @/bin/bash -lc "set -o pipefail; terraform init $(TF_INIT_UPGRADE) 2>&1 | tee \"$(LOG_DIR)/terraform-init-$(ENVIRONMENT)-$$(date +%Y%m%d-%H%M%S).log\""
	    @echo "${GREEN}✓ Terraform initialized${NC}"

# Render partitioning snippets from tfvars without provisioning VMs
render-snippets: init workspace-select
	    @echo "${YELLOW}--- Rendering partitioning snippets for ${ENVIRONMENT} ---${NC}"
	    @if [ ! -f "environments/$(ENVIRONMENT).tfvars" ]; then \
	            echo "${RED}Error: environments/$(ENVIRONMENT).tfvars not found${NC}"; \
	            exit 1; \
	    fi
	    @/bin/bash -lc "set -o pipefail; $(WITH_VAULT_TOKEN_SCRIPT) terraform apply -target=local_file.partitioning_snippet -var-file=\"environments/$(ENVIRONMENT).tfvars\" -auto-approve 2>&1 | tee \"$(LOG_DIR)/terraform-snippets-$(ENVIRONMENT)-$$(date +%Y%m%d-%H%M%S).log\""
	    @echo "${GREEN}✓ Snippets rendered for $(ENVIRONMENT)${NC}"

upload-snippets:
	    @echo "${YELLOW}--- Uploading snippets to Proxmox ---${NC}"
	    @if [ -z "$(PROXMOX_HOST_FOR_ENV)" ]; then \
	            echo "${RED}Error: failed to resolve Proxmox host for ENVIRONMENT=$(ENVIRONMENT).${NC}"; \
	            echo "${YELLOW}Hint:${NC} set PROXMOX_HOST or PROXMOX_HOST_<ENV> in .env."; \
	            exit 1; \
	    fi
	    @PROXMOX_HOST="$(PROXMOX_HOST_FOR_ENV)" PROXMOX_USER="$(PROXMOX_USER)" SNIPPET_STORAGE="$(if $(SNIPPET_STORAGE_FOR_ENV),$(SNIPPET_STORAGE_FOR_ENV),local)" ./scripts/upload-snippets.sh
	    @echo "${GREEN}✓ Snippets uploaded${NC}"

vault-mode-status:
	    @LAN_IP="$(VAULT_LAN_IP)" LAN_HOST="$(VAULT_LAN_HOST)" VAULT_HCL="$(VAULT_HCL)" VAULT_UNIT="$(VAULT_UNIT)" ENVIRONMENT="$(ENVIRONMENT)" "$(VAULT_MODE_SCRIPT)" status

vault-mode-loopback:
	    @LAN_IP="$(VAULT_LAN_IP)" LAN_HOST="$(VAULT_LAN_HOST)" VAULT_HCL="$(VAULT_HCL)" VAULT_UNIT="$(VAULT_UNIT)" ENVIRONMENT="$(ENVIRONMENT)" "$(VAULT_MODE_SCRIPT)" loopback

vault-mode-lan:
	    @LAN_IP="$(VAULT_LAN_IP)" LAN_HOST="$(VAULT_LAN_HOST)" VAULT_HCL="$(VAULT_HCL)" VAULT_UNIT="$(VAULT_UNIT)" ENVIRONMENT="$(ENVIRONMENT)" "$(VAULT_MODE_SCRIPT)" lan

vault-tls-regenerate:
	    @LAN_IP="$(VAULT_LAN_IP)" LAN_HOST="$(VAULT_LAN_HOST)" VAULT_HCL="$(VAULT_HCL)" ENV_FILE="$(ENV_FILE)" VAULT_UNIT="$(VAULT_UNIT)" DAYS="$(VAULT_TLS_DAYS)" "$(VAULT_TLS_SCRIPT)"

vault-mode-lan-auto:
	    @echo "${YELLOW}--- Regenerating TLS cert for LAN SANs before LAN mode switch ---${NC}"
	    @LAN_IP="$(VAULT_LAN_IP)" LAN_HOST="$(VAULT_LAN_HOST)" VAULT_HCL="$(VAULT_HCL)" ENV_FILE="$(ENV_FILE)" VAULT_UNIT="$(VAULT_UNIT)" DAYS="$(VAULT_TLS_DAYS)" "$(VAULT_TLS_SCRIPT)" --no-restart
	    @$(MAKE) vault-mode-lan ENVIRONMENT=$(ENVIRONMENT)

vault-mode-verify:
	    @LAN_IP="$(VAULT_LAN_IP)" LAN_HOST="$(VAULT_LAN_HOST)" VAULT_HCL="$(VAULT_HCL)" VAULT_UNIT="$(VAULT_UNIT)" ENVIRONMENT="$(ENVIRONMENT)" "$(VAULT_MODE_SCRIPT)" verify

vault-unseal-help:
	    @RECOVERY_DIR="$${VAULT_RECOVERY_DIR:-$(HOME)/.vault-recovery}"; \
	    KEY_FILE="$$RECOVERY_DIR/latest/unseal-keys.txt"; \
	    ROOT_FILE="$$RECOVERY_DIR/latest/root-token.txt"; \
	    echo "Unseal keys file: $$KEY_FILE"; \
	    echo "Root token file:  $$ROOT_FILE"; \
	    if [ ! -f "$$KEY_FILE" ]; then \
	            echo ""; \
	            echo "${YELLOW}No unseal key file found at $$KEY_FILE.${NC}"; \
	            echo "${YELLOW}If Vault reinit failed previously, rerun:${NC} make vault-reinit CONFIRM=YES"; \
	            echo "${YELLOW}Existing recovery bundles (if any):${NC}"; \
	            ls -1d "$$RECOVERY_DIR"/vault-reinit-* 2>/dev/null || true; \
	            exit 0; \
	    fi; \
	    echo ""; \
	    echo "Commands:"; \
	    echo "  export VAULT_ADDR=$${VAULT_ADDR:-https://127.0.0.1:8200}"; \
	    echo "  export VAULT_CACERT=$${VAULT_CACERT:-/etc/vault.d/vault-cert.pem}"; \
	    echo "  mapfile -t KEYS < <(sed -n 's/^key_[0-9]\\+=//p' \"$$KEY_FILE\")"; \
	    echo '  for key in "$${KEYS[@]}"; do vault operator unseal "$$key"; done';

vault-reinit-dry-run:
	    @VAULT_HCL="$(VAULT_HCL)" VAULT_UNIT="$(VAULT_UNIT)" ENV_FILE="$(ENV_FILE)" VAULT_ADDR="$(VAULT_ADDR)" VAULT_CACERT="$(VAULT_CACERT)" VAULT_SKIP_VERIFY="$(VAULT_SKIP_VERIFY)" VAULT_RECOVERY_DIR="$(VAULT_RECOVERY_DIR)" VAULT_INIT_SHARES="$(VAULT_INIT_SHARES)" VAULT_INIT_THRESHOLD="$(VAULT_INIT_THRESHOLD)" VAULT_RECOVERY_PASSPHRASE="$(VAULT_RECOVERY_PASSPHRASE)" "$(VAULT_REINIT_SCRIPT)" --yes-i-understand-data-loss --dry-run $(VAULT_REINIT_OPTS)

vault-reinit:
	    @echo "${RED}--- DESTRUCTIVE: Vault reinitialization (data loss) ---${NC}"
	    @if [ "$(CONFIRM)" != "YES" ]; then \
	            echo "${RED}Refusing to run. Re-run with: make vault-reinit CONFIRM=YES${NC}"; \
	            exit 1; \
	    fi
	    @VAULT_HCL="$(VAULT_HCL)" VAULT_UNIT="$(VAULT_UNIT)" ENV_FILE="$(ENV_FILE)" VAULT_ADDR="$(VAULT_ADDR)" VAULT_CACERT="$(VAULT_CACERT)" VAULT_SKIP_VERIFY="$(VAULT_SKIP_VERIFY)" VAULT_RECOVERY_DIR="$(VAULT_RECOVERY_DIR)" VAULT_INIT_SHARES="$(VAULT_INIT_SHARES)" VAULT_INIT_THRESHOLD="$(VAULT_INIT_THRESHOLD)" VAULT_RECOVERY_PASSPHRASE="$(VAULT_RECOVERY_PASSPHRASE)" "$(VAULT_REINIT_SCRIPT)" --yes-i-understand-data-loss $(VAULT_REINIT_OPTS)
	    @echo "${GREEN}✓ Vault reinit completed. Use make vault-recovery-list to inspect artifacts.${NC}"

vault-recovery-list:
	    @RECOVERY_DIR="$${VAULT_RECOVERY_DIR:-$(VAULT_RECOVERY_DIR)}"; \
	    if [ -d "$$RECOVERY_DIR" ]; then \
	            echo "Vault recovery directory: $$RECOVERY_DIR"; \
	            ls -la "$$RECOVERY_DIR"; \
	    else \
	            echo "${YELLOW}Vault recovery directory not found: $$RECOVERY_DIR${NC}"; \
	    fi

snippets: render-snippets
	    @$(MAKE) upload-snippets ENVIRONMENT=$(ENVIRONMENT)

packer-build:
	    @echo "${YELLOW}--- Building Packer template for ${ENVIRONMENT} ---${NC}"
	    @if [ ! -d "$(PACKER_DIR)" ]; then \
	            echo "${RED}Error: PACKER_DIR $(PACKER_DIR) not found${NC}"; \
	            exit 1; \
	    fi
	    @if [ ! -f "$(PACKER_DIR)/$(PACKER_TEMPLATE)" ]; then \
	            echo "${RED}Error: PACKER_TEMPLATE $(PACKER_DIR)/$(PACKER_TEMPLATE) not found${NC}"; \
	            exit 1; \
	    fi
	    @if [ ! -f "$(PACKER_VARS)" ]; then \
	            echo "${RED}Error: $(PACKER_VARS) not found.${NC}"; \
	            echo "${YELLOW}Tip:${NC} copy $(PACKER_DIR)/vars.example.pkrvars.hcl to $(PACKER_VARS) and fill values."; \
	            exit 1; \
	    fi
	    @set -e; \
	    if [ "$(PACKER_USE_VAULT_CREDS)" = "true" ]; then \
	            VAULT_OVERRIDE_FILE="$$(mktemp --suffix=.pkrvars.hcl)"; \
	            trap 'rm -f "$$VAULT_OVERRIDE_FILE"' EXIT; \
	            ENVIRONMENT="$(ENVIRONMENT)" VAULT_PATH="$(PACKER_VAULT_PATH)" "$(PACKER_VAULT_RENDER_SCRIPT)" "$$VAULT_OVERRIDE_FILE"; \
	            (cd "$(PACKER_DIR)" && packer init .); \
	            (cd "$(PACKER_DIR)" && packer build -var-file="$(notdir $(PACKER_VARS))" -var-file="$$VAULT_OVERRIDE_FILE" "$(PACKER_TEMPLATE)"); \
	    else \
	            (cd "$(PACKER_DIR)" && packer init .); \
	            (cd "$(PACKER_DIR)" && packer build -var-file="$(notdir $(PACKER_VARS))" "$(PACKER_TEMPLATE)"); \
	    fi
	    @echo "${GREEN}✓ Packer build complete for $(ENVIRONMENT)${NC}"

packer-build-all:
	    @echo "${YELLOW}--- Building all Packer templates for ${ENVIRONMENT} ---${NC}"
	    @$(MAKE) packer-build-ubuntu2404 ENVIRONMENT=$(ENVIRONMENT)
	    @$(MAKE) packer-build-oracle8 ENVIRONMENT=$(ENVIRONMENT)
	    @$(MAKE) packer-build-oracle9 ENVIRONMENT=$(ENVIRONMENT)
	    @echo "${GREEN}✓ All Packer builds complete for $(ENVIRONMENT)${NC}"

packer-build-ubuntu2404:
	    @$(MAKE) packer-build PACKER_DIR=packer/ubuntu-noble PACKER_TEMPLATE=ubuntu-noble.pkr.hcl PACKER_VARS=packer/ubuntu-noble/vars.$(ENVIRONMENT).pkrvars.hcl

packer-build-oracle8:
	    @$(MAKE) packer-build PACKER_DIR=packer/oracle8 PACKER_TEMPLATE=oracle8.pkr.hcl PACKER_VARS=packer/oracle8/vars.$(ENVIRONMENT).pkrvars.hcl

packer-build-oracle9:
	    @$(MAKE) packer-build PACKER_DIR=packer/oracle9 PACKER_TEMPLATE=oracle9.pkr.hcl PACKER_VARS=packer/oracle9/vars.$(ENVIRONMENT).pkrvars.hcl

packer-destroy-all:
	    @echo "${YELLOW}--- Destroying packer-generated VMs for ${ENVIRONMENT} ---${NC}"
	    @ENVIRONMENT="$(ENVIRONMENT)" PACKER_USE_VAULT_CREDS="$(PACKER_USE_VAULT_CREDS)" VAULT_PATH="$(PACKER_VAULT_PATH)" ./scripts/packer-destroy-all.sh
	    @echo "${GREEN}✓ Packer destroy completed for $(ENVIRONMENT)${NC}"

# Generate Terraform plan
plan: validate workspace-select
	    @echo "${YELLOW}--- Generating Terraform plan for ${ENVIRONMENT} ---${NC}"
	    @if [ ! -f "environments/$(ENVIRONMENT).tfvars" ]; then \
	            echo "${RED}Error: environments/$(ENVIRONMENT).tfvars not found${NC}"; \
	            exit 1; \
	    fi
	    @set -e; \
	    TFVARS_FILE="environments/$(ENVIRONMENT).tfvars"; \
	    PLAN_FILE="$(PLAN_DIR)/$(ENVIRONMENT).tfplan"; \
	    LOG_FILE="$(LOG_DIR)/terraform-plan-$(ENVIRONMENT)-$$(date +%Y%m%d-%H%M%S).log"; \
	    run_plan() { \
	            /bin/bash -lc "set -a; [ -f \"$(ENV_FILE)\" ] && source \"$(ENV_FILE)\"; set +a; set -o pipefail; $(WITH_VAULT_TOKEN_SCRIPT) terraform plan -var-file=\"$$TFVARS_FILE\" -out=\"$$PLAN_FILE\" 2>&1 | tee \"$$LOG_FILE\""; \
	    }; \
	    if run_plan; then \
	            echo "${GREEN}✓ Terraform plan generated: $$PLAN_FILE${NC}"; \
	    else \
	            VAULT_AUTH_MODE="$$(awk -F= '/^[[:space:]]*vault_auth_mode[[:space:]]*=/{gsub(/[[:space:]]|"/, "", $$2); print tolower($$2); exit}' "$$TFVARS_FILE")"; \
	            MANAGE_VAULT_ACCESS="$$(awk -F= '/^[[:space:]]*manage_vault_access[[:space:]]*=/{gsub(/[[:space:]]|"/, "", $$2); print tolower($$2); exit}' "$$TFVARS_FILE")"; \
	            SHOULD_BOOTSTRAP="false"; \
	            if [ "$$MANAGE_VAULT_ACCESS" = "true" ] && grep -Eqi 'path is already in use|already in use at' "$$LOG_FILE"; then \
	                    SHOULD_BOOTSTRAP="true"; \
	            fi; \
	            if [ "$$VAULT_AUTH_MODE" = "approle" ] && [ "$$MANAGE_VAULT_ACCESS" = "true" ] && grep -Eqi 'auth/approle/login|approle/login' "$$LOG_FILE"; then \
	                    SHOULD_BOOTSTRAP="true"; \
	            fi; \
	            if [ "$$SHOULD_BOOTSTRAP" = "true" ]; then \
	                    echo "${YELLOW}Vault bootstrap condition detected; running vault-bootstrap and retrying plan...${NC}"; \
	                    $(MAKE) --no-print-directory vault-bootstrap ENVIRONMENT=$(ENVIRONMENT); \
	                    LOG_FILE="$(LOG_DIR)/terraform-plan-$(ENVIRONMENT)-$$(date +%Y%m%d-%H%M%S)-retry.log"; \
	                    run_plan; \
	                    echo "${GREEN}✓ Terraform plan generated after Vault bootstrap: $$PLAN_FILE${NC}"; \
	            else \
	                    exit 1; \
	            fi; \
	    fi

# Apply Terraform plan
apply:
	    @$(MAKE) snippets ENVIRONMENT=$(ENVIRONMENT)
	    @$(MAKE) plan ENVIRONMENT=$(ENVIRONMENT)
	    @echo "${YELLOW}--- Applying Terraform plan for ${ENVIRONMENT} ---${NC}"
	    @/bin/bash -lc "set -a; [ -f \"$(ENV_FILE)\" ] && source \"$(ENV_FILE)\"; set +a; set -o pipefail; $(WITH_VAULT_TOKEN_SCRIPT) terraform apply \"$(PLAN_DIR)/$(ENVIRONMENT).tfplan\" 2>&1 | tee \"$(LOG_DIR)/terraform-apply-$(ENVIRONMENT)-$$(date +%Y%m%d-%H%M%S).log\""
	    @echo "${GREEN}✓ Terraform applied for $(ENVIRONMENT)${NC}"
	    @$(MAKE) generate-inventory

generate-inventory: create-dirs
	    @echo "${CYAN}--- Generating Ansible inventory for ${ENVIRONMENT} ---${NC}"
	    @if [ -f "$(INVENTORY_FILE)" ]; then \
	            echo "${GREEN}✓ Inventory available at: $(INVENTORY_FILE)${NC}"; \
	    else \
	            echo "${YELLOW}Warning: Terraform inventory file not found.${NC}"; \
	    fi
	    @if [ -f "deployment-summary-$(ENVIRONMENT).json" ]; then \
	            mv "deployment-summary-$(ENVIRONMENT).json" "$(SUMMARY_DIR)/deployment-summary-$(ENVIRONMENT).json"; \
	            echo "${GREEN}✓ Deployment summary moved to: $(SUMMARY_DIR)/deployment-summary-$(ENVIRONMENT).json${NC}"; \
	    elif [ -f "$(SUMMARY_DIR)/deployment-summary-$(ENVIRONMENT).json" ]; then \
	            echo "${GREEN}✓ Deployment summary already at: $(SUMMARY_DIR)/deployment-summary-$(ENVIRONMENT).json${NC}"; \
	    else \
	            echo "${YELLOW}Warning: Deployment summary file not found.${NC}"; \
	    fi

# Complete deployment workflow
deploy: fmt init validate workspace-create workspace-select plan apply
	    @echo "${GREEN}--- Complete deployment to ${ENVIRONMENT} completed ---${NC}"
	    @echo "${BLUE}--- Deployment Summary ---${NC}"
	    @if [ -f "$(SUMMARY_DIR)/deployment-summary-$(ENVIRONMENT).json" ]; then \
	            cat "$(SUMMARY_DIR)/deployment-summary-$(ENVIRONMENT).json" | jq . 2>/dev/null || cat "$(SUMMARY_DIR)/deployment-summary-$(ENVIRONMENT).json"; \
	    fi

# Validate environment inputs used by helper targets
check-env:
	@if [ ! -f "environments/$(ENVIRONMENT).tfvars" ]; then \
		echo "${RED}Error: environments/$(ENVIRONMENT).tfvars not found${NC}"; \
		exit 1; \
	fi

# Kubernetes deployment
k8s-deploy: check-env ## Deploy Kubernetes cluster
	@echo "Deploying Kubernetes cluster for $(ENVIRONMENT)..."
	@if [ ! -d "$(KUBESPRAY_DIR)" ]; then \
		echo "Error: Kubespray directory not found at $(KUBESPRAY_DIR)"; \
		echo "Please clone it or set KUBESPRAY_DIR variable."; \
		exit 1; \
	fi
	@if [ ! -f "$(INVENTORY_FILE)" ]; then \
		echo "Error: Inventory file not found at $(INVENTORY_FILE)"; \
		exit 1; \
	fi
	@echo "Installing python requirements..."
	@cd "$(KUBESPRAY_DIR)" && $(HOME)/.pyenv/versions/v3.13.14/bin/pip install -r requirements.txt
	@echo "Running Ansible Playbook..."
	@cd "$(KUBESPRAY_DIR)" && $(HOME)/.pyenv/versions/v3.13.14/bin/ansible-playbook -i "$(INVENTORY_FILE)" -i "$(INVENTORY_DIR)/../aliases.ini" \
		--become --become-user=root \
		--vault-password-file "$(MAKEFILE_DIR)/../ansible/.vault_password" \
		cluster.yml \
		--extra-vars "ansible_user=ansible ansible_ssh_private_key_file=~/.ssh/id_rsa"
	@echo "Kubernetes cluster deployed for $(ENVIRONMENT)!"

# Backup current state
backup: create-dirs workspace-select
	    @echo "${YELLOW}--- Backing up state for ${ENVIRONMENT} ---${NC}"
	    @BACKUP_TIME=$$(date +%Y%m%d-%H%M%S); \
	    BACKUP_FILE="$(BACKUP_DIR)/backup-$(ENVIRONMENT)-$$BACKUP_TIME.tar.gz"; \
	    tar -czf "$$BACKUP_FILE" \
	            terraform.tfstate.d/$(ENVIRONMENT)/ \
	            $(PLAN_DIR)/$(ENVIRONMENT).tfplan \
	            $(INVENTORY_FILE) \
	            $(SUMMARY_DIR)/*$(ENVIRONMENT)* \
	            environments/$(ENVIRONMENT).tfvars 2>/dev/null || true; \
	    echo "${GREEN}✓ Backup created: $$BACKUP_FILE${NC}"

# Destroy resources with proper confirmation
destroy: workspace-select backup
	    @echo "${YELLOW}--- Destroying Terraform resources in ${ENVIRONMENT} ---${NC}"
	    @echo "${RED}WARNING: This will destroy ALL resources in the $(ENVIRONMENT) environment!${NC}"
	    @set -e; \
	    read -p "Type 'yes' to confirm destruction of $(ENVIRONMENT) environment: " confirm; \
	    if [ "$$confirm" = "yes" ]; then \
	            if [ ! -f "environments/$(ENVIRONMENT).tfvars" ]; then \
	              echo "${RED}Error: environments/$(ENVIRONMENT).tfvars not found${NC}"; \
	              exit 1; \
	            fi; \
		            /bin/bash -lc "set -o pipefail; $(WITH_VAULT_TOKEN_SCRIPT) terraform destroy -var-file=\"environments/$(ENVIRONMENT).tfvars\" -auto-approve 2>&1 | tee \"$(LOG_DIR)/terraform-destroy-$(ENVIRONMENT)-$$(date +%Y%m%d-%H%M%S).log\""; \
	            echo "${GREEN}✓ Resources destroyed for $(ENVIRONMENT)${NC}"; \
	    else \
	            echo "${BLUE}Destroy operation cancelled.${NC}"; \
	    fi

# Clean ALL Terraform files and workspaces (nuclear option)
clean-all:
	@echo "${RED}--- WARNING: This will remove ALL terraform-generated files and workspaces, reverting to original clean code.  ---${NC}"
	@read -p "Type 'CLEAN_ALL' to confirm complete cleanup: " confirm; \
	if [ "$$confirm" = "CLEAN_ALL" ]; then \
		$(MAKE) clean; \
		echo "${YELLOW}Removing all Terraform files...${NC}"; \
		find . -name "*.tfstate*" -delete 2>/dev/null || true; \
		find . -name ".terraform.tfstate.lock.info" -delete 2>/dev/null || true; \
		rm -rf .terraform 2>/dev/null || true; \
		rm -rf terraform.tfstate.d 2>/dev/null || true; \
		rm -f .terraform.lock.hcl 2>/dev/null || true; \
		rm -f .env secrets.auto.tfvars 2>/dev/null || true; \
		rm -f deployment-summary-*.json crash.log 2>/dev/null || true; \
		echo "${YELLOW}Removing Terraform plugin cache...${NC}"; \
		if [ -n "$$TF_PLUGIN_CACHE_DIR" ]; then rm -rf "$$TF_PLUGIN_CACHE_DIR" 2>/dev/null || true; fi; \
		rm -rf "$$HOME/.terraform.d/plugin-cache" 2>/dev/null || true; \
		echo "${GREEN}✓ Complete cleanup finished${NC}"; \
	else \
		echo "${BLUE}Complete cleanup cancelled.${NC}"; \
	fi

# Clean generated artifacts but keep Terraform state and caches
clean:
	@echo "${YELLOW}--- Cleaning generated artifacts (state preserved) ---${NC}"
	@rm -rf $(PLAN_DIR)/ 2>/dev/null || true; \
	 rm -f $(INVENTORY_FILE) 2>/dev/null || true; \
	 rm -rf $(LEGACY_INVENTORY_DIR) 2>/dev/null || true; \
	 rm -rf $(SUMMARY_DIR)/ 2>/dev/null || true; \
	 rm -rf $(LOG_DIR)/ 2>/dev/null || true; \
	 rm -rf $(BACKUP_DIR)/ 2>/dev/null || true; \
	 rm -rf tmp 2>/dev/null || true; \
	 rm -rf tmp_venv 2>/dev/null || true; \
	 rm -f deployment-summary-*.json crash.log 2>/dev/null || true
	@echo "${GREEN}✓ Clean complete (state preserved)${NC}"

clean-legacy-inventory:
	@echo "${YELLOW}--- Removing deprecated local inventory directory ---${NC}"
	@if [ -d "$(LEGACY_INVENTORY_DIR)" ]; then \
		rm -rf "$(LEGACY_INVENTORY_DIR)"; \
		echo "${GREEN}✓ Removed: $(LEGACY_INVENTORY_DIR)${NC}"; \
	else \
		echo "${GREEN}✓ No legacy local inventory directory found.${NC}"; \
	fi

# Quick workspace switching helpers
dev:
	    @$(MAKE) workspace-select ENVIRONMENT=dev

prod:
	    @$(MAKE) workspace-select ENVIRONMENT=prod

testing:
	    @$(MAKE) workspace-select ENVIRONMENT=testing

tq-pve1:
	    @$(MAKE) workspace-select ENVIRONMENT=tq-pve1

# Show workspace-specific resources
show: workspace-select
	    @echo "${YELLOW}--- Terraform state for ${ENVIRONMENT} ---${NC}"
	    @terraform show

# Show organized project tree
tree:
	    @echo "${CYAN}--- Project Structure ---${NC}"
	    @if command -v tree >/dev/null 2>&1; then \
	            tree -I 'node_modules|.git|.terraform' --dirsfirst -a; \
	    else \
	            echo "📁 Project Root"; \
	            echo "├── 📁 environments/     (Environment configurations)"; \
	            ls environments/*.tfvars 2>/dev/null | sed 's/^/│   ├── 📄 /' || echo "│   └── (no files)"; \
	            echo "├── 📁 $(PLAN_DIR)/          (Terraform plans)"; \
	            ls $(PLAN_DIR)/*.tfplan 2>/dev/null | sed 's/^/│   ├── 📋 /' || echo "│   └── (no files)"; \
	            echo "├── 📁 $(INVENTORY_DIR)/    (Ansible inventories)"; \
	            ls $(INVENTORY_DIR)/*.ini 2>/dev/null | sed 's/^/│   ├── 📝 /' || echo "│   └── (no files)"; \
	            echo "├── 📁 $(SUMMARY_DIR)/      (Deployment summaries)"; \
	            ls $(SUMMARY_DIR)/*.json 2>/dev/null | sed 's/^/│   ├── 📊 /' || echo "│   └── (no files)"; \
	            echo "├── 📁 $(LOG_DIR)/           (Log files)"; \
	            ls $(LOG_DIR)/*.log 2>/dev/null | head -3 | sed 's/^/│   ├── 📋 /' || echo "│   └── (no files)"; \
	            echo "├── 📁 $(BACKUP_DIR)/        (State backups)"; \
	            ls $(BACKUP_DIR)/*.tar.gz 2>/dev/null | head -3 | sed 's/^/│   ├── 💾 /' || echo "│   └── (no files)"; \
	            echo "└── 📁 modules/           (Terraform modules)"; \
	    fi
