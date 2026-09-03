# Run Domotic from a private repository

Create a private Git repository for your home. Keep its hostnames, device
settings, and encrypted credentials there; keep this public repository free of
personal data. This also gives you a straightforward place to back up and
review every configuration change.

Do not use a GitHub fork for the private configuration. A fork of a public
repository is public too. The setup below creates a small independent
repository and downloads the Domotic code automatically when you run a task.

Domotic can deploy to any Kubernetes distribution that meets the
[cluster requirements](README.md#supported-kubernetes-environments). The k3s
guide is a documented reference setup for home servers, not a platform
requirement.

## 1. Create the private repository

Choose a directory for the private repository and run:

```sh
mkdir home-deployment
cd home-deployment

task --taskfile \
  'https://github.com/fiam/domotic.git//Taskfile.remote.yml?ref=main' \
  init
```

Task asks you to approve the downloaded Taskfile the first time. Check that the
URL points to `github.com/fiam/domotic`, then accept it. Replace `main` with a
tag, Git ref, or full commit when needed. The entrypoint resolves that value and
records the exact commit in the generated `Taskfile.yml`, so a future upstream
change cannot silently alter your installation.

The generated layout is:

```text
home-deployment/
├── Taskfile.yml
├── README.md
├── config/
│   ├── values.yaml
│   ├── secrets.yaml.example
│   ├── secrets.sops.yaml       # created by the operator and committed
│   ├── backup.env.example
│   └── infra/
│       └── terraform.tfvars
└── .domotic/                   # ignored materialized public source
```

You will normally use these commands from the private repository:

| Task | Purpose |
| --- | --- |
| `check`, `plan`, `deploy`, `status` | Validate and operate the normal deployment. |
| `domotic:update` | Update the pinned Domotic source without deploying it. |
| `homeassistant:update`, `homeassistant:deploy` | Update or redeploy Home Assistant without running Terraform. |
| `restore:plan`, `restore` | Prepare a blank Home Assistant instance for a native backup import. |
| `backup`, `backup:list`, `backup:restore` | Manage encrypted configuration-recovery archives. |
| `k3s:context` | Import a server installed with the optional k3s guide. |
| `secrets:edit`, `secrets:check` | Edit or verify the encrypted secrets file. |
| `keys:capture` | Refresh the portable Zigbee identity after a successful apply. |

Run `task --list` to see every command. Do not edit `.domotic/`; it is an
ignored working directory managed by Task.

Edit the two tracked configuration files. They may contain private hostnames,
device paths, selected integrations, and other non-secret desired state. Do
not add the Cloudflare token, Home Assistant password, Zigbee keys, generated
Helm values, backup credentials, or restored archives to those files.

## 2. Encrypt credentials with SOPS

A new Home Assistant installation needs these two values:

```yaml
CLOUDFLARE_API_TOKEN: your-account-api-token
HOMEASSISTANT_ADMIN_PASSWORD: your-initial-owner-password
```

You may also choose the password used to encrypt native Home Assistant backups:

```yaml
HOMEASSISTANT_BACKUP_PASSWORD: your-native-backup-password
```

This third value is optional. When it is absent, a new automatic backup setup
stores unencrypted backups in the private R2 bucket. Supplying it enables
Home Assistant's native backup encryption. Download the emergency kit after
enabling encryption and keep a copy outside the cluster.

Domotic uses SOPS for credentials but does not manage the key. Set up SOPS in
the way you prefer: a local age or PGP key, a cloud KMS, or another backend
supported by SOPS. If you use age, its default key file and the
`SOPS_AGE_KEY_FILE`, `SOPS_AGE_KEY`, and `SOPS_AGE_KEY_CMD` settings all work.

Configure a SOPS creation rule matching `config/secrets.sops.yaml`, or pass the
recipient option for your chosen backend to `sops encrypt`. Then create and
immediately remove the ignored plaintext input:

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

If encryption reports that no creation key is configured, finish your SOPS
setup and try again. Use `task secrets:edit` for later changes. Deployment tasks
decrypt the file only while Terraform is running and do not create a plaintext
copy.

Keep a recoverable copy of the SOPS key outside this repository. Anyone with
administrator access to the Kubernetes cluster can also reach secrets derived
from these credentials, so protect cluster access and recovery backups too.

Run the repository boundary checks before committing configuration:

```sh
task config:check
task check
```

These checks catch common mistakes such as committing plaintext credentials,
generated secret files, or private files with unsafe permissions.

Commit the configured scaffold to a new, independent private repository:

```sh
git add .
git commit -m "chore: configure home deployment"
git remote add origin <private-repository-url>
git push -u origin main
```

## 3. Plan and deploy

Domotic uses the current kubeconfig context. `kubectl`, Helm, and the deployment
tasks honor `KUBECONFIG`, including a platform-separated list of files. Check
the target before planning or deploying:

```sh
kubectl config current-context
```

Validate code, configuration, and credentials before the first plan:

```sh
task secrets:check
task check
task plan
```

For a new installation, keep `homeassistant_bootstrap_mode = "seed"` and
deploy:

```sh
task deploy
task status
```

To recover a native Home Assistant backup, prepare the blank installation
without changing that setting or requiring the initial owner password:

```sh
task restore:plan
task restore
```

The restore tasks still need `CLOUDFLARE_API_TOKEN`, but they do not require or
inject `HOMEASSISTANT_ADMIN_PASSWORD`. Open Home Assistant, upload and restore
the native backup, and then put the credentials of an owner from that backup
into the encrypted file before the next `task deploy`. The deployment finds
the restored owner and uses that account to finish configuring the installation.

## 4. Back up the installation

Create the ignored backup client file and use the independently stored age
identity described in [BACKUP.md](BACKUP.md):

```sh
cp config/backup.env.example config/backup.env
chmod 0600 config/backup.env
task backup
task backup:list
```

`task backup` uploads an encrypted recovery archive containing the deployment
configuration, Zigbee identity, live Kubernetes secrets, and Terraform state.
The private Git repository already preserves the SOPS-encrypted credential
document. Home Assistant's native R2 backup separately preserves its database
and application state.

The SOPS master key and the age identity configured in `backup.env` have
different roles. They may be the same key in a small single-user setup, but
that key still needs a recoverable copy outside the private repository and the
R2 bucket it protects.

## 5. Maintain and upgrade

For a configuration change:

```text
edit configuration → task check → task plan → task backup
→ review the plan → task deploy → task status → commit
```

For an upstream upgrade:

1. Run and verify both configuration and Home Assistant native backups.
2. Review the target commit and `HOME_ASSISTANT_COMPATIBILITY.md`.
3. Run `task domotic:update REF=main`. This updates `Taskfile.yml` and the local
   source cache without changing the cluster. A tag, full Git ref, or commit
   can be used instead of `main`.
4. Review the pin and run `task check`.
5. Run `task homeassistant:update` to select the Home Assistant version verified
   by that Domotic revision and perform a Helm-only deployment.
6. Run `task status` and commit the new pins only after Home Assistant, MQTT,
   Zigbee, routes, and R2 backups are healthy.

`task homeassistant:deploy` performs the same Helm-only reconciliation without
changing the image pin. Neither Home Assistant task runs Terraform. Helm owns a
single Domotic release, so pending changes in `config/values.yaml` are applied
alongside the image update.

Reverting `DOMOTIC_REF` rolls back code and charts. It does not reverse a Home
Assistant database migration; use a native backup when application data must
also be restored.

Task keeps the selected Domotic source in `.domotic/source`. You can delete that
directory if its cache becomes damaged; the next task downloads the pinned
version again. An upgrade needs network access to download the new version.

Official references:

- [Task remote Taskfiles](https://taskfile.dev/docs/remote-taskfiles)
- [GitHub fork visibility](https://docs.github.com/en/pull-requests/reference/forks)
- [Terraform sensitive inputs](https://developer.hashicorp.com/terraform/tutorials/configuration-language/sensitive-variables)
- [SOPS](https://getsops.io/docs/)
