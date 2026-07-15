// backend.tf
// Backend configuration for state management
// Configure the terraform-proxmox root module to store Terraform state in Cloudflare R2.
// Replace the placeholder bucket and endpoint values with your own.
// If you are switching from local state, run `terraform init -reconfigure`.

terraform {
  backend "s3" {
    bucket               = "terraform-bucket"
    key                  = "terraform.tfstate"
    workspace_key_prefix = "terraform-proxmox"
    region               = "us-east-1"
    endpoints = {
      s3 = "https://2c7479a73e537ded1f6087e1089f737d.r2.cloudflarestorage.com"
    }
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_metadata_api_check     = true
    skip_requesting_account_id  = true
    use_path_style              = false

    # Native S3-backend state locking (Terraform >= 1.10).
    # Writes a <key>.tflock object to R2 alongside the state file.
    # No DynamoDB or external infrastructure required.
    # Lock is acquired before plan/apply and released on completion or forced
    # with: terraform force-unlock <lock-id>
    use_lockfile = true
  }
}

// Example: S3 Backend
// terraform {
//   backend "s3" {
//     bucket = "your-terraform-state-bucket"
//     key    = "proxmox/terraform.tfstate"
//     region = "us-east-1"
//
//     // Optional: DynamoDB table for state locking
//     dynamodb_table = "terraform-state-locks"
//     encrypt        = true
//   }
// }

// Example: Remote Backend (Terraform Cloud/Enterprise)
// terraform {
//   backend "remote" {
//     organization = "your-org"
//
//     workspaces {
//       prefix = "proxmox-"
//     }
//   }
// }

// Example: Azure Backend
// terraform {
//   backend "azurerm" {
//     resource_group_name  = "terraform-state-rg"
//     storage_account_name = "terraformstate"
//     container_name       = "tfstate"
//     key                  = "proxmox.terraform.tfstate"
//   }
// }

// Example: GCS Backend
// terraform {
//   backend "gcs" {
//     bucket = "your-terraform-state-bucket"
//     prefix = "proxmox"
//   }
// }

// Default: Local backend (current behavior)
// No backend configuration = local backend
