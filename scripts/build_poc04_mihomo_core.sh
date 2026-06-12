#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/huawei_tools_env.sh"

MIHOMO_DIR="${MIHOMO_DIR:-$ROOT_DIR/core/mihomo}"
POC04_BRIDGE_PKG="${POC04_BRIDGE_PKG:-./openharmony_bridge}"
OUT_DIR="$ROOT_DIR/entry/libs/arm64-v8a"
OUT_SO="$OUT_DIR/libmihomo_ohos.so"
POC04_GOCACHE="${POC04_GOCACHE:-/private/tmp/poc04-go-build-cache}"
POC04_GOMODCACHE="${POC04_GOMODCACHE:-/private/tmp/poc04-go-mod-cache}"
POC04_GOPROXY="${POC04_GOPROXY:-https://goproxy.cn,direct}"
POC04_BUILD_TAGS="${POC04_BUILD_TAGS:-with_gvisor no_tailscale}"
POC04_LDFLAGS="${POC04_LDFLAGS:--s -w -X github.com/metacubex/mihomo/constant.Version=v1.19.27-poc04 -X github.com/metacubex/mihomo/constant.BuildTime=poc04}"

mkdir -p "$OUT_DIR"
mkdir -p "$POC04_GOCACHE"
mkdir -p "$POC04_GOMODCACHE"

cd "$MIHOMO_DIR"

GOOS=openharmony \
GOARCH=arm64 \
CGO_ENABLED=1 \
GOCACHE="$POC04_GOCACHE" \
GOMODCACHE="$POC04_GOMODCACHE" \
GOPROXY="$POC04_GOPROXY" \
CC="$OHOS_CLANG" \
CXX="$OHOS_CLANGXX" \
"$OHOS_GO" build \
  -buildmode=c-shared \
  -tags "$POC04_BUILD_TAGS" \
  -ldflags "$POC04_LDFLAGS" \
  -o "$OUT_SO" \
  "$POC04_BRIDGE_PKG"

if [[ -x "$OHOS_LLVM_NM" ]]; then
  echo "checking exported symbols..."
  "$OHOS_LLVM_NM" -D "$OUT_SO" | grep -E 'MihomoOhos' || true
  "$OHOS_LLVM_NM" -D "$OUT_SO" | grep -E 'MihomoOhos(Version|Ping|StartConfig|StartConfigFile|StartConfigFileWithTunFd|Stop|GracefulStop|SetProtectBridge|EnableProtectHook|DisableProtectHook|IsRunning|LastError|FreeCString)' >/dev/null
fi

echo "built $OUT_SO"
