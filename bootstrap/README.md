# R2 bootstrap foundation

This OpenTofu root creates the persistent resources needed before the main
deployment can use its backend:

- `<r2_bucket_prefix>-state` and a token scoped to that bucket;
- `<r2_bucket_prefix>-backups` and a different token scoped to that bucket.

It uses an encrypted local backend. Generated private deployments keep that
state at `state/bootstrap.tfstate` and commit it to their private repository.
The state contains the Cloudflare account token and must never be printed or
checked in without OpenTofu encryption.

Use `task bootstrap` from a private deployment rather than invoking this root
directly. The higher-level task prompts for the recovery passphrase and initial
Cloudflare token without echoing them.
