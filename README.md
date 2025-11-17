# Domotic - Home Automation on Kubernetes

A complete home automation stack running on Kubernetes, featuring Home Assistant, Zigbee2MQTT, MQTT broker, and Cloudflare Tunnel for secure remote access.

## Architecture

This project separates infrastructure management (Terraform) from application deployment (Helm):

**Terraform (infra/)** - Run once, update rarely
- Creates Cloudflare Tunnel + DNS
- Generates/manages Zigbee network keys (with protection)
- Creates Kubernetes secrets
- Manages external dependencies

**Helm (charts/domotic/)** - Standard Helm workflows
- Deploys Home Assistant, Zigbee2MQTT, Mosquitto, Cloudflared
- References Terraform-created secrets
- Update frequently (version upgrades, config changes)

## Quick Start

### Prerequisites

- Kubernetes cluster (k3s, Kind, or any distribution)
- `kubectl` configured
- `terraform` >= 1.5.0
- `helm` >= 3.0
- Cloudflare account with a domain
- Zigbee USB adapter

### Step 1: Setup Infrastructure with Terraform

```bash
cd infra

# Copy and configure variables
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your Cloudflare credentials and settings

# Initialize and apply
terraform init
terraform apply

# IMPORTANT: If you generated keys, save them immediately!
terraform output -json generated_keys > ../KEYS_BACKUP.json
chmod 600 ../KEYS_BACKUP.json

# Generate Helm values from Terraform outputs
terraform output -raw helm_values_yaml > ../terraform-values.yaml
```

### Step 2: Deploy with Helm

```bash
cd ..

# Create your custom values
cat > my-values.yaml <<'EOF'
zigbee2mqtt:
  config:
    serial:
      port: /dev/ttyUSB0
      adapter: ember

homeassistant:
  config:
    name: "My Home"
    latitude: 37.7749
    longitude: -122.4194
EOF

# Install the chart
helm install domotic ./charts/domotic \
  --namespace domotic \
  --create-namespace \
  -f terraform-values.yaml \
  -f my-values.yaml

# Check status
kubectl -n domotic get pods
```

### Step 3: Access Your Services

- **External (Internet)**: https://homeassistant.example.com (via Cloudflare Tunnel)
- **Internal (LAN)**: http://homeassistant.local (via HTTPRoute/Gateway)
- **Zigbee2MQTT UI**: http://zigbee2mqtt.local

## Project Structure

```
domotic/
├── charts/domotic/          # Helm chart (user-facing)
│   ├── Chart.yaml
│   ├── values.yaml          # Default values
│   └── charts/              # Sub-charts
│       ├── homeassistant/
│       ├── zigbee2mqtt/
│       ├── mosquitto/
│       └── cloudflared/
│
├── infra/                   # Terraform infrastructure
│   ├── secrets.tf           # Protected Zigbee key management
│   ├── cloudflare.tf        # Tunnel + DNS configuration
│   ├── kubernetes.tf        # K8s secrets
│   ├── variables.tf         # Input variables
│   ├── outputs.tf           # Outputs for Helm
│   └── terraform.tfvars.example
│
├── examples/                # Example configurations
│   ├── values-minimal.yaml
│   └── values-production.yaml
│
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
terraform apply

# SAVE THESE IMMEDIATELY!
terraform output -json generated_keys
```

#### After First Run

Update `terraform.tfvars` with the generated keys and disable generation:

```hcl
zigbee_network_key = "A1B2C3D4E5F67890A1B2C3D4E5F67890"
zigbee_ext_pan_id = "1234567890ABCDEF"
zigbee_pan_id = 6754
zigbee_channel = 15
generate_zigbee_keys = false  # Important!
```

### Protected Configuration Changes

All Zigbee network settings are automatically protected from accidental changes. If you try to modify them, Terraform will block the operation:

```bash
$ terraform apply
Error: PROTECTED ZIGBEE CONFIGURATION MODIFICATION BLOCKED!

You're trying to change protected Zigbee network settings that will break your network!

SECRET (sensitive keys):
  • network_key: A1B2C3D4... → WRONG_KE...

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

```bash
# Edit your values file
cat >> my-values.yaml <<'EOF'
homeassistant:
  image:
    tag: "2024.12"
EOF

# Upgrade with Helm
helm upgrade domotic ./charts/domotic \
  --namespace domotic \
  -f terraform-values.yaml \
  -f my-values.yaml
```

### Update Zigbee Channel or PAN ID (PROTECTED!)

**Warning**: Changing these settings will break communication with all paired devices!

These settings are managed via Terraform and are **protected** from accidental changes:

```bash
# Edit infra/terraform.tfvars
zigbee_channel = 20       # Change to your desired channel
zigbee_pan_id = 6754      # Change if needed
force_update_secrets = true  # Required!

cd infra
terraform apply

# This will break your Zigbee network!
# You must re-pair all devices after changing these settings.
```

Why protected? Because changing `pan_id` or `channel` changes which network your coordinator is on. All paired devices will still be looking for the old network and won't be able to communicate.

### Change Zigbee Network Keys (DANGEROUS!)

**Warning**: This will break your network and require re-pairing all devices!

```bash
# infra/terraform.tfvars
zigbee_network_key = "NEW_KEY_HERE"
force_update_secrets = true

terraform apply
```

## Common Operations

### View Protected Resources Status

```bash
cd infra

# View Secret status (sensitive keys)
terraform output zigbee_secret_status

# View ConfigMap status (network settings)
terraform output zigbee_configmap_status

# View all Zigbee configuration
terraform output -json zigbee_config
```

### Check Generated Keys

```bash
terraform output -json generated_keys
# or from backup:
cat KEYS_BACKUP.json
```

### Update Cloudflare Settings

```bash
# Edit infra/terraform.tfvars
cloudflare_homeassistant_subdomain = "ha"

cd infra
terraform apply
# No Helm changes needed - tunnel auto-updates
```

### View All Services

```bash
kubectl -n domotic get all
kubectl -n domotic get secrets
kubectl -n domotic get httproutes
```

## Troubleshooting

### Zigbee2MQTT Can't Access Serial Device

```bash
# Check device exists
ls -l /dev/ttyUSB0

# Verify pod sees device
kubectl -n domotic exec -it deployment/domotic-zigbee2mqtt -- ls -l /dev/ttyUSB0
```

### Home Assistant Not Accessible via Tunnel

```bash
# Check Cloudflare tunnel status
kubectl -n domotic logs deployment/domotic-cloudflared

# Verify DNS record
dig homeassistant.example.com
```

### MQTT Connection Issues

```bash
# Check Mosquitto logs
kubectl -n domotic logs deployment/domotic-mosquitto

# Test connectivity from Home Assistant
kubectl -n domotic exec -it deployment/domotic-homeassistant -- nc -zv domotic-mosquitto 1883
```

## Contributing

This project uses protected secrets and Terraform-managed infrastructure. When contributing:

1. Never commit `terraform.tfvars` or `KEYS_BACKUP.json`
2. Test with `generate_zigbee_keys = true` in a test cluster
3. Use example values files as reference

## Links

- [Home Assistant Documentation](https://www.home-assistant.io/docs/)
- [Zigbee2MQTT Documentation](https://www.zigbee2mqtt.io/)
- [Cloudflare Tunnel Documentation](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
- [GitHub Repository](https://github.com/fiam/domotic)
