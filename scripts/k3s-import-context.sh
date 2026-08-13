#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: $0 [--user SSH_USER] [--context NAME] <server-hostname>" >&2
  echo "Example: $0 --user fiam --context domotic automation-host.local" >&2
}

ssh_username=""
context_name=domotic
context_option_set=false
positional_arguments=()

while (( $# > 0 )); do
  case "$1" in
    --user)
      if (( $# < 2 )); then
        echo "Missing value for --user" >&2
        usage
        exit 2
      fi
      ssh_username="$2"
      shift 2
      ;;
    --context)
      if (( $# < 2 )); then
        echo "Missing value for --context" >&2
        usage
        exit 2
      fi
      context_name="$2"
      context_option_set=true
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      positional_arguments+=("$@")
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
    *)
      positional_arguments+=("$1")
      shift
      ;;
  esac
done

if (( ${#positional_arguments[@]} < 1 || ${#positional_arguments[@]} > 2 )); then
  usage
  exit 2
fi

server_host="${positional_arguments[0]}"
if (( ${#positional_arguments[@]} == 2 )); then
  if [[ "$context_option_set" == true ]]; then
    echo "Specify the context with either --context or a second positional argument, not both" >&2
    exit 2
  fi
  context_name="${positional_arguments[1]}"
fi

target_config="${HOME:?HOME is not set}/.kube/config"

if [[ ! "$server_host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
  echo "Invalid server hostname: $server_host" >&2
  exit 2
fi

if [[ ! "$context_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "Invalid context name: $context_name" >&2
  exit 2
fi

if [[ -n "$ssh_username" && ! "$ssh_username" =~ ^[A-Za-z0-9_.][A-Za-z0-9._-]*$ ]]; then
  echo "Invalid SSH username: $ssh_username" >&2
  exit 2
fi

ssh_target="$server_host"
if [[ -n "$ssh_username" ]]; then
  ssh_target="${ssh_username}@${server_host}"
fi

for required_command in install kubectl mktemp scp sed ssh; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "Required command not found: $required_command" >&2
    exit 1
  fi
done

install -d -m 0700 "$(dirname "$target_config")"

kube_merge_dir="$(mktemp -d "${TMPDIR:-/tmp}/domotic-kubeconfig.XXXXXX")"
remote_merge_dir=""

cleanup_remote_config() {
  if [[ -n "$remote_merge_dir" ]]; then
    ssh "$ssh_target" \
      "rm -f -- '$remote_merge_dir/k3s.yaml'; rmdir -- '$remote_merge_dir'" \
      </dev/null >/dev/null 2>&1 || true
    remote_merge_dir=""
  fi
}

cleanup() {
  cleanup_remote_config
  rm -rf -- "$kube_merge_dir"
}
trap cleanup EXIT HUP INT TERM

source_config="$kube_merge_dir/k3s.yaml"
import_config="$kube_merge_dir/$context_name.yaml"
merged_config="$kube_merge_dir/merged.yaml"

remote_merge_dir="$(
  ssh "$ssh_target" 'mktemp -d /tmp/domotic-kubeconfig.XXXXXX'
)"
if [[ ! "$remote_merge_dir" =~ ^/tmp/domotic-kubeconfig\.[A-Za-z0-9]+$ ]]; then
  echo "Unexpected temporary directory returned by $server_host" >&2
  exit 1
fi

# Allocate a terminal so sudo can prompt normally. Redirecting on the remote
# side keeps the prompt and terminal control bytes out of the kubeconfig.
ssh -t "$ssh_target" \
  "umask 077; sudo cat /etc/rancher/k3s/k3s.yaml > '$remote_merge_dir/k3s.yaml'"
scp -q "$ssh_target:$remote_merge_dir/k3s.yaml" "$source_config"
cleanup_remote_config
chmod 0600 "$source_config"

# k3s names its cluster, user, and context "default". Rename both list entries
# ("- name: default") and their references before merging so they cannot
# collide with entries already in kubeconfig.
sed -E \
  "s/^([[:space:]]*(-[[:space:]]*)?(name|cluster|user|current-context):) default$/\1 ${context_name}/" \
  "$source_config" > "$import_config"
chmod 0600 "$import_config"

if ! kubectl --kubeconfig "$import_config" config use-context \
  "$context_name" >/dev/null 2>&1; then
  echo "Could not rename the k3s context to $context_name" >&2
  exit 1
fi

kubectl --kubeconfig "$import_config" config set-cluster "$context_name" \
  --server="https://${server_host}:6443" >/dev/null

# A minified view resolves the context's referenced cluster and user. It fails
# if either renamed entry is missing, which prevents writing a broken context.
if ! kubectl --kubeconfig "$import_config" config view \
  --raw --minify >/dev/null; then
  echo "The imported context does not contain a valid cluster and user" >&2
  exit 1
fi

client_certificate_data="$(
  kubectl --kubeconfig "$import_config" config view --raw --minify \
    -o jsonpath='{.users[0].user.client-certificate-data}'
)"
client_key_data="$(
  kubectl --kubeconfig "$import_config" config view --raw --minify \
    -o jsonpath='{.users[0].user.client-key-data}'
)"
if [[ -z "$client_certificate_data" || -z "$client_key_data" ]]; then
  echo "The imported k3s user does not contain embedded client credentials" >&2
  exit 1
fi
unset client_certificate_data client_key_data

existing_current_context=""
had_existing_config=false
if [[ -f "$target_config" ]]; then
  had_existing_config=true
  existing_current_context="$(
    kubectl --kubeconfig "$target_config" config current-context 2>/dev/null || true
  )"
  backup_config="${target_config}.backup.$(date +%Y%m%dT%H%M%S)"
  cp -p "$target_config" "$backup_config"
  echo "Backed up the existing kubeconfig to $backup_config"

  # Put the imported file first so rerunning this script refreshes an existing
  # context with the same name instead of retaining its old credentials.
  KUBECONFIG="$import_config:$target_config" \
    kubectl config view --raw --flatten > "$merged_config"
else
  kubectl --kubeconfig "$import_config" config view --raw --flatten \
    > "$merged_config"
fi

if [[ -n "$existing_current_context" ]]; then
  kubectl --kubeconfig "$merged_config" config use-context \
    "$existing_current_context" >/dev/null
elif [[ "$had_existing_config" == true ]]; then
  kubectl --kubeconfig "$merged_config" config unset current-context >/dev/null
fi

install -m 0600 "$merged_config" "$target_config"

echo "Imported context $context_name into $target_config"
kubectl --kubeconfig "$target_config" config get-contexts "$context_name"
echo "Test it with: kubectl --context=$context_name get nodes"
