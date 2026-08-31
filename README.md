# Domotic - Home Automation on Kubernetes

A complete home automation stack running on Kubernetes, featuring Home Assistant, Zigbee2MQTT, MQTT broker, and Cloudflare Tunnel for secure remote access.

## Architecture

This project separates infrastructure management (Terraform) from application deployment (Helm):

**Terraform (infra/)** - Run once, update rarely
- Creates Cloudflare Tunnel + DNS
- Creates the protected R2 backup bucket and Home Assistant credentials
- Generates/manages Zigbee network keys (with protection)
- Creates Kubernetes secrets
- Manages external dependencies

**Helm (charts/domotic/)** - Standard Helm workflows
- Deploys Home Assistant, Zigbee2MQTT, Mosquitto, Cloudflared
- Delivers repository-local or checksum-pinned remote Home Assistant custom integrations
- References Terraform-created secrets
- Update frequently (version upgrades, config changes)

## Installation

The recommended production layout is an independent private repository that
contains only your non-secret configuration and one reviewed Domotic commit
SHA. Task runs that revision through its remote-Taskfile support, so users do
not need to fork or manually maintain a copy of this public repository.

### 1. Install the workstation tools

Install `kubectl`, Terraform 1.7 or newer, Helm 3 or newer, Git, `jq`, and
[Task](https://taskfile.dev/docs/installation). Backups additionally require
`age` and the AWS CLI. For Task itself:

```sh
# macOS
brew install go-task

# Debian or Ubuntu
curl -1sLf 'https://dl.cloudsmith.io/public/task/task/setup.deb.sh' | sudo -E bash
sudo apt-get install --yes task
```

You also need a Cloudflare account with a managed domain and, outside the Kind
development environment, a supported Zigbee adapter.

### 2. Create a private deployment repository

Run these commands in whichever parent directory you use for projects. The
directory name is arbitrary; no absolute workstation path is assumed:

```sh
mkdir home-deployment
cd home-deployment

DOMOTIC_REF="$(git ls-remote https://github.com/fiam/domotic.git \
  refs/heads/main | awk '{print $1}')"

task --taskfile \
  "https://github.com/fiam/domotic.git//Taskfile.remote.yml?ref=${DOMOTIC_REF}" \
  init DOMOTIC_REF="$DOMOTIC_REF"
```

Review the selected commit before approving Task's first remote-source trust
prompt. The generated `Taskfile.yml` pins that exact revision, initializes a
new Git repository, and stores the materialized public source under the ignored
`.domotic/source` directory.

### 3. Prepare and connect the k3s host

Complete the server-side commands in sections 1–3 and 5 of
[the k3s host guide](DEPLOYMENT.md). They install k3s, enable Traefik's Gateway
API provider, install Avahi, and advertise the two `.local` service names.

Then import the server into the administrator's default kubeconfig without
cloning this public repository:

```sh
task k3s:context \
  SSH_USER=your-server-user \
  SSH_HOST=your-server-hostname.local

kubectl --context=domotic get nodes
```

The import script opens an SSH terminal so remote `sudo` can authenticate.
Change `KUBE_CONTEXT` in the private `Taskfile.yml` if `domotic` is not the
desired local context name.

### 4. Select the credential references

Edit the two references in the generated `Taskfile.yml`. Their URI schemes
select the credential resolver independently:

| Reference | Resolver |
| --- | --- |
| `keychain://ACCOUNT/SERVICE` | macOS Keychain generic password |
| `op://VAULT/ITEM/FIELD` | [1Password CLI secret reference](https://www.1password.dev/cli/secret-reference-syntax/) |
| `env://VARIABLE` | Environment variable, primarily for CI |
| `sops://PATH#KEY` | Top-level string in an optional SOPS document |

Install the command named by the chosen scheme: `security` ships with macOS,
`op` comes from the 1Password CLI, and `sops` is required only for `sops://`.

For macOS Keychain, the generated defaults work without embedding a username
or filesystem path:

```yaml
CLOUDFLARE_API_TOKEN_REF: keychain://domotic/cloudflare-api-token
HOMEASSISTANT_ADMIN_PASSWORD_REF: keychain://domotic/homeassistant-admin-password
```

Store and verify both values:

```sh
task secrets:set
task secrets:check
```

For 1Password, use its native secret-reference syntax. The references are safe
to commit; the values remain in 1Password:

```yaml
CLOUDFLARE_API_TOKEN_REF: op://Infrastructure/Cloudflare/credential
HOMEASSISTANT_ADMIN_PASSWORD_REF: op://Infrastructure/HomeAssistant/password
```

The resolver detects `op://` and runs `op read`; `task secrets:set` is only for
`keychain://` references, so create 1Password items with the app or CLI first.
There is intentionally no `passwords://` scheme: Apple does not document a
Passwords command-line integration, while Keychain generic passwords are
accessible through macOS's `security` command.

SOPS is optional, not an additional requirement. A password manager alone is
enough for normal deployment. See
[the extended credential reference guide](PRIVATE_DEPLOYMENT.md#credential-reference-formats)
for SOPS, age-key references, environment-based CI, and custom resolvers.

### 5. Configure, validate, and deploy

Edit `config/infra/terraform.tfvars` with the Cloudflare account, domain,
routes, R2 bucket choice, and protected Zigbee network settings. Edit
`config/values.yaml` with the Zigbee adapter, persistence, and Home Assistant
settings. Credentials do not belong in either file.

For a new installation, leave the tracked bootstrap mode as:

```hcl
homeassistant_bootstrap_mode = "seed"
```

```sh
task --list
task check
task secrets:check
task plan
task deploy
task status
```

Set `KUBE_CONTEXT` in the private `Taskfile.yml` if the installed context has a
different name. Commit the private repository only after reviewing the plan;
its `.gitignore` excludes generated Helm values, Zigbee keys, backup client
credentials, restored archives, and the materialized public source.

```sh
git add .
git commit -m "chore: configure home deployment"
git remote add origin <private-repository-url>
git push -u origin main
```

For a native Home Assistant backup, prepare the blank instance without editing
the tracked seed mode or retrieving the admin-password reference:

```sh
task restore:plan
task restore
```

Upload the native backup in Home Assistant, then make the admin-password
reference resolve to an owner restored from that backup before the next normal
`task deploy`.

Custom integrations are optional and never selected by the repository. Add a
checksum-pinned public archive through
`homeassistant_remote_custom_components` as described in
[CUSTOM_INTEGRATIONS.md](CUSTOM_INTEGRATIONS.md).

### 6. Access the services

- **External**: the configured Cloudflare hostname
- **Home Assistant on the LAN**: `http://homeassistant.local`
- **Zigbee2MQTT on the LAN**: `http://zigbee2mqtt.local`

### 7. Back up configuration and keys to R2

Terraform can provision a protected R2 bucket. The repository backup task
encrypts configuration, Terraform state, and live Kubernetes secrets locally
with age before uploading them:

```sh
cp config/backup.env.example config/backup.env
chmod 0600 config/backup.env
task backup
task backup:list
```

Follow [BACKUP.md](BACKUP.md) first to configure the bucket, account token ID,
and an independently stored age identity. Terraform derives one R2 credential
pair from the same account token. In seed mode, the authenticated hook creates
Home Assistant's official R2 backup location through its config flow and
defaults to daily encrypted R2 backups with seven-copy retention. Preserve the
generated `homeassistant-backup-encryption` password outside the cluster; the
repository backup includes it inside the separate age-encrypted archive. The
repository backup workflow never uploads plaintext secrets and restores into
an ignored staging directory without replacing active files.

## Development with Kind

Kind is development tooling, not the production deployment path. Its Taskfile
and manifests live under `dev/` and it installs the Zigbee coordinator emulator.
Clone the public repository when working on the charts or development cluster:

```sh
git clone https://github.com/fiam/domotic.git
cd domotic
```

When using Colima, follow
[DEVELOPMENT_NETWORKING.md](DEVELOPMENT_NETWORKING.md) to make known LAN device
addresses reachable and to preserve the correct Terraform teardown order:

```sh
task dev:create
task dev:hosts:install
task dev:status
task dev:destroy
```

The hosts task adds only a marked block mapping the two development HTTPRoute
names to `127.0.0.1`; it leaves every other `/etc/hosts` entry untouched and
saves the previous file as `/etc/hosts.domotic.bak`. Kind publishes its Gateway
on port 8080, so open `http://homeassistant.local:8080` and
`http://zigbee2mqtt.local:8080`. Remove the block with `task
dev:hosts:remove`.

Set `local_http_hostnames` in the selected Terraform variables file to change
the two HTTPRoute hostnames. For Kind, also set `local_http_urls` with port
8080 so Home Assistant and Zigbee2MQTT publish accurate client-facing URLs.
Pass the same hostnames when configuring development hosts:

```hcl
local_http_urls = {
  homeassistant = "http://homeassistant.local:8080"
  zigbee2mqtt   = "http://zigbee2mqtt.local:8080"
}
```

```sh
task dev:hosts:install \
  HOMEASSISTANT_HOSTNAME=ha.test \
  ZIGBEE2MQTT_HOSTNAME=zigbee.test
```

`task deploy-dev` creates the cluster and runs the Terraform and Helm layers
against `kind-domotic`; it still requires the configured Cloudflare variables.
The NGINX Gateway Fabric version is pinned in `dev/Taskfile.yml` so its chart and
Gateway API definitions stay compatible.

For an isolated end-to-end Cloudflare test, use a separate ignored variables
file and state namespace. Give it distinct tunnel, hostname, bucket, namespace,
and release names. Disposable Kind environments use the deliberately insecure
`admin`/`foobar` account; never use it outside local development:

```hcl
homeassistant_bootstrap_mode = "seed"
homeassistant_onboarding = {
  password = "foobar"
}
```

Then run:

```sh
task dev:create CLUSTER_NAME=ha KUBE_CONTEXT=kind-ha
task dev:hosts:install
task infra:apply \
  KUBE_CONTEXT=kind-ha \
  STATE_NAMESPACE=kind-ha-terraform-state \
  TF_VARS_FILE=kind-ha.tfvars \
  TF_KEYS_FILE=kind-ha-zigbee-keys.tfvars.json \
  HELM_VALUES_FILE=helm-values-kind-ha.yaml
task helm:deploy \
  KUBE_CONTEXT=kind-ha \
  RELEASE_NAME=kind-ha \
  NAMESPACE=kind-ha \
  TERRAFORM_VALUES_FILE=../../infra/helm-values-kind-ha.yaml \
  VALUES_FILE=../../examples/values-kind.yaml
```

Destroy the Terraform-managed Cloudflare resources before deleting the Kind
cluster, because the test state is stored inside that cluster. The R2 bucket's
destruction guard requires preserving and deliberately deleting its objects
before removing the bucket.

## Project Structure

```
domotic/
├── Taskfile.yml              # Repository-wide workflows
├── Taskfile.remote.yml       # Commit-pinned private deployment entrypoint
├── BACKUP.md                 # Encrypted Cloudflare R2 backup and recovery
├── PRIVATE_DEPLOYMENT.md     # Long-lived private configuration workflow
├── DEVELOPMENT_NETWORKING.md # Colima, Kind, and LAN routing safety
├── backup.env.example        # Private backup-client configuration template
├── charts/domotic/          # Helm chart (user-facing)
│   ├── Chart.yaml
│   ├── Taskfile.yml          # Helm lifecycle and validation
│   ├── values.yaml          # Default values
│   └── charts/              # Sub-charts
│       ├── homeassistant/
│       ├── zigbee2mqtt/
│       ├── mosquitto/
│       └── cloudflared/
│
├── infra/                   # Terraform infrastructure
│   ├── Taskfile.yml          # State, plan, apply, and validation
│   ├── secrets.tf           # Protected Zigbee key management
│   ├── cloudflare.tf        # Tunnel + DNS configuration
│   ├── r2.tf                # Optional protected R2 backup bucket
│   ├── kubernetes.tf        # K8s secrets
│   ├── variables.tf         # Input variables
│   ├── outputs.tf           # Outputs for Helm
│   └── terraform.tfvars.example
│
├── dev/                     # Kind-only development environment
│   ├── Taskfile.yml
│   ├── kind.yaml
│   └── gateway.yaml
│
├── examples/                # Example configurations
│   ├── values-minimal.yaml
│   └── values-production.yaml
│
├── scripts/                 # Host, cluster, backup, and credential helpers
│   └── secret-reference.sh  # URI-dispatched credential resolver
└── README.md
```

## Configuration Management

### What's Managed Where?

**Terraform (Infrastructure)** - Run once, rarely changed:

*Protected & Sensitive (Secret)*:
- `network_key` - Cryptographic key, **never commit**
- `ext_pan_id` - Network identifier, **sensitive**

*Protected but Non-Sensitive (ConfigMap)*:
- `pan_id` - Network setting, **protected** but not secret
- `channel` - RF channel, **protected** but not secret

*External Resources*:
- Cloudflare Tunnel configuration
- DNS records

**All Zigbee network settings are PROTECTED** - changing them breaks communication with all paired devices and requires `force_update_secrets = true`.

**Helm (Application)** - Frequently updated:
- Serial port configuration
- MQTT server address
- Home Assistant settings
- Image versions
- Resource limits
- HTTPRoute configuration

### Zigbee Network Keys

Your Zigbee network keys are **critical** - if lost, you must re-pair all devices.

#### First-Time Setup (Generate Keys)

In `infra/terraform.tfvars`:
```hcl
generate_zigbee_keys = true
zigbee_pan_id = 6754     # Optional: customize PAN ID
zigbee_channel = 15      # Optional: customize channel
```

```bash
task infra:apply
```

The apply captures the generated values in
`infra/zigbee-keys.tfvars.json` automatically:

```sh
task keys:capture
task backup
```

Do not commit the portable file. The encrypted R2 backup is its off-host copy.
After restoring a backup into `restore/`, `task keys:import
SOURCE=restore/<backup-directory>` recreates it without exposing the keys on
the command line.

### Protected Configuration Changes

All Zigbee network settings are automatically protected from accidental changes. If you try to modify them, Terraform will block the operation:

```bash
$ task infra:apply
Error: PROTECTED ZIGBEE CONFIGURATION MODIFICATION BLOCKED!

You're trying to change protected Zigbee network settings that will break your network!

SECRET (sensitive keys):
  • network_key would change

CONFIGMAP (network settings):
  • channel: 15 → 20

⚠️  Changing these will break communication with ALL paired Zigbee devices!

If you REALLY want to change these (requires re-pairing all devices):
  force_update_secrets = true
```

This protection applies to:
- **Secret**: `network_key`, `ext_pan_id` (sensitive)
- **ConfigMap**: `pan_id`, `channel` (non-sensitive but protected)

## Upgrading

Private deployments upgrade by changing their single pinned `DOMOTIC_REF`,
then running `task check`, `task backup`, `task plan`, and `task deploy`. Review
[the private upgrade workflow](PRIVATE_DEPLOYMENT.md#5-maintain-and-upgrade)
and [HOME_ASSISTANT_COMPATIBILITY.md](HOME_ASSISTANT_COMPATIBILITY.md) before
changing the pin.

### Upgrade Home Assistant Version

Edit `values.yaml`:

```yaml
homeassistant:
  image:
    tag: "<tested-version>"
```

Then reconcile the release:

```sh
task helm:deploy
```

### Update Zigbee Channel or PAN ID (PROTECTED!)

**Warning**: Changing these settings will break communication with all paired devices!

These settings are managed via Terraform and are **protected** from accidental changes:

```bash
# Edit infra/terraform.tfvars
zigbee_channel = 20       # Change to your desired channel
zigbee_pan_id = 6754      # Change if needed
force_update_secrets = true  # Required!

task infra:plan
task infra:apply

# This will break your Zigbee network!
# You must re-pair all devices after changing these settings.
```

Why protected? Because changing `pan_id` or `channel` changes which network your coordinator is on. All paired devices will still be looking for the old network and won't be able to communicate.

### Change Zigbee Network Keys (DANGEROUS!)

**Warning**: This will break your network and require re-pairing all devices!

```bash
# Preserve the current keys first.
task keys:capture
```

Edit `infra/zigbee-keys.tfvars.json` using JSON syntax, then enable the safety
override in `infra/terraform.tfvars`:

```hcl
force_update_secrets = true
```

```bash
task infra:apply
```

## Common Operations

### View Protected Resources Status

```bash
# View Secret status (sensitive keys)
task infra:outputs -- zigbee_secret_status

# View ConfigMap status (network settings)
task infra:outputs -- zigbee_configmap_status

# Refresh the ignored key file without printing its values
task keys:capture
```

### Update Cloudflare Settings

```bash
# Edit infra/terraform.tfvars
cloudflare_homeassistant_subdomain = "ha"

task infra:apply
# No Helm changes needed - tunnel auto-updates
```

### View All Services

```bash
task helm:status
kubectl --context=domotic -n domotic get secrets
```

## Troubleshooting

### Zigbee2MQTT Can't Access Serial Device

```bash
# Check device exists
ls -l /dev/ttyUSB0

# Verify pod sees device
kubectl --context=domotic -n domotic exec -it \
  deployment/domotic-zigbee2mqtt -- ls -l /dev/ttyUSB0
```

### Home Assistant Not Accessible via Tunnel

```bash
# Check Cloudflare tunnel status
kubectl --context=domotic -n domotic logs deployment/domotic-cloudflared

# Verify DNS record
dig homeassistant.example.com
```

### MQTT Connection Issues

```bash
# Check Mosquitto logs
kubectl --context=domotic -n domotic logs deployment/domotic-mosquitto

# Test connectivity from Home Assistant
kubectl --context=domotic -n domotic exec -it \
  deployment/domotic-homeassistant -- nc -zv domotic-mosquitto 1883
```

## Contributing

This project uses protected secrets and Terraform-managed infrastructure. When contributing:

1. Never commit `terraform.tfvars` or `zigbee-keys.tfvars.json`
2. Test with `generate_zigbee_keys = true` in a test cluster
3. Run `task check` before committing
4. Use example values files as reference

## Links

- [Home Assistant Documentation](https://www.home-assistant.io/docs/)
- [Zigbee2MQTT Documentation](https://www.zigbee2mqtt.io/)
- [Cloudflare Tunnel Documentation](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
- [GitHub Repository](https://github.com/fiam/domotic)
