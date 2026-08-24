# Development networking

This guide covers the macOS, Colima, and Kind development topology. It is not
the production k3s networking guide.

The configuration below was verified on 2026-08-24 with Colima 0.10.3 using
macOS Virtualization.framework (`vmType: vz`) and virtiofs. Recheck the Colima
flags and resulting routes after upgrading Colima or Lima.

## Topology and scope

The development traffic path contains several network layers:

```text
Home Assistant pod using the Kind node network
  -> Kind node on a Docker bridge
  -> Colima VM
  -> macOS shared-network gateway
  -> physical LAN
```

The shared-network configuration below allows outbound unicast connections to
known LAN IP addresses. It does not give Kind pods addresses from the physical
LAN. Multicast discovery protocols such as mDNS and SSDP may still fail across
the Docker and VM boundaries. Test discovery-dependent integrations on the
physical k3s server when exact production behavior matters.

Do not hardcode the observed Colima or Kind addresses. They are allocated when
the VM and cluster are created.

## Required Colima configuration

Colima's default user network can provide Internet access without selecting the
preferred shared-network interface for LAN traffic. Use all three network flags:
[Colima's network configuration reference](https://colima.run/docs/configuration/#network-configuration)
describes the address, mode, and preferred-route settings.

```sh
colima stop default
colima start default \
  --network-address \
  --network-mode shared \
  --network-preferred-route \
  --save-config
```

On the verified Colima 0.10.3 installation, using
`--network-preferred-route` without `--network-address` saved
`preferredRoute: true` while leaving `address: false`. Always pass both flags
and verify the effective configuration instead of relying on the documented
implication.

The saved network block must contain:

```yaml
network:
  address: true
  mode: shared
  preferredRoute: true
```

Verify that `colima list` reports an address and that a lower-metric default
route uses the additional Colima interface (observed as `col0`):

```sh
colima list
colima ssh -- ip -brief address
colima ssh -- ip route
colima ssh -- ip route get 192.168.50.50
```

Replace `192.168.50.50` with the device under test. A correct `ip route get`
result proves route selection, not application-level connectivity.

After creating Kind, verify every layer and then probe the device from Home
Assistant:

```sh
docker exec ha-control-plane ip route get 192.168.50.50
kubectl --context kind-ha --namespace kind-ha \
  exec deploy/kind-ha-homeassistant -- ip route get 192.168.50.50
kubectl --context kind-ha --namespace kind-ha \
  exec deploy/kind-ha-homeassistant -- ping -c 1 -W 2 192.168.50.50
```

Use the device's real TCP or UDP port for the final integration test; an ICMP
reply alone does not prove that its application protocol is accessible.

## Destructive recreation safety

The isolated Kind workflow stores Terraform state in the
`kind-ha-terraform-state` namespace inside the Kind cluster. Terraform also
manages resources outside that cluster: the Cloudflare tunnel, tunnel
configuration, DNS record, and optional R2 bucket.

Never delete the Kind cluster or Colima VM first. Choose one of these paths:

1. Preserve and restore the Terraform state before deleting the cluster, if
   the external resources must survive.
2. Run Terraform destroy successfully while the cluster and its state backend
   are still available, if the external test infrastructure should be removed.

For the disposable `kind-ha` environment, initialize the correct backend and
destroy with the matching ignored variable files:

```sh
task infra:init \
  KUBE_CONTEXT=kind-ha \
  STATE_NAMESPACE=kind-ha-terraform-state \
  TF_VARS_FILE=kind-ha.tfvars \
  TF_KEYS_FILE=kind-ha-zigbee-keys.tfvars.json \
  HELM_VALUES_FILE=helm-values-kind-ha.yaml

task infra:destroy \
  KUBE_CONTEXT=kind-ha \
  STATE_NAMESPACE=kind-ha-terraform-state \
  TF_VARS_FILE=kind-ha.tfvars \
  TF_KEYS_FILE=kind-ha-zigbee-keys.tfvars.json \
  HELM_VALUES_FILE=helm-values-kind-ha.yaml
```

The R2 bucket has `prevent_destroy = true` intentionally. Do not disable the
guard or empty the bucket unless the user explicitly authorizes deleting that
exact bucket and its objects. A non-empty bucket cannot be deleted. Cloudflare
also refuses to delete a tunnel with active cloudflared connections; after the
workload stops, wait for the connections to close and retry Terraform destroy.

Only after the destroy succeeds and `terraform state list` is empty may an
agent remove the local runtime data:

```sh
colima delete default --data --force
```

This permanently deletes all Docker images, containers, Kind volumes, and any
unrelated workloads stored in the `default` Colima profile. Confirm the exact
profile and scope before running it. Do not automate this command as part of a
normal repository task.

## Recreate the development stack

Create Colima with enough resources and the verified network settings, then
follow the Kind deployment commands in the README. For the currently tested
profile:

```sh
colima start default \
  --cpu 2 \
  --memory 2 \
  --disk 100 \
  --runtime docker \
  --vm-type vz \
  --mount-type virtiofs \
  --network-address \
  --network-mode shared \
  --network-preferred-route \
  --save-config
```

After deployment, verify the cluster and Terraform state:

```sh
kubectl --context kind-ha get nodes
kubectl --context kind-ha --namespace kind-ha get pods,httproutes
task infra:plan \
  KUBE_CONTEXT=kind-ha \
  STATE_NAMESPACE=kind-ha-terraform-state \
  TF_VARS_FILE=kind-ha.tfvars \
  TF_KEYS_FILE=kind-ha-zigbee-keys.tfvars.json \
  HELM_VALUES_FILE=helm-values-kind-ha.yaml
```

The plan must report no changes after the apply.

## DNS after recreating a Cloudflare tunnel

Deleting and immediately recreating the same proxied hostname can leave a
negative DNS response cached on macOS even after Cloudflare resolves the new
record. A browser may display its cached Home Assistant frontend and then show
that it cannot connect when the WebSocket lookup fails.

Compare a public resolver with the macOS resolver:

```sh
dig +short @1.1.1.1 kind-ha.example.com A
dscacheutil -q host -a name kind-ha.example.com
```

If Cloudflare resolves the name but macOS does not, authenticate locally and
flush the cache, then fully quit and reopen the browser:

```sh
sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder
```

Do not diagnose this cached-frontend symptom as a Home Assistant or WebSocket
failure until `/api/websocket` has been tested through the current tunnel.
