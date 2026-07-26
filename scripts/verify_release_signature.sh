#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/huawei_tools_env.sh"

HAP_PATH="${1:-$ROOT_DIR/entry/build/default/outputs/default/entry-default-signed.hap}"
SIGN_TOOL="${HAP_SIGN_TOOL:-$DEVECO_STUDIO_APP/Contents/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar}"
VERIFY_TMP_DIR="$(mktemp -d "${TMPDIR:-/private/tmp}/clashguard-signature.XXXXXX")"

cleanup() {
  rm -f "$VERIFY_TMP_DIR/cert-chain.cer" "$VERIFY_TMP_DIR/profile.p7b"
  rmdir "$VERIFY_TMP_DIR"
}
trap cleanup EXIT

if [ ! -f "$HAP_PATH" ]; then
  echo "signed release HAP not found: $HAP_PATH" >&2
  exit 1
fi
if [ ! -f "$SIGN_TOOL" ]; then
  echo "HAP signature verifier not found: $SIGN_TOOL" >&2
  exit 1
fi

if ! verify_output="$(java -jar "$SIGN_TOOL" verify-app \
  -inFile "$HAP_PATH" \
  -outCertChain "$VERIFY_TMP_DIR/cert-chain.cer" \
  -outProfile "$VERIFY_TMP_DIR/profile.p7b" 2>&1)"; then
  echo 'release HAP signature verification failed' >&2
  exit 1
fi

if [[ "$verify_output" != *"verify-app success"* ]]; then
  echo 'release HAP signature verification did not complete successfully' >&2
  exit 1
fi
if [[ "$verify_output" != *"profile type is: release"* ]]; then
  echo 'release HAP uses a debug Provision Profile; configure a release signing profile before tagging' >&2
  exit 1
fi

echo "release HAP signature PASS: $HAP_PATH"
