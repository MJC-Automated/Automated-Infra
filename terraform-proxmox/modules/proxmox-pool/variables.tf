variable "poolid" {
  description = "Pool identifier."
  type        = string
}

variable "comment" {
  description = "Pool comment."
  type        = string
  default     = "Managed by Terraform"
}
