# HarmonyOS mihomo 客户端产品设计方案

## 1. 背景与结论

目标是在 HarmonyOS NEXT 上开发一个原生代理客户端，支持 Clash/mihomo 配置、订阅管理、节点选择、规则分流、VPN/TUN 全局接管、日志诊断和基础流量统计。

核心结论：

- 不建议直接移植 Clash Verge Rev。Clash Verge Rev 是 Tauri + Rust + React 的桌面客户端，面向 Windows、macOS、Linux，不适合直接运行在 HarmonyOS 原生应用模型中。
- 可以开发一个 HarmonyOS 原生客户端，复用或移植 mihomo 作为底层代理核心。
- 确定采用 native `.so` 方案：ArkTS/ArkUI 做 UI，VpnExtensionAbility 创建 TUN，NAPI/C++ 桥接 Go 编译出的 mihomo native 动态库。
- 产品立项前应先完成技术 POC，重点验证 TUN fd、Go `.so`、socket protect、DNS/UDP 四个关键点。

参考项目和文档：

- mihomo: https://github.com/MetaCubeX/mihomo
- Clash Verge Rev: https://github.com/clash-verge-rev/clash-verge-rev
- OpenHarmony VPN Extension: https://gitee.com/openharmony/docs/blob/08986484ea997e1da01ac9221d20dbb0a54b4922/en/application-dev/network/net-vpnExtension.md
- OpenHarmony NDK/NAPI: https://gitee.com/openharmony/docs/blob/9c5954d6491ee755e5f2c5d4ffbc707056ef0141/en/application-dev/napi/ndk-development-overview.md
- OpenHarmony Go 适配项目: https://gitee.com/openharmony-sig/ohos_golang_go

## 2. 产品定位

产品定位为 HarmonyOS NEXT 原生 Clash/mihomo 客户端。

候选名称：

- MetaNet
- ProxyKit
- Mihomo for Harmony
- FlowGuard

目标：

- 支持导入 Clash/mihomo YAML 配置。
- 支持订阅链接更新。
- 支持代理组和节点选择。
- 支持规则模式、全局模式、直连模式。
- 支持 VPN/TUN 全局接管系统流量。
- 支持日志、流量统计和基础诊断。

第一版目标不是完整复制 Clash Verge Rev，而是做出稳定可用的移动端体验。

## 3. 目标用户

主要用户：

- 需要在 HarmonyOS 设备上使用 Clash/mihomo 配置的用户。
- 有订阅链接、Clash YAML 配置、规则分流需求的高级用户。
- 需要可视化管理节点、延迟测试、日志排查的用户。

第一版不建议面向完全小白用户，因为 VPN、订阅、规则、DNS、TUN 等概念会增加产品解释成本。

## 4. 版本范围

### 4.1 MVP 必须包含

1. 导入 Clash/mihomo YAML 配置。
2. 支持订阅链接更新。
3. 展示代理组、节点列表、当前选择。
4. 启动和停止 VPN。
5. 基于 VPN/TUN 接管系统流量。
6. 支持规则模式、全局模式、直连模式。
7. 展示运行日志。
8. 展示当前上下行速度。
9. 支持基础 DNS 配置。
10. 支持配置文件本地存储和切换。

### 4.2 MVP 暂不包含

- 复杂脚本规则。
- 深度进程分流。
- 桌面端系统代理功能。
- 多设备同步。
- 云端账户体系。
- 规则市场。
- 插件系统。
- 非必要动画和皮肤。

## 5. 整体架构

推荐架构：

```text
HarmonyOS App
├── ArkTS / ArkUI
│   ├── 首页仪表盘
│   ├── 配置管理
│   ├── 节点选择
│   ├── 规则模式
│   ├── 日志页
│   └── 设置页
│
├── Service / State Layer
│   ├── ProfileService
│   ├── SubscriptionService
│   ├── CoreControlService
│   ├── VpnService
│   ├── LogService
│   └── TrafficService
│
├── VpnExtensionAbility
│   ├── 创建 VPN/TUN
│   ├── 获取 tunFd
│   ├── protect 出站 socket
│   ├── CoreRuntime 生命周期管理
│   └── 与 UI Ability 通信
│
├── NAPI Bridge / C++
│   ├── nativeStart(configPath, homeDir, tunFd)
│   ├── stopCore()
│   ├── reloadConfig()
│   ├── selectProxy(group, proxy)
│   ├── getStats()
│   ├── streamLogs()
│   └── socket protect callback
│
└── libmihomo_ohos.so
    ├── mihomo core
    ├── TUN adapter
    ├── DNS
    ├── Rule engine
    ├── Proxy outbound
    └── REST/control bridge
```

关键原则：

- TUN 由 HarmonyOS VPN Extension 创建。
- mihomo 只消费外部传入的 TUN fd，不自己创建系统 VPN。
- App UI 不直接操作 mihomo 内部状态，统一通过 Service 层和 NAPI Bridge 访问。
- 出站 socket 必须经过 HarmonyOS protect 逻辑，避免 VPN 流量回环。
- native core 应由 VpnExtensionAbility 或绑定其生命周期的 CoreRuntime 持有，不应由普通 UI Ability 直接持有。tunFd 的生命周期、VPN 权限和后台运行边界都属于 VPN Extension。
- tunFd 所有权必须明确：如果 native 层需要长期持有，应复制 fd 或约定唯一 owner，避免重复 close、提前 close 和 fd 泄漏。

## 6. 核心技术设计

### 6.1 mihomo 集成方案

已确定采用 native `.so` 方案。

不再按桌面端 sidecar 方式启动 mihomo 可执行文件。mihomo core 应编译为 HarmonyOS 可加载的动态库，并通过 C ABI 暴露最小控制接口，再由 C++ NAPI bridge 提供给 ArkTS/VpnExtensionAbility 调用。

建议分为两层接口：

- UI 控制接口：面向 ArkTS 页面和状态层，表达用户意图，如连接、断开、切换配置、切换节点。
- Native core 接口：面向 VpnExtensionAbility/CoreRuntime，直接管理 tunFd、core 生命周期、日志和统计。

### 6.2 Native `.so` 构建要求

Go 侧建议使用 `buildmode=c-shared` 输出动态库，并暴露稳定 C ABI。C++ NAPI 层负责把 ArkTS/HarmonyOS 的对象、fd 和回调转换为 native core 可消费的数据结构。

基础要求：

- 输出 `libmihomo_ohos.so` 和对应 C header。
- 明确目标 ABI，第一阶段优先支持 `arm64-v8a` / `aarch64`。
- 构建脚本固定 Go 工具链、HarmonyOS NDK、build tags 和 cgo 参数。
- 所有导出函数使用简单 C 类型，避免跨语言传递复杂对象。
- native core 内部必须自行管理 goroutine 生命周期，`stop` 后不能遗留读 TUN、DNS、测速或日志 goroutine。
- crash、panic、fatal log 不能直接杀掉 UI 进程，应转换为错误事件并上报。

### 6.3 Bridge 接口

```ts
interface CoreControlBridge {
  requestStart(profileId: string): Promise<void>
  requestStop(): Promise<void>
  requestReload(profileId: string): Promise<void>
  selectProxy(group: string, proxy: string): Promise<void>
  getSnapshot(): Promise<RuntimeSnapshot>
  subscribeEvents(callback: (event: RuntimeEvent) => void): void
}
```

```ts
interface NativeCoreBridge {
  nativeStart(options: {
    configPath: string
    homeDir: string
    tunFd: number
  }): Promise<void>
  stop(): Promise<void>
  reload(configPath: string): Promise<void>
  selectProxy(group: string, proxy: string): Promise<void>
  getTraffic(): Promise<TrafficStats>
  getRuntimeState(): Promise<CoreState>
  subscribeLogs(callback: (line: LogLine) => void): void
}
```

说明：

- `CoreControlBridge` 给 UI 和业务层使用。
- `NativeCoreBridge` 只应在 VpnExtensionAbility/CoreRuntime 内使用。
- UI 层不直接传 tunFd，也不直接启动 native core。
- 日志和统计建议通过事件流上报，避免 UI 轮询过重。

### 6.4 VPN 启动流程

```text
用户点击连接
→ 请求 VPN 权限
→ 启动 VpnExtensionAbility
→ 创建 VPN config
→ 获取 tunFd
→ 初始化 CoreRuntime
→ 启动 libmihomo_ohos.so
→ mihomo 读取 TUN 流量
→ mihomo 出站 socket 通过 native callback 调用 protect
→ 状态变为 Connected
```

### 6.5 VPN 断开流程

```text
用户点击断开
→ CoreRuntime 进入 stopping
→ stop mihomo，停止读写 TUN
→ 等待 goroutine / native worker 退出
→ close tunFd 或释放 fd owner
→ destroy VPN
→ 清理状态
```

### 6.6 HarmonyOS Adapter

需要为 mihomo 增加 HarmonyOS 适配层：

- 接收外部 TUN fd。
- 替换或禁用 Linux-only TUN 创建逻辑。
- 增加 socket protect callback。
- 处理 App 沙箱目录下的配置、cache、geo 数据路径。
- 关闭或替换 iptables、nftables、netlink、process rule 等不适配移动端或 HarmonyOS 的能力。

### 6.7 socket protect 设计

socket protect 是 native `.so` 方案的核心风险点之一。目标是让代理出站连接绕过本 App 创建的 VPN，否则会出现代理流量再次进入 TUN 的回环。

设计要求：

- mihomo outbound dialer 创建 socket 后、connect 前，必须触发 protect。
- Go core 不直接调用 ArkTS API，应通过 C ABI 调用 C++ adapter 注册的 protect callback。
- protect callback 内部调用 HarmonyOS VPN Extension 的 protect 能力。
- protect 失败时，本次 outbound 连接必须失败并记录日志，不能静默降级。
- POC 必须在 VPN 已启动的情况下验证 protect，否则普通 socket 测试不能证明回环问题已解决。

protect hook 启用 / 禁用必须满足：

- Go bridge 提供两组对称的 C ABI 入口：`MihomoOhosEnableProtectHook()` 和 `MihomoOhosDisableProtectHook()`。
- enable 内部必须真正写入 `dialer.DefaultSocketHook = mihomoProtectSocketHook` 并打印激活日志，绝不能"看似启用、实际禁用"。
- disable 内部必须先 `protectOn = false; DefaultSocketHook = nil`，再等待在飞 protect 调用结束（`waitProtectIdleLocked`），避免 hook 中途被解绑导致悬空指针。
- ArkTS 侧必须用同步 NAPI 调用，避免 OpenHarmony Go runtime TLS 跨 worker 线程 cgo crash。
- 安全停止必须先 disable hook → graceful stop（`hub.Parse(stoppedConfig)`） → VPN destroy，三步顺序不可调换。

### 6.8 配置和控制面

第一版建议优先使用 native bridge 控制 mihomo，而不是对外暴露 REST controller。

如果为了复用 mihomo 现有控制逻辑必须启用 `external-controller`：

- 只能绑定 `127.0.0.1`。
- 必须生成随机 secret。
- 不允许暴露到局域网。
- UI 侧访问 controller 的能力应封装在 CoreService 内，不让页面直接拼 HTTP 请求。

配置文件需要在启动前做移动端适配：

- 写入 App 沙箱内的 `homeDir`、cache 目录和 geo 数据目录。
- 禁用第一版不支持的字段或给出明确错误。
- 统一生成 DNS、TUN、mixed-port、external-controller 等运行时字段。
- 保留原始订阅文件和实际运行文件，便于问题排查。

## 7. 产品页面设计

### 7.1 首页

功能：

- 显示连接状态：未连接、连接中、已连接、异常。
- 主按钮：连接 / 断开。
- 显示当前配置名称。
- 显示当前模式：规则 / 全局 / 直连。
- 显示当前代理组和选中节点。
- 显示实时上下行速度。
- 显示今日流量。

### 7.2 配置页

功能：

- 本地 YAML 导入。
- 订阅 URL 添加。
- 手动刷新订阅。
- 配置切换。
- 配置重命名。
- 配置删除。
- 显示最后更新时间、节点数量、规则数量。

### 7.3 节点页

功能：

- 按代理组展示节点。
- 节点搜索。
- 延迟测试。
- 展示延迟、协议类型、倍率信息。
- 点击切换节点。
- 支持自动选择策略组。

### 7.4 日志页

功能：

- 实时日志流。
- 日志级别过滤：Debug / Info / Warning / Error。
- 关键词搜索。
- 一键复制诊断信息。
- 导出日志文件。

### 7.5 设置页

功能：

- 启动模式：规则 / 全局 / 直连。
- DNS 模式：默认 / fake-ip / redir-host。
- IPv6 开关。
- UDP 开关。
- 连接后自动更新订阅。
- 日志级别。
- 清理缓存。
- 开机自启，如系统允许。

## 8. 数据模型

```ts
type Profile = {
  id: string
  name: string
  type: 'local' | 'subscription'
  sourceUrl?: string
  localPath: string
  updatedAt: number
  active: boolean
}

type ProxyGroup = {
  name: string
  type: string
  selected: string
  proxies: ProxyNode[]
}

type ProxyNode = {
  name: string
  type: string
  latency?: number
  alive?: boolean
}

type AppRuntime = {
  vpnState: 'idle' | 'starting' | 'connected' | 'stopping' | 'error'
  coreState: 'stopped' | 'running' | 'error'
  mode: 'rule' | 'global' | 'direct'
  uploadSpeed: number
  downloadSpeed: number
}
```

## 9. 目录结构建议

```text
app/
├── entry/
│   └── src/main/ets/
│       ├── pages/
│       ├── components/
│       ├── services/
│       ├── stores/
│       ├── models/
│       ├── vpn/
│       └── bridge/
│
├── native/
│   ├── napi_bridge/
│   ├── mihomo_adapter/
│   └── CMakeLists.txt
│
├── core/
│   ├── mihomo/
│   ├── patches/
│   ├── c_api/
│   └── build_ohos.sh
│
└── tests/
```

## 10. 开发流程

### 10.1 阶段 0：技术预研

预计周期：2-3 周。

目标：

- 只验证能不能跑，不做完整 UI。

任务：

- 创建最小 HarmonyOS App。
- 启动 VpnExtensionAbility。
- 创建 VPN 并拿到 tunFd。
- ArkTS 通过 NAPI 调用 native `.so`。
- Go 编译出的最小 `.so` 在真机加载。
- native 层读写 TUN fd。
- 发起一个被 protect 的出站 socket。
- 验证 native worker 可以启动、停止、重复启动，不崩溃、不泄漏 fd。
- 验证 TCP、UDP、DNS。

验收标准：

- App 可以成功创建 VPN。
- 能拿到可读写的 TUN fd。
- Go `.so` 能被加载并执行。
- TCP 请求可以在 VPN 已启动的情况下通过 TUN 跑通。
- UDP/DNS 至少完成一个基础验证。
- protect 失败时能看到明确错误；protect 成功时没有流量回环。
- 连续启动和停止 20 次后 App 不崩溃，系统网络恢复正常。

### 10.2 阶段 1：mihomo 最小集成

预计周期：3-5 周。

任务：

- fork mihomo。
- 增加 HarmonyOS build target。
- 去掉或替换 Linux/Android 不兼容代码。
- 增加外部 TUN fd 注入能力。
- 增加 socket protect callback。
- 封装 start、stop、reload、stats、logs。
- 固化 native `.so` 构建脚本和 patch 管理方式。
- 跑通一个固定 YAML 配置。

验收标准：

- 使用固定配置可以连接节点。
- 系统浏览器流量可以被 VPN 接管。
- 规则分流有效。
- DNS 可用。
- 断开后网络恢复正常。
- core 停止后没有遗留 goroutine、fd、端口监听或日志线程。

### 10.3 阶段 2：MVP App

预计周期：4-6 周。

任务：

- ArkUI 页面开发。
- 配置导入和订阅更新。
- 代理组和节点选择。
- 日志流展示。
- 流量统计。
- 异常状态处理。
- 配置持久化。
- VPN 权限引导。

验收标准：

- 用户可以完整完成导入订阅、选择节点、启动 VPN、浏览网页、查看日志、断开。
- App 重启后配置不丢失。
- 断网、配置错误、节点不可用时有明确错误提示。

### 10.4 阶段 3：稳定性和兼容性

预计周期：4-8 周。

重点测试：

- 长时间后台运行。
- 锁屏后连接保持。
- 网络切换：Wi-Fi / 蜂窝。
- IPv4 / IPv6。
- UDP、QUIC、DNS。
- 订阅超大配置。
- 节点大量测速。
- App 被系统回收后的恢复。
- VPN 异常断开后的状态同步。
- 功耗和发热。

### 10.5 阶段 4：发布准备

预计周期：2-4 周。

任务：

- 隐私政策。
- 权限说明。
- 审核材料。
- 崩溃上报。
- 日志脱敏。
- 用户协议。
- 合规确认。
- 灰度测试。

## 11. 关键风险和应对

### 11.1 Go 依赖兼容性

风险：

- mihomo 依赖 `x/sys/unix`、`sing-tun`、netlink、fsnotify 等，部分 Linux/Android 路径在 HarmonyOS NEXT 上可能需要 patch。
- Go `buildmode=c-shared`、cgo、HarmonyOS NDK 和 OpenHarmony Go 适配之间可能存在工具链兼容问题。

应对：

- 先做最小 Go `.so` POC，再接 mihomo。
- 对不兼容模块建立 patches 目录，保持和上游 mihomo 的差异可追踪。
- 构建产物必须进入 CI 或至少提供可复现的一键构建脚本。

### 11.2 TUN 接入方式

风险：

- 桌面 mihomo 通常自己管理 TUN；HarmonyOS 要由系统 VPN Extension 创建 fd，再交给核心。

应对：

- 修改 TUN adapter，支持外部 fd 注入。
- 第一版只支持系统 VPN Extension 创建的 TUN。

### 11.3 socket protect

风险：

- 所有代理出站连接必须绕过 VPN，否则容易产生流量回环。
- MVP-01B 第二轮已实证：protect hook 即使代码上"注册"也可能因实现细节（如硬编码禁用）从未真正生效，表现是浏览器层 `dnsServerReturnNothing`、`vpn-tun` RX = 0。

应对：

- 在 native 层设计统一 socket 创建和保护适配层。
- 出站 socket 创建后立刻调用 HarmonyOS protect。
- 增加回环检测和日志。
- POC 阶段必须用真实 VPN 流量验证，不接受普通网络请求作为验收依据。
- Go bridge `enableProtectHookLocked` 必须真正写入 `dialer.DefaultSocketHook = mihomoProtectSocketHook`；任何"暂时禁用"的止血策略必须有明确的 TODO 标记和后续清单。
- protect hook 启用/禁用必须有可观测日志（如 `enableProtectHookLocked: protect hook activated`），避免悄无声息的禁用 bug。

### 11.3.1 fd-backed TUN 安全关闭

风险：

- 直接调 mihomo `Stop` 或在 mihomo TUN reader/DNS/dialer goroutine 仍持有 fd 时关闭 fd，会触发 SIGSEGV。
- MVP-01B 第一轮真机已实证：`MihomoOhosStop` 在 fd-backed TUN 场景必然崩溃，临时止血只能用 skip-all 跳过。

应对：

- 引入 `MihomoOhosGracefulStop`：先 `dialer.DefaultSocketHook = nil` 并等待在飞 protect 调用结束，再 `hub.Parse(stoppedConfig)` 让 mihomo 自己排空所有 goroutine，最后才关闭 fd。
- 该路径在 ArkTS 侧通过同步 NAPI 调用执行，避免跨线程进入 cgo。

### 11.3.2 OpenHarmony Go runtime cgo 跨线程 TLS

风险：

- POC-02 阶段已识别：OpenHarmony arm64 Go runtime 的 TLS 模型与桌面 Linux 不同，需要打补丁（`runtime.tls_g` 改为 offset variable）。
- 实践中发现 NAPI async work 在不同 worker 线程上反复进入 cgo 会触发 SIGSEGV，根因难以稳定复现和定位。

应对：

- 控制类、短耗时 cgo 入口（protect hook 开关、健康检查、graceful stop）一律使用同步 NAPI 调用，在 JS 主线程执行，保证 cgo 调用始终来自同一线程。
- 耗时操作（mihomo `loadCore` / `startConfigFile*` / `stopMihomo` / `getVersion`）仍可保留 async work，但在产品 connect 路径上严格限制为单次调用。
- 若后续仍出现跨线程 cgo crash，考虑引入一个 NAPI 内部专用线程，所有 cgo 调用通过线程间队列转发。

### 11.4 进程和生命周期归属

风险：

- 如果 UI Ability 直接持有 native core，VPN Extension 被系统重建、UI 被回收或 fd 生命周期变化时，容易出现状态不同步、fd 失效、后台断连。

应对：

- CoreRuntime 归属 VpnExtensionAbility。
- UI 只发送控制命令和订阅状态事件。
- 所有连接状态以 CoreRuntime/VpnExtensionAbility 为准。

### 11.5 后台保活

风险：

- 技术跑通不等于能稳定后台长期运行。

应对：

- 第一版只承诺前台和系统允许的 VPN 后台能力。
- 针对锁屏、网络切换、系统回收做专项测试。

### 11.6 上架审核

风险：

- VPN/代理类产品可能涉及敏感权限、地区政策和应用市场审核。

应对：

- 从产品命名、描述、权限说明、隐私政策开始按合规产品设计。
- 不把产品包装成翻墙工具。
- 发布前单独做合规和上架策略评估。

## 12. 团队配置

最低配置：

- HarmonyOS/ArkTS 工程师 1 人。
- Go/mihomo 内核工程师 1 人。
- C++/NAPI 工程师 1 人。
- 测试 1 人。

如果一个人开发，建议只先做 POC，不要直接开完整产品。

## 13. 推荐里程碑

```text
M0：确认目标设备和 HarmonyOS 版本
M1：VPN Extension + TUN fd POC
M2：Go .so + NAPI POC
M3：mihomo 固定配置跑通
M4：订阅导入 + 节点选择
M5：MVP 可日常使用
M6：稳定性测试
M7：内测发布
M8：合规评估后决定是否上架
```

## 14. POC 优先级

正式产品开发前，必须先完成以下 POC：

1. `VpnExtensionAbility` 创建 TUN，并获得可读写的 tunFd。
2. Go 编译为 HarmonyOS 可加载的 `.so`。
3. ArkTS 通过 NAPI 调用 Go `.so`。
4. native/mihomo 能读取 TUN fd。
5. 出站 socket 能调用 protect。
6. TCP 在 VPN 已启动场景下跑通。
7. UDP 和 DNS 跑通。
8. 断开 VPN 后系统网络正常恢复。
9. native core 支持连续启动、停止、重复启动。
10. core stop 后没有 fd、goroutine、端口和日志线程残留。

只有以上 POC 全部通过，才建议进入正式 App 开发阶段。

## 15. POC 独立任务清单

当前 POC 环境：

| 项目 | 值 |
|---|---|
| HarmonyOS NEXT 版本 | 6.1.1 |
| API 版本 | 24 |
| 真机型号 | Mate 80 |
| DevEco Studio 版本 | 6.1.1 Release |
| VPN Extension 权限和调试能力 | 已具备 |

基于当前环境，可以直接进入 `POC-01：VPN TUN 基础能力`。

### 15.1 POC-01：VPN TUN 基础能力

目标：

- 验证 HarmonyOS App 可以通过 `VpnExtensionAbility` 创建 VPN，并获得可读写的 tunFd。

任务：

- 创建最小 HarmonyOS 工程。
- 声明 VPN Extension 相关权限和 ability。
- 实现 VPN 权限申请和启动流程。
- 构造最小 VPN config。
- 调用系统 API 创建 VPN/TUN。
- 获取 tunFd 并记录 fd 状态。
- 在 native 层或最小 worker 中验证 tunFd 可读写。
- 实现 VPN destroy 和 fd 释放。

输出物：

- 最小可运行 Demo App。
- `VpnExtensionAbility` 示例代码。
- tunFd 创建、读写、释放日志。

通过标准：

- 真机上可以启动 VPN。
- 能稳定获得 tunFd。
- tunFd 可以被 native 层读取或写入。
- 停止 VPN 后系统网络恢复正常。
- 连续启动和停止 20 次无崩溃、无明显 fd 泄漏。

验证结果：

- 结论：`POC-01` 基本验证通过。
- 真机无线调试环境下，VPN 启动和停止流程正常。
- `startVpnExtensionAbility()` 已确认进入 `VpnExtensionAbility.onRequest()` 生命周期，并触发 TUN 创建流程。
- 系统日志确认 `CreateVpnConnection successfully`、`SetUp interface name:vpn-tun`、`receive tun device fd`。
- App 日志确认成功获得 tunFd，并完成最小读写探测：`tunFd write probe ok`、`tunFd read probe ok`。
- Stop 后系统关闭 tun fd 并销毁虚拟网络，日志包含 `close tunfd`、`Destroy vpn successfully`。
- 已手动连续启动和停止 20 次，未发现崩溃或明显 fd 泄漏。

边界说明：

- 当前读写验证采用 ArkTS 最小 fs read/write probe，尚未接入 native/mihomo core。
- native core 持有 tunFd、protect 出站 socket、TCP/UDP/DNS 转发能力将在后续 POC 中继续验证。

### 15.2 POC-02：Go `.so` 构建和加载

目标：

- 验证 Go 代码可以编译为 HarmonyOS 可加载的 native 动态库，并通过 NAPI 被 ArkTS 调用。

任务：

- 准备 OpenHarmony/HarmonyOS Go 工具链。
- 编写最小 Go core，导出 C ABI。
- 使用 `buildmode=c-shared` 构建 `.so` 和 header。
- 编写 C++ NAPI bridge。
- ArkTS 调用 NAPI 方法。
- 验证字符串、数字、错误码、异步回调传递。
- 验证 Go goroutine 启动和停止。
- 验证 panic 捕获和错误上报。

输出物：

- `libpoc_go_core.so`。
- C header。
- NAPI bridge 示例。
- 构建脚本。
- 工具链版本记录。

通过标准：

- `.so` 可以在真机加载。
- ArkTS 可以成功调用 Go 导出函数。
- Go 可以向 ArkTS/NAPI 返回同步结果和异步事件。
- 自动启动自检可以连续启动和停止 Go worker，无崩溃、无残留 running 状态；当前清洁启动门禁使用 3 次循环，必要时可临时调高到 20 次做压力复测。
- Go panic 不直接导致 App 进程异常退出，至少能在 POC 中转换为明确错误。

工具链版本记录：

- Go：`go1.26.4 darwin/arm64`。
- OpenHarmony NDK clang：`OHOS (dev) clang version 15.0.4`，target `aarch64-unknown-linux-ohos`。
- Hvigor：使用 DevEco Studio 内置 `/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw`。

本机 Huawei/OpenHarmony 工具路径已记录在 `scripts/huawei_tools_env.sh`，后续可直接执行 `source scripts/huawei_tools_env.sh` 后使用：

- `HVIGORW=/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw`
- `HDC=/Users/zhangpengfei/Library/OpenHarmony/Sdk/20/toolchains/hdc`
- `OHOS_NDK_HOME=/Users/zhangpengfei/Library/OpenHarmony/Sdk/20/native`
- `OHOS_CLANG=/Users/zhangpengfei/Library/OpenHarmony/Sdk/20/native/llvm/bin/aarch64-unknown-linux-ohos-clang`
- `OHOS_CLANGXX=/Users/zhangpengfei/Library/OpenHarmony/Sdk/20/native/llvm/bin/aarch64-unknown-linux-ohos-clang++`
- `OHOS_LLVM_NM=/Users/zhangpengfei/Library/OpenHarmony/Sdk/20/native/llvm/bin/llvm-nm`
- `OHOS_LLVM_READELF=/Users/zhangpengfei/Library/OpenHarmony/Sdk/20/native/llvm/bin/llvm-readelf`
- `OHOS_GO=/private/tmp/ohos_golang_go/bin/go`
- `POC_DEVICE_TARGET=192.168.3.65:41235`

验证结果：

- 结论：`POC-02` 已在真机通过。通过条件是使用本地修补后的 OpenHarmony Go runtime 生成 `buildmode=c-shared` `.so`；stock Go 产物仍不兼容 HarmonyOS 应用侧 `dlopen`。
- `scripts/build_poc02_go_core.sh` 已使用 `buildmode=c-shared` 生成 `entry/libs/arm64-v8a/libpoc_go_core.so` 和 `libpoc_go_core.h`。
- `libpoc_go_core.so` 为 ARM64 ELF shared object，导出 `PocGoVersion`、`PocGoAdd`、`PocGoStartWorker`、`PocGoStopWorker`、`PocGoLastEvent`、`PocGoPanicProbe`、`PocGoFree`。
- `entry/build/default/outputs/default/entry-default-signed.hap` 已包含 `libs/arm64-v8a/libpoc_go_core.so` 和 `libs/arm64-v8a/libpoc_napi.so`。
- `pkgContextInfo.json` 已登记 `libpoc_go_core.so` 与 `libpoc_napi.so`。
- `go test ./...` 通过；当前 Go core 包无单元测试文件。
- 真机 `192.168.3.65:41235` 已连接，`entry-default-signed.hap` 安装成功，`EntryAbility` 启动成功。
- stock Go 真机错误：`Error relocating /data/storage/el1/bundle/libs/arm64/libpoc_go_core.so: : initial-exec TLS resolves to dynamic definition in /data/storage/el1/bundle/libs/arm64/libpoc_go_core.so`。
- 修补后的 OpenHarmony Go 真机自检已通过：`loadGoCore` 成功，`add(7, 35)=42`，worker 启停成功，`panicProbe` 可转换为明确错误，`POC-02 self-test done failures=0`。
- `c-archive` 方向已做本机预检，归档仍包含 `R_AARCH64_TLSIE_* runtime.tls_g` TLS relocation，不能作为可靠规避方案。

最终真机启动验证日志：

```text
POC-02 self-test begin
Go core loaded
POC-02 self-test loadGoCore ok=true code=0 message=poc-go-core/0.1
POC-02 self-test add(7, 35)=42
POC-02 self-test workers runs=3 lastEvent=worker tick 3
POC-02 self-test panicProbe ok=true code=0 message=panic converted to error event=panic recovered: POC-02 panic probe
POC-02 self-test done failures=0
```

后续复用命令：

```bash
source scripts/huawei_tools_env.sh

POC_GO="$OHOS_GO" POC_GOOS=openharmony CGO_ENABLED=1 ./scripts/build_poc02_go_core.sh
"$HVIGORW" --mode module -p module=entry@default -p product=default -p buildMode=debug assembleHap
"$HDC" -t "$POC_DEVICE_TARGET" install -r "$POC_ENTRY_HAP"

"$HDC" -t "$POC_DEVICE_TARGET" shell hilog -r
"$HDC" -t "$POC_DEVICE_TARGET" shell aa force-stop "$POC_BUNDLE_NAME"
"$HDC" -t "$POC_DEVICE_TARGET" shell aa start -b "$POC_BUNDLE_NAME" -a "$POC_ENTRY_ABILITY"
sleep 3
"$HDC" -t "$POC_DEVICE_TARGET" shell hilog -x -T MihomoPocNapi,MihomoPocPage,GoRuntimeCgo
```

已落地修改记录：

- `scripts/huawei_tools_env.sh` 记录 DevEco/Huawei/OpenHarmony 工具路径、OpenHarmony Go 路径、真机连接地址、HAP 路径、包名和 Ability 名称，后续不需要重新查找。
- `scripts/build_poc02_go_core.sh` 会自动 source 工具环境文件，支持通过 `POC_GO` 和 `POC_GOOS` 切换 Go 工具链和目标系统，当前 POC-02 使用 `POC_GO="$OHOS_GO" POC_GOOS=openharmony CGO_ENABLED=1`。
- `poc/go-core/poc_go_core.go` 提供最小 Go core：版本查询、整数加法、worker goroutine 启停、last event 查询、panic recover 探针和 C 字符串释放接口。
- `entry/src/main/cpp/poc_napi.cpp` 使用 `dlopen("libpoc_go_core.so", RTLD_NOW)` 延迟加载 Go core，解析稳定 C ABI，并向 ArkTS 暴露 `loadGoCore`、`add`、`startWorker`、`stopWorker`、`getLastEvent`、`panicProbe`。已移除早期 NAPI constructor 中的 add smoke call，避免启动阶段额外噪音。
- `entry/src/main/ets/native/PocNative.ets` 固定 ArkTS 侧类型声明，避免页面直接依赖未约束的 native module 形态。
- `entry/src/main/ets/pages/Index.ets` 在页面 `aboutToAppear()` 自动运行 POC-02 自检。清洁启动门禁保留 3 次 worker 启停循环，并把高频 tick 日志收敛为一条 summary，便于真机 hilog 判断具体失败点。

OpenHarmony Go runtime 修补记录：

- 已从 `https://gitee.com/openharmony-sig/ohos_golang_go.git` 拉取源码到 `/private/tmp/ohos_golang_go`。
- 已使用本机 Go `go1.26.4 darwin/arm64` bootstrap 编译出 OpenHarmony Go：`/private/tmp/ohos_golang_go/bin/go`，版本为 `go1.22.10 darwin/arm64`。
- 该工具链确认支持 `GOOS=openharmony GOARCH=arm64`。
- 已使用 `POC_GO=/private/tmp/ohos_golang_go/bin/go POC_GOOS=openharmony CGO_ENABLED=1` 重新生成 `entry/libs/arm64-v8a/libpoc_go_core.so`。
- 新 `.so` 为 ARM64 ELF shared object，包含 `.note.ohos.ident`，并导出 `PocGoVersion`、`PocGoAdd`、`PocGoStartWorker`、`PocGoStopWorker`、`PocGoLastEvent`、`PocGoPanicProbe`、`PocGoFree`。
- `llvm-readelf -r` 未再观察到 stock Go 产物中的 `R_AARCH64_TLSIE_* runtime.tls_g`，但仍存在一个 `R_AARCH64_TLS_TPREL64` relocation。
- 已重新构建 HAP 成功，`entry-default-signed.hap` 包内包含新的 `libs/arm64-v8a/libpoc_go_core.so` 和 `libs/arm64-v8a/libpoc_napi.so`。
- 真机 `192.168.3.65:41235` 复测已完成：HAP 安装成功，`EntryAbility` 启动成功，`dlopen libpoc_go_core.so` 成功，Go runtime 初始化完成。
- OpenHarmony Go runtime 已做本地修补并通过真机复测。关键改动记录在 `patches/poc02-openharmony-go-runtime-notes.md`：
  - OpenHarmony arm64 将 `runtime.tls_g` 按 offset variable 处理，避免 app-side `dlopen` 拒绝 initial-exec TLS。
  - `_cgo_init` 接收 TPIDR_EL0 和 `&runtime.tls_g`，并通过 pthread TLS key 扫描计算 offset。
  - OpenHarmony c-shared 初始化跳过 Linux 对伪造 `argv/env/auxv` 的扫描。
  - `goenvs()` 初始化为空但非 nil slice，避免 `parsedebugvars()` 中 `gogetenv` 触发 runtime throw。

边界说明：

- 当前通过依赖 `/private/tmp/ohos_golang_go` 的本地 runtime 修补树。诊断打点已经从临时 runtime 中移除，并已重新生成 `entry/libs/arm64-v8a/libpoc_go_core.so` 做最终启动验证。
- 该 runtime 修补目前仍是本机临时树，不应只依赖 `/private/tmp` 作为长期资产。进入正式 mihomo 移植前，需要把 `patches/poc02-openharmony-go-runtime-notes.md` 中的功能性改动整理为可审查的 fork、patch set 或内部工具链构建脚本。
- runtime 判断 OpenHarmony 时应使用工具链内的 `IsOpenharmony`，不要依赖 `GOOS == "openharmony"`；本轮定位发现该 runtime 内部 `GOOS` 常量仍可能走 `"linux"` 路径。

### 15.3 POC-03：socket protect 回环验证

目标：

- 验证代理出站 socket 可以在 VPN 已启动状态下调用 protect，并避免流量再次进入本 App 的 TUN。

任务：

- 在 `VpnExtensionAbility` 中封装 protect 能力。
- C++ adapter 注册 protect callback。
- Go core 通过 C ABI 调用 protect callback。
- 在 socket `connect` 前执行 protect。
- 分别测试 protect 成功和失败路径。
- 增加 TUN 包计数日志，用于观察是否发生回环。
- 在 VPN 已启动状态下发起 TCP 请求。
- 在 VPN 已启动状态下发起 UDP/DNS 请求。

输出物：

- protect callback 示例代码。
- TCP/UDP/DNS 测试日志。
- protect 成功、失败、回环检测日志。

通过标准：

- protect 成功时，出站 TCP 请求可以完成。
- protect 成功时，没有观察到代理出站连接反复进入 TUN。
- protect 失败时，本次 outbound 连接失败并产生明确错误日志。
- UDP 或 DNS 至少有一个真实请求通过。

完成状态：

- POC-03 已完成，默认低噪声模式在 Mate 80 真机通过。
- 当前通过标准固定为：
  - `TCP+protect` 成功，且 POC 目标 IPv4 未进入 TUN：`loopbackDelta=0`。
  - 强制 protect 失败时，Go outbound 在 `connect`/`sendto` 前中止，并返回 `protect() failed: code=-900`。
  - `UDP+protect` 至少一个目标成功；默认使用局域网 UDP echo 目标，避免公网 UDP/53 被当前网络丢弃导致误判。
  - VPN 进程不发生 native crash。

当前实现状态：

- Go core 已新增 `PocGoTcpTest`、`PocGoUdpTest`、`PocGoSetProtectBridgeFn`，并通过 `PocProtectBridge(fd)` 在 socket 创建后、`connect`/`sendto` 前调用 protect bridge。
- protect bridge 已改为返回错误码；protect 返回非 0 时，Go TCP/UDP 测试会在 outbound 前失败并输出 `protect() failed: code=...`。
- C++ NAPI 已改为直接解析并调用 C 层 `PocProtectBridgeSetFn(NapiProtectBridgeImpl)` 注册 protect bridge，不再通过 `PocGoSetProtectBridgeFn(void*)` 为设置 C 静态函数指针而进入 Go runtime。
- C++ NAPI 已注册 `NapiProtectBridgeImpl`，并把 ArkTS protect callback 的返回值或 Promise 结果同步回 Go worker 线程。
- `runTcpTest`、`runUdpTest` 已改成 Promise 异步接口，避免同步 NAPI 调用阻塞 ArkTS 线程，导致 TSFN protect callback 无法执行。
- `VpnExtensionAbility` 已避免在 VPN Extension ArkTS 主线程同步调用 `loadGoCore()`。真机验证显示 `com.example.mihomopoc:vpn` 在主线程同步进入 `PocGoVersion` 时会退出；把首次 Go 调用推迟到 `runTcpTest`/`runUdpTest` 的 NAPI async worker 线程后，进程不再 native crash。
- `VpnExtensionAbility` 已在 VPN 创建后注册 protect callback、启动 TUN 包计数器，并自动执行：
  - TCP with protect：期望成功，并记录 `loopbackDelta` 与 `totalTunDelta`。
  - TCP with forced protect failure：期望在 outbound 前失败，并记录明确错误。
  - UDP with protect：默认使用可参数化的局域网 UDP echo 目标，期望收到 echo 响应。
- UI 页面保留手动 POC-03 探测按钮；真正的 protect 验证以 `MihomoPocVpn` 和 `MihomoPocNapi` hilog 为准。
- 已使用 `POC_GO=/private/tmp/ohos_golang_go/bin/go POC_GOOS=openharmony CGO_ENABLED=1` 重新生成 `entry/libs/arm64-v8a/libpoc_go_core.so`，并确认导出 `PocGoTcpTest`、`PocGoUdpTest`、`PocGoSetProtectBridgeFn`、`PocProtectBridge`。
- 已用 OpenHarmony NDK 对 `entry/src/main/cpp/poc_napi.cpp` 做 `clang++ -fsyntax-only` 检查通过。

验证过程：

1. 如修改 Go core，重新生成 OpenHarmony arm64 `.so`：

```bash
POC_GO=/private/tmp/ohos_golang_go/bin/go POC_GOOS=openharmony CGO_ENABLED=1 ./scripts/build_poc02_go_core.sh
```

2. 构建 HAP：

```bash
HOME=/private/tmp/codex-hvigor-home DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug assembleHap --no-daemon
```

3. 启动默认 UDP echo 服务。默认 POC-03 使用 `192.168.3.62:53535`，如果开发机 IP 变化，需要通过 Want 参数覆盖 `udpEchoHost`/`udpEchoPort`。

```bash
scripts/run_poc03_udp_echo_server.py --port 53535
```

4. 安装、清日志、启动 VPN Extension：

```bash
HDC=/Users/zhangpengfei/Library/OpenHarmony/Sdk/20/toolchains/hdc
DEVICE=192.168.3.65:41235

$HDC -t "$DEVICE" install -r entry/build/default/outputs/default/entry-default-signed.hap
$HDC -t "$DEVICE" shell hilog -r
$HDC -t "$DEVICE" shell aa start -b com.example.mihomopoc -a MihomoPocVpnAbility --ps poc POC-03
$HDC -t "$DEVICE" shell hilog -x -T MihomoPocVpn,MihomoPocNapi
```

5. 可选诊断参数：

```bash
$HDC -t "$DEVICE" shell aa start -b com.example.mihomopoc -a MihomoPocVpnAbility \
  --ps poc POC-03 \
  --ps udpEchoHost 192.168.3.62 \
  --pi udpEchoPort 53535 \
  --ps poc03RawUdpPreflight true \
  --ps poc03TunPacketDump true
```

Mate 80 真机复测记录与结论：

- 设备系统为 HarmonyOS 6.1.1/API 24，项目已更新为 `targetSdkVersion`/`compatibleSdkVersion` `6.1.1(24)`；HAP manifest 中 `targetAPIVersion`/`minAPIVersion` 为 `60101024`。
- 命令行 Hvigor 可用构建命令：
  `HOME=/private/tmp/codex-hvigor-home DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug assembleHap --no-daemon`
- 已确认 `PocGoSetProtectBridgeFn` 不是 native crash 根因：改为直接调用 `PocProtectBridgeSetFn` 后，VPN 进程可完成 bridge 注册。
- 真正崩溃点为 VPN Extension ArkTS 主线程同步调用 `loadGoCore()` 时进入 `PocGoVersion`；同一 HAP 在普通 UI 进程中 `PocGoVersion`、worker、panicProbe 均正常，说明问题集中在 VPN Extension 主线程与当前 OpenHarmony Go c-shared runtime 初始化/外部线程假设。
- 修复后真机 hilog 已出现：
  - `protect callback returned promise fd=...`
  - `protect promise settled fd=... error=0`
  - `POC-03 TCP+protect PASS loopbackDelta=0 totalTunDelta=...`
  - `POC-03 forced protect failure PASS`
  - `POC-03 UDP+protect PASS loopbackDelta=0 totalTunDelta=0`
  - `POC-03 self-test done failures=0`
- TUN 包计数已改为同时记录 `totalTunDelta` 和 `loopbackDelta`。真机日志显示进入 TUN 的背景包为 IPv6，POC 目标 IPv4 包 `loopbackPackets=0`，因此早期 `tunDelta=3` 是背景 IPv6 噪音导致的误报。
- UDP/DNS 遗留项已定性：
  - VPN 创建前 raw UDP preflight：本机局域网 UDP echo `192.168.3.62:53535` 可收到 29 bytes 响应，证明 Go UDP connected socket 收发正常。
  - VPN 创建后 with protect：同一局域网 UDP echo 目标 PASS，证明 UDP socket protect 链路正常。
  - `1.1.1.1:53` 和 `8.8.8.8:53` 在 VPN 创建前 `useProtect=false` 也 `read() failed: errno=11 n=-1`，说明当前网络下公网 UDP/53 不回包，不作为 POC-03 失败原因。
- POC-03 已收口为默认低噪声模式：
  - 默认关闭 raw UDP preflight。
  - 默认关闭 TUN 单包摘要，只保留 `totalTunDelta`/`loopbackDelta` 汇总。
  - UDP echo 目标默认 `192.168.3.62:53535`，可通过 Want 参数 `udpEchoHost`、`udpEchoPort` 覆盖。
  - 诊断开关可通过 Want 参数 `poc03RawUdpPreflight`/`rawUdpPreflight` 和 `poc03TunPacketDump`/`tunPacketDump` 打开。
  - 本地 UDP echo 服务可用 `scripts/run_poc03_udp_echo_server.py --port 53535` 启动。
- 默认模式最终真机回归：
  - `POC-03 options udpEcho=192.168.3.62:53535 rawUdpPreflight=false tunPacketDump=false`
  - `POC-03 TCP+protect PASS loopbackDelta=0 totalTunDelta=4`
  - `POC-03 forced protect failure PASS`
  - `POC-03 UDP+protect label=local-echo host=192.168.3.62 port=53535 ok=true`
  - `POC-03 self-test done failures=0`
  - `POC-03 final tun packets=4 bytes=444 loopbackPackets=0`

最终结论：

- POC-03 证明 OpenHarmony VPN Extension 进程内可以通过 NAPI async worker 调用 Go c-shared core 发起 TCP/UDP outbound。
- socket 创建后、`connect`/`sendto` 前调用 `vpnConnection.protect(fd)` 的链路可用。
- protect 成功时，TCP 与 UDP local echo outbound 均可完成；POC 目标 IPv4 未回流进 TUN。
- protect 失败时，Go outbound 会在真正发起连接前失败，并返回明确错误。
- 公网 UDP/53 不回包是当前网络环境限制，不影响 POC-03 对 UDP protect 链路的判断。
- 仍需在 POC-04 避免 VPN Extension ArkTS 主线程同步进入 Go runtime；当前策略是让 Go 调用发生在 native/worker 线程。

### 15.4 POC-04：mihomo 固定配置最小运行

目标：

- 验证 mihomo 可以作为 native `.so` 在 HarmonyOS 上用固定 YAML 配置启动，并处理 TUN 流量。

任务：

- fork mihomo。
- 固定一个可测试的 mihomo commit。
- 建立 `core/mihomo` 和 `core/patches`。
- 增加 HarmonyOS build tags 和构建脚本。
- 处理 Go/cgo/NDK 编译错误。
- 增加外部 tunFd 注入能力。
- 接入 socket protect callback。
- 禁用或替换不支持的 Linux-only 能力。
- 固定一个最小 YAML 配置。
- 通过 native bridge 启动 mihomo。
- 验证规则模式、全局模式、直连模式中的至少一种。

输出物：

- `libmihomo_ohos.so`。
- mihomo patch 列表。
- 一键构建脚本。
- 最小运行配置。
- 启动、停止、日志、流量统计示例。

通过标准：

- mihomo 可以在真机上启动。
- 使用固定配置可以建立代理出站连接。
- 系统浏览器或测试请求的流量可以被 TUN 接管。
- DNS 可用。
- stop 后没有遗留 goroutine、fd、端口监听或日志线程。
- 断开后系统网络恢复正常。

当前实现状态（2026-06-07）：

- 已固定 mihomo Go core 源码到 `core/mihomo`，版本 tag 为 `v1.19.27`，提交 `5184081ac327394d9e15fa5d5f9f4a61e723fd94`。早期误拉到的 Python 项目保留在 `core/mihomo-python`，不参与 POC-04 构建。
- 已新增 `core/mihomo/openharmony_bridge`，以 `buildmode=c-shared` 暴露最小 C ABI：
  - `MihomoOhosVersion`
  - `MihomoOhosPing`
  - `MihomoOhosStartConfig`
  - `MihomoOhosStartConfigFile`
  - `MihomoOhosStop`
  - `MihomoOhosLastError`
  - `MihomoOhosFreeCString`
- 已新增 `scripts/build_poc04_mihomo_core.sh`，默认构建完整 mihomo bridge 到 `entry/libs/arm64-v8a/libmihomo_ohos.so`。脚本将 `GOCACHE`、`GOMODCACHE` 放到 `/private/tmp`，默认 `GOPROXY=https://goproxy.cn,direct`，避免依赖用户主目录缓存和默认 `proxy.golang.org` 网络超时。
- 已新增 `core/mihomo/openharmony_bridge/poc04_minimal.yaml`，用于固定配置最小启动验证。当前配置不启用 TUN、不启用 DNS listener、不监听 mixed/http/socks 端口，只验证 mihomo 配置解析和 core start/stop 控制面。
- 已新增 `core/mihomo/openharmony_probe_bare` 作为定位用对照组。该包不导入 mihomo，仅导出同名 C ABI，用于验证 NAPI、HAP 打包、OpenHarmony Go c-shared 入口本身是否可用。正式产物已恢复为完整 mihomo bridge 版。
- C++ NAPI 已增加 POC-04 异步接口：
  - `loadMihomoCore(): Promise<PocStatus>`
  - `pingMihomo(): Promise<PocStatus>`
  - `getMihomoVersion(): Promise<PocStatus>`
  - `startMihomoConfig(homeDir, config): Promise<PocStatus>`
  - `stopMihomo(): Promise<PocStatus>`
- `VpnExtensionAbility` 已支持通过 Want 参数 `--ps poc POC-04` 进入 POC-04 验证路径。该路径避免同步进入 Go runtime，所有 mihomo `.so` 调用均在 NAPI async worker 中执行，并且不再同时运行 POC-03 的 Go socket core，避免一个 VPN 进程内混用两个 Go runtime 的干扰。
- API 24 真机上已改为从 `EntryAbility` 接收命令行 Want，再调用官方 `vpnExtension.startVpnExtensionAbility()` 进入 VPN Extension。直接 `aa start -a MihomoPocVpnAbility` 在当前设备上不稳定进入 VPN Extension 生命周期，不再作为 POC-04 推荐触发方式。
- 已新增 OpenHarmony 专用依赖修补：
  - `github.com/klauspost/cpuid/v2` 使用 `core/mihomo/openharmony_shims/cpuid`，避免 `cpuid/v2 -> flag` 在 c-shared 首次 Go export 时触发崩溃路径，同时保守关闭 SIMD feature，让 `reedsolomon/kcp` 走安全路径。
  - `github.com/enfein/mieru/v3` 和 `github.com/RyuaNerin/go-krypto` 使用 `core/mihomo/openharmony_shims/modules/*` 本地副本，仅给误放在生产构建里的测试辅助文件加 `!openharmony` build tag，移除 `testing -> flag` 依赖。
- `openharmony_bridge` 已修正运行目录：启动前创建 `homeDir`，并把 `CN.SetConfig()` 设置为 `homeDir/config.yaml` 绝对路径，避免 `config.Init()` 在 VPN 进程当前工作目录写 `config.yaml` 时触发 `permission denied`。

本机/构建验证：

```bash
bash scripts/build_poc04_mihomo_core.sh
```

- 结果：通过，生成 `entry/libs/arm64-v8a/libmihomo_ohos.so`，完整 mihomo bridge 版体积约 37 MB。
- `llvm-nm -D entry/libs/arm64-v8a/libmihomo_ohos.so` 已确认导出 `MihomoOhosVersion`、`MihomoOhosPing`、`MihomoOhosStartConfig`、`MihomoOhosStartConfigFile`、`MihomoOhosStartConfigFileWithTunFd`、`MihomoOhosStop`、`MihomoOhosLastError`、`MihomoOhosFreeCString`。
- `llvm-readelf -h entry/libs/arm64-v8a/libmihomo_ohos.so` 已确认产物为 `ELF64`、`DYN (Shared object file)`、`AArch64`。
- `GOOS=openharmony GOARCH=arm64 CGO_ENABLED=1 go list -deps ./openharmony_bridge | rg '^(testing|flag)$'` 已确认完整 bridge 依赖图不再包含 `testing` 或 `flag`。
- NDK `clang++ -fsyntax-only entry/src/main/cpp/poc_napi.cpp` 通过。
- HAP 构建命令通过：

```bash
HOME=/private/tmp/codex-hvigor-home \
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  --mode module \
  -p module=entry@default \
  -p product=default \
  -p buildMode=debug \
  assembleHap --no-daemon
```

- 最终 HAP `entry/build/default/outputs/default/entry-default-signed.hap` 已确认包含：
  - `libs/arm64-v8a/libmihomo_ohos.so`，约 37 MB，完整 mihomo bridge 版。
  - `libs/arm64-v8a/libpoc_go_core.so`。
  - `libs/arm64-v8a/libpoc_napi.so`。

Mate 80 真机验证记录：

```bash
$HDC -t "$DEVICE" install -r entry/build/default/outputs/default/entry-default-signed.hap
$HDC -t "$DEVICE" shell hilog -r
$HDC -t "$DEVICE" shell aa start -b com.example.mihomopoc -a EntryAbility --ps poc POC-04
$HDC -t "$DEVICE" shell hilog -x | grep -E 'MihomoPocEntry|MihomoPocVpn|MihomoPocNapi|POC-04'
```

- 设备：Mate 80，HarmonyOS 6.1.1/API 24。当前 HAP 安装信息显示 `apiCompatibleVersion=60101024`、`apiTargetVersion=60101024`，与设备系统版本匹配。
- 完整 mihomo bridge 版真机验证已通过：
  - `EntryAbility` 收到 `--ps poc POC-04` 后调用 `startVpnExtensionAbility()` 成功。
  - VPN Extension 创建 TUN fd 成功，TUN read/write probe 成功。
  - `dlopen libmihomo_ohos.so`、`dlsym`、`loadMihomoCore()` 成功。
  - `MihomoOhosPing()` 首次 Go export 调用已稳定返回 `404`，不再触发 VPN 进程 native crash。
  - `MihomoOhosVersion()` 返回 `mihomo/v1.19.27-poc04`。
  - `MihomoOhosStartConfig()` 使用固定最小 YAML 成功启动 mihomo 控制面。
  - `MihomoOhosStop()` 成功停止。

关键通过日志：

```text
MihomoPocEntry: startVpnExtensionAbility returned ok poc=POC-04 source=onCreate
MihomoPocVpn: tunFd created fd=29
MihomoPocVpn: tunFd write probe ok bytes=20 fd=29
MihomoPocVpn: tunFd read probe ok bytes=76 fd=29
POC-04 load mihomo core ok=true code=0 msg=mihomo core loaded
POC-04 MihomoOhosPing returned code=404
POC-04 ping mihomo ok=true code=404 msg=mihomo ping ok
POC-04 MihomoOhosVersion copied value=mihomo/v1.19.27-poc04
POC-04 mihomo version ok=true code=0 msg=mihomo/v1.19.27-poc04
POC-04 MihomoOhosStartConfig returned code=0
POC-04 start fixed config ok=true code=0 msg=mihomo started
POC-04 MihomoOhosStop returned code=0
POC-04 stop ok=true code=0 msg=mihomo stopped
POC-04 self-test done failures=0
```

阶段结论：

- 验证结论：POC-04 已完成并通过。Mate 80（HarmonyOS 6.1.1/API 24）真机上，完整 `libmihomo_ohos.so` 可在 VPN 进程中加载，首次 Go export 不再 native crash，固定最小 YAML 可完成 `ping/version/start/stop` 闭环，最终日志为 `POC-04 self-test done failures=0`。
- POC-04 已按“固定配置最小运行”范围通过。当前通过内容包括：mihomo 源码固定、OpenHarmony c-shared 编译、完整 bridge HAP 打包、NAPI 异步 bridge、VPN Ability 入口、固定最小 YAML 启动、version/ping/start/stop 控制面闭环。
- 可以排除的问题：
  - Mate 80 API 版本不匹配：当前 HAP 已为 6.1.1/API 24。
  - HAP 未打包 `.so`：HAP 中已包含完整 `libmihomo_ohos.so`。
  - NAPI async worker 调用模型错误：bare probe 和完整 bridge 均通过。
  - OpenHarmony Go c-shared 基础入口不可用：bare probe 和完整 bridge 均通过。
  - 完整 bridge 首次 Go export 失败：已通过移除 `testing/flag` 依赖解决。
- 已确认的根因和修复：
  - `cpuid/v2 -> flag`、`mieru/pkg/log -> testing -> flag`、`go-krypto/internal/memory -> testing -> flag` 会使完整 bridge 在 OpenHarmony c-shared 首次 Go export 时崩溃或退出。通过 `cpuid` shim 和本地 patched module 移除 `testing/flag` 后，`MihomoOhosPing()` 可稳定返回。
  - `CN.SetConfig("config.yaml")` 会让 `config.Init()` 在 VPN 进程当前工作目录创建文件，导致 `permission denied`。改为 `homeDir/config.yaml` 绝对路径后，固定配置启动成功。
- 边界说明：当前 POC-04 只验证 mihomo 固定配置最小控制面，不启用 mihomo 内部 TUN、不启用 DNS listener、不验证真实代理出站流量接管。配置目录规范、真实订阅配置改写、DNS 和 TUN 流量接管进入 POC-05 继续验证。

### 15.5 POC-05：配置文件和运行目录适配

目标：

- 验证订阅配置可以转换为 HarmonyOS App 沙箱内可运行的 mihomo 配置。

任务：

- 定义 App `homeDir`、profile 目录、cache 目录、geo 数据目录。
- 保存原始订阅 YAML。
- 生成实际运行 YAML。
- 注入或覆盖移动端运行字段。
- 检查不支持字段并给出错误。
- 验证配置热重载。
- 验证配置切换。

输出物：

- 配置目录规范。
- 原始配置和运行配置样例。
- 配置转换代码。
- 配置校验错误列表。

通过标准：

- App 重启后配置不丢失。
- 运行配置路径全部位于 App 沙箱内。
- 不支持字段不会导致 core 静默失败。
- reload 后节点选择、DNS 和规则状态符合预期。

当前实现状态（2026-06-07）：

- 已在 `EntryAbility` 支持通过命令行 Want 参数 `--ps poc POC-05` 触发 VPN Extension：

```bash
$HDC -t "$DEVICE" shell aa start -b com.example.mihomopoc -a EntryAbility --ps poc POC-05
```

- C++ NAPI 已补齐 `MihomoOhosStartConfigFile` bridge：
  - `dlopen libmihomo_ohos.so` 后解析 `MihomoOhosStartConfigFile`。
  - 新增 ArkTS Promise 接口 `startMihomoConfigFile(homeDir: string, configPath: string)`。
  - mihomo `.so` 调用仍在 NAPI async worker 中执行，避免阻塞 ArkTS 线程。
- `VpnExtensionAbility` 已新增 POC-05 自测路径，当前目录规范如下：

```text
baseDir      = context.filesDir + "/poc05-mihomo"
homeDir      = baseDir + "/home"
profileDir   = baseDir + "/profiles"
runDir       = baseDir + "/run"
cacheDir     = baseDir + "/cache"
geoDir       = baseDir + "/geo"
rawPath      = profileDir + "/subscription-raw.yaml"
runtimePath  = runDir + "/config.yaml"
```

- POC-05 会执行以下闭环：
  - 启动前检查 `rawPath/runtimePath` 是否已存在，用于验证重复启动或 App 重启后配置文件不丢失。
  - 创建或复用 `home/profiles/run/cache/geo` 目录。真机验证时发现 `fs.mkdirSync(path, true)` 在目录已存在时仍可能抛 `File exists`，已改为先 `accessSync` 判断再创建。
  - 写入原始订阅 YAML 到 `profiles/subscription-raw.yaml`。
  - 对包含 `script:`、`proxy-providers:` 的不支持配置做显式拒绝，日志输出拒绝 key，避免 core 静默失败。
  - 生成移动端安全 runtime YAML 到 `run/config.yaml`，覆盖监听端口、`allow-lan`、DNS、TUN 等字段：

```yaml
mixed-port: 0
port: 0
socks-port: 0
redir-port: 0
tproxy-port: 0
allow-lan: false
mode: direct
log-level: info
ipv6: false
find-process-mode: off
profile:
  store-selected: false
  store-fake-ip: false
dns:
  enable: false
tun:
  enable: false
proxies: []
proxy-groups: []
rules:
  - MATCH,DIRECT
```

  - 调用 `startMihomoConfigFile(homeDir, runtimePath)` 从沙箱 runtime YAML 启动 mihomo。
  - 启动后改写 `runtimePath` 为 switch 配置，再次调用 `startMihomoConfigFile(homeDir, runtimePath)`，验证当前 bridge 下的配置重载/切换式应用路径。
  - 最后调用 `stopMihomo()` 清理 core 状态。

验证记录：

```bash
HOME=/private/tmp/codex-hvigor-home \
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  --mode module -p module=entry@default -p product=default -p buildMode=debug \
  assembleHap --no-daemon
```

- HAP 构建通过：`BUILD SUCCESSFUL`。
- ArkTS 仅有 `fs.mkdirSync/openSync/writeSync/closeSync` 可能抛异常的 warning，POC-05 外层已有 try/catch，并且目录已存在场景已单独修复。

Mate 80（HarmonyOS 6.1.1/API 24）真机验证命令：

```bash
source scripts/huawei_tools_env.sh
"$HDC" -t "$POC_DEVICE_TARGET" install -r "$POC_ENTRY_HAP"
"$HDC" -t "$POC_DEVICE_TARGET" shell hilog -r
"$HDC" -t "$POC_DEVICE_TARGET" shell aa start \
  -b "$POC_BUNDLE_NAME" -a "$POC_ENTRY_ABILITY" --ps poc POC-05
"$HDC" -t "$POC_DEVICE_TARGET" shell hilog -x | \
  grep -E 'MihomoPocEntry|MihomoPocVpn|MihomoPocNapi|POC-05|DfxFaultLogger|Ability on scheduler died|On ability died'
```

关键真机 hilog：

```text
MihomoPocEntry: startVpnExtensionAbility returned ok poc=POC-05 source=onCreate
MihomoPocVpn: POC-05 persisted files before write raw=true runtime=true
MihomoPocVpn: POC-05 directories ready home=/data/storage/el2/base/haps/entry/files/poc05-mihomo/home profiles=/data/storage/el2/base/haps/entry/files/poc05-mihomo/profiles run=/data/storage/el2/base/haps/entry/files/poc05-mihomo/run cache=/data/storage/el2/base/haps/entry/files/poc05-mihomo/cache geo=/data/storage/el2/base/haps/entry/files/poc05-mihomo/geo
MihomoPocVpn: POC-05 raw subscription saved path=/data/storage/el2/base/haps/entry/files/poc05-mihomo/profiles/subscription-raw.yaml bytes=190
MihomoPocVpn: POC-05 unsupported config rejected keys=script,proxy-providers ok=true
MihomoPocVpn: POC-05 runtime config saved path=/data/storage/el2/base/haps/entry/files/poc05-mihomo/run/config.yaml bytes=297
MihomoPocVpn: POC-05 runtime config readback ok=true
MihomoPocVpn: POC-05 sandbox path check ok=true
MihomoPocNapi: POC-05 calling MihomoOhosStartConfigFile homeDir=/data/storage/el2/base/haps/entry/files/poc05-mihomo/home configPath=/data/storage/el2/base/haps/entry/files/poc05-mihomo/run/config.yaml
MihomoPocNapi: POC-05 MihomoOhosStartConfigFile returned code=0
MihomoPocVpn: POC-05 start generated config ok=true code=0 msg=mihomo started
MihomoPocVpn: POC-05 switch config saved bytes=298 readbackOk=true
MihomoPocVpn: POC-05 reload switched config ok=true code=0 msg=mihomo started
MihomoPocVpn: POC-05 stop ok=true code=0 msg=mihomo stopped
MihomoPocVpn: POC-05 self-test done failures=0
```

验证结论：

- POC-05 已完成并通过。Mate 80（HarmonyOS 6.1.1/API 24）真机上，App 沙箱目录可创建并复用，原始订阅和 runtime YAML 可持久落地，runtime 配置路径全部位于 App sandbox 下，不支持字段会被 ArkTS 侧显式拒绝并输出 key，mihomo 可通过 `MihomoOhosStartConfigFile(homeDir, configPath)` 从 runtime YAML 启动。
- 当前 reload/switch 验证通过的是“改写 runtime YAML 后再次调用 config-file bridge 应用配置”的控制面闭环，日志为 `POC-05 reload switched config ok=true`。更细粒度的节点选择保持、DNS runtime 状态和规则命中状态，需要在后续真实代理节点、DNS 接管和 UI 状态模型接入后继续扩展。
- 本轮 hilog 未出现 `DfxFaultLogger`、`Ability on scheduler died` 或 native crash 相关记录。

### 15.6 POC-06：生命周期和异常恢复

目标：

- 验证 VPN Extension、CoreRuntime、native core 在异常和重复操作下可以保持状态一致。

任务：

- 定义状态机：idle、starting、connected、stopping、error。
- 实现重复点击连接/断开的防抖和互斥。
- 测试 VPN 创建失败。
- 测试 mihomo 启动失败。
- 测试配置错误。
- 测试网络切换。
- 测试 App 进入后台。
- 测试 UI Ability 被回收后恢复状态。
- 测试 native core crash 或 panic 上报。

输出物：

- 生命周期状态机文档。
- 异常场景测试记录。
- 状态恢复日志。

通过标准：

- 任意失败路径都能回到 idle 或 error 状态。
- UI 展示状态以 `CoreRuntime/VpnExtensionAbility` 为准。
- 重复连接/断开不会导致多实例 core。
- 异常断开后系统网络可以恢复。

当前实现状态（2026-06-07）：

- 已在 `EntryAbility` 支持通过命令行 Want 参数 `--ps poc POC-06` 触发 VPN Extension。
- `VpnExtensionAbility` 已新增 POC-06 生命周期状态机：

```text
idle -> starting -> connected -> stopping -> idle
                         \-> error
```

- 当前 POC-06 自测覆盖以下场景：
  - `onRequest` 进入时记录 `starting` 状态。
  - 已存在 VPN fd 时，先执行 `destroyVpn()`，再重建 TUN，验证重复启动不会留下多实例 VPN。
  - 写入非法 YAML 并调用 `startMihomoConfigFile()`，预期 mihomo 返回明确错误，不进入 started 状态。
  - 非法配置失败后回到 `idle`，再写入有效 runtime YAML 并恢复启动 mihomo。
  - 在 `connected` 状态下内部再次触发 `startVpnForPoc()`，验证 `startInProgress` busy guard 会拒绝重复启动。
  - 执行第一次 `stopMihomo()`，状态从 `connected -> stopping -> idle`。
  - 执行第二次 `stopMihomo()`，验证 stop 幂等。
  - 执行 `destroyVpn()`，验证 TUN fd 释放，最终 `tunFd=-1`、`vpnConnection=null`、状态回到 `idle`。
- `destroyVpn()` 已增加 `destroyInProgress` guard，避免重复 destroy 交叉执行；destroy 成功后统一回到 `idle`，失败时进入 `error`。

验证记录：

```bash
HOME=/private/tmp/codex-hvigor-home \
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  --mode module -p module=entry@default -p product=default -p buildMode=debug \
  assembleHap --no-daemon
```

- HAP 构建通过：`BUILD SUCCESSFUL`。
- ArkTS 仅有 `fs.mkdirSync/openSync/writeSync/closeSync` 可能抛异常的 warning，相关调用位于 POC 自测 try/catch 内。

Mate 80（HarmonyOS 6.1.1/API 24）真机验证命令：

```bash
source scripts/huawei_tools_env.sh
"$HDC" -t "$POC_DEVICE_TARGET" install -r "$POC_ENTRY_HAP"
"$HDC" -t "$POC_DEVICE_TARGET" shell hilog -r
"$HDC" -t "$POC_DEVICE_TARGET" shell aa start \
  -b "$POC_BUNDLE_NAME" -a "$POC_ENTRY_ABILITY" --ps poc POC-06
"$HDC" -t "$POC_DEVICE_TARGET" shell hilog -x | \
  grep -E 'MihomoPocEntry|MihomoPocVpn|MihomoPocNapi|POC-06|DfxFaultLogger|Ability on scheduler died|On ability died'
```

关键真机 hilog：

```text
MihomoPocEntry: startVpnExtensionAbility returned ok poc=POC-06 source=onNewWant
MihomoPocVpn: POC-06 state connected -> starting reason=onRequest start poc=POC-06
MihomoPocVpn: existing vpn detected, destroy before recreate tunFd=36
MihomoPocVpn: POC-06 state starting -> stopping reason=destroyVpn begin fd=36
MihomoPocVpn: vpn destroyed fd=36
MihomoPocVpn: POC-06 state stopping -> idle reason=destroyVpn complete fd=36
MihomoPocVpn: POC-06 invalid config rejected ok=true code=-1 msg=yaml: line 2: did not find expected node content
MihomoPocVpn: POC-06 state idle -> starting reason=recovery start after invalid config
MihomoPocVpn: POC-06 recovery start ok=true code=0 msg=mihomo started
MihomoPocVpn: POC-06 state starting -> connected reason=recovery start ok
MihomoPocVpn: POC-06 busy start rejected poc=POC-06 state=connected
MihomoPocVpn: POC-06 duplicate start rejected ok=true
MihomoPocVpn: POC-06 state connected -> stopping reason=first stop
MihomoPocVpn: POC-06 first stop ok=true code=0 msg=mihomo stopped
MihomoPocVpn: POC-06 state stopping -> idle reason=first stop complete
MihomoPocVpn: POC-06 second stop idempotent ok=true code=0 msg=mihomo stopped
MihomoPocVpn: POC-06 destroy recovery ok=true fd=-1
MihomoPocVpn: POC-06 final state=idle
MihomoPocVpn: POC-06 self-test done failures=0
```

验证结论：

- POC-06 已完成当前 POC 范围并通过。Mate 80（HarmonyOS 6.1.1/API 24）真机上，VPN Extension、NAPI async worker、mihomo native core 在非法配置、恢复启动、重复启动、重复停止和 destroy 清理场景下可以保持状态一致，最终回到 `idle`，且 `tunFd=-1`。
- POC-05 回归通过：在 POC-06 状态机改动后，`POC-05 self-test done failures=0` 仍成立。
- 已验证“已有 VPN fd 场景下再次触发 POC-06”：日志出现 `existing vpn detected, destroy before recreate tunFd=36`，随后旧 VPN 被销毁，新 POC-06 自测仍以 `failures=0` 结束。
- 本轮 hilog 未出现 `DfxFaultLogger`、`Ability on scheduler died` 或 native crash 相关记录。
- 边界说明：当前 POC-06 覆盖的是控制面生命周期和异常恢复闭环；网络切换、UI Ability 被系统回收后的持久状态恢复、真实 native crash/panic 上报，需要在 MVP 状态存储、UI 状态订阅和真实代理流量路径接入后继续扩展。

### 15.7 POC 完成顺序

推荐顺序：

```text
POC-01：VPN TUN 基础能力
POC-02：Go .so 构建和加载
POC-03：socket protect 回环验证
POC-04：mihomo 固定配置最小运行
POC-05：配置文件和运行目录适配
POC-06：生命周期和异常恢复
```

阶段门槛：

- `POC-01`、`POC-02`、`POC-03` 是硬门槛，任何一个失败都不应进入 mihomo 完整移植。
- `POC-04` 通过后，可以进入 MVP App 开发。
- `POC-05` 和 `POC-06` 通过后，才适合进入内测和稳定性测试。

## 16. MVP-01 开发计划

POC-01 到 POC-06 已全部通过，已进入 MVP-01。

当前 MVP-01 按两个里程碑推进：

- MVP-01A：控制面产品化。本地配置、runtime YAML、VPN/TUN 创建、mihomo core start/stop、状态恢复、错误展示和 POC 回归。
- MVP-01B：真实流量闭环。订阅最小更新器、TUN/core 流量路径打通、系统浏览器真实访问 smoke。

当前进度（2026-06-09，MVP-01B 第二轮修复后）：

### MVP-01A（已通过）

- 第一版已完成。Mate 80 / HarmonyOS 6.1.1(API 24) 真机 smoke / special smoke / POC-05/06 回归在 `192.168.50.153:37805` 设备上全部通过。
- 首页已从 POC 控制台改为 MVP-01A 控制面首页，支持本地 YAML 保存/校验、Connect/Disconnect、状态和事件展示。
- 已新增正式 MVP 类型、配置服务、运行状态服务和 VPN 控制服务。
- `MihomoPocVpnAbility` 保留 POC 路径，并新增 `command=connect` / `command=disconnect` 产品路径。

### MVP-01B 第一轮（fd-backed TUN 接入 + 控制面闭环）

- 已完成 TUN fd 到 mihomo TUN adapter 的第一段真实链路：产品 connect 现在调用 `startMihomoConfigFileWithTunFd(homeDir, runtimePath, tunFd)`，Go bridge 在内存中注入 `tun.file-descriptor`，mihomo 使用 HarmonyOS VPN 创建的 fd 启动 gVisor TUN stack。
- 6 种路由模式 + 订阅 URL 添加/手动刷新（`SubscriptionService`）+ 首页订阅 UI 已实现。
- 真机探测发现：浏览器日志 `vpnEnabled:1`，`vpn-tun` TX > 0（DNS 包确实进入 TUN），但 RX = 0（mihomo 没有回复），浏览器报 `dnsServerReturnNothing`。

### MVP-01B 第二轮（2026-06-09，关键修复）

定位到根本问题并完成五项修复：

1. **`enableProtectHookLocked` 真正激活 hook**：之前被硬编码为 `protectOn = false; DefaultSocketHook = nil` 作为 stop crash 的临时止血，导致 mihomo 出站 DNS 没有 protect → 流量回环 → mihomo 无法解析 → 浏览器 `dnsServerReturnNothing`。已修正为真正激活 `dialer.DefaultSocketHook = mihomoProtectSocketHook`。
2. **NAPI 控制类调用改为同步**：`enableProtectHook` / `disableProtectHook` / `isMihomoRunning` / `gracefulStopMihomo` 从异步 work 改为同步 NAPI 调用，避免 OpenHarmony Go runtime TLS 补丁在跨 worker 线程进入 cgo 时崩溃。ArkTS 类型相应改为 `PocStatus`（非 Promise）。
3. **新增 `MihomoOhosGracefulStop`**：先 `protectOn = false` + `waitProtectIdleLocked` 等待在飞 protect 调用结束，再 `hub.Parse(stoppedConfig)` 让 mihomo 自己排空 TUN reader / DNS resolver / outbound dialer goroutine，然后才允许 `VpnConnection.destroy()`。取代了之前的 skip-all 止血策略。
4. **DNS hijack 语法修正**：`tun.dns-hijack` 从 `0.0.0.0:53` 改为 mihomo 规范语法 `any:53`，并在 `injectTunFd` 自动补全 DNS 块（`listen: 0.0.0.0:53` / `enhanced-mode: fake-ip` / `fake-ip-range: 198.18.0.0/15` / 国内 nameserver）。
5. **路由模式参数解析 bug 修复**：`parseProductVpnOptions` 之前把除 `default` 外的所有模式都强制改回 `split-default`，导致新增的 5 种 blocking 模式实际未生效；已修正为白名单匹配。

#### 修复后真机已通过的基线

- mihomo `.so` 构建：13 个导出符号全部到位（含新增 `MihomoOhosGracefulStop`、`MihomoOhosEnableProtectHook`、`MihomoOhosDisableProtectHook`、`MihomoOhosIsRunning`）。
- HAP 构建：`BUILD SUCCESSFUL`。
- 真机 smoke 在 `192.168.50.153:37805`：
  - `scripts/run_mvp01_smoke.sh`：`MVP-01A smoke PASS`
  - `scripts/run_mvp01_special_smoke.sh`：`MVP-01A special smoke PASS`
  - `scripts/run_poc_regression.sh`：`POC-05 PASS`、`POC-06 PASS`、`POC regression PASS`
- hilog 无 `DfxFaultLogger` / `Ability on scheduler died` / `On ability died` / native crash。

#### 仍需后续验证

- 修复后的浏览器真实流量端到端 smoke（关键观察点：`enableProtectHookLocked: protect hook activated`、`MVP-01B MihomoOhosGracefulStop returned code=0`、`vpn-tun` RX > 0、`https://httpbin.org/get` 可访问、hilog 无 native crash）。
- 订阅 URL 真机刷新一遍 + 切换为 active 后再连接的端到端 smoke。
- 7 种路由模式各自在修复 hook 后的真实流量表现对比。

边界说明：

- MVP-01A 通过只代表控制面闭环可用，不代表真实代理流量已被 mihomo 接管。
- MVP-01B 第一轮已完成 HarmonyOS VPN/TUN fd 到 NAPI/Go bridge 的参数贯通，并已通过 `tun.file-descriptor` 接入 mihomo TUN adapter；MVP-01B 第二轮已完成 protect hook、DNS hijack、安全 stop 的代码层修复，端到端真实流量 smoke 待复测。
- 完整订阅更新器（自动刷新、ETag、Last-Modified）、节点选择、流量统计、DNS 产品化和日志流实时追踪不属于 MVP-01。

详细开发计划和设计见：

- [MVP-01 开发计划和详细设计](./mvp-01-development-plan.md)
