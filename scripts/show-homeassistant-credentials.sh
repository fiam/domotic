#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 1 ]] || {
  printf 'usage: show-homeassistant-credentials.sh INFRA_DIR\n' >&2
  exit 2
}

credentials="$(tofu -chdir="$1" output -json homeassistant_credentials)"
backup_password="$(tofu -chdir="$1" output -json homeassistant_backup_password)"

printf 'Home Assistant username: %s\n' "$(jq -er '.username' <<<"$credentials")"
printf 'Home Assistant password: %s\n' "$(jq -er '.password' <<<"$credentials")"
if [[ "$backup_password" != "null" ]]; then
  printf 'Native backup password: %s\n' "$(jq -er '.' <<<"$backup_password")"
else
  printf '%s\n' 'Native backup encryption: disabled'
fi
