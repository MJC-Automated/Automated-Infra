// versions.tf
// Terraform and provider version constraints

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    proxmox = {
      source  = "Telmate/proxmox"
      version = "3.0.2-rc07"
    }
    local = {
      source  = "hashicorp/local"
      version = "2.7.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "5.7.0"
    }
  }
}
