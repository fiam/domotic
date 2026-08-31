# Private production deployments

Use an independent private repository for a long-lived home installation. Do
not place personal configuration on a branch of this public repository, and do
not use a GitHub fork: a fork of a public repository remains public.

The private repository stores non-secret desired state and a pinned Domotic
revision. Task downloads a commit-pinned remote `Taskfile.remote.yml`. Because
remote Taskfiles do not expose a local repository directory, that Taskfile
materializes the same pinned commit under the ignored `.domotic/source`
directory before running Terraform, Helm, or repository scripts. The checkout
is detached and its origin and commit are verified on every change.

## 1. Create the private repository

Create an empty directory wherever you normally keep projects and select the
exact public commit to trust. The directory name is arbitrary. Review that
commit before accepting Task's first remote-source prompt:

```sh
mkdir home-deployment
cd home-deployment

DOMOTIC_REF="$(git ls-remote https://github.com/fiam/domotic.git \
  refs/heads/main | awk '{print $1}')"

task --taskfile \
  "https://github.com/fiam/domotic.git//Taskfile.remote.yml?ref=${DOMOTIC_REF}" \
  init DOMOTIC_REF="$DOMOTIC_REF"
```

The generated `Taskfile.yml` records that full commit SHA. Commit the
scaffold to a new, independent private repository:

```sh
git add .
git commit -m "chore: initialize home deployment"
git remote add origin <private-repository-url>
git push -u origin main
```

Task automatically remembers an approved remote-file checksum and prompts if
it changes. A full commit SHA prevents the selected Git content from moving.
For unattended CI, inspect and add the remote Taskfile's explicit `checksum`
to the include instead of accepting every remote source with `--yes`.

The generated layout is:

```text
home-deployment/
├── Taskfile.yml
├── README.md
├── config/
│   ├── values.yaml
│   ├── backup.env.example
│   └── infra/
│       └── terraform.tfvars
└── .domotic/                 # ignored materialized public source
```

The remote entrypoint is the deployment's operator interface:

| Task | Purpose |
| --- | --- |
| `bootstrap` | Materialize and verify the pinned public source checkout. |
| `check`, `plan`, `deploy`, `status` | Validate and operate the normal deployment. |
| `restore:plan`, `restore` | Prepare a blank Home Assistant instance for a native backup import. |
| `backup`, `backup:list`, `backup:restore` | Manage encrypted configuration-recovery archives. |
| `k3s:context` | Import the server into the default administrator kubeconfig. |
| `keys:capture` | Refresh the portable Zigbee identity after a successful apply. |
| `version` | Show the requested and materialized public revisions. |

Run `task --list` for the complete command surface. The `bootstrap` task treats
`.domotic/source` as disposable: it verifies the origin and commit and removes
non-ignored untracked changes before any delegated operation.

Edit the two tracked configuration files. They may contain private hostnames,
device paths, selected integrations, and other non-secret desired state. Do
not add the Cloudflare token, Home Assistant password, Zigbee keys, generated
Helm values, backup credentials, or restored archives.

Run the boundary check before committing configuration:

```sh
task config:check
```

It rejects known plaintext Terraform credentials in a tracked variables file,
tracked generated/recovery files, and private runtime files with permissions
broader than owner-only, non-executable access such as mode `0600`.

## 2. Credential reference formats

Terraform needs two credentials during a normal seed-mode deployment:

- `cloudflare_api_token`
- `homeassistant_admin_password`

The private Taskfile configures a reference for each value. The URI scheme
selects the resolver automatically, so the two credentials may come from
different password managers. The wrapper resolves them immediately before
Terraform starts and passes them as `TF_VAR_cloudflare_api_token` and a JSON
`TF_VAR_homeassistant_onboarding` value. It never writes or prints either
value. Terraform still stores sensitive resource inputs in its protected
Kubernetes backend, so cluster access and the encrypted recovery archive
remain security boundaries.

### macOS Keychain (default)

The generated references use macOS Keychain generic-password items:

```yaml
CLOUDFLARE_API_TOKEN_REF: keychain://domotic/cloudflare-api-token
HOMEASSISTANT_ADMIN_PASSWORD_REF: keychain://domotic/homeassistant-admin-password
```

The URI carries the Keychain account and service; there is no separate
provider or profile setting. Save both values interactively:

```sh
task secrets:set
task secrets:check
```

The built-in resolver uses `/usr/bin/security` with the account and service
encoded in each reference. macOS may ask whether the process can access each
Keychain item. Do not select an option that grants every application access.

Apple does not document a command-line integration for the Passwords app.
Keychain Services is the native scriptable credential store; generic entries
created here are managed by Keychain and are not guaranteed to appear as
ordinary website entries in Passwords.

To remove an entry explicitly:

```sh
.domotic/source/scripts/secret-reference.sh delete \
  keychain://domotic/cloudflare-api-token
```

If only one of the two references uses Keychain, manage it directly with the
same `set` command. `task secrets:set` intentionally requires both references
to use Keychain so it cannot partially update a mixed configuration.

### 1Password

Use 1Password's native `op://VAULT/ITEM/FIELD` references:

```yaml
CLOUDFLARE_API_TOKEN_REF: op://Infrastructure/Cloudflare/credential
HOMEASSISTANT_ADMIN_PASSWORD_REF: op://Infrastructure/HomeAssistant/password
```

The built-in resolver detects the scheme and executes `op read` with the
complete reference. Authenticate the 1Password CLI using its normal desktop,
service-account, or CI workflow, then run `task secrets:check`. Create and
update these items with 1Password rather than `task secrets:set`.

### Environment references

For CI, point each reference at a variable injected by the CI secret store:

```yaml
CLOUDFLARE_API_TOKEN_REF: env://DOMOTIC_CLOUDFLARE_API_TOKEN
HOMEASSISTANT_ADMIN_PASSWORD_REF: env://DOMOTIC_HOMEASSISTANT_ADMIN_PASSWORD
```

Avoid typing secret assignments into interactive shell history.

### Custom resolver

Set `SECRET_RESOLVER` to an executable path to add other schemes such as a
hardware-backed store. The executable receives `get <reference>` and must print
only the requested value to standard output. `set <reference>` and
`delete <reference>` are optional operations used only for interactive secret
management.

```sh
#!/bin/sh
set -eu
test "$1" = get
case "$2" in
  vault://cloudflare) exec my-vault read cloudflare-token ;;
  vault://homeassistant) exec my-vault read homeassistant-password ;;
  *) exit 1 ;;
esac
```

Keep the resolver in the private repository, mark it executable, and configure
it relative to that repository without a machine-specific path:

```yaml
SECRET_RESOLVER: '{{.ROOT_DIR}}/scripts/secret-resolver'
```

The resolver contains references and commands, never credentials.

### Optional SOPS

SOPS is not required when a password manager is the source of truth. Use it
only when encrypted, versioned secret files are useful for multiple operators
or CI.

The built-in `sops://PATH#KEY` scheme reads a top-level string from an
encrypted document. Relative paths resolve from the private repository root:

```yaml
CLOUDFLARE_API_TOKEN_REF: sops://config/secrets.sops.yaml#cloudflare_api_token
HOMEASSISTANT_ADMIN_PASSWORD_REF: sops://config/secrets.sops.yaml#homeassistant_admin_password
```

SOPS can find an age identity through its normal environment or key-file
locations. Alternatively, reference the one-line age secret identity through
another supported scheme:

```yaml
SOPS_AGE_KEY_REF: keychain://domotic/sops-age-key
```

Store that Keychain value with:

```sh
.domotic/source/scripts/secret-reference.sh set \
  keychain://domotic/sops-age-key
```

The wrapper retrieves it only while SOPS decrypts the deployment values.
Commit only the encrypted
`secrets.sops.yaml`; preserve the age identity independently.

This SOPS identity and the age identity configured in `backup.env` serve
different roles. They may use the same key for a small single-user setup, but
the recovery identity must always have an independent password-manager or
offline copy.

## 3. Plan and deploy

Validate code, configuration, and credentials before the first plan:

```sh
task check
task secrets:check
task plan
```

For a new installation, keep `homeassistant_bootstrap_mode = "seed"` and
deploy:

```sh
task deploy
task status
```

For a native Home Assistant backup recovery, prepare the blank installation
without changing the tracked seed configuration or requesting an owner
password:

```sh
task restore:plan
task restore
```

Open Home Assistant, upload and restore the native backup, and then store the
credentials of an owner from that backup in the configured reference. The next ordinary
`task deploy` returns to the tracked seed mode; it finds the existing owner and
uses those credentials to reconcile the chart-derived settings.

## 4. Back up the installation

Create the ignored backup client file and use the independently stored age
identity described in [BACKUP.md](BACKUP.md):

```sh
cp config/backup.env.example config/backup.env
chmod 0600 config/backup.env
task backup
task backup:list
```

`CONFIG_DIR` makes the backup script archive the private `values.yaml`,
Terraform variables, generated Helm values, portable Zigbee identity, live
Kubernetes secrets, and Terraform state. Home Assistant's native R2 backup
separately preserves its database and application state.

## 5. Maintain and upgrade

For a configuration change:

```text
edit configuration → task check → task plan → task backup
→ review the plan → task deploy → task status → commit
```

For an upstream upgrade:

1. Run and verify both configuration and Home Assistant native backups.
2. Review the target commit and `HOME_ASSISTANT_COMPATIBILITY.md`.
3. Change the single `DOMOTIC_REF` in the private Taskfile.
4. Run `task check`, `task plan`, `task deploy`, and `task status`.
5. Commit the new pin only after Home Assistant, MQTT, Zigbee, routes, and R2
   backups are healthy.

Reverting `DOMOTIC_REF` rolls back code and charts. It does not reverse a Home
Assistant database migration; use a native backup when application data must
also be restored.

The `.domotic/source` checkout and Task's remote-file cache allow normal tasks
to keep running offline after they have been materialized. An upgrade requires
network access to retrieve the newly pinned commit.

Official references:

- [Task remote Taskfiles](https://taskfile.dev/docs/remote-taskfiles)
- [GitHub fork visibility](https://docs.github.com/en/pull-requests/reference/forks)
- [Terraform sensitive inputs](https://developer.hashicorp.com/terraform/tutorials/configuration-language/sensitive-variables)
- [1Password secret-reference syntax](https://www.1password.dev/cli/secret-reference-syntax/)
- [SOPS](https://getsops.io/docs/)
- [Apple Passwords](https://support.apple.com/guide/passwords/the-passwords-app-mchl901b1b95/mac)
- [Apple Keychain Access](https://support.apple.com/guide/keychain-access/welcome/mac)
