#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="${1:-${OHOS_GO_ROOT:-}}"
EXPECTED_COMMIT='ccab16a688b9331d0911016aee0e8a30a05fe2c8'
PATCH_PATH="$ROOT_DIR/patches/poc02-openharmony-go-runtime.patch"

if [[ -z "$SOURCE_DIR" || ! -e "$SOURCE_DIR/.git" ]]; then
  echo 'usage: scripts/verify_toolchain_patch.sh /path/to/ohos_golang_go' >&2
  exit 2
fi

actual_commit="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
if [[ "$actual_commit" != "$EXPECTED_COMMIT" ]]; then
  echo "unexpected OpenHarmony Go base: $actual_commit" >&2
  echo "expected: $EXPECTED_COMMIT" >&2
  exit 1
fi

git -C "$SOURCE_DIR" apply --check --unidiff-zero "$PATCH_PATH"
echo "OpenHarmony Go runtime patch applies cleanly to $EXPECTED_COMMIT"
