#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/huawei_tools_env.sh"

RELEASE_HAP="${RELEASE_HAP:-entry/build/default/outputs/default/entry-default-signed.hap}"

run_hdc() {
  "$HDC" -t "$POC_DEVICE_TARGET" "$@"
}

install_hap() {
  local hap_path="$1"
  local install_output

  if ! install_output="$(run_hdc install -r "$hap_path" 2>&1)"; then
    printf '%s\n' "$install_output" >&2
    return 1
  fi
  printf '%s\n' "$install_output"
  if grep -Eiq 'msg:error|failed to install bundle|signature verification failed' <<<"$install_output"; then
    echo 'release HAP installation failed' >&2
    return 1
  fi
}

if [ ! -f "$ROOT_DIR/$RELEASE_HAP" ]; then
  echo "signed release HAP not found: $ROOT_DIR/$RELEASE_HAP" >&2
  exit 1
fi

"$ROOT_DIR/scripts/verify_release_hap.sh" "$ROOT_DIR/$RELEASE_HAP"
install_hap "$ROOT_DIR/$RELEASE_HAP"
run_hdc shell aa force-stop "$POC_BUNDLE_NAME" >/dev/null 2>&1 || true
run_hdc shell hilog -r >/dev/null
run_hdc shell aa start -b "$POC_BUNDLE_NAME" -a "$POC_ENTRY_ABILITY" >/dev/null
sleep 3
run_hdc shell hilog -x > /private/tmp/fluxgate-release-launch-hilog.txt

if grep -E 'DfxFaultLogger|Ability on scheduler died|On ability died|Fatal signal|Signal:SIG' \
  /private/tmp/fluxgate-release-launch-hilog.txt >/dev/null; then
  echo 'crash signal detected after launching the release HAP' >&2
  exit 1
fi

echo 'release HAP launch smoke PASS'
