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

resource "kubernetes_secret" "homeassistant_onboarding" {
  # Only the presence of the sensitive object is declassified for resource
  # cardinality; none of its fields are exposed.
  count = (
    var.homeassistant_bootstrap_mode == "seed" &&
    nonsensitive(var.homeassistant_onboarding != null)
  ) ? 1 : 0

  depends_on = [kubernetes_namespace.domotic]

  metadata {
    name      = "homeassistant-onboarding"
    namespace = var.kubernetes_namespace

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "homeassistant-onboarding"
    }
  }

  data = {
    name     = try(var.homeassistant_onboarding.name, "")
    username = try(var.homeassistant_onboarding.username, "")
    password = try(var.homeassistant_onboarding.password, "")
    language = try(var.homeassistant_onboarding.language, "en")
  }

  type = "Opaque"
}
