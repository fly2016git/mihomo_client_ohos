#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/huawei_tools_env.sh"

bash "$ROOT_DIR/scripts/build_poc04_mihomo_core.sh"
"$HVIGORW" --mode module -p module=entry@default -p product=default -p buildMode=release assembleHap --no-daemon

if [ ! -f "$ROOT_DIR/$POC_ENTRY_HAP" ]; then
  echo "release HAP not found: $ROOT_DIR/$POC_ENTRY_HAP" >&2
  exit 1
fi

echo "built release HAP: $ROOT_DIR/$POC_ENTRY_HAP"
