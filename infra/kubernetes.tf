resource "kubernetes_secret" "cloudflared_tunnel_token_secret" {
  metadata {
    name = "cloudflared"
  }
  data = {
    tunnel_token = data.cloudflare_zero_trust_tunnel_cloudflared_token._.token
  }
}
