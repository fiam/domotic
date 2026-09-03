resource "kubernetes_namespace" "domotic" {
  metadata {
    name = var.kubernetes_namespace

    labels = {
      "app.kubernetes.io/managed-by" = "opentofu"
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
      "app.kubernetes.io/managed-by" = "opentofu"
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

resource "random_password" "homeassistant_admin" {
  length  = 32
  special = false
}

resource "terraform_data" "homeassistant_credentials" {
  input = {
    username = coalesce(
      var.homeassistant_admin_username_override,
      var.homeassistant_owner.username
    )
    password = coalesce(
      var.homeassistant_admin_password_override,
      random_password.homeassistant_admin.result
    )
  }

  # Home Assistant owns password changes after onboarding. An explicit
  # credentials:update task replaces this resource when the operator needs to
  # record a changed or restored owner password.
  lifecycle {
    ignore_changes = [input]
  }
}

resource "kubernetes_secret" "homeassistant_onboarding" {
  count = var.homeassistant_bootstrap_mode == "seed" ? 1 : 0

  depends_on = [kubernetes_namespace.domotic]

  metadata {
    name      = "homeassistant-onboarding"
    namespace = var.kubernetes_namespace

    labels = {
      "app.kubernetes.io/managed-by" = "opentofu"
      "app.kubernetes.io/component"  = "homeassistant-onboarding"
    }
  }

  data = {
    name     = var.homeassistant_owner.name
    username = terraform_data.homeassistant_credentials.output.username
    password = terraform_data.homeassistant_credentials.output.password
    language = var.homeassistant_owner.language
  }

  type = "Opaque"
}
