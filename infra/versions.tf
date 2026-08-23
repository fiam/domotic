terraform {
  required_version = ">= 1.7.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }

    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.23"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}
