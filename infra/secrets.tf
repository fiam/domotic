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

data "kubernetes_resources" "zigbee_keys_existing" {
  api_version    = "v1"
  kind           = "Secret"
  namespace      = var.kubernetes_namespace
  field_selector = "metadata.name=zigbee-keys"

  # A namespaced list request requires the namespace to exist on first apply.
  depends_on = [kubernetes_namespace.domotic]
}

data "kubernetes_resources" "zigbee_network_existing" {
  api_version    = "v1"
  kind           = "ConfigMap"
  namespace      = var.kubernetes_namespace
  field_selector = "metadata.name=zigbee-network"

  depends_on = [kubernetes_namespace.domotic]
}

# ------------------------------------------------------------------------------
# Protection Logic
# ------------------------------------------------------------------------------

locals {
  existing_secret_object    = try(data.kubernetes_resources.zigbee_keys_existing.objects[0], null)
  existing_configmap_object = try(data.kubernetes_resources.zigbee_network_existing.objects[0], null)

  # Check if resources exist
  secret_exists    = local.existing_secret_object != null
  configmap_exists = local.existing_configmap_object != null

  # Check if resources are marked as protected
  secret_protected = try(
    local.existing_secret_object.metadata.annotations["domotic.fiam.github.com/protected"],
    "false"
  ) == "true"

  configmap_protected = try(
    local.existing_configmap_object.metadata.annotations["domotic.fiam.github.com/protected"],
    "false"
  ) == "true"

  # The generic Kubernetes API returns Secret values as base64. Mark the decoded
  # values sensitive explicitly because the generic data source cannot infer it.
  existing_network_key = try(
    sensitive(base64decode(local.existing_secret_object.data["network_key"])),
    null
  )
  existing_ext_pan_id = try(
    sensitive(base64decode(local.existing_secret_object.data["ext_pan_id"])),
    null
  )

  # Get existing values from ConfigMap (non-sensitive)
  existing_pan_id = try(
    tonumber(local.existing_configmap_object.data["pan_id"]),
    null
  )
  existing_channel = try(
    tonumber(local.existing_configmap_object.data["channel"]),
    null
  )

  # Determine desired values
  desired_network_key = terraform_data.zigbee_identity.output.network_key
  desired_ext_pan_id  = terraform_data.zigbee_identity.output.ext_pan_id
  desired_pan_id      = var.zigbee_pan_id
  desired_channel     = var.zigbee_channel

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

  identity_metadata_matches_config = (
    (var.zigbee_expected_pan_id == null || var.zigbee_expected_pan_id == local.desired_pan_id) &&
    (var.zigbee_expected_channel == null || var.zigbee_expected_channel == local.desired_channel)
  )

  # The booleans are tainted by comparisons with sensitive values, but the
  # resulting message names changed fields only and never includes key data.
  protection_error_message = nonsensitive(<<-EOT
    ❌ PROTECTED ZIGBEE CONFIGURATION MODIFICATION BLOCKED!

    You're trying to change protected Zigbee network settings that will break your network!

    ${local.secret_fields_would_change ? "SECRET (sensitive keys):" : ""}
    ${local.network_key_would_change ? "  • network_key would change" : ""}
    ${local.ext_pan_id_would_change ? "  • ext_pan_id would change" : ""}

    ${local.configmap_fields_would_change ? "CONFIGMAP (network settings):" : ""}
    ${local.pan_id_would_change ? "  • pan_id: ${coalesce(local.existing_pan_id, 0)} → ${local.desired_pan_id}" : ""}
    ${local.channel_would_change ? "  • channel: ${coalesce(local.existing_channel, 0)} → ${local.desired_channel}" : ""}

    ⚠️  Changing these will break communication with ALL paired Zigbee devices!

    If you REALLY want to change these (requires re-pairing all devices):
      force_update_secrets = true

    Otherwise, preserve encrypted OpenTofu state and a current native backup.
    Import a replacement identity explicitly with:
      task zigbee:import SOURCE=/path/to/zigbee-keys.tfvars.json

    Inspect the non-secret radio settings with:
      kubectl -n ${var.kubernetes_namespace} get configmap zigbee-network -o yaml
  EOT
  )
}

# ------------------------------------------------------------------------------
# Key generation
# ------------------------------------------------------------------------------

resource "random_id" "zigbee_network_key_high" {
  byte_length = 8

  lifecycle {
    ignore_changes = all
  }
}

resource "random_id" "zigbee_network_key_low" {
  byte_length = 8

  lifecycle {
    ignore_changes = all
  }
}

resource "random_id" "zigbee_ext_pan_id" {
  byte_length = 8

  lifecycle {
    ignore_changes = all
  }
}

resource "terraform_data" "zigbee_identity" {
  input = {
    network_key = coalesce(
      var.zigbee_network_key,
      lower("${random_id.zigbee_network_key_high.hex}${random_id.zigbee_network_key_low.hex}")
    )
    ext_pan_id = coalesce(
      var.zigbee_ext_pan_id,
      random_id.zigbee_ext_pan_id.hex
    )
  }

  # Generated or imported keys are retained in encrypted state. To import a
  # different identity, the operator must explicitly replace this resource.
  lifecycle {
    ignore_changes = [input]

    precondition {
      condition = (
        local.identity_metadata_matches_config ||
        var.force_update_secrets
      )
      error_message = "The imported Zigbee identity does not match the configured PAN ID and channel."
    }
  }
}

# ------------------------------------------------------------------------------
# Protection Check
# ------------------------------------------------------------------------------

resource "terraform_data" "zigbee_protection_check" {
  lifecycle {
    # Check 1: A restored identity must be paired with its recorded radio
    # settings, even when the target cluster has no existing ConfigMap yet.
    precondition {
      condition = (
        local.identity_metadata_matches_config ||
        var.force_update_secrets
      )
      error_message = <<-EOT
        ❌ ZIGBEE IDENTITY DOES NOT MATCH THE CONFIGURED NETWORK!

        The imported key file records a different PAN ID or channel than
        terraform.tfvars. Restoring keys with the wrong radio settings can
        disconnect every paired device.

        Set zigbee_pan_id and zigbee_channel to the backed-up values. Only use
        force_update_secrets = true when intentionally creating a new network.
      EOT
    }

    # Check 2: Protect existing resources from accidental changes
    precondition {
      condition     = !local.protected_fields_would_change || var.force_update_secrets
      error_message = local.protection_error_message
    }
  }
}

moved {
  from = random_id.zigbee_ext_pan_id[0]
  to   = random_id.zigbee_ext_pan_id
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
      "app.kubernetes.io/managed-by" = "opentofu"
      "app.kubernetes.io/component"  = "zigbee2mqtt"
    }

    annotations = {
      "domotic.fiam.github.com/protected"   = "true"
      "domotic.fiam.github.com/description" = "Protected Zigbee network configuration - changing breaks network"

      "domotic.fiam.github.com/created.at" = try(
        local.existing_configmap_object.metadata.annotations["domotic.fiam.github.com/created.at"],
        timestamp()
      )

      "domotic.fiam.github.com/last.updated" = var.force_update_secrets ? timestamp() : try(
        local.existing_configmap_object.metadata.annotations["domotic.fiam.github.com/last.updated"],
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
      "app.kubernetes.io/managed-by" = "opentofu"
      "app.kubernetes.io/component"  = "zigbee2mqtt"
    }

    annotations = {
      "domotic.fiam.github.com/protected"   = "true"
      "domotic.fiam.github.com/description" = "Protected Zigbee network keys - NEVER commit these"

      "domotic.fiam.github.com/created.at" = try(
        local.existing_secret_object.metadata.annotations["domotic.fiam.github.com/created.at"],
        timestamp()
      )

      "domotic.fiam.github.com/last.updated" = var.force_update_secrets ? timestamp() : try(
        local.existing_secret_object.metadata.annotations["domotic.fiam.github.com/last.updated"],
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
