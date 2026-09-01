#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

values_file="${1:-}"
version="${2:-}"

[[ -n "$values_file" ]] || fail "missing values file"
[[ -n "$version" ]] || fail "missing Home Assistant version"
[[ "$version" =~ ^[0-9]{4}\.[0-9]{1,2}\.[0-9]+$ ]] ||
  fail "Home Assistant version must be an exact stable tag such as 2026.8.3"
[[ -f "$values_file" ]] || fail "values file does not exist: $values_file"
[[ ! -L "$values_file" ]] || fail "refusing a symlinked values file: $values_file"

temporary_file="$(mktemp "${values_file}.tmp.XXXXXX")"
trap 'rm -f "$temporary_file"' EXIT

if ! awk -v version="$version" '
  BEGIN {
    in_homeassistant = 0
    in_image = 0
    homeassistant_sections = 0
    image_sections = 0
    replacements = 0
  }

  /^[^[:space:]#][^:]*:/ {
    in_homeassistant = ($0 ~ /^homeassistant:[[:space:]]*(#.*)?$/)
    in_image = 0
    if (in_homeassistant) {
      homeassistant_sections++
    }
  }

  in_homeassistant && /^  [^[:space:]#][^:]*:/ {
    in_image = ($0 ~ /^  image:[[:space:]]*(#.*)?$/)
    if (in_image) {
      image_sections++
    }
  }

  in_homeassistant && in_image && /^    tag:[[:space:]]*/ {
    comment = $0
    sub(/^[^#]*/, "", comment)
    printf "    tag: \"%s\"", version
    if (comment != "") {
      printf "  %s", comment
    }
    printf "\n"
    replacements++
    next
  }

  { print }

  END {
    if (homeassistant_sections != 1 || image_sections != 1 || replacements != 1) {
      exit 42
    }
  }
' "$values_file" > "$temporary_file"; then
  fail "expected exactly one homeassistant.image.tag in $values_file"
fi

mode="$(stat -f '%Lp' "$values_file" 2>/dev/null || stat -c '%a' "$values_file")"
chmod "$mode" "$temporary_file"
mv "$temporary_file" "$values_file"
trap - EXIT
