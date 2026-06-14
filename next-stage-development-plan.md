# 下一阶段开发计划

日期：2026-06-14

关联资料：

- `design/index.html`：FlowGuard MVP-01 手机端 + 平板端重新设计原型。
- `mvp-01-development-plan.md`：MVP-01 控制面与真实流量闭环开发计划。
- `harmonyos-mihomo-product-design.md`：HarmonyOS mihomo 客户端产品设计方案。
- `entry/src/main/ets/pages/Index.ets`：当前 ArkUI 页面实现。
- `entry/src/main/ets/config/ConfigService.ets`、`SubscriptionService.ets`、`RuntimeStore.ets`、`VpnControlService.ets`、`MihomoPocVpnAbility.ets`：当前业务和运行层实现。

## 1. 阶段目标

下一阶段目标不是继续扩展 POC，而是把已经验证和部分实现的能力收敛成一个可日常试用的 FlowGuard MVP-02：

```text
新原型信息架构落地
-> 连接 / 断开 / 状态恢复稳定
-> 配置 / 订阅 / 节点选择可用
-> 日志 / 诊断可观测
-> 手机和平板布局一致
-> 真实浏览器流量 smoke 可重复验证
```

核心验收口径：

- 用户打开 App 后第一屏就是新原型中的深色运行仪表盘。
- 手机端使用底部导航与节点 Bottom Sheet；平板端使用侧边栏、双栏首页和配置页。
- 连接状态、core 状态、active profile、tunFd、最近错误、运行事件都来自真实 `RuntimeStore`。
- 配置保存、订阅刷新、profile 切换、连接、断开、错误恢复是闭环能力，不是静态 UI。
- 节点页至少可以展示代理组、节点列表、当前选择；具备后续接入 native `selectProxy` 的数据模型和入口。
- 日志页和诊断面板能支持排障，至少覆盖 Runtime 快照、POC/smoke 结果、最近错误和 bridge 状态。

## 2. 当前实现盘点

### 2.1 已经具备的能力

- `ConfigService`
  - 本地 profile、订阅 profile、active profile 管理。
  - raw YAML 和 runtime YAML 分离保存。
  - runtime YAML 生成，覆盖移动端安全字段。
  - 基础不支持字段校验。
  - 从 raw YAML 提取 `proxies`，生成 `ProxyNode[]`。
  - profile 复制、删除、切换。

- `SubscriptionService`
  - HTTP/HTTPS URL 校验。
  - 手动添加订阅。
  - 手动刷新订阅。
  - 超时、重定向、状态码、响应大小限制。
  - 下载成功后临时文件校验并原子替换 raw/runtime。
  - 下载失败时保留旧配置。

- `RuntimeStore`
  - 文件化 `RuntimeSnapshot`。
  - runtime/core 状态、active profile、tunFd、最近错误、最近事件、上下行字段。
  - 最近事件列表。
  - UI Ability 恢复后将不可信运行态标记为 `unknown`。

- `VpnControlService` / `MihomoPocVpnAbility`
  - UI 通过 VPN Extension 发起 connect/disconnect。
  - 产品化 connect 路径已调用 `startMihomoConfigFileWithTunFd(homeDir, runtimePath, tunFd)`。
  - protect callback 已注册。
  - graceful stop / destroy VPN / fallback idle 已有实现。
  - route mode、DNS、TUN readiness probe 已经有参数解析和 VPN config 分支。

- `Index.ets`
  - 已有首页、代理、配置、创建配置、编辑配置、日志、设置、帮助、关于页面。
  - 已接入配置列表、订阅添加/刷新、YAML 保存/校验、节点列表、运行事件。
  - 当前 UI 仍是旧的浅色单栏页面。

### 2.2 新原型新增或强化的产品要求

- 品牌与视觉：
  - 名称切换为 FlowGuard。
  - 深色主界面。
  - 状态球表达 idle / starting / connected / stopping / error / unknown。
  - 状态 pills 展示 VPN、Core、Mode。

- 首页：
  - 当前节点快捷入口。
  - 实时上下行和今日流量。
  - connect / disconnect / reload 三个主操作。
  - profile chips 快速切换。
  - route mode 选择。
  - 最近运行事件。
  - 错误 banner。

- 节点：
  - 代理组 tabs。
  - 节点搜索。
  - 节点列表和当前选择。
  - 手机端 Bottom Sheet，平板端右侧节点面板。
  - 测速全部 / 测速当前组入口。

- 配置：
  - profile 列表。
  - 订阅 URL 输入、添加、刷新和状态条。
  - YAML 编辑、校验、保存。
  - 文件导入入口。
  - 平板双栏：左侧 profile/订阅，右侧 YAML 编辑器。

- 日志：
  - 实时日志开关。
  - 搜索。
  - level 过滤。
  - 复制诊断信息。
  - 导出日志。

- 设置：
  - 启动模式：规则 / 全局 / 直连。
  - DNS 模式。
  - IPv6、UDP 转发、连接后自动更新订阅、开机自启开关。
  - 日志级别。
  - 清理缓存、重置配置。

- 诊断：
  - Runtime 快照。
  - POC-05/06 与 smoke 结果。
  - mihomo 版本。
  - Protect Hook 状态。
  - GracefulStop 状态。
  - 最近错误。

## 3. 主要差距

| 模块 | 当前状态 | 下一阶段差距 |
| --- | --- | --- |
| UI 架构 | 单个 `Index.ets` 承载所有页面，浅色旧风格 | 需要按新原型重构为深色、手机/平板响应式布局 |
| 导航 | 首页卡片跳转 + 返回头部 | 手机底部导航，平板侧边栏 |
| 状态展示 | 状态卡 + 文本 | 状态球、pills、error banner、诊断同步 |
| Profile | 列表页可管理 | 首页 chips 快速切换，配置页状态条更细 |
| Route mode | VPN Ability 已有参数分支，UI 未持久化 | 需要设置模型、RuntimeSnapshot 展示、connect 时传递 |
| 节点 | 从 YAML 提取节点，只有展示 | 需要代理组模型、当前选择、搜索、sheet/panel、选择控制入口 |
| 节点测速 | 未实现 | 先做 UI 状态和占位验收，再接 native/API |
| 日志 | RuntimeStore 最近事件 | 需要日志流模型、过滤、搜索、导出、诊断信息复制 |
| 流量 | Snapshot 有字段但缺真实更新 | 需要 native 统计接口或轻量采样方案 |
| 设置 | 只有信息展示 | 需要 SettingsStore 和 connect 参数联动 |
| 诊断 | 原型有完整面板，当前无独立页 | 需要实现诊断面板和回归脚本结果读取 |
| 配置解析 | 手写字符串解析 YAML | 下一阶段应收敛风险，至少补强代理组/规则统计解析和测试 |
| 验证 | 脚本存在 | 需要形成新阶段 smoke + UI 回归清单 |

## 4. 里程碑计划

### M2-1：UI 基线迁移

目标：把新原型的页面结构落到 ArkUI，但先复用现有业务状态，不引入 native 新能力。

状态：已完成（2026-06-14）。

完成情况：

- `Index.ets` 已迁移为 FlowGuard 深色 UI 基线，首屏为运行仪表盘。
- 已在同一页面内按 `@Builder` 拆分首页、代理、配置、日志、设置、诊断、底部导航、平板侧边栏等结构，保留现有业务调用链。
- 首页已落地状态球、VPN/Core/Mode pills、错误 banner、当前节点卡片、上下行速率、连接/断开/重载、profile chips、route mode 展示和最近事件。
- 配置页已改为新结构，手机端保持单栏流程，平板端采用双栏布局。
- 连接、断开、订阅刷新、profile 切换、YAML 保存/校验仍复用现有 `ConfigService`、`SubscriptionService`、`RuntimeStore`、`VpnControlService`。
- 真机测试地址 `192.168.3.65:37805` 已完成安装、启动、连接、断开、布局树解析和 hilog 检查。
- 真机连接态验收：`运行中 / VPN: Connected / Core: Running`，`连接` 禁用、`断开` 可用。
- 真机断开态验收：`已停止 / VPN: Idle / Core: Stopped`，`连接` 可用、`断开` 禁用。
- 测试中发现并修复 ArkUI builder 参数导致状态 pill 文案不刷新的问题；VPN/Core pills 已改为直接绑定页面状态。
- 测试中发现并修复断开后 runtime/core 状态残留问题；`VpnControlService.disconnect()` 现在会在非 error 情况下收敛到 `idle/stopped` 并清零 tun 与速率。

遗留到后续里程碑：

- route mode 目前仍是 UI 展示/占位，真实设置持久化和 connect 参数传递进入 M2-2。
- 节点选择、代理组控制、测速和真实流量统计进入 M2-3/M2-5。
- 日志搜索、过滤、导出和诊断信息复制进入 M2-4。

范围：

- 将 App 品牌文案统一为 FlowGuard。
- 重构 `Index.ets` 页面结构：
  - `HomePage`
  - `ProxyPage`
  - `ConfigPage`
  - `LogsPage`
  - `SettingsPage`
  - `DiagnosticsPanel`
  - 手机底部导航
  - 平板侧边栏和双栏布局
- 建立统一深色 token：
  - background、surface、border、text、accent、warn、error。
- 首页落地：
  - 状态球。
  - VPN/Core/Mode pills。
  - 错误 banner。
  - 连接、断开、重载按钮。
  - profile chips。
  - route mode select。
  - 运行事件。
- 保持现有 connect/disconnect/config/subscription 调用不退化。

验收：

- 手机宽度下可完成：首页 -> 配置 -> 添加订阅 -> 切换 profile -> 返回首页 -> 连接 -> 断开。
- 平板宽度下首页为双栏，配置页为左右双栏，导航不依赖返回栈。
- `idle / starting / connected / stopping / error / unknown` 六种状态都有明确 UI 表达。

建议改动：

- 先在 `Index.ets` 内拆 `@Builder`，不要一开始拆文件，降低 ArkUI 状态传递成本。
- 颜色、间距、字号先集中为 private helper 或常量，后续再抽组件。

### M2-2：设置与连接参数闭环

目标：让新原型里的 route mode、启动模式、DNS、IPv6、UDP 等设置成为真实可保存、可传递、可诊断的参数。

状态：已完成（2026-06-14）。

完成情况：

- 新增 `AppSettings` 数据模型和 `SettingsService`，设置持久化到 `mihomo/state/settings.json`。
- 设置项覆盖：VPN 路由模式、代理启动模式、DNS 模式、VPN DNS 地址、IPv6、UDP、连接前自动刷新订阅、开机自启、日志级别。
- `ConfigService.generateRuntimeYaml()` 已接入 settings，生成 runtime YAML 时写入 `mode`、`log-level`、`ipv6`、`dns.enhanced-mode`、`dns.ipv6`。
- `SubscriptionService.update()` 刷新订阅后会使用当前 settings 生成 runtime YAML，避免刷新订阅覆盖用户运行参数。
- `VpnControlService.connect()` 会读取 settings，按开关在连接前自动刷新订阅；刷新失败时沿用旧 runtime 并写入运行事件，不阻断连接。
- `VpnControlService.connect()` 已向 `MihomoPocVpnAbility` 传递 `vpnRouteMode`、`vpnDnsAddress`、IPv6、UDP、proxy mode、DNS mode、log level 等参数。
- `MihomoPocVpnAbility` 已用 settings 生成产品 runtime YAML，并将 IPv6 设置传入 VPN 配置。
- 首页 Mode pill、路由模式卡片和设置页都读取真实 settings；设置页支持点击切换/开关，并立即重建当前 active profile runtime YAML。
- 真机测试地址 `192.168.3.65:37805` 已完成安装、设置页切换、首页同步、连接参数日志验证、连接/断开恢复。
- 真机验证日志确认：设置 VPN 路由为 `split-default` 后，VPN Ability 收到 `routeMode=split-default`、`dns=10.7.0.3`，并创建 split route。

遗留到后续里程碑：

- `autoStart` 已持久化，系统级开机自启注册能力尚未接入。
- `udpEnabled` 已持久化并传入连接参数，native/core 侧更细的 UDP 策略控制留到后续网络能力阶段。
- 设置项目前采用点击循环选择，后续可替换为更完整的 picker/select 控件。

范围：

- 新增 `SettingsService` 或在现有 config/state 层增加 `AppSettings`：

```ts
interface AppSettings {
  routeMode: string;
  proxyMode: 'rule' | 'global' | 'direct';
  dnsMode: 'default' | 'fake-ip' | 'redir-host';
  ipv6Enabled: boolean;
  udpEnabled: boolean;
  autoRefreshSubscriptionOnConnect: boolean;
  autoStart: boolean;
  logLevel: 'debug' | 'info' | 'warning' | 'error';
}
```

- connect 时将 `routeMode`、DNS 地址、IPv6 等参数传入 `VpnControlService.connect()` 和 `MihomoPocVpnAbility`。
- `ConfigService.generateRuntimeYaml()` 接收 settings，生成对应 `mode`、`dns`、`ipv6`、`log-level`。
- 首页 `modePill` 和诊断面板从 settings/runtime 读取，不写死。
- 自动刷新订阅：
  - 若 active profile 是 subscription 且开关开启，connect 前刷新。
  - 刷新失败时阻止连接还是沿用旧配置，需要明确策略。建议默认沿用上一次可用配置，并在首页 error/warn 区域提示。

验收：

- 修改 route mode 后连接，`MihomoPocVpnAbility.createPocConfig()` 使用新参数。
- 修改 proxy mode 后保存 runtime YAML，`mode` 字段变化。
- 设置重启 App 后仍保留。
- 订阅刷新失败不破坏旧 runtime，也不造成 connected 假状态。

### M2-3：节点与代理组控制面

目标：节点页从“raw proxies 列表展示”升级为“代理组 + 当前选择 + 可选择”的控制面。

范围：

- 扩展数据模型：

```ts
interface ProxyGroup {
  name: string;
  type: string;
  selected: string;
  nodes: ProxyNode[];
}
```

- `ConfigService` 增加：
  - `listProxyGroups(profileId): ProxyGroup[]`
  - `selectLocalProxy(groupName, nodeName)` 先维护本地选择状态。
  - 规则数量统计，用于 profile 列表展示。
- UI：
  - group tabs。
  - 节点搜索。
  - 当前节点卡片。
  - 手机 Bottom Sheet。
  - 平板右侧节点面板。
- Native/核心预留：
  - `PocNative` 增加 `selectProxy(group, node)` 类型定义占位，等 C++/Go bridge 实现后接入。
  - 连接中选择节点时，如果 native 未实现，明确显示“仅保存本地选择，重连生效”。

验收：

- 使用含多个 `proxy-groups` 的 YAML，可以展示所有组和节点。
- 切换 group 后节点列表同步变化。
- 选择节点后首页当前节点、诊断面板和节点列表同步。
- native `selectProxy` 未完成时，不误报“已切换核心节点”。

### M2-4：日志与诊断可观测性

目标：让排障不依赖 IDE 日志，App 内能看到必要运行证据。

范围：

- 统一事件和日志模型：

```ts
interface RuntimeEvent {
  timestamp: number;
  level: 'debug' | 'info' | 'warn' | 'error';
  source: 'ui' | 'vpn' | 'core' | 'subscription' | 'config' | 'diagnostic';
  message: string;
}
```

- `RuntimeStore` 从 `string[]` 迁移或兼容到结构化事件。
- 日志页：
  - level 过滤。
  - 搜索。
  - 实时追踪开关。
  - 复制诊断信息。
  - 导出到 `files/mihomo/logs`。
- 诊断面板：
  - Runtime 快照。
  - active profile。
  - 当前 group/node。
  - tunFd。
  - mihomo 版本。
  - protect hook 状态。
  - graceful stop 可用性。
  - 最近错误。
  - POC/smoke 结果。
- 回归脚本结果读取：
  - 优先使用脚本生成的摘要文件。
  - 若没有摘要文件，诊断面板显示“未运行”，不要写死 PASS。

验收：

- 连接失败时，首页 error banner、日志页、诊断面板显示同一错误来源。
- 连接成功时，诊断面板显示 tunFd、core running、protect active。
- 导出的诊断信息足够包含 snapshot、settings、active profile、最近 60 条事件。

### M2-5：流量统计与真实 smoke

目标：把“已连接”从状态展示推进到可重复验证的真实网络访问。

范围：

- 明确流量统计来源：
  - 优先 native/mihomo stats。
  - 若短期不可得，先用 TUN fd 读写计数作为低精度统计，并在 UI 标注为 TUN 统计。
- 更新 `RuntimeSnapshot.uploadSpeed/downloadSpeed`：
  - 连接中周期更新。
  - 断开后清零实时速度，保留今日累计。
- 今日流量：
  - 新增每日累计文件，按本地日期 rollover。
- smoke：
  - 连接后系统浏览器访问固定 HTTPS URL。
  - 断开后资源清理。
  - 日志中有 DNS/TCP/protect/core 证据。
- 路由模式回归：
  - `blocking-default`
  - `split-default`
  - `no-routes`
  - `exclude-local`

验收：

- `scripts/run_mvp01_browser_verify.sh` 或新 smoke 脚本能稳定复现成功/失败结果。
- 首页实时速度不再长期固定为 0。
- 今日流量在 App 重启后保留。
- smoke 失败时诊断面板能定位到 config、VPN、protect、core、DNS 或 outbound 之一。

### M2-6：配置可靠性和导入体验

目标：降低真实订阅和复杂 YAML 下的解析风险。

范围：

- 文件导入：
  - 接入系统文件选择器。
  - 支持 `.yaml`、`.yml`、`.txt`。
  - 导入后先校验，成功再保存。
- YAML 解析：
  - 当前字符串解析可以继续用于 MVP，但需要补测试覆盖。
  - 若 ArkTS 侧无法稳定引入 YAML parser，则考虑将解析工作下沉到 Go/native 或维护一套受限解析器。
- 校验：
  - 不支持字段继续拦截。
  - 对空 proxies、空 rules、缺少 group、group 引用不存在的节点给 warning。
  - runtime YAML 生成失败不能覆盖旧 runtime。
- Profile 管理：
  - active profile 不允许删除。
  - 删除前确认。
  - 重置所有配置放在危险操作确认里。

验收：

- 真实订阅 YAML 至少覆盖：
  - block style proxies。
  - inline style proxies。
  - select/url-test/fallback group。
  - rules 引用 group。
- 无效 YAML 保存失败时，旧 runtime 仍可连接。
- 文件导入失败有明确错误，不产生半 profile。

## 5. 推荐执行顺序

1. M2-1 UI 基线迁移。
2. M2-2 设置与连接参数闭环。
3. M2-3 节点与代理组控制面。
4. M2-4 日志与诊断可观测性。
5. M2-5 流量统计与真实 smoke。
6. M2-6 配置可靠性和导入体验。

理由：

- UI 先迁移，可以尽早暴露手机/平板信息架构问题。
- Settings 和 route mode 已经有 VPN Ability 基础，闭环成本相对低。
- 节点控制面依赖更好的配置解析，适合在 UI 稳定后推进。
- 日志/诊断应早于大规模 native 能力扩展，否则真实 smoke 失败时定位成本会很高。
- 文件导入和复杂 YAML 解析容易扩大范围，建议放在核心链路稳定之后。

## 6. 工程拆分建议

下一阶段可以先不做大规模目录重组，但建议逐步从 `Index.ets` 中拆出边界：

```text
entry/src/main/ets/pages/Index.ets
entry/src/main/ets/models/MvpTypes.ets
entry/src/main/ets/config/ConfigService.ets
entry/src/main/ets/subscription/SubscriptionService.ets
entry/src/main/ets/runtime/RuntimeStore.ets
entry/src/main/ets/runtime/VpnControlService.ets
entry/src/main/ets/settings/SettingsService.ets        # 新增
entry/src/main/ets/diagnostics/DiagnosticService.ets    # 新增
entry/src/main/ets/proxy/ProxyService.ets               # 可选，节点控制面稳定后新增
```

拆分原则：

- `Index.ets` 保留页面状态和 UI 组合。
- Service 层负责文件、订阅、settings、runtime、diagnostic。
- VPN Extension 仍是 native core 生命周期 owner。
- UI 不直接调用 `pocNative.startMihomo*`。
- 所有跨层状态都落到结构化模型，避免页面里拼字符串做判断。

## 7. 测试和验收清单

### 7.1 单元 / 轻量测试

- `ConfigService`
  - `generateRuntimeYaml()` 保留 proxies/groups/rules。
  - unsupported keys 拦截。
  - inline/block proxies 解析。
  - proxy-groups 解析。
  - invalid YAML 不覆盖 runtime。

- `SubscriptionService`
  - URL scheme 校验。
  - HTTP 非 200。
  - 空 body。
  - body 超过 5 MiB。
  - 校验失败不替换旧文件。
  - 成功刷新更新 metadata。

- `SettingsService`
  - 默认值。
  - 持久化。
  - 损坏文件 fallback。

- `RuntimeStore`
  - 结构化事件上限。
  - snapshot 更新。
  - unknown 恢复逻辑。

### 7.2 设备 smoke

- 冷启动：
  - 首页显示 idle。
  - active profile 正确。
  - 诊断面板可打开。

- 配置：
  - 创建本地 profile。
  - 添加订阅。
  - 刷新订阅。
  - 切换 active profile。
  - 校验错误显示。

- VPN：
  - connect 成功。
  - disconnect 成功。
  - 重复点击不会产生多实例。
  - App 回前台后 connected/unknown 表达正确。

- 网络：
  - 浏览器 HTTPS 访问成功。
  - 断开后访问路径恢复。
  - protect 失败能进入 error。

- UI：
  - 手机底部导航。
  - 手机节点 Bottom Sheet。
  - 平板侧边栏。
  - 平板配置双栏。
  - 长 profile 名、长节点名、长错误信息不溢出。

## 8. 风险与处理策略

| 风险 | 影响 | 策略 |
| --- | --- | --- |
| `Index.ets` 继续膨胀 | UI 改动风险高 | M2-1 先按 Builder 分区，M2-3 后再拆 service/component |
| YAML 字符串解析不稳 | 真实订阅展示错误 | 补测试，限制 MVP 支持范围，必要时下沉 native 解析 |
| native stats/selectProxy 未就绪 | 节点和流量只能展示静态状态 | UI 明确区分“本地选择”和“core 已应用”，stats 先用 TUN 计数兜底 |
| VPN Extension 生命周期不稳定 | UI 显示 connected 但实际断开 | 保留 unknown 恢复策略，增加 health check |
| 日志来源分散 | 排障困难 | 统一 RuntimeEvent，所有 service 写同一事件入口 |
| 平板适配返工 | 布局成本高 | M2-1 同时实现手机/平板，而不是手机完成后再补 |
| 设置项过多但未生效 | 用户误判能力 | 未闭环的设置必须 disabled 或显示“待接入” |

## 9. 下一步具体任务

建议从下面 8 个任务开始，完成后再进入 native selectProxy/stats：

1. 新增 UI token 和 FlowGuard 文案，替换旧浅色主页。
2. 在 `Index.ets` 实现手机底部导航和平板侧边栏。
3. 落地首页状态球、pills、error banner、profile chips、route mode select。
4. 新增 settings 持久化，并把 route mode 传入 connect。
5. 将配置页改成新原型结构，保留现有订阅/保存/校验逻辑。
6. 增加诊断面板，先展示真实 RuntimeSnapshot、active profile、tunFd、lastError。
7. 扩展 `ConfigService` 的 proxy-groups 解析和测试。
8. 新增新阶段 smoke 清单或脚本，覆盖连接、断开、订阅、浏览器访问。

完成以上任务后，MVP-02 的产品主链路就能从“工程验证页面”升级为“可试用客户端原型”。
