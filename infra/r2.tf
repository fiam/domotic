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
