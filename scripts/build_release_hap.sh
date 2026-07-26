#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/huawei_tools_env.sh"

RELEASE_HAP="${RELEASE_HAP:-entry/build/default/outputs/default/entry-default-unsigned.hap}"
SIGNED_RELEASE_HAP="${SIGNED_RELEASE_HAP:-entry/build/default/outputs/default/entry-default-signed.hap}"

bash "$ROOT_DIR/scripts/build_poc04_mihomo_core.sh"
"$HVIGORW" --mode module -p module=entry@default -p product=default -p buildMode=release assembleHap --no-daemon

if [ ! -f "$ROOT_DIR/$RELEASE_HAP" ]; then
  echo "release HAP not found: $ROOT_DIR/$RELEASE_HAP" >&2
  exit 1
fi

"$ROOT_DIR/scripts/verify_release_hap.sh" "$ROOT_DIR/$RELEASE_HAP"
if [ ! -f "$ROOT_DIR/$SIGNED_RELEASE_HAP" ]; then
  echo "signed release HAP not found: $ROOT_DIR/$SIGNED_RELEASE_HAP" >&2
  exit 1
fi
"$ROOT_DIR/scripts/verify_release_hap.sh" "$ROOT_DIR/$SIGNED_RELEASE_HAP"
"$ROOT_DIR/scripts/verify_release_signature.sh" "$ROOT_DIR/$SIGNED_RELEASE_HAP"
echo "built release HAP: $ROOT_DIR/$SIGNED_RELEASE_HAP"
