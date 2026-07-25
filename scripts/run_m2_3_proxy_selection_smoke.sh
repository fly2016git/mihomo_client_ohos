#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/huawei_tools_env.sh"

TMP_DIR="${M2_3_SMOKE_TMP_DIR:-/private/tmp/m2-3-proxy-selection-smoke}"
APP_STATE_DIR="/data/app/el2/100/base/$POC_BUNDLE_NAME/haps/entry/files/mihomo/state"
PROFILES_JSON="$APP_STATE_DIR/profiles.json"
RUNTIME_JSON="$APP_STATE_DIR/runtime.json"
SELECTIONS_JSON="$APP_STATE_DIR/proxy-selections.json"
REQUEST_JSON="$APP_STATE_DIR/proxy-selection-request.json"
PROFILE_ID="${M2_3_PROFILE_ID:-}"
GROUP_NAME="${M2_3_GROUP_NAME:-Auto}"
TARGET_NODE="${M2_3_TARGET_NODE:-}"
RESTORE_NODE="${M2_3_RESTORE_NODE:-}"
SKIP_INSTALL="${M2_3_SKIP_INSTALL:-false}"
CONNECTED_BY_SMOKE=false

mkdir -p "$TMP_DIR"

run_hdc() {
  "$HDC" -t "$POC_DEVICE_TARGET" "$@"
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
if isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

selection_node() {
  local file="$1"
  local profile_id="$2"
  local group_name="$3"
  python3 - "$file" "$profile_id" "$group_name" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
for item in data.get("selections", []):
    if item.get("profileId") == sys.argv[2] and item.get("groupName") == sys.argv[3]:
        print(item.get("nodeName", ""))
        break
PY
}

wait_for_runtime() {
  local runtime_state="$1"
  local core_state="$2"
  local attempt
  for attempt in $(seq 1 20); do
    if read_device_json "$RUNTIME_JSON" "$TMP_DIR/runtime.json" 2>/dev/null; then
      local actual_runtime
      local actual_core
      actual_runtime="$(json_value "$TMP_DIR/runtime.json" snapshot.runtimeState 2>/dev/null || true)"
      actual_core="$(json_value "$TMP_DIR/runtime.json" snapshot.coreState 2>/dev/null || true)"
      if [ "$actual_runtime" = "$runtime_state" ] && [ "$actual_core" = "$core_state" ]; then
        return 0
      fi
    fi
    sleep 1
  done
  echo "runtime did not reach $runtime_state/$core_state" >&2
  return 1
}

assert_runtime_idle_if_present() {
  if ! read_device_json "$RUNTIME_JSON" "$TMP_DIR/runtime-preflight.json" 2>/dev/null; then
    return 0
  fi
  local runtime_state
  local core_state
  runtime_state="$(json_value "$TMP_DIR/runtime-preflight.json" snapshot.runtimeState 2>/dev/null || true)"
  core_state="$(json_value "$TMP_DIR/runtime-preflight.json" snapshot.coreState 2>/dev/null || true)"
  if [ "$runtime_state" != "idle" ] || [ "$core_state" != "stopped" ]; then
    echo "refusing smoke while runtime is $runtime_state/$core_state" >&2
    return 1
  fi
}

wait_for_request() {
  local request_id="$1"
  local attempt
  for attempt in $(seq 1 15); do
    if read_device_json "$REQUEST_JSON" "$TMP_DIR/request.json" 2>/dev/null; then
      local actual_id
      local status
      actual_id="$(json_value "$TMP_DIR/request.json" requestId 2>/dev/null || true)"
      status="$(json_value "$TMP_DIR/request.json" status 2>/dev/null || true)"
      if [ "$actual_id" = "$request_id" ] && [ "$status" = "complete" ]; then
        return 0
      fi
      if [ "$actual_id" = "$request_id" ] && [ "$status" = "error" ]; then
        json_value "$TMP_DIR/request.json" error >&2 || true
        return 1
      fi
    fi
    sleep 1
  done
  echo "proxy selection request timed out: $request_id" >&2
  return 1
}

request_selection() {
  local request_id="$1"
  local node_name="$2"
  start_home \
    --ps mvpCommand selectProxy \
    --ps requestId "$request_id" \
    --ps profileId "$PROFILE_ID" \
    --ps groupName "$GROUP_NAME" \
    --ps nodeName "$node_name" >/dev/null
  wait_for_request "$request_id"
}

disconnect_smoke() {
  start_home --ps mvpCommand disconnectProduct >/dev/null 2>&1 || true
  wait_for_runtime idle stopped >/dev/null 2>&1 || true
  CONNECTED_BY_SMOKE=false
}

cleanup() {
  local exit_code=$?
  if [ "$CONNECTED_BY_SMOKE" = "true" ]; then
    if [ -n "$RESTORE_NODE" ]; then
      request_selection "select-cleanup-$(date +%s)" "$RESTORE_NODE" >/dev/null 2>&1 || true
    fi
    disconnect_smoke
  fi
  exit "$exit_code"
}
trap cleanup EXIT

echo "== M2-3 proxy selection smoke =="
echo "device: $POC_DEVICE_TARGET"
echo "group: $GROUP_NAME"

assert_runtime_idle_if_present
if [ "$SKIP_INSTALL" != "true" ]; then
  run_hdc install -r "$POC_ENTRY_HAP"
fi
assert_runtime_idle_if_present

read_device_json "$PROFILES_JSON" "$TMP_DIR/profiles.json"
if [ -z "$PROFILE_ID" ]; then
  PROFILE_ID="$(json_value "$TMP_DIR/profiles.json" activeProfileId)"
fi
if [ -z "$TARGET_NODE" ]; then
  echo "M2_3_TARGET_NODE must name a node different from the saved selection" >&2
  exit 1
fi

if [ -z "$RESTORE_NODE" ]; then
  if ! read_device_json "$SELECTIONS_JSON" "$TMP_DIR/selections-before.json" 2>/dev/null; then
    echo "no saved selection found; set M2_3_RESTORE_NODE explicitly" >&2
    exit 1
  fi
  RESTORE_NODE="$(selection_node "$TMP_DIR/selections-before.json" "$PROFILE_ID" "$GROUP_NAME")"
fi
if [ -z "$RESTORE_NODE" ]; then
  echo "no saved selection found; set M2_3_RESTORE_NODE explicitly" >&2
  exit 1
fi
if [ "$TARGET_NODE" = "$RESTORE_NODE" ]; then
  echo "target node must differ from restore node: $TARGET_NODE" >&2
  exit 1
fi

echo "profile: $PROFILE_ID"
echo "switch: $RESTORE_NODE -> $TARGET_NODE -> $RESTORE_NODE"

start_home --ps mvpCommand connectProduct --ps profileId "$PROFILE_ID" >/dev/null
CONNECTED_BY_SMOKE=true
wait_for_runtime connected running

TARGET_REQUEST="select-target-$(date +%s)"
request_selection "$TARGET_REQUEST" "$TARGET_NODE"
read_device_json "$SELECTIONS_JSON" "$TMP_DIR/selections-target.json"
if [ "$(selection_node "$TMP_DIR/selections-target.json" "$PROFILE_ID" "$GROUP_NAME")" != "$TARGET_NODE" ]; then
  echo "target selection was not persisted" >&2
  exit 1
fi

RESTORE_REQUEST="select-restore-$(date +%s)"
request_selection "$RESTORE_REQUEST" "$RESTORE_NODE"
read_device_json "$SELECTIONS_JSON" "$TMP_DIR/selections-restored.json"
if [ "$(selection_node "$TMP_DIR/selections-restored.json" "$PROFILE_ID" "$GROUP_NAME")" != "$RESTORE_NODE" ]; then
  echo "original selection was not restored" >&2
  exit 1
fi

disconnect_smoke
wait_for_runtime idle stopped
trap - EXIT

echo "M2-3 proxy selection smoke PASS"
echo "final runtime: idle/stopped"
echo "logs: $TMP_DIR"
