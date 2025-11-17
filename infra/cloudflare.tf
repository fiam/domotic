locals {
  home_assistant_external_hostname = "${var.cloudflare_homeassistant_subdomain}.${var.cloudflare_domain}"
  mqtt_server                      = "${var.helm_release_name}-mosquitto.${var.kubernetes_namespace}.svc.cluster.local"
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "_" {
  account_id = var.cloudflare_account_id
  name       = var.cloudflare_tunnel_name
  config_src = "cloudflare"
}

# Note: This resource cannot be destroyed from Terraform once created.
# If you need to delete it, you must do so manually via the Cloudflare API/dashboard.
# This is a known limitation of the Cloudflare provider.
# The warning during plan/apply is informational and cannot be suppressed.
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "_" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared._.id
  config = {
    ingress = [{
      hostname = local.home_assistant_external_hostname
      service  = "http://${var.helm_release_name}-homeassistant.${var.kubernetes_namespace}.svc.cluster.local:8123"
      },
      {
        service = "http_status:404"
    }]
  }
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "_" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared._.id
}

data "cloudflare_zone" "_" {
  filter = {
    account = {
      id = var.cloudflare_account_id
    }
    name  = var.cloudflare_domain
    match = "all"
  }
}

resource "cloudflare_dns_record" "_" {
  zone_id = data.cloudflare_zone._.zone_id
  name    = var.cloudflare_homeassistant_subdomain
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared._.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}

