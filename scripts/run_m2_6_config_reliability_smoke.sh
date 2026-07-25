#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/huawei_tools_env.sh"

TMP_DIR="${M2_6_SMOKE_TMP_DIR:-/private/tmp/m2-6-config-reliability-smoke}"
APP_STATE_DIR="/data/app/el2/100/base/$POC_BUNDLE_NAME/haps/entry/files/mihomo/state"
APP_RUN_DIR="/data/app/el2/100/base/$POC_BUNDLE_NAME/haps/entry/files/mihomo/run"
APP_PROFILE_DIR="/data/app/el2/100/base/$POC_BUNDLE_NAME/haps/entry/files/mihomo/profiles"
RUNTIME_YAML="$APP_RUN_DIR/default.runtime.yaml"
PROFILES_JSON="$APP_STATE_DIR/profiles.json"
RUNTIME_JSON="$APP_STATE_DIR/runtime.json"
BACKUP_READY=false

mkdir -p "$TMP_DIR"

run_hdc() {
  "$HDC" -t "$POC_DEVICE_TARGET" "$@"
}

restore_device_state() {
  if [ "$BACKUP_READY" = "true" ]; then
    run_hdc shell aa force-stop "$POC_BUNDLE_NAME" >/dev/null 2>&1 || true
    run_hdc file send "$TMP_DIR/default-before.raw.yaml" "$APP_PROFILE_DIR/default.raw.yaml" >/dev/null 2>&1 || true
    run_hdc file send "$TMP_DIR/runtime-before.yaml" "$RUNTIME_YAML" >/dev/null 2>&1 || true
    run_hdc file send "$TMP_DIR/profiles-before.json" "$PROFILES_JSON" >/dev/null 2>&1 || true
    run_hdc file send "$TMP_DIR/runtime-before.json" "$RUNTIME_JSON" >/dev/null 2>&1 || true
    BACKUP_READY=false
  fi
}

cleanup() {
  local exit_code=$?
  restore_device_state
  exit "$exit_code"
}
trap cleanup EXIT

profile_count() {
  local file="$1"
  python3 - "$file" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
print(len(data.get("profiles", [])))
PY
}

runtime_hash() {
  local file="$1"
  python3 - "$file" <<'PY'
import hashlib
import sys
with open(sys.argv[1], "rb") as f:
    print(hashlib.sha256(f.read()).hexdigest())
PY
}

assert_runtime_idle() {
  local file="$1"
  python3 - "$file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    snapshot = json.load(f).get("snapshot", {})
runtime_state = snapshot.get("runtimeState", "")
core_state = snapshot.get("coreState", "")
if runtime_state != "idle" or core_state != "stopped":
    print(f"refusing smoke while runtime is {runtime_state}/{core_state}", file=sys.stderr)
    raise SystemExit(1)
PY
}

echo "== M2-6 config reliability smoke =="
echo "device: $POC_DEVICE_TARGET"
echo "hap: $POC_ENTRY_HAP"

run_hdc shell cat "$RUNTIME_JSON" > "$TMP_DIR/runtime-preflight.json"
assert_runtime_idle "$TMP_DIR/runtime-preflight.json"
run_hdc install -r "$POC_ENTRY_HAP"
run_hdc shell cat "$RUNTIME_JSON" > "$TMP_DIR/runtime-after-install.json"
assert_runtime_idle "$TMP_DIR/runtime-after-install.json"
run_hdc shell aa force-stop "$POC_BUNDLE_NAME" >/dev/null || true
run_hdc shell cat "$APP_PROFILE_DIR/default.raw.yaml" > "$TMP_DIR/default-before.raw.yaml"
run_hdc shell cat "$RUNTIME_YAML" > "$TMP_DIR/runtime-before.yaml"
run_hdc shell cat "$PROFILES_JSON" > "$TMP_DIR/profiles-before.json"
run_hdc shell cat "$RUNTIME_JSON" > "$TMP_DIR/runtime-before.json"
BACKUP_READY=true

run_hdc shell aa start -b "$POC_BUNDLE_NAME" -a "$POC_ENTRY_ABILITY" --ps mvpCommand setDefaultConfig >/dev/null
sleep 2

run_hdc shell cat "$RUNTIME_YAML" > "$TMP_DIR/runtime-after-default.yaml"
run_hdc shell cat "$PROFILES_JSON" > "$TMP_DIR/profiles-after-default.json"
before_hash="$(runtime_hash "$TMP_DIR/runtime-after-default.yaml")"
before_count="$(profile_count "$TMP_DIR/profiles-after-default.json")"

echo "== invalid raw must not overwrite runtime =="
run_hdc shell aa start -b "$POC_BUNDLE_NAME" -a "$POC_ENTRY_ABILITY" --ps mvpCommand setInvalidConfig >/dev/null
sleep 2
run_hdc shell cat "$RUNTIME_YAML" > "$TMP_DIR/runtime-after-invalid.yaml"
after_hash="$(runtime_hash "$TMP_DIR/runtime-after-invalid.yaml")"
if [ "$before_hash" != "$after_hash" ]; then
  echo "runtime YAML changed after invalid config" >&2
  exit 1
fi

echo "== native YAML parser must accept valid and reject invalid syntax =="
run_hdc shell hilog -r >/dev/null
run_hdc shell aa start -b "$POC_BUNDLE_NAME" -a "$POC_ENTRY_ABILITY" \
  --ps mvpCommand validateConfig --ps validationCase valid >/dev/null
sleep 2
run_hdc shell aa start -b "$POC_BUNDLE_NAME" -a "$POC_ENTRY_ABILITY" \
  --ps mvpCommand validateConfig --ps validationCase invalidSyntax >/dev/null
sleep 2
run_hdc shell hilog -x > "$TMP_DIR/hilog-native-validation.txt"
if ! grep -F 'mvpCommand validateConfig complete case=valid ok=true' \
  "$TMP_DIR/hilog-native-validation.txt" >/dev/null; then
  echo "native validator did not accept valid config" >&2
  exit 1
fi
if ! grep -F 'mvpCommand validateConfig complete case=invalidSyntax ok=false' \
  "$TMP_DIR/hilog-native-validation.txt" >/dev/null; then
  echo "native validator did not reject invalid YAML" >&2
  exit 1
fi

echo "== failed subscription import must not leave profile =="
run_hdc shell aa start -b "$POC_BUNDLE_NAME" -a "$POC_ENTRY_ABILITY" \
  --ps mvpCommand prepareSubscription \
  --ps subscriptionName BrokenM26 \
  --ps subscriptionUrl https://127.0.0.1:9/not-found.yaml >/dev/null
sleep 5
run_hdc shell cat "$PROFILES_JSON" > "$TMP_DIR/profiles-after-failed-sub.json"
after_count="$(profile_count "$TMP_DIR/profiles-after-failed-sub.json")"
if [ "$before_count" != "$after_count" ]; then
  echo "profile count changed after failed subscription: before=$before_count after=$after_count" >&2
  exit 1
fi

echo "M2-6 config reliability smoke PASS"
echo "logs: $TMP_DIR"

restore_device_state
trap - EXIT
