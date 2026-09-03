#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

canonical_path() {
  local path="$1"
  local parent
  local name

  parent="$(dirname "$path")"
  name="$(basename "$path")"
  [[ -d "$parent" ]] || fail "parent directory does not exist: $parent"
  printf '%s/%s\n' "$(cd "$parent" && pwd -P)" "$name"
}

config_dir="${1:-}"
bootstrap_vars_file="${2:-}"
bootstrap_state_file="${3:-}"
tofu_vars_file="${4:-}"
values_file="${5:-}"
helm_values_file="${6:-}"

[[ -n "$config_dir" ]] || fail "missing configuration directory"
[[ -n "$helm_values_file" ]] || fail "missing generated Helm values path"
[[ -d "$config_dir" ]] || fail "configuration directory does not exist: $config_dir"
config_dir="$(cd "$config_dir" && pwd -P)"
bootstrap_vars_file="$(canonical_path "$bootstrap_vars_file")"
bootstrap_state_file="$(canonical_path "$bootstrap_state_file")"
tofu_vars_file="$(canonical_path "$tofu_vars_file")"
values_file="$(canonical_path "$values_file")"
helm_values_file="$(canonical_path "$helm_values_file")"

[[ -f "$bootstrap_vars_file" ]] || fail "missing bootstrap variables file: $bootstrap_vars_file"
[[ -f "$bootstrap_state_file" ]] || fail "missing encrypted bootstrap state; run task bootstrap first"
[[ -f "$tofu_vars_file" ]] || fail "missing OpenTofu variables file: $tofu_vars_file"
[[ -f "$values_file" ]] || fail "missing Helm values file: $values_file"

git_root="$(git -C "$config_dir" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$git_root" ]] || fail "configuration directory must be inside a Git repository"

tracked_path() {
  local path="$1"
  local relative_path

  [[ "$path" == "$git_root"/* ]] || return 1
  relative_path="${path#"$git_root"/}"
  git -C "$git_root" ls-files --error-unmatch -- "$relative_path" >/dev/null 2>&1
}

check_private_file() {
  local path="$1"
  local label="$2"
  local mode

  [[ -e "$path" ]] || return 0
  tracked_path "$path" && fail "$label must not be tracked in Git: $path"

  if [[ -f "$path" ]]; then
    mode="$(stat -f '%Lp' "$path" 2>/dev/null || stat -c '%a' "$path")"
    (( (8#$mode & 0177) == 0 )) ||
      fail "$label must use owner-only, non-executable permissions: $path"
  fi
}

tracked_path "$bootstrap_vars_file" ||
  fail "bootstrap variables must be tracked in Git: $bootstrap_vars_file"
tracked_path "$bootstrap_state_file" ||
  fail "encrypted bootstrap state must be tracked in Git: $bootstrap_state_file"
tracked_path "$tofu_vars_file" ||
  fail "OpenTofu variables must be tracked in Git: $tofu_vars_file"
tracked_path "$values_file" ||
  fail "Helm values must be tracked in Git: $values_file"

grep -Eq '"encrypted_data"[[:space:]]*:' "$bootstrap_state_file" ||
  fail "bootstrap state is not an OpenTofu-encrypted state file"
if grep -Fq 'CLOUDFLARE_API_TOKEN' "$bootstrap_state_file"; then
  fail "bootstrap state contains a plaintext Cloudflare credential"
fi

if grep -E -q '^[[:space:]]*(cloudflare_api_token|state_passphrase)([[:space:]]|=|$)' \
  "$bootstrap_vars_file"; then
  fail "bootstrap variables must not contain credentials or the recovery passphrase"
fi

if grep -E -q '^[[:space:]]*(cloudflare_api_token|state_passphrase|r2_backup_credentials|homeassistant_admin_password_override)([[:space:]]|=|$)' \
  "$tofu_vars_file"; then
  fail "tracked OpenTofu variables contain a runtime credential"
fi

check_private_file "$helm_values_file" "generated Helm values"
check_private_file "$config_dir/secrets.yaml" "legacy plaintext secrets file"
check_private_file "$config_dir/infra/zigbee-keys.tfvars.json" "legacy Zigbee identity file"

restore_dir="$config_dir/restore"
if [[ "$restore_dir" == "$git_root"/* ]]; then
  restore_relative="${restore_dir#"$git_root"/}"
  if [[ -n "$(git -C "$git_root" ls-files -- "$restore_relative")" ]]; then
    fail "restored backup material must not be tracked in Git: $restore_dir"
  fi
fi

printf 'Private deployment configuration passed safety checks.\n'
