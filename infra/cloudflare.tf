locals {
  home_assistant_external_hostname = "${var.cloudflare_homeassistant_subdomain}.${var.cloudflare_domain}"
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "_" {
  account_id = var.cloudflare_account_id
  name       = var.cloudflare_tunnel_name
  config_src = "cloudflare"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "_" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared._.id
  config = {
    ingress = [{
      hostname = local.home_assistant_external_hostname
      service  = "http://${local.helm_release_name}-homeassistant.default.svc.cluster.local"
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

