cloudflare_domain = "example.com"

cloudflare_homeassistant_subdomain = "homeassistant"
cloudflare_tunnel_name              = "domotic-tunnel"

local_http_hostnames = {
  homeassistant = "homeassistant.local"
  zigbee2mqtt   = "zigbee2mqtt.local"
}

homeassistant_bootstrap_mode = "seed"

# The initial password is generated and retained in encrypted OpenTofu state.
# The username defaults to admin; the profile fields are not secret.
# homeassistant_owner = {
#   name     = "Home Administrator"
#   username = "admin"
#   language = "en"
# }

# Native backups are unencrypted by default. When enabled, OpenTofu generates
# the backup password and retains it in encrypted state.
# homeassistant_backup_encryption_enabled = true

# homeassistant_r2_backup_prefix = "home-assistant"

kubernetes_namespace = "domotic"
helm_release_name     = "domotic"

zigbee_pan_id         = 6754
zigbee_channel        = 15

# Optional public, immutable custom integration archive.
# homeassistant_remote_custom_components = [{
#   name         = "example_integration"
#   url          = "https://github.com/example/integration/archive/0123456789abcdef.tar.gz"
#   sha256       = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
#   archive_path = "integration-0123456789abcdef/custom_components/example_integration"
# }]
