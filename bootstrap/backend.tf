variable "state_passphrase" {
  description = "Passphrase used by OpenTofu to encrypt bootstrap state and plan files."
  type        = string
  sensitive   = true
}

terraform {
  backend "local" {}

  encryption {
    key_provider "pbkdf2" "bootstrap" {
      passphrase               = var.state_passphrase
      encrypted_metadata_alias = "domotic-bootstrap"
    }

    method "aes_gcm" "bootstrap" {
      keys = key_provider.pbkdf2.bootstrap
    }

    state {
      method   = method.aes_gcm.bootstrap
      enforced = true
    }

    plan {
      method   = method.aes_gcm.bootstrap
      enforced = true
    }
  }
}
