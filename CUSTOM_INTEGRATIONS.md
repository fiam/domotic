# Home Assistant custom integrations

This repository does not ship any custom Home Assistant integration by
default. Deployments opt into integrations explicitly through Terraform or
private Helm values.

## Recommended: Terraform-managed archive

Set `homeassistant_remote_custom_components` in the ignored
`infra/terraform.tfvars` file. Each entry installs exactly one integration
domain:

```hcl
homeassistant_remote_custom_components = [{
  name         = "example_integration"
  url          = "https://github.com/example/integration/archive/0123456789abcdef0123456789abcdef01234567.tar.gz"
  sha256       = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  archive_path = "integration-0123456789abcdef0123456789abcdef01234567/custom_components/example_integration"
}]
```

`name` is the Home Assistant integration domain and therefore permits
underscores. `archive_path` is the directory inside the archive that directly
contains `manifest.json`.

Use an immutable release artifact or a full commit archive. Download it once
to inspect its layout and calculate its digest before adding it:

```sh
archive="$(mktemp)"
curl --fail --location --output "$archive" \
  https://github.com/example/integration/archive/0123456789abcdef0123456789abcdef01234567.tar.gz
tar -tzf "$archive" | grep '/custom_components/.*/manifest.json$'
shasum -a 256 "$archive"
rm "$archive"
```

Terraform writes only the URL, digest, domain, and archive path to generated
non-secret Helm values. An init container downloads the archive on every Home
Assistant pod creation, verifies the SHA-256, rejects unsafe archive paths,
checks for `manifest.json`, and copies only the declared integration directory
into an ephemeral volume. Home Assistant receives that directory as a
read-only mount under `/config/custom_components/<domain>`.

URLs must use HTTPS and must not contain credentials, private access tokens, or
expiring signed parameters. The current mechanism supports public archives. A
private repository should publish a separately accessible immutable artifact
or be supplied through the repository-local Helm method below; do not put a
repository token in Terraform's non-secret Helm output.

Apply and deploy after changing the list:

```sh
task infra:plan
task infra:apply
task helm:deploy
```

## Direct Helm values

Deployments that do not use Terraform can provide the equivalent values in an
ignored `values.yaml`:

```yaml
homeassistant:
  customComponents:
    remote:
      - name: example_integration
        url: https://github.com/example/integration/archive/0123456789abcdef0123456789abcdef01234567.tar.gz
        sha256: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
        archivePath: integration-0123456789abcdef0123456789abcdef01234567/custom_components/example_integration
```

For source already packaged below the Home Assistant chart's `files/`
directory, use a local entry instead:

```yaml
homeassistant:
  customComponents:
    local:
      - name: example_integration
        source: files/repositories/example/custom_components/example_integration
```

The local directory can be ordinary vendored source or a user-managed Git
submodule. It must be present before Helm renders the chart and must contain
the integration's `manifest.json`. No local repository is configured or
required by this project itself.

## Upgrades and removal

Custom integrations execute inside Home Assistant and are coupled to its
internal Python APIs. Before upgrading Home Assistant, verify every configured
integration against the proposed exact Home Assistant version. The deployment
mechanism verifies artifact identity; it cannot establish compatibility or
trustworthiness.

To upgrade an integration, change its immutable URL, digest, and archive path
together, then run the normal Terraform and Helm workflow. The pod-template
checksum changes and forces a Home Assistant rollout.

Before removing an integration from the list, remove its config entries from
Home Assistant when possible. Otherwise Home Assistant retains those entries
and reports that their integration code is missing after the next rollout.
