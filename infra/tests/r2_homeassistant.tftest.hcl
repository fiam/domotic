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
      hex = "0123456789ABCDEF"
    }
  }
}

run "r2_credentials_are_derived_for_homeassistant" {
  # A plan is sufficient because every asserted value is known before apply.
  # It also avoids Terraform trying to tear down the deliberately protected
  # mock R2 bucket after the test.
  command = plan

  variables {
    cloudflare_api_token          = "mock-account-api-token"
    cloudflare_api_token_id       = "0123456789abcdef0123456789abcdef"
    cloudflare_account_id         = "00000000000000000000000000000000"
    cloudflare_domain             = "example.com"
    kubernetes_namespace          = "domotic-test"
    generate_zigbee_keys          = true
    r2_backup_bucket_name         = "domotic-test-backups"
    r2_backup_location            = "weur"
    homeassistant_backup_password = "test-native-backup-password"
    homeassistant_onboarding = {
      name     = "Home Administrator"
      username = "admin"
      password = "a-long-test-password"
      language = "en"
    }
  }

  assert {
    condition = (
      nonsensitive(kubernetes_secret.homeassistant_r2_credentials[0].data["access_key_id"]) ==
      "0123456789abcdef0123456789abcdef"
    )
    error_message = "The R2 access key must be the account API token ID."
  }

  assert {
    condition = (
      nonsensitive(kubernetes_secret.homeassistant_r2_credentials[0].data["secret_access_key"]) ==
      sha256("mock-account-api-token")
    )
    error_message = "The R2 secret access key must be the SHA-256 hash of the account API token."
  }

  assert {
    condition     = strcontains(output.helm_values_yaml, "homeassistant-r2-credentials")
    error_message = "Generated Helm values must reference Terraform's R2 credentials Secret."
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
      "test-native-backup-password"
    )
    error_message = "Terraform must store the configured native backup password."
  }
}

run "r2_backups_are_unencrypted_without_a_password" {
  command = plan

  variables {
    cloudflare_api_token    = "mock-account-api-token"
    cloudflare_api_token_id = "0123456789abcdef0123456789abcdef"
    cloudflare_account_id   = "00000000000000000000000000000000"
    cloudflare_domain       = "example.com"
    kubernetes_namespace    = "domotic-test"
    generate_zigbee_keys    = true
    r2_backup_bucket_name   = "domotic-test-backups"
    r2_backup_location      = "weur"
    homeassistant_onboarding = {
      name     = "Home Administrator"
      username = "admin"
      password = "a-long-test-password"
      language = "en"
    }
  }

  assert {
    condition     = length(kubernetes_secret.homeassistant_backup_encryption) == 0
    error_message = "Terraform must not create a backup password Secret when no password is configured."
  }

  assert {
    condition = (
      yamldecode(output.helm_values_yaml).homeassistant.r2Backup.automatic.enabled &&
      yamldecode(output.helm_values_yaml).homeassistant.r2Backup.automatic.existingSecret.name == ""
    )
    error_message = "Automatic R2 backups must remain enabled without an encryption Secret."
  }
}
