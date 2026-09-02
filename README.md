# Domotic

[![Kubernetes v1.23+](https://img.shields.io/badge/Kubernetes-v1.23%2B-326CE5?style=flat-square&logo=kubernetes&logoColor=white)](https://kubernetes.io/releases/)
[![Home Assistant](https://img.shields.io/badge/Home%20Assistant-Core-18BCF2?style=flat-square&logo=home-assistant&logoColor=white)](https://www.home-assistant.io/)
[![Terraform](https://img.shields.io/badge/Terraform-1.7%2B-844FBA?style=flat-square&logo=terraform&logoColor=white)](https://developer.hashicorp.com/terraform)
[![Helm](https://img.shields.io/badge/Helm-3-0F1689?style=flat-square&logo=helm&logoColor=white)](https://helm.sh/)

Home Assistant, Zigbee2MQTT, Mosquitto, and Cloudflare Tunnel on Kubernetes.
Domotic also manages Zigbee network settings, local routes, and optional R2
backups.

## Installation

Keep your home's configuration in a separate private repository. It will pin
the Domotic version, hold the SOPS-encrypted credentials, and provide the Task
commands used below. You do not need to fork this repository.

### Supported Kubernetes environments

Domotic supports Kubernetes 1.23 or newer on any distribution with Gateway API.
The included [k3s guide](DEPLOYMENT.md) is a complete reference for a
single-node home server, not a requirement.

### 1. Install the workstation tools

Install `kubectl`, Terraform 1.7 or newer, Helm 3 or newer, Git, `jq`,
[SOPS](https://getsops.io/docs/), and
[Task](https://taskfile.dev/docs/installation). Repository backups additionally
use `age` and the AWS CLI.

On macOS, Task and SOPS are available through Homebrew:

```sh
brew install go-task sops
```

You also need a Kubernetes cluster, a Cloudflare account with a managed domain,
and a supported Zigbee adapter.

### 2. Create a private deployment repository

Run this in the directory where you keep your private projects:

```sh
mkdir home-deployment
cd home-deployment

task --taskfile \
  'https://github.com/fiam/domotic.git//Taskfile.remote.yml?ref=main' \
  init
```

Task asks you to approve the remote Taskfile the first time. Check the
repository URL before accepting it. `main` can be replaced with a tag, Git ref,
or full commit. The entrypoint resolves it and records the exact commit in the
generated `Taskfile.yml`.

### 3. Encrypt the deployment credentials

Configure SOPS with the key backend of your choice, then create the encrypted
secrets file:

```sh
cp config/secrets.yaml.example config/secrets.yaml
chmod 0600 config/secrets.yaml
${EDITOR:-vi} config/secrets.yaml
sops encrypt --filename-override config/secrets.sops.yaml \
  < config/secrets.yaml > config/secrets.sops.yaml
rm config/secrets.yaml

git add config/secrets.sops.yaml
task secrets:check
```

The file contains two values:

```yaml
CLOUDFLARE_API_TOKEN: your-account-api-token
HOMEASSISTANT_ADMIN_PASSWORD: your-initial-owner-password
```

Domotic does not manage the SOPS key. Standard age, PGP, and KMS setups all
work. Use `task secrets:edit` when the encrypted values need to change.

### 4. Configure, validate, and deploy

Deployment commands use the current kubeconfig context and honor `KUBECONFIG`.
Check the target before planning or deploying:

```sh
kubectl config current-context
```

Edit:

- `config/infra/terraform.tfvars` for Cloudflare, local hostnames, R2, and
  Zigbee network settings;
- `config/values.yaml` for the Zigbee adapter, storage, resources, and
  application settings.

Keep `homeassistant_bootstrap_mode = "seed"` for a new Home Assistant
installation. Then run:

```sh
task secrets:check
task check
task plan
task deploy
task status
```

Review the Terraform plan before applying it. Once the deployment is healthy,
commit and push the private repository:

```sh
git add .
git commit -m "chore: configure home deployment"
git remote add origin <private-repository-url>
git push -u origin main
```

With the documented k3s setup, the default local addresses are:

- `http://homeassistant.local`
- `http://zigbee2mqtt.local`

Home Assistant is also available at the Cloudflare hostname configured in
`config/infra/terraform.tfvars`.

## What gets deployed

Terraform manages the Cloudflare tunnel and DNS, the optional R2 bucket,
protected Zigbee settings, and the Kubernetes secrets consumed by the chart.
Helm deploys:

- Home Assistant
- Zigbee2MQTT
- Mosquitto
- cloudflared

`task deploy` runs both layers in that order. Application data lives on
persistent volumes. Terraform state lives in a Kubernetes Secret, so preserve
the state or run the matching destroy operation before deleting a cluster that
owns external Cloudflare resources.

## Common tasks

Run these from the private repository:

| Command | Purpose |
| --- | --- |
| `task secrets:edit` | Edit the SOPS-encrypted credentials. |
| `task check` | Validate the code and private configuration. |
| `task plan` | Preview Terraform changes. |
| `task deploy` | Apply Terraform and deploy the Helm release. |
| `task domotic:update REF=main` | Update the pinned Domotic code without deploying it. |
| `task homeassistant:update` | Deploy the Home Assistant version verified by the Domotic pin. |
| `task homeassistant:deploy` | Reapply Helm without running Terraform. |
| `task status` | Show the release and workload status. |
| `task keys:capture` | Refresh the portable Zigbee identity. |
| `task backup` | Upload an encrypted recovery archive. |
| `task restore:plan` | Preview native Home Assistant restore mode. |
| `task restore` | Start a blank instance for native backup import. |

## Backups and restore

Home Assistant can write encrypted native backups to R2. A separate repository
backup preserves Terraform state, the Zigbee identity, and Kubernetes recovery
secrets:

```sh
cp config/backup.env.example config/backup.env
chmod 0600 config/backup.env
task backup
```

Setup and recovery instructions are in [BACKUP.md](BACKUP.md).

To import an existing native Home Assistant backup, run `task restore:plan`
and `task restore`, then choose **Upload backup** in Home Assistant. After the
restore, put the password of an owner from the restored system in
`config/secrets.sops.yaml` before returning to `task deploy`.

## Zigbee network safety

The network key, extended PAN ID, PAN ID, and channel identify an existing
Zigbee network. Losing or changing them can mean pairing every device again.
Terraform records the live identity and blocks accidental changes.

After a successful deployment:

```sh
task keys:capture
task backup
```

Only set `force_update_secrets = true` when deliberately creating a different
Zigbee network.

## Upgrading

Update the private repository plumbing without changing the cluster:

```sh
task domotic:update REF=main
git diff -- Taskfile.yml
task check
```

The task resolves `main` to an exact commit. A tag, full Git ref, or commit can
be used instead. Commit the updated pin after reviewing it.

Each Domotic revision declares one tested Home Assistant version. After
updating Domotic and making both backups, deploy that image without running
Terraform:

```sh
task backup
task homeassistant:update
task status
```

Helm still reconciles the complete Domotic release, so any pending changes in
`config/values.yaml` are also applied. Home Assistant setup uses
version-coupled APIs; read
[HOME_ASSISTANT_COMPATIBILITY.md](HOME_ASSISTANT_COMPATIBILITY.md) before
changing the Home Assistant version.

## Development

Clone this repository when changing Terraform, charts, or scripts:

```sh
git clone https://github.com/fiam/domotic.git
cd domotic
task check
```

The development environment uses Kind, an NGINX Gateway, and a Zigbee
coordinator emulator. After preparing disposable `infra/terraform.tfvars`:

```sh
task deploy-dev
task dev:hosts:install
task dev:status
```

Colima and LAN networking details are in
[DEVELOPMENT_NETWORKING.md](DEVELOPMENT_NETWORKING.md). Destroy the Terraform
resources before deleting the Kind cluster:

```sh
task destroy-dev
task dev:hosts:remove
```

## Documentation

- [k3s installation](DEPLOYMENT.md)
- [Private deployment workflow](PRIVATE_DEPLOYMENT.md)
- [Backups and recovery](BACKUP.md)
- [Custom Home Assistant integrations](CUSTOM_INTEGRATIONS.md)
- [Kind and Colima networking](DEVELOPMENT_NETWORKING.md)
- [Home Assistant compatibility contract](HOME_ASSISTANT_COMPATIBILITY.md)
- [Terraform details](infra/README.md)
