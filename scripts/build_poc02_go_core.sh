#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$ROOT_DIR/scripts/huawei_tools_env.sh" ]; then
  # shellcheck source=scripts/huawei_tools_env.sh
  source "$ROOT_DIR/scripts/huawei_tools_env.sh"
fi

GO_CORE_DIR="$ROOT_DIR/poc/go-core"
OUT_DIR="$ROOT_DIR/entry/libs/arm64-v8a"
OUT_SO="$OUT_DIR/libpoc_go_core.so"
GO_CACHE_DIR="${GOCACHE:-$ROOT_DIR/.cache/go-build}"
GO_CMD="${POC_GO:-go}"
TARGET_GOOS="${POC_GOOS:-linux}"

if ! command -v "$GO_CMD" >/dev/null 2>&1; then
  echo "go command not found: $GO_CMD. Install or set POC_GO to an OpenHarmony-compatible Go toolchain before building POC-02 Go core." >&2
  exit 127
fi

mkdir -p "$OUT_DIR"
mkdir -p "$GO_CACHE_DIR"

export GOOS="$TARGET_GOOS"
export GOARCH=arm64
export CGO_ENABLED="${CGO_ENABLED:-1}"
export GOCACHE="$GO_CACHE_DIR"
export CC="${OHOS_CLANG:-${OHOS_NDK_HOME:-/Users/zhangpengfei/Library/OpenHarmony/Sdk/20/native}/llvm/bin/aarch64-unknown-linux-ohos-clang}"
export CXX="${OHOS_CLANGXX:-${OHOS_NDK_HOME:-/Users/zhangpengfei/Library/OpenHarmony/Sdk/20/native}/llvm/bin/aarch64-unknown-linux-ohos-clang++}"

cd "$GO_CORE_DIR"
"$GO_CMD" build -buildmode=c-shared -o "$OUT_SO" .

echo "Generated $OUT_SO"
