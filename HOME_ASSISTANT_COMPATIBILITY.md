# Home Assistant compatibility contract

This deployment deliberately automates parts of Home Assistant that do not
have stable public provisioning interfaces. A successful Helm render is not
proof that these integrations work. Every Home Assistant upgrade must be
treated as a compatibility migration and tested on a new disposable volume.

## Verified baseline

Last verified: **2026-08-23**

| Contract | Verified value |
| --- | --- |
| Home Assistant Core image | `2026.8.3` |
| HTTP storage file | `.storage/http`, store `2.2` |
| Config-entry storage file | `.storage/core.config_entries`, store `1.5` |
| MQTT config entry | entry `2.1`, protocol `5` |
| Cloudflare R2 config entry | entry `1.1` |
| Onboarding steps | `user`, `core_config`, `analytics`, `integration` |

The version pin lives in the root and Home Assistant `Chart.yaml` files and in
the Home Assistant default values. `examples/values-production.yaml` also pins
the image explicitly. Keep all four locations aligned.

## Private and version-coupled behavior

The following behavior is not a supported declarative provisioning API. It may
change in any Home Assistant release, including a patch release.

| Implementation | Private assumption | Failure mode |
| --- | --- | --- |
| `templates/configmap.yaml` | The JSON schemas, store versions, and field names of `.storage/http` and `.storage/core.config_entries` | Home Assistant can reject startup, ignore proxy settings, fail an integration, or migrate data unexpectedly. |
| `templates/configmap.yaml` | MQTT and Cloudflare R2 config entries can be created by writing storage instead of completing each integration's config flow | Validation and defaults normally applied by config flows are bypassed. |
| `templates/onboarding-job.yaml` | `/api/onboarding` and its step endpoints retain their paths, payloads, order, authentication requirements, and response shapes | The owner may not be created or onboarding may remain partially complete. |
| `templates/onboarding-job.yaml` | `/auth/login_flow` accepts the `homeassistant` handler and returns an authorization code in the current flow result shape | Retry of partially completed onboarding can fail. |
| `templates/onboarding-job.yaml` | The Home Assistant image contains a compatible `python3` standard library | The Helm hook cannot run. |
| `templates/deployment.yaml` | Missing files on `/config` reliably identify a fresh volume and Home Assistant has not started while storage is seeded | Existing configuration could be overwritten or two writers could corrupt storage. |
| Restore mode | Starting with only `default_config:` exposes Home Assistant's native onboarding backup upload flow and a restored `/config` takes over | A new release may require different bootstrap configuration or restore steps. |

The seed init container only writes private storage when the target file does
not exist. It must never overwrite `.storage` on a populated PVC. Restore mode
must never seed config entries or run the onboarding Job.

The token exchange and revocation endpoints are documented, but the automated
login-flow and onboarding calls around them remain implementation-coupled. Do
not broaden the claim of stability merely because they are HTTP endpoints.

## Sources to inspect for every upgrade

Replace `2026.8.3` in these links with the proposed exact tag and compare the
code, constants, schemas, migrations, and tests—not just release notes.

- [Onboarding views and payloads](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/components/onboarding/views.py)
- [Login-flow HTTP views](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/components/auth/login_flow.py)
- [Documented token and revocation API](https://developers.home-assistant.io/docs/auth_api/)
- [HTTP storage schema](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/components/http/config.py)
- [Config-entry storage and migrations](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/config_entries.py)
- [MQTT config flow and entry version](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/components/mqtt/config_flow.py)
- [MQTT constants](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/components/mqtt/const.py)
- [Cloudflare R2 config flow](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/components/cloudflare_r2/config_flow.py)
- [Native backup documentation](https://www.home-assistant.io/integrations/backup/)

Also inspect the integration tests beside those source files. They often show
required payloads and migration behavior more precisely than user-facing docs.

## Mandatory upgrade procedure

1. Select an exact patch release. Never deploy the moving `stable` tag.
2. Audit every source above at that exact tag. Update the version table, seeded
   JSON, onboarding client, and tests before changing the image pin.
3. Run `task check`.
4. Create a fresh Kind cluster, fresh Terraform state namespace, fresh R2
   bucket, and fresh Home Assistant PVC. Enable `homeassistant_onboarding`.
5. Deploy and verify that the onboarding hook completes, the generated owner
   can log in, MQTT connects, Cloudflare R2 loads without setup errors, and both
   local and tunnel HTTP routes respond.
6. Inspect the resulting storage without printing credentials:

   ```sh
   kubectl --context kind-ha -n kind-ha exec deploy/kind-ha-homeassistant -- \
     python3 -c 'import json; d=json.load(open("/config/.storage/core.config_entries")); print("store", d["version"], d["minor_version"]); [print(e["domain"], e["version"], e["minor_version"], sorted(e["data"])) for e in d["data"]["entries"] if e["domain"] in ("mqtt", "cloudflare_r2")]'

   kubectl --context kind-ha -n kind-ha exec deploy/kind-ha-homeassistant -- \
     python3 -c 'import json; d=json.load(open("/config/.storage/http")); print(d["version"], d["minor_version"], sorted(d["data"]), sorted(d["data"]["stable"]))'
   ```

7. Restart the Home Assistant Deployment and repeat the login, integration,
   route, and log checks. This catches schemas accepted only during migration.
8. Test `homeassistant_bootstrap_mode = "restore"` separately with a disposable
   native backup. Confirm that neither config-entry seeding nor owner seeding
   runs and that the restored configuration survives another restart.
9. Create and restore a test backup through the Cloudflare R2 integration.
10. Update the verified date, versions, source links, and any changed failure
    assumptions in this document. Record what was actually exercised.

Do not test an upgrade first against the production PVC. Preserve a native
Home Assistant backup, the encrypted repository backup, and the Zigbee network
identity before changing production.

## Baseline observations

The 2026.8.3 baseline was exercised with a fresh Kind cluster and PVC,
automated owner creation, a real login and token revocation, MQTT and Cloudflare
R2 both reporting `loaded`, the storage checks above, a Home Assistant rollout
restart, and local and tunnel route checks.

Cloudflare R2 currently emits blocking-call warnings while botocore loads its
service data and CA bundle. The integration still reaches `loaded`; no setup or
credential error was present. Recheck these warnings on upgrade rather than
hiding them or treating them as proof that setup failed.

Native-backup upload/restore and creation of an actual R2 backup object were
not exercised in this baseline run. They remain required before approving a
Home Assistant version change for production.
