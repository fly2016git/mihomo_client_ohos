#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HAP_PATH="${1:-$ROOT_DIR/entry/build/default/outputs/default/entry-default-unsigned.hap}"
GEOIP_ENTRY='resources/rawfile/geoip.metadb'
EXPECTED_GEOIP_SHA256='79a59a337d942c9dd8874ae64028024f9f4461452a4db4eee9697f9faeab1340'
LEGAL_ENTRIES=(
  'resources/rawfile/gpl-3.0.txt'
  'resources/rawfile/third_party_notices.txt'
  'resources/rawfile/third_party_licenses.txt'
  'resources/rawfile/modifications.txt'
  'resources/rawfile/source_code.txt'
)

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
assert_manifest '.app.bundleName == "com.fly.fluxgate"' \
  'release HAP has an unexpected bundle name'
assert_manifest '.app.vendor == "fly2016"' \
  'release HAP has an unexpected vendor'
assert_manifest '.app.versionName == "1.0.3" and .app.versionCode == 1000003' \
  'release HAP has an unexpected version'
assert_manifest '.app.targetAPIVersion == 60101024 and .app.minAPIVersion == 50000012' \
  'release HAP has an unexpected target or minimum API version'
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

for legal_entry in "${LEGAL_ENTRIES[@]}"; do
  if ! unzip -p "$HAP_PATH" "$legal_entry" | grep '[^[:space:]]' >/dev/null; then
    echo "release HAP is missing legal resource: $legal_entry" >&2
    exit 1
  fi

  legal_source="$ROOT_DIR/entry/src/main/resources/rawfile/${legal_entry##*/}"
  packaged_sha256="$(unzip -p "$HAP_PATH" "$legal_entry" | shasum -a 256 | awk '{print $1}')"
  source_sha256="$(shasum -a 256 "$legal_source" | awk '{print $1}')"
  if [[ "$packaged_sha256" != "$source_sha256" ]]; then
    echo "release HAP contains a stale legal resource: $legal_entry" >&2
    exit 1
  fi
done

if ! unzip -p "$HAP_PATH" resources/rawfile/gpl-3.0.txt | grep 'GNU GENERAL PUBLIC LICENSE' >/dev/null; then
  echo 'release HAP does not contain the GNU GPL text' >&2
  exit 1
fi

if ! unzip -p "$HAP_PATH" resources/rawfile/source_code.txt | grep 'github.com/fly2016git/mihomo_client_ohos' >/dev/null; then
  echo 'release HAP does not identify the corresponding source location' >&2
  exit 1
fi

echo "release HAP metadata PASS: $HAP_PATH"
