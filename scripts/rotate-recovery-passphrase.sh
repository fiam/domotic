#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 4 ]] || fail "usage: rotate-recovery-passphrase.sh SOURCE_ROOT PRIVATE_ROOT CONFIG_DIR BOOTSTRAP_STATE_FILE"
source_root="$1"
private_root="$2"
config_dir="$3"
bootstrap_state_file="$4"

old_passphrase="${TF_VAR_state_passphrase:-}"
[[ -n "$old_passphrase" ]] || fail "the current recovery passphrase was not provided"
[[ -f "$bootstrap_state_file" ]] || fail "bootstrap state is missing: $bootstrap_state_file"

new_passphrase="${DOMOTIC_NEW_RECOVERY_PASSPHRASE:-}"
if [[ -z "$new_passphrase" ]]; then
  [[ -r /dev/tty ]] || fail "set DOMOTIC_NEW_RECOVERY_PASSPHRASE in a non-interactive session"
  IFS= read -r -s -p 'New recovery passphrase: ' new_passphrase </dev/tty
  printf '\n' >/dev/tty
  IFS= read -r -s -p 'Confirm new recovery passphrase: ' confirmation </dev/tty
  printf '\n' >/dev/tty
  [[ "$new_passphrase" == "$confirmation" ]] || fail "new recovery passphrases do not match"
  unset confirmation
fi
(( ${#new_passphrase} >= 16 )) || fail "the new recovery passphrase must contain at least 16 characters"
[[ "$new_passphrase" != "$old_passphrase" ]] || fail "the new recovery passphrase must differ from the current one"

bootstrap_vars_file="${DOMOTIC_BOOTSTRAP_VARS_FILE:-$config_dir/bootstrap.tfvars}"
tofu_vars_file="${TF_VARS_FILE:-$config_dir/infra/terraform.tfvars}"
[[ -f "$bootstrap_vars_file" ]] || fail "missing bootstrap variables: $bootstrap_vars_file"
[[ -f "$tofu_vars_file" ]] || fail "missing OpenTofu variables: $tofu_vars_file"

for variable in DOMOTIC_R2_ENDPOINT DOMOTIC_STATE_BUCKET DOMOTIC_STATE_KEY AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY CLOUDFLARE_API_TOKEN; do
  [[ -n "${!variable:-}" ]] || fail "runtime environment is missing $variable"
done

temp_root="$(mktemp -d "${TMPDIR:-/tmp}/domotic-passphrase-rollover.XXXXXX")"
cleanup() {
  rm -rf -- "$temp_root"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

cp -R "$source_root/infra" "$temp_root/infra-normal"
cp -R "$source_root/infra" "$temp_root/infra-to-rollover"
cp -R "$source_root/infra" "$temp_root/infra-from-rollover"
cp -R "$source_root/bootstrap" "$temp_root/bootstrap-to-rollover"
cp -R "$source_root/bootstrap" "$temp_root/bootstrap-from-rollover"
cp "$source_root/scripts/encryption-rollover/main-to-rollover.tf" \
  "$temp_root/infra-to-rollover/backend.tf"
cp "$source_root/scripts/encryption-rollover/main-from-rollover.tf" \
  "$temp_root/infra-from-rollover/backend.tf"
cp "$source_root/scripts/encryption-rollover/bootstrap-to-rollover.tf" \
  "$temp_root/bootstrap-to-rollover/backend.tf"
cp "$source_root/scripts/encryption-rollover/bootstrap-from-rollover.tf" \
  "$temp_root/bootstrap-from-rollover/backend.tf"
cp "$bootstrap_state_file" "$temp_root/bootstrap.tfstate"

init_main_backend() {
  local infra_dir="$1"
  local data_dir="$2"
  TF_DATA_DIR="$data_dir" tofu -chdir="$infra_dir" init \
    -input=false -reconfigure \
    -backend-config="bucket=${DOMOTIC_STATE_BUCKET}" \
    -backend-config="key=${DOMOTIC_STATE_KEY}" \
    -backend-config="region=auto" \
    -backend-config="endpoints={s3=\"${DOMOTIC_R2_ENDPOINT}\"}" \
    -backend-config="skip_credentials_validation=true" \
    -backend-config="skip_metadata_api_check=true" \
    -backend-config="skip_region_validation=true" \
    -backend-config="skip_requesting_account_id=true" \
    -backend-config="skip_s3_checksum=true" \
    -backend-config="use_path_style=true" \
    -backend-config="use_lockfile=true" >/dev/null
}

probe_main_with_normal_key() {
  local passphrase="$1"
  local data_dir="$2"

  export TF_VAR_state_passphrase="$passphrase"
  unset TF_VAR_previous_state_passphrase
  init_main_backend "$temp_root/infra-normal" "$data_dir" &&
    TF_DATA_DIR="$data_dir" tofu -chdir="$temp_root/infra-normal" \
      state pull >/dev/null
}

probe_main_with_rollover_key() {
  local data_dir="$1"

  export TF_VAR_state_passphrase="$new_passphrase"
  export TF_VAR_previous_state_passphrase="$old_passphrase"
  init_main_backend "$temp_root/infra-to-rollover" "$data_dir" &&
    TF_DATA_DIR="$data_dir" tofu -chdir="$temp_root/infra-to-rollover" \
      state pull >/dev/null
}

roll_main_state() {
  local infra_dir="$1"
  local previous_passphrase="$2"
  local data_dir="$3"

  export TF_VAR_state_passphrase="$new_passphrase"
  export TF_VAR_previous_state_passphrase="$previous_passphrase"
  init_main_backend "$infra_dir" "$data_dir"
  TF_DATA_DIR="$data_dir" tofu -chdir="$infra_dir" apply \
    -refresh-only -input=false -auto-approve -var-file="$tofu_vars_file" >/dev/null
}

# Detect the durable state left by either a previous interrupted run or the
# normal configuration. State contents are discarded and never printed.
if probe_main_with_normal_key \
  "$new_passphrase" "$temp_root/data-main-probe-final" 2>/dev/null; then
  main_rotation_stage=complete
elif probe_main_with_normal_key \
  "$old_passphrase" "$temp_root/data-main-probe-original" 2>/dev/null; then
  main_rotation_stage=original
elif probe_main_with_rollover_key \
  "$temp_root/data-main-probe-rollover" 2>/dev/null; then
  main_rotation_stage=rollover
else
  fail "main state is missing or cannot be decrypted with the supplied passphrases"
fi

if [[ "$main_rotation_stage" == original ]]; then
  roll_main_state \
    "$temp_root/infra-to-rollover" "$old_passphrase" \
    "$temp_root/data-main-rollover"
fi
if [[ "$main_rotation_stage" != complete ]]; then
  roll_main_state \
    "$temp_root/infra-from-rollover" "$new_passphrase" \
    "$temp_root/data-main-final"
  probe_main_with_normal_key \
    "$new_passphrase" "$temp_root/data-main-verify" >/dev/null
fi

roll_bootstrap_state() {
  local bootstrap_dir="$1"
  local previous_passphrase="$2"
  local data_dir="$3"

  export TF_VAR_state_passphrase="$new_passphrase"
  export TF_VAR_previous_state_passphrase="$previous_passphrase"
  export TF_VAR_cloudflare_api_token="$CLOUDFLARE_API_TOKEN"
  TF_DATA_DIR="$data_dir" tofu -chdir="$bootstrap_dir" init \
    -input=false -reconfigure \
    -backend-config="path=$temp_root/bootstrap.tfstate" >/dev/null
  TF_DATA_DIR="$data_dir" tofu -chdir="$bootstrap_dir" apply \
    -refresh-only -input=false -auto-approve \
    -var-file="$bootstrap_vars_file" >/dev/null
}

# Rotate a copy so interruption cannot leave the tracked bootstrap state using
# an alias the normal configuration cannot read.
roll_bootstrap_state \
  "$temp_root/bootstrap-to-rollover" "$old_passphrase" \
  "$temp_root/data-bootstrap-rollover"
roll_bootstrap_state \
  "$temp_root/bootstrap-from-rollover" "$new_passphrase" \
  "$temp_root/data-bootstrap-final"

TF_VAR_state_passphrase="$new_passphrase" \
TF_DATA_DIR="$temp_root/data-bootstrap-verify" \
  tofu -chdir="$source_root/bootstrap" init -input=false -reconfigure \
  -backend-config="path=$temp_root/bootstrap.tfstate" >/dev/null
TF_VAR_state_passphrase="$new_passphrase" \
TF_DATA_DIR="$temp_root/data-bootstrap-verify" \
  tofu -chdir="$source_root/bootstrap" output -json runtime >/dev/null

mv -f "$temp_root/bootstrap.tfstate" "$bootstrap_state_file"

unset TF_VAR_previous_state_passphrase
export TF_VAR_state_passphrase="$new_passphrase"
unset new_passphrase old_passphrase

printf '%s\n' 'Both OpenTofu states now use the new recovery passphrase.'
printf 'Review and commit %s.\n' "$bootstrap_state_file"
