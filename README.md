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

For a new single-node k3s host, complete [DEPLOYMENT.md](DEPLOYMENT.md) first.
It covers k3s, remote cluster access, Traefik Gateway API, and the `.local`
names advertised on the LAN. Run the repository tasks from the administrator
machine whose default kubeconfig contains the `domotic` context.

### 1. Install the workstation tools

Install `kubectl`, Terraform 1.7 or newer, Helm 3 or newer, Git, and
[Task](https://taskfile.dev/docs/installation). Backups additionally require
`age`, `jq`, and the AWS CLI. For Task itself:

```sh
# macOS
brew install go-task

# Debian or Ubuntu
curl -1sLf 'https://dl.cloudsmith.io/public/task/task/setup.deb.sh' | sudo -E bash
sudo apt-get install --yes task
```

You also need a Cloudflare account with a managed domain and, outside the Kind
development environment, a supported Zigbee adapter.

### 2. Clone and create private configuration

```sh
git clone --recurse-submodules https://github.com/fiam/domotic.git
cd domotic

cp infra/terraform.tfvars.example infra/terraform.tfvars
cp examples/values-production.yaml values.yaml
```

Edit `infra/terraform.tfvars` with the Cloudflare account, domain, and Zigbee
network configuration. Seed mode requires an admin password so Helm can
authenticate all Home Assistant API configuration. The username defaults to
`admin`; the password goes only into the ignored variables, Terraform state,
and a Kubernetes Secret:

```hcl
homeassistant_bootstrap_mode = "seed"
homeassistant_onboarding = {
  password = "replace-with-a-long-unique-password"
}
```

The Helm hook uses Home Assistant's built-in but undocumented onboarding HTTP
flow to create the owner and finish first-boot onboarding. With that temporary
admin session it also reconciles core and HTTP settings and creates missing
MQTT and R2 entries through their config flows, then revokes the token. See
`HOME_ASSISTANT_COMPATIBILITY.md` before upgrading. It preserves completed
onboarding and existing integration entries on later deployments. Change
passwords through Home Assistant after the first boot; changing this Terraform
value does not rotate an existing account or integration credential.

When restoring a native Home Assistant backup onto a blank volume, use
`homeassistant_bootstrap_mode = "restore"` and omit the owner block until the
restore finishes. This leaves Home Assistant's **Upload backup** onboarding
path available. Switching back to `seed` afterward does not overwrite restored
configuration, storage, automations, scripts, or scenes. Supply credentials for
an existing restored owner before switching back so the API hook can log in.

Edit `values.yaml` with the serial device, adapter type,
Home Assistant settings, storage, and route parent references described in
[the k3s guide](DEPLOYMENT.md#6-attach-the-application-routes-to-traefik).
Both files are ignored by Git, so pulling upstream changes does not overwrite
local configuration. Do not put secrets in a tracked example file.

For an existing clone, initialize the pinned custom-integration repository
before rendering or deploying the Kind values:

```sh
git submodule update --init --recursive
```

List the available workflows at any time:

```sh
task --list
```

### 3. Plan and deploy

The tasks default to the `domotic` kubeconfig context. Set `KUBE_CONTEXT` on a
command if yours has a different name.

```sh
task check
task infra:plan KUBE_CONTEXT=domotic
task infra:apply KUBE_CONTEXT=domotic
task helm:deploy KUBE_CONTEXT=domotic
task helm:status KUBE_CONTEXT=domotic
```

`task infra:init` creates the `terraform-state` namespace when needed. Applying
Terraform also generates the ignored `infra/helm-values.yaml`; `task
helm:deploy` combines that generated file with the private root `values.yaml`
using `helm upgrade --install`.

The first apply works on an empty namespace. After every successful apply, the
infrastructure task captures the live Zigbee keys into the ignored,
mode-0600 `infra/zigbee-keys.tfvars.json`. Future plans load that file after the
main variables file, so generated keys automatically become explicit,
restorable Terraform inputs without appearing in terminal output.

The encrypted R2 archive includes both this portable variable file and the live
Kubernetes Secret and ConfigMap. The portable file records PAN ID and channel
as recovery guards: they do not override the main variables, but Terraform
blocks a mismatch unless a network change is explicitly forced. To reconstruct
the portable file from a restored archive:

```sh
task backup:restore OBJECT=<object-key>
task keys:import SOURCE=restore/<backup-directory>
```

`task deploy` is the convenient single command for routine infrastructure and
application updates.

The chart consumes the experimental third-party custom integration LAN bridge from a pinned
`custom-integration` submodule. It preserves the vendor Home Server,
discovers it through SSDP, and asks for existing credentials through Home
Assistant's integration UI. See [custom integration.md](custom integration.md) for local and immutable
remote installation workflows; the integration repository owns its protocol,
tests, emulator, and supported-entity documentation.

Component tasks also work locally. For example, `cd infra && task plan` is the
same workflow as `task infra:plan` from the repository root.

### 4. Access the services

- **External (Internet)**: https://homeassistant.example.com (via Cloudflare Tunnel)
- **Internal (LAN)**: http://homeassistant.local (via HTTPRoute/Gateway)
- **Zigbee2MQTT UI**: http://zigbee2mqtt.local

### 5. Back up configuration and keys to R2

Terraform can provision a protected Cloudflare R2 bucket, and the repository's
backup task encrypts configuration, Terraform state, and live Kubernetes
secrets locally with age before uploading them:

```sh
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
├── BACKUP.md                 # Encrypted Cloudflare R2 backup and recovery
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
├── scripts/                 # Host, cluster, and R2 backup helpers
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
