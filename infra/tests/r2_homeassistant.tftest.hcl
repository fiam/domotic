mock_provider "cloudflare" {
  mock_data "cloudflare_zone" {
    defaults = {
      zone_id = "00000000000000000000000000000000"
    }
  }

  mock_data "cloudflare_zero_trust_tunnel_cloudflared_token" {
    defaults = {
      token = "mock-tunnel-token"
    }
  }
}

mock_provider "kubernetes" {
  mock_data "kubernetes_resources" {
    defaults = {
      objects = []
    }
  }
}

mock_provider "random" {
  mock_resource "random_password" {
    defaults = {
      result = "0123456789ABCDEF0123456789ABCDEF"
    }
  }

  mock_resource "random_id" {
    defaults = {
      hex = "0123456789abcdef"
    }
  }
}

run "r2_credentials_are_derived_for_homeassistant" {
  # A plan is sufficient because every asserted value is known before apply.
  # It also avoids OpenTofu trying to tear down the deliberately protected
  # mock R2 bucket after the test.
  command = plan

  variables {
    cloudflare_account_id                   = "00000000000000000000000000000000"
    cloudflare_domain                       = "example.com"
    kubernetes_namespace                    = "domotic-test"
    r2_backup_bucket_name                   = "domotic-test-backups"
    homeassistant_backup_encryption_enabled = true
    r2_backup_credentials = {
      access_key_id     = "backup-id"
      secret_access_key = "backup-secret"
    }
  }

  assert {
    condition = (
      nonsensitive(kubernetes_secret.homeassistant_r2_credentials[0].data["access_key_id"]) ==
      "backup-id"
    )
    error_message = "Home Assistant must receive the bucket-scoped R2 access key."
  }

  assert {
    condition = (
      nonsensitive(kubernetes_secret.homeassistant_r2_credentials[0].data["secret_access_key"]) ==
      "backup-secret"
    )
    error_message = "Home Assistant must receive the bucket-scoped R2 secret."
  }

  assert {
    condition     = strcontains(output.helm_values_yaml, "homeassistant-r2-credentials")
    error_message = "Generated Helm values must reference OpenTofu's R2 credentials Secret."
  }

  assert {
    condition = (
      yamldecode(output.helm_values_yaml).homeassistant.r2Backup.automatic.enabled &&
      yamldecode(output.helm_values_yaml).homeassistant.r2Backup.automatic.agentName ==
      "domotic-test-backups" &&
      yamldecode(output.helm_values_yaml).homeassistant.r2Backup.automatic.retentionCopies == 7 &&
      yamldecode(output.helm_values_yaml).homeassistant.r2Backup.automatic.existingSecret.name ==
      "homeassistant-backup-encryption"
    )
    error_message = "Seed mode must enable encrypted daily R2 backups when a password is configured."
  }

  assert {
    condition = (
      nonsensitive(kubernetes_secret.homeassistant_backup_encryption[0].data["password"]) ==
      "0123456789ABCDEF0123456789ABCDEF"
    )
    error_message = "OpenTofu must generate and store the native backup password."
  }
}

run "r2_backups_are_unencrypted_without_a_password" {
  command = plan

  variables {
    cloudflare_account_id = "00000000000000000000000000000000"
    cloudflare_domain     = "example.com"
    kubernetes_namespace  = "domotic-test"
    r2_backup_bucket_name = "domotic-test-backups"
    r2_backup_credentials = {
      access_key_id     = "backup-id"
      secret_access_key = "backup-secret"
    }
  }

  assert {
    condition     = length(kubernetes_secret.homeassistant_backup_encryption) == 0
    error_message = "OpenTofu must not create a backup password Secret when no password is configured."
  }

  assert {
    condition = (
      yamldecode(output.helm_values_yaml).homeassistant.r2Backup.automatic.enabled &&
      yamldecode(output.helm_values_yaml).homeassistant.r2Backup.automatic.existingSecret.name == ""
    )
    error_message = "Automatic R2 backups must remain enabled without an encryption Secret."
  }
}
