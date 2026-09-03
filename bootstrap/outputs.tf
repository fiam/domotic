output "runtime" {
  description = "Sensitive values consumed by Domotic tasks; do not print this output."
  sensitive   = true
  value = {
    cloudflare_api_token  = var.cloudflare_api_token
    cloudflare_account_id = var.cloudflare_account_id
    endpoint              = local.r2_endpoint
    state = {
      bucket            = cloudflare_r2_bucket.state.name
      key               = "domotic.tfstate"
      access_key_id     = cloudflare_account_token.state.id
      secret_access_key = sha256(cloudflare_account_token.state.value)
    }
    backups = {
      bucket            = cloudflare_r2_bucket.backups.name
      access_key_id     = cloudflare_account_token.backups.id
      secret_access_key = sha256(cloudflare_account_token.backups.value)
    }
  }
}
