# Repository instructions for coding agents

Before changing Home Assistant versions, bootstrap behavior, configuration,
authentication, proxy settings, integrations, or backups, read and follow
[HOME_ASSISTANT_COMPATIBILITY.md](HOME_ASSISTANT_COMPATIBILITY.md).

Before changing how custom integrations are fetched, verified, mounted, or
configured, also read and follow
[CUSTOM_INTEGRATIONS.md](CUSTOM_INTEGRATIONS.md).

Before changing the Kind topology, Colima configuration, development routes,
or destroying a local development cluster, read and follow
[DEVELOPMENT_NETWORKING.md](DEVELOPMENT_NETWORKING.md). The Kind cluster holds
its own Terraform backend; deleting it without first destroying the external
test infrastructure or preserving that state can orphan Cloudflare resources.

Before changing external configuration paths, the SOPS credential boundary,
recovery commands, or the remote Taskfile, read and follow
[PRIVATE_DEPLOYMENT.md](PRIVATE_DEPLOYMENT.md). Keep the remote Taskfile
self-contained: Task downloads it without exposing the source repository.

Treat every Home Assistant version change as a compatibility migration. This
repository intentionally uses private Home Assistant HTTP and WebSocket
interfaces for onboarding, integration config flows, HTTP configuration, and
backups. It does not write private `.storage` files directly, but the APIs and
their payloads remain version-coupled. Do not describe those interfaces as
public or stable. Do not merge a Home Assistant version bump until the linked
source audit and fresh Kind-cluster tests are complete and the compatibility
record has been updated.

Never print secret values while testing. Inspect only key names, schema
versions, integration states, and redacted data.
