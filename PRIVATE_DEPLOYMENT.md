# Run Domotic from a private repository

Keep hostnames, device settings, and encrypted bootstrap state in an
independent private repository. Do not use a GitHub fork: a fork of a public
repository remains public.

The private repository contains only your configuration and a pinned Domotic
revision. Its Taskfile fetches the entrypoint through an immutable commit URL,
then downloads that same revision into the ignored `.domotic` directory when a
command runs.

## Create the repository

```sh
mkdir home-deployment
cd home-deployment

task --taskfile \
  'https://github.com/fiam/domotic.git//Taskfile.remote.yml?ref=main' \
  init
```

The generated files are:

```text
home-deployment/
├── .opentofu-version
├── Taskfile.yml
├── README.md
├── config/
│   ├── bootstrap.tfvars
│   ├── values.yaml
│   └── infra/
│       └── terraform.tfvars
└── state/
    └── bootstrap.tfstate       # created by task bootstrap and committed
```

`.domotic` and generated Helm values are ignored. Do not edit the materialized
source under `.domotic`.

## Bootstrap Cloudflare and state

Create a Cloudflare account API token with:

- Account API Tokens Read and Write for the entire account;
- Workers R2 Storage Read and Write for the entire account;
- Cloudflare One Connector `cloudflared` Read and Write for the entire account;
- Zone Read and DNS Read and Write for the zone used by this installation.

The account-token permissions let OpenTofu create two child tokens. Each child
has object read/write access to one R2 bucket and nothing else.

Set the account and a unique installation prefix in
`config/bootstrap.tfvars`:

```hcl
cloudflare_account_id = "0123456789abcdef0123456789abcdef"
r2_bucket_prefix      = "my-home"
r2_location           = "weur" # optional
```

This creates `my-home-state` and `my-home-backups`. Bucket names are scoped to
the Cloudflare account, so every Domotic installation in that account must use
a different prefix.

Run:

```sh
task bootstrap
```

The task asks for:

1. a recovery passphrase of at least 16 characters;
2. the Cloudflare account API token.

OpenTofu encrypts `state/bootstrap.tfstate` with PBKDF2 and AES-GCM. The file
contains the account token, bucket identities, and the two scoped R2
credentials, but none of those values are readable without the passphrase.

Task does not create commits or push on your behalf. Keep the recovery
passphrase outside this repository, preferably in a password manager. Set
`DOMOTIC_RECOVERY_PASSPHRASE` when a password manager or automation supplies
it; otherwise Task prompts without echoing it.

## Configure the installation

Edit `config/infra/terraform.tfvars` for:

- the Cloudflare domain, hostname, and tunnel name;
- local Home Assistant and Zigbee2MQTT routes;
- the Kubernetes namespace and Helm release;
- the Zigbee PAN ID and channel;
- optional custom integrations and backup settings.

Edit `config/values.yaml` for storage classes, volume sizes, the Zigbee adapter,
resources, and chart-specific settings.

Do not add tokens, passwords, Zigbee keys, or the recovery passphrase to either
file. The account ID and both R2 bucket names come from bootstrap state.

Stage the complete private configuration so the safety check can inspect what
Git will retain. Commands use the current kubeconfig context and honor
`KUBECONFIG`:

```sh
git add .
kubectl config current-context
task check
task plan

git commit -m "chore: configure home deployment"
git remote add origin <private-repository-url>
git push -u origin main

task deploy
task status
```

The first apply generates the Home Assistant password and Zigbee key material
inside encrypted R2 state. Retrieve the initial login only when needed:

```sh
task credentials:show
```

The default username is `admin`. If you later change the owner password or
username in Home Assistant, record it before the next reconciliation:

```sh
task credentials:update
task deploy
```

The update task prompts securely and deliberately replaces only the retained
credential. The subsequent deployment updates the Kubernetes Secret and runs
the normal Home Assistant reconciliation.

To import an existing Zigbee identity before the first deployment, set the
matching `zigbee_pan_id` and `zigbee_channel`, then run:

```sh
task zigbee:import SOURCE=/path/to/zigbee-keys.tfvars.json
task plan
```

The legacy bundle is read in memory and is not copied into the repository.

## Backups and restore

Seed mode configures Home Assistant's R2 integration and daily native backups.
The backup bucket credential cannot read or modify the OpenTofu state bucket.
Native backups are unencrypted by default; set this to generate a separate
backup password:

```hcl
homeassistant_backup_encryption_enabled = true
```

`task credentials:show` displays that password. Also download Home Assistant's
backup emergency kit and keep it outside the cluster.

The chart stages the latest Zigbee2MQTT data-directory ZIP below Home
Assistant's `/config` directory every hour, so it is included in the next
native backup. See [BACKUP.md](BACKUP.md) for verification and recovery.

To restore onto a blank cluster:

```sh
task restore:plan
task restore
```

Upload and restore a native backup through Home Assistant. After Home Assistant
has restarted, finish with:

```sh
task restore:complete
```

That task asks for an owner credential from the restored system, stores it in
encrypted state, and resumes normal seed-mode reconciliation. It does not
create another owner. The normal deployment also reconciles checksum-pinned
custom integrations after the restored configuration has taken over.

## Recover the deployment repository

On a new workstation:

```sh
git clone <private-repository-url> home-deployment
cd home-deployment
kubectl config current-context
task plan
```

Enter the recovery passphrase when prompted. Task decrypts the committed
bootstrap state in memory, uses its state-bucket credential to open the main R2
state, and supplies the Cloudflare token only to the OpenTofu process.

The normal `task destroy` path preserves both R2 buckets. Losing the private
repository is recoverable from another clone. Losing the recovery passphrase
is not.

## Updates and credential rotation

Update the pinned Domotic source without deploying it:

```sh
task domotic:update REF=main
git diff -- Taskfile.yml
task check
```

After reviewing the change, `task homeassistant:update` selects the Home
Assistant version verified by that Domotic revision and performs a Helm-only
deployment. A native backup should exist before every Home Assistant update.

Replace the Cloudflare account token with:

```sh
task cloudflare-token:update
git add state/bootstrap.tfstate
git commit -m "chore: rotate Cloudflare token"
```

After the first deployment, re-encrypt both bootstrap and main state with a
new recovery passphrase:

```sh
task recovery-passphrase:update
git add state/bootstrap.tfstate
git commit -m "chore: rotate recovery passphrase"
```

Do not revoke the old Cloudflare token until its replacement task succeeds.
During passphrase rotation, keep the same new passphrase if an interrupted
operation must be retried.

Official references:

- [Task remote Taskfiles](https://taskfile.dev/docs/remote-taskfiles)
- [OpenTofu state encryption](https://opentofu.org/docs/v1.12/language/state/encryption/)
- [OpenTofu S3 backend](https://opentofu.org/docs/language/settings/backends/s3/)
- [Cloudflare R2 API tokens](https://developers.cloudflare.com/r2/api/tokens/)
- [Cloudflare R2 remote backend](https://developers.cloudflare.com/terraform/advanced-topics/remote-backend/)
