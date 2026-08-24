# Encrypted Cloudflare R2 backups

The backup workflow creates a private R2 bucket with Terraform, gives Home
Assistant access through a Terraform-managed Kubernetes Secret, encrypts a
separate configuration archive locally with
[age](https://github.com/FiloSottile/age), and uploads only encrypted archives.
The credentials and age private identity remain outside Git and outside the
bucket.

The archive contains:

- the selected Terraform variables, portable Zigbee key variables, root
  `values.yaml`, and generated Helm values when present;
- the current Terraform state, pulled from the configured Kubernetes backend;
- the live `zigbee-keys` Secret and `zigbee-network` ConfigMap;
- the live `cloudflared-tunnel-token` Secret;
- the live `homeassistant-r2-credentials` Secret when R2 is enabled;
- the native `homeassistant-backup-encryption` recovery Secret when R2 is
  enabled;
- the optional first-boot `homeassistant-onboarding` Secret; and
- a manifest with the backup timestamp and source cluster context.

It does **not** back up PersistentVolume contents such as Home Assistant's
database or Zigbee2MQTT's runtime data. Add a storage-level backup before those
volumes contain anything you cannot recreate.

Home Assistant's native backup is the preferred way to preserve its database,
automations, users, and other application state. For a new cluster restored
from such a backup, set this before the first deployment:

```hcl
homeassistant_bootstrap_mode = "restore"
```

This keeps the native **Upload backup** action available on the welcome screen
by skipping owner, MQTT, R2, HTTP configuration, automation, script, and scene
seeding. The only created file is a minimal `configuration.yaml` that the
restored `/config` replaces. After the restore succeeds, changing the mode back
to `seed` is safe: the chart adopts and preserves restored files. Keep the
backup emergency-kit key separately; it is required for
encrypted native backups. See [Home Assistant's backup and restore
instructions](https://www.home-assistant.io/common-tasks/general/#backups).

## 1. Install the client tools

Install `age`, `jq`, and the AWS CLI on the machine from which you run Task:

```bash
# macOS
brew install age awscli jq

# Debian/Ubuntu (when both packages are available from your configured repos)
sudo apt-get update
sudo apt-get install --yes age awscli jq
```

Cloudflare R2 exposes an S3-compatible API, which is why this workflow uses the
AWS CLI with the R2 endpoint and `auto` region.

## 2. Create the R2 bucket

The account API token in `infra/terraform.tfvars` needs **Workers R2 Storage
Read** and **Write** in its **Entire Account** policy. Get that token's ID
without printing its secret:

```bash
export CLOUDFLARE_ACCOUNT_ID="<your-account-id>"
printf "Cloudflare account token: " >&2
read -r -s CLOUDFLARE_API_TOKEN
printf "\n" >&2
curl -fsS \
  "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/tokens/verify" \
  -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" |
  jq -r .result.id
unset CLOUDFLARE_API_TOKEN
```

Add the ID, a bucket name, and optionally a location hint. The ID is not the
`cfat_...` token value and is not secret. Bucket names use 3-63 lowercase
letters, numbers, or hyphens and cannot begin or end with a hyphen:

```hcl
cloudflare_api_token_id        = "0123456789abcdef0123456789abcdef"
r2_backup_bucket_name          = "my-domotic-backups"
r2_backup_location             = "weur"
homeassistant_r2_backup_prefix = "home-assistant"
```

Apply the infrastructure change:

```bash
task infra:plan
task infra:apply
```

The bucket has Terraform's `prevent_destroy` lifecycle guard. Removing its
configuration or running `terraform destroy` will stop with an error instead of
silently deleting the backups. Preserve the objects elsewhere before removing
that guard deliberately.

## 3. Configure Home Assistant backups

Terraform uses the same account token to derive the R2 S3 credential pair:

- Access Key ID: the account API token ID;
- Secret Access Key: the SHA-256 hash of the account API token value.

It stores only that pair in the `homeassistant-r2-credentials` Kubernetes
Secret. With owner seeding enabled, the Helm hook creates Home Assistant's
official **Cloudflare R2** integration through its config flow with the bucket,
endpoint, credentials, and `home-assistant` prefix. The flow validates access
to the bucket before saving the entry. The raw `cfat_...` bearer token is never
placed in the Home Assistant pod.

This is the convenient one-token profile: a compromise of Home Assistant would
expose access to R2 objects allowed by the account token, but would not expose
the original bearer token or grant access to DNS and tunnel APIs. Use a
separate bucket-scoped R2 token only if you later want stronger isolation.

When `homeassistant_onboarding` is also configured, seed mode uses that owner's
temporary authenticated session to initialize automatic backups. The defaults
are one encrypted backup every day, the R2 bucket as the only location, seven
retained copies, and Home Assistant's randomized early-morning start time.
Terraform generates a distinct 32-character encryption password and stores it
in the `homeassistant-backup-encryption` Secret. The hook marks the backup setup
as configured only after the matching R2 agent is available.

Override the first-boot defaults when needed:

```hcl
homeassistant_automatic_backups = {
  enabled          = true
  retention_copies = 14
  time             = "03:30:00"
}
```

Set `enabled = false` to opt out. Omitting `time` lets Home Assistant select its
default time and add jitter. These values initialize a fresh, unconfigured
schedule; subsequent changes under **Settings > System > Backups** are
preserved instead of being reconciled by Terraform or Helm.

The authenticated integration and schedule setup requires
`homeassistant_onboarding`. With manual onboarding, add the R2 location and
configure its schedule once in the UI. Existing volumes and native restores
are never modified.

For a schedule initialized by this hook, preserve the generated recovery
password outside the cluster. The repository backup task includes its Secret
and Terraform state inside the separate age-encrypted archive. You can also
copy it directly into a password manager:

```sh
kubectl --context=domotic -n domotic \
  get secret homeassistant-backup-encryption \
  -o go-template='{{index .data "password" | base64decode}}{{"\n"}}'
```

Anyone with this password and a native backup can decrypt that backup. Do not
commit it or reuse the Cloudflare, R2, or Home Assistant owner credentials.
Home Assistant's Cloudflare R2 integration requires Home Assistant 2026.2 or
newer.

If Home Assistant already has backup settings, the hook preserves them and
does not replace their password. In that case, the existing Home Assistant
emergency-kit key remains authoritative and may differ from the Terraform
Secret. Store that existing key separately before relying on those backups.

The chart detects a matching **Cloudflare R2** config entry and preserves it.
It creates only a missing entry, through Home Assistant's own validated config
flow. If owner seeding is disabled, add **Cloudflare R2** once under **Settings
> Devices & services** and copy the values from the Kubernetes Secret instead.

## 4. Create the encryption identity

```bash
install -d -m 0700 "$HOME/.config/domotic"
age-keygen -o "$HOME/.config/domotic/backup.agekey"
age-keygen -y "$HOME/.config/domotic/backup.agekey"
```

The final command prints the public recipient beginning with `age1`. Keep a
second, protected copy of `backup.agekey` in a password manager or offline
storage. The public recipient can encrypt backups but cannot decrypt them; the
private identity is required for recovery.

## 5. Configure and run backups

```bash
cp backup.env.example backup.env
chmod 0600 backup.env
```

Fill `backup.env` with the account ID, bucket name, the same derived R2
credentials, public age recipient, and the absolute path to the private age
identity. The configuration backup defaults to the separate `domotic/` prefix,
while Home Assistant uses `home-assistant/`. The file is ignored by Git.

You can read the generated credential values from the Kubernetes Secret:

```bash
kubectl --context=domotic -n domotic get secret homeassistant-r2-credentials \
  -o jsonpath='{.data.access_key_id}' | base64 --decode
printf '\n'
kubectl --context=domotic -n domotic get secret homeassistant-r2-credentials \
  -o jsonpath='{.data.secret_access_key}' | base64 --decode
printf '\n'
```

Create and verify an encrypted backup:

```bash
task backup
task backup:list
```

The script creates its plaintext staging directory with restrictive
permissions, removes it on exit, uploads the `.tar.gz.age` archive, and verifies
that R2 can read the uploaded object's metadata.

## 6. Recover safely

List the objects, then extract one into the ignored `restore/` directory:

```bash
task backup:list
task backup:restore OBJECT=domotic/domotic-20260823T120000Z-abcdef123456.tar.gz.age
```

The filename alone also works when `R2_PREFIX=domotic`. Restore refuses to
replace an existing recovery directory and never overwrites the active
Terraform, Helm, or Kubernetes configuration. Inspect the extracted state and
configuration before copying selected files back or applying Kubernetes
objects. Treat the extracted Terraform state and Secret JSON as sensitive.

Recreate the ignored Terraform Zigbee input directly from the recovered live
Secret and ConfigMap without printing key values:

```bash
task keys:import SOURCE=restore/domotic-20260823T120000Z-abcdef123456
```

This writes `infra/zigbee-keys.tfvars.json` with mode 0600. Terraform loads it
after `terraform.tfvars`, so the recovered keys override any request to
generate replacements. It records PAN ID and channel as expected values rather
than overrides: if the main configuration differs, Terraform stops before
creating the restored network unless `force_update_secrets=true` is explicit.

Official references:

- [Cloudflare R2 bucket Terraform resource](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/r2_bucket)
- [Cloudflare R2 API tokens](https://developers.cloudflare.com/r2/api/tokens/)
- [Cloudflare R2 with the AWS CLI](https://developers.cloudflare.com/r2/examples/aws/aws-cli/)
- [Home Assistant Cloudflare R2 integration](https://www.home-assistant.io/integrations/cloudflare_r2/)
- [age installation and usage](https://github.com/FiloSottile/age)
