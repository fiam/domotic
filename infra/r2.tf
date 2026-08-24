resource "cloudflare_r2_bucket" "backups" {
  count = var.r2_backup_bucket_name == null ? 0 : 1

  account_id    = var.cloudflare_account_id
  name          = var.r2_backup_bucket_name
  location      = var.r2_backup_location
  storage_class = "Standard"

  # Backups must survive an accidental infrastructure teardown. To remove this
  # bucket intentionally, first preserve its objects and remove this guard.
  lifecycle {
    prevent_destroy = true
  }
}

check "r2_account_token_id" {
  assert {
    condition     = var.r2_backup_bucket_name == null || var.cloudflare_api_token_id != null
    error_message = "cloudflare_api_token_id is required when r2_backup_bucket_name is set. Obtain it from the account token verification endpoint."
  }
}

resource "random_password" "homeassistant_backup" {
  count = (
    var.r2_backup_bucket_name != null &&
    var.homeassistant_backup_password == null
  ) ? 1 : 0

  length  = 32
  special = false

  lifecycle {
    ignore_changes = all
  }
}

locals {
  effective_homeassistant_backup_password = (
    var.homeassistant_backup_password != null ?
    var.homeassistant_backup_password :
    try(random_password.homeassistant_backup[0].result, "")
  )

  homeassistant_automatic_backups_enabled = (
    var.r2_backup_bucket_name != null &&
    var.homeassistant_bootstrap_mode == "seed" &&
    nonsensitive(var.homeassistant_onboarding != null) &&
    var.homeassistant_automatic_backups.enabled
  )
}

# R2 accepts the account API token ID as its S3 access key and the SHA-256 hash
# of the token value as its S3 secret. Only these derived credentials enter the
# cluster; the raw Cloudflare bearer token remains on the Terraform workstation.
resource "kubernetes_secret" "homeassistant_r2_credentials" {
  count = var.r2_backup_bucket_name == null ? 0 : 1

  depends_on = [
    cloudflare_r2_bucket.backups,
    kubernetes_namespace.domotic,
  ]

  metadata {
    name      = "homeassistant-r2-credentials"
    namespace = var.kubernetes_namespace

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "homeassistant-backup"
    }
  }

  data = {
    access_key_id     = coalesce(var.cloudflare_api_token_id, "")
    secret_access_key = sha256(var.cloudflare_api_token)
  }

  type = "Opaque"
}

resource "kubernetes_secret" "homeassistant_backup_encryption" {
  count = var.r2_backup_bucket_name == null ? 0 : 1

  depends_on = [kubernetes_namespace.domotic]

  metadata {
    name      = "homeassistant-backup-encryption"
    namespace = var.kubernetes_namespace

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "homeassistant-backup"
    }

    annotations = {
      "domotic.fiam.github.com/description" = "Home Assistant native backup recovery password"
    }
  }

  data = {
    password = local.effective_homeassistant_backup_password
  }

  type = "Opaque"
}
