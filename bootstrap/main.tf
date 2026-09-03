provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

locals {
  state_bucket_name  = "${var.r2_bucket_prefix}-state"
  backup_bucket_name = "${var.r2_bucket_prefix}-backups"
  r2_endpoint = (
    var.r2_jurisdiction == "default" ?
    "https://${var.cloudflare_account_id}.r2.cloudflarestorage.com" :
    "https://${var.cloudflare_account_id}.${var.r2_jurisdiction}.r2.cloudflarestorage.com"
  )
}

data "cloudflare_account_api_token_permission_groups" "available" {
  account_id = var.cloudflare_account_id
}

locals {
  r2_bucket_item_write_permission_id = one([
    for permission in data.cloudflare_account_api_token_permission_groups.available.permission_groups :
    permission.id
    if permission.name == "Workers R2 Storage Bucket Item Write"
  ])
}

resource "cloudflare_r2_bucket" "state" {
  account_id   = var.cloudflare_account_id
  name         = local.state_bucket_name
  location     = var.r2_location
  jurisdiction = var.r2_jurisdiction

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_r2_bucket" "backups" {
  account_id   = var.cloudflare_account_id
  name         = local.backup_bucket_name
  location     = var.r2_location
  jurisdiction = var.r2_jurisdiction

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_account_token" "state" {
  account_id = var.cloudflare_account_id
  name       = "domotic-${var.r2_bucket_prefix}-state"

  policies = [{
    effect = "allow"
    permission_groups = [{
      id = local.r2_bucket_item_write_permission_id
    }]
    resources = jsonencode({
      "com.cloudflare.edge.r2.bucket.${var.cloudflare_account_id}_${var.r2_jurisdiction}_${cloudflare_r2_bucket.state.name}" = "*"
    })
  }]
}

resource "cloudflare_account_token" "backups" {
  account_id = var.cloudflare_account_id
  name       = "domotic-${var.r2_bucket_prefix}-backups"

  policies = [{
    effect = "allow"
    permission_groups = [{
      id = local.r2_bucket_item_write_permission_id
    }]
    resources = jsonencode({
      "com.cloudflare.edge.r2.bucket.${var.cloudflare_account_id}_${var.r2_jurisdiction}_${cloudflare_r2_bucket.backups.name}" = "*"
    })
  }]
}
