variable "cloudflare_api_token" {
  type        = string
  description = "Cloudflare API token with the necessary permissions for managed resources."
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

variable "force_update_secrets" {
  description = "DANGER: Allow updating protected secret keys. This will break your Zigbee network!"
  type        = bool
  default     = false
}
