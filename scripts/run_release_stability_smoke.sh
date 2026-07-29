#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/huawei_tools_env.sh"

TMP_DIR="${RELEASE_STABILITY_TMP_DIR:-/private/tmp/fluxgate-release-stability}"
APP_STATE_DIR="/data/app/el2/100/base/$POC_BUNDLE_NAME/haps/entry/files/mihomo/state"
RUNTIME_JSON="$APP_STATE_DIR/runtime.json"
PROFILES_JSON="$APP_STATE_DIR/profiles.json"
CYCLES="${RELEASE_STABILITY_CYCLES:-5}"
SKIP_INSTALL="${RELEASE_STABILITY_SKIP_INSTALL:-false}"
CONNECTED_BY_SMOKE=false
RECOVERY_RETRIES=0

mkdir -p "$TMP_DIR"

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

start_home() {
  run_hdc shell aa start -b "$POC_BUNDLE_NAME" -a "$POC_ENTRY_ABILITY" "$@"
}

read_device_json() {
  local device_path="$1"
  local local_path="$2"
  run_hdc shell cat "$device_path" > "$local_path"
}

json_value() {
  local file="$1"
  local path="$2"
  python3 - "$file" "$path" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    value = json.load(f)
for key in sys.argv[2].split("."):
    value = value[key]
print(value)
PY
}

wait_for_runtime() {
  local runtime_state="$1"
  local core_state="$2"
  local attempt
  for attempt in $(seq 1 30); do
    if read_device_json "$RUNTIME_JSON" "$TMP_DIR/runtime-current.json" 2>/dev/null; then
      local actual_runtime
      local actual_core
      actual_runtime="$(json_value "$TMP_DIR/runtime-current.json" snapshot.runtimeState 2>/dev/null || true)"
      actual_core="$(json_value "$TMP_DIR/runtime-current.json" snapshot.coreState 2>/dev/null || true)"
      if [ "$actual_runtime" = "$runtime_state" ] && [ "$actual_core" = "$core_state" ]; then
        return 0
      fi
      if [ "$actual_runtime" = "error" ] || [ "$actual_core" = "error" ]; then
        json_value "$TMP_DIR/runtime-current.json" snapshot.lastError >&2 || true
        return 1
      fi
    fi
    sleep 1
  done
  echo "runtime did not reach $runtime_state/$core_state" >&2
  return 1
}

assert_idle() {
  read_device_json "$RUNTIME_JSON" "$TMP_DIR/runtime-preflight.json"
  local runtime_state
  local core_state
  runtime_state="$(json_value "$TMP_DIR/runtime-preflight.json" snapshot.runtimeState)"
  core_state="$(json_value "$TMP_DIR/runtime-preflight.json" snapshot.coreState)"
  if [ "$runtime_state" != "idle" ] || [ "$core_state" != "stopped" ]; then
    echo "refusing stability smoke while runtime is $runtime_state/$core_state" >&2
    exit 1
  fi
}

disconnect_smoke() {
  start_home --ps mvpCommand disconnectProduct >/dev/null 2>&1 || true
  if wait_for_runtime idle stopped; then
    CONNECTED_BY_SMOKE=false
    return 0
  fi

  RECOVERY_RETRIES=$((RECOVERY_RETRIES + 1))
  echo "disconnect did not settle; retrying once" >&2
  start_home --ps mvpCommand disconnectProduct >/dev/null 2>&1 || true
  if wait_for_runtime idle stopped; then
    CONNECTED_BY_SMOKE=false
    return 0
  fi
  return 1
}

cleanup() {
  local exit_code=$?
  if [ "$CONNECTED_BY_SMOKE" = "true" ]; then
    disconnect_smoke || true
  fi
  exit "$exit_code"
}
trap cleanup EXIT

if ! [[ "$CYCLES" =~ ^[1-9][0-9]*$ ]]; then
  echo "RELEASE_STABILITY_CYCLES must be a positive integer" >&2
  exit 2
fi

echo "== FluxGate release stability smoke =="
echo "device: $POC_DEVICE_TARGET"
echo "cycles: $CYCLES"

assert_idle
if [ "$SKIP_INSTALL" != "true" ]; then
  install_hap "$POC_ENTRY_HAP"
fi
assert_idle

read_device_json "$PROFILES_JSON" "$TMP_DIR/profiles.json"
PROFILE_ID="$(json_value "$TMP_DIR/profiles.json" activeProfileId)"
if [ -z "$PROFILE_ID" ]; then
  echo "active profile is missing" >&2
  exit 1
fi
echo "profile: $PROFILE_ID"

run_hdc shell hilog -r >/dev/null
for cycle in $(seq 1 "$CYCLES"); do
  echo "cycle $cycle/$CYCLES: connect"
  start_home --ps mvpCommand connectProduct --ps profileId "$PROFILE_ID" >/dev/null
  CONNECTED_BY_SMOKE=true
  wait_for_runtime connected running

  read_device_json "$RUNTIME_JSON" "$TMP_DIR/runtime-connected-$cycle.json"
  tun_fd="$(json_value "$TMP_DIR/runtime-connected-$cycle.json" snapshot.tunFd)"
  if [ "$tun_fd" -lt 0 ]; then
    echo "connected snapshot has invalid tunFd=$tun_fd" >&2
    exit 1
  fi

  echo "cycle $cycle/$CYCLES: disconnect"
  disconnect_smoke
  read_device_json "$RUNTIME_JSON" "$TMP_DIR/runtime-idle-$cycle.json"
  tun_fd="$(json_value "$TMP_DIR/runtime-idle-$cycle.json" snapshot.tunFd)"
  if [ "$tun_fd" -ne -1 ]; then
    echo "idle snapshot did not release tunFd: $tun_fd" >&2
    exit 1
  fi
done

run_hdc shell hilog -x > "$TMP_DIR/hilog.txt"
if grep -E 'DfxFaultLogger|Ability on scheduler died|On ability died|Signal:SIG|Fatal signal' \
  "$TMP_DIR/hilog.txt" >/dev/null; then
  echo "crash signal detected during stability smoke" >&2
  grep -E 'DfxFaultLogger|Ability on scheduler died|On ability died|Signal:SIG|Fatal signal' \
    "$TMP_DIR/hilog.txt" >&2 || true
  exit 1
fi

if [ "$RECOVERY_RETRIES" -ne 0 ]; then
  echo "stability smoke required $RECOVERY_RETRIES disconnect recovery retries" >&2
  exit 1
fi

trap - EXIT
echo "FluxGate release stability smoke PASS"
echo "cycles: $CYCLES"
echo "final runtime: idle/stopped"
echo "logs: $TMP_DIR"
