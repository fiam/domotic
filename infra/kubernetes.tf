resource "kubernetes_namespace" "domotic" {
  metadata {
    name = var.kubernetes_namespace

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "name"                         = var.kubernetes_namespace
    }
  }
}

resource "kubernetes_secret" "cloudflared_tunnel_token_secret" {
  depends_on = [kubernetes_namespace.domotic]
  metadata {
    name      = "cloudflared-tunnel-token"
    namespace = var.kubernetes_namespace

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "cloudflared"
    }

    annotations = {
      "domotic.fiam.github.com/component" = "cloudflared-tunnel"
    }
  }

  data = {
    token = data.cloudflare_zero_trust_tunnel_cloudflared_token._.token
  }

  type = "Opaque"
}
