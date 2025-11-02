resource "cloudflare_zero_trust_tunnel_cloudflared" "_" {
    account_id   = var.cloudflare_account_id
    name         = var.cloudflare_tunnel_name
    config_src   = "cloudflare"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "_" {
  account_id   = var.cloudflare_account_id
  tunnel_id   = cloudflare_zero_trust_tunnel_cloudflared._.id
  config = {
    ingress = [{
      hostname = "ha.example.com"
      service = "https://localhost:8001"
    },
    {
      hostname = "ha2.example.com"
      service = "https://localhost:8002"
    },
    {
        service  = "http_status:404"
    }]
  }
} 

data "cloudflare_zero_trust_tunnel_cloudflared_token" "_" {
  account_id   = var.cloudflare_account_id
  tunnel_id   = cloudflare_zero_trust_tunnel_cloudflared._.id
}

