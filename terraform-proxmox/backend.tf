// backend.tf
// Backend configuration for state management
// Uncomment and configure based on your preferred backend

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
