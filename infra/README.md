# OpenTofu infrastructure

The infrastructure configuration manages the Cloudflare tunnel and DNS,
Kubernetes configuration consumed by Helm, generated Home Assistant
credentials, and protected Zigbee network identity.

Its state is encrypted by OpenTofu before being written to the installation's
R2 state bucket. The separate [`bootstrap`](../bootstrap) configuration creates
that bucket, the Home Assistant backup bucket, and one scoped credential for
each.

Use the tasks from a generated private deployment repository for normal
operation. They decrypt bootstrap state in memory, initialize the R2 backend,
and provide the required process environment. Running `tofu` directly requires
recreating that environment and is intended only for development.

## Configuration

The tracked `config/infra/terraform.tfvars` contains non-secret desired state:

- Cloudflare domain, route hostname, and tunnel name;
- Kubernetes namespace and Helm release name;
- local HTTP route names and client-facing URLs;
- Home Assistant owner profile and backup policy;
- Zigbee PAN ID and channel;
- checksum-pinned custom integrations.

It must not contain the Cloudflare token, recovery passphrase, generated owner
password, R2 credentials, or Zigbee keys.

OpenTofu uses the current kubeconfig context and honors `KUBECONFIG`. Confirm
the target before every plan or apply:

```sh
kubectl config current-context
task plan
```

## Generated credentials

`random_password.homeassistant_admin` creates the initial owner password.
`terraform_data.homeassistant_credentials` retains the effective username and
password in encrypted state with changes ignored during ordinary plans. This
prevents a password changed in Home Assistant from being reset accidentally.

`task credentials:update` explicitly replaces that retained value. It is also
used after restoring a native backup, where the owner already exists inside
the restored Home Assistant database.

The Zigbee network key and extended PAN ID follow the same rule: generated on
the first apply and retained in encrypted state. PAN ID and channel stay in the
tracked configuration because they are not secret, but changing any protected
identity value still requires an explicit override.

## Helm values

`task infra:apply` writes an owner-only generated values file containing
references to Kubernetes Secrets and ConfigMaps. It does not contain secret
values. The root deploy task applies that file before the private Helm values.

Generated values configure:

- the MQTT service used by Home Assistant and Zigbee2MQTT;
- local and external Home Assistant URLs;
- local HTTPRoute hostnames;
- the bucket-scoped Cloudflare R2 backup credential;
- automatic native backup defaults;
- the Zigbee2MQTT snapshot CronJob;
- checksum-pinned custom integration mounts.

## Restore mode

`task restore` overrides `homeassistant_bootstrap_mode` to `restore`. The chart
starts with only the minimal Home Assistant configuration required to expose
the native backup upload flow. It does not run onboarding or integration
reconciliation.

After the native backup is restored, `task restore:complete` records an
existing owner credential in encrypted state and returns to normal seed mode.

## Static checks

The static suite does not contact R2, Cloudflare, or Kubernetes:

```sh
task infra:format-check
task infra:validate
task infra:test
```

Tests use mocked external providers. A live Kind test remains required for
Home Assistant's private onboarding, WebSocket, integration, and backup API
contracts; follow [HOME_ASSISTANT_COMPATIBILITY.md](../HOME_ASSISTANT_COMPATIBILITY.md).
