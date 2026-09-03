terraform {
  backend "s3" {}

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
