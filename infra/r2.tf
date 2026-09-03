check "r2_backup_credentials" {
  assert {
    condition = (
      (var.r2_backup_bucket_name == null) ==
      (nonsensitive(var.r2_backup_credentials == null))
    )
    error_message = "R2 backup bucket and bucket-scoped credentials must be configured together."
  }
}

locals {
  homeassistant_automatic_backups_enabled = (
    var.r2_backup_bucket_name != null &&
    var.homeassistant_bootstrap_mode == "seed" &&
    var.homeassistant_automatic_backups.enabled
  )
}

resource "kubernetes_secret" "homeassistant_r2_credentials" {
  count = var.r2_backup_bucket_name == null ? 0 : 1

  depends_on = [kubernetes_namespace.domotic]

  metadata {
    name      = "homeassistant-r2-credentials"
    namespace = var.kubernetes_namespace

    labels = {
      "app.kubernetes.io/managed-by" = "opentofu"
      "app.kubernetes.io/component"  = "homeassistant-backup"
    }
  }

  data = {
    access_key_id     = try(var.r2_backup_credentials.access_key_id, "")
    secret_access_key = try(var.r2_backup_credentials.secret_access_key, "")
  }

  type = "Opaque"
}

resource "random_password" "homeassistant_backup" {
  count = var.homeassistant_backup_encryption_enabled ? 1 : 0

  length  = 32
  special = false
}

resource "kubernetes_secret" "homeassistant_backup_encryption" {
  count = (
    local.homeassistant_automatic_backups_enabled &&
    var.homeassistant_backup_encryption_enabled
  ) ? 1 : 0

  depends_on = [kubernetes_namespace.domotic]

  metadata {
    name      = "homeassistant-backup-encryption"
    namespace = var.kubernetes_namespace

    labels = {
      "app.kubernetes.io/managed-by" = "opentofu"
      "app.kubernetes.io/component"  = "homeassistant-backup"
    }

    annotations = {
      "domotic.fiam.github.com/description" = "Home Assistant native backup recovery password"
    }
  }

  data = {
    password = random_password.homeassistant_backup[0].result
  }

  type = "Opaque"
}
