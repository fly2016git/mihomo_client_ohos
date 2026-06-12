#!/usr/bin/env bash
# Source this file before running local HarmonyOS build/device commands:
#   source scripts/huawei_tools_env.sh

export DEVECO_STUDIO_APP="${DEVECO_STUDIO_APP:-/Applications/DevEco-Studio.app}"
export OHOS_SDK_HOME="${OHOS_SDK_HOME:-/Users/zhangpengfei/Library/OpenHarmony/Sdk/20}"
export OHOS_NDK_HOME="${OHOS_NDK_HOME:-$OHOS_SDK_HOME/native}"
export OHOS_TOOLCHAINS_HOME="${OHOS_TOOLCHAINS_HOME:-$OHOS_SDK_HOME/toolchains}"

export HVIGORW="${HVIGORW:-$DEVECO_STUDIO_APP/Contents/tools/hvigor/bin/hvigorw}"
export HDC="${HDC:-$OHOS_TOOLCHAINS_HOME/hdc}"
export OHOS_CLANG="${OHOS_CLANG:-$OHOS_NDK_HOME/llvm/bin/aarch64-unknown-linux-ohos-clang}"
export OHOS_CLANGXX="${OHOS_CLANGXX:-$OHOS_NDK_HOME/llvm/bin/aarch64-unknown-linux-ohos-clang++}"
export OHOS_LLVM_NM="${OHOS_LLVM_NM:-$OHOS_NDK_HOME/llvm/bin/llvm-nm}"
export OHOS_LLVM_READELF="${OHOS_LLVM_READELF:-$OHOS_NDK_HOME/llvm/bin/llvm-readelf}"

export OHOS_GO="${OHOS_GO:-/private/tmp/ohos_golang_go/bin/go}"

export POC_DEVICE_TARGET="${POC_DEVICE_TARGET:-192.168.3.65:41235}"
export POC_ENTRY_HAP="${POC_ENTRY_HAP:-entry/build/default/outputs/default/entry-default-signed.hap}"
export POC_BUNDLE_NAME="${POC_BUNDLE_NAME:-com.example.mihomopoc}"
export POC_ENTRY_ABILITY="${POC_ENTRY_ABILITY:-EntryAbility}"
