#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-$ROOT_DIR/build/outputs/default/MyApplication-default-unsigned.app}"

if [[ ! -f "$APP_PATH" ]]; then
  echo "release APP not found: $APP_PATH" >&2
  exit 1
fi

if ! unzip -tqq "$APP_PATH"; then
  echo "release APP is not a valid ZIP archive: $APP_PATH" >&2
  exit 1
fi

pack_info="$(unzip -p "$APP_PATH" pack.info)"
if [[ -z "$pack_info" ]]; then
  echo 'release APP is missing pack.info' >&2
  exit 1
fi

assert_pack_info() {
  local expression="$1"
  local message="$2"
  if ! jq -e "$expression" >/dev/null <<<"$pack_info"; then
    echo "$message" >&2
    exit 1
  fi
}

assert_pack_info '.summary.app.bundleName == "com.fly.fluxgate"' \
  'release APP has an unexpected bundle name'
assert_pack_info '.summary.app.version.name == "1.0.2" and .summary.app.version.code == 1000002' \
  'release APP has an unexpected version'
assert_pack_info '[.packages[] | select(.name == "entry-default" and .moduleType == "entry")] | length == 1' \
  'release APP does not contain the expected entry package'

hap_entries="$(unzip -Z1 "$APP_PATH" | grep -E '(^|/)[^/]+\.hap$' || true)"
hap_count="$(printf '%s\n' "$hap_entries" | grep -c '[^[:space:]]' || true)"
if [[ "$hap_count" -ne 1 ]]; then
  echo "release APP must contain exactly one HAP; found $hap_count" >&2
  exit 1
fi

if [[ "$hap_entries" != 'entry-default.hap' ]]; then
  echo "release APP contains an unexpected HAP: $hap_entries" >&2
  exit 1
fi

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/fluxgate-app-verify.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT

embedded_hap="$temp_dir/entry-default.hap"
unzip -p "$APP_PATH" "$hap_entries" > "$embedded_hap"
"$ROOT_DIR/scripts/verify_release_hap.sh" "$embedded_hap"

echo "release APP contents PASS: $APP_PATH"
