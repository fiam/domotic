#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 1 ]] || {
  printf 'usage: show-homeassistant-credentials.sh INFRA_DIR\n' >&2
  exit 2
}

outputs="$(tofu -chdir="$1" output -json)"
credentials="$(jq -cer '.homeassistant_credentials.value' <<<"$outputs")"
backup_password="$(
  jq -cr '.homeassistant_backup_password.value // null' <<<"$outputs"
)"
unset outputs

printf 'Home Assistant username: %s\n' "$(jq -er '.username' <<<"$credentials")"
printf 'Home Assistant password: %s\n' "$(jq -er '.password' <<<"$credentials")"
if [[ "$backup_password" != "null" ]]; then
  printf 'Native backup password: %s\n' "$(jq -er '.' <<<"$backup_password")"
else
  printf '%s\n' 'Native backup encryption: disabled'
fi

unset credentials backup_password
