variable "kv_mount_path" {
  description = "KV v2 mount path used for Terraform environment secrets."
  type        = string
  default     = "secret"
}

variable "create_kv_mount" {
  description = "Whether to create/manage the KV mount resource."
  type        = bool
  default     = true
}

variable "kv_max_versions" {
  description = "Maximum number of secret versions kept per key."
  type        = number
  default     = 20
}

variable "kv_delete_version_after_seconds" {
  description = "Seconds after which secret versions are deleted."
  type        = number
  default     = 2592000
}

variable "kv_cas_required" {
  description = "Require CAS for writes to KV v2 keys."
  type        = bool
  default     = true
}

variable "policy_name" {
  description = "Vault policy name for Terraform Proxmox credential reads."
  type        = string
  default     = "terraform-proxmox"
}

variable "approle_path" {
  description = "Auth path where AppRole backend is enabled."
  type        = string
  default     = "approle"
}

variable "approle_role_name" {
  description = "AppRole role name for Terraform Proxmox operations."
  type        = string
  default     = "terraform-proxmox"
}

variable "secret_prefix" {
  description = "Prefix under KV v2 mount containing per-environment credential paths."
  type        = string
  default     = "terraform"
}

variable "token_ttl_seconds" {
  description = "Default AppRole token TTL in seconds."
  type        = number
  default     = 3600
}

variable "token_max_ttl_seconds" {
  description = "Maximum AppRole token TTL in seconds."
  type        = number
  default     = 86400
}

variable "approle_bind_secret_id" {
  description = "Whether AppRole login requires a secret_id."
  type        = bool
  default     = true
}

variable "approle_secret_id_num_uses" {
  description = "Maximum number of times a secret_id can be used (0 means unlimited)."
  type        = number
  default     = 0
}

variable "approle_secret_id_ttl_seconds" {
  description = "Secret ID TTL in seconds (0 means no expiry)."
  type        = number
  default     = 0
}

variable "approle_secret_id_bound_cidrs" {
  description = "CIDR blocks allowed to use the secret_id."
  type        = set(string)
  default     = []
}

variable "approle_token_bound_cidrs" {
  description = "CIDR blocks allowed to use tokens issued by this AppRole."
  type        = set(string)
  default     = []
}

variable "approle_token_no_default_policy" {
  description = "If true, tokens do not include Vault default policy."
  type        = bool
  default     = false
}

variable "approle_token_num_uses" {
  description = "Maximum uses for tokens issued by this AppRole (0 means unlimited)."
  type        = number
  default     = 0
}
