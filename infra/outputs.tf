# ==============================================================================
# Outputs for Helm Chart Configuration
# ==============================================================================

output "zigbee_secret_status" {
  description = "Status of the Zigbee keys secret (sensitive)"
  value = {
    name         = kubernetes_secret.zigbee_keys.metadata[0].name
    namespace    = kubernetes_secret.zigbee_keys.metadata[0].namespace
    protected    = kubernetes_secret.zigbee_keys.metadata[0].annotations["domotic.fiam.github.com/protected"]
    created_at   = kubernetes_secret.zigbee_keys.metadata[0].annotations["domotic.fiam.github.com/created.at"]
    last_updated = kubernetes_secret.zigbee_keys.metadata[0].annotations["domotic.fiam.github.com/last.updated"]
  }
}

output "zigbee_configmap_status" {
  description = "Status of the Zigbee network ConfigMap (non-sensitive)"
  value = {
    name         = kubernetes_config_map.zigbee_network.metadata[0].name
    namespace    = kubernetes_config_map.zigbee_network.metadata[0].namespace
    protected    = kubernetes_config_map.zigbee_network.metadata[0].annotations["domotic.fiam.github.com/protected"]
    created_at   = kubernetes_config_map.zigbee_network.metadata[0].annotations["domotic.fiam.github.com/created.at"]
    last_updated = kubernetes_config_map.zigbee_network.metadata[0].annotations["domotic.fiam.github.com/last.updated"]
  }
}

output "cloudflare_tunnel_hostname" {
  description = "External hostname for Home Assistant via Cloudflare Tunnel"
  value       = local.home_assistant_external_hostname
}

output "kubernetes_namespace" {
  description = "Namespace containing the Domotic application resources"
  value       = var.kubernetes_namespace
}

output "local_http_hostnames" {
  description = "Hostnames assigned to the local Home Assistant and Zigbee2MQTT HTTPRoutes"
  value       = var.local_http_hostnames
}

output "local_http_urls" {
  description = "Client-facing local URLs configured in Home Assistant and Zigbee2MQTT"
  value       = local.effective_local_http_urls
}

output "r2_backup_bucket_name" {
  description = "Name of the private R2 backup bucket, or an empty string when backups are disabled"
  value       = var.r2_backup_bucket_name == null ? "" : var.r2_backup_bucket_name
}

output "r2_backup_endpoint" {
  description = "S3-compatible endpoint for the Cloudflare account"
  value       = var.r2_backup_bucket_name == null ? "" : local.effective_r2_endpoint
}

# ==============================================================================
# Helm Values Output (ready to use with helm install)
# ==============================================================================

output "helm_values_yaml" {
  description = "Generated values consumed by the Helm deployment task"
  sensitive   = false
  value = yamlencode({
    # Zigbee2MQTT configuration
    zigbee2mqtt = {
      # Reference OpenTofu-created resources
      secretRef = {
        name = kubernetes_secret.zigbee_keys.metadata[0].name
      }
      configMapRef = {
        name = kubernetes_config_map.zigbee_network.metadata[0].name
      }
      config = {
        frontend = {
          url = local.effective_local_http_urls.zigbee2mqtt
        }
        mqtt = {
          server = local.mqtt_server
          port   = 1883
        }
      }
      httpRoute = {
        hostnames = [var.local_http_hostnames.zigbee2mqtt]
      }
    }

    # Home Assistant configuration
    homeassistant = {
      configSeed = {
        mode = var.homeassistant_bootstrap_mode
      }
      onboarding = {
        enabled = var.homeassistant_bootstrap_mode == "seed"
        existingSecret = {
          name        = try(kubernetes_secret.homeassistant_onboarding[0].metadata[0].name, "")
          nameKey     = "name"
          usernameKey = "username"
          passwordKey = "password"
          languageKey = "language"
        }
      }
      config = {
        external_url = "https://${local.home_assistant_external_hostname}"
        internal_url = local.effective_local_http_urls.homeassistant
        mqtt = {
          server = local.mqtt_server
          port   = 1883
        }
      }
      customComponents = {
        remote = [
          for component in var.homeassistant_remote_custom_components : {
            name        = component.name
            url         = component.url
            sha256      = lower(component.sha256)
            archivePath = component.archive_path
          }
        ]
      }
      httpRoute = {
        hostnames = [var.local_http_hostnames.homeassistant]
      }
      r2Backup = {
        enabled     = var.r2_backup_bucket_name != null && var.homeassistant_bootstrap_mode == "seed"
        bucket      = var.r2_backup_bucket_name == null ? "" : var.r2_backup_bucket_name
        endpointUrl = var.r2_backup_bucket_name == null ? "" : local.effective_r2_endpoint
        prefix      = trim(var.homeassistant_r2_backup_prefix, "/")
        existingSecret = {
          name               = try(kubernetes_secret.homeassistant_r2_credentials[0].metadata[0].name, "")
          accessKeyIdKey     = "access_key_id"
          secretAccessKeyKey = "secret_access_key"
        }
        automatic = {
          enabled         = local.homeassistant_automatic_backups_enabled
          agentName       = var.r2_backup_bucket_name == null ? "" : var.r2_backup_bucket_name
          retentionCopies = var.homeassistant_automatic_backups.retention_copies
          time            = var.homeassistant_automatic_backups.time
          existingSecret = {
            name        = try(kubernetes_secret.homeassistant_backup_encryption[0].metadata[0].name, "")
            passwordKey = "password"
          }
        }
      }
      zigbee2mqttBackup = {
        enabled = true
        mqtt = {
          server = local.mqtt_server
          port   = 1883
        }
      }
    }

    # Cloudflared configuration
    cloudflared = {
      tunnelTokenSecret = {
        name = kubernetes_secret.cloudflared_tunnel_token_secret.metadata[0].name
        key  = "token"
      }
    }
  })
}

output "helm_install_command" {
  description = "Task commands to generate values and deploy the Helm chart"
  value       = <<-EOT
    # From the repository root, refresh the generated values:
    task infra:helm-values

    # Install or upgrade the chart using root values.yaml:
    task helm:deploy \
      RELEASE_NAME=${var.helm_release_name} \
      NAMESPACE=${var.kubernetes_namespace}
  EOT
}

output "homeassistant_credentials" {
  description = "Home Assistant owner credential retained in encrypted state."
  value       = terraform_data.homeassistant_credentials.output
  sensitive   = true
}

output "homeassistant_backup_password" {
  description = "Generated native backup password, or null when encryption is disabled."
  value       = try(random_password.homeassistant_backup[0].result, null)
  sensitive   = true
}
