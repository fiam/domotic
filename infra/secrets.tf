# ==============================================================================
# Zigbee Configuration Management (Protected)
# ==============================================================================
# This file manages both:
#   - ConfigMap: Non-sensitive network config (pan_id, channel)
#   - Secret: Sensitive network keys (network_key, ext_pan_id)
# Both are PROTECTED and require force_update_secrets=true to modify

# ------------------------------------------------------------------------------
# Check for Existing Resources
# ------------------------------------------------------------------------------

data "kubernetes_secret" "zigbee_keys_existing" {
  metadata {
    name      = "zigbee-keys"
    namespace = var.kubernetes_namespace
  }

  # Don't error if secret doesn't exist yet
  count = 1
}

data "kubernetes_config_map" "zigbee_network_existing" {
  metadata {
    name      = "zigbee-network"
    namespace = var.kubernetes_namespace
  }

  # Don't error if configmap doesn't exist yet
  count = 1
}

# ------------------------------------------------------------------------------
# Protection Logic
# ------------------------------------------------------------------------------

locals {
  # Check if resources exist
  secret_exists = try(data.kubernetes_secret.zigbee_keys_existing[0].metadata[0].name, null) != null
  configmap_exists = try(data.kubernetes_config_map.zigbee_network_existing[0].metadata[0].name, null) != null

  # Check if resources are marked as protected
  secret_protected = try(
    data.kubernetes_secret.zigbee_keys_existing[0].metadata[0].annotations["domotic.fiam.github.com/protected"],
    "false"
  ) == "true"

  configmap_protected = try(
    data.kubernetes_config_map.zigbee_network_existing[0].metadata[0].annotations["domotic.fiam.github.com/protected"],
    "false"
  ) == "true"

  # Get existing values from Secret (sensitive)
  existing_network_key = try(
    data.kubernetes_secret.zigbee_keys_existing[0].data["network_key"],
    null
  )
  existing_ext_pan_id = try(
    data.kubernetes_secret.zigbee_keys_existing[0].data["ext_pan_id"],
    null
  )

  # Get existing values from ConfigMap (non-sensitive)
  existing_pan_id = try(
    tonumber(data.kubernetes_config_map.zigbee_network_existing[0].data["pan_id"]),
    null
  )
  existing_channel = try(
    tonumber(data.kubernetes_config_map.zigbee_network_existing[0].data["channel"]),
    null
  )

  # Determine desired values
  desired_network_key = coalesce(
    var.zigbee_network_key,
    try(random_password.zigbee_network_key[0].result, null)
  )
  desired_ext_pan_id = coalesce(
    var.zigbee_ext_pan_id,
    try(random_id.zigbee_ext_pan_id[0].hex, null)
  )
  desired_pan_id  = var.zigbee_pan_id
  desired_channel = var.zigbee_channel

  # Check if protected fields would change (Secret)
  network_key_would_change = local.secret_exists && local.existing_network_key != local.desired_network_key
  ext_pan_id_would_change  = local.secret_exists && local.existing_ext_pan_id != local.desired_ext_pan_id

  secret_fields_would_change = (
    local.secret_protected &&
    (local.network_key_would_change || local.ext_pan_id_would_change)
  )

  # Check if protected fields would change (ConfigMap)
  pan_id_would_change  = local.configmap_exists && local.existing_pan_id != local.desired_pan_id
  channel_would_change = local.configmap_exists && local.existing_channel != local.desired_channel

  configmap_fields_would_change = (
    local.configmap_protected &&
    (local.pan_id_would_change || local.channel_would_change)
  )

  # Overall protection check
  protected_fields_would_change = local.secret_fields_would_change || local.configmap_fields_would_change

  # Validate we have all required values
  has_keys = (
    (var.zigbee_network_key != null && var.zigbee_ext_pan_id != null) ||
    var.generate_zigbee_keys
  )

  # Non-sensitive display values for error messages
  display_existing_network_key = local.existing_network_key != null ? nonsensitive(substr(local.existing_network_key, 0, 8)) : "unknown"
  display_desired_network_key = nonsensitive(substr(local.desired_network_key, 0, 8))
  display_existing_ext_pan_id = local.existing_ext_pan_id != null ? nonsensitive(local.existing_ext_pan_id) : "unknown"
  display_desired_ext_pan_id = nonsensitive(local.desired_ext_pan_id)

  # Build the error message with non-sensitive values
  protection_error_message = nonsensitive(<<-EOT
    ❌ PROTECTED ZIGBEE CONFIGURATION MODIFICATION BLOCKED!

    You're trying to change protected Zigbee network settings that will break your network!

    ${local.secret_fields_would_change ? "SECRET (sensitive keys):" : ""}
    ${local.network_key_would_change ? "  • network_key: ${local.display_existing_network_key}... → ${local.display_desired_network_key}..." : ""}
    ${local.ext_pan_id_would_change ? "  • ext_pan_id: ${local.display_existing_ext_pan_id} → ${local.display_desired_ext_pan_id}" : ""}

    ${local.configmap_fields_would_change ? "CONFIGMAP (network settings):" : ""}
    ${local.pan_id_would_change ? "  • pan_id: ${coalesce(local.existing_pan_id, 0)} → ${local.desired_pan_id}" : ""}
    ${local.channel_would_change ? "  • channel: ${coalesce(local.existing_channel, 0)} → ${local.desired_channel}" : ""}

    ⚠️  Changing these will break communication with ALL paired Zigbee devices!

    If you REALLY want to change these (requires re-pairing all devices):
      force_update_secrets = true

    Otherwise, check your terraform.tfvars matches your existing config:
      terraform output -json zigbee_config
  EOT
  )
}

# ------------------------------------------------------------------------------
# Key Generation (only if requested)
# ------------------------------------------------------------------------------

resource "random_password" "zigbee_network_key" {
  count = var.generate_zigbee_keys && var.zigbee_network_key == null ? 1 : 0

  length  = 32
  special = false
  upper   = true
  lower   = false
  numeric = true

  lifecycle {
    ignore_changes = all
  }
}

resource "random_id" "zigbee_ext_pan_id" {
  count = var.generate_zigbee_keys && var.zigbee_ext_pan_id == null ? 1 : 0

  byte_length = 8

  lifecycle {
    ignore_changes = all
  }
}

# ------------------------------------------------------------------------------
# Protection Check
# ------------------------------------------------------------------------------

resource "terraform_data" "zigbee_protection_check" {
  lifecycle {
    # Check 1: Must provide keys or request generation
    precondition {
      condition     = local.has_keys
      error_message = <<-EOT
        ❌ Missing Zigbee keys!

        You must either:
          1. Provide both keys:
             zigbee_network_key = "32-hex-chars"
             zigbee_ext_pan_id  = "16-hex-chars"

          2. Enable generation (first run only):
             generate_zigbee_keys = true
      EOT
    }

    # Check 2: Protect existing resources from accidental changes
    precondition {
      condition     = !local.protected_fields_would_change || var.force_update_secrets
      error_message = local.protection_error_message
    }
  }
}

# ------------------------------------------------------------------------------
# Create ConfigMap (Non-Sensitive Protected Network Config)
# ------------------------------------------------------------------------------

resource "kubernetes_config_map" "zigbee_network" {
  depends_on = [
    terraform_data.zigbee_protection_check,
    kubernetes_namespace.domotic
  ]

  metadata {
    name      = "zigbee-network"
    namespace = var.kubernetes_namespace

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "zigbee2mqtt"
    }

    annotations = {
      "domotic.fiam.github.com/protected" = "true"
      "domotic.fiam.github.com/description" = "Protected Zigbee network configuration - changing breaks network"

      "domotic.fiam.github.com/created.at" = try(
        data.kubernetes_config_map.zigbee_network_existing[0].metadata[0].annotations["domotic.fiam.github.com/created.at"],
        timestamp()
      )

      "domotic.fiam.github.com/last.updated" = var.force_update_secrets ? timestamp() : try(
        data.kubernetes_config_map.zigbee_network_existing[0].metadata[0].annotations["domotic.fiam.github.com/last.updated"],
        ""
      )

      "domotic.fiam.github.com/update.reason" = var.force_update_secrets ? "force_update_secrets=true" : ""
    }
  }

  data = {
    # Non-sensitive but PROTECTED - changing breaks network communication
    pan_id  = tostring(var.zigbee_pan_id)
    channel = tostring(var.zigbee_channel)
  }
}

# ------------------------------------------------------------------------------
# Create Secret (Sensitive Protected Network Keys)
# ------------------------------------------------------------------------------

resource "kubernetes_secret" "zigbee_keys" {
  depends_on = [
    terraform_data.zigbee_protection_check,
    kubernetes_namespace.domotic
  ]

  metadata {
    name      = "zigbee-keys"
    namespace = var.kubernetes_namespace

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "zigbee2mqtt"
    }

    annotations = {
      "domotic.fiam.github.com/protected" = "true"
      "domotic.fiam.github.com/description" = "Protected Zigbee network keys - NEVER commit these"

      "domotic.fiam.github.com/created.at" = try(
        data.kubernetes_secret.zigbee_keys_existing[0].metadata[0].annotations["domotic.fiam.github.com/created.at"],
        timestamp()
      )

      "domotic.fiam.github.com/last.updated" = var.force_update_secrets ? timestamp() : try(
        data.kubernetes_secret.zigbee_keys_existing[0].metadata[0].annotations["domotic.fiam.github.com/last.updated"],
        ""
      )

      "domotic.fiam.github.com/update.reason" = var.force_update_secrets ? "force_update_secrets=true" : ""
    }
  }

  data = {
    # Sensitive AND protected - cryptographic keys
    network_key = local.desired_network_key
    ext_pan_id  = local.desired_ext_pan_id
  }

  type = "Opaque"
}
