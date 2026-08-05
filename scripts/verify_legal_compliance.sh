#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RAW_DIR="$ROOT_DIR/entry/src/main/resources/rawfile"

required_files=(
  "$ROOT_DIR/LICENSE"
  "$ROOT_DIR/THIRD_PARTY_NOTICES.md"
  "$ROOT_DIR/MODIFICATIONS.md"
  "$ROOT_DIR/SOURCE_CODE.md"
  "$RAW_DIR/gpl-3.0.txt"
  "$RAW_DIR/third_party_notices.txt"
  "$RAW_DIR/third_party_licenses.txt"
  "$RAW_DIR/modifications.txt"
  "$RAW_DIR/source_code.txt"
)

for required_file in "${required_files[@]}"; do
  if [[ ! -s "$required_file" ]]; then
    echo "missing required legal file: $required_file" >&2
    exit 1
  fi
done

cmp "$ROOT_DIR/LICENSE" "$RAW_DIR/gpl-3.0.txt"
cmp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$RAW_DIR/third_party_notices.txt"
cmp "$ROOT_DIR/MODIFICATIONS.md" "$RAW_DIR/modifications.txt"
cmp "$ROOT_DIR/SOURCE_CODE.md" "$RAW_DIR/source_code.txt"

grep -q 'GNU GENERAL PUBLIC LICENSE' "$ROOT_DIR/LICENSE"
grep -q 'GPL-3.0-only' "$ROOT_DIR/README.md"
grep -q 'GPL-3.0-only' "$ROOT_DIR/entry/oh-package.json5"
if grep -q 'github.com/rasky/go-lzo\|accept this unresolved license-compliance risk' "$ROOT_DIR/THIRD_PARTY_NOTICES.md"; then
  echo 'third-party notices still contain the removed go-lzo disclosure' >&2
  exit 1
fi
grep -q 'github.com/fly2016git/mihomo_client_ohos' "$ROOT_DIR/SOURCE_CODE.md"

go_mod_sha256="$(shasum -a 256 "$ROOT_DIR/core/mihomo/go.mod" | awk '{print $1}')"
grep -q "Mihomo go.mod SHA-256: $go_mod_sha256" "$RAW_DIR/third_party_licenses.txt"

if rg -n 'storePassword|keyPassword|"storeFile"|"certpath"|/Users/' "$ROOT_DIR/build-profile.json5" >/dev/null; then
  echo 'build-profile.json5 contains signing secrets or developer-local paths' >&2
  exit 1
fi

echo 'license compliance resources PASS'
