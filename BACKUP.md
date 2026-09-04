# Backups and disaster recovery

Domotic uses two private Cloudflare R2 buckets for different purposes:

- `<prefix>-state` contains client-side encrypted OpenTofu state;
- `<prefix>-backups` contains Home Assistant native backups.

The buckets have different scoped credentials. Home Assistant cannot read or
modify infrastructure state.

There is no separate Domotic repository-backup command. The private Git
repository, encrypted OpenTofu state, and Home Assistant native backups are the
recovery set.

## What to keep

Keep these independently recoverable:

1. the private deployment repository, including `state/bootstrap.tfstate`;
2. the recovery passphrase used by OpenTofu;
3. the native Home Assistant backups in R2.

The encrypted bootstrap state contains the Cloudflare account token and the
two bucket-scoped credentials. The main state bucket contains generated Home
Assistant credentials, Zigbee keys, Cloudflare resource IDs, and the desired
Kubernetes objects. Home Assistant's backup contains its database and `/config`.

Losing only a Kubernetes cluster or server is recoverable. Losing the recovery
passphrase makes both OpenTofu states unreadable. Losing the state bucket can
orphan external Cloudflare resources even if the Home Assistant backup
survives.

## Bucket setup

The private deployment's `config/bootstrap.tfvars` selects the bucket prefix:

```hcl
cloudflare_account_id = "0123456789abcdef0123456789abcdef"
r2_bucket_prefix      = "my-home"
r2_location           = "weur" # optional
```

`task bootstrap` creates `my-home-state` and `my-home-backups`, plus one
object read/write token for each bucket. Use a different prefix for every
Domotic installation sharing the Cloudflare account.

Both buckets are private and protected from ordinary OpenTofu destruction.
The state backend also uses OpenTofu's adjacent `.tflock` object to serialize
operations.

## Automatic Home Assistant backups

In seed mode, the Home Assistant onboarding Job creates a Cloudflare R2 backup
agent through Home Assistant's config flow. It then initializes automatic
backups with seven-copy retention and Home Assistant's default randomized
early-morning schedule.

Override those defaults in `config/infra/terraform.tfvars`:

```hcl
homeassistant_automatic_backups = {
  enabled          = true
  retention_copies = 14
  time             = "03:30:00"
}
```

The bootstrap settings are applied only when the R2 config entry or automatic
backup settings are missing. Later changes made in Home Assistant remain
authoritative.

Backups are unencrypted by default because the bucket is private. To enable
Home Assistant's native backup encryption:

```hcl
homeassistant_backup_encryption_enabled = true
```

OpenTofu generates and retains the password in encrypted state. Retrieve it
with `task credentials:show`, and download Home Assistant's emergency kit from
the backup settings page. Keep the kit outside the cluster and R2 account.

Verify backups in Home Assistant under **Settings → System → Backups**. An
actual restore test is stronger than checking that an object exists in R2.

## Zigbee2MQTT data in native backups

An hourly Kubernetes CronJob asks Zigbee2MQTT for its documented data-directory
backup over MQTT. It validates the response as a ZIP and atomically replaces:

```text
/config/.domotic/zigbee2mqtt/latest.zip
/config/.domotic/zigbee2mqtt/latest.timestamp
```

Home Assistant includes that directory in its native `/config` archive. Only
one Zigbee2MQTT snapshot is staged, so it does not create a second retention
system. With the default `17 * * * *` schedule, Zigbee data can be up to one
hour older than the Home Assistant backup.

The Job mounts only Home Assistant's claim. Required pod affinity places it on
the Home Assistant pod's node for `ReadWriteOnce` volumes; it never mounts the
live Zigbee2MQTT claim. A failed MQTT request or invalid ZIP leaves the last
valid snapshot intact.

Change the schedule or disable staging in `config/values.yaml`:

```yaml
homeassistant:
  zigbee2mqttBackup:
    schedule: "17 */6 * * *"
    # enabled: false
```

Inspect execution status without displaying archive contents:

```sh
kubectl -n domotic get cronjob domotic-homeassistant-z2m-backup
kubectl -n domotic get jobs \
  -l app.kubernetes.io/component=zigbee2mqtt-backup
```

A Home Assistant restore puts the staged ZIP back under `/config`. Restoring
that ZIP into a new Zigbee2MQTT volume is a separate maintenance operation;
never extract it over a running Zigbee2MQTT instance.

## Restore onto a new cluster

Clone the private repository and configure access to the replacement cluster:

```sh
git clone <private-repository-url> home-deployment
cd home-deployment
kubectl config current-context
```

Then prepare Home Assistant's native restore screen:

```sh
task restore:plan
task restore
```

Enter the OpenTofu recovery passphrase when prompted. The restore task reads
the existing encrypted main state from R2, recreates cluster secrets and
routes, and deploys only the minimal Home Assistant configuration needed for
the native upload flow.

Upload the chosen backup in Home Assistant and wait for the application to
restart. Then run:

```sh
task restore:complete
```

Supply an owner username and password from the restored system. The task
retains that credential in encrypted state and resumes MQTT, R2, URL, and
other chart-derived reconciliation. It also reinstalls each declared custom
integration from its checksum-pinned artifact; their directories remain on the
writable configuration volume so they cannot block Home Assistant from
replacing `/config` during restoration.

After recovery, confirm:

- Home Assistant history and integrations are present;
- a new automatic backup reaches R2;
- MQTT and Zigbee2MQTT are connected;
- PAN ID and channel match the private configuration;
- the staged Zigbee2MQTT archive exists and is current;
- `task plan` reports no unexpected changes.

## Rotate recovery credentials

Replace the Cloudflare account token before revoking the old token:

```sh
task cloudflare-token:update
git add state/bootstrap.tfstate
git commit -m "chore: rotate Cloudflare token"
```

After the first deployment, change the OpenTofu recovery passphrase with:

```sh
task recovery-passphrase:update
git add state/bootstrap.tfstate
git commit -m "chore: rotate recovery passphrase"
```

That task rolls both encrypted states to the new key. If it is interrupted,
retry with the same new passphrase.

References:

- [Home Assistant backups](https://www.home-assistant.io/common-tasks/general/#backups)
- [Cloudflare R2 API tokens](https://developers.cloudflare.com/r2/api/tokens/)
- [OpenTofu state encryption](https://opentofu.org/docs/v1.12/language/state/encryption/)
- [OpenTofu S3 backend](https://opentofu.org/docs/language/settings/backends/s3/)
- [Zigbee2MQTT backup request](https://www.zigbee2mqtt.io/guide/usage/mqtt_topics_and_messages.html#zigbee2mqttbridgerequestbackup)
