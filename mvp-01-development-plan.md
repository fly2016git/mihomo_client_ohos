# MVP-01 开发计划和详细设计

## 1. 目标

MVP-01 的目标是把 POC-01 到 POC-06 中已经验证通过的能力产品化，先形成一个“控制面闭环”稳定的 HarmonyOS mihomo VPN App，再把真实流量闭环作为硬验收门槛。

为避免范围失控，MVP-01 拆成两个连续里程碑：

- MVP-01A：控制面闭环。本地配置保存、runtime YAML 生成、VPN 创建、mihomo core start/stop、状态恢复、错误处理和 POC 回归。
- MVP-01B：真实流量闭环。明确并验证 mihomo 如何消费 HarmonyOS VPN/TUN 流量，完成系统浏览器真实访问 smoke。

MVP-01A 必须做到：

- 用户可以选择一个本地配置或订阅配置。
- App 可以生成移动端安全 runtime YAML。
- 用户可以连接 VPN。
- VpnExtensionAbility 可以启动 mihomo core。
- 用户可以断开 VPN。
- App 重启或 UI Ability 被回收后，页面能恢复真实运行状态。
- 配置错误、启动失败、重复点击和异常停止都有明确状态和错误提示。

MVP-01B 必须补齐：

- App 可以添加订阅 URL、手动刷新订阅并保存最新原始 YAML。
- 订阅刷新失败不会破坏上一次可用 raw/runtime 文件。
- mihomo core 与 HarmonyOS VPN/TUN 流量路径打通。
- 用户可以在系统浏览器完成一次真实网络访问验证。

MVP-01 不追求完整 Clash 客户端体验。它只验证“产品主链路”是否稳定：

```text
配置准备 -> 点击连接 -> VPN/TUN 创建 -> mihomo 启动 -> 状态展示 -> 点击断开 -> 资源清理 -> 状态恢复
```

## 2. 范围

### 2.1 必须包含

- 本地 YAML 配置的保存、读取、切换为 active。
- 原始配置和 runtime 配置分离保存。
- runtime YAML 移动端字段覆盖。
- 不支持字段校验和错误提示。
- VPN 权限触发和 VpnExtensionAbility 启停。
- CoreRuntime 状态机。
- NAPI bridge 的 start/stop/config-file 调用封装。
- 连接/断开主按钮。
- 当前状态、当前配置、最近错误展示。
- 最近运行日志展示。
- POC-03 到 POC-06 回归命令保留。
- TUN/core 流量路径技术验证：明确使用外部 TUN fd、mihomo 内部 TUN，或 ArkTS packet loop 的具体方案。
- 最小订阅更新器：添加订阅 URL、手动刷新、错误提示、临时文件写入、校验成功后替换、失败不破坏旧配置。

### 2.2 暂不包含

- 节点测速。
- 代理组节点选择 UI。
- 规则编辑器。
- 日志流实时追踪。
- 流量统计图表。
- DNS 接管完整产品化。
- 真实 native crash 自动恢复。
- 多配置复杂管理。
- 完整订阅更新器：自动刷新、HTTP 缓存、ETag、Last-Modified、复杂压缩策略、指数退避。
- 云同步、账户体系、上架素材。

### 2.3 可选但建议预留

- RuntimeSnapshot 预留 upload/download 字段。
- Native bridge 预留 `reloadConfig`，但 MVP-01 至少需要可探测的 `getRuntimeState` 或等价轻量健康检查。
- UI 保留 “诊断” 区域用于显示 POC 回归结果。

## 3. 当前基础

已通过的 POC 能力：

- POC-01：VPN TUN 创建和 fd 读写探测通过。
- POC-02：Go `.so` 构建、NAPI 加载和基础调用通过。
- POC-03：socket protect bridge 通过，protect 失败会中止 outbound。
- POC-04：完整 mihomo `.so` 可加载，固定 YAML start/stop 通过。
- POC-05：App 沙箱配置目录、raw/runtime YAML、config file 启动、配置切换通过。
- POC-06：生命周期状态机、非法配置恢复、重复启动/停止、destroy 清理通过。

当前主要代码位置：

```text
entry/src/main/ets/pages/Index.ets
entry/src/main/ets/entryability/EntryAbility.ets
entry/src/main/ets/vpnability/MihomoPocVpnAbility.ets
entry/src/main/ets/native/PocNative.ets
entry/src/main/cpp/poc_napi.cpp
entry/src/main/cpp/types/libpoc_napi/index.d.ts
core/mihomo/openharmony_bridge/main.go
scripts/build_poc04_mihomo_core.sh
scripts/huawei_tools_env.sh
```

## 4. 开发原则

- 先产品化控制面，再扩展真实代理能力。
- UI 不直接持有 tunFd，不直接调用 native core start。
- VpnExtensionAbility/CoreRuntime 是运行状态唯一事实来源。
- 页面展示的连接状态必须来自 RuntimeStore/RuntimeSnapshot。
- 所有 start/stop/reload 都必须幂等。
- 配置错误不能进入 connected。
- core 启动失败后必须回到 `idle` 或 `error`，不能卡在 `starting`。
- stop 必须先停 mihomo，再 destroy VPN。
- 保留所有 POC 入口作为回归测试资产。

## 5. MVP-01 架构

### 5.1 分层

```text
ArkUI Pages
├── HomePage
├── ProfileEditor
└── DiagnosticsPanel

ArkTS Service Layer
├── RuntimeStore
├── ProfileService
├── SubscriptionService
├── ConfigService
├── VpnControlService
└── DiagnosticService

VpnExtensionAbility
├── VpnRuntime
├── CoreRuntime
├── ProtectBridge
└── LifecycleGuard

NAPI / C++
├── loadMihomoCore
├── startMihomoConfigFile
├── startMihomoConfigFileWithTunFd
├── stopMihomo
├── registerProtect
└── socket test POC APIs

Go mihomo bridge
├── MihomoOhosStartConfigFile
├── MihomoOhosStartConfigFileWithTunFd
├── MihomoOhosStop
├── MihomoOhosLastError
└── MihomoOhosVersion
```

### 5.2 模块职责

`RuntimeStore`

- 保存 UI 可读的运行状态。
- 提供 `getSnapshot()`。
- 提供状态变更通知接口。
- 存储最近错误和最近日志。

`ProfileService`

- 管理本地 profile 元数据。
- 管理 active profile。
- 保存用户导入的 raw YAML。
- 保存订阅 profile 的 URL、刷新时间、HTTP 状态码、下载字节数和失败信息。
- MVP-01 可以有多个 profile，但同一时间只允许一个 active profile。

`SubscriptionService`

- 添加和更新订阅 URL。
- 执行 HTTP(S) 下载。
- 处理超时、基础重定向、状态码、响应大小和 UTF-8 编码。
- 维护 lastFetchedAt、lastSuccessAt、lastStatusCode、bytes、失败次数。
- 下载成功后原子写入 raw YAML，并触发 ConfigService 校验和 runtime YAML 生成。
- 下载失败时保留上一次可用 raw/runtime 文件，不破坏 active profile。

`ConfigService`

- 读取 raw YAML。
- 校验不支持字段。
- 生成 runtime YAML。
- 维护 App 沙箱目录结构。

`VpnControlService`

- UI 调用入口。
- 发起 `vpnExtension.startVpnExtensionAbility()`。
- 发起 `vpnExtension.stopVpnExtensionAbility()`。
- 不直接调用 native core。

`VpnRuntime`

- 运行在 VpnExtensionAbility 内。
- 创建 VPN config。
- 持有 VpnConnection 和 tunFd。
- 注册 protect callback。
- 管理 CoreRuntime。

`CoreRuntime`

- 调用 NAPI bridge。
- 加载 mihomo core。
- start/stop/reload。
- 管理 mihomo 运行状态。

`LifecycleGuard`

- start/stop/destroy 互斥。
- 防止重复点击产生多实例。
- 所有异常路径进入 `idle` 或 `error`。

## 6. 数据模型

### 6.1 Profile

```ts
export type ProfileType = 'local' | 'subscription';

export interface Profile {
  id: string;
  name: string;
  type: ProfileType;
  active: boolean;
  sourceUrl?: string;
  subscription?: SubscriptionMeta;
  rawPath: string;
  runtimePath: string;
  homeDir: string;
  createdAt: number;
  updatedAt: number;
  lastValidatedAt?: number;
  lastError?: string;
}
```

MVP-01 默认内置一个本地 profile，但必须支持新增订阅 profile：

```text
id: "default"
name: "Default"
type: "local"
active: true
```

### 6.2 SubscriptionMeta

```ts
export interface SubscriptionMeta {
  url: string;
  userAgent: string;
  etag: string;
  lastModified: string;
  lastFetchedAt: number;
  lastSuccessAt: number;
  failureCount: number;
  lastStatusCode: number;
  lastError: string;
  autoUpdate: boolean;
  updateIntervalHours: number;
}
```

### 6.3 RuntimeSnapshot

```ts
export type RuntimeState = 'idle' | 'starting' | 'connected' | 'stopping' | 'error';
export type CoreState = 'stopped' | 'loading' | 'running' | 'stopping' | 'error';

export interface RuntimeSnapshot {
  runtimeState: RuntimeState;
  coreState: CoreState;
  activeProfileId: string;
  activeProfileName: string;
  tunFd: number;
  startedAt: number;
  updatedAt: number;
  lastError: string;
  lastEvent: string;
  uploadSpeed: number;
  downloadSpeed: number;
}
```

### 6.4 ConfigValidationResult

```ts
export interface ConfigValidationResult {
  ok: boolean;
  unsupportedKeys: string[];
  errors: string[];
  warnings: string[];
}
```

### 6.5 RuntimeCommand

```ts
export type RuntimeCommandType = 'connect' | 'disconnect' | 'reload' | 'recover';

export interface RuntimeCommand {
  type: RuntimeCommandType;
  profileId: string;
  requestedAt: number;
  requestId: string;
}
```

### 6.6 SubscriptionUpdateResult

```ts
export interface SubscriptionUpdateResult {
  ok: boolean;
  profileId: string;
  statusCode: number;
  bytes: number;
  fromCache: boolean;
  rawPath: string;
  runtimePath: string;
  error: string;
  updatedAt: number;
}
```

## 7. 文件和目录规范

### 7.1 App 沙箱目录

MVP-01 继续复用 POC-05 已验证目录结构，并改名为正式目录：

```text
context.filesDir + "/mihomo"
├── home/
├── profiles/
│   ├── default.raw.yaml
│   └── subscription-{id}.raw.yaml
├── run/
│   ├── default.runtime.yaml
│   └── subscription-{id}.runtime.yaml
├── cache/
│   └── subscriptions/
│       ├── {id}.download.tmp
│       └── {id}.headers.json
├── geo/
├── logs/
└── state/
    ├── profiles.json
    └── runtime.json
```

### 7.2 路径约束

- 所有 runtime path 必须位于 `context.filesDir + "/mihomo"` 下。
- raw YAML 和 runtime YAML 必须分离。
- raw YAML 不直接传给 mihomo。
- 所有外部输入路径必须经过 sandbox subpath 检查。
- `homeDir` 传给 mihomo bridge 时必须是绝对 sandbox 路径。

## 8. 配置设计

### 8.1 输入

MVP-01A 支持本地 YAML 输入，MVP-01B 增加订阅 URL 输入。输入方式优先级从高到低：

1. 订阅 URL 添加和刷新。
2. 页面文本框粘贴 YAML。
3. 内置示例 YAML。
4. 未来扩展文件选择器导入。

订阅 URL 是 MVP-01B 必须能力。订阅更新器必须与连接主链路解耦：下载失败不能破坏当前可用配置，刷新成功后才替换 raw/runtime 文件。

### 8.2 校验

MVP-01 明确拒绝：

```text
script:
proxy-providers:
rule-providers:
external-ui:
interface-name:
routing-mark:
```

MVP-01 可覆盖而不拒绝：

```text
allow-lan
mixed-port
port
socks-port
redir-port
tproxy-port
external-controller
dns.enable
tun.enable
log-level
mode
ipv6
find-process-mode
profile.store-selected
profile.store-fake-ip
```

### 8.3 runtime YAML 生成

MVP-01 先采用保守生成策略：

- 从 raw YAML 保留 `proxies`、`proxy-groups`、`rules`。
- 覆盖移动端敏感字段。
- 禁用 mihomo 内部 TUN。
- 暂不启用 external-controller。
- 暂不启用 mixed/http/socks 监听端口。
- 仅承诺支持简单内联 Clash YAML；复杂 YAML、anchors、proxy-providers、rule-providers 和脚本字段必须明确拒绝。

最小 runtime 模板（MVP-01B 第二轮起）：

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
  enable: true
  listen: 0.0.0.0:53
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.0/15
  ipv6: false
  nameserver:
    - 223.5.5.5
    - 119.29.29.29
  fallback:
    - 1.1.1.1
    - 8.8.8.8
  default-nameserver:
    - 223.5.5.5
    - 119.29.29.29
tun:
  enable: false        # 这里关闭，由 Go bridge 在 fd-backed 启动时打开
proxies: []
proxy-groups: []
rules:
  - MATCH,DIRECT
```

DNS 必须 `enable: true` 并配置 `fake-ip` 模式：fd-backed TUN 启动时 Go bridge `injectTunFd` 会覆盖 `tun` 块为 `enable: true / file-descriptor: <fd> / stack: gvisor / dns-hijack: ['any:53'] / inet4-address: ['10.7.0.2/24'] / mtu: 1500`，并自动补全缺失的 DNS 字段（listen、enhanced-mode、fake-ip-range、nameserver、default-nameserver）。

### 8.4 YAML 处理策略

ArkTS 侧如果没有稳定 YAML parser，MVP-01 可以分两步：

1. 先实现保守文本级校验和模板生成，保证主链路。
2. 后续引入 YAML parser 或把配置转换下沉到 Go bridge。

MVP-01A 的实现底线：

- 可以直接生成安全 runtime 模板。
- 可以拒绝已知不支持字段。
- 不要求可靠转换任意真实订阅。

更推荐的长期方案：

- ArkTS 负责文件和 UI。
- Go bridge 负责 mihomo config parse/validate/transform。
- NAPI 返回结构化校验结果。

## 9. 订阅更新器设计

### 9.1 目标

MVP-01B 的订阅更新器必须做到“最小可用、可诊断、失败不破坏现有配置”：

- 支持添加 HTTP/HTTPS 订阅 URL。
- 支持手动刷新。
- 自动刷新、ETag、Last-Modified、复杂 HTTP 缓存进入 MVP-02。
- 301/302/307/308 重定向可依赖系统 HTTP API 默认行为；MVP-01B 只要求避免无限重定向。
- gzip/deflate/br 如果系统 HTTP API 自动解压则可用；MVP-01B 不要求手动实现全部压缩格式。
- 支持 UTF-8 文本；非 UTF-8 响应先明确报错，不做静默转码。
- 支持最大下载大小限制。
- 下载成功后先写临时文件，校验通过后再原子替换 raw YAML。
- runtime YAML 生成成功后才更新 profile 元数据。
- 任何失败都保留上一次可用配置。

### 9.2 下载约束

默认参数：

```text
timeoutMs: 15000
maxRedirects: 5
maxBytes: 5 MiB
userAgent: ClashX Pro/1.118.0
autoUpdateIntervalHours: 24  # MVP-02 启用
```

状态码处理：

```text
200 -> 读取 body，校验并写入
304 -> MVP-02；MVP-01B 可按无 body 成功检查处理，不改 raw/runtime
301/302/307/308 -> 跟随重定向，限制 maxRedirects
400/401/403/404/5xx -> 失败，保留旧配置
```

### 9.3 原子更新流程

```text
用户点击刷新订阅
-> SubscriptionService.update(profileId)
-> 发起 HTTP GET
-> 写入 cache/subscriptions/{id}.download.tmp
-> 检查 body 大小和文本编码
-> ConfigService.validateRawYaml(tmpContent)
-> ConfigService.generateRuntimeYaml(tmpContent)
-> 写入 run/subscription-{id}.runtime.yaml.tmp
-> raw tmp rename 为 profiles/subscription-{id}.raw.yaml
-> runtime tmp rename 为 run/subscription-{id}.runtime.yaml
-> 更新 profiles.json 中的 lastSuccessAt、lastStatusCode、bytes
-> RuntimeStore 记录更新成功事件
```

失败回滚：

```text
下载失败
-> 不改 rawPath/runtimePath
-> failureCount + 1
-> lastError 写入 profiles.json
-> UI 显示错误
-> 如果当前 profile 已有可用 runtimePath，仍允许连接
```

### 9.4 自动更新策略

自动更新进入 MVP-02。MVP-01B 只做手动刷新。

MVP-01B 可以预留字段：

- `autoUpdate`
- `updateIntervalHours`
- `lastFetchedAt`

但 UI 不承诺后台自动刷新行为。

### 9.5 UI 行为

- 首页配置区增加订阅 URL 输入。
- 增加“添加订阅”和“刷新订阅”按钮。
- 展示最后成功刷新时间、上次 HTTP 状态码、下载字节数、最近错误。
- 刷新中禁用重复刷新按钮。
- 刷新失败但存在旧配置时，连接按钮仍可用，同时显示“使用上次成功配置”。

### 9.6 安全边界

- 只允许 `http://` 和 `https://`。
- 不支持 file、content、data、ftp 等 scheme。
- 不在日志中完整打印订阅 URL query，避免泄露 token。
- profiles.json 中可以保存 URL；后续如进入发布阶段，应评估是否加密或使用系统安全存储。
- 不执行订阅内容中的脚本字段。

### 9.7 错误码

```text
SUBSCRIPTION_INVALID_URL
SUBSCRIPTION_UNSUPPORTED_SCHEME
SUBSCRIPTION_TIMEOUT
SUBSCRIPTION_TOO_LARGE
SUBSCRIPTION_HTTP_ERROR
SUBSCRIPTION_REDIRECT_LOOP
SUBSCRIPTION_DECODE_FAILED
SUBSCRIPTION_EMPTY_BODY
SUBSCRIPTION_CONFIG_INVALID
SUBSCRIPTION_WRITE_FAILED
```

## 10. 生命周期状态机

### 10.1 RuntimeState

```text
idle
  -> starting
  -> connected
  -> stopping
  -> idle

starting
  -> error
  -> idle

connected
  -> error
  -> stopping

error
  -> idle
  -> starting
```

### 10.2 状态迁移规则

- `connect` 只允许在 `idle` 或 `error` 下执行。
- `disconnect` 只允许在 `connected`、`starting`、`error` 下执行。
- `starting` 中再次 `connect` 必须返回 busy。
- `stopping` 中再次 `disconnect` 必须返回 busy 或复用同一个 promise。
- native start 失败后进入 `error`，随后必须执行资源清理并回到 `idle` 或保持 `error` 且可再次 connect。
- stop 成功后必须进入 `idle`。
- destroy 成功后 `tunFd=-1`。

### 10.3 CoreState

```text
stopped -> loading -> running -> stopping -> stopped
              \-> error
running -> error
```

### 10.4 错误模型

```ts
export interface RuntimeError {
  code: string;
  message: string;
  detail: string;
  recoverable: boolean;
  occurredAt: number;
}
```

建议错误码：

```text
CONFIG_UNSUPPORTED_FIELD
CONFIG_PARSE_FAILED
VPN_CREATE_FAILED
CORE_LOAD_FAILED
CORE_START_FAILED
CORE_STOP_FAILED
PROTECT_REGISTER_FAILED
PROTECT_FAILED
BUSY
UNKNOWN
```

## 11. UI 设计

### 11.1 首页

第一屏就是可操作主界面，不做 landing page。

布局：

```text
状态栏
  当前状态：未连接 / 连接中 / 已连接 / 正在断开 / 错误
  当前配置：Default
  最近错误：无 / 错误摘要

主操作区
  连接 / 断开按钮
  重新加载配置按钮

配置区
  订阅 URL 输入
  添加订阅按钮
  刷新订阅按钮
  最近刷新状态
  YAML 输入框或当前 raw YAML 摘要
  保存配置按钮
  校验配置按钮

诊断区
  最近 20 条 runtime event
  POC 回归入口说明
```

### 11.2 按钮状态

```text
idle       -> Connect enabled, Disconnect disabled
starting   -> Connect disabled, Disconnect enabled
connected  -> Connect disabled, Disconnect enabled
stopping   -> Connect disabled, Disconnect disabled
error      -> Connect enabled, Disconnect enabled
```

### 11.3 首页文案

状态文案：

```text
Idle
Starting
Connected
Stopping
Error
```

错误展示：

```text
配置错误：不支持字段 script
启动失败：mihomo config parse failed
系统错误：VPN 创建失败
```

## 12. ArkTS 服务设计

### 12.1 RuntimeStore

建议文件：

```text
entry/src/main/ets/runtime/RuntimeStore.ets
```

接口：

```ts
export class RuntimeStore {
  getSnapshot(): RuntimeSnapshot;
  setSnapshot(next: RuntimeSnapshot): void;
  update(patch: Partial<RuntimeSnapshot>): void;
  appendEvent(message: string): void;
  getEvents(): string[];
}
```

MVP-01 可先用内存状态加 JSON 文件持久化，但持久化 snapshot 只能代表“最后记录状态”，不能单独证明 core 仍在运行。

UI 恢复状态时必须执行一次轻量健康检查：

- 如果 Native bridge 已提供 `getRuntimeState`，以 native 返回为准。
- 如果暂未提供，则至少调用 `pingMihomo()` 或等价探测，并在 UI 上标记状态为 `unknown` 或恢复到 `idle/error`。
- 禁止仅凭 `runtime.json` 把页面恢复为 `connected`。

### 12.2 ProfileService

建议文件：

```text
entry/src/main/ets/profile/ProfileService.ets
```

接口：

```ts
export class ProfileService {
  getActiveProfile(): Profile;
  listProfiles(): Profile[];
  createSubscriptionProfile(name: string, url: string): Profile;
  setActiveProfile(profileId: string): void;
  saveDefaultRawYaml(content: string): Profile;
  loadRawYaml(profileId: string): string;
  markValidation(profileId: string, result: ConfigValidationResult): void;
}
```

### 12.3 SubscriptionService

建议文件：

```text
entry/src/main/ets/subscription/SubscriptionService.ets
```

接口：

```ts
export class SubscriptionService {
  addSubscription(name: string, url: string): Promise<Profile>;
  update(profileId: string): Promise<SubscriptionUpdateResult>;
  updateActiveIfDue(): Promise<SubscriptionUpdateResult | null>;
  validateUrl(url: string): ConfigValidationResult;
}
```

### 12.4 ConfigService

建议文件：

```text
entry/src/main/ets/config/ConfigService.ets
```

接口：

```ts
export class ConfigService {
  ensureLayout(): MihomoLayout;
  validateRawYaml(content: string): ConfigValidationResult;
  generateRuntimeYaml(rawYaml: string): string;
  saveRuntimeYaml(profile: Profile, runtimeYaml: string): string;
}
```

### 12.5 VpnControlService

建议文件：

```text
entry/src/main/ets/runtime/VpnControlService.ets
```

接口：

```ts
export class VpnControlService {
  connect(profileId: string): Promise<void>;
  disconnect(): Promise<void>;
  reload(profileId: string): Promise<void>;
}
```

## 13. VpnExtensionAbility 设计

### 13.1 从 POC 类拆分

当前 `MihomoPocVpnAbility.ets` 同时包含 POC-03 到 POC-06 逻辑。MVP-01 应逐步拆分：

```text
entry/src/main/ets/vpnability/MihomoPocVpnAbility.ets
entry/src/main/ets/vpnability/runtime/VpnRuntime.ets
entry/src/main/ets/vpnability/runtime/CoreRuntime.ets
entry/src/main/ets/vpnability/runtime/LifecycleGuard.ets
entry/src/main/ets/vpnability/runtime/ProtectBridge.ets
entry/src/main/ets/vpnability/poc/Poc03Runner.ets
entry/src/main/ets/vpnability/poc/Poc04Runner.ets
entry/src/main/ets/vpnability/poc/Poc05Runner.ets
entry/src/main/ets/vpnability/poc/Poc06Runner.ets
```

拆分原则：

- POC runner 保留命令行触发。
- 产品路径使用 `VpnRuntime`。
- 不在产品路径中引用 POC 常量。

### 13.2 Want 参数

产品 connect：

```ts
{
  command: 'connect',
  profileId: 'default',
  requestedAt: '...',
  requestedBy: 'ui'
}
```

产品 disconnect：

```ts
{
  command: 'disconnect',
  requestedAt: '...',
  requestedBy: 'ui'
}
```

POC 回归继续使用：

```ts
{
  poc: 'POC-06'
}
```

### 13.3 运行流程

```text
onRequest(command=connect)
-> LifecycleGuard.enterStarting()
-> ProfileService/ConfigService 确认 runtimePath
-> createVpnConnection()
-> create VPN config
-> probe optional
-> register protect callback
-> CoreRuntime.load()
-> CoreRuntime.start(homeDir, runtimePath)
-> RuntimeStore connected
```

断开流程：

```text
onRequest(command=disconnect) 或 stopVpnExtensionAbility
-> LifecycleGuard.enterStopping()
-> CoreRuntime.stop()
-> stop TUN reader
-> destroy VpnConnection
-> RuntimeStore idle
```

## 14. Native Bridge 设计

MVP-01 继续使用当前已验证接口：

```ts
// 异步接口（NAPI async work，单次调用、耗时操作）
loadMihomoCore(): Promise<PocStatus>;
startMihomoConfigFile(homeDir: string, configPath: string): Promise<PocStatus>;
startMihomoConfigFileWithTunFd(homeDir: string, configPath: string, tunFd: number): Promise<PocStatus>;
stopMihomo(): Promise<PocStatus>;
pingMihomo(): Promise<PocStatus>;
getMihomoVersion(): Promise<PocStatus>;

// 同步接口（JS 主线程执行，避免 OpenHarmony Go runtime 跨线程 cgo 风险）
registerProtect(callback): PocStatus;
enableProtectHook(): PocStatus;                  // MVP-01B 新增
disableProtectHook(): PocStatus;                 // MVP-01B 新增
isMihomoRunning(): PocStatus;                    // MVP-01B 新增
gracefulStopMihomo(): PocStatus;                 // MVP-01B 新增

// 同步辅助
startTunFdReadinessProbe(tunFd: number, durationMs: number): PocStatus;
startTunFdPollProbe(tunFd: number, durationMs: number): PocStatus;
holdTunFdReference(tunFd: number): PocStatus;
releaseTunFdReference(): PocStatus;
```

`enableProtectHook` / `disableProtectHook` / `gracefulStopMihomo` 等控制类操作走同步路径，是 MVP-01B 第二轮专门针对 OpenHarmony Go runtime TLS 跨线程 cgo crash 做出的设计决策。

对应的 Go bridge C ABI 导出符号：

```c
MihomoOhosVersion()
MihomoOhosPing()
MihomoOhosStartConfig(homeDir, configBytes, configLen)
MihomoOhosStartConfigFile(homeDir, configPath)
MihomoOhosStartConfigFileWithTunFd(homeDir, configPath, tunFd)
MihomoOhosStop()
MihomoOhosGracefulStop()        // MVP-01B 第二轮新增
MihomoOhosSetProtectBridge(fn)
MihomoOhosEnableProtectHook()   // MVP-01B 第二轮新增
MihomoOhosDisableProtectHook()  // MVP-01B 第二轮新增
MihomoOhosIsRunning()           // MVP-01B 第二轮新增
MihomoOhosLastError()
MihomoOhosFreeCString(s)
```

`MihomoOhosGracefulStop` 设计要点：先 `protectOn = false; dialer.DefaultSocketHook = nil`，等待在飞 protect 调用结束（`waitProtectIdleLocked`），再调用 `hub.Parse(stoppedConfig)` 让 mihomo 自己排空 TUN reader / DNS resolver / outbound dialer goroutine，最后清理 `started/activeTunFd/protectFn`。这是 fd-backed TUN 场景下安全关闭的关键路径，取代了之前的 skip-all 止血策略。

建议后续改名为正式接口：

```ts
loadCore(): Promise<NativeStatus>;
startConfigFile(homeDir: string, configPath: string): Promise<NativeStatus>;
stopCore(): Promise<NativeStatus>;
getLastError(): Promise<NativeStatus>;
```

MVP-01 不强制改名，避免破坏 POC 回归。

## 15. 开发计划

当前进度（2026-06-09 — MVP-01B 关键修复轮次）：

### MVP-01A（已通过）

- 控制面产品化第一版已完成并通过 Mate 80 / HarmonyOS 6.1.1(API 24) 真机 smoke。
- 已新增正式 MVP 类型、配置服务、运行状态服务和 VPN 控制服务。
- 首页已从 POC 控制台改为 MVP-01A 控制面首页，支持本地 YAML 保存/校验、连接/断开、状态和事件展示。
- `MihomoPocVpnAbility` 已保留 POC 路径，并新增 `command=connect` / `command=disconnect` 产品路径。
- MVP-01A smoke、special smoke 和 POC-05/06 回归在 `192.168.50.153:37805` 真机上均已通过（2026-06-09）。

### MVP-01B 第一轮（fd-backed TUN 接入 + 控制面闭环）

- 已完成 TUN fd 到 mihomo TUN adapter 的第一段真实链路：产品 connect 调用 `startMihomoConfigFileWithTunFd(homeDir, runtimePath, tunFd)`，Go bridge 在内存中注入 `tun.file-descriptor`，mihomo 使用 HarmonyOS VPN 创建的 fd 启动 gVisor TUN stack。
- 6 种路由模式（`split-default` / `default` / `blocking-empty` / `blocking-split` / `blocking-default` / `no-routes` / `exclude-local`）已支持，可通过 `vpnRouteMode` 参数切换。
- 订阅 URL 添加、手动刷新、原子文件替换和失败回滚已实现（`SubscriptionService`），首页 UI 已暴露订阅入口和 profile 切换器。

#### 第一轮真机探测发现（关键问题）

- 系统 `netstat -rn` 即使指定 `0.0.0.0/0` 或 split-default，默认路由仍不出现在路由表中，但 `vpn-tun` TX 字节 > 0，说明 DNS 查询包确实进入了 TUN。
- `vpn-tun` RX = 0，浏览器报 `dnsServerReturnNothing` / `Timeout`，即 mihomo 没有回复任何 DNS 包。

### MVP-01B 第二轮修复（2026-06-09，本轮重点）

定位到核心 bug 是 protect hook 从未真正启用。已完成以下修复：

#### 修复 1：`enableProtectHookLocked` 真正激活 hook

- 之前 `enableProtectHookLocked()` 被硬编码为 `protectOn = false; DefaultSocketHook = nil`，作为 stop crash 的临时止血。
- 现已修正为真正激活：`protectOn = true; dialer.DefaultSocketHook = mihomoProtectSocketHook`。
- 这是 MVP-01B 真实流量无法闭环的**根因**：mihomo 出站 DNS 查询没有 protect callback，流量回环进 VPN，mihomo 无法解析真实 DNS，因此无法回复 fake-ip 给系统浏览器。

#### 修复 2：NAPI enable/disable/isRunning/gracefulStop 改为同步调用

- 之前 `enableProtectHook` / `disableProtectHook` 使用 NAPI async work，会在不同 worker 线程上进入 cgo。
- OpenHarmony Go runtime 的 TLS 补丁（POC-02 阶段已记录）可能在跨线程进入 cgo 时崩溃。
- 已将这些 NAPI 方法改为同步调用（在 JS 主线程执行），保持 cgo 调用线程一致性。
- ArkTS 类型声明从 `Promise<PocStatus>` 改为 `PocStatus`。

#### 修复 3：新增 `MihomoOhosGracefulStop` 安全停止路径

- 直接调 `MihomoOhosStop()` 在 fd-backed TUN 场景仍会触发 SIGSEGV，原因是 mihomo TUN reader / DNS resolver / outbound dialer goroutine 仍在使用 fd 时被强行中断。
- 新增 `MihomoOhosGracefulStop` 导出：先关闭 protect hook，等待在飞调用结束，再调用 `hub.Parse(stoppedConfig)` 让 mihomo 自己排空所有 goroutine。
- ArkTS disconnect 流程改为：`disableProtectHook` → `gracefulStopMihomo` → `sleep 500ms` → `VpnConnection.destroy()`，取代原来的 skip-all 止血策略。

#### 修复 4：DNS hijack 配置改进

- 之前 `dns-hijack: ['0.0.0.0:53']` — 不是 mihomo 标准语法，可能未生效。
- 现改为 `dns-hijack: ['any:53']` — mihomo 规范语法，匹配任何目的 IP 的 UDP/53 包。
- Go bridge `injectTunFd` 还会自动补全 DNS 块：`listen: 0.0.0.0:53`、`enhanced-mode: fake-ip`、`fake-ip-range: 198.18.0.0/15`、`nameserver: [223.5.5.5, 119.29.29.29]`、`default-nameserver` 同上。
- `ConfigService.ets` 中的 `DEFAULT_RUNTIME_CONFIG` 模板也同步更新这些字段。

#### 修复 5：路由模式参数解析 bug

- `parseProductVpnOptions` 之前把除 `default` 外的所有路由模式都强制改为 `split-default`，导致新增的 5 种模式实际未生效。
- 已修复为白名单匹配：`['default', 'split-default', 'blocking-empty', 'blocking-split', 'blocking-default', 'no-routes', 'exclude-local']`。

### 本轮通过范围

- VPN/TUN 创建、protect callback 注册、mihomo `.so` 加载、fd-backed runtime YAML 启动、VPN destroy 和状态恢复。
- MVP-01A smoke、special smoke、POC 回归全部通过，未出现 native crash。
- 订阅服务和订阅 UI 已实现（订阅刷新真机端到端 smoke 待补）。

### 后续验证

- 2026-06-10 已在 `192.168.3.65:37805` 用 `blocking-default` 完成真实浏览器端到端 smoke：WebView 页面正文命中 `httpbin.org/get` JSON，`vpn-tun` RX 字节增长，浏览器 DNS 错误为 0，connect/disconnect crash 为 0。
- protect callback 在真实 outbound 路径上的实际触发观测。
- 订阅 URL 真机刷新一遍 + 切换为 active 后再连接的端到端流程。

### 阶段 A：基线整理

预计：1-2 天。

任务：

- 固定 POC-01 到 POC-06 当前通过状态。
- 整理 POC 回归命令到脚本。
- 新增 `docs` 或当前根目录 MVP 文档。
- 标记 POC 代码和产品代码的边界。
- 明确当前 `core/mihomo/openharmony_bridge` 是正式 bridge 源码路径，构建脚本默认包路径必须与实际目录一致。

验收：

- HAP 构建通过。
- POC-03 到 POC-06 至少可单独触发。
- 文档记录当前设备、SDK、命令。
- `scripts/build_poc04_mihomo_core.sh` 可以从干净环境构建出 `libmihomo_ohos.so`，且导出符号检查通过。

状态：

- 已完成。POC-01 到 POC-06 的通过状态已记录在产品设计文档，MVP-01A HAP 构建通过。

### 阶段 B：TUN/core 流量路径技术决策

预计：2-4 天。

任务：

- 明确 HarmonyOS VPN/TUN fd 的数据如何进入 mihomo。
- 在以下方案中选择一个并写入文档：
  - mihomo bridge 支持外部 TUN fd。
  - 启用 mihomo 内部 TUN，并确认 HarmonyOS 权限和 fd 模型可行。
  - ArkTS/Native 层实现 packet loop，把 TUN 包转交给 core 可消费的入口。
- 明确 protect callback 在真实 outbound 中被调用，而不只是 POC socket test 中被调用。
- 形成一个最小真实流量 smoke 设计，不要求 UI 完成。

验收：

- 能解释真实浏览器流量从系统 VPN 到 mihomo outbound 的完整路径。
- 能指出当前缺口对应的代码模块。
- 如果无法打通，MVP-01A 仍可继续，但 MVP-01B 不得标记完成。

状态：

- 进行中。2026-06-08 已新增 `MihomoOhosStartConfigFileWithTunFd(homeDir, configPath, tunFd)` C ABI、NAPI Promise 接口和 ArkTS 调用入口。
- `scripts/build_poc04_mihomo_core.sh` 已检查新导出符号 `MihomoOhosStartConfigFileWithTunFd`，并扩展为同时检查 MVP-01B 第二轮新增的 `EnableProtectHook`、`DisableProtectHook`、`IsRunning`、`GracefulStop`。
- 真机 smoke 日志已验证 `product tunFd created fd=` 后调用 `MVP-01B calling MihomoOhosStartConfigFileWithTunFd ... tunFd=`，并返回 `code=0`。
- Go bridge 已在内存中把产品 runtime YAML 注入为 fd-backed TUN 配置：`tun.enable=true`、`tun.file-descriptor=<tunFd>`、`tun.stack=gvisor`、`tun.auto-route=false`、`tun.auto-detect-interface=false`、`tun.inet4-address=10.7.0.2/24`、`tun.mtu=1500`。
- 2026-06-09 第二轮已把 `tun.dns-hijack` 从 `0.0.0.0:53` 改为 mihomo 规范语法 `any:53`，并在 `injectTunFd` 中自动补全 DNS 块（`listen: 0.0.0.0:53`、`enhanced-mode: fake-ip`、`fake-ip-range: 198.18.0.0/15`、`nameserver/default-nameserver` 默认值）。
- 产品 VPN config 已调整为 `10.7.0.2/24`，并用 `blockedApplications=['com.example.mihomopoc']` 避免控制 App 自身回环进入 VPN。
- 路由模式已扩展为 7 种：`split-default`（默认）、`default`、`blocking-empty`、`blocking-split`、`blocking-default`、`no-routes`、`exclude-local`，可通过 `--ps vpnRouteMode <mode>` 切换；`parseProductVpnOptions` 之前的白名单 bug（把非 `default` 的所有模式强制改回 `split-default`）已修复。
- 2026-06-09 真机路由诊断结论：上述路由组合创建 VPN 后，设备 `netstat -rn` 均只显示 `10.7.0.0/24 -> vpn-tun`，未出现默认路由；但 `vpn-tun` TX > 0（DNS 包确实进入 TUN）、RX = 0（mihomo 未回复）。
- 第二轮定位到 RX = 0 的**根因**：`enableProtectHookLocked()` 被硬编码为禁用（`protectOn = false; DefaultSocketHook = nil`），导致 mihomo 出站 DNS 没有 protect → 流量回环 → mihomo 无法解析 → 无法回复 fake-ip → 浏览器报 `dnsServerReturnNothing`。已修复：`enableProtectHookLocked()` 现在真正激活 `dialer.DefaultSocketHook = mihomoProtectSocketHook`，并在 `startWithConfig` fd-backed TUN 路径上自动启用。
- fd-backed TUN stop 风险已用 `MihomoOhosGracefulStop` 新导出解决：先 `disableProtectHook` + `waitProtectIdleLocked` 等待在飞 protect 调用结束，再 `hub.Parse(stoppedConfig)` 让 mihomo 自己排空 TUN reader / DNS resolver / outbound dialer goroutine，最后才允许 `VpnConnection.destroy()` 关闭 fd。
- NAPI `enableProtectHook` / `disableProtectHook` / `isMihomoRunning` / `gracefulStopMihomo` 已从异步 work 改为同步 NAPI 调用，避免 OpenHarmony Go runtime TLS 补丁在跨线程进入 cgo 时崩溃。ArkTS 类型从 `Promise<PocStatus>` 改为 `PocStatus`。
- 2026-06-10 已用 `scripts/run_mvp01_route_probe_verify.sh blocking-default` 在 `192.168.3.65:37805` 完成真实浏览器端到端 smoke：浏览器 WebView 正文返回 `https://httpbin.org/get` JSON，`vpn-tun` RX bytes 从 `464` 增长到 `324637`，浏览器 DNS 错误为 0，connect/disconnect crash 为 0。该结果证明系统浏览器真实流量已经形成 `VPN TUN -> mihomo gVisor TUN stack -> DNS hijack/fake-ip -> outbound protect -> 真实网络 -> 浏览器页面` 的闭环。

### 阶段 C：数据、目录和配置服务

预计：3-4 天。

任务：

- 新增 `MihomoLayout`。
- 新增 `Profile` 数据模型。
- 新增 ProfileService。
- 新增 ConfigService。
- 把 POC-05 的目录和写文件 helper 移到正式服务。
- 支持 local profile 和 subscription profile 元数据。

验收：

- 能保存默认 raw YAML。
- 能生成 runtime YAML。
- 能持久化 `profiles.json`。
- App 重启后仍能读取 active profile。
- active profile 可以在 local/subscription 之间切换。

状态：

- MVP-01A 已完成 local profile 路径。
- 已新增 `entry/src/main/ets/models/MvpTypes.ets` 和 `entry/src/main/ets/config/ConfigService.ets`。
- 当前目录为 `context.filesDir + "/mihomo"`，包含 `home/`、`profiles/`、`run/`、`cache/`、`geo/`、`logs/`、`state/`。
- 已支持默认 profile、raw YAML 保存、runtime YAML 生成和 `profiles.json` 持久化。
- subscription profile 的完整创建和切换留到阶段 G。

### 阶段 D：RuntimeStore 和状态机

预计：2-3 天。

任务：

- 新增 RuntimeSnapshot。
- 新增 RuntimeStore。
- 状态迁移方法集中化。
- 最近事件列表持久化。
- UI 读取 RuntimeStore，不再只使用页面局部状态。
- UI 恢复时执行 native/core 健康检查，不能只信任持久化 snapshot。

验收：

- 页面能显示真实 runtime state 或明确的 unknown/error。
- POC-06 状态迁移逻辑可复用。
- 重复点击不会产生多实例。

状态：

- MVP-01A 已完成。
- 已新增 `entry/src/main/ets/runtime/RuntimeStore.ets`，持久化 `RuntimeSnapshot` 和最近事件。
- UI 启动时如果发现旧状态为 `connected`、`starting` 或 `stopping`，会降级为 `unknown`，避免只凭 `runtime.json` 误显示 connected。
- 真机 smoke 中已验证旧 `Stopping` 状态重启后会降级为 `Unknown`，并可通过产品 disconnect 命令恢复到 `Idle`。

### 阶段 E：VpnRuntime/CoreRuntime 产品路径

预计：4-6 天。

任务：

- 从 `MihomoPocVpnAbility` 抽出 VpnRuntime。
- 从 POC-04/05/06 抽出 CoreRuntime。
- 产品 connect 走 `command=connect`。
- 产品 disconnect 走 `command=disconnect`。
- POC runner 保留原入口。
- 产品路径不引用 POC 常量。

验收：

- UI connect 可以启动 VPN 和 mihomo。
- UI disconnect 可以 stop mihomo 并 destroy VPN。
- POC-05/06 回归仍通过。

状态：

- MVP-01A 产品路径已接入到 `MihomoPocVpnAbility.ets`。
- `command=connect` 会创建 VPN/TUN、注册 protect callback、加载 `libmihomo_ohos.so`，并调用 `startMihomoConfigFile(homeDir, runtimePath)`。
- `command=disconnect` 会在运行中的 VPN Extension `onRequest` 内执行 `stopMihomo()`、destroy VPN，并写回 `Idle/Stopped`。
- 真机 smoke 中曾发现 `stopVpnExtensionAbility()` 进入 `onDestroy` 后异步清理不能可靠写回 `idle`，已修正为产品 disconnect command。
- POC runner 入口仍保留。2026-06-08 已运行 `scripts/run_poc_regression.sh`，默认 POC-05/POC-06 均通过。

### 阶段 F：首页 MVP-01A UI

预计：3-4 天。

任务：

- 重做 `Index.ets` 首页。
- 增加连接状态区域。
- 增加 active profile 区域。
- 增加 YAML 输入/保存/校验入口。
- 增加连接/断开按钮。
- 增加最近事件列表。
- 保留诊断区域入口。

验收：

- 用户不用命令行也能完成保存配置、连接、断开。
- 按钮 disabled 状态符合状态机。
- 错误能显示在首页。

状态：

- 已完成第一版。
- `entry/src/main/ets/pages/Index.ets` 已改为 MVP-01A 首页。
- 首页支持状态、core 状态、active profile、本地 YAML 编辑、保存、校验、Connect/Disconnect、runtime event 列表。
- POC 自测按钮已不再作为首页主流程展示；POC 仍通过 Want 参数触发。

### 阶段 G：最小订阅更新器和订阅 UI

预计：2-4 天。

任务：

- 增加订阅 URL 输入、添加订阅和刷新订阅入口。
- 新增 SubscriptionService。
- 实现订阅 URL 校验。
- 实现 HTTP/HTTPS GET。
- 实现 timeout、maxBytes、基础重定向限制。
- 实现下载临时文件、校验、runtime 生成、原子替换。
- 实现失败回滚：失败时保留上一次可用 raw/runtime 文件。
- 实现 `profiles.json` 中订阅元数据更新。
- 增加订阅最近刷新时间、HTTP 状态码、错误摘要。

验收：

- 用户不用命令行也能添加和刷新订阅。
- 订阅刷新成功后 raw/runtime 文件更新。
- 4xx/5xx/超时/超大响应会显示明确错误。
- 下载失败后仍可使用上一次成功配置连接。
- 订阅 URL query 不完整打印到日志。

状态：

- 已完成代码实现（2026-06-09，MVP-01B 第二轮）。
- 新增 `entry/src/main/ets/subscription/SubscriptionService.ets`：HTTP/HTTPS GET、最多 5 次重定向、15s 超时、5 MiB 上限、UTF-8 校验、临时文件写入、原子 rename、失败回滚。
- `ConfigService` 增加 `createSubscriptionProfile()`、`setActiveProfile()`、`listProfiles()`，profiles.json 已支持 subscription profile 元数据（`SubscriptionMeta`：url、lastFetchedAt、lastSuccessAt、lastStatusCode、lastBytes、failureCount、lastError）。
- `Index.ets` 已增加订阅 URL 输入框、Add Sub / Refresh 按钮、订阅状态展示、横向 profile 切换器。
- 错误码：`SUBSCRIPTION_INVALID_URL` / `UNSUPPORTED_SCHEME` / `REDIRECT_LOOP` / `HTTP_ERROR` / `TOO_LARGE` / `EMPTY_BODY` / `DECODE_FAILED` / `CONFIG_INVALID` / `WRITE_FAILED`。
- 真机订阅刷新 smoke 已完成（2026-06-10）：订阅 HTTP 200，raw/runtime 原子写入，active profile 切换成功。后续发现 `generateRuntimeYaml()` 早期实现只保留 `mode`，把订阅里的 `proxies`、`proxy-groups`、`rules` 丢弃为 `MATCH,DIRECT`，导致订阅连接后实际仍走 DIRECT。已修复为保留这三个顶层块，同时继续覆盖 DNS/TUN/端口等移动端安全 runtime 字段。

### 阶段 H：错误处理和恢复

预计：2-3 天。

任务：

- 统一 RuntimeError。
- 配置错误展示。
- core start 失败展示。
- stop 失败展示。
- busy 状态展示。
- destroy 清理失败展示。

验收：

- 非法 YAML 不会卡住 UI。
- 订阅下载失败不会破坏旧配置。
- 启动失败后可以再次连接。
- 重复点击不会产生多个 VPN/core。

### 阶段 I：真实流量验证

预计：3-7 天。

任务：

- 准备一个真实可用 mihomo 本地配置和一个真实可用订阅配置。
- 验证订阅刷新后生成的 runtime YAML 可启动。
- 验证浏览器流量是否进入 VPN。
- 验证 protect 后出站不回环。
- 验证 DNS 行为。
- 验证断开后系统网络恢复。

验收：

- 浏览器可访问测试网站。
- 订阅配置和本地配置至少各完成一次连接/断开 smoke。
- 断开后网络恢复。
- hilog 没有 protect loop 或 native crash。

### 阶段 J：回归脚本和文档

预计：1-2 天。

任务：

- 编写 `scripts/run_poc_regression.sh`。
- 编写 `scripts/run_mvp01_smoke.sh`。
- 编写或记录订阅刷新 smoke 命令/步骤。
- 更新产品文档。
- 记录 Mate 80/API 24 真机结论。

验收：

- 一条命令能跑 smoke。
- 文档记录 MVP-01 通过标准和已知限制。

状态：

- 已新增 `scripts/run_mvp01_smoke.sh`。
- 已新增 `scripts/run_poc_regression.sh`。
- 已新增 `scripts/run_mvp01_special_smoke.sh`。
- 2026-06-08 已运行 `scripts/run_mvp01_smoke.sh`，结果为 `MVP-01A smoke PASS`。
- 2026-06-08 已运行 `scripts/run_poc_regression.sh`，默认 POC-05/POC-06 均通过，结果为 `POC regression PASS`。
- 2026-06-08 已运行 `POC_DEVICE_TARGET=192.168.3.65:37805 scripts/run_mvp01_special_smoke.sh`，结果为 `MVP-01A special smoke PASS`。
- 当前 smoke 脚本覆盖安装、启动首页、重置 idle、Connect、Disconnect、UI 状态断言、关键 hilog 断言和 crash 信号检查。
- 专项 smoke 已覆盖非法 YAML 不启动 core、重复 Connect/Disconnect 不产生异常、UI force-stop 后降级为 `Unknown` 并可恢复到 `Idle`。

## 16. MVP-01 验收标准

MVP-01 验收分为 MVP-01A 和 MVP-01B。MVP-01A 通过只代表控制面可用，不代表真实代理流量已接管。MVP-01B 通过后，才可以称为 MVP-01 完整完成。

### 16.0 MVP-01A 真机 smoke 记录

验证环境：

```text
日期：2026-06-08
设备：Mate 80
系统：HarmonyOS 6.1.1 / API 24
HAP：entry/build/default/outputs/default/entry-default-signed.hap
```

构建和安装：

- `assembleHap --no-daemon` 构建成功。
- HAP 安装成功，日志显示 `install bundle successfully`。
- 首页启动成功，日志显示 `Succeeded in loading the content`。

Connect 验证：

- UI 点击 Connect 后，页面显示 `Connected / Running`。
- `MihomoPocVpnAbility` 收到 `command=connect`。
- VPN/TUN 创建成功：日志包含 `product tunFd created fd=`。
- protect callback 注册成功：`protect callback registered`。
- `libmihomo_ohos.so` 加载成功：`mihomo core loaded`。
- runtime YAML 通过带 fd 的产品入口启动成功：`MVP-01B MihomoOhosStartConfigFileWithTunFd returned code=0 tunFd=`，且 fd 与 VPN 创建日志一致。
- 状态进入 connected：`POC-06 state starting -> connected reason=product connect ok`。

Disconnect 验证：

- UI 点击 Disconnect 后，`MihomoPocVpnAbility` 收到 `command=disconnect`。
- 当前产品路径跳过 `stopMihomo()`：日志包含 `MVP-01A stop skipped on destroy`。原因是 `MihomoOhosStop()` c-shared bridge 在 fd-backed TUN 真机场景仍会触发 native crash。
- VPN destroy 成功：`vpn destroyed fd=30`。
- 状态回到 idle：`POC-06 state stopping -> idle reason=destroyVpn complete fd=30`。
- UI 最终显示 `Idle / Stopped`，Connect enabled，Disconnect disabled。

本轮发现并修复：

- 原实现用 `stopVpnExtensionAbility()` 触发断开。真机上该路径进入 `onDestroy`，异步 `destroyVpn()` 不能可靠写回 RuntimeStore，页面会卡在 `Stopping`。
- 已改为 UI 发送 `command=disconnect`，由运行中的 VPN Extension 在 `onRequest` 内执行 stop/destroy 并写回 `Idle/Stopped`。

本轮未发现：

- 未发现 `DfxFaultLogger`。
- 未发现 `Ability on scheduler died`。
- 未发现 `On ability died`。
- 未发现 native crash。

脚本化复测：

- 2026-06-08 新增并运行 `scripts/run_mvp01_smoke.sh`。
- 脚本结果：`MVP-01A smoke PASS`。
- 输出日志目录：`/private/tmp/mvp01-smoke`。
- 覆盖内容：安装 HAP、启动首页、产品 disconnect 重置 idle、产品 connect、产品 disconnect、UI 布局断言、带 `tunFd` 的 native 启动入口断言、关键 hilog 断言、崩溃信号检查。
- 2026-06-08 新增并运行 `scripts/run_mvp01_special_smoke.sh`。
- 脚本结果：`MVP-01A special smoke PASS`。
- 执行目标：`POC_DEVICE_TARGET=192.168.3.65:37805`。
- 输出日志目录：`/private/tmp/mvp01-special-smoke`。
- 覆盖内容：非法 YAML 不进入 connected、不创建 product TUN fd、不启动 mihomo core；恢复默认配置后可回到 `Idle / Stopped`；重复 Connect 保持 `Connected / Running` 且无 crash；重复 Disconnect 保持 `Idle / Stopped`；force-stop 后 UI 恢复为 `Unknown` 并提示 `runtime state needs verification`，再执行 Disconnect 可恢复到 `Idle / Stopped`。
- 2026-06-08 已在 MVP-01B fd-backed TUN 接入后重跑：
  - `bash scripts/build_poc04_mihomo_core.sh`：通过。
  - `assembleHap --no-daemon`：通过。
  - `POC_DEVICE_TARGET=192.168.3.65:37805 bash scripts/run_mvp01_smoke.sh`：`MVP-01A smoke PASS`。
  - `POC_DEVICE_TARGET=192.168.3.65:37805 bash scripts/run_mvp01_special_smoke.sh`：`MVP-01A special smoke PASS`。
  - `POC_DEVICE_TARGET=192.168.3.65:37805 bash scripts/run_poc_regression.sh`：`POC-05 PASS`、`POC-06 PASS`、`POC regression PASS`。
  - 本轮修复前曾在 `MihomoOhosStop()` 关闭 fd-backed TUN 时触发 `DfxFaultLogger` / `SIGSEGV`；修复后上述 smoke 和回归未再出现 native crash。
- 2026-06-08 已尝试真实浏览器访问 smoke：
  - 命令路径：连接 MVP-01A 后，通过 `aa start -A ohos.want.action.viewData -U https://connectivitycheck.platform.hicloud.com/generate_204` 启动系统浏览器。
  - 结果：浏览器日志显示 `vpnEnabled:1`，但请求超时，错误集中在 `dnsServerReturnNothing` / `Timeout was reached`。
  - 结论：系统浏览器流量已受 VPN 影响，但 DNS/真实 outbound protect 仍未闭环，MVP-01B 未通过。
  - 直接把 NAPI protect callback 接到 mihomo `dialer.DefaultSocketHook` 的尝试会导致 `MihomoOhosStop()` 阶段 native crash；已回退 hook 激活路径，并重新验证 `run_mvp01_smoke.sh`、`run_mvp01_special_smoke.sh`、`run_poc_regression.sh` 均通过。
- 2026-06-09 已新增并运行 `scripts/run_mvp01_route_probe_verify.sh`：
  - `MVP_ROUTE_MODE=split-default`：`netstat -rn` 只显示 `10.7.0.0/24 -> vpn-tun`，浏览器仍 `ERR_NAME_NOT_RESOLVED`，`vpn-tun` RX 为 0。
  - `MVP_ROUTE_MODE=default`：结果同上，单条 `0.0.0.0/0` 未出现在路由表。
  - `MVP_ROUTE_MODE=default MVP_ROUTE_INTERFACE=none`：结果同上，排除 `RouteInfo.interface='vpn-tun'` 字段导致默认路由被忽略的假设。
  - readiness probe 能从 TUN fd 读到 3 个样本，说明 fd 可读；但样本与浏览器访问没有形成有效 DNS/HTTP 数据面闭环。
  - 输出日志目录：`/private/tmp/mvp01-route-probe-split`、`/private/tmp/mvp01-route-probe-default`、`/private/tmp/mvp01-route-probe-default-ifnone`。
- 2026-06-09 标准 smoke 复测通过：
  - `POC_DEVICE_TARGET=192.168.50.153:37805 bash scripts/run_mvp01_smoke.sh`：`MVP-01A smoke PASS`。
  - 输出日志目录：`/private/tmp/mvp01-smoke-route-diag-final`。

### 16.1 构建

- HAP 构建成功。
- NAPI 编译成功。
- `libmihomo_ohos.so` 和 `libpoc_go_core.so` 都打入 HAP。

状态：MVP-01A 已通过。

### 16.2 配置

- raw YAML 可保存。
- runtime YAML 可生成。
- 不支持字段会显示明确错误。
- App 重启后 active profile 不丢失。

状态：MVP-01A local profile 已通过基础 smoke；subscription profile 留到 MVP-01B 阶段 G。

### 16.3 MVP-01A 连接

- UI 点击连接后进入 `starting`。
- VPN Extension 创建 TUN 成功。
- mihomo start config file 成功。
- 状态进入 `connected`。
- UI 恢复状态时不能只凭 `runtime.json` 显示 connected，必须完成 native/core 健康检查或降级到 unknown/error。

状态：MVP-01A 已通过。当前实现是 UI 恢复时降级到 `unknown`，尚未实现 native `getRuntimeState`。

### 16.4 MVP-01A 断开

- UI 点击断开后进入 `stopping`。
- `stopMihomo()` 成功。
- VPN destroy 成功。
- 状态进入 `idle`。
- 系统网络恢复。

状态：MVP-01A 已通过控制面 smoke。系统网络恢复以 VPN destroy 和设备网络状态无异常为准，未做浏览器访问验证。

### 16.5 异常

- 配置错误不会启动 core。
- core start 失败后能再次连接。
- 重复点击 connect 被拒绝或合并。
- 重复点击 disconnect 被拒绝或合并。
- 不出现 native crash。

状态：MVP-01A 已通过专项 smoke。非法 YAML、重复 connect、重复 disconnect、force-stop 恢复均已脚本覆盖；本轮未发现 `DfxFaultLogger`、Ability died 或 native crash。真实 native crash/panic 自动恢复不属于 MVP-01A 当前范围。

### 16.6 MVP-01B 最小订阅更新

- UI 可以添加 HTTP/HTTPS 订阅 URL。
- 手动刷新成功后更新 raw YAML 和 runtime YAML。
- timeout、4xx、5xx、超过 maxBytes、重定向过多都会显示明确错误。
- 刷新失败不会破坏上一次可用 raw/runtime 文件。
- 订阅 URL 的 query/token 不完整打印到 hilog 或 UI 日志。
- 自动刷新、ETag、Last-Modified 和 304 缓存语义不作为 MVP-01B 验收要求。

状态：

- 代码实现完成。`SubscriptionService.ets` + `ConfigService.createSubscriptionProfile/setActiveProfile/listProfiles` + 首页订阅 UI 已合入。
- 真机端到端订阅刷新 smoke 待补（需要可访问的测试订阅 URL）。

### 16.7 MVP-01B 真实流量

- 已明确真实浏览器流量从系统 VPN 到 mihomo outbound 的完整路径。
- protect callback 在真实 outbound 中生效，不只是在 POC socket test 中生效。
- 浏览器可访问测试网站。
- 订阅配置和本地配置至少各完成一次连接/断开 smoke。
- 断开后系统网络恢复。
- hilog 没有 protect loop 或 native crash。

状态：

- 本地配置和订阅配置真实浏览器链路均已通过。
- 2026-06-09 第一轮真机探测：浏览器日志处于 `vpnEnabled:1` 且系统选择 `vpn-tun`；`vpn-tun` TX > 0 但 RX = 0，浏览器报 `dnsServerReturnNothing` / `Timeout was reached`。
- 2026-06-09 第二轮已完成代码修复（详见第 15 节 "MVP-01B 第二轮修复"），包含五项关键改动：
  1. `enableProtectHookLocked` 真正激活 hook（之前硬编码禁用，是 RX = 0 的根因）。
  2. NAPI enable/disable/isRunning/gracefulStop 改为同步调用，规避 OpenHarmony Go runtime TLS 跨线程 cgo 风险。
  3. 新增 `MihomoOhosGracefulStop` + `hub.Parse(stoppedConfig)`，让 mihomo 自己排空 TUN goroutine 后再 destroy。
  4. `tun.dns-hijack` 改为 mihomo 规范语法 `any:53`，并在 `injectTunFd` 自动补全 DNS 块。
  5. `parseProductVpnOptions` 路由模式白名单 bug 修复，7 种模式真正可切换。
- 2026-06-10 真机端到端 smoke 已通过：
  - 命令：`POC_DEVICE_TARGET=192.168.3.65:37805 MVP_ROUTE_PROBE_TMP_DIR=/private/tmp/mvp01-route-probe-issue5-rerun bash scripts/run_mvp01_route_probe_verify.sh blocking-default`
  - 结果：`blocking-default: PASS (rxDelta=480 txDelta=446 vpnLog=5 samples=2 errors=0 page=1 crash=0)`；脚本随后已修正为读取 `RX bytes/TX bytes`，按同一产物计算为 `RX bytes 464 -> 324637`、`TX bytes 464 -> 92116`。
  - 页面级断言：`browser-web-text.txt` 中包含 `httpbin.org/get` 返回的 JSON（`headers`、`origin`、`url`、`User-Agent`），不是只依赖 browser hilog 的 `statusCode: 200`。
  - 产物目录：`/private/tmp/mvp01-route-probe-issue5-rerun/blocking-default/`，包含 `browser-layout.json`、`browser-layout-text.txt`、`browser-web-text.txt`、`browser-screen.png`。
  - 稳定性：浏览器 DNS 错误为 0，connect crash 为 0，disconnect crash 为 0。
- 2026-06-10 订阅配置真实流量 smoke 已通过：
  - 新增 `mvpCommand=prepareSubscription` 自动化入口：添加订阅、刷新订阅、切换 active profile；日志中的订阅 URL 只保留 origin，避免 path/query token 泄露。
  - 订阅服务默认 `User-Agent` 改为 `ClashX Pro/1.118.0`。本轮验证发现默认 UA 会被订阅服务端返回 HTTP 403，ClashX/Clash Verge UA 可正常返回 200。
  - `scripts/run_mvp01_subscription_route_probe.sh` 自动安装 HAP、准备订阅 profile、提取 profileId，再调用 `run_mvp01_route_probe_verify.sh` 对该订阅 profile 跑真实浏览器链路。
  - `run_mvp01_route_probe_verify.sh` 支持 `MVP_PROFILE_ID` 和 `MVP_SKIP_DEFAULT_CONFIG=true`，避免订阅 smoke 被 `setDefaultConfig` 重置回本地默认 profile。
  - 浏览器启动方式改为优先 `aa start -A ohos.want.action.viewData -U <url>`，修复直接启动 `com.huawei.hmos.browser/MainAbility -U` 时偶发 `LoadUrl message:invalidUrl` 并停在浏览器首页的问题。
  - 命令：`POC_DEVICE_TARGET=192.168.3.65:37805 MVP_SUBSCRIPTION_URL=<redacted> MVP_SUBSCRIPTION_PROBE_TMP_DIR=/private/tmp/mvp01-subscription-route-probe-browserfix bash scripts/run_mvp01_subscription_route_probe.sh`
  - 订阅刷新结果：`status=200 bytes=29582`，active profile `sub-mq879w08-7ib`。
  - 真实流量结果：`blocking-default: PASS (rxDelta=624456 txDelta=90764 vpnLog=5 samples=1 errors=0 page=1 crash=0)`；WebView 正文命中 `httpbin.org/get` JSON，浏览器 DNS 错误为 0，connect/disconnect crash 为 0。
  - 产物目录：`/private/tmp/mvp01-subscription-route-probe-browserfix/`。
- 2026-06-10 `https://www.google.com.hk` 访问问题定位和修复：
  - 根因：`ConfigService.generateRuntimeYaml()` 早期实现只提取 raw YAML 的 `mode`，然后写入固定 runtime 模板，导致订阅里的 `proxies`、`proxy-groups`、`rules` 被替换成空代理和 `MATCH,DIRECT`。因此订阅 profile 虽然能连接、httpbin 能打开，但没有真正按订阅规则走代理，访问 Google 时仍可能失败。
  - 修复：`generateRuntimeYaml()` 现在保留 raw YAML 中的 `proxies`、`proxy-groups`、`rules` 顶层块，并继续覆盖移动端敏感字段（DNS/TUN/端口等）。
  - 验证命令：`POC_DEVICE_TARGET=192.168.3.65:37805 MVP_SUBSCRIPTION_URL=<redacted> MVP_SUBSCRIPTION_PROBE_TMP_DIR=/private/tmp/mvp01-subscription-google-probe MVP_BROWSER_URL=https://www.google.com.hk MVP_BROWSER_PAGE_ASSERT_REGEX='Google|google.com.hk|Google 搜索|Google Search' bash scripts/run_mvp01_subscription_route_probe.sh`
  - 验证结果：`blocking-default: PASS (rxDelta=770318 txDelta=117498 vpnLog=4 samples=1 errors=0 page=1 crash=0)`；WebView 正文命中 Google 页面文本，浏览器 DNS 错误为 0，connect/disconnect crash 为 0。
  - 产物目录：`/private/tmp/mvp01-subscription-google-probe/`。

### 16.8 回归

- POC-03 通过。
- POC-04 通过。
- POC-05 通过。
- POC-06 通过。
- MVP-01 smoke 通过。

状态：

- 2026-06-08 已新增并运行 `scripts/run_poc_regression.sh`。
- 默认回归项：POC-05、POC-06。
- 结果：`POC-05 PASS`、`POC-06 PASS`、`POC regression PASS`。
- 输出日志目录：`/private/tmp/poc-regression`。
- POC-03/POC-04 未在本轮脚本默认项中重跑，仍沿用此前真机通过记录。

### MVP-01B 第二轮新增脚本

路由模式多选探测（验证 7 种路由模式在真机上的路由表/RX 表现）：

```bash
# 默认测试 5 种 blocking 模式
POC_DEVICE_TARGET=192.168.50.153:37805 bash scripts/run_mvp01_route_probe_verify.sh

# 也可显式列出模式
POC_DEVICE_TARGET=192.168.50.153:37805 bash scripts/run_mvp01_route_probe_verify.sh \
  blocking-empty blocking-split no-routes
```

输出日志目录：`/private/tmp/mvp01-route-probe/<mode>/`。

2026-06-10 有效修改：

- `scripts/run_mvp01_route_probe_verify.sh` 的浏览器验证从只依赖 browser hilog 升级为页面级断言。
- 新增 `uitest dumpLayout -b com.huawei.hmos.browser` 采集浏览器 UI 树，并把文本拆成完整 UI 文本和 WebView 正文文本。
- PASS 只使用 `browser-web-text.txt` 做页面成功断言，避免地址栏 URL 或浏览器 chrome 文本造成假阳性。
- 新增 `uitest screenCap` / `snapshot_display` 截图采集，保留浏览器可视证据。
- 新增页面 dump 重试：页面未渲染完成时会重新 dump，直到 WebView 正文命中断言或达到重试上限。
- PASS 判定改为真实数据面条件：浏览器无 DNS 错误、`vpn-tun` RX bytes 增长、WebView 正文命中断言、connect/disconnect 无 crash；`vpnEnabled` hilog 保留为辅助诊断，不再作为唯一通过条件。
- 支持指定 profile：`MVP_PROFILE_ID=<profileId>`；支持跳过默认配置重置：`MVP_SKIP_DEFAULT_CONFIG=true`。
- 浏览器打开测试 URL 优先使用 `aa start -A ohos.want.action.viewData -U <url>`，比直接启动浏览器 `MainAbility -U` 更稳定。

订阅配置真实流量脚本：

```bash
POC_DEVICE_TARGET=192.168.3.65:37805 \
MVP_SUBSCRIPTION_URL='<subscription-url>' \
bash scripts/run_mvp01_subscription_route_probe.sh
```

脚本会自动执行：安装 HAP → `prepareSubscription` → 提取订阅 profileId → 用订阅 profile 执行 `blocking-default` 真实浏览器 smoke。

每个模式自动采集 `ifconfig vpn-tun` 前后对比、`netstat -rn`、应用 hilog（含 `createPocConfig`、TUN readiness、`MVP-01B`）、浏览器 hilog（`vpnEnabled`、`tryDns`、`ERR_NAME_NOT_RESOLVED`）、浏览器 UI 树和截图。PASS 判定必须同时满足浏览器无 DNS 错误、`vpn-tun` RX 字节在浏览器访问后增长、WebView 正文命中 `MVP_BROWSER_PAGE_ASSERT_REGEX`、无 crash；`vpnEnabled` hilog 只作为辅助诊断信号。默认断言只检查 WebView 页面正文，不把地址栏 URL 当成页面成功。

页面级验证产物：

- `browser-layout.json`：完整浏览器 UI 树。
- `browser-layout-text.txt`：完整 UI 文本，含地址栏，供排错使用。
- `browser-web-text.txt`：WebView 正文文本，PASS 只使用该文件做页面成功断言。
- `browser-screen.png`：浏览器截图。

## 17. 真机验证命令

构建：

```bash
HOME=/private/tmp/codex-hvigor-home \
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  --mode module -p module=entry@default -p product=default -p buildMode=debug \
  assembleHap --no-daemon
```

安装：

```bash
source scripts/huawei_tools_env.sh
"$HDC" -t "$POC_DEVICE_TARGET" install -r "$POC_ENTRY_HAP"
```

POC 回归：

```bash
"$HDC" -t "$POC_DEVICE_TARGET" shell hilog -r
"$HDC" -t "$POC_DEVICE_TARGET" shell aa start \
  -b "$POC_BUNDLE_NAME" -a "$POC_ENTRY_ABILITY" --ps poc POC-06
sleep 24
"$HDC" -t "$POC_DEVICE_TARGET" shell hilog -x | \
  grep -E 'MihomoPocEntry|MihomoPocVpn|MihomoPocNapi|POC-06|DfxFaultLogger|Ability on scheduler died|On ability died'
```

MVP smoke 建议日志过滤：

```bash
grep -E 'MihomoRuntime|MihomoVpn|MihomoCore|MihomoPoc|DfxFaultLogger|Ability on scheduler died|On ability died'
```

MVP-01A smoke：

```bash
scripts/run_mvp01_smoke.sh
```

POC-05/06 回归：

```bash
scripts/run_poc_regression.sh
```

指定 POC 回归：

```bash
scripts/run_poc_regression.sh POC-05
scripts/run_poc_regression.sh POC-06
```

## 18. 风险和应对

### 18.1 真实浏览器流量 smoke 状态

风险：

- 已在本地默认配置和订阅配置下分别完成 `blocking-default` 真实浏览器端到端 smoke，证明 fd-backed TUN adapter、DNS hijack/fake-ip、protect hook、订阅刷新/激活和 graceful stop 的主链路已经闭环。
- 剩余风险是覆盖面和稳定性：其他路由模式仍可按需补测，长时间运行/多次连接断开仍需后续 soak。

应对：

- 已完成验证记录：
  1. 本地默认 profile：`blocking-default: PASS`，WebView 正文命中 `httpbin.org/get` JSON，`vpn-tun` RX bytes 从 `464` 增长到 `324637`，浏览器 DNS 错误为 0，connect/disconnect crash 为 0。
  2. 订阅 profile：订阅刷新 `status=200 bytes=29582`，`blocking-default: PASS (rxDelta=624456 txDelta=90764 vpnLog=5 samples=1 errors=0 page=1 crash=0)`。
- 下一步可补 `blocking-empty` / `blocking-split` / `no-routes` / `exclude-local` 的覆盖测试，或做 10-30 分钟长时间浏览/多次 connect-disconnect soak。

### 18.1.1 OpenHarmony Go runtime cgo 跨线程风险

风险：

- POC-02 阶段已知 OpenHarmony arm64 Go runtime 的 TLS 处理需要补丁（`runtime.tls_g` 改为 offset variable）。
- 实践中发现 NAPI async work 从不同 worker 线程进入 cgo 容易触发 SIGSEGV，定位困难。

应对：

- MVP-01B 第二轮已将所有控制类 cgo 入口（`enableProtectHook` / `disableProtectHook` / `isMihomoRunning` / `gracefulStopMihomo`）改为同步 NAPI 调用，在 JS 主线程执行，保持 cgo 调用线程一致性。
- 仅 `loadMihomoCore` / `startMihomoConfigFile*` / `stopMihomo` / `pingMihomo` / `getMihomoVersion` 等耗时较大的入口仍保留 async work；这些路径在产品 connect 时只调用一次，cgo 入口次数有限。
- 后续若发现新的 cgo crash，优先考虑统一切换为同步 NAPI 或绑定到单一专用线程。

### 18.2 YAML 转换能力不足

风险：

- ArkTS 文本处理无法可靠转换复杂订阅。

应对：

- MVP-01B 支持最小订阅下载、手动刷新、原子写入和失败回滚链路。
- 完整 HTTP 缓存、自动刷新、ETag、Last-Modified、304 语义进入 MVP-02。
- YAML parse/validate/transform 第一版保持保守，只做移动端必要字段覆盖和已知不支持字段拦截。
- 如果 ArkTS 文本处理无法可靠处理真实订阅，复杂 parse/validate/transform 下沉到 Go bridge。

### 18.3 UI 状态与 VPN Extension 状态不同步

风险：

- UI Ability 被回收后状态丢失。

应对：

- RuntimeStore 持久化最后 snapshot。
- UI 每次启动主动拉取 snapshot。
- 后续引入事件订阅或 common event。

### 18.4 后台和网络切换

风险：

- 系统后台限制和网络切换可能导致 core 状态不一致。

应对：

- MVP-01 只承诺基础连接和断开。
- 网络切换进入 MVP-02 稳定性专项。

## 19. 交付物

MVP-01A 完成时必须交付：

- ArkTS runtime/profile/config 服务。
- 产品化 connect/disconnect 路径。
- 最小首页 UI。
- 本地配置的保存、切换、raw/runtime YAML 生成。
- 状态机和错误展示。
- POC 回归脚本。
- MVP smoke 脚本。
- 真机验证记录。
- 已知限制清单。

MVP-01B 完成时必须补交付：

- SubscriptionService 和订阅元数据持久化。
- 订阅配置的保存、切换、raw/runtime YAML 生成。
- 订阅 raw/runtime 原子更新和刷新失败回滚。
- TUN/core 流量路径实现或明确可运行方案；当前已完成 `tunFd` 参数贯通和 fd-backed mihomo TUN adapter 接入，仍需完成浏览器真实流量 smoke。
- 本地配置和订阅配置的真实流量 smoke 记录。

## 20. 推荐实施顺序

```text
1. 新建数据模型和目录服务
2. 抽出 ConfigService
3. 前置确认 TUN/core 流量路径
4. 抽出 RuntimeStore
5. 抽出 VpnRuntime/CoreRuntime
6. 接入产品 command=connect/disconnect
7. 重做首页并完成本地配置控制面闭环
8. 实现最小 SubscriptionService 和订阅 UI
9. 接入错误展示和订阅刷新状态
10. 跑 POC-05/06 回归
11. 做本地配置和订阅配置真实流量 smoke
12. 写 MVP-01 验证结论
```

## 21. MVP-01 完成定义

MVP-01A 只有同时满足以下条件才算完成：

- 用户可以在 UI 保存一个配置。
- 用户可以在 UI 点击连接。
- App 状态进入 connected。
- 用户可以点击断开。
- App 状态回到 idle。
- 断开后系统网络恢复。
- App 重启后配置仍存在。
- POC-03 到 POC-06 回归仍通过。
- 真机 hilog 无 native crash。

MVP-01B 只有在 MVP-01A 已通过，并同时满足以下条件时才算完成：

- 用户可以在 UI 添加订阅 URL。
- 用户可以在 UI 手动刷新订阅成功。
- 订阅刷新失败不会破坏旧的可用配置。
- 用户可以在系统浏览器完成一次真实网络访问验证。
- 本地配置和订阅配置至少各完成一次真实流量 connect/disconnect smoke。
- 已记录 TUN/core 流量路径方案、已知限制和后续稳定性工作。
