#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: dev-sync-custom-integrations.sh SOURCE KUBE_CONTEXT [NAMESPACE] [INSTANCE]

SOURCE may be an integration repository, a custom_components directory, or a
single integration directory containing manifest.json.
EOF
}

[[ $# -ge 2 && $# -le 4 ]] || {
  usage >&2
  exit 2
}

source_path="$1"
kube_context="$2"
namespace_filter="${3:-}"
instance_filter="${4:-}"

command -v kubectl >/dev/null 2>&1 || fail "kubectl is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v tar >/dev/null 2>&1 || fail "tar is required"
[[ -d "$source_path" ]] || fail "source directory does not exist: $source_path"

source_path="$(cd -- "$source_path" && pwd -P)"
component_directories=()

if [[ -f "$source_path/manifest.json" ]]; then
  components_root="$(dirname -- "$source_path")"
  component_directories+=("$source_path")
elif [[ -d "$source_path/custom_components" ]]; then
  components_root="$source_path/custom_components"
else
  components_root="$source_path"
fi

if [[ ${#component_directories[@]} -eq 0 ]]; then
  shopt -s nullglob
  for candidate in "$components_root"/*; do
    if [[ -d "$candidate" && -f "$candidate/manifest.json" ]]; then
      component_directories+=("$candidate")
    fi
  done
  shopt -u nullglob
fi

[[ ${#component_directories[@]} -gt 0 ]] ||
  fail "no integration manifests found below $source_path"

domains=()
for component_directory in "${component_directories[@]}"; do
  if find "$component_directory" -type l -print -quit | grep -q .; then
    fail "integration source contains a symbolic link: $component_directory"
  fi

  domain="$(
    jq -er '
      .domain
      | select(type == "string")
      | select(test("^[a-z][a-z0-9_]{0,49}$"))
    ' "$component_directory/manifest.json" 2>/dev/null
  )" || fail "manifest has an invalid Home Assistant domain: $component_directory"

  directory_name="$(basename -- "$component_directory")"
  [[ "$directory_name" == "$domain" ]] ||
    fail "manifest domain $domain does not match directory $directory_name"

  if printf '%s\n' "${domains[@]:-}" | grep -Fxq "$domain"; then
    fail "duplicate integration domain: $domain"
  fi
  domains+=("$domain")
done

temp_directory="$(mktemp -d "${TMPDIR:-/tmp}/domotic-integration-sync.XXXXXX")"
cleanup() {
  rm -rf -- "$temp_directory"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

deployments_file="$temp_directory/deployments.json"
kubectl --context "$kube_context" get deployments --all-namespaces \
  --selector app.kubernetes.io/name=homeassistant -o json > "$deployments_file"

matching_deployments="$(
  jq -c \
    --arg namespace "$namespace_filter" \
    --arg instance "$instance_filter" \
    '[
      .items[]
      | select($namespace == "" or .metadata.namespace == $namespace)
      | select(
          $instance == ""
          or .metadata.labels["app.kubernetes.io/instance"] == $instance
        )
    ]' "$deployments_file"
)"
deployment_count="$(jq 'length' <<<"$matching_deployments")"

if [[ "$deployment_count" != 1 ]]; then
  printf 'Matching Home Assistant deployments:\n' >&2
  jq -r '.[] | "  \(.metadata.namespace)/\(.metadata.name)"' \
    <<<"$matching_deployments" >&2
  fail "expected exactly one Home Assistant deployment, found $deployment_count"
fi

namespace="$(jq -r '.[0].metadata.namespace' <<<"$matching_deployments")"
deployment="$(jq -r '.[0].metadata.name' <<<"$matching_deployments")"
deployment_selector="$(
  jq -r '
    .[0].spec.selector.matchLabels
    | to_entries
    | sort_by(.key)
    | map("\(.key)=\(.value)")
    | join(",")
  ' <<<"$matching_deployments"
)"
[[ -n "$deployment_selector" ]] || fail "Home Assistant deployment has no label selector"

container_count="$(
  jq '[.[0].spec.template.spec.containers[] | select(.name == "homeassistant")] | length' \
    <<<"$matching_deployments"
)"
[[ "$container_count" == 1 ]] ||
  fail "deployment $namespace/$deployment has no unique homeassistant container"

for domain in "${domains[@]}"; do
  target="/config/custom_components/$domain"
  managed_mount_count="$(
    jq \
      --arg target "$target" \
      '[
        .[0].spec.template.spec.containers[]
        | select(.name == "homeassistant")
        | .volumeMounts[]?
        | select(
            .readOnly == true
            and (.mountPath == $target or .mountPath == "/config/custom_components")
          )
      ]
      | length' <<<"$matching_deployments"
  )"
  [[ "$managed_mount_count" == 0 ]] ||
    fail "$domain is mounted read-only by the deployment; remove it from Helm values first"
done

kubectl --context "$kube_context" --namespace "$namespace" \
  rollout status "deployment/$deployment" --timeout=5m

pods_file="$temp_directory/pods.json"
kubectl --context "$kube_context" --namespace "$namespace" get pods \
  --selector "$deployment_selector" -o json > "$pods_file"
pod="$(
  jq -r '
    [
      .items[]
      | select(.metadata.deletionTimestamp == null)
      | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
    ]
    | sort_by(.metadata.creationTimestamp)
    | last
    | .metadata.name // empty
  ' "$pods_file"
)"
[[ -n "$pod" ]] || fail "no ready Home Assistant pod found for $namespace/$deployment"

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
stage="/config/.domotic-local-integrations/staging/$run_id"
backup="/config/.domotic-local-integrations/backups/$run_id"

kubectl --context "$kube_context" --namespace "$namespace" \
  exec "$pod" --container homeassistant -- \
  install -d -m 0755 "$stage" "$backup" /config/custom_components

COPYFILE_DISABLE=1 tar \
  --exclude='*/__pycache__' \
  --exclude='*/__pycache__/*' \
  --exclude='*.pyc' \
  --exclude='._*' \
  --exclude='.DS_Store' \
  -C "$components_root" -cf - "${domains[@]}" |
  kubectl --context "$kube_context" --namespace "$namespace" \
    exec -i "$pod" --container homeassistant -- tar -C "$stage" -xf -

kubectl --context "$kube_context" --namespace "$namespace" \
  exec "$pod" --container homeassistant -- sh -eu -c '
    stage=$1
    backup=$2
    shift 2

    test ! -L /config/custom_components
    for domain do
      case "$domain" in
        ""|*[!a-z0-9_]* ) exit 2 ;;
      esac
      target="/config/custom_components/$domain"
      test ! -L "$target"
      test -f "$stage/$domain/manifest.json"
    done

    for domain do
      target="/config/custom_components/$domain"
      if test -e "$target"; then
        mv "$target" "$backup/$domain"
      fi
      if ! mv "$stage/$domain" "$target"; then
        if test -e "$backup/$domain"; then
          mv "$backup/$domain" "$target"
        fi
        exit 1
      fi
    done
    rmdir "$stage"
  ' sh "$stage" "$backup" "${domains[@]}"

kubectl --context "$kube_context" --namespace "$namespace" \
  rollout restart "deployment/$deployment"
if ! kubectl --context "$kube_context" --namespace "$namespace" \
  rollout status "deployment/$deployment" --timeout=5m; then
  fail "Home Assistant rollout failed; previous files remain at $backup"
fi

kubectl --context "$kube_context" --namespace "$namespace" get pods \
  --selector "$deployment_selector" -o json > "$pods_file"
pod="$(
  jq -r '
    [
      .items[]
      | select(.metadata.deletionTimestamp == null)
      | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
    ]
    | sort_by(.metadata.creationTimestamp)
    | last
    | .metadata.name // empty
  ' "$pods_file"
)"
[[ -n "$pod" ]] || fail "Home Assistant rolled out without a ready pod"

kubectl --context "$kube_context" --namespace "$namespace" \
  exec -i "$pod" --container homeassistant -- \
  python3 - "${domains[@]}" <<'PY'
import importlib
import json
import sys
from pathlib import Path

sys.path.insert(0, "/config")
for domain in sys.argv[1:]:
    manifest = json.loads(
        Path(f"/config/custom_components/{domain}/manifest.json").read_text()
    )
    if manifest.get("domain") != domain:
        raise RuntimeError(f"installed manifest does not match {domain}")
    importlib.import_module(f"custom_components.{domain}")
    if manifest.get("config_flow"):
        importlib.import_module(f"custom_components.{domain}.config_flow")
    print(f"Synced {domain} {manifest.get('version', 'unversioned')}")
PY

printf 'Previous integration files, if any, are preserved at %s.\n' "$backup"
