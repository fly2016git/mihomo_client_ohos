#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/huawei_tools_env.sh"

CONNECT_X="${MVP_CONNECT_X:-341}"
CONNECT_Y="${MVP_CONNECT_Y:-755}"
DISCONNECT_X="${MVP_DISCONNECT_X:-939}"
DISCONNECT_Y="${MVP_DISCONNECT_Y:-755}"
TMP_DIR="${MVP_SPECIAL_SMOKE_TMP_DIR:-/private/tmp/mvp01-special-smoke}"
DEVICE_LAYOUT_DIR="${MVP_DEVICE_LAYOUT_DIR:-/data/local/tmp}"
LOG_FILTER='MihomoMvpPage|MihomoPocEntry|MihomoPocVpn|MihomoPocNapi|DfxFaultLogger|Ability on scheduler died|On ability died'

mkdir -p "$TMP_DIR"

run_hdc() {
  "$HDC" -t "$POC_DEVICE_TARGET" "$@"
}

dump_layout() {
  local name="$1"
  local device_path="$DEVICE_LAYOUT_DIR/$name.json"
  local local_path="$TMP_DIR/$name.json"
  run_hdc shell uitest dumpLayout -b "$POC_BUNDLE_NAME" -p "$device_path" >/dev/null
  run_hdc file recv "$device_path" "$local_path" >/dev/null
  printf '%s\n' "$local_path"
}

assert_layout_text() {
  local file="$1"
  local expected="$2"
  python3 - "$file" "$expected" <<'PY'
import json
import sys

path, expected = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

texts = []

def walk(node):
    attrs = node.get("attributes", {})
    text = attrs.get("text") or attrs.get("originalText") or ""
    if text:
        texts.append(text)
    for child in node.get("children", []):
        walk(child)

walk(data)
if not any(expected in item for item in texts):
    print("expected layout text not found:", expected, file=sys.stderr)
    print("visible texts:", file=sys.stderr)
    for item in texts:
        print(repr(item), file=sys.stderr)
    sys.exit(1)
PY
}

assert_log_contains() {
  local file="$1"
  local pattern="$2"
  if ! grep -E "$pattern" "$file" >/dev/null; then
    echo "expected log pattern not found: $pattern" >&2
    echo "log file: $file" >&2
    tail -220 "$file" >&2
    exit 1
  fi
}

assert_log_not_contains() {
  local file="$1"
  local pattern="$2"
  if grep -E "$pattern" "$file" >/dev/null; then
    echo "unexpected log pattern found: $pattern" >&2
    echo "log file: $file" >&2
    grep -E "$pattern" "$file" >&2
    exit 1
  fi
}

collect_log() {
  local file="$1"
  run_hdc shell hilog -x | grep -E "$LOG_FILTER" > "$file" || true
}

start_home() {
  run_hdc shell aa start -b "$POC_BUNDLE_NAME" -a "$POC_ENTRY_ABILITY" "$@"
}

set_default_config() {
  start_home --ps mvpCommand setDefaultConfig >/dev/null
  sleep 2
}

set_invalid_config() {
  start_home --ps mvpCommand setInvalidConfig >/dev/null
  sleep 2
}

reset_idle_from_ui() {
  run_hdc shell uitest uiInput click "$DISCONNECT_X" "$DISCONNECT_Y" >/dev/null || true
  sleep 4
}

echo "== MVP-01A special smoke =="
echo "device: $POC_DEVICE_TARGET"
echo "hap: $POC_ENTRY_HAP"

"$HDC" list targets
run_hdc install -r "$POC_ENTRY_HAP"

echo "== prepare =="
run_hdc shell hilog -r
run_hdc shell aa force-stop "$POC_BUNDLE_NAME" >/dev/null || true
start_home
sleep 3
set_default_config
reset_idle_from_ui
idle_layout="$(dump_layout special-idle)"
assert_layout_text "$idle_layout" "Idle"
assert_layout_text "$idle_layout" "Stopped"

echo "== invalid YAML must not connect =="
run_hdc shell hilog -r
set_invalid_config
run_hdc shell uitest uiInput click "$CONNECT_X" "$CONNECT_Y" >/dev/null
sleep 5
invalid_layout="$(dump_layout special-invalid)"
assert_layout_text "$invalid_layout" "Error"
assert_layout_text "$invalid_layout" "CONFIG_UNSUPPORTED_FIELD"
collect_log "$TMP_DIR/invalid.log"
assert_log_contains "$TMP_DIR/invalid.log" 'mvpCommand setInvalidConfig'
assert_log_contains "$TMP_DIR/invalid.log" 'product connect failed'
assert_log_contains "$TMP_DIR/invalid.log" 'CONFIG_UNSUPPORTED_FIELD'
assert_log_not_contains "$TMP_DIR/invalid.log" 'product tunFd created fd='
assert_log_not_contains "$TMP_DIR/invalid.log" 'MihomoOhosStartConfigFile returned code=0'
assert_log_not_contains "$TMP_DIR/invalid.log" 'MihomoOhosStartConfigFileWithTunFd returned code=0'
assert_log_not_contains "$TMP_DIR/invalid.log" 'DfxFaultLogger|Ability on scheduler died|On ability died'

echo "== restore default config =="
set_default_config
reset_idle_from_ui
restored_layout="$(dump_layout special-restored)"
assert_layout_text "$restored_layout" "Idle"
assert_layout_text "$restored_layout" "Stopped"

echo "== repeated connect clicks =="
run_hdc shell hilog -r
run_hdc shell uitest uiInput click "$CONNECT_X" "$CONNECT_Y" >/dev/null
run_hdc shell uitest uiInput click "$CONNECT_X" "$CONNECT_Y" >/dev/null || true
run_hdc shell uitest uiInput click "$CONNECT_X" "$CONNECT_Y" >/dev/null || true
sleep 7
repeat_connect_layout="$(dump_layout special-repeat-connect)"
assert_layout_text "$repeat_connect_layout" "Connected"
assert_layout_text "$repeat_connect_layout" "Running"
collect_log "$TMP_DIR/repeat-connect.log"
assert_log_contains "$TMP_DIR/repeat-connect.log" 'product onRequest connect profile=default'
assert_log_contains "$TMP_DIR/repeat-connect.log" 'product connect ok'
assert_log_not_contains "$TMP_DIR/repeat-connect.log" 'DfxFaultLogger|Ability on scheduler died|On ability died'

echo "== repeated disconnect clicks =="
run_hdc shell hilog -r
run_hdc shell uitest uiInput click "$DISCONNECT_X" "$DISCONNECT_Y" >/dev/null
run_hdc shell uitest uiInput click "$DISCONNECT_X" "$DISCONNECT_Y" >/dev/null || true
run_hdc shell uitest uiInput click "$DISCONNECT_X" "$DISCONNECT_Y" >/dev/null || true
sleep 6
repeat_disconnect_layout="$(dump_layout special-repeat-disconnect)"
assert_layout_text "$repeat_disconnect_layout" "Idle"
assert_layout_text "$repeat_disconnect_layout" "Stopped"
collect_log "$TMP_DIR/repeat-disconnect.log"
assert_log_contains "$TMP_DIR/repeat-disconnect.log" 'product onRequest disconnect'
assert_log_contains "$TMP_DIR/repeat-disconnect.log" 'product disconnect complete'
assert_log_not_contains "$TMP_DIR/repeat-disconnect.log" 'DfxFaultLogger|Ability on scheduler died|On ability died'

echo "== force-stop recovery degrades to unknown =="
run_hdc shell hilog -r
run_hdc shell uitest uiInput click "$CONNECT_X" "$CONNECT_Y" >/dev/null
sleep 6
connected_before_stop="$(dump_layout special-connected-before-force-stop)"
assert_layout_text "$connected_before_stop" "Connected"
run_hdc shell aa force-stop "$POC_BUNDLE_NAME" >/dev/null || true
sleep 2
start_home
sleep 3
recovered_layout="$(dump_layout special-recovered-unknown)"
assert_layout_text "$recovered_layout" "Unknown"
assert_layout_text "$recovered_layout" "runtime state needs verification"
run_hdc shell uitest uiInput click "$DISCONNECT_X" "$DISCONNECT_Y" >/dev/null || true
sleep 4
recovered_idle_layout="$(dump_layout special-recovered-idle)"
assert_layout_text "$recovered_idle_layout" "Idle"
assert_layout_text "$recovered_idle_layout" "Stopped"
collect_log "$TMP_DIR/recovery.log"
assert_log_contains "$TMP_DIR/recovery.log" 'product onRequest disconnect'
assert_log_not_contains "$TMP_DIR/recovery.log" 'DfxFaultLogger|Ability on scheduler died|On ability died'

echo "MVP-01A special smoke PASS"
echo "logs: $TMP_DIR"
