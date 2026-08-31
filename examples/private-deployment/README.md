# Home deployment

This private repository stores the non-secret desired state for one Domotic
installation. Its Taskfile pins a reviewed revision of the public
`fiam/domotic` repository and exposes that revision's deployment commands.

Start with:

```sh
task --list
task k3s:context SSH_USER=your-server-user SSH_HOST=your-server.local
task config:check
task secrets:set
task check
task plan
```

The two `*_REF` values in `Taskfile.yml` select credentials by URI scheme.
The generated `keychain://` references use macOS Keychain; replace them with
native `op://VAULT/ITEM/FIELD`, `env://VARIABLE`, or optional
`sops://PATH#KEY` references when appropriate.

Then deploy with `task deploy`. For a native Home Assistant backup import, run
`task restore:plan` followed by `task restore` instead.

Keep `config/infra/terraform.tfvars` and `config/values.yaml` under version
control. Never commit `config/backup.env`, generated Terraform/Helm files,
Zigbee keys, restored archives, or plaintext credentials. See the public
repository's `PRIVATE_DEPLOYMENT.md` for credential references, backups,
recovery, and upgrades.
