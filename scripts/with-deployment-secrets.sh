#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  with-deployment-secrets.sh check SECRETS_FILE
  with-deployment-secrets.sh seed SECRETS_FILE -- COMMAND [ARGUMENTS...]
  with-deployment-secrets.sh cloudflare SECRETS_FILE -- COMMAND [ARGUMENTS...]

The seed mode injects the Cloudflare token and Home Assistant onboarding
password. The cloudflare mode injects only the Cloudflare token for restore or
destroy operations. SOPS is solely responsible for locating its master key.
EOF
}

mode="${1:-}"
secrets_file="${2:-}"

case "$mode" in
  check|seed|cloudflare) ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    fail "first argument must be check, seed, or cloudflare"
    ;;
esac

[[ -n "$secrets_file" ]] || fail "missing SOPS secrets file path"
[[ -f "$secrets_file" ]] || fail "SOPS secrets file does not exist: $secrets_file"

if [[ "$mode" == check ]]; then
  [[ $# -eq 2 ]] || fail "check accepts only a SOPS secrets file path"
else
  [[ $# -ge 4 && "$3" == -- ]] || fail "$mode requires -- followed by a command"
  shift 3
fi

command -v sops >/dev/null 2>&1 || fail "sops is required to decrypt deployment secrets"
command -v jq >/dev/null 2>&1 || fail "jq is required to read deployment secrets"

# SOPS owns master-key discovery. In particular, preserve SOPS_AGE_KEY,
# SOPS_AGE_KEY_FILE, SOPS_AGE_KEY_CMD, and all KMS-related environment values.
secrets_json="$(sops decrypt --output-type json "$secrets_file")" ||
  fail "could not decrypt the SOPS secrets file: $secrets_file"

read_secret() {
  local key="$1"
  local value

  value="$(jq -er --arg key "$key" \
    '.[$key] | select(type == "string" and length > 0)' \
    <<<"$secrets_json" 2>/dev/null)" ||
    fail "SOPS secrets file is missing a non-empty $key value"
  printf '%s' "$value"
}

# Do not accidentally inherit stale Terraform credentials from the parent
# shell; the decrypted document is authoritative for this command.
unset TF_VAR_cloudflare_api_token TF_VAR_homeassistant_onboarding

cloudflare_api_token="$(read_secret CLOUDFLARE_API_TOKEN)"
environment=("TF_VAR_cloudflare_api_token=$cloudflare_api_token")

if [[ "$mode" != cloudflare ]]; then
  homeassistant_admin_password="$(read_secret HOMEASSISTANT_ADMIN_PASSWORD)"
  homeassistant_onboarding="$(
    jq -cn \
      --arg password "$homeassistant_admin_password" \
      '{password: $password}'
  )"
  environment+=("TF_VAR_homeassistant_onboarding=$homeassistant_onboarding")
fi

if [[ "$mode" == check ]]; then
  printf 'SOPS deployment secrets are readable.\n'
  exit 0
fi

exec env "${environment[@]}" "$@"
