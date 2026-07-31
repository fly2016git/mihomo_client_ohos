# FluxGate v1.0.2

## Changes

- Validate imported and QR-code configurations in ArkTS to reject malformed YAML without crashing the VPN process.
- Run node latency tests through the local Mihomo controller with primary and fallback connectivity URLs.
- Gate proxy operations on the active VPN runtime and improve connection request acknowledgement.
- Stop traffic polling and destroy the system VPN before terminating the VPN extension, avoiding intermittent disconnect crashes.

## Package

- `FluxGate-v1.0.2.app`: signed HarmonyOS AppGallery release package.
- `SHA256SUMS`: SHA-256 checksum for the release package.
