# Modification Record

This distribution contains modified versions of upstream software. The Git history is the authoritative record of the exact changes.

## FluxGate License Change

- Date: 2026-08-05
- Change: FluxGate original code is licensed under `GPL-3.0-only` from this revision forward.
- Earlier releases: versions previously conveyed under AGPL-3.0 remain available under the license terms supplied with those copies.

## Mihomo Baseline

- Upstream: <https://github.com/MetaCubeX/mihomo>
- Version: `v1.19.27`
- Commit: `5184081ac327394d9e15fa5d5f9f4a61e723fd94`
- Modification period: 2026-06-12 through 2026-07-31

FluxGate adds an OpenHarmony C shared-library bridge, VPN/TUN file-descriptor integration, platform shims, configuration validation, lifecycle cleanup, DNS and listener adaptations, proxy selection, latency testing, traffic statistics, and defensive error handling. The relevant source is retained under `core/mihomo/openharmony_*` and in the modified Mihomo files recorded by Git.

## OpenHarmony Go Toolchain

- Upstream: <https://gitee.com/openharmony-sig/ohos_golang_go>
- Base commit: `ccab16a688b9331d0911016aee0e8a30a05fe2c8`
- Reported Go version: `go1.22.10`
- FluxGate runtime patch: `patches/poc02-openharmony-go-runtime.patch`

The patch adjusts arm64 TLS initialization and c-shared startup behavior required by the embedded Mihomo library. Reproduction and verification commands are documented in `patches/poc02-openharmony-go-runtime-notes.md`.
