#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/huawei_tools_env.sh"

RESULT_FILE="$ROOT_DIR/entry/.test/default/intermediates/test/coverage_data/test_result.txt"
rm -f "$RESULT_FILE"

"$HVIGORW" --mode module \
  -p product=default \
  -p module=entry@default \
  -p buildMode=debug \
  -p ohos-test-coverage=false \
  test --no-daemon

if [ ! -f "$RESULT_FILE" ]; then
  echo "unit test result not found: $RESULT_FILE" >&2
  exit 1
fi

if rg -q '^result=(Failure|Error)$' "$RESULT_FILE" || \
  ! rg -q '^Tests run: [0-9]+, Failure: 0, Error: 0, Pass: [0-9]+, Ignore: [0-9]+$' "$RESULT_FILE"; then
  cat "$RESULT_FILE" >&2
  exit 1
fi

tail -n 1 "$RESULT_FILE"
