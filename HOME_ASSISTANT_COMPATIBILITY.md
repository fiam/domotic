# Home Assistant compatibility contract

This deployment deliberately automates parts of Home Assistant that do not
have stable public provisioning interfaces. A successful Helm render is not
proof that these integrations work. Every Home Assistant upgrade must be
treated as a compatibility migration and tested on a new disposable volume.

## Verified baseline

Last verified: **2026-09-03**

| Contract | Verified value |
| --- | --- |
| Home Assistant Core image | `2026.8.3` |
| Resulting HTTP storage | `.storage/http`, store `2.2` |
| Resulting core configuration storage | `.storage/core.config`, store `1.4` |
| Resulting config-entry storage | `.storage/core.config_entries`, store `1.5` |
| MQTT config flow result | entry `2.1`, protocol `5`, transport `tcp` |
| Cloudflare R2 config flow result | entry `1.1` |
| Resulting backup storage | `.storage/backup`, store `1.7` |
| Seeded automatic backup | daily, R2 only, seven copies; protection follows the optional password |
| Core settings command | `config/core/update` |
| Reconciled core settings | location name, external URL, internal URL |
| Config-entry lookup command | `config_entries/get` |
| Integration flow endpoint | `/api/config/config_entries/flow` |
| HTTP settings commands | `http/config`, `http/config/configure`, `http/config/promote` |
| Onboarding steps | `user`, `core_config`, `analytics`, `integration` |
| Custom integration delivery | no integration enabled by default; local and checksum-pinned remote render contracts verified |
| Zigbee2MQTT snapshot staging | hourly CronJob; validated latest ZIP under `/config/.domotic/zigbee2mqtt` |

The version pin lives in the root and Home Assistant `Chart.yaml` files and in
the Home Assistant default values. `examples/values-production.yaml` also pins
the image explicitly, and the README badge identifies the audited version.
Keep all five locations aligned.

Private deployments may retain an older image in `config/values.yaml` while
updating their Domotic source pin. `task homeassistant:update` copies the
verified Home Assistant `appVersion` from that source into the private values
file before running Helm. It deliberately does not accept an arbitrary image
tag; a different version first requires this compatibility audit and a new
Domotic revision.

## Private and version-coupled behavior

The following behavior is not a supported declarative provisioning API. It may
change in any Home Assistant release, including a patch release.

| Implementation | Private assumption | Failure mode |
| --- | --- | --- |
| `templates/onboarding-job.yaml` | `/api/onboarding` and its step endpoints retain their paths, payloads, order, authentication requirements, and response shapes | The owner may not be created or onboarding may remain partially complete. |
| `templates/onboarding-job.yaml` | `/auth/login_flow` accepts the `homeassistant` handler and returns an authorization code in the current flow result shape | Retry of partially completed onboarding can fail. |
| `templates/onboarding-job.yaml` | `config/core/update` retains its schema and persists name and URLs without making them YAML-managed | Declared settings may not be applied or may become read-only in the UI. |
| `templates/onboarding-job.yaml` | `config_entries/get` and config-flow HTTP views retain their paths, result shapes, authorization, and duplicate semantics | Existing integrations may not be detected, or a missing integration may not be created. |
| `templates/onboarding-job.yaml` | The MQTT broker step accepts protocol `5` and the nested TCP/no-certificate `other_settings` payload | MQTT setup can stop at a form error or use different connection defaults. |
| `templates/onboarding-job.yaml` | The Cloudflare R2 user step accepts the current credential, bucket, endpoint, and prefix fields and validates them with `HeadBucket` | R2 setup can fail validation or store incompatible data. |
| `templates/onboarding-job.yaml` | `http/config/configure` stages a complete configuration, restarts Home Assistant, and `http/config/promote` confirms the active pending slot before automatic rollback | The hook can lose connectivity, leave an unpromoted trial, or restore defaults after the trial window. |
| `templates/onboarding-job.yaml` | `backup/config/info`, `backup/agents/info`, and `backup/config/update` retain their schemas and authorization behavior | The automatic R2 schedule may be absent, target the wrong agent, or use incorrect protection or retention. |
| `templates/onboarding-job.yaml` | The R2 backup agent ID starts with `cloudflare_r2.` and its display name equals the config-entry title/bucket | The hook cannot identify the intended R2 destination. |
| `templates/onboarding-job.yaml` | The Home Assistant image contains compatible `python3` and `aiohttp` runtimes | The Helm hook cannot run. |
| `templates/deployment.yaml` | The `.seed` adoption rules distinguish unchanged chart-managed YAML from user-modified files | An update could overwrite YAML edits or fail to restore a missing managed file. |
| Restore mode | Starting with only `default_config:` exposes Home Assistant's native onboarding backup upload flow and a restored `/config` takes over | A release may require different bootstrap configuration or restore steps. |
| Custom integration mounts | A user-selected integration remains compatible with the pinned Home Assistant image and can run from a read-only directory | Home Assistant can reject or fail to load the integration even though artifact verification and mounting succeeded. |
| `templates/zigbee2mqtt-backup-cronjob.yaml` | Home Assistant continues archiving non-excluded files beneath `/config`, including the staged Zigbee2MQTT ZIP | A native backup may omit the Zigbee2MQTT recovery snapshot even though the CronJob succeeds. |

The chart does not write private `.storage` files. In seed mode, the
authenticated hook creates MQTT only when no MQTT entry exists, creates R2 only
when no entry matches the declared bucket title, and reconciles HTTP settings
through Home Assistant's trial-and-promotion workflow. It never updates
existing integration credentials. Restore mode must never run the hook or any
config flow. OpenTofu seed mode supplies admin credentials so chart-derived
settings are never silently skipped. Restore mode remains the credential-free
path for manual onboarding or native backup recovery.

The token exchange and revocation endpoints are documented, but the automated
login-flow and onboarding calls around them remain implementation-coupled. Do
not broaden the claim of stability merely because they are HTTP endpoints.

Custom integrations are selected entirely by the deployment owner. The chart
verifies artifact identity and isolation, not source trust or Home Assistant
compatibility. Follow [CUSTOM_INTEGRATIONS.md](CUSTOM_INTEGRATIONS.md) whenever
changing their delivery contract.

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
- [MQTT config flow](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/components/mqtt/config_flow.py)
- [MQTT config-flow tests](https://github.com/home-assistant/core/blob/2026.8.3/tests/components/mqtt/test_config_flow.py)
- [MQTT constants](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/components/mqtt/const.py)
- [Cloudflare R2 config flow](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/components/cloudflare_r2/config_flow.py)
- [Backup WebSocket command schemas](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/components/backup/websocket.py)
- [Automatic schedule and retention model](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/components/backup/config.py)
- [Backup agent ID contract](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/components/backup/agent.py)
- [Cloudflare R2 backup agent](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/components/cloudflare_r2/backup.py)
- [Native backup documentation](https://www.home-assistant.io/integrations/backup/)
- [Core backup archive construction and exclusions](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/components/backup/manager.py)
- [Zigbee2MQTT backup request](https://www.zigbee2mqtt.io/guide/usage/mqtt_topics_and_messages.html#zigbee2mqttbridgerequestbackup)

Inspect the tests beside these source files as well. They often document
required payloads and migration behavior more precisely than user-facing docs.

## Mandatory upgrade procedure

1. Select an exact patch release. Never deploy the moving `stable` tag.
2. Audit every source above at that tag. Update the version table, API
   payloads, onboarding client, and tests before changing the image pin.
3. Audit every user-configured custom integration against the proposed image.
   Upgrade or remove incompatible integrations before testing the stack.
4. Run `task check`.
5. Create a fresh Kind cluster and Home Assistant PVC. Bootstrap isolated R2
   state and backup buckets, then supply the required seed-mode credentials
   through encrypted OpenTofu state.
6. Deploy and verify onboarding, login, MQTT, Cloudflare R2, HTTP promotion,
   local routing, tunnel routing, and every configured custom integration.
7. Inspect storage without printing credentials:

   ```sh
   kubectl --context kind-ha -n kind-ha exec deploy/kind-ha-homeassistant -- \
     python3 -c 'import json; d=json.load(open("/config/.storage/core.config_entries")); print("store", d["version"], d["minor_version"]); [print(e["domain"], e["version"], e["minor_version"], sorted(e["data"])) for e in d["data"]["entries"] if e["domain"] in ("mqtt", "cloudflare_r2")]'

   kubectl --context kind-ha -n kind-ha exec deploy/kind-ha-homeassistant -- \
     python3 -c 'import json; d=json.load(open("/config/.storage/http")); print(d["version"], d["minor_version"], sorted(d["data"]), sorted(d["data"]["stable"]))'

   kubectl --context kind-ha -n kind-ha exec deploy/kind-ha-homeassistant -- \
     python3 -c 'import json; d=json.load(open("/config/.storage/core.config")); print(d["version"], d["minor_version"], sorted(d["data"]))'
   ```

   Confirm that `configuration.yaml` has no `homeassistant:` block and that the
   UI permits editing Home information and both URLs.
8. Restart the Home Assistant Deployment and repeat login, integration, route,
   and log checks. This catches schemas accepted only during migration and
   verifies that remote custom-integration installation is repeatable.
9. When automatic R2 backups are enabled, verify only the expected R2 agent is
   selected, recurrence and retention match the inputs, protection matches
   whether a password was supplied, and `next_automatic_backup` is populated.
   Re-run the hook and confirm it preserves stored settings.
10. Test restore mode separately with a disposable native backup. Confirm that
    neither integration config flows nor owner seeding runs and that restored
    configuration survives another restart.
11. Create and restore a test backup through the Cloudflare R2 integration.
12. Confirm the Zigbee2MQTT snapshot CronJob shares Home Assistant's node,
    produces a valid archive without replacing the last good file on failure,
    and that a native backup and restore preserve the staged ZIP. Exercise the
    separate empty-volume Zigbee2MQTT recovery procedure before relying on it.
13. Update the README badge and the verified date, versions, source links, and
    observations in this document. Record only what was actually exercised.

Do not test an upgrade first against the production PVC. Preserve a native
Home Assistant backup, encrypted OpenTofu state, and the Zigbee network
identity before changing production.

## Baseline observations

The `2026.8.3` baseline was exercised with a fresh Kind cluster and PVC,
automated owner creation, real login and token revocation, MQTT and Cloudflare
R2 reporting `loaded`, storage checks, a rollout restart, and local and tunnel
route checks.

MQTT and Cloudflare R2 creation were re-exercised on a blank PVC through their
native config flows. The resulting entries had fresh generated IDs and MQTT
included the flow-applied `transport` field. An in-place upgrade over the older
direct-storage baseline detected and preserved both entries. No private
storage seed is rendered by the chart.

HTTP reconciliation was exercised with zero Job retries: one run staged,
restarted into, and promoted a changed trusted-proxy set; a second restored the
declared set. Core settings were exercised without a `homeassistant:` YAML
block and survived rollout restart while remaining UI-editable.

Automatic backup seeding was exercised against the real test R2 bucket. It
selected only the intended R2 agent, used daily recurrence, Home Assistant's
randomized time, seven-copy retention, and a non-empty protection password. A
second hook run preserved the complete backup configuration. Native backup
objects were confirmed in the configured R2 prefix without exposing secrets.

Cloudflare R2 currently emits blocking-call warnings while botocore loads its
service data and CA bundle. The integration still reaches `loaded`; recheck
these warnings on upgrade instead of hiding them or treating them as proof of
failure.

Native-backup upload through R2 is verified. Download/decryption and a complete
native restore were not exercised in this baseline and remain required before
approving a Home Assistant version change for production.

The Zigbee2MQTT snapshot CronJob was exercised against the live Kind test
broker. Required pod affinity placed it on Home Assistant's node, and the
documented MQTT request produced a valid staged ZIP. A forced MQTT failure
preserved the last valid archive and removed its temporary files. Inclusion in
a native R2 backup and restoration into a new Zigbee2MQTT volume have not yet
been exercised.

The chart renders with no custom integrations by default. The generic remote
delivery contract was rendered with an underscored Home Assistant domain,
checksum verification, archive traversal rejection, and distinct
Kubernetes-safe resource names. Runtime compatibility remains an obligation
of whichever integrations a deployment chooses.
