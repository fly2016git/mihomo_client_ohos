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
APP_LOG_DIR="/data/app/el2/100/base/$POC_BUNDLE_NAME/haps/entry/files/mihomo/logs"
APP_RUNTIME_PATH="/data/app/el2/100/base/$POC_BUNDLE_NAME/haps/entry/files/mihomo/state/runtime.json"

mkdir -p "$TMP_DIR"

run_hdc() {
  "$HDC" -t "$POC_DEVICE_TARGET" "$@"
}

ifconfig_bytes() {
  local file="$1"
  local direction="$2"
  awk -v direction="$direction" '
    {
      for (i = 1; i <= NF; i++) {
        if ($i == direction && (i + 1) <= NF && $(i + 1) ~ /^bytes:/) {
          split($(i + 1), parts, ":")
          print parts[2]
          found = 1
          exit
        }
      }
    }
    END {
      if (!found) {
        print 0
      }
    }
  ' "$file"
}

count_lines() {
  local pattern="$1"
  local file="$2"
  if [ ! -f "$file" ]; then
    echo 0
    return
  fi
  grep -E "$pattern" "$file" | wc -l | tr -d ' '
}

runtime_field() {
  local file="$1"
  local field="$2"
  if [ ! -f "$file" ]; then
    echo ""
    return
  fi
  python3 - "$file" "$field" <<'PY'
import json
import sys

path, field = sys.argv[1], sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    value = data.get("snapshot", {}).get(field, "")
    print(value)
except Exception:
    print("")
PY
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
run_hdc shell cat "$APP_RUNTIME_PATH" > "$TMP_DIR/runtime-after-browser.json" || true

echo "== key app logs =="
grep -E 'MVP-01B|\[TUN\]|\[DNS\]|protect|DfxFaultLogger|Ability on scheduler died|On ability died' "$TMP_DIR/hilog-connect.txt" "$TMP_DIR/hilog-app-browser.txt" || true

echo "== key browser logs =="
grep -E 'vpnEnabled|tryDns|ERR_NAME_NOT_RESOLVED|FinalUrlRequestOccursError|HttpDNSResult|vpn-tun' "$TMP_DIR/hilog-browser.txt" || true

RX_BEFORE=$(ifconfig_bytes "$TMP_DIR/ifconfig-before.txt" RX)
RX_AFTER=$(ifconfig_bytes "$TMP_DIR/ifconfig-after.txt" RX)
TX_BEFORE=$(ifconfig_bytes "$TMP_DIR/ifconfig-before.txt" TX)
TX_AFTER=$(ifconfig_bytes "$TMP_DIR/ifconfig-after.txt" TX)
RX_DELTA=$((RX_AFTER - RX_BEFORE))
TX_DELTA=$((TX_AFTER - TX_BEFORE))
if [ "$RX_DELTA" -lt 0 ]; then RX_DELTA=0; fi
if [ "$TX_DELTA" -lt 0 ]; then TX_DELTA=0; fi

BROWSER_ERRORS=$(count_lines 'ERR_NAME_NOT_RESOLVED|dnsServerReturnNothing|Couldn.t resolve host name|errCode:1007900006|errCode:1007900028|FinalUrlRequestOccursError' "$TMP_DIR/hilog-browser.txt")
BROWSER_VPN=$(count_lines 'vpnEnabled|vpn-tun' "$TMP_DIR/hilog-browser.txt")
APP_EVIDENCE=$(count_lines 'MVP-01B|protect|\[TUN\]|\[DNS\]|Traffic stats source=native-mihomo|Core start status' "$TMP_DIR/hilog-connect.txt")
APP_EVIDENCE=$((APP_EVIDENCE + $(count_lines 'MVP-01B|protect|\[TUN\]|\[DNS\]|Traffic stats source=native-mihomo|Core start status' "$TMP_DIR/hilog-app-browser.txt")))
CRASH_SIGNALS=$(count_lines 'DfxFaultLogger|Ability on scheduler died|On ability died' "$TMP_DIR/hilog-connect.txt")
CRASH_SIGNALS=$((CRASH_SIGNALS + $(count_lines 'DfxFaultLogger|Ability on scheduler died|On ability died' "$TMP_DIR/hilog-app-browser.txt")))
RUNTIME_SOURCE="$(runtime_field "$TMP_DIR/runtime-after-browser.json" trafficSource)"
RUNTIME_TODAY_UP="$(runtime_field "$TMP_DIR/runtime-after-browser.json" todayUploadBytes)"
RUNTIME_TODAY_DOWN="$(runtime_field "$TMP_DIR/runtime-after-browser.json" todayDownloadBytes)"
RUNTIME_TODAY_TOTAL=$(( ${RUNTIME_TODAY_UP:-0} + ${RUNTIME_TODAY_DOWN:-0} ))

RESULT="FAIL"
if [ "$CRASH_SIGNALS" -eq 0 ] && [ "$BROWSER_ERRORS" -eq 0 ] && [ "$APP_EVIDENCE" -gt 0 ] &&
  { [ "$RX_DELTA" -gt 0 ] || [ "$TX_DELTA" -gt 0 ] || [ "$RUNTIME_TODAY_TOTAL" -gt 0 ]; }; then
  RESULT="PASS"
elif [ "$CRASH_SIGNALS" -eq 0 ] && { [ "$RX_DELTA" -gt 0 ] || [ "$TX_DELTA" -gt 0 ] ||
  [ "$RUNTIME_TODAY_TOTAL" -gt 0 ] || [ "$APP_EVIDENCE" -gt 0 ]; }; then
  RESULT="PARTIAL"
fi

SUMMARY="M2-5 browser smoke $RESULT url=$TARGET_URL source=native-mihomo runtimeSource=$RUNTIME_SOURCE runtimeTodayBytes=$RUNTIME_TODAY_TOTAL rxDelta=$RX_DELTA txDelta=$TX_DELTA browserVpnLogs=$BROWSER_VPN browserErrors=$BROWSER_ERRORS appEvidence=$APP_EVIDENCE crashSignals=$CRASH_SIGNALS"
SUMMARY_FILE="$TMP_DIR/poc-smoke-summary.txt"
printf '%s\n' "$SUMMARY" > "$SUMMARY_FILE"
run_hdc shell mkdir -p "$APP_LOG_DIR" >/dev/null || true
run_hdc file send "$SUMMARY_FILE" "$APP_LOG_DIR/poc-smoke-summary.txt" >/dev/null || true

echo "$SUMMARY"
echo "MVP-01 browser verify $RESULT"
echo "logs: $TMP_DIR"
if [ "$RESULT" = "FAIL" ]; then
  exit 1
fi
