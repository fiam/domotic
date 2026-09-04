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

The development stack keeps encrypted OpenTofu state in Cloudflare R2, not in
the Kind cluster. Deleting Kind or Colima therefore no longer destroys the
resource inventory needed to clean up tunnels and DNS records.

It is still cleaner to destroy the deployment while the cluster is reachable,
because OpenTofu can refresh and remove its Kubernetes resources normally:

```sh
kubectl config use-context kind-ha
task destroy-dev DOMOTIC_TF_VARS_FILE=infra/kind-ha.tfvars
```

The development prefix creates persistent `<prefix>-state` and
`<prefix>-backups` buckets. Normal destroy does not remove either bucket.
Cloudflare may refuse to delete a tunnel while cloudflared connections are
still closing; wait briefly and retry the destroy before deleting the cluster.

Only after the destroy succeeds should an agent remove the local runtime data:

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

Copy and edit the ignored development foundation settings once, using a prefix
that is not shared with any other installation:

```sh
cp bootstrap/terraform.tfvars.example bootstrap.tfvars
${EDITOR:-vi} bootstrap.tfvars
task bootstrap-local
```

The encrypted bootstrap state stays ignored in a public source checkout. Keep
the development recovery passphrase in the same place used for the private
deployment, or export `DOMOTIC_RECOVERY_PASSPHRASE` for disposable automation.

After deployment, verify the cluster and OpenTofu state:

```sh
kubectl config use-context kind-ha
kubectl get nodes
kubectl --namespace kind-ha get pods,httproutes
task deploy-dev DOMOTIC_TF_VARS_FILE=infra/kind-ha.tfvars
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
