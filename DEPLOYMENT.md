# Install on a single-node k3s server

This is the documented reference setup for a common home-server environment.
Domotic itself supports any Kubernetes distribution that ships Gateway API;
use this guide only when choosing k3s.

This guide prepares a new Debian or Ubuntu server for Domotic. It installs
k3s, enables Traefik's Kubernetes Gateway API provider, configures remote
cluster access, and advertises the application hostnames on the local network
with multicast DNS (mDNS).

The examples use:

- Server hostname: `domotic-server`
- Home Assistant: `http://homeassistant.local`
- Zigbee2MQTT: `http://zigbee2mqtt.local`

The server can use an ordinary DHCP lease; neither a static address nor a DHCP
reservation is required by these instructions. A reservation is still useful
if other systems need to connect to the server by address.

> `.local` names use mDNS and normally work only within the same broadcast
> domain/VLAN. If the home network has multiple VLANs, prefer local unicast DNS
> (for example `homeassistant.home.arpa`) or configure an mDNS reflector on the
> router.

## 1. Prepare the host

Set a stable hostname and inspect the LAN interface and address:

```sh
sudo hostnamectl set-hostname domotic-server
ip -br address
ip route show default
```

Install Avahi before k3s so that the server itself is reachable as
`domotic-server.local`:

```sh
sudo apt-get update
sudo apt-get install --yes avahi-daemon avahi-utils libnss-mdns curl
sudo systemctl enable --now avahi-daemon
systemctl is-active avahi-daemon
```

From another mDNS-capable machine on the same LAN, verify the primary name:

```sh
ping domotic-server.local
```

Linux clients may also need `libnss-mdns`; macOS and iOS include mDNS support.

### Optional: use the server's Bluetooth adapter

Home Assistant Container uses the host's BlueZ service through the system
D-Bus socket. Install BlueZ on the server and confirm that it sees a controller:

```sh
sudo apt-get install --yes bluez
sudo systemctl enable --now bluetooth.service
systemctl is-active bluetooth.service
bluetoothctl list
```

Then expose the host D-Bus directory read-only in the private deployment's
`config/values.yaml`:

```yaml
homeassistant:
  volumes:
    - name: host-dbus
      hostPath:
        path: /run/dbus
        type: Directory
  volumeMounts:
    - name: host-dbus
      mountPath: /run/dbus
      readOnly: true
```

Deploy the change with `task deploy`. The Home Assistant chart already grants
the `NET_ADMIN` and `NET_RAW` capabilities required for reliable Bluetooth
management. If the server keeps its system bus below `/var/run/dbus`, use that
as the `hostPath.path` while retaining `/run/dbus` as the container mount path.

## 2. Configure and install k3s

Configure the API server names before the first installation. This avoids an
unnecessary certificate rotation later. Secret encryption at rest is enabled
because this deployment stores Cloudflare, MQTT, and Zigbee credentials as
Kubernetes Secrets.

```sh
sudo install -d -m 0755 /etc/rancher/k3s
sudo tee /etc/rancher/k3s/config.yaml >/dev/null <<EOF
tls-san:
  - "$(hostname --short).local"
secrets-encryption: true
EOF
```

Install from k3s's production-recommended `stable` channel:

```sh
curl -sfL https://get.k3s.io | sudo env INSTALL_K3S_CHANNEL=stable sh -
```

For a reproducible installation, replace `INSTALL_K3S_CHANNEL=stable` with
`INSTALL_K3S_VERSION=<version from the k3s releases page>` and record that
version in the server's configuration notes.

Verify the installation:

```sh
sudo systemctl status k3s --no-pager
sudo k3s --version
sudo k3s kubectl get nodes -o wide
```

Do not edit `/var/lib/rancher/k3s/server/manifests/traefik.yaml`; k3s replaces
that packaged manifest during upgrades.

## 3. Enable Gateway API in the packaged Traefik

Current k3s releases package Traefik v3 and the standard Gateway API CRDs. A
separate Gateway API CRD installation is not required for the `HTTPRoute`
resources used by this project.

Create a `HelmChartConfig` alongside the packaged manifests:

```sh
sudo tee /var/lib/rancher/k3s/server/manifests/traefik-config.yaml >/dev/null <<'EOF'
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    providers:
      kubernetesGateway:
        enabled: true
    gateway:
      enabled: true
      name: traefik-gateway
      listeners:
        web:
          namespacePolicy:
            from: All
EOF
```

Wait for k3s's Helm controller to reconcile Traefik, then confirm that the
Gateway exists:

```sh
sudo k3s kubectl -n kube-system rollout status deployment/traefik --timeout=5m
sudo k3s kubectl get gatewayclass
sudo k3s kubectl -n kube-system get gateway traefik-gateway
```

Traefik is exposed through k3s ServiceLB on the server's ports 80 and 443.

## 4. Configure remote `kubectl` and Helm access

The k3s admin kubeconfig grants unrestricted cluster access. Copy it only to a
trusted administrator machine and keep it private. After initializing the
private deployment repository in
[the README](README.md#install), run this from
that repository to merge the server configuration into your kubeconfig under
the distinct name `domotic`:

```sh
task k3s:context \
  SSH_USER=your-server-user \
  SSH_HOST=domotic-server.local

kubectl config get-contexts
kubectl config use-context domotic
kubectl get nodes
```

Replace `your-server-user` with the account used to SSH into the server. The
task materializes the pinned public source and the import script allocates a
terminal so `sudo` can request that account's password. It
backs up an existing configuration, avoids collisions with k3s's generic
`default` names, and preserves the current context until you explicitly switch
to `domotic`. Deployment tasks use the current context. The merged kubeconfig
contains embedded client certificates. Run the script again after k3s rotates
or renews them. The helper writes to `KUBECONFIG` when it names one file and
otherwise uses `~/.kube/config`; deployment commands support the normal
multi-file `KUBECONFIG` form.

## 5. Advertise the application names with Avahi

Kubernetes CoreDNS only serves clients inside the cluster, and an `HTTPRoute`
hostname does not create a LAN DNS or mDNS record. For a single-node home
server, publish the application names from the host and point them at the IPv4
address already advertised for the host's primary mDNS name.

The names are configured once in `config/infra/terraform.tfvars` in the
private deployment repository and passed to both Helm HTTPRoutes:

```hcl
local_http_hostnames = {
  homeassistant = "homeassistant.local"
  zigbee2mqtt   = "zigbee2mqtt.local"
}
```

Use the labels before `.local` for the Avahi units below. If you customize
these variables, customize the two unit instances as well.

First, find the interface carrying the default IPv4 route:

```sh
ip -4 route show default
```

Edit the existing `[server]` section in
`/etc/avahi/avahi-daemon.conf` and set `allow-interfaces` to the interface shown
after `dev`. For a wireless interface named `wlo1`, use:

```ini
[server]
allow-interfaces=wlo1
```

This prevents Avahi from advertising k3s interfaces such as `cni0`. Restart
Avahi and confirm that the primary name resolves to the LAN address:

```sh
sudo systemctl restart avahi-daemon
avahi-resolve-host-name -4 "$(hostname --short).local"
```

Create a small publisher script. It deliberately resolves only IPv4 because
k3s ServiceLB and home LAN IPv6 configurations vary:

```sh
sudo tee /usr/local/sbin/avahi-publish-alias >/dev/null <<'EOF'
#!/bin/sh
set -eu

primary_name="${AVAHI_PRIMARY_NAME:-$(hostname --short).local}"
alias_label="${1:?missing alias label}"
address="$({ /usr/bin/avahi-resolve-host-name -4 "$primary_name" || true; } \
  | /usr/bin/awk 'NR == 1 { print $2 }')"

if [ -z "$address" ]; then
  echo "Could not resolve $primary_name to an IPv4 address" >&2
  exit 1
fi

exec /usr/bin/avahi-publish-address \
  --no-reverse --no-fail "${alias_label}.local" "$address"
EOF
sudo chmod 0755 /usr/local/sbin/avahi-publish-alias
```

Create a reusable systemd template for the application aliases:

```sh
sudo tee /etc/systemd/system/avahi-alias@.service >/dev/null <<'EOF'
[Unit]
Description=Publish %i.local as a local mDNS alias
After=avahi-daemon.service network-online.target
Requires=avahi-daemon.service
Wants=network-online.target
PartOf=avahi-daemon.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/avahi-publish-alias %i
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now \
  avahi-alias@homeassistant.service \
  avahi-alias@zigbee2mqtt.service
```

`--no-reverse` is intentional: both aliases share one address, so the server's
primary name remains the only reverse mapping. The address is determined once
at service startup. If DHCP changes the address while the server remains
running, restart the alias units (or reboot) to publish the new address:

```sh
sudo systemctl restart 'avahi-alias@*.service'
```

Confirm which address the publisher selected before testing the aliases from
another machine:

```sh
systemctl --no-pager --full status \
  avahi-alias@homeassistant.service \
  avahi-alias@zigbee2mqtt.service
```

Verify the aliases from another machine on the same LAN:

```sh
avahi-resolve-host-name -4 homeassistant.local
avahi-resolve-host-name -4 zigbee2mqtt.local
```

## 6. Attach the application routes to Traefik

On the administrator machine, continue from
[the private deployment workflow](README.md#configure-and-deploy).
First run `task bootstrap` as described there. It creates separate R2 buckets
for encrypted OpenTofu state and Home Assistant backups, plus a bucket-scoped
credential for each. Then fill in `config/infra/terraform.tfvars` and customize
`config/values.yaml`, including the serial adapter and storage settings.

Do not put the Cloudflare token, passwords, or generated Zigbee keys in either
configuration file. They are retained only in encrypted OpenTofu state. Keep
the recovery passphrase in a password manager.

The repository installs no custom Home Assistant integration by default. If
this deployment needs one, declare its public immutable archive in
`homeassistant_remote_custom_components` or use a repository-local source in
private Helm values. Follow [CUSTOM_INTEGRATIONS.md](CUSTOM_INTEGRATIONS.md)
for checksum, archive-path, upgrade, and removal requirements.

For a new Home Assistant installation, keep
`homeassistant_bootstrap_mode="seed"`. OpenTofu generates and retains the first
owner credential, then creates the Kubernetes Secret consumed by a one-shot
Helm hook. The hook uses Home Assistant's built-in but undocumented onboarding
flow, completes the remaining steps, reconciles core and HTTP settings, and
creates missing MQTT and R2 entries through their config flows. Its temporary
login token is revoked. It never replaces an existing user, password, or
integration entry.

For a native Home Assistant backup recovery onto a blank volume, run
`task restore:plan` followed by `task restore`. These targets temporarily select
restore mode without editing the tracked seed setting or creating an owner.
Open Home Assistant, choose **Upload backup**, and use the credentials and
emergency-kit key from the backed-up system. After the restore succeeds, run
`task restore:complete` to record an existing restored owner credential in
encrypted state and resume normal reconciliation.

Use the following route attachment for k3s's packaged Traefik. OpenTofu
supplies both route hostnames from `local_http_hostnames`, so do not repeat them
in `config/values.yaml`:

```yaml
homeassistant:
  httpRoute:
    enabled: true
    parentRefs:
      - name: traefik-gateway
        namespace: kube-system
        sectionName: web

zigbee2mqtt:
  httpRoute:
    enabled: true
    parentRefs:
      - name: traefik-gateway
        namespace: kube-system
        sectionName: web
```

Validate, review, and deploy from the private repository root. These tasks use
the current `kubectl` context and do not change it:

```sh
kubectl config current-context
task check
task plan
task deploy
task status
```

The first apply generates the Home Assistant owner password and Zigbee key
material in encrypted R2 state. Use `task credentials:show` when the initial
login is needed. Import an existing Zigbee identity before the first deploy
with `task zigbee:import SOURCE=/path/to/zigbee-keys.tfvars.json`.

Verify that Traefik accepted the routes:

```sh
kubectl -n domotic get httproute
kubectl -n domotic describe httproute
curl --fail --show-error --head http://homeassistant.local
curl --fail --show-error --head http://zigbee2mqtt.local
```

Do not use `examples/values-kind.yaml` on k3s; it connects Zigbee2MQTT to the
development-only coordinator emulator.

## 7. Configure off-host backups

`task bootstrap` creates the private R2 backup bucket and a credential scoped
to that bucket. In seed mode, the chart creates Home Assistant's official
Cloudflare R2 backup location through its validated config flow, then
configures daily backups and retains seven copies by default. Set
`homeassistant_backup_encryption_enabled = true` to generate a native backup
password. Use `homeassistant_automatic_backups` to change the initial
retention/time or disable scheduling. Existing integration entries, backup
settings, and native restores are preserved.

For a newly initialized encrypted schedule, preserve the configured password
and download Home Assistant's emergency kit before relying on native backups.
A preserved existing schedule keeps its existing Home Assistant emergency-kit
key instead. Recovery details are in
[BACKUP.md](BACKUP.md#automatic-home-assistant-backups).

The chart also stages a validated Zigbee2MQTT data-directory archive inside
Home Assistant's configuration volume every hour. The next native backup then
contains both applications' recoverable data. Encrypted OpenTofu state in the
separate state bucket retains generated credentials and Zigbee identity.
Recovery and verification steps are in [BACKUP.md](BACKUP.md).

## Firewall notes

The k3s project recommends disabling UFW because it can interfere with the
default pod and service networks. On a dedicated server behind a trusted LAN
firewall:

```sh
sudo ufw disable
```

If UFW must remain enabled, follow the current k3s networking requirements and
allow at least:

- TCP 6443 from administrator machines to the Kubernetes API.
- TCP 80 and 443 from the LAN to Traefik.
- UDP 5353 from the LAN for mDNS.
- Traffic from the default pod network `10.42.0.0/16` and service network
  `10.43.0.0/16`.

Additional ports are required when adding more k3s nodes. Never expose the
Flannel VXLAN port (UDP 8472) to the public internet.

## Adding a `tls-san` after installation

Prefer configuring every stable API address before installation. If an address
must be added later, update `/etc/rancher/k3s/config.yaml` and follow k3s's
documented stop-rotate-start sequence:

```sh
sudo systemctl stop k3s
sudo k3s certificate rotate
sudo systemctl start k3s
```

Refresh any remote copies of `/etc/rancher/k3s/k3s.yaml` afterward.

## References

- [k3s quick-start guide](https://docs.k3s.io/quick-start)
- [k3s configuration file](https://docs.k3s.io/installation/configuration)
- [k3s networking and Gateway API](https://docs.k3s.io/networking/networking-services)
- [k3s installation requirements](https://docs.k3s.io/installation/requirements)
- [k3s cluster access](https://docs.k3s.io/cluster-access)
- [k3s certificate rotation](https://docs.k3s.io/cli/certificate)
- [Traefik Gateway API provider](https://doc.traefik.io/traefik/providers/kubernetes-gateway/)
- [Home Assistant Bluetooth requirements](https://www.home-assistant.io/integrations/bluetooth/#requirements-for-linux-systems)
- [Avahi address publication](https://manpages.debian.org/trixie/avahi-utils/avahi-publish-address.1.en.html)
- [Avahi daemon configuration](https://manpages.debian.org/trixie/avahi-daemon/avahi-daemon.conf.5.en.html)
- [Cloudflare R2 bucket OpenTofu resource](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/r2_bucket)
- [Cloudflare R2 with the AWS CLI](https://developers.cloudflare.com/r2/examples/aws/aws-cli/)
