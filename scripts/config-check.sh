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
terraform_vars_file="${2:-}"
values_file="${3:-}"
terraform_keys_file="${4:-}"
helm_values_file="${5:-}"
backup_env_file="${6:-}"

[[ -n "$config_dir" ]] || fail "missing configuration directory"
[[ -d "$config_dir" ]] || fail "configuration directory does not exist: $config_dir"
config_dir="$(cd "$config_dir" && pwd -P)"
terraform_vars_file="$(canonical_path "$terraform_vars_file")"
values_file="$(canonical_path "$values_file")"
terraform_keys_file="$(canonical_path "$terraform_keys_file")"
helm_values_file="$(canonical_path "$helm_values_file")"
backup_env_file="$(canonical_path "$backup_env_file")"
[[ -f "$terraform_vars_file" ]] || fail "missing Terraform variables file: $terraform_vars_file"
[[ -f "$values_file" ]] || fail "missing Helm values file: $values_file"

git_root="$(git -C "$config_dir" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$git_root" ]] || fail "configuration directory must be inside a Git repository"

tracked_path() {
  local path="$1"
  local relative_path

  [[ -n "$git_root" && "$path" == "$git_root"/* ]] || return 1
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

if tracked_path "$terraform_vars_file" &&
  grep -E -q '^[[:space:]]*(cloudflare_api_token|homeassistant_onboarding)([[:space:]]|=|$)' "$terraform_vars_file"; then
  fail "tracked Terraform variables must obtain Cloudflare and Home Assistant credentials from a secret provider"
fi

check_private_file "$terraform_keys_file" "Zigbee identity file"
check_private_file "$helm_values_file" "generated Helm values"
check_private_file "$backup_env_file" "backup environment file"

restore_dir="$config_dir/restore"
if [[ "$restore_dir" == "$git_root"/* ]]; then
  restore_relative="${restore_dir#"$git_root"/}"
  if [[ -n "$(git -C "$git_root" ls-files -- "$restore_relative")" ]]; then
    fail "restored backup material must not be tracked in Git: $restore_dir"
  fi
fi

printf 'Private deployment configuration passed safety checks.\n'
