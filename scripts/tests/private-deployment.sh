#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "$script_dir/../.." && pwd)"
temp_root="$(mktemp -d "${TMPDIR:-/tmp}/domotic-private-deployment-test.XXXXXX")"

# The test builds isolated deployment roots and must not inherit paths exported
# by the parent Taskfile.
unset BOOTSTRAP_VARS_FILE BOOTSTRAP_STATE_FILE TF_VARS_FILE \
  HELM_VALUES_FILE TERRAFORM_VALUES_FILE VALUES_FILE CONFIG_DIR

cleanup() {
  rm -rf -- "$temp_root"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

fail() {
  printf 'Test failed: %s\n' "$*" >&2
  exit 1
}

# Each passphrase-rollover stage must be a valid standalone encryption
# configuration. Metadata aliases are intentionally static because OpenTofu
# does not permit variables in encrypted_metadata_alias.
for template_file in "$repository_root"/scripts/encryption-rollover/*.tf; do
  template_name="$(basename "$template_file" .tf)"
  template_dir="$temp_root/rollover-$template_name"
  install -d -m 0700 "$template_dir"
  cp "$template_file" "$template_dir/backend.tf"
  env \
    TF_VAR_state_passphrase=domotic-new-test-passphrase \
    TF_VAR_previous_state_passphrase=domotic-old-test-passphrase \
    TF_DATA_DIR="$temp_root/data-rollover-$template_name" \
    tofu -chdir="$template_dir" init -backend=false -input=false >/dev/null
  env \
    TF_VAR_state_passphrase=domotic-new-test-passphrase \
    TF_VAR_previous_state_passphrase=domotic-old-test-passphrase \
    TF_DATA_DIR="$temp_root/data-rollover-$template_name" \
    tofu -chdir="$template_dir" validate >/dev/null
done

# Exercise the two-stage alias transition against a real encrypted local state.
rotation_root="$temp_root/encryption-rotation"
install -d -m 0700 \
  "$rotation_root/original" \
  "$rotation_root/to-rollover" \
  "$rotation_root/from-rollover" \
  "$rotation_root/final"
cp "$repository_root/bootstrap/backend.tf" "$rotation_root/original/backend.tf"
cp "$repository_root/scripts/encryption-rollover/bootstrap-to-rollover.tf" \
  "$rotation_root/to-rollover/backend.tf"
cp "$repository_root/scripts/encryption-rollover/bootstrap-from-rollover.tf" \
  "$rotation_root/from-rollover/backend.tf"
cp "$repository_root/bootstrap/backend.tf" "$rotation_root/final/backend.tf"
rotation_state="$rotation_root/state.tfstate"

env TF_VAR_state_passphrase=domotic-old-test-passphrase \
  TF_DATA_DIR="$rotation_root/data-original" \
  tofu -chdir="$rotation_root/original" init -input=false -reconfigure \
  -backend-config="path=$rotation_state" >/dev/null
env TF_VAR_state_passphrase=domotic-old-test-passphrase \
  TF_DATA_DIR="$rotation_root/data-original" \
  tofu -chdir="$rotation_root/original" apply -input=false -auto-approve >/dev/null
env TF_VAR_state_passphrase=domotic-new-test-passphrase \
  TF_VAR_previous_state_passphrase=domotic-old-test-passphrase \
  TF_DATA_DIR="$rotation_root/data-to-rollover" \
  tofu -chdir="$rotation_root/to-rollover" init -input=false -reconfigure \
  -backend-config="path=$rotation_state" >/dev/null
env TF_VAR_state_passphrase=domotic-new-test-passphrase \
  TF_VAR_previous_state_passphrase=domotic-old-test-passphrase \
  TF_DATA_DIR="$rotation_root/data-to-rollover" \
  tofu -chdir="$rotation_root/to-rollover" apply -refresh-only \
  -input=false -auto-approve >/dev/null
env TF_VAR_state_passphrase=domotic-new-test-passphrase \
  TF_VAR_previous_state_passphrase=domotic-new-test-passphrase \
  TF_DATA_DIR="$rotation_root/data-from-rollover" \
  tofu -chdir="$rotation_root/from-rollover" init -input=false -reconfigure \
  -backend-config="path=$rotation_state" >/dev/null
env TF_VAR_state_passphrase=domotic-new-test-passphrase \
  TF_VAR_previous_state_passphrase=domotic-new-test-passphrase \
  TF_DATA_DIR="$rotation_root/data-from-rollover" \
  tofu -chdir="$rotation_root/from-rollover" apply -refresh-only \
  -input=false -auto-approve >/dev/null
env TF_VAR_state_passphrase=domotic-new-test-passphrase \
  TF_DATA_DIR="$rotation_root/data-final" \
  tofu -chdir="$rotation_root/final" init -input=false -reconfigure \
  -backend-config="path=$rotation_state" >/dev/null
env TF_VAR_state_passphrase=domotic-new-test-passphrase \
  TF_DATA_DIR="$rotation_root/data-final" \
  tofu -chdir="$rotation_root/final" state pull >/dev/null
grep -Fq '"encrypted_data"' "$rotation_state" ||
  fail "passphrase rotation produced an unencrypted state"
if env TF_VAR_state_passphrase=domotic-old-test-passphrase \
  TF_DATA_DIR="$rotation_root/data-old-final" \
  tofu -chdir="$rotation_root/original" init -input=false -reconfigure \
  -backend-config="path=$rotation_state" >/dev/null 2>&1 &&
  env TF_VAR_state_passphrase=domotic-old-test-passphrase \
  TF_DATA_DIR="$rotation_root/data-old-final" \
  tofu -chdir="$rotation_root/original" state pull >/dev/null 2>&1; then
  fail "the original passphrase still decrypts rotated state"
fi

if grep -Eq 'KUBE_CONTEXT.*default "[^"]+"' \
  "$repository_root/Taskfile.remote.yml" \
  "$repository_root/infra/Taskfile.yml" \
  "$repository_root/charts/domotic/Taskfile.yml"; then
  fail "a production Taskfile selects a default Kubernetes context"
fi

# Validate the runtime wrapper without printing any of its test credentials.
install -d -m 0700 "$temp_root/bin" "$temp_root/runtime/config" "$temp_root/runtime/state"
printf '%s\n' 'r2_bucket_prefix = "test-home"' > "$temp_root/runtime/config/bootstrap.tfvars"
printf '%s\n' '{"encrypted_data":"test"}' > "$temp_root/runtime/state/bootstrap.tfstate"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'for argument in "$@"; do' \
  '  if test "$argument" = init; then exit 0; fi' \
  'done' \
  'if printf "%s\\n" "$@" | grep -Fqx output; then' \
  '  printf '\''{"cloudflare_api_token":"test-cloudflare-token","cloudflare_account_id":"00000000000000000000000000000000","endpoint":"https://00000000000000000000000000000000.r2.cloudflarestorage.com","state":{"bucket":"test-home-state","key":"domotic.tfstate","access_key_id":"state-id","secret_access_key":"state-secret"},"backups":{"bucket":"test-home-backups","access_key_id":"backup-id","secret_access_key":"backup-secret"}}'\''' \
  '  exit 0' \
  'fi' \
  'exit 1' > "$temp_root/bin/tofu"
chmod 0700 "$temp_root/bin/tofu"

PATH="$temp_root/bin:$PATH" \
DOMOTIC_RECOVERY_PASSPHRASE=domotic-test-recovery-passphrase \
  "$repository_root/scripts/with-opentofu-environment.sh" \
  runtime "$repository_root" "$temp_root/runtime" "$temp_root/runtime/config" -- \
  sh -c '
    test "$CLOUDFLARE_API_TOKEN" = test-cloudflare-token
    test "$DOMOTIC_STATE_BUCKET" = test-home-state
    test "$TF_VAR_r2_endpoint" = https://00000000000000000000000000000000.r2.cloudflarestorage.com
    test "$TF_VAR_r2_backup_bucket_name" = test-home-backups
    test "$AWS_ACCESS_KEY_ID" = state-id
    test "$AWS_SECRET_ACCESS_KEY" = state-secret
    test "$(printf "%s" "$TF_VAR_r2_backup_credentials" | jq -r .access_key_id)" = backup-id
  ' || fail "runtime wrapper did not inject bootstrap-state values"

PATH="$temp_root/bin:$PATH" \
DOMOTIC_RECOVERY_PASSPHRASE=domotic-test-recovery-passphrase \
CLOUDFLARE_API_TOKEN=test-cloudflare-token \
  "$repository_root/scripts/with-opentofu-environment.sh" \
  bootstrap "$repository_root" "$temp_root/runtime" "$temp_root/runtime/config" -- \
  sh -c '
    test "$TF_VAR_state_passphrase" = domotic-test-recovery-passphrase
    test "$TF_VAR_cloudflare_api_token" = test-cloudflare-token
  ' || fail "bootstrap wrapper did not inject operator credentials"

# Check the tracked/private boundary with an encrypted-state-shaped fixture.
private_root="$temp_root/private"
config_dir="$private_root/config"
install -d -m 0700 "$config_dir/infra" "$private_root/state"
printf '%s\n' \
  'cloudflare_account_id = "00000000000000000000000000000000"' \
  'r2_bucket_prefix = "test-home"' > "$config_dir/bootstrap.tfvars"
printf '%s\n' 'cloudflare_domain = "example.com"' > "$config_dir/infra/terraform.tfvars"
printf '%s\n' 'homeassistant: {}' > "$config_dir/values.yaml"
printf '%s\n' \
  '{' \
  '  "serial": 1,' \
  '  "meta": {"domotic-bootstrap": "test"},' \
  '  "encrypted_data": "ciphertext"' \
  '}' > "$private_root/state/bootstrap.tfstate"
printf '%s\n' \
  '/.domotic/' \
  '/config/infra/helm-values.yaml' \
  '/config/infra/zigbee-keys.tfvars.json' \
  '/config/restore/' \
  '/config/secrets.yaml' > "$private_root/.gitignore"
git -C "$private_root" init --quiet
git -C "$private_root" add \
  .gitignore \
  config/bootstrap.tfvars \
  config/infra/terraform.tfvars \
  config/values.yaml \
  state/bootstrap.tfstate

run_config_check() {
  "$repository_root/scripts/config-check.sh" \
    "$config_dir" \
    "$config_dir/bootstrap.tfvars" \
    "$private_root/state/bootstrap.tfstate" \
    "$config_dir/infra/terraform.tfvars" \
    "$config_dir/values.yaml" \
    "$config_dir/infra/helm-values.yaml"
}

run_config_check >/dev/null

printf '%s\n' 'cloudflare_api_token = "must-not-be-tracked"' >> "$config_dir/bootstrap.tfvars"
if run_config_check >/dev/null 2>&1; then
  fail "tracked bootstrap credentials were not rejected"
fi
sed -i.bak '$d' "$config_dir/bootstrap.tfvars"
rm "$config_dir/bootstrap.tfvars.bak"

printf '%s\n' 'homeassistant_admin_password_override = "must-not-be-tracked"' \
  >> "$config_dir/infra/terraform.tfvars"
if run_config_check >/dev/null 2>&1; then
  fail "tracked Home Assistant credentials were not rejected"
fi
sed -i.bak '$d' "$config_dir/infra/terraform.tfvars"
rm "$config_dir/infra/terraform.tfvars.bak"

cp "$private_root/state/bootstrap.tfstate" "$private_root/state/bootstrap.tfstate.bak"
printf '%s\n' '{"outputs":{"CLOUDFLARE_API_TOKEN":"plaintext"}}' \
  > "$private_root/state/bootstrap.tfstate"
if run_config_check >/dev/null 2>&1; then
  fail "plaintext bootstrap state was not rejected"
fi
mv "$private_root/state/bootstrap.tfstate.bak" "$private_root/state/bootstrap.tfstate"

# Materialize a Git revision with the current remote entrypoint and scaffold.
fixture_repository="$temp_root/source-repository"
git clone --quiet "$repository_root" "$fixture_repository"
if ! git -C "$repository_root" diff --quiet HEAD -- \
  Taskfile.yml \
  Taskfile.remote.yml \
  examples/private-deployment \
  scripts/config-check.sh \
  scripts/tests/private-deployment.sh; then
  git -C "$repository_root" diff --binary HEAD -- \
    Taskfile.yml \
    Taskfile.remote.yml \
    examples/private-deployment \
    scripts/config-check.sh \
    scripts/tests/private-deployment.sh |
    git -C "$fixture_repository" apply -
fi
cp "$repository_root/examples/private-deployment/.opentofu-version" \
  "$fixture_repository/examples/private-deployment/.opentofu-version"
cp "$repository_root/examples/private-deployment/config/bootstrap.tfvars" \
  "$fixture_repository/examples/private-deployment/config/bootstrap.tfvars"
git -C "$fixture_repository" add -A
git -C "$fixture_repository" add -f \
  examples/private-deployment/config/bootstrap.tfvars
if ! git -C "$fixture_repository" diff --cached --quiet; then
  git -C "$fixture_repository" \
    -c user.name='Domotic Tests' \
    -c user.email='tests@example.invalid' \
    commit --quiet -m 'test: snapshot private deployment workflow'
fi

revision="$(git -C "$fixture_repository" rev-parse HEAD)"
git -C "$fixture_repository" branch test-release "$revision"

equivalent_taskfile="$temp_root/Taskfile.remote.yml?ref=$revision"
equivalent_source_cache="$temp_root/equivalent/.domotic/source"
cp "$repository_root/Taskfile.remote.yml" "$equivalent_taskfile"
git clone --quiet "$fixture_repository" "$equivalent_source_cache"
git -C "$equivalent_source_cache" remote set-url origin git@github.com:fiam/domotic.git
task --silent --taskfile "$equivalent_taskfile" version \
  PRIVATE_ROOT="$temp_root/equivalent" \
  DOMOTIC_SOURCE_DIR="$equivalent_source_cache" \
  DOMOTIC_REPOSITORY=https://github.com/fiam/domotic.git >/dev/null
[[ "$(git -C "$equivalent_source_cache" config --local --get remote.origin.url)" == \
  https://github.com/fiam/domotic.git ]] ||
  fail "remote Taskfile did not normalize an equivalent GitHub origin"

source_cache="$temp_root/remote/.domotic/source"
task --silent --taskfile "$repository_root/Taskfile.remote.yml" version \
  PRIVATE_ROOT="$temp_root/remote" \
  DOMOTIC_SOURCE_DIR="$source_cache" \
  DOMOTIC_REPOSITORY="$fixture_repository" >/dev/null
[[ "$(git -C "$source_cache" rev-parse HEAD)" == "$revision" ]] ||
  fail "remote Taskfile did not materialize the pinned revision"

printf '%s\n' modified >> "$source_cache/README.md"
printf '%s\n' untracked > "$source_cache/untracked-test-file"
task --silent --taskfile "$repository_root/Taskfile.remote.yml" version \
  PRIVATE_ROOT="$temp_root/remote" \
  DOMOTIC_SOURCE_DIR="$source_cache" \
  DOMOTIC_REPOSITORY="$fixture_repository" >/dev/null
[[ -z "$(git -C "$source_cache" status --short)" ]] ||
  fail "remote Taskfile did not normalize the source cache"

tag_taskfile="$temp_root/Taskfile.remote.yml?ref=test-release"
tag_source_cache="$temp_root/tagged/.domotic/source"
cp "$repository_root/Taskfile.remote.yml" "$tag_taskfile"
task --silent --taskfile "$tag_taskfile" version \
  PRIVATE_ROOT="$temp_root/tagged" \
  DOMOTIC_SOURCE_DIR="$tag_source_cache" \
  DOMOTIC_REPOSITORY="$fixture_repository" >/dev/null
[[ "$(git -C "$tag_source_cache" rev-parse HEAD)" == "$revision" ]] ||
  fail "remote Taskfile did not resolve the ref from its URL"

initialized_root="$temp_root/initialized"
task --silent --taskfile "$repository_root/Taskfile.remote.yml" init \
  PRIVATE_ROOT="$initialized_root" \
  DOMOTIC_REPOSITORY="$fixture_repository"
grep -Fq "DOMOTIC_REF: $revision" "$initialized_root/Taskfile.yml" ||
  fail "remote initialization did not pin the selected revision"
grep -Fq "BOOTSTRAP_STATE_FILE: '{{.ROOT_DIR}}/state/bootstrap.tfstate'" \
  "$initialized_root/Taskfile.yml" ||
  fail "remote initialization did not configure encrypted bootstrap state"
if grep -q 'KUBE_CONTEXT' "$initialized_root/Taskfile.yml"; then
  fail "remote initialization pinned a Kubernetes context"
fi
[[ -f "$initialized_root/config/bootstrap.tfvars" ]] ||
  fail "remote initialization did not copy bootstrap configuration"
[[ -f "$initialized_root/.opentofu-version" ]] ||
  fail "remote initialization did not copy the OpenTofu version pin"
[[ ! -e "$initialized_root/config/secrets.yaml.example" ]] ||
  fail "remote initialization retained the removed plaintext secret template"
[[ -f "$initialized_root/config/infra/terraform.tfvars" ]] ||
  fail "remote initialization did not copy deployment configuration"
[[ "$(git -C "$initialized_root" symbolic-ref --short HEAD)" == main ]] ||
  fail "remote initialization did not create the expected main branch"

git -C "$fixture_repository" \
  -c user.name='Domotic Tests' \
  -c user.email='tests@example.invalid' \
  -c commit.gpgsign=false \
  commit --quiet --allow-empty -m 'test: newer remote revision'
updated_revision="$(git -C "$fixture_repository" rev-parse HEAD)"
task --silent --taskfile "$repository_root/Taskfile.remote.yml" domotic:update \
  PRIVATE_ROOT="$initialized_root" \
  DOMOTIC_REPOSITORY="$fixture_repository"
grep -Fq "DOMOTIC_REF: $updated_revision" "$initialized_root/Taskfile.yml" ||
  fail "Domotic update did not pin the resolved revision"

values_file="$initialized_root/config/values.yaml"
"$repository_root/scripts/set-homeassistant-version.sh" "$values_file" "2099.12.7"
grep -Fq '    tag: "2099.12.7"' "$values_file" ||
  fail "Home Assistant update did not change the private image pin"
if "$repository_root/scripts/set-homeassistant-version.sh" \
  "$values_file" "stable" >/dev/null 2>&1; then
  fail "Home Assistant update accepted a moving image tag"
fi

printf 'Private deployment helper tests passed.\n'
