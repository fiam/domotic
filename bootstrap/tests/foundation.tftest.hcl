mock_provider "cloudflare" {
  mock_data "cloudflare_account_api_token_permission_groups_list" {
    defaults = {
      result = [{
        id     = "bucket-item-write"
        name   = "Workers R2 Storage Bucket Item Write"
        scopes = ["com.cloudflare.edge.r2.bucket"]
      }]
    }
  }

  mock_resource "cloudflare_account_token" {
    defaults = {
      id    = "mock-access-key-id"
      value = "mock-token-value"
    }
  }
}

run "installation_prefix_isolates_buckets_and_tokens" {
  command = plan

  variables {
    cloudflare_api_token  = "mock-account-api-token"
    cloudflare_account_id = "00000000000000000000000000000000"
    r2_bucket_prefix      = "house-one"
    r2_location           = "weur"
    r2_jurisdiction       = "eu"
  }

  assert {
    condition = (
      cloudflare_r2_bucket.state.name == "house-one-state" &&
      cloudflare_r2_bucket.backups.name == "house-one-backups"
    )
    error_message = "The installation prefix must produce distinct state and backup buckets."
  }

  assert {
    condition = (
      jsondecode(cloudflare_account_token.state.policies[0].resources) == {
        "com.cloudflare.edge.r2.bucket.00000000000000000000000000000000_eu_house-one-state" = "*"
      } &&
      jsondecode(cloudflare_account_token.backups.policies[0].resources) == {
        "com.cloudflare.edge.r2.bucket.00000000000000000000000000000000_eu_house-one-backups" = "*"
      }
    )
    error_message = "Each generated token must be scoped to only its own bucket."
  }

  assert {
    condition = (
      output.runtime.state.bucket == "house-one-state" &&
      output.runtime.backups.bucket == "house-one-backups" &&
      output.runtime.endpoint == "https://00000000000000000000000000000000.eu.r2.cloudflarestorage.com" &&
      output.runtime.state.secret_access_key == sha256("mock-token-value")
    )
    error_message = "Bootstrap runtime output must expose derived S3 credentials without changing bucket scope."
  }
}

run "another_installation_gets_different_bucket_names" {
  command = plan

  variables {
    cloudflare_api_token  = "mock-account-api-token"
    cloudflare_account_id = "00000000000000000000000000000000"
    r2_bucket_prefix      = "house-two"
  }

  assert {
    condition = (
      local.state_bucket_name == "house-two-state" &&
      local.backup_bucket_name == "house-two-backups"
    )
    error_message = "A second installation prefix must produce a separate bucket pair."
  }
}

run "invalid_bucket_prefix_is_rejected" {
  command = plan

  variables {
    cloudflare_api_token  = "mock-account-api-token"
    cloudflare_account_id = "00000000000000000000000000000000"
    r2_bucket_prefix      = "Not A Valid Prefix"
  }

  expect_failures = [var.r2_bucket_prefix]
}
