# Credentials do not belong in this file. The SOPS deployment wrapper injects
# TF_VAR_cloudflare_api_token and TF_VAR_homeassistant_onboarding only while a
# Terraform command is running.

cloudflare_account_id = "replace-with-account-id"
cloudflare_domain     = "example.com"

cloudflare_homeassistant_subdomain = "homeassistant"
cloudflare_tunnel_name              = "domotic-tunnel"

local_http_hostnames = {
  homeassistant = "homeassistant.local"
  zigbee2mqtt   = "zigbee2mqtt.local"
}

homeassistant_bootstrap_mode = "seed"

# Required only when the shared account token also provisions R2. This is the
# token identifier, not the secret token value.
# cloudflare_api_token_id        = "0123456789abcdef0123456789abcdef"
# r2_backup_bucket_name          = "replace-with-unique-bucket-name"
# r2_backup_location             = "weur"
# homeassistant_r2_backup_prefix = "home-assistant"

kubernetes_namespace = "domotic"
helm_release_name     = "domotic"

generate_zigbee_keys = true
zigbee_pan_id         = 6754
zigbee_channel        = 15

# Optional public, immutable custom integration archive.
# homeassistant_remote_custom_components = [{
#   name         = "example_integration"
#   url          = "https://github.com/example/integration/archive/0123456789abcdef.tar.gz"
#   sha256       = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
#   archive_path = "integration-0123456789abcdef/custom_components/example_integration"
# }]
