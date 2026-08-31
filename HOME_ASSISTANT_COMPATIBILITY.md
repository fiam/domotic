# Home Assistant compatibility contract

This deployment deliberately automates parts of Home Assistant that do not
have stable public provisioning interfaces. A successful Helm render is not
proof that these integrations work. Every Home Assistant upgrade must be
treated as a compatibility migration and tested on a new disposable volume.

## Verified baseline

Last verified: **2026-08-31**

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
| custom integration custom integration | version `0.8.0`; 33 sanitized contracts and hassfest pass against `2026.8.3`; live authentication, inventory, logical-channel registry migration, Área → Divisão as Floor → Area, state schema, actuator commands, emitter mappings, identification, 74 power entities, metering schema/reporting, and redacted unknown-message monitoring are verified |

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
| `custom-integration` submodule | Config-flow, SSDP service info, typed config-entry runtime data, coordinator, entity, diagnostics, and aiohttp APIs retain their imported interfaces | The custom integration can fail to load, discover, configure, update entities, or unload. |
| `custom-integration` submodule | third-party's private `/HsAPI`, cookie/challenge authentication, device-scenario records, MQTT-over-WebSocket endpoint, and protobuf schemas retain their observed contracts | Authentication, inventory, button assignments, commands, or push state can fail independently of Home Assistant compatibility. |

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
- [SSDP integration cache API](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/components/ssdp/__init__.py)
- [SSDP service-info model](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/helpers/service_info/ssdp.py)
- [Config entries and runtime data](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/config_entries.py)
- [Data update coordinator](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/helpers/update_coordinator.py)
- [aiohttp session helpers](https://github.com/home-assistant/core/blob/2026.8.3/homeassistant/helpers/aiohttp_client.py)

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

The custom integration component was imported and its sanitized authentication, inventory,
command, MQTT-over-WebSocket, binary/base64 protobuf, diagnostics, entity
filtering, and write-reconciliation contracts were exercised inside the exact
`2026.8.3` image. Helm renders were exercised for both repository-local
ConfigMap delivery and remote checksum-pinned init-container delivery. A real
Home Server was identified over SSDP and its unauthenticated description and
shipped browser client were audited without recording installation identifiers
or session material. Live administrator authentication, manual access through
the router-provided `custom integration.lan` name, inventory/entity enumeration, one simple
relay command, and the authenticated `DeviceStateEvent` field map/fingerprint
were verified on 2026-08-26. The live inventory established that rows without
`capLevel` or `capOnOff` and with `headerFilter=Switches` are emitter/input rows,
not descriptive duplicates. It contains 72 physical modules represented by 74
actuator-channel rows and 72 emitter rows. The official client groups physical
siblings by hardware address, while their A–D and IR actions are programmable
`DefaultBinds` scenarios. Home Assistant exposes the named emitter separately
and links it to the primary actuator device through `via_device`. Each logical
actuator channel is also a separate linked device because sibling channels can
have different names and divisions.
The live server also reports `switchedOn=false` for every lighting regulator,
including outputs with a positive `levelPercentage`; regulator on/off and
brightness state must therefore be derived from the level. Bidirectional relay,
dimmer, and blind behavior is accepted. The shipped client and authenticated
schemas established that four-key assignments are device-scoped scenarios,
`TeclaA` through `TeclaD` are endpoints 9 through 12, `Pressed` is state 0, and
`Released` is state 1 and only follows a long press. The sixteen IR keys are
endpoints 13 through 28. All 24 assignments from six live standalone
`QuadPressureButton` devices and the four Escadaria emitter assignments were
first inspected individually. The v0.6.1 Kind-cluster acceptance then resolved
all 288 A–D assignments from all 72 emitters, registered 72 disabled-by-default
IR receiver entities, and exposed all named emitters as linked Home Assistant
devices. The live registry contains 74 actuator devices and 72 emitter devices;
eight secondary actuator channels link to their primary physical sibling;
66 emitters carry a `via_device` actuator link and six standalone
`QuadPressureButton` emitters do not. The identification-LED REST command is
covered by the sanitized contract. Version 0.6.5 sends direct light/blind and
switch identification to exactly the selected logical row ID. Its complementary
receiver action reverses loaded hub scenarios for exactly the selected actuator
ID and sends one request to each associated emitter ID; it does not broaden
either side to physical siblings. The request duration is a native config-entry
option, defaults to 30 seconds, and is constrained to the Home Server's observed
1–30-second range. A physical live-button MQTT event is still pending
acceptance. A future protobuf mismatch deliberately uses MQTT only to trigger
authoritative REST refreshes.

Version 0.7.0 additionally verifies the authenticated
`DeviceInstantReadingEvent` contract and converts its `consumed_mW` field to a
native Home Assistant power measurement in watts. The live inventory advertises
74 metering-capable logical rows, and Home Assistant creates 74 available power
entities. Reporting uses concurrency-limited 10-second round-robin batches,
with rows sharing a hardware address placed in separate batches. Live
acceptance completed emitter mapping with no failures, kept the authoritative
coordinator healthy, decoded numeric readings for 66 rows during the observed
window, and left eight rows available but unknown pending a successful sample.
Two transient lease precondition failures were retained as aggregate diagnostics
and are retried automatically; they did not affect entity availability.

Version 0.7.1 splits logical actuator siblings into separate linked Home
Assistant devices. The live dual-channel migration confirmed that each
actuator and its power sensor use the same logical device, both observed
multi-output modules expose distinct device IDs, and every actuator device area
matches its Home Server division. This prevents a secondary channel from being
shown under the primary sibling's name and area. The migration runs before
platform setup because changing `device_info` alone does not move an existing
Home Assistant entity-registry row.

Version 0.8.0 maps the Home Server's Área → Divisão hierarchy to Home
Assistant Floor → Area through the pinned floor, area, and device registry
callbacks. The live inventory produced four floors and 18 named divisions;
only the two globally colliding division rows were parent-qualified. All 146
custom integration device rows matched their expected HA area with no missing area, floor,
or device-registry rows. All 148 light, cover, switch, and power entities were
available after rollout. Existing non-empty HA floor assignments and devices
moved to custom HA areas are preserved by sanitized migration contracts.

The off-by-default unknown-message observer was enabled through the native
options flow for a bounded live window, then disabled. It recorded only three
redacted families: `events/device/pen/state` with fields `1:2,2:0,3:0`, an
otherwise-redacted device-event shape with fields `1:2,2:0,3:0,4:2`, and one
non-protobuf top-level event shape. Known state and metering payloads had no
additive fields or decode failures. Option updates reconnect only the custom integration
MQTT listener and do not repeat inventory or emitter mapping.
