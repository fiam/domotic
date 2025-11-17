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

output "generated_keys" {
  description = "Generated keys (if any). SAVE THESE IMMEDIATELY!"
  sensitive   = true
  value = var.generate_zigbee_keys ? {
    network_key = try(random_password.zigbee_network_key[0].result, "provided-by-user")
    ext_pan_id  = try(random_id.zigbee_ext_pan_id[0].hex, "provided-by-user")

    warning = "⚠️  SAVE THESE KEYS NOW! Add them to terraform.tfvars for future runs."
  } : null
}

output "zigbee_config" {
  description = "Complete Zigbee configuration (for verification)"
  sensitive   = true
  value = {
    # Sensitive (from Secret)
    network_key = kubernetes_secret.zigbee_keys.data["network_key"]
    ext_pan_id  = kubernetes_secret.zigbee_keys.data["ext_pan_id"]

    # Non-sensitive (from ConfigMap)
    pan_id  = tonumber(kubernetes_config_map.zigbee_network.data["pan_id"])
    channel = tonumber(kubernetes_config_map.zigbee_network.data["channel"])
  }
}

output "cloudflare_tunnel_hostname" {
  description = "External hostname for Home Assistant via Cloudflare Tunnel"
  value       = local.home_assistant_external_hostname
}

# ==============================================================================
# Helm Values Output (ready to use with helm install)
# ==============================================================================

output "helm_values_yaml" {
  description = "YAML values to use with: helm install domotic ./charts/domotic -f values.yaml"
  sensitive   = false
  value = yamlencode({
    # Zigbee2MQTT configuration
    zigbee2mqtt = {
      # Reference Terraform-created resources
      secretRef = {
        name = kubernetes_secret.zigbee_keys.metadata[0].name
      }
      configMapRef = {
        name = kubernetes_config_map.zigbee_network.metadata[0].name
      }
      config = {
        mqtt = {
          server = local.mqtt_server
          port   = 1883
        }
      }
    }

    # Home Assistant configuration
    homeassistant = {
      config = {
        external_url = "https://${local.home_assistant_external_hostname}"
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
  description = "Command to install the Helm chart"
  value       = <<-EOT
    # Save Helm values to file:
    terraform output -raw helm_values_yaml > helm-values.yaml

    # Install the chart:
    helm install ${var.helm_release_name} ./charts/domotic \
      --namespace ${var.kubernetes_namespace} \
      --create-namespace \
      -f helm-values.yaml \
      -f your-custom-values.yaml
  EOT
}
