#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: secret-reference.sh <get|set|delete> <reference>

Supported references:
  keychain://ACCOUNT/SERVICE    macOS Keychain generic password
  op://VAULT/ITEM/FIELD         1Password secret reference
  env://VARIABLE                environment variable
  sops://PATH#KEY               top-level key in a SOPS document

Only keychain:// references support set and delete.
EOF
}

action="${1:-}"
reference="${2:-}"
[[ -n "$action" && -n "$reference" ]] || {
  usage >&2
  exit 2
}

case "$action" in
  get|set|delete) ;;
  *) usage >&2; exit 2 ;;
esac

[[ "$reference" == *://* ]] || fail "secret reference must include a URI scheme"
scheme="${reference%%://*}"
payload="${reference#*://}"

case "$scheme" in
  keychain)
    command -v security >/dev/null 2>&1 ||
      fail "keychain:// references require the macOS security command"
    [[ "$payload" == */* ]] ||
      fail "keychain reference must be keychain://ACCOUNT/SERVICE"
    account="${payload%%/*}"
    service="${payload#*/}"
    [[ "$account" =~ ^[A-Za-z0-9._-]+$ && "$service" =~ ^[A-Za-z0-9._-]+$ ]] ||
      fail "Keychain account and service must use letters, digits, dot, underscore, or hyphen"
    case "$action" in
      get)
        security find-generic-password -a "$account" -s "$service" -w
        ;;
      set)
        printf 'Store Keychain service %s for account %s.\n' "$service" "$account" >&2
        printf 'The security tool will prompt without echoing the value.\n' >&2
        security add-generic-password -U \
          -a "$account" \
          -s "$service" \
          -l "Domotic $account $service" \
          -w
        ;;
      delete)
        security delete-generic-password -a "$account" -s "$service"
        ;;
    esac
    ;;
  op)
    [[ "$action" == get ]] ||
      fail "manage op:// values with 1Password; only get is supported here"
    command -v op >/dev/null 2>&1 || fail "op:// references require the 1Password CLI"
    exec op read "$reference"
    ;;
  env)
    [[ "$action" == get ]] ||
      fail "env:// references cannot be changed by a child process"
    [[ "$payload" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
      fail "invalid environment variable in secret reference"
    value="${!payload:-}"
    [[ -n "$value" ]] || fail "required environment variable is not set: $payload"
    printf '%s' "$value"
    ;;
  sops)
    [[ "$action" == get ]] ||
      fail "edit sops:// values with SOPS; only get is supported here"
    command -v sops >/dev/null 2>&1 || fail "sops:// references require SOPS"
    command -v jq >/dev/null 2>&1 || fail "sops:// references require jq"
    [[ "$payload" == *#* ]] || fail "SOPS reference must be sops://PATH#KEY"
    sops_file="${payload%%#*}"
    sops_key="${payload#*#}"
    [[ -n "$sops_file" && -f "$sops_file" ]] ||
      fail "SOPS document does not exist: $sops_file"
    [[ "$sops_key" =~ ^[A-Za-z0-9_.-]+$ ]] || fail "invalid top-level SOPS key"
    sops decrypt --output-type json "$sops_file" |
      jq -er --arg key "$sops_key" '.[$key] | select(type == "string" and length > 0)'
    ;;
  passwords)
    fail "passwords:// is not supported; use keychain:// for macOS Keychain"
    ;;
  *)
    fail "unsupported secret reference scheme: $scheme"
    ;;
esac
