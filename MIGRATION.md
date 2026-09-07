# Migrate an existing Domotic installation to kube4ha

kube4ha changes the project name and defaults for new installations. Upgrade an
existing production installation in place by retaining its deployed identities.
Renaming the Kubernetes namespace or Helm release would create different
resources and does not migrate their persistent data.

## Prepare the private deployment

Keep the existing namespace, release, tunnel, DNS names, R2 bucket prefix, and
storage settings in `config/infra/terraform.tfvars` and `config/values.yaml`.
For an installation using the former defaults, retain:

```hcl
kubernetes_namespace = "domotic"
helm_release_name    = "domotic"
```

Add the existing main-state object key to `config/bootstrap.tfvars`:

```hcl
state_object_key = "domotic.tfstate"
```

The runtime wrapper also reads this key from the encrypted bootstrap state
before a bootstrap re-apply or credential rotation. The explicit setting keeps
direct bootstrap commands pointed at the same state. Preserve the existing
encrypted `state/bootstrap.tfstate` and recovery passphrase. Do not create new
state or backup buckets for this migration.

Update `Taskfile.yml` to use an immutable kube4ha commit, explicitly retaining
the existing Helm identities in the included entrypoint:

```yaml
version: '3'
vars:
  KUBE4HA_REF: REPLACE_WITH_FULL_COMMIT_SHA
includes:
  kube4ha:
    taskfile: 'https://raw.githubusercontent.com/fiam/kube4ha/{{.KUBE4HA_REF}}/Taskfile.remote.yml'
    flatten: true
    vars:
      KUBE4HA_PINNED_REF: '{{.KUBE4HA_REF}}'
      RELEASE_NAME: domotic
      NAMESPACE: domotic
```

Ignore both `/.kube4ha/` and `/.domotic/` in the private repository. Source
materialization uses the new cache after updating the wrapper. Existing
`DOMOTIC_*` input variables and `task domotic:update` remain accepted; new
configuration uses `KUBE4HA_*` and `task kube4ha:update`. An unchanged wrapper
with `DOMOTIC_PINNED_REF` keeps the old cache and default Helm identities.

To keep staging Zigbee recovery snapshots in their existing directory, retain
this override in `config/values.yaml`:

```yaml
homeassistant:
  zigbee2mqttBackup:
    directory: .domotic/zigbee2mqtt
```

New installations use `.kube4ha/zigbee2mqtt`. Existing snapshots are never
deleted by the rename and remain within Home Assistant's configuration volume.
The custom-integration reconciler adopts `.domotic/managed-custom-components`
when its new tracking file is absent; unmanaged integrations remain untouched.

## Review and apply

Confirm that a recent native backup is available, then run from the private
deployment repository using the production context:

```sh
kubectl config current-context
git add Taskfile.yml .gitignore config/bootstrap.tfvars config/values.yaml
task check
task plan
```

The plan must retain the namespace, credentials, tunnel, DNS records, and
Zigbee identity. The namespace's OpenTofu address moves from
`kubernetes_namespace.domotic` to `kubernetes_namespace.kube4ha`; its actual
Kubernetes name stays the same. Protection annotations move to
`kube4ha.fiam.github.com`, with the old annotations still recognized during
validation. Existing creation and update timestamps are retained.

Do not apply a plan that replaces infrastructure merely to change its name.
Both encryption metadata aliases deliberately retain their `domotic-*` names:
they are part of the persisted encryption format, not cosmetic labels. Scoped
Cloudflare token names also remain unchanged for existing foundations.

After reviewing the plan, commit the private configuration and run:

```sh
task deploy
task status
task plan
```

This upgrades the existing Helm release and reuses its PVCs. Verify that all
deployments are available, Home Assistant loads its existing integrations, and
backup staging continues at the retained path. A final plan should converge.
The rename does not change the Home Assistant version.

For application rollback, restore the previous source pin while keeping the
explicit release, namespace, and original configuration paths. The previous
Helm revision can also restore the chart. Once the OpenTofu address move has
been applied, returning to pre-rename infrastructure code requires moving
`kubernetes_namespace.kube4ha` back to `kubernetes_namespace.domotic` in state
before planning; never apply a reverse plan that destroys the namespace.

## Local Kind installations

Kind can be recreated instead of migrated. Follow
[DEVELOPMENT_NETWORKING.md](DEVELOPMENT_NETWORKING.md): destroy the deployment
through its current configuration while the cluster is reachable, then remove
the Kind cluster. This allows OpenTofu to clean up Kubernetes, tunnel, and DNS
resources while preserving the R2 recovery buckets. Use the kube4ha defaults
when creating the replacement installation.
