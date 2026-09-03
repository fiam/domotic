cloudflare_account_id = "0123456789abcdef0123456789abcdef"

# This prefix must be unique for every Domotic installation in the Cloudflare
# account. It creates <prefix>-state and <prefix>-backups.
r2_bucket_prefix = "my-home"

# Optional best-effort placement for both buckets.
# r2_location = "weur"

# Optional data residency jurisdiction. This also changes the R2 endpoint.
# r2_jurisdiction = "eu"
