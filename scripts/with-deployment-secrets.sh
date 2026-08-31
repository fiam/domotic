#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  with-deployment-secrets.sh [options] -- <command> [arguments...]
  with-deployment-secrets.sh [options] --check

Options:
  --resolver PATH               Secret-reference resolver executable
  --cloudflare-token-ref URI    Cloudflare API token reference
  --homeassistant-password-ref URI
                                Home Assistant owner password reference
  --sops-age-key-ref URI        Optional reference for the SOPS age identity
  --without-homeassistant-admin Do not request or inject the HA owner password

A resolver is an executable accepting: get <secret-reference>.
EOF
}

resolver="${DOMOTIC_SECRET_RESOLVER:-$script_dir/secret-reference.sh}"
secret_base_dir="${DOMOTIC_SECRET_BASE_DIR:-$PWD}"
cloudflare_token_ref="${DOMOTIC_CLOUDFLARE_API_TOKEN_REF:-}"
homeassistant_password_ref="${DOMOTIC_HOMEASSISTANT_ADMIN_PASSWORD_REF:-}"
sops_age_key_ref="${DOMOTIC_SOPS_AGE_KEY_REF:-}"
with_homeassistant_admin="${DOMOTIC_WITH_HOMEASSISTANT_ADMIN:-true}"
check_only=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resolver)
      [[ $# -ge 2 ]] || fail "--resolver requires a value"
      resolver="$2"
      shift 2
      ;;
    --cloudflare-token-ref)
      [[ $# -ge 2 ]] || fail "--cloudflare-token-ref requires a value"
      cloudflare_token_ref="$2"
      shift 2
      ;;
    --homeassistant-password-ref)
      [[ $# -ge 2 ]] || fail "--homeassistant-password-ref requires a value"
      homeassistant_password_ref="$2"
      shift 2
      ;;
    --sops-age-key-ref)
      [[ $# -ge 2 ]] || fail "--sops-age-key-ref requires a value"
      sops_age_key_ref="$2"
      shift 2
      ;;
    --without-homeassistant-admin)
      with_homeassistant_admin=false
      shift
      ;;
    --check)
      check_only=true
      shift
      ;;
    --)
      shift
      break
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

[[ "$with_homeassistant_admin" == true || "$with_homeassistant_admin" == false ]] ||
  fail "DOMOTIC_WITH_HOMEASSISTANT_ADMIN must be true or false"
[[ -d "$secret_base_dir" ]] || fail "secret reference base directory does not exist: $secret_base_dir"
if [[ "$resolver" != /* ]]; then
  resolver="$secret_base_dir/$resolver"
fi
[[ -x "$resolver" ]] || fail "secret resolver is not executable: $resolver"
[[ -n "$cloudflare_token_ref" ]] || fail "Cloudflare API token reference is not configured"
if [[ "$with_homeassistant_admin" == true ]]; then
  [[ -n "$homeassistant_password_ref" ]] ||
    fail "Home Assistant admin password reference is not configured"
fi

# The configured resolver is authoritative; do not accidentally inherit stale
# Terraform credentials from the parent shell.
unset TF_VAR_cloudflare_api_token TF_VAR_homeassistant_onboarding

age_key=""
if [[ -n "$sops_age_key_ref" ]]; then
  age_key="$(cd "$secret_base_dir" && "$resolver" get "$sops_age_key_ref")"
  [[ -n "$age_key" ]] || fail "SOPS age key reference resolved to an empty identity"
fi

resolve_secret() {
  local secret_reference="$1"

  if [[ -n "$age_key" ]]; then
    (cd "$secret_base_dir" && SOPS_AGE_KEY="$age_key" "$resolver" get "$secret_reference")
  else
    (cd "$secret_base_dir" && "$resolver" get "$secret_reference")
  fi
}

cloudflare_api_token="$(resolve_secret "$cloudflare_token_ref")"
[[ -n "$cloudflare_api_token" ]] || fail "Cloudflare token reference resolved to an empty value"

environment=("TF_VAR_cloudflare_api_token=$cloudflare_api_token")
if [[ "$with_homeassistant_admin" == true ]]; then
  command -v jq >/dev/null 2>&1 || fail "jq is required to construct the Home Assistant owner input"
  homeassistant_admin_password="$(resolve_secret "$homeassistant_password_ref")"
  [[ -n "$homeassistant_admin_password" ]] ||
    fail "Home Assistant password reference resolved to an empty value"
  homeassistant_onboarding="$(
    jq -cn \
    --arg name "${DOMOTIC_HOMEASSISTANT_ADMIN_NAME:-Home Administrator}" \
    --arg username "${DOMOTIC_HOMEASSISTANT_ADMIN_USERNAME:-admin}" \
    --arg password "$homeassistant_admin_password" \
    --arg language "${DOMOTIC_HOMEASSISTANT_ADMIN_LANGUAGE:-en}" \
    '{name: $name, username: $username, password: $password, language: $language}'
  )"
  environment+=("TF_VAR_homeassistant_onboarding=$homeassistant_onboarding")
fi

if [[ "$check_only" == true ]]; then
  printf 'Configured secret references are readable.\n'
  exit 0
fi

[[ $# -gt 0 ]] || fail "missing command after --"
exec env "${environment[@]}" "$@"
