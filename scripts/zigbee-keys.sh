#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage: zigbee-keys.sh import BUNDLE INFRA_DIR TF_VARS_FILE

Imports a legacy Domotic Zigbee identity bundle into encrypted OpenTofu state.
The bundle is read in memory and is never copied into the deployment.
EOF
  exit 2
}

[[ "${1:-}" == "import" && $# -eq 4 ]] || usage
bundle="$2"
infra_dir="$3"
tf_vars_file="$4"

command -v jq >/dev/null 2>&1 || fail "jq is required"
[[ -f "$bundle" ]] || fail "Zigbee identity bundle does not exist: $bundle"
[[ -d "$infra_dir" ]] || fail "OpenTofu infrastructure directory does not exist: $infra_dir"
[[ -f "$tf_vars_file" ]] || fail "OpenTofu variables file does not exist: $tf_vars_file"

jq -e '
  (.zigbee_network_key | type == "string" and test("^[0-9A-Fa-f]{32}$")) and
  (.zigbee_ext_pan_id | type == "string" and test("^[0-9A-Fa-f]{16}$")) and
  (.zigbee_expected_pan_id | type == "number" and . >= 0 and . <= 65535) and
  (.zigbee_expected_channel | type == "number" and . >= 11 and . <= 26)
' "$bundle" >/dev/null || fail "invalid Zigbee identity bundle"

export TF_VAR_zigbee_network_key="$(jq -er '.zigbee_network_key' "$bundle")"
export TF_VAR_zigbee_ext_pan_id="$(jq -er '.zigbee_ext_pan_id' "$bundle")"
export TF_VAR_zigbee_expected_pan_id="$(jq -er '.zigbee_expected_pan_id' "$bundle")"
export TF_VAR_zigbee_expected_channel="$(jq -er '.zigbee_expected_channel' "$bundle")"

tofu -chdir="$infra_dir" apply -input=false \
  -var-file="$tf_vars_file" \
  -replace=terraform_data.zigbee_identity \
  -target=terraform_data.zigbee_identity

printf '%s\n' 'The Zigbee identity is now retained in encrypted OpenTofu state.'
printf '%s\n' 'Run task plan and verify the protected PAN ID and channel before deploying.'
