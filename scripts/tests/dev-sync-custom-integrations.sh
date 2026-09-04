#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "$script_dir/../.." && pwd)"
temp_root="$(mktemp -d "${TMPDIR:-/tmp}/domotic-integration-sync-test.XXXXXX")"

cleanup() {
  rm -rf -- "$temp_root"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

fail() {
  printf 'Test failed: %s\n' "$*" >&2
  exit 1
}

install -d -m 0700 \
  "$temp_root/bin" \
  "$temp_root/config/custom_components/example_integration" \
  "$temp_root/source/custom_components/example_integration"

printf '%s\n' '{"domain":"example_integration","config_flow":true,"version":"1.2.3"}' \
  > "$temp_root/source/custom_components/example_integration/manifest.json"
printf '%s\n' 'VALUE = "new"' \
  > "$temp_root/source/custom_components/example_integration/__init__.py"
printf '%s\n' 'FLOW = "available"' \
  > "$temp_root/source/custom_components/example_integration/config_flow.py"
printf '%s\n' 'ignored' \
  > "$temp_root/source/custom_components/example_integration/._metadata"
install -d "$temp_root/source/custom_components/example_integration/__pycache__"
printf '%s\n' 'ignored' \
  > "$temp_root/source/custom_components/example_integration/__pycache__/cache.pyc"
printf '%s\n' 'VALUE = "old"' \
  > "$temp_root/config/custom_components/example_integration/old.py"

cat > "$temp_root/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

map_path() {
  case "$1" in
    /config*) printf '%s%s' "$FAKE_CONFIG_ROOT" "${1#/config}" ;;
    *) printf '%s' "$1" ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context | --namespace)
      shift 2
      ;;
    *)
      break
      ;;
  esac
done

command_name="${1:-}"
shift || true
case "$command_name" in
  get)
    resource="${1:-}"
    if [[ "$resource" == deployments ]]; then
      extra_mount=''
      if [[ "${FAKE_READ_ONLY:-false}" == true ]]; then
        extra_mount=',{"mountPath":"/config/custom_components/example_integration","readOnly":true}'
      fi
      cat <<JSON
{"items":[{"metadata":{"namespace":"test","name":"test-homeassistant","labels":{"app.kubernetes.io/instance":"test"}},"spec":{"selector":{"matchLabels":{"app.kubernetes.io/name":"homeassistant","app.kubernetes.io/instance":"test"}},"template":{"spec":{"containers":[{"name":"homeassistant","volumeMounts":[{"mountPath":"/config","readOnly":false}${extra_mount}]}]}}}}]}
JSON
    elif [[ "$resource" == pods ]]; then
      cat <<'JSON'
{"items":[{"metadata":{"name":"test-homeassistant-pod","creationTimestamp":"2026-01-01T00:00:00Z"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}
JSON
    else
      exit 2
    fi
    ;;
  rollout)
    printf '%s\n' "rollout $*" >> "$FAKE_KUBECTL_LOG"
    ;;
  exec)
    if [[ "${1:-}" == -i ]]; then
      shift
    fi
    shift
    if [[ "${1:-}" == --container ]]; then
      shift 2
    fi
    [[ "${1:-}" == -- ]] || exit 2
    shift

    case "${1:-}" in
      install | tar)
        mapped=()
        for argument in "$@"; do
          mapped+=("$(map_path "$argument")")
        done
        "${mapped[@]}"
        ;;
      sh)
        mapped=("$@")
        mapped[3]="${mapped[3]//\/config/$FAKE_CONFIG_ROOT}"
        for ((index = 4; index < ${#mapped[@]}; index++)); do
          mapped[$index]="$(map_path "${mapped[$index]}")"
        done
        "${mapped[@]}"
        ;;
      python3)
        python_script="$(cat)"
        python_script="${python_script//\/config/$FAKE_CONFIG_ROOT}"
        python3 - "${@:3}" <<<"$python_script"
        ;;
      *)
        exit 2
        ;;
    esac
    ;;
  *)
    exit 2
    ;;
esac
EOF
chmod 0700 "$temp_root/bin/kubectl"

PATH="$temp_root/bin:$PATH" \
FAKE_CONFIG_ROOT="$temp_root/config" \
FAKE_KUBECTL_LOG="$temp_root/kubectl.log" \
  "$repository_root/scripts/dev-sync-custom-integrations.sh" \
  "$temp_root/source" kind-test >/dev/null

[[ -f "$temp_root/config/custom_components/example_integration/__init__.py" ]] ||
  fail "new integration source was not installed"
[[ ! -e "$temp_root/config/custom_components/example_integration/old.py" ]] ||
  fail "stale integration source remained in the active directory"
[[ ! -e "$temp_root/config/custom_components/example_integration/._metadata" ]] ||
  fail "AppleDouble metadata was copied"
[[ ! -e "$temp_root/config/custom_components/example_integration/__pycache__/cache.pyc" ]] ||
  fail "source Python cache files were copied"
find "$temp_root/config/.domotic-local-integrations/backups" \
  -path '*/example_integration/old.py' -type f -print -quit | grep -q . ||
  fail "the previous integration source was not preserved"
grep -Fq 'rollout restart deployment/test-homeassistant' "$temp_root/kubectl.log" ||
  fail "Home Assistant was not restarted"

if PATH="$temp_root/bin:$PATH" \
  FAKE_CONFIG_ROOT="$temp_root/config" \
  FAKE_KUBECTL_LOG="$temp_root/kubectl.log" \
  FAKE_READ_ONLY=true \
    "$repository_root/scripts/dev-sync-custom-integrations.sh" \
    "$temp_root/source" kind-test >/dev/null 2>&1; then
  fail "a read-only chart-managed integration was replaced"
fi

install -d "$temp_root/mismatched/custom_components/wrong_directory"
printf '%s\n' '{"domain":"different_domain"}' \
  > "$temp_root/mismatched/custom_components/wrong_directory/manifest.json"
if PATH="$temp_root/bin:$PATH" \
  FAKE_CONFIG_ROOT="$temp_root/config" \
  FAKE_KUBECTL_LOG="$temp_root/kubectl.log" \
    "$repository_root/scripts/dev-sync-custom-integrations.sh" \
    "$temp_root/mismatched" kind-test >/dev/null 2>&1; then
  fail "a mismatched manifest domain was accepted"
fi

printf 'Local custom integration sync tests passed.\n'
