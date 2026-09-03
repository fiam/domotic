variable "state_passphrase" {
  description = "Passphrase used by OpenTofu to encrypt state and plan files."
  type        = string
  sensitive   = true
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
  description = "First-boot behavior: seed initializes the owner, chart defaults, and integrations; restore starts only the native Home Assistant backup recovery flow and preserves restored configuration."
  type        = string
  default     = "seed"

  validation {
    condition     = contains(["seed", "restore"], var.homeassistant_bootstrap_mode)
    error_message = "Home Assistant bootstrap mode must be seed or restore."
  }
}

variable "homeassistant_owner" {
  description = "Non-secret profile for the Home Assistant owner created during seed mode."
  type = object({
    name     = optional(string, "Home Administrator")
    username = optional(string, "admin")
    language = optional(string, "en")
  })
  default = {}

  validation {
    condition = (
      length(trimspace(var.homeassistant_owner.name)) > 0 &&
      var.homeassistant_owner.username == lower(trimspace(var.homeassistant_owner.username)) &&
      length(regexall("\\s", var.homeassistant_owner.username)) == 0 &&
      length(var.homeassistant_owner.username) > 0 &&
      can(regex("^[a-z]{2}(-[A-Z]{2})?$", var.homeassistant_owner.language))
    )
    error_message = "Home Assistant owner requires a name, a lowercase username without whitespace, and a language such as en or en-GB."
  }
}

variable "homeassistant_admin_password_override" {
  description = "One-time owner password used only when explicitly replacing the credential retained in encrypted state."
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition = (
      var.homeassistant_admin_password_override == null ||
      (
        length(var.homeassistant_admin_password_override) >= 6 &&
        length(var.homeassistant_admin_password_override) <= 72
      )
    )
    error_message = "The Home Assistant owner password must contain 6-72 characters."
  }
}

variable "homeassistant_admin_username_override" {
  description = "One-time owner username used with an explicit credential replacement."
  type        = string
  default     = null

  validation {
    condition = (
      var.homeassistant_admin_username_override == null ||
      (
        var.homeassistant_admin_username_override == lower(trimspace(var.homeassistant_admin_username_override)) &&
        length(regexall("\\s", var.homeassistant_admin_username_override)) == 0 &&
        length(var.homeassistant_admin_username_override) > 0
      )
    )
    error_message = "The replacement Home Assistant username must be lowercase and contain no whitespace."
  }
}

variable "homeassistant_remote_custom_components" {
  description = "Public, immutable Home Assistant custom-integration repository or release archives installed by Kubernetes init containers. URLs and checksums are written to non-secret Helm values; never place credentials in a URL."
  type = list(object({
    name         = string
    url          = string
    sha256       = string
    archive_path = string
  }))
  default = []

  validation {
    condition = (
      length(distinct([for component in var.homeassistant_remote_custom_components : component.name])) == length(var.homeassistant_remote_custom_components) &&
      alltrue([
        for component in var.homeassistant_remote_custom_components :
        length(component.name) <= 50 &&
        can(regex("^[a-z][a-z0-9_]*$", component.name)) &&
        startswith(component.url, "https://") &&
        can(regex("^[0-9A-Fa-f]{64}$", component.sha256)) &&
        length(component.archive_path) > 0 &&
        !startswith(component.archive_path, "/") &&
        !strcontains(component.archive_path, "..")
      ])
    )
    error_message = "Remote custom integrations need unique lowercase Home Assistant domains, HTTPS URLs, 64-character SHA-256 values, and safe relative archive paths."
  }
}

# ==============================================================================
# Backup Configuration
# ==============================================================================

variable "r2_backup_bucket_name" {
  description = "Private R2 bucket prepared by the bootstrap stack for Home Assistant backups."
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

variable "r2_backup_credentials" {
  description = "Bucket-scoped S3 credentials created by the bootstrap stack."
  type = object({
    access_key_id     = string
    secret_access_key = string
  })
  default   = null
  sensitive = true
}

variable "r2_endpoint" {
  description = "S3-compatible R2 endpoint supplied by the bootstrap stack."
  type        = string
  default     = null

  validation {
    condition = (
      var.r2_endpoint == null ||
      can(regex("^https://[0-9a-f]{32}(?:\\.(?:eu|us|fedramp))?\\.r2\\.cloudflarestorage\\.com$", var.r2_endpoint))
    )
    error_message = "The R2 endpoint must be the account's Cloudflare R2 HTTPS endpoint."
  }
}

locals {
  effective_r2_endpoint = coalesce(
    var.r2_endpoint,
    "https://${var.cloudflare_account_id}.r2.cloudflarestorage.com"
  )
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
  description = "First-boot automatic backup defaults when R2 is enabled in seed mode. Home Assistant owns the settings after they are initialized."
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

variable "homeassistant_backup_encryption_enabled" {
  description = "Generate and retain a password for encrypted native Home Assistant backups."
  type        = bool
  default     = false
}

# ==============================================================================
# Zigbee Configuration
# ==============================================================================

variable "zigbee_network_key" {
  description = "One-time Zigbee network key override used when explicitly importing an identity."
  type        = string
  sensitive   = true
  default     = null

  validation {
    condition     = var.zigbee_network_key == null || can(regex("^[0-9A-Fa-f]{32}$", var.zigbee_network_key))
    error_message = "Network key must be exactly 32 hexadecimal characters."
  }
}

variable "zigbee_ext_pan_id" {
  description = "One-time Zigbee extended PAN ID override used when explicitly importing an identity."
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
