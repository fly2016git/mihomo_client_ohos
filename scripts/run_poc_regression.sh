#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/huawei_tools_env.sh"

TMP_DIR="${POC_REGRESSION_TMP_DIR:-/private/tmp/poc-regression}"
POCS=("$@")
if [[ ${#POCS[@]} -eq 0 ]]; then
  POCS=("POC-05" "POC-06")
fi

mkdir -p "$TMP_DIR"

run_hdc() {
  "$HDC" -t "$POC_DEVICE_TARGET" "$@"
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

echo "== POC regression =="
echo "device: $POC_DEVICE_TARGET"
echo "pocs: ${POCS[*]}"

"$HDC" list targets
run_hdc install -r "$POC_ENTRY_HAP"

for poc in "${POCS[@]}"; do
  lower="$(printf '%s' "$poc" | tr '[:upper:]' '[:lower:]')"
  log_file="$TMP_DIR/$lower.log"
  echo "== $poc =="
  run_hdc shell hilog -r
  run_hdc shell aa force-stop "$POC_BUNDLE_NAME" >/dev/null || true
  run_hdc shell aa start -b "$POC_BUNDLE_NAME" -a "$POC_ENTRY_ABILITY" --ps poc "$poc"
  sleep "${POC_REGRESSION_WAIT_SECONDS:-24}"
  run_hdc shell hilog -x | grep -E "MihomoPocEntry|MihomoPocVpn|MihomoPocNapi|$poc|DfxFaultLogger|Ability on scheduler died|On ability died" > "$log_file" || true
  assert_log_contains "$log_file" "$poc self-test done failures=0"
  assert_log_not_contains "$log_file" 'DfxFaultLogger|Ability on scheduler died|On ability died'
  echo "$poc PASS"
done

echo "POC regression PASS"
echo "logs: $TMP_DIR"
