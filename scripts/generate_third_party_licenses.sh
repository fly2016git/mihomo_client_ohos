#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIHOMO_DIR="$ROOT_DIR/core/mihomo"
OUTPUT_PATH="${1:-$ROOT_DIR/entry/src/main/resources/rawfile/third_party_licenses.txt}"
LICENSE_GOMODCACHE="${LICENSE_GOMODCACHE:-/private/tmp/fluxgate-license-mod-cache}"
LICENSE_GOCACHE="${LICENSE_GOCACHE:-/private/tmp/fluxgate-license-build-cache}"
BUILD_TAGS="${LICENSE_BUILD_TAGS:-openharmony with_gvisor no_tailscale}"
YAML_LICENSE="$ROOT_DIR/oh_modules/.ohpm/yaml@2.8.0/oh_modules/yaml/LICENSE"
GO_TOOLCHAIN_LICENSE="$ROOT_DIR/licenses/OpenHarmony-Go-BSD-3-Clause.txt"
TEMP_DIR="$(mktemp -d)"
MODULES_JSON="$TEMP_DIR/modules.json"
trap 'rm -rf "$TEMP_DIR"' EXIT

for command_name in go jq find shasum; do
  if ! command -v "$command_name" >/dev/null; then
    echo "required command not found: $command_name" >&2
    exit 2
  fi
done

if [[ ! -f "$YAML_LICENSE" ]]; then
  echo 'yaml 2.8.0 license not found; run ohpm install first' >&2
  exit 2
fi
if [[ ! -f "$GO_TOOLCHAIN_LICENSE" ]]; then
  echo 'OpenHarmony Go toolchain license not found' >&2
  exit 2
fi

(
  cd "$MIHOMO_DIR"
  GOCACHE="$LICENSE_GOCACHE" \
  GOMODCACHE="$LICENSE_GOMODCACHE" \
  GOPROXY="${GOPROXY:-https://goproxy.cn,direct}" \
  GOOS=linux \
  GOARCH=arm64 \
  CGO_ENABLED=1 \
    go list -deps -json -tags "$BUILD_TAGS" ./openharmony_bridge
) | jq -s '
  [.[]
    | select(.Standard != true and .Module != null)
    | {
        path: .Module.Path,
        version: (.Module.Version // "local"),
        dir: .Module.Dir
      }
  ]
  | unique_by(.path)
  | sort_by(.path)
' >"$MODULES_JSON"

mkdir -p "$(dirname "$OUTPUT_PATH")"
{
  printf 'FluxGate Third-Party License Texts\n'
  printf '===================================\n\n'
  printf 'Generated from the OpenHarmony arm64 production dependency graph.\n'
  printf 'Mihomo go.mod SHA-256: %s\n\n' "$(shasum -a 256 "$MIHOMO_DIR/go.mod" | awk '{print $1}')"
  printf 'The FluxGate and Mihomo GPL-3.0 text is provided separately as gpl-3.0.txt.\n\n'

  printf '%s\n' '------------------------------------------------------------------------'
  printf 'Component: OpenHarmony Go runtime\n'
  printf 'Base commit: ccab16a688b9331d0911016aee0e8a30a05fe2c8\n'
  printf 'File: LICENSE\n\n'
  sed -e 's/[[:space:]]*$//' -e '$a\' "$GO_TOOLCHAIN_LICENSE"

  while IFS=$'\t' read -r module_path module_version module_dir; do
    if [[ "$module_path" == 'github.com/metacubex/mihomo' ]]; then
      continue
    fi
    license_files="$(find "$module_dir" -maxdepth 2 -type f \( -iname 'LICENSE*' -o -iname 'COPYING*' -o -iname 'NOTICE*' \) | sort)"
    if [[ -z "$license_files" ]]; then
      echo "no license file found for $module_path ($module_dir)" >&2
      exit 1
    fi
    printf '\n------------------------------------------------------------------------\n'
    printf 'Module: %s\nVersion: %s\n' "$module_path" "$module_version"
    while IFS= read -r license_file; do
      printf '\nFile: %s\n\n' "${license_file#"$module_dir"/}"
      sed -e 's/[[:space:]]*$//' -e '$a\' "$license_file"
    done <<<"$license_files"
  done < <(jq -r '.[] | [.path, .version, .dir] | @tsv' "$MODULES_JSON")

  printf '\n------------------------------------------------------------------------\n'
  printf 'Package: yaml\nVersion: 2.8.0\nFile: LICENSE\n\n'
  sed -e 's/[[:space:]]*$//' -e '$a\' "$YAML_LICENSE"
} >"$OUTPUT_PATH"

echo "generated $OUTPUT_PATH"
