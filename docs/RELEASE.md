# Release Checklist

The repository intentionally contains no certificate, provisioning profile, keystore, password, or developer-specific absolute path.

Signing credentials previously committed to repository history must be treated as compromised. Replace or revoke them before publishing; removing them from the current tree does not remove them from Git history.

## Signing

Before installing a build on a physical device or publishing it, configure a HarmonyOS signing profile for `com.fly.clashguard` in DevEco Studio or inject an equivalent signing configuration in CI. Never commit the generated credentials or machine paths.

Set `RELEASE_HAP` to the signed release artifact when running device verification:

```bash
RELEASE_GATE_DEVICE=true \
RELEASE_HAP=entry/build/default/outputs/default/entry-default-signed.hap \
scripts/run_release_gate.sh
```

Without signing, `scripts/build_release_hap.sh` still builds and verifies the unsigned release artifact.

## Required Checks

- Review `PRIVACY.md`, `THIRD_PARTY_NOTICES.md`, and dependency licenses.
- Confirm the bundled `geoip.metadb` source, license notice, and SHA-256 before updating it.
- Run `scripts/run_release_gate.sh`.
- Run the gate against a physical device with the exact signed release HAP.
- Confirm VPN consent, connection, disconnection, subscription update, configuration import, and foreground/background restoration manually.
- Publish the corresponding source code and release tag as required by AGPL-3.0 and GPL-3.0.
