#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "$script_dir/../.." && pwd)"
temp_root="$(mktemp -d "${TMPDIR:-/tmp}/domotic-private-deployment-test.XXXXXX")"

cleanup() {
  rm -rf -- "$temp_root"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

fail() {
  printf 'Test failed: %s\n' "$*" >&2
  exit 1
}

install -d -m 0700 "$temp_root/bin"
fake_secrets_file="$temp_root/secrets.sops.yaml"
fake_age_key_file="$temp_root/age-identity.txt"
printf '%s\n' encrypted-placeholder > "$fake_secrets_file"
printf '%s\n' AGE-SECRET-KEY-TEST > "$fake_age_key_file"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'test "$1" = decrypt' \
  'test "$2" = --output-type' \
  'test "$3" = json' \
  'test -f "$4"' \
  'test "${SOPS_AGE_KEY_FILE:-}" = "${EXPECTED_SOPS_AGE_KEY_FILE:-}"' \
  'if test "${FAKE_SOPS_WITHOUT_HA:-false}" = true; then' \
  '  printf '\''{"CLOUDFLARE_API_TOKEN":"test-cloudflare-token"}'\''' \
  'else' \
  '  printf '\''{"CLOUDFLARE_API_TOKEN":"test-cloudflare-token","HOMEASSISTANT_ADMIN_PASSWORD":"test-homeassistant-password"}'\''' \
  'fi' > "$temp_root/bin/sops"
chmod 0700 "$temp_root/bin/sops"

resolver_result="$(
  PATH="$temp_root/bin:$PATH" \
  SOPS_AGE_KEY_FILE="$fake_age_key_file" \
  EXPECTED_SOPS_AGE_KEY_FILE="$fake_age_key_file" \
    "$repository_root/scripts/with-deployment-secrets.sh" \
    seed "$fake_secrets_file" -- sh -c '
      test "$TF_VAR_cloudflare_api_token" = test-cloudflare-token
      printf "%s" "$TF_VAR_homeassistant_onboarding" |
        jq -e '\''
          .password == "test-homeassistant-password" and
          (keys == ["password"])
        '\'' >/dev/null
      printf sops-ok
    '
)"
[[ "$resolver_result" == sops-ok ]] ||
  fail "SOPS wrapper did not inject the expected Terraform variables"

PATH="$temp_root/bin:$PATH" \
SOPS_AGE_KEY_FILE="$fake_age_key_file" \
EXPECTED_SOPS_AGE_KEY_FILE="$fake_age_key_file" \
  "$repository_root/scripts/with-deployment-secrets.sh" \
  check "$fake_secrets_file" |
  grep -Fqx 'SOPS deployment secrets are readable.' ||
  fail "SOPS deployment secret check did not succeed"

TF_VAR_homeassistant_onboarding=inherited-value \
PATH="$temp_root/bin:$PATH" \
SOPS_AGE_KEY_FILE="$fake_age_key_file" \
EXPECTED_SOPS_AGE_KEY_FILE="$fake_age_key_file" \
FAKE_SOPS_WITHOUT_HA=true \
  "$repository_root/scripts/with-deployment-secrets.sh" \
  cloudflare "$fake_secrets_file" -- \
  sh -c 'test -z "${TF_VAR_homeassistant_onboarding+x}"' ||
  fail "restore mode required or inherited a Home Assistant credential"

if PATH="$temp_root/bin:$PATH" \
  SOPS_AGE_KEY_FILE="$fake_age_key_file" \
  EXPECTED_SOPS_AGE_KEY_FILE="$fake_age_key_file" \
  FAKE_SOPS_WITHOUT_HA=true \
    "$repository_root/scripts/with-deployment-secrets.sh" \
    check "$fake_secrets_file" \
    >/dev/null 2>&1; then
  fail "seed mode accepted a SOPS document without the Home Assistant password"
fi

config_dir="$temp_root/private/config"
install -d -m 0700 "$config_dir/infra"
printf '%s\n' 'cloudflare_domain = "example.com"' > "$config_dir/infra/terraform.tfvars"
printf '%s\n' 'homeassistant: {}' > "$config_dir/values.yaml"
printf '%s\n' \
  'CLOUDFLARE_API_TOKEN: ENC[AES256_GCM,data:test]' \
  'HOMEASSISTANT_ADMIN_PASSWORD: ENC[AES256_GCM,data:test]' \
  'sops:' \
  '  mac: ENC[AES256_GCM,data:test]' > "$config_dir/secrets.sops.yaml"
printf '%s\n' \
  '/config/backup.env' \
  '/config/infra/helm-values.yaml' \
  '/config/infra/zigbee-keys.tfvars.json' \
  '/config/restore/' \
  '/config/secrets.yaml' > "$temp_root/private/.gitignore"
git -C "$temp_root/private" init --quiet
git -C "$temp_root/private" add \
  .gitignore \
  config/infra/terraform.tfvars \
  config/secrets.sops.yaml \
  config/values.yaml

run_config_check() {
  "$repository_root/scripts/config-check.sh" \
    "$config_dir" \
    "$config_dir/infra/terraform.tfvars" \
    "$config_dir/values.yaml" \
    "$config_dir/infra/zigbee-keys.tfvars.json" \
    "$config_dir/infra/helm-values.yaml" \
    "$config_dir/backup.env" \
    "$config_dir/secrets.sops.yaml"
}

run_config_check >/dev/null

printf '%s\n' 'cloudflare_api_token = "must-not-be-tracked"' >> "$config_dir/infra/terraform.tfvars"
if run_config_check >/dev/null 2>&1; then
  fail "tracked Terraform credentials were not rejected"
fi
sed -i.bak '$d' "$config_dir/infra/terraform.tfvars"
rm "$config_dir/infra/terraform.tfvars.bak"

sed -i.bak \
  's/^HOMEASSISTANT_ADMIN_PASSWORD:.*/HOMEASSISTANT_ADMIN_PASSWORD: must-not-be-plaintext/' \
  "$config_dir/secrets.sops.yaml"
if run_config_check >/dev/null 2>&1; then
  fail "a plaintext value in the tracked SOPS document was not rejected"
fi
mv "$config_dir/secrets.sops.yaml.bak" "$config_dir/secrets.sops.yaml"

sed -i.bak '/^HOMEASSISTANT_ADMIN_PASSWORD:/d' "$config_dir/secrets.sops.yaml"
run_config_check >/dev/null ||
  fail "restore-compatible configuration required a Home Assistant password"
mv "$config_dir/secrets.sops.yaml.bak" "$config_dir/secrets.sops.yaml"

# Materialize a temporary Git revision containing the current implementation.
# This keeps the remote-Taskfile test useful before and after these files are
# committed without copying unrelated untracked workspace files.
fixture_repository="$temp_root/source-repository"
git clone --quiet "$repository_root" "$fixture_repository"
git -C "$repository_root" diff --binary HEAD -- \
  Taskfile.yml \
  Taskfile.remote.yml \
  examples/private-deployment \
  scripts/config-check.sh \
  scripts/tests/private-deployment.sh \
  scripts/with-deployment-secrets.sh |
  git -C "$fixture_repository" apply -
if ! git -C "$fixture_repository" ls-files --error-unmatch \
  examples/private-deployment/config/secrets.yaml.example >/dev/null 2>&1; then
  cp "$repository_root/examples/private-deployment/config/secrets.yaml.example" \
    "$fixture_repository/examples/private-deployment/config/secrets.yaml.example"
fi
git -C "$fixture_repository" add -A
if ! git -C "$fixture_repository" diff --cached --quiet; then
  git -C "$fixture_repository" \
    -c user.name='Domotic Tests' \
    -c user.email='tests@example.invalid' \
    commit --quiet -m 'test: snapshot private deployment workflow'
fi

source_cache="$temp_root/remote/.domotic/source"
revision="$(git -C "$fixture_repository" rev-parse HEAD)"
task --silent --taskfile "$repository_root/Taskfile.remote.yml" bootstrap \
  PRIVATE_ROOT="$temp_root/remote" \
  DOMOTIC_SOURCE_DIR="$source_cache" \
  DOMOTIC_REPOSITORY="$fixture_repository" \
  DOMOTIC_REF="$revision"
[[ "$(git -C "$source_cache" rev-parse HEAD)" == "$revision" ]] ||
  fail "remote Taskfile bootstrap did not materialize the pinned revision"

printf '%s\n' modified >> "$source_cache/README.md"
printf '%s\n' untracked > "$source_cache/untracked-test-file"
task --silent --taskfile "$repository_root/Taskfile.remote.yml" bootstrap \
  PRIVATE_ROOT="$temp_root/remote" \
  DOMOTIC_SOURCE_DIR="$source_cache" \
  DOMOTIC_REPOSITORY="$fixture_repository" \
  DOMOTIC_REF="$revision"
[[ -z "$(git -C "$source_cache" status --short)" ]] ||
  fail "remote Taskfile bootstrap did not normalize the source cache"

initialized_root="$temp_root/initialized"
task --silent --taskfile "$repository_root/Taskfile.remote.yml" init \
  PRIVATE_ROOT="$initialized_root" \
  DOMOTIC_REPOSITORY="$fixture_repository" \
  DOMOTIC_REF="$revision"
grep -Fq "DOMOTIC_REF: $revision" "$initialized_root/Taskfile.yml" ||
  fail "remote initialization did not pin the selected revision"
grep -Fq "SECRETS_FILE: '{{.ROOT_DIR}}/config/secrets.sops.yaml'" \
  "$initialized_root/Taskfile.yml" ||
  fail "remote initialization did not configure the SOPS secrets document"
[[ -f "$initialized_root/config/secrets.yaml.example" ]] ||
  fail "remote initialization did not copy the SOPS plaintext template"
[[ -f "$initialized_root/config/infra/terraform.tfvars" ]] ||
  fail "remote initialization did not copy the private configuration scaffold"
[[ "$(git -C "$initialized_root" symbolic-ref --short HEAD)" == main ]] ||
  fail "remote initialization did not create the expected main branch"

printf 'Private deployment helper tests passed.\n'
