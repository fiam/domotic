#!/usr/bin/env bash
# Source this helper before reading the environment. New names take precedence;
# existing private deployment automation can migrate its variables gradually.
for kube4ha_legacy_name in ${!DOMOTIC_@}; do
  kube4ha_current_name="KUBE4HA_${kube4ha_legacy_name#DOMOTIC_}"
  if [[ -z "${!kube4ha_current_name:-}" ]]; then
    export "$kube4ha_current_name=${!kube4ha_legacy_name}"
  fi
done
unset kube4ha_legacy_name kube4ha_current_name
