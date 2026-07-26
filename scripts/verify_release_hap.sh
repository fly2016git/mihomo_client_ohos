#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HAP_PATH="${1:-$ROOT_DIR/entry/build/default/outputs/default/entry-default-unsigned.hap}"

if [ ! -f "$HAP_PATH" ]; then
  echo "release HAP not found: $HAP_PATH" >&2
  exit 1
fi

manifest="$(unzip -p "$HAP_PATH" module.json)"
backup_config="$(unzip -p "$HAP_PATH" resources/base/profile/backup_config.json)"

assert_manifest() {
  local expression="$1"
  local message="$2"
  if ! jq -e "$expression" >/dev/null <<<"$manifest"; then
    echo "$message" >&2
    exit 1
  fi
}

assert_manifest '.app.debug == false and .app.buildMode == "release"' \
  'release HAP is marked as debug'
assert_manifest '.app.bundleName == "com.fly.clashguard"' \
  'release HAP has an unexpected bundle name'
assert_manifest '.app.vendor == "fly2016"' \
  'release HAP has an unexpected vendor'
assert_manifest '.app.versionName == "1.0.0" and .app.versionCode == 1000000' \
  'release HAP has an unexpected version'

if ! jq -e '.allowToBackupRestore == false' >/dev/null <<<"$backup_config"; then
  echo 'release HAP allows application backup or restore' >&2
  exit 1
fi

if unzip -p "$HAP_PATH" ets/modules.abc | strings | grep -E '客户端原型|Mihomo POC VPN' >/dev/null; then
  echo 'release HAP contains prototype product text' >&2
  exit 1
fi

echo "release HAP metadata PASS: $HAP_PATH"
