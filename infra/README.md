# Terraform infrastructure

The infrastructure layer manages Cloudflare resources, an optional R2 backup
bucket, Kubernetes secrets and configuration, protected Zigbee network
settings, and the values passed to the Helm chart. Its state is stored as a
Kubernetes Secret in the `terraform-state` namespace.

From the repository root, create the ignored private variables file and edit
its placeholders:

```sh
cp infra/terraform.tfvars.example infra/terraform.tfvars
task infra:plan KUBE_CONTEXT=domotic
task infra:apply KUBE_CONTEXT=domotic
```

The initialization task creates the state namespace and supplies the kubeconfig
path, context, and state namespace to Terraform's partially configured backend.
Override these settings when needed:

```sh
task infra:plan \
  KUBE_CONTEXT=another-context \
  KUBE_CONFIG_PATH=/path/to/config \
  STATE_NAMESPACE=another-namespace
```

`task infra:apply` writes `infra/helm-values.yaml` from Terraform outputs for
the chart layer and captures the live cryptographic Zigbee identity in
`infra/zigbee-keys.tfvars.json`. This generated file, `terraform.tfvars`, state
files, and the `.terraform/` working directory are ignored by Git. The
dependency lock file is tracked and should be committed when provider
selections intentionally change.

The component Taskfile can also be used directly:

```sh
cd infra
task plan KUBE_CONTEXT=domotic
task apply KUBE_CONTEXT=domotic
task keys:capture KUBE_CONTEXT=domotic
```

Use `TF_VARS_FILE`, `TF_KEYS_FILE`, and `HELM_VALUES_FILE` for an isolated
configuration, such as the end-to-end Kind test documented in the root README.
Paths are relative to `infra/`:

```sh
task apply \
  KUBE_CONTEXT=kind-ha \
  STATE_NAMESPACE=kind-ha-terraform-state \
  TF_VARS_FILE=kind-ha.tfvars \
  TF_KEYS_FILE=kind-ha-zigbee-keys.tfvars.json \
  HELM_VALUES_FILE=helm-values-kind-ha.yaml
```

The key file contains `network_key`, `ext_pan_id`, the switch that disables
further generation, and the live PAN ID/channel as recovery guards. PAN ID and
channel remain ordinary variables in the main file: the recorded values do not
override them, but Terraform blocks a mismatch unless
`force_update_secrets=true`. `task infra:backup` refreshes the portable file
from the live Secret and ConfigMap before encrypting and uploading the archive.

`local_http_hostnames` controls the two Gateway API route matches.
`local_http_urls` is optional and defaults to `http://` plus those hostnames;
set it explicitly when the client-visible port differs, such as port 8080 for
Kind. Zigbee2MQTT receives this as `frontend.url`, matching its current
configuration schema. In seed mode, the Helm onboarding hook reconciles Home
Assistant's external and internal URLs through its authenticated WebSocket API
on every install or upgrade. They remain editable in the UI, but the next
deployment restores the Terraform values instead of treating UI changes as
persistent drift.

`homeassistant_bootstrap_mode="seed"` adopts the chart-managed YAML files and
requires `homeassistant_onboarding.password`. The owner name, username, and
language default to `Home Administrator`, `admin`, and `en`. Terraform places
those values in the `homeassistant-onboarding` Secret. Helm then completes Home
Assistant's built-in but undocumented onboarding flow and uses the temporary
admin session to reconcile core and HTTP settings and to create missing MQTT
and R2 entries through their config flows. It revokes the token afterward.
Existing users and integration entries are never overwritten, so this is not a
password- or credential-rotation mechanism.

When an R2 bucket is configured in seed mode, that same temporary admin session
initializes daily encrypted backups to the R2 agent with seven-copy retention.
Terraform generates the distinct recovery password in
`homeassistant-backup-encryption` for that initialization.
`homeassistant_automatic_backups` can change the first-boot retention/time or
disable the schedule; after initialization, Home Assistant owns the settings
and later UI changes are preserved. An existing schedule retains its existing
emergency-kit key, which may differ from the Terraform Secret.

Use `homeassistant_bootstrap_mode="restore"` before deploying onto a blank
volume that will receive a native Home Assistant backup. The chart creates only
a minimal temporary `configuration.yaml` needed to expose the welcome screen;
it does not seed the owner, MQTT, R2, HTTP configuration, automations, scripts,
or scenes. The restored `/config` replaces that temporary file. Switching back
to `seed` afterward adopts and preserves the restored files, but requires the
credentials of an existing restored owner for authenticated reconciliation.

Setting `r2_backup_bucket_name` creates the private backup bucket with a
`prevent_destroy` lifecycle guard. The account API token then also needs
**Workers R2 Storage Read** and **Write**, and `cloudflare_api_token_id` must
contain that token's 32-character identifier. Terraform derives the
corresponding R2 S3 credentials, stores them in the
`homeassistant-r2-credentials` Kubernetes Secret, and passes only the Secret
reference to Helm. The raw Cloudflare token does not enter the application
namespace. Follow [the backup guide](../BACKUP.md) for Home Assistant and
encrypted configuration backups.
