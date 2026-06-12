#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/huawei_tools_env.sh"

CONNECT_X="${MVP_CONNECT_X:-341}"
CONNECT_Y="${MVP_CONNECT_Y:-755}"
DISCONNECT_X="${MVP_DISCONNECT_X:-939}"
DISCONNECT_Y="${MVP_DISCONNECT_Y:-755}"
TMP_DIR="${MVP_BROWSER_TMP_DIR:-/private/tmp/mvp01-browser-verify}"
DEVICE_LAYOUT_DIR="${MVP_DEVICE_LAYOUT_DIR:-/data/local/tmp}"
TARGET_URL="${MVP_BROWSER_URL:-https://httpbin.org/get}"
APP_LOG_FILTER='MihomoMvpPage|MihomoPocEntry|MihomoPocVpn|MihomoPocNapi|DfxFaultLogger|Ability on scheduler died|On ability died|\[TUN\]|\[DNS\]'
BROWSER_LOG_FILTER='com.huawei.hmos.browser|NetConnManager|NETSTACK_RCP|ERR_NAME_NOT_RESOLVED|vpnEnabled|tryDns|FinalUrlRequestOccursError|HttpDNSResult'

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
    for item in texts:
        print(repr(item), file=sys.stderr)
    sys.exit(1)
PY
}

echo "== MVP-01 browser verify =="
echo "device: $POC_DEVICE_TARGET"
echo "url: $TARGET_URL"
echo "logs: $TMP_DIR"

echo "== install =="
run_hdc install -r "$POC_ENTRY_HAP"

echo "== launch app =="
run_hdc shell hilog -r
run_hdc shell aa force-stop "$POC_BUNDLE_NAME" >/dev/null || true
run_hdc shell aa start -b "$POC_BUNDLE_NAME" -a "$POC_ENTRY_ABILITY"
sleep 3

echo "== reset =="
run_hdc shell uitest uiInput click "$DISCONNECT_X" "$DISCONNECT_Y" >/dev/null
sleep 4
idle_layout="$(dump_layout browser-idle)"
assert_layout_text "$idle_layout" "Idle"
assert_layout_text "$idle_layout" "Stopped"

echo "== connect =="
run_hdc shell hilog -r
run_hdc shell uitest uiInput click "$CONNECT_X" "$CONNECT_Y" >/dev/null
sleep 8
connected_layout="$(dump_layout browser-connected)"
assert_layout_text "$connected_layout" "Connected"
assert_layout_text "$connected_layout" "Running"
run_hdc shell hilog -x | grep -E "$APP_LOG_FILTER" > "$TMP_DIR/hilog-connect.txt" || true

echo "== ifconfig before =="
run_hdc shell ifconfig vpn-tun > "$TMP_DIR/ifconfig-before.txt" || true
cat "$TMP_DIR/ifconfig-before.txt"

echo "== browser =="
run_hdc shell hilog -r
run_hdc shell aa force-stop com.huawei.hmos.browser >/dev/null || true
sleep 1
run_hdc shell aa start -b com.huawei.hmos.browser -a MainAbility -U "$TARGET_URL" >/dev/null || \
  run_hdc shell aa start -b com.huawei.hmos.browser -a MainAbility --uri "$TARGET_URL" >/dev/null || \
  run_hdc shell aa start -b com.huawei.hmos.browser -a MainAbility >/dev/null
sleep 22

echo "== ifconfig after =="
run_hdc shell ifconfig vpn-tun > "$TMP_DIR/ifconfig-after.txt" || true
cat "$TMP_DIR/ifconfig-after.txt"

run_hdc shell hilog -x | grep -E "$APP_LOG_FILTER" > "$TMP_DIR/hilog-app-browser.txt" || true
run_hdc shell hilog -x | grep -E "$BROWSER_LOG_FILTER" > "$TMP_DIR/hilog-browser.txt" || true

echo "== key app logs =="
grep -E 'MVP-01B|\[TUN\]|\[DNS\]|protect|DfxFaultLogger|Ability on scheduler died|On ability died' "$TMP_DIR/hilog-connect.txt" "$TMP_DIR/hilog-app-browser.txt" || true

echo "== key browser logs =="
grep -E 'vpnEnabled|tryDns|ERR_NAME_NOT_RESOLVED|FinalUrlRequestOccursError|HttpDNSResult|vpn-tun' "$TMP_DIR/hilog-browser.txt" || true

echo "MVP-01 browser verify DONE"
echo "logs: $TMP_DIR"
