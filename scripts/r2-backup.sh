#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(dirname "$script_dir")"
config_dir="${CONFIG_DIR:-$repository_root}"
[[ "$config_dir" == /* ]] || config_dir="$repository_root/$config_dir"
backup_env_file="${BACKUP_ENV_FILE:-$config_dir/backup.env}"
[[ "$backup_env_file" == /* ]] || backup_env_file="$config_dir/$backup_env_file"

if [[ -f "$backup_env_file" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$backup_env_file"
  set +a
fi

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

require_variable() {
  [[ -n "${!1:-}" ]] || fail "set $1 in $backup_env_file or the environment"
}

resolve_config_path() {
  local configured_path="$1"
  local legacy_base="$2"

  if [[ "$configured_path" == /* ]]; then
    printf '%s\n' "$configured_path"
  elif [[ -e "$config_dir/$configured_path" ]]; then
    printf '%s\n' "$config_dir/$configured_path"
  elif [[ -e "$legacy_base/$configured_path" ]]; then
    printf '%s\n' "$legacy_base/$configured_path"
  else
    printf '%s\n' "$config_dir/$configured_path"
  fi
}

configure_r2() {
  require_command aws
  require_variable R2_BUCKET
  require_variable R2_ACCESS_KEY_ID
  require_variable R2_SECRET_ACCESS_KEY

  if [[ -n "${R2_ENDPOINT:-}" ]]; then
    r2_endpoint="$R2_ENDPOINT"
  else
    require_variable R2_ACCOUNT_ID
    r2_endpoint="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
  fi

  r2_prefix="${R2_PREFIX:-domotic}"
  r2_prefix="${r2_prefix#/}"
  r2_prefix="${r2_prefix%/}"
  [[ -n "$r2_prefix" ]] || fail "R2_PREFIX cannot be empty"
}

r2_aws() {
  env \
    AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
    AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
    AWS_REGION=auto \
    AWS_DEFAULT_REGION=auto \
    AWS_EC2_METADATA_DISABLED=true \
    AWS_PAGER= \
    aws --endpoint-url "$r2_endpoint" "$@"
}

make_backup() {
  require_command age
  require_command kubectl
  require_command tar
  require_command terraform
  require_variable R2_AGE_RECIPIENT

  local terraform_vars_path
  local terraform_keys_path
  local helm_values_path
  local values_path

  terraform_vars_path="$(resolve_config_path "${TF_VARS_FILE:-infra/terraform.tfvars}" "$repository_root/infra")"
  terraform_keys_path="$(resolve_config_path "${TF_KEYS_FILE:-infra/zigbee-keys.tfvars.json}" "$repository_root/infra")"
  helm_values_path="$(resolve_config_path "${HELM_VALUES_FILE:-infra/helm-values.yaml}" "$repository_root/infra")"
  values_path="$(resolve_config_path "${VALUES_FILE:-values.yaml}" "$repository_root")"

  [[ -f "$terraform_vars_path" ]] ||
    fail "missing Terraform variables file: $terraform_vars_path"
  [[ -f "$values_path" ]] || fail "missing Helm values file: $values_path"

  local app_namespace
  local git_revision
  local timestamp
  local temp_root
  local payload_dir
  local archive_path
  local encrypted_path
  local object_key

  app_namespace="$(terraform -chdir="$repository_root/infra" output -raw kubernetes_namespace)"
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  git_revision="$(git -C "$repository_root" rev-parse --verify HEAD 2>/dev/null || printf unknown)"
  temp_root="$(mktemp -d "${TMPDIR:-/tmp}/domotic-backup.XXXXXX")"
  payload_dir="$temp_root/payload"
  archive_path="$temp_root/domotic-$timestamp.tar.gz"
  encrypted_path="$archive_path.age"
  object_key="$r2_prefix/domotic-$timestamp-${git_revision:0:12}.tar.gz.age"

  cleanup() {
    rm -rf -- "$temp_root"
  }
  trap cleanup EXIT
  trap 'exit 130' HUP INT TERM

  umask 077
  mkdir -p "$payload_dir/infra" "$payload_dir/kubernetes"

  cp "$terraform_vars_path" "$payload_dir/infra/$(basename "$terraform_vars_path")"
  cp "$values_path" "$payload_dir/values.yaml"
  if [[ -f "$terraform_keys_path" ]]; then
    cp "$terraform_keys_path" "$payload_dir/infra/$(basename "$terraform_keys_path")"
  fi
  if [[ -f "$helm_values_path" ]]; then
    cp "$helm_values_path" "$payload_dir/infra/$(basename "$helm_values_path")"
  fi

  terraform -chdir="$repository_root/infra" state pull > "$payload_dir/infra/terraform.tfstate"

  kubectl \
    --kubeconfig "${KUBE_CONFIG_PATH:-$HOME/.kube/config}" \
    --context "${KUBE_CTX:-domotic}" \
    --namespace "$app_namespace" \
    get secret zigbee-keys -o json > "$payload_dir/kubernetes/zigbee-keys.json"
  kubectl \
    --kubeconfig "${KUBE_CONFIG_PATH:-$HOME/.kube/config}" \
    --context "${KUBE_CTX:-domotic}" \
    --namespace "$app_namespace" \
    get configmap zigbee-network -o json > "$payload_dir/kubernetes/zigbee-network.json"
  kubectl \
    --kubeconfig "${KUBE_CONFIG_PATH:-$HOME/.kube/config}" \
    --context "${KUBE_CTX:-domotic}" \
    --namespace "$app_namespace" \
    get secret cloudflared-tunnel-token -o json > "$payload_dir/kubernetes/cloudflared-tunnel-token.json"
  if kubectl \
    --kubeconfig "${KUBE_CONFIG_PATH:-$HOME/.kube/config}" \
    --context "${KUBE_CTX:-domotic}" \
    --namespace "$app_namespace" \
    get secret homeassistant-r2-credentials >/dev/null 2>&1; then
    kubectl \
      --kubeconfig "${KUBE_CONFIG_PATH:-$HOME/.kube/config}" \
      --context "${KUBE_CTX:-domotic}" \
      --namespace "$app_namespace" \
      get secret homeassistant-r2-credentials -o json > "$payload_dir/kubernetes/homeassistant-r2-credentials.json"
  fi
  if kubectl \
    --kubeconfig "${KUBE_CONFIG_PATH:-$HOME/.kube/config}" \
    --context "${KUBE_CTX:-domotic}" \
    --namespace "$app_namespace" \
    get secret homeassistant-backup-encryption >/dev/null 2>&1; then
    kubectl \
      --kubeconfig "${KUBE_CONFIG_PATH:-$HOME/.kube/config}" \
      --context "${KUBE_CTX:-domotic}" \
      --namespace "$app_namespace" \
      get secret homeassistant-backup-encryption -o json > "$payload_dir/kubernetes/homeassistant-backup-encryption.json"
  fi
  if kubectl \
    --kubeconfig "${KUBE_CONFIG_PATH:-$HOME/.kube/config}" \
    --context "${KUBE_CTX:-domotic}" \
    --namespace "$app_namespace" \
    get secret homeassistant-onboarding >/dev/null 2>&1; then
    kubectl \
      --kubeconfig "${KUBE_CONFIG_PATH:-$HOME/.kube/config}" \
      --context "${KUBE_CTX:-domotic}" \
      --namespace "$app_namespace" \
      get secret homeassistant-onboarding -o json > "$payload_dir/kubernetes/homeassistant-onboarding.json"
  fi

  printf '%s\n' \
    "created_at=$timestamp" \
    "git_revision=$git_revision" \
    "kube_context=${KUBE_CTX:-domotic}" \
    "kubernetes_namespace=$app_namespace" > "$payload_dir/MANIFEST"

  tar -C "$payload_dir" -czf "$archive_path" .
  age --recipient "$R2_AGE_RECIPIENT" --output "$encrypted_path" "$archive_path"

  r2_aws s3 cp \
    "$encrypted_path" \
    "s3://$R2_BUCKET/$object_key" \
    --only-show-errors
  r2_aws s3api head-object --bucket "$R2_BUCKET" --key "$object_key" >/dev/null

  printf 'Uploaded and verified encrypted backup:\n  s3://%s/%s\n' "$R2_BUCKET" "$object_key"
}

list_backups() {
  r2_aws s3 ls "s3://$R2_BUCKET/$r2_prefix/"
}

restore_backup() {
  require_command age
  require_command tar
  require_variable R2_AGE_IDENTITY_FILE

  local object_key="${1:-}"
  [[ -n "$object_key" ]] || fail "missing R2 object key"
  [[ "$object_key" != /* && "$object_key" != *"../"* ]] || fail "invalid R2 object key"
  if [[ "$object_key" != */* ]]; then
    object_key="$r2_prefix/$object_key"
  fi

  local identity_file="${R2_AGE_IDENTITY_FILE/#\~/$HOME}"
  [[ -f "$identity_file" ]] || fail "age identity file does not exist: $identity_file"

  local restore_name
  local destination
  local temp_root
  local encrypted_path
  local archive_path
  local archive_entry
  local normalized_entry

  restore_name="$(basename "$object_key" .tar.gz.age)"
  destination="${RESTORE_DIR:-$config_dir/restore/$restore_name}"
  [[ ! -e "$destination" ]] || fail "restore destination already exists: $destination"

  temp_root="$(mktemp -d "${TMPDIR:-/tmp}/domotic-restore.XXXXXX")"
  encrypted_path="$temp_root/backup.tar.gz.age"
  archive_path="$temp_root/backup.tar.gz"

  cleanup() {
    rm -rf -- "$temp_root"
  }
  trap cleanup EXIT
  trap 'exit 130' HUP INT TERM

  umask 077
  r2_aws s3 cp \
    "s3://$R2_BUCKET/$object_key" \
    "$encrypted_path" \
    --only-show-errors
  age --decrypt --identity "$identity_file" --output "$archive_path" "$encrypted_path"

  while IFS= read -r archive_entry; do
    normalized_entry="${archive_entry#./}"
    [[ "$normalized_entry" != /* && "$normalized_entry" != ../* && "$normalized_entry" != *"/../"* ]] ||
      fail "unsafe path in backup archive: $archive_entry"
  done < <(tar -tzf "$archive_path")

  mkdir -p "$destination"
  chmod 0700 "$destination"
  tar -C "$destination" -xzf "$archive_path"

  printf 'Decrypted backup into:\n  %s\n' "$destination"
  printf 'No active configuration or Terraform state was overwritten.\n'
}

usage() {
  cat <<'EOF'
Usage:
  r2-backup.sh backup
  r2-backup.sh list
  r2-backup.sh restore <object-key>
EOF
}

configure_r2

case "${1:-}" in
  backup)
    make_backup
    ;;
  list)
    list_backups
    ;;
  restore)
    restore_backup "${2:-}"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
