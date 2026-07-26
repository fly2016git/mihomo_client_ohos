#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/huawei_tools_env.sh"

RELEASE_HAP="${RELEASE_HAP:-entry/build/default/outputs/default/entry-default-signed.hap}"

run_hdc() {
  "$HDC" -t "$POC_DEVICE_TARGET" "$@"
}

if [ ! -f "$ROOT_DIR/$RELEASE_HAP" ]; then
  echo "signed release HAP not found: $ROOT_DIR/$RELEASE_HAP" >&2
  exit 1
fi

"$ROOT_DIR/scripts/verify_release_hap.sh" "$ROOT_DIR/$RELEASE_HAP"
run_hdc install -r "$ROOT_DIR/$RELEASE_HAP"
run_hdc shell aa force-stop "$POC_BUNDLE_NAME" >/dev/null 2>&1 || true
run_hdc shell hilog -r >/dev/null
run_hdc shell aa start -b "$POC_BUNDLE_NAME" -a "$POC_ENTRY_ABILITY" >/dev/null
sleep 3
run_hdc shell hilog -x > /private/tmp/clashguard-release-launch-hilog.txt

if grep -E 'DfxFaultLogger|Ability on scheduler died|On ability died|Fatal signal|Signal:SIG' \
  /private/tmp/clashguard-release-launch-hilog.txt >/dev/null; then
  echo 'crash signal detected after launching the release HAP' >&2
  exit 1
fi

echo 'release HAP launch smoke PASS'
