# Home Assistant compatibility contract

This deployment deliberately automates parts of Home Assistant that do not
have stable public provisioning interfaces. A successful Helm render is not
proof that these integrations work. Every Home Assistant upgrade must be
treated as a compatibility migration and tested on a new disposable volume.

## Verified baseline

Last verified: **2026-08-24**

| Contract | Verified value |
| --- | --- |
| Home Assistant Core image | `2026.8.3` |
| Resulting HTTP storage | `.storage/http`, store `2.2` |
| Resulting core configuration storage | `.storage/core.config`, store `1.4` |
| Resulting config-entry storage | `.storage/core.config_entries`, store `1.5` |
| MQTT config flow result | entry `2.1`, protocol `5`, transport `tcp` |
| Cloudflare R2 config flow result | entry `1.1` |
| Resulting backup storage | `.storage/backup`, store `1.7` |
| Seeded automatic backup | daily, R2 only, seven copies, protected |
| Core settings command | `config/core/update` |
| Reconciled core settings | location name, external URL, internal URL |
| Config-entry lookup command | `config_entries/get` |
| Integration flow endpoint | `/api/config/config_entries/flow` |
| HTTP settings commands | `http/config`, `http/config/configure`, `http/config/promote` |
| Onboarding steps | `user`, `core_config`, `analytics`, `integration` |

The version pin lives in the root and Home Assistant `Chart.yaml` files and in
the Home Assistant default values. `examples/values-production.yaml` also pins
the image explicitly. Keep all four locations aligned.

## Private and version-coupled behavior

The following behavior is not a supported declarative provisioning API. It may
change in any Home Assistant release, including a patch release.

| Implementation | Private assumption | Failure mode |
| --- | --- | --- |
| `templates/onboarding-job.yaml` | `/api/onboarding` and its step endpoints retain their paths, payloads, order, authentication requirements, and response shapes | The owner may not be created or onboarding may remain partially complete. |
| `templates/onboarding-job.yaml` | `/auth/login_flow` accepts the `homeassistant` handler and returns an authorization code in the current flow result shape | Retry of partially completed onboarding can fail. |
| `templates/onboarding-job.yaml` | The private `config/core/update` WebSocket command retains its schema and persists `location_name`, `external_url`, and `internal_url` without making them YAML-managed | The declared name and URLs may not be applied, the hook may fail, or the settings may become incompatible with the UI. |
| `templates/onboarding-job.yaml` | The private `config_entries/get` command and config-flow HTTP views retain their paths, result shapes, admin authorization, and duplicate semantics | Existing integrations may not be detected, or a missing integration may not be created. |
| `templates/onboarding-job.yaml` | The MQTT broker step accepts protocol `5` and the nested TCP/no-certificate `other_settings` payload | MQTT setup can stop at a form error or use different connection defaults. |
| `templates/onboarding-job.yaml` | The Cloudflare R2 user step accepts the current credential, bucket, endpoint, and prefix fields and validates them with `HeadBucket` | R2 setup can fail validation or store incompatible data. |
| `templates/onboarding-job.yaml` | `http/config/configure` stages a complete configuration, restarts Home Assistant, and `http/config/promote` confirms the active pending slot before automatic rollback | The hook can lose connectivity, leave an unpromoted trial, or restore defaults after the trial window. |
| `templates/onboarding-job.yaml` | The private `backup/config/info`, `backup/agents/info`, and `backup/config/update` WebSocket commands retain their schemas and admin authorization behavior | The automatic R2 schedule may be absent, target the wrong agent, lose encryption, or apply incorrect retention. |
| `templates/onboarding-job.yaml` | The R2 backup agent ID starts with `cloudflare_r2.` and its display name equals the config-entry title/bucket | The hook cannot identify the intended R2 destination. |
| `templates/onboarding-job.yaml` | The Home Assistant image contains compatible `python3` and `aiohttp` runtimes | The Helm hook cannot run. |
| `templates/deployment.yaml` | The `.seed` adoption rules distinguish unchanged chart-managed YAML from user-modified files | A chart update could overwrite YAML edits or fail to restore a missing managed file. |
| Restore mode | Starting with only `default_config:` exposes Home Assistant's native onboarding backup upload flow and a restored `/config` takes over | A new release may require different bootstrap configuration or restore steps. |

The chart does not write private `.storage` files. In seed mode, the
authenticated hook creates MQTT only when no MQTT entry exists, creates R2 only
when no entry matches the declared bucket title, and reconciles HTTP settings
through Home Assistant's trial-and-promotion workflow. It never updates
existing integration credentials. Restore mode must never run the hook or any
config flow. Terraform seed mode requires admin credentials so these
chart-derived settings are never silently skipped. Restore mode remains the
credential-free path for manual onboarding or native backup recovery.

The token exchange and revocation endpoints are documented, but the automated
login-flow and onboarding calls around them remain implementation-coupled. Do
not broaden the claim of stability merely because they are HTTP endpoints.

## Sources to inspect for every upgrade

Replace `2026.8.3` in these links with the proposed exact tag and compare the
code, constants, schemas, migrations, and tests—not just release notes.

- [Onboarding views and payloads](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/components/onboarding/views.py)
- [Login-flow HTTP views](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/components/auth/login_flow.py)
- [Documented token and revocation API](https://developers.home-assistant.io/docs/auth_api/)
- [Core-settings WebSocket command](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/components/config/core.py)
- [Config-entry flow HTTP views and lookup command](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/components/config/config_entries.py)
- [HTTP user-configuration WebSocket commands](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/components/http/websocket_api.py)
- [HTTP storage schema](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/components/http/config.py)
- [Config-entry storage and migrations](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/config_entries.py)
- [MQTT config flow and entry version](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/components/mqtt/config_flow.py)
- [MQTT config-flow tests and broker payload](https://github.com/home-assistant/core/blob/2026.8.3/tests/components/mqtt/test_config_flow.py)
- [MQTT constants](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/components/mqtt/const.py)
- [Cloudflare R2 config flow](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/components/cloudflare_r2/config_flow.py)
- [Backup WebSocket command schemas](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/components/backup/websocket.py)
- [Automatic schedule and retention model](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/components/backup/config.py)
- [Backup agent ID contract](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/components/backup/agent.py)
- [Cloudflare R2 backup agent](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/components/cloudflare_r2/backup.py)
- [Native backup documentation](https://www.home-assistant.io/integrations/backup/)

Also inspect the integration tests beside those source files. They often show
required payloads and migration behavior more precisely than user-facing docs.

## Mandatory upgrade procedure

1. Select an exact patch release. Never deploy the moving `stable` tag.
2. Audit every source above at that exact tag. Update the version table, API
   payloads, onboarding client, and tests before changing the image pin.
3. Run `task check`.
4. Create a fresh Kind cluster, fresh Terraform state namespace, fresh R2
   bucket, and fresh Home Assistant PVC. Supply the required seed-mode
   `homeassistant_onboarding` credentials.
5. Deploy and verify that the onboarding hook completes without using a Job
   retry, the generated owner can log in, MQTT connects, Cloudflare R2 loads
   without setup errors, the HTTP pending configuration is promoted, and both
   local and tunnel HTTP routes respond.
6. Inspect the resulting storage without printing credentials:

   ```sh
   kubectl --context kind-ha -n kind-ha exec deploy/kind-ha-homeassistant -- \
     python3 -c 'import json; d=json.load(open("/config/.storage/core.config_entries")); print("store", d["version"], d["minor_version"]); [print(e["domain"], e["version"], e["minor_version"], sorted(e["data"])) for e in d["data"]["entries"] if e["domain"] in ("mqtt", "cloudflare_r2")]'

   kubectl --context kind-ha -n kind-ha exec deploy/kind-ha-homeassistant -- \
     python3 -c 'import json; d=json.load(open("/config/.storage/http")); print(d["version"], d["minor_version"], sorted(d["data"]), sorted(d["data"]["stable"]))'

   kubectl --context kind-ha -n kind-ha exec deploy/kind-ha-homeassistant -- \
     python3 -c 'import json; d=json.load(open("/config/.storage/core.config")); print(d["version"], d["minor_version"], sorted(d["data"]))'
   ```

   Confirm that `configuration.yaml` has no `homeassistant:` block and that the
   UI allows editing Home information and both Home Assistant URLs.

7. Restart the Home Assistant Deployment and repeat the login, integration,
   route, and log checks. This catches schemas accepted only during migration.
8. When automatic R2 backups are enabled, verify in the backup UI or through a
   redacting WebSocket client that only the expected R2 agent is selected, the
   recurrence is daily, retention matches the Terraform input, protection has
   a non-empty password, and `next_automatic_backup` is populated. Never print
   the password. Re-run the hook and confirm it preserves the stored settings.
9. Test `homeassistant_bootstrap_mode = "restore"` separately with a disposable
   native backup. Confirm that neither integration config flows nor owner
   seeding runs and that the restored configuration survives another restart.
10. Create and restore a test backup through the Cloudflare R2 integration.
11. Update the verified date, versions, source links, and any changed failure
    assumptions in this document. Record what was actually exercised.

Do not test an upgrade first against the production PVC. Preserve a native
Home Assistant backup, the encrypted repository backup, and the Zigbee network
identity before changing production.

## Baseline observations

The 2026.8.3 baseline was exercised with a fresh Kind cluster and PVC,
automated owner creation, a real login and token revocation, MQTT and Cloudflare
R2 both reporting `loaded`, the storage checks above, a Home Assistant rollout
restart, and local and tunnel route checks.

MQTT and Cloudflare R2 creation was re-exercised on a blank Home Assistant PVC
through their native config flows. The resulting entries had fresh generated
IDs/timestamps, and MQTT included the flow-applied `transport` field. An
in-place upgrade over the older direct-storage baseline detected and preserved
both existing entries. No private storage seed is rendered by the chart.

HTTP API reconciliation was exercised with zero Job retries: one run staged,
restarted into, and promoted a changed trusted-proxy set; a second run repeated
the process to restore the declared set. The client tolerates the WebSocket
closure during restart and accepts both a promoted pending slot and a direct
return to an already-matching stable slot.

Core-setting reconciliation was exercised on a fresh Kind PVC with no
`homeassistant:` block in `configuration.yaml`. The post-install hook created
`.storage/core.config` with the declared location name, external URL, and
internal URL. A subsequent Helm upgrade changed the location name through
`config/core/update`, and another upgrade restored the declared value. All
three values and the UI-managed storage file survived a Home Assistant rollout
restart.

Automatic backup seeding was separately exercised on a fresh disposable Kind
PVC against the real test R2 bucket. The resulting backup store selected only
the discovered `cloudflare_r2.*` agent, used daily recurrence, null time
(Home Assistant's randomized default), seven-copy retention, and a non-empty
password matching the Terraform-managed Secret. A second hook run left the
complete backup configuration byte-for-byte unchanged. In the working Kind
environment, an actual native backup was also created with stored automatic
settings, and both its `.tar` and `.metadata.json` objects were confirmed under
the configured R2 prefix.

Cloudflare R2 currently emits blocking-call warnings while botocore loads its
service data and CA bundle. The integration still reaches `loaded`; no setup or
credential error was present. Recheck these warnings on upgrade rather than
hiding them or treating them as proof that setup failed.

Native-backup upload through R2 is verified. Download/decryption and a complete
native restore were not exercised in this baseline run and remain required
before approving a Home Assistant version change for production.
