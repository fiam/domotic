#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 2 ]] || fail "usage: update-homeassistant-credentials.sh INFRA_DIR TF_VARS_FILE"
infra_dir="$1"
tf_vars_file="$2"

[[ -r /dev/tty ]] || fail "interactive credential entry requires a terminal"
[[ -f "$tf_vars_file" ]] || fail "missing OpenTofu variables file: $tf_vars_file"

current_credentials="$(tofu -chdir="$infra_dir" output -json homeassistant_credentials)"
current_username="$(jq -er '.username' <<<"$current_credentials")"
unset current_credentials

IFS= read -r -p "Home Assistant owner username [$current_username]: " username </dev/tty
username="${username:-$current_username}"
[[ "$username" =~ ^[a-z0-9._-]+$ ]] || fail "username must be lowercase and contain no whitespace"

IFS= read -r -s -p 'Home Assistant owner password: ' password </dev/tty
printf '\n' >/dev/tty
IFS= read -r -s -p 'Confirm Home Assistant owner password: ' confirmation </dev/tty
printf '\n' >/dev/tty
[[ "$password" == "$confirmation" ]] || fail "passwords do not match"
(( ${#password} >= 6 && ${#password} <= 72 )) || fail "password must contain 6-72 characters"
unset confirmation current_username

export TF_VAR_homeassistant_admin_username_override="$username"
export TF_VAR_homeassistant_admin_password_override="$password"
unset username password

tofu -chdir="$infra_dir" apply -input=false \
  -var-file="$tf_vars_file" \
  -replace=terraform_data.homeassistant_credentials \
  -target=terraform_data.homeassistant_credentials

printf '%s\n' 'The encrypted state now contains the supplied owner credential.'
printf '%s\n' 'Run task deploy to update the cluster and complete reconciliation.'
