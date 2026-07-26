# Release Checklist

The repository intentionally contains no certificate, provisioning profile, keystore, password, or developer-specific absolute path.

Signing credentials previously committed to repository history must be treated as compromised. Replace or revoke them before publishing; removing them from the current tree does not remove them from Git history.

## Signing

Before installing a build on a physical device or publishing it, configure a HarmonyOS signing profile for `com.fly.clashguard` in DevEco Studio or inject an equivalent signing configuration in CI. Never commit the generated credentials or machine paths.

An AppGallery Release Provision Profile is accepted only through AppGallery distribution. The resulting HAP cannot be installed directly with `hdc`; exact-artifact device verification must use an AppGallery internal-test release.

For local device regression, build the same release-mode code with a development signing profile that includes the test device. Run the automated debug device checks separately from the final AppGallery build:

```bash
RELEASE_GATE_DEVICE=true \
RELEASE_GATE_BUILD_RELEASE=false \
scripts/run_release_gate.sh

scripts/build_release_hap.sh
```

`scripts/build_release_hap.sh` requires a Release certificate and Release Provision Profile, and rejects debug-signed output.

## Required Checks

- Review `PRIVACY.md`, `THIRD_PARTY_NOTICES.md`, and dependency licenses.
- Confirm the bundled `geoip.metadb` source, license notice, and SHA-256 before updating it.
- Run `scripts/run_release_gate.sh`.
- Run local device regression against the release-mode code using a device-compatible development profile.
- Install the exact AppGallery-signed HAP through an AppGallery internal-test release before production rollout.
- Confirm VPN consent, connection, disconnection, subscription update, configuration import, and foreground/background restoration manually.
- Publish the corresponding source code and release tag as required by AGPL-3.0 and GPL-3.0.
