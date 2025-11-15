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
  default     = "default"
}

variable "serial_port" {
  type        = string
  description = "Serial port for Zigbee adapter"
}

variable "serial_adapter" {
  type        = string
  description = "Serial adapter type for Zigbee adapter"
}

variable "zigbee_channel" {
  type        = number
  description = "Zigbee channel for the adapter"
}

variable "zigbee_pan_id" {
  type        = number
  description = "Zigbee PAN ID for the network"
}

variable "zigbee_ext_pan_id" {
  type        = string
  description = "Zigbee Extended PAN ID for the network as a 16-character hexadecimal string"
}

variable "zigbee_network_key" {
  type        = string
  description = "Zigbee Network Key for the network as a 32-character hexadecimal string"
  sensitive   = true
}

variable "http_route_parent_refs" {
  description = "List of Gateway parentRefs for the HTTPRoute. Each item may include name, namespace, and sectionName."
  type = list(object({
    name         = string
    namespace    = optional(string)
    section_name = optional(string)
  }))
  default = [
    {
      name         = "gateway"
      section_name = "http"
    }
  ]
}
