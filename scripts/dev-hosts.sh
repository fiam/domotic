#!/usr/bin/env bash

set -euo pipefail

begin_marker="# BEGIN domotic-kind"
end_marker="# END domotic-kind"
hosts_file="${HOSTS_FILE:-/etc/hosts}"

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  dev-hosts.sh install [address] [homeassistant-hostname] [zigbee2mqtt-hostname]
  dev-hosts.sh remove

Defaults:
  address                   127.0.0.1
  homeassistant-hostname    homeassistant.local
  zigbee2mqtt-hostname      zigbee2mqtt.local
EOF
}

validate_hostname() {
  local hostname="$1"
  [[ ${#hostname} -le 253 ]] || fail "hostname is longer than 253 characters: $hostname"
  [[ "$hostname" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] ||
    fail "invalid lowercase hostname: $hostname"
  [[ "$hostname" != *..* ]] || fail "hostname contains consecutive dots: $hostname"
}

[[ -f "$hosts_file" ]] || fail "hosts file does not exist: $hosts_file"
if [[ "$hosts_file" == "/etc/hosts" && ${EUID:-$(id -u)} -ne 0 ]]; then
  fail "run this command through sudo (or use task dev:hosts:install)"
fi

action="${1:-}"
case "$action" in
  install | remove) ;;
  *)
    usage >&2
    exit 2
    ;;
esac

temp_file="$(mktemp "${TMPDIR:-/tmp}/domotic-hosts.XXXXXX")"
cleanup() {
  rm -f -- "$temp_file"
}
trap cleanup EXIT HUP INT TERM

# Remove only the block managed by this repository. Refuse a malformed block
# rather than risking an unintended rewrite of the hosts file.
awk -v begin="$begin_marker" -v end="$end_marker" '
  $0 == begin {
    if (managed) exit 2
    managed = 1
    next
  }
  $0 == end {
    if (!managed) exit 2
    managed = 0
    next
  }
  !managed { print }
  END { if (managed) exit 2 }
' "$hosts_file" > "$temp_file" || fail "the managed block in $hosts_file is malformed"

if [[ "$action" == "install" ]]; then
  address="${2:-127.0.0.1}"
  homeassistant_hostname="${3:-homeassistant.local}"
  zigbee2mqtt_hostname="${4:-zigbee2mqtt.local}"

  [[ "$address" =~ ^[0-9A-Fa-f:.]+$ ]] || fail "invalid IP address: $address"
  validate_hostname "$homeassistant_hostname"
  validate_hostname "$zigbee2mqtt_hostname"
  [[ "$homeassistant_hostname" != "$zigbee2mqtt_hostname" ]] ||
    fail "the two route hostnames must be different"

  {
    printf '\n%s\n' "$begin_marker"
    printf '%s %s %s\n' "$address" "$homeassistant_hostname" "$zigbee2mqtt_hostname"
    printf '%s\n' "$end_marker"
  } >> "$temp_file"
fi

backup_file="${hosts_file}.domotic.bak"
cp -p -- "$hosts_file" "$backup_file"
cp -- "$temp_file" "$hosts_file"

if [[ "$action" == "install" ]]; then
  printf 'Configured %s for %s and %s.\n' \
    "$hosts_file" "$homeassistant_hostname" "$zigbee2mqtt_hostname"
else
  printf 'Removed the Domotic Kind block from %s.\n' "$hosts_file"
fi
printf 'Previous contents are available at %s.\n' "$backup_file"
