#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "$script_dir/../.." && pwd)"
temp_root="$(mktemp -d "${TMPDIR:-/tmp}/kube4ha-rename-test.XXXXXX")"
trap 'rm -rf -- "$temp_root"' EXIT
trap 'exit 130' HUP INT TERM

fail() { printf 'Rename test failed: %s\n' "$*" >&2; exit 1; }

# Both shell and Task entrypoints continue accepting legacy configuration.
env DOMOTIC_CONFIG_DIR=legacy KUBE4HA_CONFIG_DIR=current \
  bash -c 'source "$1"; test "$KUBE4HA_CONFIG_DIR" = current' \
  _ "$repository_root/scripts/legacy-environment.sh"
env -u KUBE4HA_CONFIG_DIR DOMOTIC_CONFIG_DIR=legacy \
  bash -c 'source "$1"; test "$KUBE4HA_CONFIG_DIR" = legacy' \
  _ "$repository_root/scripts/legacy-environment.sh"
mkdir -p "$temp_root/legacy-config/infra"
printf '{}\n' > "$temp_root/legacy-config/values.yaml"
printf '{}\n' > "$temp_root/legacy-config/infra/helm-values.yaml"
legacy_render="$(
  env -u KUBE4HA_CONFIG_DIR DOMOTIC_CONFIG_DIR="$temp_root/legacy-config" \
    task --dry --dir "$repository_root" helm:deploy 2>&1
)"
printf '%s\n' "$legacy_render" | grep -Fq "$temp_root/legacy-config/values.yaml" ||
  fail 'legacy Task configuration path was ignored'

# The new hosts manager adopts and removes only its old managed block.
hosts="$temp_root/hosts"
printf '%s\n' '127.0.0.1 localhost' '# BEGIN domotic-kind' \
  '127.0.0.2 old-ha.invalid old-z2m.invalid' '# END domotic-kind' \
  '127.0.0.3 unrelated.invalid' > "$hosts"
HOSTS_FILE="$hosts" bash "$repository_root/scripts/dev-hosts.sh" install \
  127.0.0.1 new-ha.invalid new-z2m.invalid >/dev/null
! grep -q domotic-kind "$hosts" || fail 'legacy hosts block was retained'
grep -q '# BEGIN kube4ha-kind' "$hosts" || fail 'new hosts block is missing'
grep -q unrelated.invalid "$hosts" || fail 'unmanaged hosts line was removed'
HOSTS_FILE="$hosts" bash "$repository_root/scripts/dev-hosts.sh" remove >/dev/null
! grep -q new-ha.invalid "$hosts" || fail 'new hosts block was not removed'

# Bootstrap re-apply and passphrase rotation must keep the stored state key.
install -d -m 0700 "$temp_root/bin" "$temp_root/private/config" \
  "$temp_root/private/state" "$temp_root/private/.domotic"
printf '%s\n' 'r2_bucket_prefix = "fixture"' > "$temp_root/private/config/bootstrap.tfvars"
printf '%s\n' '{"encrypted_data":"fixture"}' > "$temp_root/private/state/bootstrap.tfstate"
cat > "$temp_root/bin/tofu" <<'EOF'
#!/usr/bin/env bash
for argument in "$@"; do
  if [[ "$argument" == output ]]; then
    printf '%s\n' '{"cloudflare_api_token":"fixture-token","cloudflare_account_id":"00000000000000000000000000000000","endpoint":"https://example.invalid","state":{"bucket":"fixture-state","key":"domotic.tfstate","access_key_id":"fixture-id","secret_access_key":"fixture-secret"},"backups":{"bucket":"fixture-backups","access_key_id":"fixture-id","secret_access_key":"fixture-secret"}}'
    exit 0
  fi
done
EOF
chmod 0700 "$temp_root/bin/tofu"
for mode in bootstrap runtime; do
  env -u KUBE4HA_RECOVERY_PASSPHRASE \
    PATH="$temp_root/bin:$PATH" \
    DOMOTIC_RECOVERY_PASSPHRASE=fixture-recovery-passphrase \
    "$repository_root/scripts/with-opentofu-environment.sh" \
    "$mode" "$repository_root" "$temp_root/private" "$temp_root/private/config" -- \
    bash -c 'test "$TF_VAR_state_object_key" = domotic.tfstate; case "$TF_DATA_DIR" in */.domotic/tofu/*) ;; *) exit 1 ;; esac'
done

# Execute the rendered reconciler against a synthetic pre-rename PVC layout.
python3 - "$repository_root" "$temp_root" <<'PY'
import pathlib, subprocess, sys, textwrap
root, temporary = map(pathlib.Path, sys.argv[1:])
rendered = subprocess.check_output([
    "helm", "template", "kube4ha", str(root / "charts/kube4ha"),
    "-f", str(root / "examples/values-minimal.yaml"),
    "--set", "homeassistant.hacs.enabled=false",
], text=True)
container = rendered.split("        - name: custom-components-reconcile\n", 1)[1]
script = textwrap.dedent(container.split("            - |\n", 1)[1].split("          volumeMounts:", 1)[0])
config = temporary / "config"
for directory in [".domotic/zigbee2mqtt", "custom_components/old_managed", "custom_components/unmanaged"]:
    (config / directory).mkdir(parents=True)
(config / ".domotic/managed-custom-components").write_text("old_managed\n")
(config / ".domotic/zigbee2mqtt/latest.zip").write_bytes(b"fixture-backup")
subprocess.run(["sh", "-c", script.replace("/config", str(config))], check=True)
assert not (config / "custom_components/old_managed").exists()
assert (config / "custom_components/unmanaged").is_dir()
assert (config / ".kube4ha/managed-custom-components").is_file()
assert (config / ".domotic/zigbee2mqtt/latest.zip").read_bytes() == b"fixture-backup"
PY

printf 'Project rename migration tests passed.\n'
