#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/huawei_tools_env.sh"

CONNECT_X="${MVP_CONNECT_X:-341}"
CONNECT_Y="${MVP_CONNECT_Y:-755}"
DISCONNECT_X="${MVP_DISCONNECT_X:-939}"
DISCONNECT_Y="${MVP_DISCONNECT_Y:-755}"
TMP_DIR="${MVP_SMOKE_TMP_DIR:-/private/tmp/mvp01-smoke}"
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
    tail -200 "$file" >&2
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

echo "== MVP-01A smoke =="
echo "device: $POC_DEVICE_TARGET"
echo "hap: $POC_ENTRY_HAP"

if [[ ! -f "$ROOT_DIR/$POC_ENTRY_HAP" && ! -f "$POC_ENTRY_HAP" ]]; then
  echo "HAP not found: $POC_ENTRY_HAP" >&2
  exit 1
fi

echo "== device =="
"$HDC" list targets

echo "== install =="
run_hdc install -r "$POC_ENTRY_HAP"

echo "== launch =="
run_hdc shell hilog -r
run_hdc shell aa force-stop "$POC_BUNDLE_NAME" >/dev/null || true
run_hdc shell aa start -b "$POC_BUNDLE_NAME" -a "$POC_ENTRY_ABILITY"
sleep 3

initial_layout="$(dump_layout mvp01-initial)"
assert_layout_text "$initial_layout" "Profile"
assert_layout_text "$initial_layout" "Connect"
assert_layout_text "$initial_layout" "Disconnect"

echo "== reset to idle =="
run_hdc shell uitest uiInput click "$DISCONNECT_X" "$DISCONNECT_Y" >/dev/null
sleep 4
idle_layout="$(dump_layout mvp01-idle)"
assert_layout_text "$idle_layout" "Idle"
assert_layout_text "$idle_layout" "Stopped"

echo "== connect =="
run_hdc shell hilog -r
run_hdc shell uitest uiInput click "$CONNECT_X" "$CONNECT_Y" >/dev/null
sleep 6
connected_layout="$(dump_layout mvp01-connected)"
assert_layout_text "$connected_layout" "Connected"
assert_layout_text "$connected_layout" "Running"
run_hdc shell hilog -x | grep -E "$LOG_FILTER" > "$TMP_DIR/connect.log" || true
assert_log_contains "$TMP_DIR/connect.log" 'product onRequest connect profile=default'
assert_log_contains "$TMP_DIR/connect.log" 'product tunFd created fd='
assert_log_contains "$TMP_DIR/connect.log" 'protect callback registered'
assert_log_contains "$TMP_DIR/connect.log" 'MVP-01B calling MihomoOhosStartConfigFileWithTunFd'
assert_log_contains "$TMP_DIR/connect.log" 'MVP-01B MihomoOhosStartConfigFileWithTunFd returned code=0 tunFd='
assert_log_contains "$TMP_DIR/connect.log" 'product connect ok'
assert_log_not_contains "$TMP_DIR/connect.log" 'DfxFaultLogger|Ability on scheduler died|On ability died'

echo "== disconnect =="
run_hdc shell uitest uiInput click "$DISCONNECT_X" "$DISCONNECT_Y" >/dev/null
sleep 5
disconnected_layout="$(dump_layout mvp01-disconnected)"
assert_layout_text "$disconnected_layout" "Idle"
assert_layout_text "$disconnected_layout" "Stopped"
run_hdc shell hilog -x | grep -E "$LOG_FILTER" > "$TMP_DIR/disconnect.log" || true
assert_log_contains "$TMP_DIR/disconnect.log" 'product onRequest disconnect'
assert_log_contains "$TMP_DIR/disconnect.log" 'skipping Go bridge calls'
assert_log_contains "$TMP_DIR/disconnect.log" 'vpn destroyed fd='
assert_log_contains "$TMP_DIR/disconnect.log" 'product disconnect complete'
assert_log_not_contains "$TMP_DIR/disconnect.log" 'DfxFaultLogger|Ability on scheduler died|On ability died'

echo "MVP-01A smoke PASS"
echo "logs: $TMP_DIR"
