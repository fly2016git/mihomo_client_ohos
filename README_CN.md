# FluxGate

[English](README.md) | 简体中文

FluxGate 是一款基于 Mihomo 的 HarmonyOS VPN 客户端，支持导入 Mihomo YAML 配置并通过系统 VPN 接管网络流量。

当前版本：`v1.0.2`

应用包名：`com.fly.fluxgate`

## 主要功能

- 支持本地文件、订阅链接和二维码导入配置；
- 支持规则、全局和直连等运行模式；
- 支持代理组与节点切换；
- 支持节点延迟测试及备用检测地址；
- 提供实时流量、运行日志和诊断信息；
- 支持 HarmonyOS 手机和平板设备。

## 基本使用

1. 打开应用，点击“添加配置”。
2. 选择文件、订阅链接或二维码方式导入 Mihomo YAML 配置。
3. 返回首页并确认当前配置，然后点击“连接”。
4. 首次连接时，按照系统提示允许 FluxGate 创建 VPN 连接。
5. 连接成功后，可在“节点”页面查看节点、切换节点或执行测速。
6. 使用结束后返回首页，点击“断开”。

仓库提供了仅使用 Mihomo 内置 `DIRECT` 的测试配置：[docs/fluxgate-test.yaml](docs/fluxgate-test.yaml)。该配置只用于验证导入、连接、测速和断开流程，不提供代理能力。

## 开发与构建

开发环境需要 DevEco Studio、HarmonyOS SDK 和项目依赖工具。

安装依赖：

```bash
ohpm install
```

运行单元测试：

```bash
scripts/run_local_unit_tests.sh
```

构建 Debug HAP：

```bash
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  --mode module \
  -p product=default \
  -p module=entry@default \
  -p buildMode=debug \
  assembleHap --no-daemon
```

构建 Release HAP：

```bash
scripts/build_release_hap.sh
```

构建 AppGallery 使用的 `.app`：

```bash
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  assembleApp -p product=default -p buildMode=release --no-daemon
```

Release 构建前需在 DevEco Studio 中配置有效的正式证书和 Release Provision Profile。请勿将证书、私钥或密码提交到仓库。

## 相关文档

- [发布说明](docs/RELEASE.md)
- [隐私政策](PRIVACY.md)
- [用户服务协议](TERMS.md)
- [第三方软件声明](THIRD_PARTY_NOTICES.md)

## 许可证

本项目采用 [GNU AGPL-3.0](LICENSE) 许可证。Mihomo 及其他第三方组件同时受其各自许可证约束。
