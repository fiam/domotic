#!/usr/bin/env bash

set -euo pipefail
umask 077

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(dirname "$script_dir")"
default_destination="$repository_root/infra/zigbee-keys.tfvars.json"
temporary_file=""
temporary_dir=""

cleanup() {
  [[ -z "$temporary_file" ]] || rm -f -- "$temporary_file"
  [[ -z "$temporary_dir" ]] || rm -rf -- "$temporary_dir"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

usage() {
  cat <<'EOF'
Usage:
  zigbee-keys.sh capture [destination]
  zigbee-keys.sh import <portable-json-or-restored-backup-directory> [destination]

The destination defaults to infra/zigbee-keys.tfvars.json. The generated file
is a Terraform variable file, is ignored by Git, and is written with mode 0600.
EOF
}

validate_bundle() {
  local bundle="$1"
  jq -e '
    (keys | sort) == [
      "generate_zigbee_keys",
      "zigbee_expected_channel",
      "zigbee_expected_pan_id",
      "zigbee_ext_pan_id",
      "zigbee_network_key"
    ] and
    .generate_zigbee_keys == false and
    (.zigbee_network_key | type == "string" and test("^[0-9A-Fa-f]{32}$")) and
    (.zigbee_ext_pan_id | type == "string" and test("^[0-9A-Fa-f]{16}$")) and
    (.zigbee_expected_pan_id | type == "number" and . >= 0 and . <= 65535) and
    (.zigbee_expected_channel | type == "number" and . >= 11 and . <= 26)
  ' "$bundle" >/dev/null || fail "invalid Zigbee key bundle: $bundle"
}

write_bundle_from_kubernetes_json() {
  local secret_json="$1"
  local configmap_json="$2"
  local destination="$3"
  local destination_dir
  local temp_file
  local network_key
  local ext_pan_id
  local pan_id
  local channel

  [[ -f "$secret_json" ]] || fail "missing Secret JSON: $secret_json"
  [[ -f "$configmap_json" ]] || fail "missing ConfigMap JSON: $configmap_json"

  network_key="$(jq -er '.data.network_key' "$secret_json" | base64 --decode)"
  ext_pan_id="$(jq -er '.data.ext_pan_id' "$secret_json" | base64 --decode)"
  pan_id="$(jq -er '.data.pan_id' "$configmap_json")"
  channel="$(jq -er '.data.channel' "$configmap_json")"

  destination_dir="$(dirname "$destination")"
  mkdir -p "$destination_dir"
  temp_file="$(mktemp "$destination_dir/.zigbee-keys.XXXXXX")"
  temporary_file="$temp_file"

  jq -n \
    --arg network_key "$network_key" \
    --arg ext_pan_id "$ext_pan_id" \
    --argjson pan_id "$pan_id" \
    --argjson channel "$channel" \
    '{
      generate_zigbee_keys: false,
      zigbee_network_key: $network_key,
      zigbee_ext_pan_id: $ext_pan_id,
      zigbee_expected_pan_id: $pan_id,
      zigbee_expected_channel: $channel
    }' > "$temp_file"

  validate_bundle "$temp_file"
  chmod 0600 "$temp_file"
  mv -f -- "$temp_file" "$destination"
  temporary_file=""
}

capture_from_cluster() {
  local destination="$1"
  local app_namespace
  local -a kubectl_context_args=()

  require_command kubectl
  require_command terraform
  require_command jq
  require_command base64

  app_namespace="${APP_NAMESPACE:-$(terraform -chdir="$repository_root/infra" output -raw kubernetes_namespace)}"
  [[ -n "$app_namespace" ]] || fail "could not determine the application namespace"
  temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/domotic-zigbee-keys.XXXXXX")"

  if [[ -n "${KUBE_CTX:-}" ]]; then
    kubectl_context_args=(--context "$KUBE_CTX")
  fi

  kubectl "${kubectl_context_args[@]}" \
    --namespace "$app_namespace" \
    get secret zigbee-keys -o json > "$temporary_dir/secret.json"
  kubectl "${kubectl_context_args[@]}" \
    --namespace "$app_namespace" \
    get configmap zigbee-network -o json > "$temporary_dir/configmap.json"
  write_bundle_from_kubernetes_json \
    "$temporary_dir/secret.json" \
    "$temporary_dir/configmap.json" \
    "$destination"
  printf 'Captured the live Zigbee identity in %s (mode 0600).\n' "$destination"
}

import_bundle() {
  local source="$1"
  local destination="$2"
  local destination_dir
  local temp_file

  require_command jq

  if [[ ! -e "$source" && -e "$repository_root/$source" ]]; then
    source="$repository_root/$source"
  fi

  if [[ -d "$source" ]]; then
    write_bundle_from_kubernetes_json \
      "$source/kubernetes/zigbee-keys.json" \
      "$source/kubernetes/zigbee-network.json" \
      "$destination"
  else
    [[ -f "$source" ]] || fail "import source does not exist: $source"
    validate_bundle "$source"
    destination_dir="$(dirname "$destination")"
    mkdir -p "$destination_dir"
    temp_file="$(mktemp "$destination_dir/.zigbee-keys.XXXXXX")"
    temporary_file="$temp_file"
    cp -- "$source" "$temp_file"
    chmod 0600 "$temp_file"
    mv -f -- "$temp_file" "$destination"
    temporary_file=""
  fi

  printf 'Imported the Zigbee identity into %s (mode 0600).\n' "$destination"
}

case "${1:-}" in
  capture)
    capture_from_cluster "${2:-$default_destination}"
    ;;
  import)
    [[ -n "${2:-}" ]] || fail "missing import source"
    import_bundle "$2" "${3:-$default_destination}"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
