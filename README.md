# FluxGate

English | [简体中文](README_CN.md)

FluxGate is a Mihomo-based VPN client for HarmonyOS. It imports Mihomo YAML configurations and routes network traffic through the system VPN service.

Current version: `v1.0.3`

Bundle name: `com.fly.fluxgate`

## Features

- Import configurations from local files, subscription URLs, or QR codes;
- Support rule, global, and direct operating modes;
- View proxy groups and switch nodes;
- Test node latency with a fallback connectivity endpoint;
- Display real-time traffic, runtime logs, and diagnostic information;
- Support HarmonyOS phones and tablets.

## Basic Usage

1. Open FluxGate and tap **Add Configuration**.
2. Import a Mihomo YAML configuration from a file, subscription URL, or QR code.
3. Return to the home page, confirm the active configuration, and tap **Connect**.
4. When connecting for the first time, allow FluxGate to create a VPN connection in the system prompt.
5. After the VPN is connected, open the **Nodes** page to view nodes, switch nodes, or run a latency test.
6. When finished, return to the home page and tap **Disconnect**.

The repository includes a test configuration that uses Mihomo's built-in `DIRECT` outbound: [docs/fluxgate-test.yaml](docs/fluxgate-test.yaml). It is intended only for testing configuration import, connection, latency testing, and disconnection. It does not provide proxy functionality.

## Development and Build

Development requires DevEco Studio, the HarmonyOS SDK, and the project dependency tools.

Install dependencies:

```bash
ohpm install
```

Run unit tests:

```bash
scripts/run_local_unit_tests.sh
```

Build a Debug HAP:

```bash
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  --mode module \
  -p product=default \
  -p module=entry@default \
  -p buildMode=debug \
  assembleHap --no-daemon
```

Build a Release HAP:

```bash
scripts/build_release_hap.sh
```

Build an `.app` package for AppGallery:

```bash
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  assembleApp -p product=default -p buildMode=release --no-daemon

scripts/verify_release_app.sh build/outputs/default/MyApplication-default-unsigned.app
```

Before building a release package, configure a valid release certificate and Release Provision Profile in DevEco Studio. Never commit certificates, private keys, or passwords to the repository.

## Documentation

- [Release guide](docs/RELEASE.md)
- [Privacy policy](PRIVACY.md)
- [Terms of service](TERMS.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)
- [Third-party license texts](entry/src/main/resources/rawfile/third_party_licenses.txt)
- [Modification record](MODIFICATIONS.md)
- [Corresponding source information](SOURCE_CODE.md)

## License

FluxGate is licensed under the [GNU GPL-3.0-only](LICENSE). Mihomo and other third-party components remain subject to their respective licenses. Versions previously released under AGPL-3.0 remain available under the license terms that accompanied those versions.
