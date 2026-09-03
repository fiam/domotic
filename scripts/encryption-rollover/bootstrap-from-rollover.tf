variable "state_passphrase" {
  type      = string
  sensitive = true
}

variable "previous_state_passphrase" {
  type      = string
  sensitive = true
}

terraform {
  backend "local" {}

  encryption {
    key_provider "pbkdf2" "current" {
      passphrase               = var.state_passphrase
      encrypted_metadata_alias = "domotic-bootstrap"
    }

    key_provider "pbkdf2" "previous" {
      passphrase               = var.previous_state_passphrase
      encrypted_metadata_alias = "domotic-bootstrap-rollover"
    }

    method "aes_gcm" "current" {
      keys = key_provider.pbkdf2.current
    }

    method "aes_gcm" "previous" {
      keys = key_provider.pbkdf2.previous
    }

    state {
      method   = method.aes_gcm.current
      enforced = true
      fallback {
        method = method.aes_gcm.previous
      }
    }

    plan {
      method   = method.aes_gcm.current
      enforced = true
      fallback {
        method = method.aes_gcm.previous
      }
    }
  }
}
