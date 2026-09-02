# Home deployment

This is the private deployment repository for your home. Edit the files under
`config/` and run the Task commands here. The Domotic code is downloaded
automatically at the version recorded in `Taskfile.yml`.

Commands use the current kubeconfig context and honor `KUBECONFIG`. Check
`kubectl config current-context` before planning or deploying. The cluster must
meet the [Domotic requirements](https://github.com/fiam/domotic#supported-kubernetes-environments).
If the server was installed with the k3s guide, `task k3s:context` can import
its kubeconfig.

Configure SOPS with a master-key backend of your choice. Domotic does not
create, locate, or back up that key; `sops` uses its normal configuration,
environment variables, key files, agents, or KMS credentials.

Create the encrypted credential document without committing its temporary
plaintext input:

```sh
cp config/secrets.yaml.example config/secrets.yaml
chmod 0600 config/secrets.yaml
${EDITOR:-vi} config/secrets.yaml
sops encrypt --filename-override config/secrets.sops.yaml \
  < config/secrets.yaml > config/secrets.sops.yaml
rm config/secrets.yaml
git add config/secrets.sops.yaml
```

The encrypted document must contain `CLOUDFLARE_API_TOKEN` and
`HOMEASSISTANT_ADMIN_PASSWORD`. Keep `config/secrets.sops.yaml` under version
control and keep the SOPS master key elsewhere.

Start with:

```sh
task --list
kubectl config current-context
kubectl get nodes
task secrets:check
task check
task plan
```

Use `task secrets:edit` for later changes and `task deploy` to deploy. For a
native Home Assistant backup import, run `task restore:plan` followed by `task
restore`; those tasks do not require the Home Assistant admin password.

Use `task domotic:update REF=main` to update the pinned Domotic code without
deploying it. After reviewing that change and creating backups, `task
homeassistant:update` deploys the Home Assistant version verified by the new
pin without running Terraform. `task homeassistant:deploy` performs a Helm-only
deployment without changing either version.

Keep `config/infra/terraform.tfvars`, `config/values.yaml`, and the encrypted
SOPS document under version control. Never commit `config/secrets.yaml`,
`config/backup.env`, generated Terraform/Helm files, Zigbee keys, restored
archives, or plaintext credentials. See the public repository's
`PRIVATE_DEPLOYMENT.md` for credentials, backups, recovery, and upgrades.
