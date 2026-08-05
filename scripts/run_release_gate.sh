#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/huawei_tools_env.sh"

RUN_DEVICE="${RELEASE_GATE_DEVICE:-false}"
RUN_M2_3="${RELEASE_GATE_M2_3:-false}"
STABILITY_CYCLES="${RELEASE_GATE_STABILITY_CYCLES:-5}"
BUILD_RELEASE="${RELEASE_GATE_BUILD_RELEASE:-true}"

echo "== FluxGate release gate =="
echo "device checks: $RUN_DEVICE"

echo "== shell syntax =="
bash -n "$ROOT_DIR"/scripts/*.sh

echo "== diff checks =="
git -C "$ROOT_DIR" diff --check -- . ':(exclude)patches/*.patch'
git -C "$ROOT_DIR/core/mihomo" diff --check

echo "== license compliance =="
"$ROOT_DIR/scripts/verify_legal_compliance.sh"

echo "== local unit tests =="
"$ROOT_DIR/scripts/run_local_unit_tests.sh"

echo "== Go config validation tests =="
GOCACHE="${POC04_GOCACHE:-/private/tmp/poc04-go-build-cache}" \
GOMODCACHE="${POC04_GOMODCACHE:-/private/tmp/poc04-go-mod-cache}" \
  go -C "$ROOT_DIR/core/mihomo" test ./openharmony_bridge

echo "== mihomo core =="
bash "$ROOT_DIR/scripts/build_poc04_mihomo_core.sh"

echo "== debug HAP =="
"$HVIGORW" --mode module -p module=entry@default -p product=default -p buildMode=debug assembleHap --no-daemon

if [ "$RUN_DEVICE" = "true" ]; then
  echo "== debug device regression =="
  echo "== M2-6 config reliability =="
  "$ROOT_DIR/scripts/run_m2_6_config_reliability_smoke.sh"

  if [ "$RUN_M2_3" = "true" ]; then
    if [ -z "${M2_3_TARGET_NODE:-}" ]; then
      echo "M2_3_TARGET_NODE is required when RELEASE_GATE_M2_3=true" >&2
      exit 2
    fi
    echo "== M2-3 proxy selection =="
    "$ROOT_DIR/scripts/run_m2_3_proxy_selection_smoke.sh"
  fi

  echo "== connection stability =="
  RELEASE_STABILITY_CYCLES="$STABILITY_CYCLES" \
  RELEASE_STABILITY_SKIP_INSTALL=true \
    "$ROOT_DIR/scripts/run_release_stability_smoke.sh"
fi

if [ "$BUILD_RELEASE" = "true" ]; then
  echo "== release HAP =="
  "$ROOT_DIR/scripts/build_release_hap.sh"

  if [ "$RUN_DEVICE" = "true" ]; then
    echo "== exact release HAP launch =="
    "$ROOT_DIR/scripts/run_release_launch_smoke.sh"
  fi
fi

echo "FluxGate release gate PASS"
