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
  # A list query represents an absent object as an empty collection. This is
  # the first-run behavior that the singular data sources could not handle.
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

run "empty_namespace_first_apply" {
  command = apply

  variables {
    cloudflare_api_token  = "mock-api-token"
    cloudflare_account_id = "00000000000000000000000000000000"
    cloudflare_domain     = "example.com"
    kubernetes_namespace  = "domotic-test"
    generate_zigbee_keys  = true
    homeassistant_onboarding = {
      password = "a-long-test-password"
    }
    local_http_urls = {
      homeassistant = "http://homeassistant.local:8080"
      zigbee2mqtt   = "http://zigbee2mqtt.local:8080"
    }
  }

  assert {
    condition     = local.secret_exists == false
    error_message = "An absent zigbee-keys Secret must be treated as a clean first run."
  }

  assert {
    condition     = local.configmap_exists == false
    error_message = "An absent zigbee-network ConfigMap must be treated as a clean first run."
  }

  assert {
    condition = can(regex(
      "^[0-9A-F]{32}$",
      nonsensitive(kubernetes_secret.zigbee_keys.data["network_key"])
    ))
    error_message = "The first apply must create a 32-character Zigbee network key."
  }

  assert {
    condition = (
      yamldecode(output.helm_values_yaml).homeassistant.config.internal_url ==
      "http://homeassistant.local:8080"
    )
    error_message = "Home Assistant must receive the configured client-facing local URL."
  }

  assert {
    condition = (
      nonsensitive(kubernetes_secret.homeassistant_onboarding[0].data["username"]) ==
      "admin"
    )
    error_message = "Seed mode must default the Home Assistant username to admin."
  }

  assert {
    condition = (
      yamldecode(output.helm_values_yaml).zigbee2mqtt.config.frontend.url ==
      "http://zigbee2mqtt.local:8080"
    )
    error_message = "Zigbee2MQTT must receive its local URL through frontend.url."
  }
}

run "seed_requires_an_admin_password" {
  command = plan

  variables {
    cloudflare_api_token  = "mock-api-token"
    cloudflare_account_id = "00000000000000000000000000000000"
    cloudflare_domain     = "example.com"
    kubernetes_namespace  = "domotic-test"
    generate_zigbee_keys  = true
  }

  expect_failures = [
    terraform_data.homeassistant_seed_check,
  ]
}

run "restored_identity_must_match_radio_settings" {
  command = plan

  variables {
    cloudflare_api_token    = "mock-api-token"
    cloudflare_account_id   = "00000000000000000000000000000000"
    cloudflare_domain       = "example.com"
    kubernetes_namespace    = "domotic-test"
    generate_zigbee_keys    = false
    zigbee_network_key      = "0123456789ABCDEF0123456789ABCDEF"
    zigbee_ext_pan_id       = "0123456789ABCDEF"
    zigbee_pan_id           = 6754
    zigbee_channel          = 15
    zigbee_expected_pan_id  = 6754
    zigbee_expected_channel = 20
    homeassistant_onboarding = {
      password = "a-long-test-password"
    }
  }

  expect_failures = [
    terraform_data.zigbee_protection_check,
  ]
}

run "homeassistant_owner_seed_uses_a_secret" {
  command = plan

  variables {
    cloudflare_api_token  = "mock-api-token"
    cloudflare_account_id = "00000000000000000000000000000000"
    cloudflare_domain     = "example.com"
    kubernetes_namespace  = "domotic-test"
    generate_zigbee_keys  = true
    homeassistant_onboarding = {
      name     = "Home Administrator"
      password = "a-long-test-password"
      language = "en"
    }
  }

  assert {
    condition = (
      yamldecode(output.helm_values_yaml).homeassistant.onboarding.enabled &&
      yamldecode(output.helm_values_yaml).homeassistant.onboarding.existingSecret.name ==
      "homeassistant-onboarding" &&
      nonsensitive(kubernetes_secret.homeassistant_onboarding[0].data["username"]) ==
      "admin"
    )
    error_message = "Seed mode must enable the onboarding Secret and default its username to admin."
  }
}

run "native_restore_disables_owner_seed" {
  command = plan

  variables {
    cloudflare_api_token         = "mock-api-token"
    cloudflare_account_id        = "00000000000000000000000000000000"
    cloudflare_domain            = "example.com"
    kubernetes_namespace         = "domotic-test"
    generate_zigbee_keys         = true
    homeassistant_bootstrap_mode = "restore"
    cloudflare_api_token_id      = "00000000000000000000000000000000"
    r2_backup_bucket_name        = "domotic-test-backups"
    homeassistant_onboarding = {
      name     = "Home Administrator"
      username = "admin"
      password = "a-long-test-password"
      language = "en"
    }
  }

  assert {
    condition = (
      !yamldecode(output.helm_values_yaml).homeassistant.onboarding.enabled &&
      yamldecode(output.helm_values_yaml).homeassistant.onboarding.existingSecret.name == "" &&
      yamldecode(output.helm_values_yaml).homeassistant.configSeed.mode == "restore" &&
      !yamldecode(output.helm_values_yaml).homeassistant.r2Backup.enabled &&
      !yamldecode(output.helm_values_yaml).homeassistant.r2Backup.automatic.enabled
    )
    error_message = "Restore mode must disable Home Assistant owner, integration, and storage seeding."
  }
}

run "remote_custom_components_reach_helm_values" {
  command = plan

  variables {
    cloudflare_api_token  = "mock-api-token"
    cloudflare_account_id = "00000000000000000000000000000000"
    cloudflare_domain     = "example.com"
    kubernetes_namespace  = "domotic-test"
    generate_zigbee_keys  = true
    homeassistant_onboarding = {
      password = "a-long-test-password"
    }
    homeassistant_remote_custom_components = [{
      name         = "fixture"
      url          = "https://example.invalid/fixture.tar.gz"
      sha256       = "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"
      archive_path = "fixture/custom_components/fixture"
    }]
  }

  assert {
    condition = (
      yamldecode(output.helm_values_yaml).homeassistant.customComponents.remote[0].name == "fixture" &&
      yamldecode(output.helm_values_yaml).homeassistant.customComponents.remote[0].sha256 == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" &&
      yamldecode(output.helm_values_yaml).homeassistant.customComponents.remote[0].archivePath == "fixture/custom_components/fixture"
    )
    error_message = "Terraform must pass validated remote custom-component metadata to Helm."
  }
}
