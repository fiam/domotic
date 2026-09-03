variable "cloudflare_api_token" {
  description = "Cloudflare account API token used to manage the installation foundation."
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare account that owns this installation."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.cloudflare_account_id))
    error_message = "Cloudflare account ID must be 32 lowercase hexadecimal characters."
  }
}

variable "r2_bucket_prefix" {
  description = "Unique prefix for this installation's <prefix>-state and <prefix>-backups buckets."
  type        = string

  validation {
    condition = (
      length(var.r2_bucket_prefix) <= 55 &&
      can(regex("^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$", var.r2_bucket_prefix))
    )
    error_message = "R2 bucket prefix must contain at most 55 lowercase letters, numbers, or internal hyphens."
  }
}

variable "r2_location" {
  description = "Optional best-effort R2 location hint applied when both buckets are created."
  type        = string
  default     = null

  validation {
    condition = (
      var.r2_location == null ||
      contains(["apac", "eeur", "enam", "weur", "wnam", "oc"], var.r2_location)
    )
    error_message = "R2 location must be one of apac, eeur, enam, weur, wnam, or oc."
  }
}

variable "r2_jurisdiction" {
  description = "R2 jurisdiction used for storage and bucket-scoped token resource names."
  type        = string
  default     = "default"

  validation {
    condition     = contains(["default", "eu", "fedramp", "us"], var.r2_jurisdiction)
    error_message = "R2 jurisdiction must be default, eu, fedramp, or us."
  }
}
