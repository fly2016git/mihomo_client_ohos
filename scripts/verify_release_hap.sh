#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HAP_PATH="${1:-$ROOT_DIR/entry/build/default/outputs/default/entry-default-unsigned.hap}"
GEOIP_ENTRY='resources/rawfile/geoip.metadb'
EXPECTED_GEOIP_SHA256='79a59a337d942c9dd8874ae64028024f9f4461452a4db4eee9697f9faeab1340'

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
assert_manifest '.app.versionName == "1.0.1" and .app.versionCode == 1000001' \
  'release HAP has an unexpected version'
assert_manifest '.module.abilities[] | select(.name == "EntryAbility") | .exported == true' \
  'release HAP launcher ability is not exported'
assert_manifest '.module.extensionAbilities[] | select(.name == "MihomoPocVpnAbility") | .exported == false' \
  'release HAP VPN extension is externally exported'

if ! jq -e '.allowToBackupRestore == false' >/dev/null <<<"$backup_config"; then
  echo 'release HAP allows application backup or restore' >&2
  exit 1
fi

if unzip -p "$HAP_PATH" ets/modules.abc | strings | grep -E '客户端原型|Mihomo POC VPN' >/dev/null; then
  echo 'release HAP contains prototype product text' >&2
  exit 1
fi

if unzip -p "$HAP_PATH" libs/arm64-v8a/libpoc_napi.so | strings | \
  grep -E 'protect callback invoked|Go core already loaded|calling PocGoVersion|mihomo core loaded and protect bridge registered' \
  >/dev/null; then
  echo 'release HAP contains verbose native diagnostic logs' >&2
  exit 1
fi

geoip_sha256="$(unzip -p "$HAP_PATH" "$GEOIP_ENTRY" | shasum -a 256 | awk '{print $1}')"
if [ "$geoip_sha256" != "$EXPECTED_GEOIP_SHA256" ]; then
  echo 'release HAP has a missing or unexpected geoip.metadb' >&2
  exit 1
fi

echo "release HAP metadata PASS: $HAP_PATH"
