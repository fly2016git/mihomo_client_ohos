#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/huawei_tools_env.sh"

TMP_DIR="${MVP_ROUTE_PROBE_TMP_DIR:-/private/tmp/mvp01-route-probe}"
DEVICE_LAYOUT_DIR="${MVP_DEVICE_LAYOUT_DIR:-/data/local/tmp}"
DNS_ADDRESS="${MVP_VPN_DNS_ADDRESS:-10.7.0.3}"
READ_PROBE_MS="${MVP_TUN_READINESS_PROBE_MS:-30000}"
ROUTE_INTERFACE="${MVP_ROUTE_INTERFACE:-vpn-tun}"
ROUTE_DEFAULT_FLAG="${MVP_ROUTE_DEFAULT_FLAG:-true}"
PROFILE_ID="${MVP_PROFILE_ID:-default}"
SKIP_DEFAULT_CONFIG="${MVP_SKIP_DEFAULT_CONFIG:-false}"
TARGET_URL="${MVP_BROWSER_URL:-https://httpbin.org/get}"
BROWSER_WAIT_SECONDS="${MVP_BROWSER_WAIT_SECONDS:-20}"
PAGE_DUMP_RETRIES="${MVP_BROWSER_PAGE_DUMP_RETRIES:-3}"
PAGE_DUMP_INTERVAL_SECONDS="${MVP_BROWSER_PAGE_DUMP_INTERVAL_SECONDS:-3}"
PAGE_ASSERT_REGEX="${MVP_BROWSER_PAGE_ASSERT_REGEX:-\"headers\"|\"origin\"|\"url\"|User-Agent}"
PAGE_ERROR_REGEX="${MVP_BROWSER_PAGE_ERROR_REGEX:-Service Temporarily Unavailable|ERR_NAME_NOT_RESOLVED|Couldn.t resolve host name|dnsServerReturnNothing|无法访问|网页无法打开}"
APP_LOG_FILTER='MihomoMvpPage|MihomoPocEntry|MihomoPocVpn|MihomoPocNapi|MihomoOhosBridge|DfxFaultLogger|Ability on scheduler died|On ability died|TUN readiness|TUN poll|\[TUN\]|\[DNS\]|createPocConfig|product creating vpn|MVP-01B|Start TUN listening error|Tun adapter listening'
BROWSER_LOG_FILTER='com.huawei.hmos.browser|NetConnManager|NETSTACK_RCP|ERR_NAME_NOT_RESOLVED|vpnEnabled|tryDns|FinalUrlRequestOccursError|HttpDNSResult'

# Route modes to test:
# - blocking-empty: isBlocking=true, routes=[]
# - blocking-split: isBlocking=true, split /1 routes
# - blocking-default: isBlocking=true, single 0.0.0.0/0 route
# - no-routes: isBlocking=false, routes=[]
# - exclude-local: isBlocking=true, only 10.7.0.0/24 route
# - split-default: original default (isBlocking=false, split /1 routes)
DEFAULT_MODES=("blocking-empty" "blocking-split" "blocking-default" "no-routes" "exclude-local")
MODES=("${@}")
if [ ${#MODES[@]} -eq 0 ]; then
  MODES=("${DEFAULT_MODES[@]}")
fi

mkdir -p "$TMP_DIR"

run_hdc() {
  "$HDC" -t "$POC_DEVICE_TARGET" "$@"
}

start_home() {
  run_hdc shell aa start -b "$POC_BUNDLE_NAME" -a "$POC_ENTRY_ABILITY" "$@"
}

count_lines() {
  local pattern="$1"
  local file="$2"
  if [ ! -f "$file" ]; then
    echo "0"
    return
  fi
  grep -E -c "$pattern" "$file" 2>/dev/null || true
}

ifconfig_bytes() {
  local file="$1"
  local direction="$2"
  if [ ! -f "$file" ]; then
    echo "0"
    return
  fi
  awk -v direction="$direction" '
    {
      for (i = 1; i <= NF; i++) {
        if ($i == direction && (i + 1) <= NF && $(i + 1) ~ /^bytes:/) {
          value = $(i + 1)
          gsub(/[^0-9]/, "", value)
          print value
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

extract_layout_text() {
  local file="$1"
  local all_text_file="$2"
  local web_text_file="$3"
  python3 - "$file" "$all_text_file" "$web_text_file" <<'PY'
import json
import sys

path = sys.argv[1]
all_text_file = sys.argv[2]
web_text_file = sys.argv[3]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

all_texts = []
web_texts = []

def append_once(items, value):
    if value and value not in items:
        items.append(value)

def is_web_container(attrs):
    node_type = attrs.get("type") or ""
    node_id = attrs.get("id") or ""
    node_key = attrs.get("key") or ""
    return (
        node_type in ("Web", "rootWebArea")
        or node_id.startswith("web_page_component")
        or node_id.startswith("web-component")
        or node_key.startswith("web_page_component")
        or node_key.startswith("web-component")
    )

def walk(node, in_web):
    attrs = node.get("attributes", {})
    current_in_web = in_web or is_web_container(attrs)
    for key in ("text", "originalText", "description"):
        value = attrs.get(key) or ""
        if value:
            append_once(all_texts, value)
            if current_in_web:
                append_once(web_texts, value)
    for child in node.get("children", []):
        walk(child, current_in_web)

walk(data, False)

with open(all_text_file, "w", encoding="utf-8") as f:
    for text in all_texts:
        print(text, file=f)

with open(web_text_file, "w", encoding="utf-8") as f:
    for text in web_texts:
        print(text, file=f)
PY
}

dump_browser_page() {
  local mode_tmp="$1"
  local name="$2"
  local device_layout="$DEVICE_LAYOUT_DIR/$name-browser-layout.json"
  local device_screen="$DEVICE_LAYOUT_DIR/$name-browser-screen.png"
  local local_layout="$mode_tmp/browser-layout.json"
  local local_text="$mode_tmp/browser-layout-text.txt"
  local local_web_text="$mode_tmp/browser-web-text.txt"
  local local_screen="$mode_tmp/browser-screen.png"

  rm -f "$local_layout" "$local_text" "$local_web_text" "$local_screen"
  run_hdc shell rm -f "$device_layout" "$device_screen" >/dev/null 2>&1 || true

  if run_hdc shell uitest dumpLayout -b com.huawei.hmos.browser -p "$device_layout" >/dev/null; then
    run_hdc file recv "$device_layout" "$local_layout" >/dev/null || true
    if [ -f "$local_layout" ]; then
      extract_layout_text "$local_layout" "$local_text" "$local_web_text" || true
    fi
  fi

  if run_hdc shell uitest screenCap -p "$device_screen" >/dev/null 2>&1; then
    run_hdc file recv "$device_screen" "$local_screen" >/dev/null || true
  elif run_hdc shell snapshot_display -f "$device_screen" >/dev/null 2>&1; then
    run_hdc file recv "$device_screen" "$local_screen" >/dev/null || true
  fi
}

browser_page_match() {
  local mode_tmp="$1"
  local all_text_file="$mode_tmp/browser-layout-text.txt"
  local web_text_file="$mode_tmp/browser-web-text.txt"
  if [ ! -s "$web_text_file" ]; then
    echo "0"
    return
  fi
  if grep -E "$PAGE_ERROR_REGEX" "$all_text_file" "$web_text_file" >/dev/null 2>&1; then
    echo "0"
    return
  fi
  if grep -E "$PAGE_ASSERT_REGEX" "$web_text_file" >/dev/null 2>&1; then
    echo "1"
    return
  fi
  echo "0"
}

wait_for_browser_page() {
  local mode_tmp="$1"
  local name="$2"
  local attempt
  local match

  for attempt in $(seq 1 "$PAGE_DUMP_RETRIES"); do
    dump_browser_page "$mode_tmp" "$name"
    match=$(browser_page_match "$mode_tmp")
    echo "  page dump attempt $attempt/$PAGE_DUMP_RETRIES: match=$match"
    if [ "$match" -eq 1 ]; then
      return 0
    fi
    if [ "$attempt" -lt "$PAGE_DUMP_RETRIES" ]; then
      sleep "$PAGE_DUMP_INTERVAL_SECONDS"
    fi
  done

  return 1
}

echo "== MVP-01 route probe verify (multi-mode) =="
echo "device: $POC_DEVICE_TARGET"
echo "modes: ${MODES[*]}"
echo "dns: $DNS_ADDRESS"
echo "readProbeMs: $READ_PROBE_MS"
echo "routeInterface: $ROUTE_INTERFACE"
echo "routeDefaultFlag: $ROUTE_DEFAULT_FLAG"
echo "profileId: $PROFILE_ID"
echo "skipDefaultConfig: $SKIP_DEFAULT_CONFIG"
echo "url: $TARGET_URL"
echo "browserWaitSeconds: $BROWSER_WAIT_SECONDS"
echo "pageDumpRetries: $PAGE_DUMP_RETRIES"
echo "pageAssertRegex: $PAGE_ASSERT_REGEX"
echo "logs: $TMP_DIR"

echo "== install =="
run_hdc install -r "$POC_ENTRY_HAP"

PASS_MODES=()
FAIL_MODES=()

for MODE in "${MODES[@]}"; do
  MODE_TMP="${TMP_DIR}/${MODE}"
  mkdir -p "$MODE_TMP"
  echo ""
  echo "========== testing route mode: $MODE =========="

  echo "== prepare ($MODE) =="
  run_hdc shell hilog -r
  run_hdc shell aa force-stop "$POC_BUNDLE_NAME" >/dev/null || true
  if [ "$SKIP_DEFAULT_CONFIG" = "true" ]; then
    start_home --ps mvpCommand resetRuntime >/dev/null
  else
    start_home --ps mvpCommand setDefaultConfig >/dev/null
  fi
  sleep 3

  echo "== connect ($MODE) =="
  run_hdc shell hilog -r
  start_home \
    --ps mvpCommand connectProduct \
    --ps profileId "$PROFILE_ID" \
    --ps vpnRouteMode "$MODE" \
    --ps vpnDnsAddress "$DNS_ADDRESS" \
    --ps tunReadinessProbeMs "$READ_PROBE_MS" \
    --ps vpnRouteInterface "$ROUTE_INTERFACE" \
    --ps vpnRouteDefaultFlag "$ROUTE_DEFAULT_FLAG" >/dev/null
  sleep 8
  run_hdc shell ifconfig vpn-tun > "$MODE_TMP/ifconfig-before.txt" || true
  run_hdc shell hilog -x | grep -E "$APP_LOG_FILTER" > "$MODE_TMP/hilog-connect.txt" || true

  echo "== browser ($MODE) =="
  run_hdc shell aa force-stop com.huawei.hmos.browser >/dev/null || true
  sleep 1
  run_hdc shell aa start -A ohos.want.action.viewData -U "$TARGET_URL" >/dev/null || \
    run_hdc shell aa start -b com.huawei.hmos.browser -a MainAbility -U "$TARGET_URL" >/dev/null || \
    run_hdc shell aa start -b com.huawei.hmos.browser -a MainAbility --uri "$TARGET_URL" >/dev/null || \
    run_hdc shell aa start -b com.huawei.hmos.browser -a MainAbility >/dev/null
  sleep "$BROWSER_WAIT_SECONDS"
  wait_for_browser_page "$MODE_TMP" "$MODE" || true

  echo "== after browser ($MODE) =="
  run_hdc shell ifconfig vpn-tun > "$MODE_TMP/ifconfig-after.txt" || true
  run_hdc shell netstat -rn > "$MODE_TMP/netstat-rn.txt" || true

  run_hdc shell hilog -x | grep -E "$APP_LOG_FILTER" > "$MODE_TMP/hilog-app.txt" || true
  run_hdc shell hilog -x | grep -E "$BROWSER_LOG_FILTER" > "$MODE_TMP/hilog-browser.txt" || true
  cat "$MODE_TMP/hilog-connect.txt" "$MODE_TMP/hilog-app.txt" > "$MODE_TMP/hilog-app-combined.txt"

  # --- Quick verdict for this mode ---
  echo ""
  echo "--- $MODE verdict ---"

  # Check for createPocConfig log
  echo "VPN config:"
  grep 'createPocConfig' "$MODE_TMP/hilog-app-combined.txt" || echo "  (no createPocConfig log)"

  # Check netstat
  echo "Routes (netstat -rn):"
  grep 'vpn-tun' "$MODE_TMP/netstat-rn.txt" || echo "  (no vpn-tun routes)"

  # Check ifconfig RX
  echo "vpn-tun RX:"
  if [ -f "$MODE_TMP/ifconfig-after.txt" ]; then
    grep -E 'RX|bytes' "$MODE_TMP/ifconfig-after.txt" || echo "  (no RX data)"
  fi
  RX_BEFORE=$(ifconfig_bytes "$MODE_TMP/ifconfig-before.txt" RX)
  RX_AFTER=$(ifconfig_bytes "$MODE_TMP/ifconfig-after.txt" RX)
  TX_BEFORE=$(ifconfig_bytes "$MODE_TMP/ifconfig-before.txt" TX)
  TX_AFTER=$(ifconfig_bytes "$MODE_TMP/ifconfig-after.txt" TX)
  RX_DELTA=$((RX_AFTER - RX_BEFORE))
  TX_DELTA=$((TX_AFTER - TX_BEFORE))
  echo "  RX bytes before/after/delta: $RX_BEFORE / $RX_AFTER / $RX_DELTA"
  echo "  TX bytes before/after/delta: $TX_BEFORE / $TX_AFTER / $TX_DELTA"

  # Check browser errors
  echo "Browser DNS errors:"
  echo "  error lines: $(count_lines 'ERR_NAME_NOT_RESOLVED|dnsServerReturnNothing|Couldn.t resolve host name|errCode:1007900006|errCode:1007900028' "$MODE_TMP/hilog-browser.txt")"

  # Check browser vpnEnabled
  echo "Browser vpnEnabled:"
  grep 'vpnEnabled' "$MODE_TMP/hilog-browser.txt" | head -3 || echo "  (no vpnEnabled log)"

  echo "Browser page assertion:"
  PAGE_MATCH=$(browser_page_match "$MODE_TMP")
  echo "  page match: $PAGE_MATCH"
  if [ -f "$MODE_TMP/browser-layout-text.txt" ]; then
    echo "  page text sample:"
    head -20 "$MODE_TMP/browser-layout-text.txt" | sed 's/^/    /'
  else
    echo "  page text sample: (no browser layout text)"
  fi
  if [ -f "$MODE_TMP/browser-web-text.txt" ]; then
    echo "  web text sample:"
    head -20 "$MODE_TMP/browser-web-text.txt" | sed 's/^/    /'
  else
    echo "  web text sample: (no browser web text)"
  fi
  if [ -f "$MODE_TMP/browser-screen.png" ]; then
    echo "  screenshot: $MODE_TMP/browser-screen.png"
  else
    echo "  screenshot: (not captured)"
  fi

  # Check TUN readiness
  echo "TUN readiness samples:"
  grep 'TUN readiness sample' "$MODE_TMP/hilog-app-combined.txt" | head -3 || echo "  (no TUN samples)"

  echo "TUN poll samples:"
  grep 'TUN poll probe POLLIN' "$MODE_TMP/hilog-app-combined.txt" | head -3 || echo "  (no TUN poll POLLIN)"

  echo "mihomo bridge/TUN logs:"
  grep -E 'MihomoOhosBridge|MVP-01B|Start TUN listening error|Tun adapter listening|\[TUN\]|\[DNS\]' "$MODE_TMP/hilog-app-combined.txt" | head -20 || \
    echo "  (no mihomo bridge/TUN logs)"

  # Check crash signals
  CRASH_LINES=$(count_lines 'DfxFaultLogger|Ability on scheduler died|On ability died' "$MODE_TMP/hilog-app-combined.txt")
  echo "Crash signals: $CRASH_LINES"

  echo "== disconnect ($MODE) =="
  start_home --ps mvpCommand disconnectProduct >/dev/null || true
  sleep 5
  run_hdc shell hilog -x | grep -E "$APP_LOG_FILTER" > "$MODE_TMP/hilog-disconnect.txt" || true
  DISCONNECT_CRASH=$(count_lines 'DfxFaultLogger|Ability on scheduler died|On ability died' "$MODE_TMP/hilog-disconnect.txt")
  echo "Disconnect crash signals: $DISCONNECT_CRASH"

  # Simple mode verdict
  BROWSER_ERRORS=$(count_lines 'ERR_NAME_NOT_RESOLVED|dnsServerReturnNothing|Couldn.t resolve host name|errCode:1007900006|errCode:1007900028' "$MODE_TMP/hilog-browser.txt")
  BROWSER_VPN=$(count_lines 'vpnEnabled' "$MODE_TMP/hilog-browser.txt")
  TUN_SAMPLES=$(count_lines 'TUN readiness sample|TUN poll probe POLLIN|\[DNS\] hijack' "$MODE_TMP/hilog-app-combined.txt")
  PAGE_MATCH=$(browser_page_match "$MODE_TMP")
  MODE_CRASH=$((CRASH_LINES + DISCONNECT_CRASH))

  if [ "$RX_DELTA" -gt 0 ] && [ "$BROWSER_ERRORS" -eq 0 ] && [ "$PAGE_MATCH" -eq 1 ] && [ "$MODE_CRASH" -eq 0 ]; then
    echo ">>> $MODE: PASS (rxDelta=$RX_DELTA txDelta=$TX_DELTA vpnLog=$BROWSER_VPN samples=$TUN_SAMPLES errors=$BROWSER_ERRORS page=$PAGE_MATCH crash=$MODE_CRASH)"
    PASS_MODES+=("$MODE")
  elif [ "$RX_DELTA" -gt 0 ] || [ "$BROWSER_VPN" -gt 0 ] || [ "$PAGE_MATCH" -eq 1 ]; then
    echo ">>> $MODE: PARTIAL (rxDelta=$RX_DELTA txDelta=$TX_DELTA vpnLog=$BROWSER_VPN samples=$TUN_SAMPLES errors=$BROWSER_ERRORS page=$PAGE_MATCH crash=$MODE_CRASH)"
    PASS_MODES+=("$MODE-partial")
  else
    echo ">>> $MODE: FAIL (rxDelta=$RX_DELTA txDelta=$TX_DELTA vpnLog=$BROWSER_VPN samples=$TUN_SAMPLES errors=$BROWSER_ERRORS page=$PAGE_MATCH crash=$MODE_CRASH)"
    FAIL_MODES+=("$MODE")
  fi
done

echo ""
echo "========== MVP-01 route probe multi-mode SUMMARY =========="
echo "Pass/partial: ${#PASS_MODES[@]} modes"
if [ ${#PASS_MODES[@]} -gt 0 ]; then
  for m in "${PASS_MODES[@]}"; do
    echo "  PASS: $m"
  done
fi
echo "Fail: ${#FAIL_MODES[@]} modes"
if [ ${#FAIL_MODES[@]} -gt 0 ]; then
  for m in "${FAIL_MODES[@]}"; do
    echo "  FAIL: $m"
  done
fi
echo "logs: $TMP_DIR"
