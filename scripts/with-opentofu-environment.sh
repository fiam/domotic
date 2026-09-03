#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage: with-opentofu-environment.sh MODE SOURCE_ROOT PRIVATE_ROOT CONFIG_DIR -- COMMAND [ARGUMENTS...]

MODE is bootstrap, rotate-cloudflare-token, or runtime.
EOF
  exit 2
}

read_hidden() {
  local prompt="$1"
  local value

  [[ -r /dev/tty ]] || fail "$prompt must be provided through the environment in a non-interactive session"
  IFS= read -r -s -p "$prompt: " value </dev/tty
  printf '\n' >/dev/tty
  printf '%s' "$value"
}

[[ $# -ge 6 ]] || usage
command -v tofu >/dev/null 2>&1 || fail "OpenTofu is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
mode="$1"
source_root="$2"
private_root="$3"
config_dir="$4"
shift 4
[[ "${1:-}" == "--" ]] || usage
shift
[[ $# -gt 0 ]] || usage

case "$mode" in
  bootstrap|rotate-cloudflare-token|runtime) ;;
  *) usage ;;
esac

bootstrap_vars_file="${BOOTSTRAP_VARS_FILE:-$config_dir/bootstrap.tfvars}"
bootstrap_state_file="${BOOTSTRAP_STATE_FILE:-$private_root/state/bootstrap.tfstate}"
bootstrap_data_dir="${BOOTSTRAP_TF_DATA_DIR:-$private_root/.domotic/tofu/bootstrap}"
main_data_dir="${MAIN_TF_DATA_DIR:-$private_root/.domotic/tofu/main}"

[[ -d "$source_root/bootstrap" ]] || fail "missing bootstrap OpenTofu root: $source_root/bootstrap"
[[ -f "$bootstrap_vars_file" ]] || fail "missing bootstrap configuration: $bootstrap_vars_file"
[[ ! -L "$bootstrap_state_file" ]] || fail "refusing a symlinked bootstrap state: $bootstrap_state_file"

recovery_passphrase="${DOMOTIC_RECOVERY_PASSPHRASE:-}"
if [[ -z "$recovery_passphrase" ]]; then
  recovery_passphrase="$(read_hidden 'Recovery passphrase')"
  if [[ ! -f "$bootstrap_state_file" ]]; then
    confirmation="$(read_hidden 'Confirm recovery passphrase')"
    [[ "$recovery_passphrase" == "$confirmation" ]] || fail "recovery passphrases do not match"
    unset confirmation
  fi
fi
(( ${#recovery_passphrase} >= 16 )) || fail "the recovery passphrase must contain at least 16 characters"

export TF_VAR_state_passphrase="$recovery_passphrase"
unset recovery_passphrase

read_bootstrap_runtime() {
  local runtime

  [[ -f "$bootstrap_state_file" ]] || fail "bootstrap state is missing; run task bootstrap first"
  install -d -m 0700 "$bootstrap_data_dir"
  TF_DATA_DIR="$bootstrap_data_dir" tofu -chdir="$source_root/bootstrap" \
    init -input=false -reconfigure \
    -backend-config="path=$bootstrap_state_file" >/dev/null
  runtime="$(
    TF_DATA_DIR="$bootstrap_data_dir" tofu -chdir="$source_root/bootstrap" \
      output -json runtime
  )"
  jq -e '
    (.cloudflare_api_token | type == "string" and length > 0) and
    (.cloudflare_account_id | test("^[0-9a-f]{32}$")) and
    (.endpoint | startswith("https://")) and
    (.state.bucket | type == "string" and length > 0) and
    (.state.key | type == "string" and length > 0) and
    (.state.access_key_id | type == "string" and length > 0) and
    (.state.secret_access_key | type == "string" and length > 0) and
    (.backups.bucket | type == "string" and length > 0) and
    (.backups.access_key_id | type == "string" and length > 0) and
    (.backups.secret_access_key | type == "string" and length > 0)
  ' <<<"$runtime" >/dev/null || fail "bootstrap state has an unexpected schema"
  printf '%s' "$runtime"
}

if [[ "$mode" == "bootstrap" || "$mode" == "rotate-cloudflare-token" ]]; then
  cloudflare_api_token="${CLOUDFLARE_API_TOKEN:-}"
  if [[ "$mode" == "rotate-cloudflare-token" ]]; then
    cloudflare_api_token="$(read_hidden 'New Cloudflare account API token')"
  elif [[ -z "$cloudflare_api_token" && -f "$bootstrap_state_file" ]]; then
    bootstrap_runtime="$(read_bootstrap_runtime)"
    cloudflare_api_token="$(jq -er '.cloudflare_api_token' <<<"$bootstrap_runtime")"
    unset bootstrap_runtime
  elif [[ -z "$cloudflare_api_token" ]]; then
    cloudflare_api_token="$(read_hidden 'Cloudflare account API token')"
  fi

  [[ -n "$cloudflare_api_token" ]] || fail "Cloudflare account API token cannot be empty"
  export CLOUDFLARE_API_TOKEN="$cloudflare_api_token"
  export TF_VAR_cloudflare_api_token="$cloudflare_api_token"
  export TF_DATA_DIR="$bootstrap_data_dir"
  unset cloudflare_api_token
  exec "$@"
fi

bootstrap_runtime="$(read_bootstrap_runtime)"
export CLOUDFLARE_API_TOKEN="$(jq -er '.cloudflare_api_token' <<<"$bootstrap_runtime")"
export TF_VAR_cloudflare_account_id="$(jq -er '.cloudflare_account_id' <<<"$bootstrap_runtime")"
export DOMOTIC_R2_ENDPOINT="$(jq -er '.endpoint' <<<"$bootstrap_runtime")"
export TF_VAR_r2_endpoint="$DOMOTIC_R2_ENDPOINT"
export DOMOTIC_STATE_BUCKET="$(jq -er '.state.bucket' <<<"$bootstrap_runtime")"
export DOMOTIC_STATE_KEY="$(jq -er '.state.key' <<<"$bootstrap_runtime")"
export AWS_ACCESS_KEY_ID="$(jq -er '.state.access_key_id' <<<"$bootstrap_runtime")"
export AWS_SECRET_ACCESS_KEY="$(jq -er '.state.secret_access_key' <<<"$bootstrap_runtime")"
export TF_VAR_r2_backup_bucket_name="$(jq -er '.backups.bucket' <<<"$bootstrap_runtime")"
export TF_VAR_r2_backup_credentials="$(
  jq -c '{
    access_key_id: .backups.access_key_id,
    secret_access_key: .backups.secret_access_key
  }' <<<"$bootstrap_runtime"
)"
export AWS_EC2_METADATA_DISABLED=true
export TF_DATA_DIR="$main_data_dir"
unset bootstrap_runtime

# The HashiCorp Kubernetes provider intentionally ignores KUBECONFIG. Bridge
# kubectl's standard setting (or its default path) to the provider-specific
# variables while preserving an explicit provider override.
if [[ -z "${KUBE_CONFIG_PATH:-}" && -z "${KUBE_CONFIG_PATHS:-}" ]]; then
  if [[ -n "${KUBECONFIG:-}" ]]; then
    export KUBE_CONFIG_PATHS="$KUBECONFIG"
  elif [[ -f "${HOME}/.kube/config" ]]; then
    export KUBE_CONFIG_PATH="${HOME}/.kube/config"
  fi
fi

exec "$@"
