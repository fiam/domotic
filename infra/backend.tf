terraform {
  backend "s3" {}

  # Persisted metadata identity: retain this alias to decrypt pre-rename state.
  encryption {
    key_provider "pbkdf2" "main" {
      passphrase               = var.state_passphrase
      encrypted_metadata_alias = "domotic-main"
    }

    method "aes_gcm" "main" {
      keys = key_provider.pbkdf2.main
    }

    state {
      method   = method.aes_gcm.main
      enforced = true
    }

    plan {
      method   = method.aes_gcm.main
      enforced = true
    }
  }
}
