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

fake_resolver="$temp_root/resolver.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'test "$1" = get' \
  'case "$2" in' \
  '  test://cloudflare) printf test-cloudflare-token ;;' \
  '  test://homeassistant) printf test-homeassistant-password ;;' \
  '  test://age) printf AGE-SECRET-KEY-TEST ;;' \
  '  *) exit 1 ;;' \
  'esac' > "$fake_resolver"
chmod 0700 "$fake_resolver"

resolver_result="$({
  "$repository_root/scripts/with-deployment-secrets.sh" \
    --resolver "$fake_resolver" \
    --cloudflare-token-ref test://cloudflare \
    --homeassistant-password-ref test://homeassistant \
    -- sh -c '
      test "$TF_VAR_cloudflare_api_token" = test-cloudflare-token
      printf "%s" "$TF_VAR_homeassistant_onboarding" |
        jq -e '\''
          .name == "Home Administrator" and
          .username == "admin" and
          .password == "test-homeassistant-password" and
          .language == "en"
        '\'' >/dev/null
      printf resolver-ok
    '
})"
[[ "$resolver_result" == resolver-ok ]] || fail "reference resolver did not inject the expected Terraform variables"

TF_VAR_homeassistant_onboarding=inherited-value \
  "$repository_root/scripts/with-deployment-secrets.sh" \
  --resolver "$fake_resolver" \
  --cloudflare-token-ref test://cloudflare \
  --without-homeassistant-admin \
  -- sh -c 'test -z "${TF_VAR_homeassistant_onboarding+x}"' ||
  fail "restore mode inherited an unrelated Home Assistant credential"

DOMOTIC_REFERENCE_TEST=test-environment-secret \
  "$repository_root/scripts/secret-reference.sh" \
  get env://DOMOTIC_REFERENCE_TEST | grep -Fqx test-environment-secret ||
  fail "env:// secret reference did not resolve"

install -d -m 0700 "$temp_root/bin"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'test "$1" = read' \
  'test "$2" = op://TestVault/TestItem/credential' \
  'printf test-onepassword-secret' > "$temp_root/bin/op"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'test "$1" = find-generic-password' \
  'test "$2" = -a && test "$3" = test-account' \
  'test "$4" = -s && test "$5" = test-service' \
  'test "$6" = -w' \
  'printf test-keychain-secret' > "$temp_root/bin/security"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'test "$1" = decrypt && test "$2" = --output-type && test "$3" = json' \
  'printf '\''{"cloudflare_api_token":"test-sops-secret"}'\''' > "$temp_root/bin/sops"
chmod 0700 "$temp_root/bin/op" "$temp_root/bin/security" "$temp_root/bin/sops"

[[ "$(PATH="$temp_root/bin:$PATH" \
  "$repository_root/scripts/secret-reference.sh" \
  get op://TestVault/TestItem/credential)" == test-onepassword-secret ]] ||
  fail "op:// secret reference was not passed to the 1Password CLI"
[[ "$(PATH="$temp_root/bin:$PATH" \
  "$repository_root/scripts/secret-reference.sh" \
  get keychain://test-account/test-service)" == test-keychain-secret ]] ||
  fail "keychain:// secret reference did not select its account and service"
printf '%s\n' encrypted-placeholder > "$temp_root/secrets.sops.yaml"
[[ "$(PATH="$temp_root/bin:$PATH" \
  "$repository_root/scripts/secret-reference.sh" \
  get "sops://$temp_root/secrets.sops.yaml#cloudflare_api_token")" == test-sops-secret ]] ||
  fail "sops:// secret reference did not select its file and key"

if "$repository_root/scripts/secret-reference.sh" \
  get passwords://unsupported >/dev/null 2>&1; then
  fail "passwords:// must not imply unsupported Apple Passwords access"
fi

config_dir="$temp_root/private/config"
install -d -m 0700 "$config_dir/infra"
printf '%s\n' 'cloudflare_domain = "example.com"' > "$config_dir/infra/terraform.tfvars"
printf '%s\n' 'homeassistant: {}' > "$config_dir/values.yaml"
printf '%s\n' \
  '/config/backup.env' \
  '/config/infra/helm-values.yaml' \
  '/config/infra/zigbee-keys.tfvars.json' \
  '/config/restore/' > "$temp_root/private/.gitignore"
git -C "$temp_root/private" init --quiet
git -C "$temp_root/private" add .gitignore config/infra/terraform.tfvars config/values.yaml

"$repository_root/scripts/config-check.sh" \
  "$config_dir" \
  "$config_dir/infra/terraform.tfvars" \
  "$config_dir/values.yaml" \
  "$config_dir/infra/zigbee-keys.tfvars.json" \
  "$config_dir/infra/helm-values.yaml" \
  "$config_dir/backup.env" >/dev/null

printf '%s\n' 'cloudflare_api_token = "must-not-be-tracked"' >> "$config_dir/infra/terraform.tfvars"
if "$repository_root/scripts/config-check.sh" \
  "$config_dir" \
  "$config_dir/infra/terraform.tfvars" \
  "$config_dir/values.yaml" \
  "$config_dir/infra/zigbee-keys.tfvars.json" \
  "$config_dir/infra/helm-values.yaml" \
  "$config_dir/backup.env" >/dev/null 2>&1; then
  fail "tracked Terraform credentials were not rejected"
fi

source_cache="$temp_root/remote/.domotic/source"
revision="$(git -C "$repository_root" rev-parse HEAD)"
task --silent --taskfile "$repository_root/Taskfile.remote.yml" bootstrap \
  PRIVATE_ROOT="$temp_root/remote" \
  DOMOTIC_SOURCE_DIR="$source_cache" \
  DOMOTIC_REPOSITORY="$repository_root" \
  DOMOTIC_REF="$revision"
[[ "$(git -C "$source_cache" rev-parse HEAD)" == "$revision" ]] ||
  fail "remote Taskfile bootstrap did not materialize the pinned revision"

printf '%s\n' modified >> "$source_cache/README.md"
printf '%s\n' untracked > "$source_cache/untracked-test-file"
task --silent --taskfile "$repository_root/Taskfile.remote.yml" bootstrap \
  PRIVATE_ROOT="$temp_root/remote" \
  DOMOTIC_SOURCE_DIR="$source_cache" \
  DOMOTIC_REPOSITORY="$repository_root" \
  DOMOTIC_REF="$revision"
[[ -z "$(git -C "$source_cache" status --short)" ]] ||
  fail "remote Taskfile bootstrap did not normalize the source cache"

initialized_root="$temp_root/initialized"
task --silent --taskfile "$repository_root/Taskfile.remote.yml" init \
  PRIVATE_ROOT="$initialized_root" \
  DOMOTIC_REPOSITORY="$repository_root" \
  DOMOTIC_REF="$revision"
grep -Fq "DOMOTIC_REF: $revision" "$initialized_root/Taskfile.yml" ||
  fail "remote initialization did not pin the selected revision"
grep -Fq "CLOUDFLARE_API_TOKEN_REF: 'keychain://domotic/cloudflare-api-token'" \
  "$initialized_root/Taskfile.yml" ||
  fail "remote initialization did not configure a Cloudflare secret reference"
grep -Fq "HOMEASSISTANT_ADMIN_PASSWORD_REF: 'keychain://domotic/homeassistant-admin-password'" \
  "$initialized_root/Taskfile.yml" ||
  fail "remote initialization did not configure a Home Assistant secret reference"
[[ -f "$initialized_root/config/infra/terraform.tfvars" ]] ||
  fail "remote initialization did not copy the private configuration scaffold"
[[ "$(git -C "$initialized_root" symbolic-ref --short HEAD)" == main ]] ||
  fail "remote initialization did not create the expected main branch"

printf 'Private deployment helper tests passed.\n'
