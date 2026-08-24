variable "cloudflare_api_token" {
  type        = string
  description = "Cloudflare API token with the necessary permissions for managed resources."
  sensitive   = true
}

variable "cloudflare_api_token_id" {
  type        = string
  description = "Identifier of the account API token. Required when R2 backups are enabled so Terraform can derive S3 credentials from the same token."
  default     = null

  validation {
    condition = (
      var.cloudflare_api_token_id == null ||
      can(regex("^[0-9a-f]{32}$", var.cloudflare_api_token_id))
    )
    error_message = "Cloudflare account API token ID must be 32 lowercase hexadecimal characters."
  }
}

variable "cloudflare_account_id" {
  type        = string
  description = "Cloudflare Account ID"
  default     = null
}

variable "cloudflare_tunnel_name" {
  type        = string
  description = "Friendly name for the tunnel"
  default     = "domotic-tunnel"
}

variable "cloudflare_domain" {
  type        = string
  description = "Domain to create the subdomains for tunnel routing"
}

variable "cloudflare_homeassistant_subdomain" {
  type        = string
  description = "Subdomain for Home Assistant access"
  default     = "homeassistant"
}

variable "kubernetes_namespace" {
  type        = string
  description = "Kubernetes namespace to deploy resources"
  default     = "domotic"
}

variable "helm_release_name" {
  type        = string
  description = "Helm release name (used for computing service FQDNs)"
  default     = "domotic"
}

variable "local_http_hostnames" {
  description = "LAN or development hostnames assigned to the Home Assistant and Zigbee2MQTT HTTPRoutes."
  type = object({
    homeassistant = string
    zigbee2mqtt   = string
  })
  default = {
    homeassistant = "homeassistant.local"
    zigbee2mqtt   = "zigbee2mqtt.local"
  }

  validation {
    condition = alltrue([
      for hostname in values(var.local_http_hostnames) :
      length(hostname) <= 253 &&
      can(regex("^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$", hostname)) &&
      !strcontains(hostname, "..")
    ])
    error_message = "Local HTTPRoute hostnames must be lowercase DNS names without a scheme, port, or consecutive dots."
  }
}

variable "local_http_urls" {
  description = "Optional client-facing URLs for the local services. Defaults to HTTP on each local_http_hostnames value; set explicit ports for Kind."
  type = object({
    homeassistant = string
    zigbee2mqtt   = string
  })
  default = null

  validation {
    condition = var.local_http_urls == null || alltrue([
      for url in values(var.local_http_urls) :
      can(regex("^https?://[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]{1,5})?$", url))
    ])
    error_message = "Local service URLs must contain http:// or https://, a lowercase hostname, and an optional port, without a path."
  }
}

locals {
  effective_local_http_urls = var.local_http_urls != null ? var.local_http_urls : {
    homeassistant = "http://${var.local_http_hostnames.homeassistant}"
    zigbee2mqtt   = "http://${var.local_http_hostnames.zigbee2mqtt}"
  }
}

# ==============================================================================
# Home Assistant First-Boot Onboarding
# ==============================================================================

variable "homeassistant_bootstrap_mode" {
  description = "First-boot behavior: seed initializes chart defaults, integrations, and an optional owner; restore starts only the native Home Assistant backup recovery flow and preserves restored configuration."
  type        = string
  default     = "seed"

  validation {
    condition     = contains(["seed", "restore"], var.homeassistant_bootstrap_mode)
    error_message = "Home Assistant bootstrap mode must be seed or restore."
  }
}

variable "homeassistant_onboarding" {
  description = "Optional owner account used to complete Home Assistant's built-in but undocumented onboarding HTTP flow on a fresh volume. Existing completed onboarding is never overwritten."
  type = object({
    name     = string
    username = string
    password = string
    language = optional(string, "en")
  })
  default   = null
  sensitive = true

  validation {
    condition = var.homeassistant_onboarding == null || (
      length(trimspace(var.homeassistant_onboarding.name)) > 0 &&
      var.homeassistant_onboarding.username == lower(trimspace(var.homeassistant_onboarding.username)) &&
      length(regexall("\\s", var.homeassistant_onboarding.username)) == 0 &&
      length(var.homeassistant_onboarding.username) > 0 &&
      length(var.homeassistant_onboarding.password) >= 12 &&
      length(var.homeassistant_onboarding.password) <= 72 &&
      can(regex("^[a-z]{2}(-[A-Z]{2})?$", var.homeassistant_onboarding.language))
    )
    error_message = "Home Assistant onboarding requires a name, a lowercase username without whitespace, a 12-72 character password, and a language such as en or en-GB."
  }
}

# ==============================================================================
# Backup Configuration
# ==============================================================================

variable "r2_backup_bucket_name" {
  description = "Private Cloudflare R2 bucket for encrypted backups. Set to null to disable R2 backups."
  type        = string
  default     = null

  validation {
    condition = (
      var.r2_backup_bucket_name == null ||
      can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.r2_backup_bucket_name))
    )
    error_message = "R2 backup bucket name must be 3-63 lowercase letters, numbers, or hyphens and cannot start or end with a hyphen."
  }
}

variable "r2_backup_location" {
  description = "Optional R2 location hint such as weur. This is best-effort and only used when creating the bucket."
  type        = string
  default     = null

  validation {
    condition = (
      var.r2_backup_location == null ||
      contains(["apac", "eeur", "enam", "weur", "wnam", "oc"], var.r2_backup_location)
    )
    error_message = "R2 backup location must be one of apac, eeur, enam, weur, wnam, or oc."
  }
}

variable "homeassistant_r2_backup_prefix" {
  description = "Folder prefix used by Home Assistant inside the shared R2 backup bucket."
  type        = string
  default     = "home-assistant"

  validation {
    condition = (
      length(trim(var.homeassistant_r2_backup_prefix, "/")) > 0 &&
      !strcontains(var.homeassistant_r2_backup_prefix, "..")
    )
    error_message = "Home Assistant's R2 backup prefix must be non-empty and cannot contain '..'."
  }
}

variable "homeassistant_automatic_backups" {
  description = "First-boot automatic backup defaults when R2 and owner seeding are enabled. Home Assistant owns the settings after they are initialized."
  type = object({
    enabled          = optional(bool, true)
    retention_copies = optional(number, 7)
    time             = optional(string)
  })
  default = {}

  validation {
    condition = (
      var.homeassistant_automatic_backups.retention_copies >= 1 &&
      floor(var.homeassistant_automatic_backups.retention_copies) == var.homeassistant_automatic_backups.retention_copies
    )
    error_message = "Home Assistant automatic backup retention_copies must be a positive integer."
  }

  validation {
    condition = (
      var.homeassistant_automatic_backups.time == null ||
      can(regex("^(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$", var.homeassistant_automatic_backups.time))
    )
    error_message = "Home Assistant automatic backup time must be null or a 24-hour HH:MM:SS value."
  }
}

variable "homeassistant_backup_password" {
  description = "Optional password used when seed mode initializes native Home Assistant backups. Terraform generates one when R2 is enabled; preserve it outside the cluster for recovery."
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition = (
      var.homeassistant_backup_password == null ||
      (
        length(var.homeassistant_backup_password) >= 16 &&
        length(var.homeassistant_backup_password) <= 128
      )
    )
    error_message = "The Home Assistant backup password must contain 16-128 characters."
  }
}

# ==============================================================================
# Zigbee Configuration
# ==============================================================================

variable "generate_zigbee_keys" {
  description = "Generate new Zigbee keys. Only use on first setup!"
  type        = bool
  default     = false
}

variable "zigbee_network_key" {
  description = "Zigbee network encryption key (32 hex chars). Required unless generate_zigbee_keys=true."
  type        = string
  sensitive   = true
  default     = null

  validation {
    condition     = var.zigbee_network_key == null || can(regex("^[0-9A-Fa-f]{32}$", var.zigbee_network_key))
    error_message = "Network key must be exactly 32 hexadecimal characters."
  }
}

variable "zigbee_ext_pan_id" {
  description = "Zigbee extended PAN ID (16 hex chars). Required unless generate_zigbee_keys=true."
  type        = string
  default     = null

  validation {
    condition     = var.zigbee_ext_pan_id == null || can(regex("^[0-9A-Fa-f]{16}$", var.zigbee_ext_pan_id))
    error_message = "Extended PAN ID must be exactly 16 hexadecimal characters."
  }
}

variable "zigbee_pan_id" {
  description = "Zigbee PAN ID (0-65535). Protected - changing breaks network."
  type        = number
  default     = 6754

  validation {
    condition     = var.zigbee_pan_id >= 0 && var.zigbee_pan_id <= 65535
    error_message = "PAN ID must be between 0 and 65535."
  }
}

variable "zigbee_channel" {
  description = "Zigbee channel (11-26). Protected - changing breaks network."
  type        = number
  default     = 15

  validation {
    condition     = var.zigbee_channel >= 11 && var.zigbee_channel <= 26
    error_message = "Zigbee channel must be between 11 and 26."
  }
}

variable "zigbee_expected_pan_id" {
  description = "PAN ID recorded with an imported Zigbee identity. Used as a recovery guard and does not override zigbee_pan_id."
  type        = number
  default     = null

  validation {
    condition     = var.zigbee_expected_pan_id == null || (var.zigbee_expected_pan_id >= 0 && var.zigbee_expected_pan_id <= 65535)
    error_message = "Expected PAN ID must be null or between 0 and 65535."
  }
}

variable "zigbee_expected_channel" {
  description = "Channel recorded with an imported Zigbee identity. Used as a recovery guard and does not override zigbee_channel."
  type        = number
  default     = null

  validation {
    condition     = var.zigbee_expected_channel == null || (var.zigbee_expected_channel >= 11 && var.zigbee_expected_channel <= 26)
    error_message = "Expected Zigbee channel must be null or between 11 and 26."
  }
}

variable "force_update_secrets" {
  description = "DANGER: Allow updating protected secret keys. This will break your Zigbee network!"
  type        = bool
  default     = false
}
