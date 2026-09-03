# Home deployment

This private repository contains the configuration for one Domotic
installation. The public source is downloaded at the commit recorded in
`Taskfile.yml`.

Start by editing:

- `config/bootstrap.tfvars`: Cloudflare account and a unique R2 bucket prefix;
- `config/infra/terraform.tfvars`: domain, routes, namespace, and Zigbee radio;
- `config/values.yaml`: storage, Zigbee adapter, and workload settings.

Create the persistent R2 foundation:

```sh
task bootstrap
```

The task prompts for the Cloudflare account token and a recovery passphrase.
The state file is encrypted; keep the passphrase in a password manager outside
this repository.

Deployment commands use the current kubeconfig context:

```sh
git add .
kubectl config current-context
task check
task plan

git commit -m "chore: configure home deployment"
git remote add origin <private-repository-url>
git push -u origin main

task deploy
task status
task credentials:show
```

Home Assistant writes daily native backups to the dedicated R2 backup bucket.
The next native backup also includes the latest Zigbee2MQTT data snapshot
staged by the chart.

For a native restore, run `task restore:plan` and `task restore`, upload the
backup in Home Assistant, then run `task restore:complete`. Use
`task credentials:update` after changing the owner password in Home Assistant.

Use `task domotic:update REF=main` to update the public source pin and
`task homeassistant:update` to deploy the Home Assistant version verified by
that revision.

See the public repository's `PRIVATE_DEPLOYMENT.md` and `BACKUP.md` for token
permissions, recovery, and credential rotation.
