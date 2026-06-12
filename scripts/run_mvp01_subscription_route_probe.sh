#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/huawei_tools_env.sh"

TMP_DIR="${MVP_SUBSCRIPTION_PROBE_TMP_DIR:-/private/tmp/mvp01-subscription-route-probe}"
SUBSCRIPTION_URL="${MVP_SUBSCRIPTION_URL:-}"
SUBSCRIPTION_NAME="${MVP_SUBSCRIPTION_NAME:-Subscription Smoke}"
ROUTE_MODE="${MVP_SUBSCRIPTION_ROUTE_MODE:-blocking-default}"
PREPARE_WAIT_SECONDS="${MVP_SUBSCRIPTION_PREPARE_WAIT_SECONDS:-20}"

if [ -z "$SUBSCRIPTION_URL" ]; then
  echo "MVP_SUBSCRIPTION_URL is required" >&2
  exit 2
fi

mkdir -p "$TMP_DIR"

run_hdc() {
  "$HDC" -t "$POC_DEVICE_TARGET" "$@"
}

redact_url() {
  local url="$1"
  local rest
  local host
  case "$url" in
    http://*)
      rest="${url#http://}"
      host="${rest%%/*}"
      host="${host%%\?*}"
      host="${host%%#*}"
      printf 'http://%s/<redacted>\n' "$host"
      ;;
    https://*)
      rest="${url#https://}"
      host="${rest%%/*}"
      host="${host%%\?*}"
      host="${host%%#*}"
      printf 'https://%s/<redacted>\n' "$host"
      ;;
    *) printf '%s\n' "$url" ;;
  esac
}

echo "== MVP-01 subscription route probe =="
echo "device: $POC_DEVICE_TARGET"
echo "subscriptionUrl: $(redact_url "$SUBSCRIPTION_URL")"
echo "subscriptionName: $SUBSCRIPTION_NAME"
echo "routeMode: $ROUTE_MODE"
echo "logs: $TMP_DIR"

echo "== install =="
run_hdc install -r "$POC_ENTRY_HAP"

echo "== prepare subscription =="
run_hdc shell hilog -r
run_hdc shell aa force-stop "$POC_BUNDLE_NAME" >/dev/null || true
run_hdc shell aa start \
  -b "$POC_BUNDLE_NAME" \
  -a "$POC_ENTRY_ABILITY" \
  --ps mvpCommand prepareSubscription \
  --ps subscriptionUrl "$SUBSCRIPTION_URL" \
  --ps subscriptionName "$SUBSCRIPTION_NAME" >/dev/null

sleep "$PREPARE_WAIT_SECONDS"
run_hdc shell hilog -x | grep -E 'MihomoPocEntry|Subscription|mvpCommand prepareSubscription|DfxFaultLogger|Ability on scheduler died|On ability died' \
  > "$TMP_DIR/hilog-prepare-subscription.txt" || true

if grep -E 'DfxFaultLogger|Ability on scheduler died|On ability died' "$TMP_DIR/hilog-prepare-subscription.txt" >/dev/null 2>&1; then
  echo "prepare subscription crash detected" >&2
  grep -E 'DfxFaultLogger|Ability on scheduler died|On ability died' "$TMP_DIR/hilog-prepare-subscription.txt" >&2 || true
  exit 1
fi

PROFILE_ID="$(sed -n 's/.*mvpCommand prepareSubscription ok .*profile=\([^ ]*\).*/\1/p' "$TMP_DIR/hilog-prepare-subscription.txt" | tail -1)"
if [ -z "$PROFILE_ID" ]; then
  echo "prepare subscription did not produce an active profile" >&2
  echo "key logs:" >&2
  grep -E 'mvpCommand prepareSubscription' "$TMP_DIR/hilog-prepare-subscription.txt" >&2 || true
  exit 1
fi

echo "preparedProfileId: $PROFILE_ID"
grep -E 'mvpCommand prepareSubscription' "$TMP_DIR/hilog-prepare-subscription.txt" || true

echo "== route probe with subscription profile =="
MVP_ROUTE_PROBE_TMP_DIR="$TMP_DIR/route-probe" \
MVP_SKIP_DEFAULT_CONFIG=true \
MVP_PROFILE_ID="$PROFILE_ID" \
POC_DEVICE_TARGET="$POC_DEVICE_TARGET" \
  bash "$ROOT_DIR/scripts/run_mvp01_route_probe_verify.sh" "$ROUTE_MODE"

echo "MVP-01 subscription route probe DONE"
echo "profileId: $PROFILE_ID"
echo "logs: $TMP_DIR"
