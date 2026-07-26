import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { picker } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { scanBarcode } from '@kit.ScanKit';
import fs from '@ohos.file.fs';
import pasteboard from '@ohos.pasteboard';
import { ConfigService } from '../config/ConfigService';
import { ConfigValidationService } from '../config/ConfigValidationService';
import {
  AppSettings,
  ConfigValidationResult,
  DEFAULT_APP_SETTINGS,
  DnsMode,
  LogLevel,
  Profile,
  ProxyGroup,
  ProxyLatencyRecord,
  ProxyLatencyState,
  ProxyMode,
  ProxyNode,
  ProxySelectionRequestState,
  RuntimeEvent,
  RuntimeEventLevel,
  RuntimeSnapshot,
  TrafficStatsSource,
  VpnRouteMode
} from '../models/MvpTypes';
import { RuntimeStore } from '../runtime/RuntimeStore';
import { TrafficStatsService } from '../runtime/TrafficStatsService';
import { SettingsService } from '../settings/SettingsService';
import { SubscriptionService } from '../subscription/SubscriptionService';
import { UiRefreshBus } from '../runtime/UiRefreshBus';
import { VpnControlService } from '../runtime/VpnControlService';

const DOMAIN = 0x0001;
const TAG = 'MihomoMvpPage';
const MAX_IMPORT_FILE_BYTES = 5 * 1024 * 1024;
const IMPORT_READ_CHUNK_BYTES = 64 * 1024;

interface ImportedTextFile {
  name: string;
  content: string;
}

@Entry
@Component
struct Index {
  @State statusText: string = 'Idle';
  @State coreText: string = 'Stopped';
  @State activeProfileName: string = '未配置';
  @State activeProfileId: string = '';
  @State lastError: string = '';
  @State rawYaml: string = '';
  @State runtimeEvents: RuntimeEvent[] = [];
  @State busy: boolean = false;
  @State validationText: string = 'Ready';
  @State subUrl: string = '';
  @State subStatus: string = '';
  @State subBusy: boolean = false;
  @State profiles: Profile[] = [];
  @State selectedSectionIndex: number = 0;
  @State uploadSpeed: number = 0;
  @State downloadSpeed: number = 0;
  @State todayUploadBytes: number = 0;
  @State todayDownloadBytes: number = 0;
  @State trafficSource: TrafficStatsSource = 'none';
  @StorageLink('runtimeRefreshSignal') @Watch('onRuntimeRefreshSignalChanged')
  runtimeRefreshSignal: number = 0;
  @State nodes: ProxyNode[] = [];
  @State proxyGroups: ProxyGroup[] = [];
  @State selectedProxyGroupName: string = '';
  @State nodeSearchText: string = '';
  @State proxyDelayRecords: ProxyLatencyRecord[] = [];
  @State latencyBusy: boolean = false;
  @State sheetVisible: boolean = false;
  @State sheetProfileId: string = '';
  @State settingsSelector: string = '';
  @State createMode: number = 1;
  @State newProfileName: string = '新配置';
  @State editProfileId: string = '';
  @State rootWidth: number = 390;
  @State appSettings: AppSettings = DEFAULT_APP_SETTINGS;
  @State logLevelFilter: string = 'all';
  @State logSearchText: string = '';
  @State logFollow: boolean = true;
  @State diagnosticText: string = '';
  @State lastDiagnosticPath: string = '';
  @State renderTick: number = 0;

  private configService?: ConfigService;
  private configValidationService?: ConfigValidationService;
  private runtimeStore?: RuntimeStore;
  private vpnControlService?: VpnControlService;
  private subscriptionService?: SubscriptionService;
  private settingsService?: SettingsService;
  private uiContext?: common.UIAbilityContext;
  private runtimeRefreshHandler?: () => void;
  private runtimeRefreshBusHandler?: (timestamp: number) => void;
  private logsScroller: Scroller = new Scroller();
  private followedLogEventKey: string = '';
  private pollTimer: number = -1;
  private profileRefreshTick: number = 0;
  private loadedYamlProfileId: string = '';
  private sectionHistory: number[] = [];

  aboutToAppear(): void {
    const context = getContext(this) as common.UIAbilityContext;
    this.uiContext = context;
    const filesDir = context.filesDir;
    this.configService = new ConfigService(filesDir);
    this.configValidationService = new ConfigValidationService(filesDir);
    this.runtimeStore = new RuntimeStore(filesDir);
    this.vpnControlService = new VpnControlService(filesDir, context);
    this.subscriptionService = new SubscriptionService(filesDir);
    this.settingsService = new SettingsService(filesDir);
    this.bindRuntimeRefreshEvent(context);
    this.bindRuntimeRefreshBus();
    const profile = this.configService.getActiveProfile();
    if (profile) {
      this.activeProfileId = profile.id;
      this.activeProfileName = profile.name;
      this.rawYaml = this.configService.loadRawYaml(profile.id);
      this.loadedYamlProfileId = profile.id;
    }
    this.loadSettings();
    this.reloadProfiles();
    this.markRestoredRuntimeUnknown();
    this.refreshDailyTraffic();
    this.refreshState(true);
    this.startRuntimePolling();
  }

  aboutToDisappear(): void {
    this.unbindRuntimeRefreshEvent();
    this.unbindRuntimeRefreshBus();
    this.stopRuntimePolling();
  }

  onPageShow(): void {
    this.refreshDailyTraffic();
    this.refreshRuntimeView(true);
    this.startRuntimePolling();
  }

  onPageHide(): void {
    // Keep the lightweight runtime poller alive while the page is hidden. On
    // real devices page-show callbacks are not always paired with every app
    // foreground transition, so stopping here can leave traffic tiles stale
    // after returning from another app.
  }

  onBackPress(): boolean {
    return this.navigateBack();
  }

  onRuntimeRefreshSignalChanged(): void {
    this.refreshRuntimeView(true);
    this.startRuntimePolling();
  }

  private bindRuntimeRefreshEvent(context: common.UIAbilityContext): void {
    if (this.runtimeRefreshHandler) {
      return;
    }
    this.runtimeRefreshHandler = () => {
      this.refreshRuntimeView(true);
      this.startRuntimePolling();
    };
    context.eventHub.on('runtimeRefresh', this.runtimeRefreshHandler);
  }

  private unbindRuntimeRefreshEvent(): void {
    if (!this.uiContext || !this.runtimeRefreshHandler) {
      return;
    }
    this.uiContext.eventHub.off('runtimeRefresh', this.runtimeRefreshHandler);
    this.runtimeRefreshHandler = undefined;
  }

  private bindRuntimeRefreshBus(): void {
    if (this.runtimeRefreshBusHandler) {
      return;
    }
    this.runtimeRefreshBusHandler = (_timestamp: number) => {
      this.refreshRuntimeView(true);
      this.startRuntimePolling();
    };
    UiRefreshBus.add(this.runtimeRefreshBusHandler);
  }

  private unbindRuntimeRefreshBus(): void {
    if (!this.runtimeRefreshBusHandler) {
      return;
    }
    UiRefreshBus.remove(this.runtimeRefreshBusHandler);
    this.runtimeRefreshBusHandler = undefined;
  }

  private startRuntimePolling(): void {
    if (this.pollTimer >= 0) {
      return;
    }
    this.pollTimer = setInterval(() => {
      this.refreshState(false);
    }, 1000);
  }

  private stopRuntimePolling(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private refreshRuntimeView(forceProfiles: boolean = false): void {
    this.refreshState(forceProfiles);
    this.renderTick = (this.renderTick + 1) % 1000000;
  }

  private reloadProfiles(): void {
    if (!this.configService) {
      return;
    }
    this.profiles = this.configService.listProfiles();
    const active = this.configService.getActiveProfile();
    if (!active) {
      this.activeProfileId = '';
      this.activeProfileName = '未配置';
      this.rawYaml = '';
      this.loadedYamlProfileId = '';
      this.proxyDelayRecords = this.configService.loadProxyLatencyState().records;
      this.proxyGroups = [];
      this.selectedProxyGroupName = '';
      this.nodes = [];
      return;
    }
    this.activeProfileId = active.id;
    this.activeProfileName = active.name;
    this.proxyDelayRecords = this.configService.loadProxyLatencyState().records;
    this.proxyGroups = this.withMeasuredDelays(this.configService.listProxyGroups(active.id), active.id);
    if (this.proxyGroups.length === 0) {
      this.selectedProxyGroupName = '';
      this.nodes = [];
      return;
    }
    if (this.selectedProxyGroupName.length === 0 || !this.hasProxyGroup(this.selectedProxyGroupName)) {
      this.selectedProxyGroupName = this.proxyGroups[0].name;
    }
    this.nodes = this.getSelectedProxyGroupNodes();
  }

  private loadSettings(): void {
    if (!this.settingsService) {
      return;
    }
    this.appSettings = this.settingsService.load();
  }

  private updateSettings(patch: Partial<AppSettings>): void {
    if (!this.settingsService) {
      return;
    }
    this.appSettings = this.settingsService.update(patch);
    this.validationText = '设置已保存';
    this.rebuildActiveRuntimeYaml();
    if (this.runtimeStore) {
      this.runtimeStore.appendEvent('Settings updated: route=' + this.appSettings.routeMode +
        ' mode=' + this.appSettings.proxyMode + ' dns=' + this.appSettings.dnsMode);
    }
    this.refreshState();
  }

  private rebuildActiveRuntimeYaml(): void {
    if (!this.configService) {
      return;
    }
    const profile = this.configService.getActiveProfile();
    if (!profile) {
      return;
    }
    const rawYaml = this.configService.loadRawYaml(profile.id);
    const validation = this.configService.validateRawYaml(rawYaml);
    if (!validation.ok) {
      this.validationText = validation.errors.join('; ');
      return;
    }
    this.configService.writeTextFile(profile.runtimePath,
      this.configService.generateRuntimeYaml(rawYaml, this.appSettings));
  }

  private refreshState(forceProfiles: boolean = false): void {
    if (!this.runtimeStore || !this.configService) {
      return;
    }
    try {
      const snapshot = this.runtimeStore.getSnapshot();
      this.applySnapshot(snapshot);
      const nextRuntimeEvents = this.runtimeStore.getRuntimeEvents();
      const latestLogEventKey = nextRuntimeEvents.length > 0 ?
        nextRuntimeEvents[0].timestamp.toString() + nextRuntimeEvents[0].message : '';
      const hasNewLogEvent = latestLogEventKey.length > 0 && latestLogEventKey !== this.followedLogEventKey;
      this.runtimeEvents = nextRuntimeEvents;
      this.profileRefreshTick++;
      if (forceProfiles || this.profileRefreshTick >= 6) {
        this.profileRefreshTick = 0;
        this.reloadProfiles();
      }
      if (this.selectedSectionIndex === 4 && this.logFollow && hasNewLogEvent) {
        this.logsScroller.scrollEdge(Edge.Top);
      }
      this.followedLogEventKey = latestLogEventKey;
    } catch (err) {
      this.lastError = this.toErrorText(err);
      hilog.error(DOMAIN, TAG, 'refreshState failed: %{public}s', this.lastError);
    }
  }

  private markRestoredRuntimeUnknown(): void {
    if (!this.runtimeStore) {
      return;
    }
    const snapshot = this.runtimeStore.getSnapshot();
    if (Date.now() - snapshot.updatedAt < 30000) {
      return;
    }
    if (snapshot.runtimeState === 'connected' || snapshot.runtimeState === 'starting' ||
      snapshot.runtimeState === 'stopping') {
      this.runtimeStore.update({
        runtimeState: 'unknown',
        coreState: 'unknown',
        lastEvent: 'UI restored; runtime state needs verification'
      });
      this.runtimeStore.appendEvent('UI restored; runtime state needs verification');
    }
  }

  private applySnapshot(snapshot: RuntimeSnapshot): void {
    this.statusText = this.toDisplayState(snapshot.runtimeState);
    this.coreText = this.toDisplayState(snapshot.coreState);
    this.lastError = snapshot.lastError;
    this.uploadSpeed = snapshot.uploadSpeed;
    this.downloadSpeed = snapshot.downloadSpeed;
    this.todayUploadBytes = snapshot.todayUploadBytes;
    this.todayDownloadBytes = snapshot.todayDownloadBytes;
    this.trafficSource = snapshot.trafficSource;
    if (this.lastError.length === 0 && snapshot.lastEvent.length > 0) {
      this.validationText = snapshot.lastEvent;
    }
  }

  private async saveConfig(): Promise<void> {
    if (!this.configService || !this.configValidationService || !this.runtimeStore) {
      return;
    }
    try {
      const targetId = this.editProfileId.length > 0 ? this.editProfileId : this.loadedYamlProfileId;
      if (targetId.length === 0) {
        this.validationText = '保存失败: 编辑器未绑定配置';
        return;
      }
      const strictValidation = await this.configValidationService.validate(this.rawYaml);
      if (!strictValidation.ok) {
        this.validationText = strictValidation.errors.join('; ');
        this.runtimeStore.appendEvent('Config rejected: ' + this.validationText);
        return;
      }
      const result = this.configService.saveRawYaml(targetId, this.rawYaml);
      if (result.ok) {
        this.validationText = '配置已保存 · ' + this.validationSummary(result);
        this.runtimeStore.appendEvent('Config saved');
      } else {
        this.validationText = result.errors.join('; ');
        this.runtimeStore.appendEvent('Config rejected: ' + this.validationText);
      }
      this.reloadProfiles();
      this.refreshState();
    } catch (err) {
      this.validationText = this.toErrorText(err);
    }
  }

  private async validateConfig(): Promise<void> {
    if (!this.configValidationService || !this.runtimeStore) {
      return;
    }
    try {
      const result = await this.configValidationService.validate(this.rawYaml);
      this.validationText = this.validationSummary(result);
      this.runtimeStore.appendEvent(result.ok ? 'Config validation ok' : 'Config validation failed');
      this.refreshState();
    } catch (err) {
      this.validationText = '校验失败: ' + this.toErrorText(err);
    }
  }

  private async connect(): Promise<void> {
    if (!this.vpnControlService || !this.configService) {
      return;
    }
    this.busy = true;
    try {
      const profile = this.configService.getActiveProfile();
      if (!profile) {
        this.validationText = '请先创建配置';
        this.selectSection(3);
        return;
      }
      await this.vpnControlService.connect(profile.id);
      this.validationText = '正在启动连接';
    } catch (err) {
      this.validationText = '启动失败: ' + this.toErrorText(err);
    } finally {
      this.busy = false;
      this.refreshState();
    }
  }

  private async disconnect(): Promise<void> {
    if (!this.vpnControlService) {
      return;
    }
    this.busy = true;
    try {
      await this.vpnControlService.disconnect();
      this.validationText = '正在断开连接';
    } catch (err) {
      this.validationText = '断开失败: ' + this.toErrorText(err);
    } finally {
      this.busy = false;
      this.refreshState();
    }
  }

  private canConnect(): boolean {
    return this.activeProfileId.length > 0 && !this.busy &&
      (this.statusText === 'Idle' || this.statusText === 'Error' || this.statusText === 'Unknown');
  }

  private canDisconnect(): boolean {
    return !this.busy && (this.statusText === 'Connected' || this.statusText === 'Starting' ||
      this.statusText === 'Error' || this.statusText === 'Unknown');
  }

  private currentSectionLabel(): string {
    if (this.selectedSectionIndex === 1) {
      return '代理';
    }
    if (this.selectedSectionIndex === 2) {
      return '配置';
    }
    if (this.selectedSectionIndex === 3) {
      return '创建配置';
    }
    if (this.selectedSectionIndex === 4) {
      return '日志';
    }
    if (this.selectedSectionIndex === 5) {
      return '设置';
    }
    if (this.selectedSectionIndex === 6) {
      return '帮助';
    }
    if (this.selectedSectionIndex === 7) {
      return '关于';
    }
    if (this.selectedSectionIndex === 8) {
      return '编辑配置';
    }
    if (this.selectedSectionIndex === 9) {
      return '诊断';
    }
    return '首页';
  }

  private navIcon(index: number): Resource {
    if (index === 0) {
      return $r('sys.symbol.house');
    }
    if (index === 1) {
      return $r('sys.symbol.wifi_router');
    }
    if (index === 2) {
      return $r('sys.symbol.doc_plaintext');
    }
    if (index === 4) {
      return $r('sys.symbol.list_bullet');
    }
    return $r('sys.symbol.gearshape');
  }

  private selectSection(index: number): void {
    if (index === this.selectedSectionIndex) {
      this.sheetVisible = false;
      this.settingsSelector = '';
      return;
    }
    if (this.isPrimarySection(index)) {
      this.sectionHistory = [];
    } else {
      this.sectionHistory.push(this.selectedSectionIndex);
    }
    this.showSection(index);
  }

  private showSection(index: number): void {
    if (index === 2 && this.configService) {
      this.editProfileId = '';
      const active = this.configService.getActiveProfile();
      if (active) {
        this.rawYaml = this.configService.loadRawYaml(active.id);
        this.loadedYamlProfileId = active.id;
      } else {
        this.rawYaml = '';
        this.loadedYamlProfileId = '';
      }
    }
    this.selectedSectionIndex = index;
    this.sheetVisible = false;
    this.settingsSelector = '';
    if (index === 0 || index === 1 || index === 2) {
      this.reloadProfiles();
    }
  }

  private isPrimarySection(index: number): boolean {
    return index === 0 || index === 1 || index === 2 || index === 4 || index === 5;
  }

  private navigateBack(): boolean {
    if (this.settingsSelector.length > 0) {
      this.settingsSelector = '';
      return true;
    }
    if (this.sheetVisible) {
      this.closeProfileActions();
      return true;
    }
    if (this.selectedSectionIndex === 0) {
      return false;
    }
    let target = 0;
    if (!this.isPrimarySection(this.selectedSectionIndex) && this.sectionHistory.length > 0) {
      target = this.sectionHistory.pop() ?? 0;
    } else {
      this.sectionHistory = [];
    }
    this.showSection(target);
    return true;
  }

  private statusIconText(): string {
    if (this.statusText === 'Connected') {
      return '✓';
    }
    if (this.statusText === 'Starting' || this.statusText === 'Stopping') {
      return '…';
    }
    if (this.statusText === 'Error') {
      return '!';
    }
    if (this.statusText === 'Unknown') {
      return '?';
    }
    return '⊘';
  }

  private statusSubtitleText(): string {
    if (this.activeProfileId.length === 0) {
      return '';
    }
    if (this.statusText === 'Connected') {
      return this.formatBytes(this.uploadSpeed + this.downloadSpeed) + ' 已转发';
    }
    if (this.statusText === 'Starting' || this.statusText === 'Stopping') {
      return this.localizedMessage(this.validationText);
    }
    if (this.statusText === 'Error') {
      return this.lastError.length > 0 ? this.localizedMessage(this.lastError) : '请查看日志';
    }
    if (this.statusText === 'Unknown') {
      return '运行状态待确认';
    }
    return '';
  }

  private formatBytes(value: number): string {
    if (value < 1024) {
      return value.toString() + ' Bytes';
    }
    const kib = value / 1024;
    if (kib < 1024) {
      return kib.toFixed(1) + ' KiB';
    }
    const mib = kib / 1024;
    if (mib < 1024) {
      return mib.toFixed(1) + ' MiB';
    }
    return (mib / 1024).toFixed(1) + ' GiB';
  }

  private formatRate(value: number): string {
    if (value < 1024) {
      return value.toString() + ' B/s';
    }
    return this.formatBytes(value) + '/s';
  }

  private trafficSourceLabel(): string {
    if (this.trafficSource === 'native-mihomo') {
      return 'mihomo';
    }
    if (this.trafficSource === 'tun-interface') {
      return 'TUN';
    }
    return '未采样';
  }

  private profileTypeLabel(profile: Profile): string {
    return profile.type === 'subscription' ? '订阅' : '本地';
  }

  private profileNameLabel(profile: Profile): string {
    if (profile.id === 'default' && profile.name === 'Default') {
      return '默认配置';
    }
    return profile.name;
  }

  private activeProfileLabel(): string {
    if (this.activeProfileId.length === 0) {
      return '未配置';
    }
    if (this.activeProfileId === 'default' && this.activeProfileName === 'Default') {
      return '默认配置';
    }
    return this.activeProfileName;
  }

  private profileTrafficText(profile: Profile): string {
    if (profile.subscription && profile.subscription.lastBytes > 0) {
      return this.formatBytes(profile.subscription.lastBytes) + ' 已下载';
    }
    return profile.type === 'subscription' ? '等待更新' : '本地配置';
  }

  private profileRuleText(profile: Profile): string {
    if (!this.configService) {
      return '0 条规则';
    }
    return this.configService.countRules(profile.id).toString() + ' 条规则';
  }

  private profileDateText(profile: Profile): string {
    if (profile.subscription && profile.subscription.lastSuccessAt > 0) {
      return this.formatDate(profile.subscription.lastSuccessAt);
    }
    return this.formatDate(profile.updatedAt);
  }

  private profileRelativeText(profile: Profile): string {
    const stamp = profile.subscription && profile.subscription.lastSuccessAt > 0 ? profile.subscription.lastSuccessAt : profile.updatedAt;
    if (stamp <= 0) {
      return '未更新';
    }
    const days = Math.floor((Date.now() - stamp) / 86400000);
    if (days <= 0) {
      return '今天';
    }
    return days.toString() + ' 天前';
  }

  private formatDate(timestamp: number): string {
    if (timestamp <= 0) {
      return '--';
    }
    const date = new Date(timestamp);
    const year = date.getFullYear().toString();
    const month = this.pad2(date.getMonth() + 1);
    const day = this.pad2(date.getDate());
    const hour = this.pad2(date.getHours());
    const minute = this.pad2(date.getMinutes());
    const second = this.pad2(date.getSeconds());
    return year + '-' + month + '-' + day + ' ' + hour + ':' + minute + ':' + second;
  }

  private pad2(value: number): string {
    return value < 10 ? '0' + value.toString() : value.toString();
  }

  private toDisplayState(state: string): string {
    if (state.length === 0) {
      return 'Unknown';
    }
    return state.substring(0, 1).toUpperCase() + state.substring(1);
  }

  private runtimeStateLabel(state: string): string {
    if (state === 'Connected') {
      return '已连接';
    }
    if (state === 'Starting') {
      return '启动中';
    }
    if (state === 'Stopping') {
      return '停止中';
    }
    if (state === 'Error') {
      return '异常';
    }
    if (state === 'Unknown') {
      return '待确认';
    }
    return '已停止';
  }

  private coreStateLabel(state: string): string {
    if (state === 'Running') {
      return '运行中';
    }
    if (state === 'Loading') {
      return '加载中';
    }
    if (state === 'Stopping') {
      return '停止中';
    }
    if (state === 'Error') {
      return '异常';
    }
    if (state === 'Unknown') {
      return '待确认';
    }
    return '已停止';
  }

  private eventLevelLabel(level: string): string {
    if (level === 'debug') {
      return '调试';
    }
    if (level === 'warn' || level === 'warning') {
      return '警告';
    }
    if (level === 'error') {
      return '错误';
    }
    return '信息';
  }

  private eventSourceLabel(source: string): string {
    if (source === 'ui') {
      return '界面';
    }
    if (source === 'vpn') {
      return 'VPN';
    }
    if (source === 'core') {
      return '核心';
    }
    if (source === 'subscription') {
      return '订阅';
    }
    if (source === 'config') {
      return '配置';
    }
    if (source === 'diagnostic') {
      return '诊断';
    }
    return source;
  }

  private localizedMessage(message: string): string {
    if (message.startsWith('Error: ')) {
      return '错误：' + this.localizedMessage(message.substring('Error: '.length));
    }
    if (message.startsWith('BusinessError: ')) {
      return '系统错误：' + message.substring('BusinessError: '.length);
    }
    const nestedErrorIndex = message.indexOf('Error: ');
    if (nestedErrorIndex > 0) {
      return message.substring(0, nestedErrorIndex) + this.localizedMessage(message.substring(nestedErrorIndex));
    }
    if (message.startsWith('CONFIG_INVALID: ')) {
      return '配置无效：' + message.substring('CONFIG_INVALID: '.length);
    }
    if (message === 'profiles.json has no profiles') {
      return '配置列表为空';
    }
    if (message === 'Ready') {
      return '准备就绪';
    }
    if (message === 'Connected') {
      return '已连接';
    }
    if (message === 'Disconnected' || message === 'Disconnect finalized idle') {
      return '已断开连接';
    }
    if (message === 'Core loaded') {
      return '核心已加载';
    }
    if (message === 'Starting VPN') {
      return '正在启动 VPN';
    }
    if (message === 'Stopping VPN') {
      return '正在停止 VPN';
    }
    if (message === 'Connect requested') {
      return '已请求连接';
    }
    if (message === 'Disconnect requested') {
      return '已请求断开连接';
    }
    if (message === 'Config saved') {
      return '配置已保存';
    }
    if (message === 'Config validation ok') {
      return '配置校验通过';
    }
    if (message === 'Config validation failed') {
      return '配置校验失败';
    }
    if (message === 'Background running started') {
      return '后台运行已启动';
    }
    if (message === 'Background running stopped') {
      return '后台运行已停止';
    }
    if (message === 'Traffic stats writer starting') {
      return '流量统计正在启动';
    }
    if (message === 'Protect callback registered') {
      return '网络保护回调已注册';
    }
    if (message === 'Protect hook auto-enabled by Go bridge') {
      return '网络保护钩子已由 Go 桥接自动启用';
    }
    if (message === 'TUN poll probe disabled') {
      return 'TUN 轮询探测已关闭';
    }
    if (message === 'Mihomo graceful stop: ok') {
      return 'Mihomo 核心已平滑停止';
    }
    if (message === 'Diagnostics copied to clipboard') {
      return '诊断信息已复制到剪贴板';
    }
    if (message === 'UI restored; runtime state needs verification') {
      return '界面已恢复，正在确认运行状态';
    }
    if (message === 'All configuration reset') {
      return '已重置全部配置';
    }
    if (message === 'BUSY' || message === 'Connect rejected: busy') {
      return '当前正在处理其他操作，请稍后重试';
    }
    if (message === 'latency test timeout') {
      return '节点测速超时';
    }
    if (message.startsWith('Connected profile=')) {
      return '已连接，配置=' + message.substring('Connected profile='.length);
    }
    if (message.startsWith('Connect requested profile=')) {
      return '已请求连接，配置=' + message.substring('Connect requested profile='.length);
    }
    if (message.startsWith('Starting VPN profile=')) {
      return '正在启动 VPN，配置=' + message.substring('Starting VPN profile='.length);
    }
    if (message.startsWith('Connect failed: ')) {
      return '连接失败：' + message.substring('Connect failed: '.length);
    }
    if (message.startsWith('Disconnect failed: ')) {
      return '断开失败：' + message.substring('Disconnect failed: '.length);
    }
    if (message.startsWith('Active profile changed to ')) {
      return '当前配置已切换为 ' + message.substring('Active profile changed to '.length);
    }
    if (message.startsWith('Config rejected: ')) {
      return '配置未通过校验：' + message.substring('Config rejected: '.length);
    }
    if (message.startsWith('Auto refresh subscription before connect profile=')) {
      return '连接前正在自动更新订阅，配置=' +
        message.substring('Auto refresh subscription before connect profile='.length);
    }
    if (message.startsWith('Auto refresh subscription ok bytes=')) {
      return '订阅自动更新成功，字节数=' + message.substring('Auto refresh subscription ok bytes='.length);
    }
    if (message.startsWith('Auto refresh subscription failed, using cached runtime: ')) {
      return '订阅自动更新失败，已使用缓存配置：' +
        message.substring('Auto refresh subscription failed, using cached runtime: '.length);
    }
    if (message.startsWith('Diagnostics export failed: ')) {
      return '诊断导出失败：' + message.substring('Diagnostics export failed: '.length);
    }
    if (message.startsWith('Diagnostics copy failed: ')) {
      return '诊断信息复制失败：' + message.substring('Diagnostics copy failed: '.length);
    }
    if (message.startsWith('Latency test error: ')) {
      return '节点测速失败：' + message.substring('Latency test error: '.length);
    }
    if (message.startsWith('Latency test requested groups=')) {
      return '已请求节点测速，组数=' + message.substring('Latency test requested groups='.length);
    }
    if (message.startsWith('Latency test skipped: ')) {
      return '已跳过节点测速：' + message.substring('Latency test skipped: '.length);
    }
    if (message.startsWith('Proxy selected group=')) {
      return '节点已切换，组=' + message.substring('Proxy selected group='.length);
    }
    if (message.startsWith('Proxy selection failed group=')) {
      return '节点切换失败，组=' + message.substring('Proxy selection failed group='.length);
    }
    if (message.startsWith('Proxy selection requested group=')) {
      return '已请求切换节点，组=' + message.substring('Proxy selection requested group='.length);
    }
    if (message.startsWith('Proxy selected for next connection group=')) {
      return '节点选择已保存供下次连接使用，组=' +
        message.substring('Proxy selected for next connection group='.length);
    }
    if (message.startsWith('Proxy select failed group=')) {
      return '节点选择失败，组=' + message.substring('Proxy select failed group='.length);
    }
    if (message.startsWith('Core start status: ')) {
      return '核心启动状态：' + message.substring('Core start status: '.length);
    }
    if (message.startsWith('Mihomo version unavailable: ')) {
      return '无法读取 Mihomo 版本：' + message.substring('Mihomo version unavailable: '.length);
    }
    if (message.startsWith('VPN created fd=')) {
      return 'VPN 已创建，文件描述符=' + message.substring('VPN created fd='.length);
    }
    if (message.startsWith('Traffic stats source=')) {
      return '流量统计来源=' + message.substring('Traffic stats source='.length);
    }
    if (message.startsWith('Traffic stats writer failed: ')) {
      return '流量统计启动失败：' + message.substring('Traffic stats writer failed: '.length);
    }
    if (message.startsWith('Traffic stats unavailable: ')) {
      return '流量统计不可用：' + message.substring('Traffic stats unavailable: '.length);
    }
    if (message.startsWith('Background running failed: ')) {
      return '后台运行启动失败：' + message.substring('Background running failed: '.length);
    }
    if (message.startsWith('Background running stop failed: ')) {
      return '后台运行停止失败：' + message.substring('Background running stop failed: '.length);
    }
    if (message.startsWith('Settings updated: ')) {
      return this.localizedSettingsEvent(message.substring('Settings updated: '.length));
    }
    if (message.startsWith('Mihomo graceful stop: failed code=')) {
      return 'Mihomo 核心平滑停止失败，错误码=' +
        message.substring('Mihomo graceful stop: failed code='.length);
    }
    if (message.startsWith('Mihomo graceful stop threw: ')) {
      return 'Mihomo 核心平滑停止异常：' + message.substring('Mihomo graceful stop threw: '.length);
    }
    if (message.startsWith('CONFIG_TOO_LARGE')) {
      return '配置文件过大：' + message.substring('CONFIG_TOO_LARGE'.length);
    }
    return message;
  }

  private localizedSettingsEvent(detail: string): string {
    const modeMark = ' mode=';
    const dnsMark = ' dns=';
    const modeIndex = detail.indexOf(modeMark);
    const dnsIndex = detail.indexOf(dnsMark);
    if (!detail.startsWith('route=') || modeIndex < 0 || dnsIndex < 0 || dnsIndex <= modeIndex) {
      return '设置已更新：' + detail;
    }
    const routeMode = detail.substring('route='.length, modeIndex);
    const proxyMode = detail.substring(modeIndex + modeMark.length, dnsIndex);
    const dnsMode = detail.substring(dnsIndex + dnsMark.length);
    return '设置已更新：路由=' + this.routeModeLabel(routeMode) + '，模式=' +
      this.proxyModeLabel(proxyMode) + '，DNS=' + this.dnsModeLabel(dnsMode);
  }

  private eventLineText(event: RuntimeEvent): string {
    return this.eventTimeText(event) + ' · ' + this.eventLevelLabel(event.level) + ' · ' +
      this.localizedMessage(event.message);
  }

  private toErrorText(err: Object): string {
    if (err instanceof Error) {
      return err.name + ': ' + err.message;
    }
    return JSON.stringify(err);
  }

  private async addSubscription(): Promise<void> {
    if (!this.subscriptionService || !this.configService) {
      return;
    }
    this.subBusy = true;
    try {
      const name = this.newProfileName.trim().length > 0 ? this.newProfileName.trim() : '新配置';
      const created = await this.subscriptionService.addSubscriptionAndUpdate(name, this.subUrl);
      if (!created.profile || !created.result.ok) {
        this.subStatus = '添加失败: ' + created.result.error;
        return;
      }
      const profile = created.profile;
      const result = created.result;
      this.configService.setActiveProfile(profile.id);
      this.subStatus = '配置已创建并更新: ' + result.bytes.toString() + 'B';
      this.rawYaml = this.configService.loadRawYaml(profile.id);
      this.loadedYamlProfileId = profile.id;
      this.reloadProfiles();
      this.selectSection(2);
      hilog.info(DOMAIN, TAG, 'Subscription added id=%{public}s', profile.id);
    } catch (err) {
      this.subStatus = '添加失败: ' + this.toErrorText(err);
      hilog.error(DOMAIN, TAG, 'Subscription add failed: %{public}s', this.toErrorText(err));
    } finally {
      this.subBusy = false;
    }
  }

  private async createLocalProfile(): Promise<void> {
    if (!this.configService || !this.configValidationService) {
      return;
    }
    try {
      const name = this.newProfileName.trim().length > 0 ? this.newProfileName.trim() : '新配置';
      const validation = await this.configValidationService.validate(this.rawYaml);
      if (!validation.ok) {
        this.subStatus = '创建失败: ' + validation.errors.join('; ');
        return;
      }
      const profile = this.configService.createLocalProfile(name, this.rawYaml);
      this.configService.setActiveProfile(profile.id);
      this.loadedYamlProfileId = profile.id;
      this.subStatus = '本地配置已创建';
      this.reloadProfiles();
      this.selectSection(2);
    } catch (err) {
      this.subStatus = '创建失败: ' + this.toErrorText(err);
    }
  }

  private async importLocalProfileFromFile(): Promise<void> {
    if (!this.configService || !this.configValidationService) {
      return;
    }
    this.subBusy = true;
    try {
      const documentPicker = new picker.DocumentViewPicker(getContext(this));
      const uris = await documentPicker.select({
        maxSelectNumber: 1,
        fileSuffixFilters: ['YAML|.yaml,.yml', 'Text|.txt']
      });
      if (!uris || uris.length === 0) {
        this.subStatus = '已取消文件导入';
        return;
      }
      const uri = uris[0];
      const importedFile = this.readTextFileUri(uri);
      if (!this.isSupportedImportFile(importedFile.name)) {
        this.subStatus = '导入失败: 仅支持 .yaml/.yml/.txt';
        return;
      }
      const content = importedFile.content;
      const validation = await this.configValidationService.validate(content);
      if (!validation.ok) {
        this.subStatus = '导入失败: ' + validation.errors.join('; ');
        hilog.warn(DOMAIN, TAG, 'Config file validation failed: %{public}s', validation.errors.join('; '));
        return;
      }
      const name = this.newProfileName.trim().length > 0 ? this.newProfileName.trim() :
        this.importNameFromFileName(importedFile.name);
      const profile = this.configService.createLocalProfile(name, content);
      this.configService.setActiveProfile(profile.id);
      this.rawYaml = content;
      this.loadedYamlProfileId = profile.id;
      this.validationText = this.validationSummary(validation);
      this.subStatus = '文件已导入: ' + profile.name;
      this.reloadProfiles();
      this.selectSection(2);
    } catch (err) {
      this.subStatus = '导入异常: ' + this.toErrorText(err);
      hilog.error(DOMAIN, TAG, 'Config file import failed: %{public}s', this.toErrorText(err));
    } finally {
      this.subBusy = false;
    }
  }

  private async refreshSubscription(profileId: string = ''): Promise<void> {
    if (!this.subscriptionService || !this.configService) {
      return;
    }
    this.subBusy = true;
    try {
      const profile = profileId.length > 0 ? this.configService.getProfile(profileId) :
        this.configService.getActiveProfile();
      if (!profile || profile.type !== 'subscription') {
        this.subStatus = '当前配置不是 URL 订阅';
        return;
      }
      const result = await this.subscriptionService.update(profile.id);
      this.subStatus = result.ok ? '更新完成: ' + result.statusCode.toString() + ' ' + result.bytes.toString() + 'B' :
        '更新失败: ' + result.error;
      if (profile.active) {
        this.rawYaml = this.configService.loadRawYaml(profile.id);
        this.loadedYamlProfileId = profile.id;
      }
      this.reloadProfiles();
      this.refreshState();
    } catch (err) {
      this.subStatus = '更新异常: ' + this.toErrorText(err);
    } finally {
      this.subBusy = false;
    }
  }

  private async refreshActiveConfig(): Promise<void> {
    const profile = this.getActiveProfileFromState();
    if (profile && profile.type === 'subscription') {
      this.refreshSubscription(profile.id);
      return;
    }
    if (this.configService && this.configValidationService) {
      if (this.activeProfileId.length === 0) {
        this.subStatus = '请先创建配置';
        return;
      }
      const result = await this.configValidationService.validate(this.configService.loadRawYaml(this.activeProfileId));
      this.subStatus = this.validationSummary(result);
      this.reloadProfiles();
    }
  }

  private switchProfile(profileId: string): void {
    if (!this.configService) {
      return;
    }
    if (profileId === this.activeProfileId) {
      return;
    }
    if (!this.canChangeStoredData()) {
      this.subStatus = '请先断开 VPN 再切换配置';
      this.validationText = '请先断开 VPN 再切换配置';
      if (this.runtimeStore) {
        this.runtimeStore.appendEvent('Profile switch rejected while VPN is active', 'warn', 'config');
      }
      return;
    }
    const profile = this.configService.setActiveProfile(profileId);
    if (profile) {
      this.activeProfileId = profile.id;
      this.activeProfileName = profile.name;
      this.selectedProxyGroupName = '';
      this.rawYaml = this.configService.loadRawYaml(profileId);
      this.loadedYamlProfileId = profileId;
      this.subStatus = '已切换到: ' + profile.name;
      if (this.runtimeStore) {
        const snapshot = this.runtimeStore.getSnapshot();
        if (snapshot.runtimeState === 'idle' || snapshot.runtimeState === 'error' || snapshot.runtimeState === 'unknown') {
          this.runtimeStore.update({
            activeProfileId: profile.id,
            activeProfileName: profile.name
          });
        }
        this.runtimeStore.appendEvent('Active profile changed to ' + profile.name, 'info', 'config');
      }
      this.reloadProfiles();
      this.refreshState();
    }
  }

  private openProfileActions(profileId: string): void {
    this.settingsSelector = '';
    this.sheetProfileId = profileId;
    this.sheetVisible = true;
  }

  private closeProfileActions(): void {
    this.sheetVisible = false;
    this.sheetProfileId = '';
  }

  private getProfileById(profileId: string): Profile | null {
    for (const profile of this.profiles) {
      if (profile.id === profileId) {
        return profile;
      }
    }
    return null;
  }

  private getActiveProfileFromState(): Profile | null {
    for (const profile of this.profiles) {
      if (profile.active || profile.id === this.activeProfileId) {
        return profile;
      }
    }
    return this.profiles.length > 0 ? this.profiles[0] : null;
  }

  private editProfile(profileId: string): void {
    if (!this.configService) {
      return;
    }
    this.editProfileId = profileId;
    this.rawYaml = this.configService.loadRawYaml(profileId);
    this.loadedYamlProfileId = profileId;
    this.closeProfileActions();
    this.selectSection(8);
  }

  private duplicateProfile(profileId: string): void {
    if (!this.configService) {
      return;
    }
    const profile = this.configService.duplicateProfile(profileId);
    this.subStatus = profile ? '配置已复制' : '复制失败';
    this.closeProfileActions();
    this.reloadProfiles();
  }

  private deleteProfile(profileId: string): void {
    if (!this.configService) {
      return;
    }
    if (profileId === this.activeProfileId) {
      this.subStatus = '当前使用中的配置不能删除，请先切换到其他配置';
      this.closeProfileActions();
      return;
    }
    const ok = this.configService.deleteProfile(profileId);
    this.subStatus = ok ? '配置已删除' : '默认配置、当前配置或最后一个配置不能删除';
    this.closeProfileActions();
    this.reloadProfiles();
  }

  private confirmDeleteProfile(profileId: string): void {
    const profile = this.getProfileById(profileId);
    const profileName = profile ? profile.name : profileId;
    this.closeProfileActions();
    AlertDialog.show({
      title: '删除配置',
      message: '确定删除“' + profileName + '”吗？此操作无法撤销。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        action: () => {
          this.deleteProfile(profileId);
        }
      },
      cancel: () => {
      }
    });
  }

  private canChangeStoredData(): boolean {
    return this.statusText !== 'Connected' && this.statusText !== 'Starting' && this.statusText !== 'Stopping';
  }

  private confirmClearCache(): void {
    if (!this.canChangeStoredData()) {
      this.validationText = '请先断开 VPN 再清理缓存';
      return;
    }
    AlertDialog.show({
      title: '清理缓存',
      message: '将清除延迟测试结果、临时流量文件和 mihomo 缓存，不会删除配置或今日流量。',
      primaryButton: { value: '取消', action: () => {
      } },
      secondaryButton: { value: '清理', action: () => {
        if (this.configService) {
          const count = this.configService.clearGeneratedCache();
          this.proxyDelayRecords = [];
          this.validationText = '缓存已清理，共 ' + count.toString() + ' 项';
          this.reloadProfiles();
        }
      } },
      cancel: () => {
      }
    });
  }

  private confirmResetAllConfiguration(): void {
    if (!this.canChangeStoredData()) {
      this.validationText = '请先断开 VPN 再重置配置';
      return;
    }
    AlertDialog.show({
      title: '重置全部配置',
      message: '所有本地配置、订阅、设置、节点选择和流量记录都将被删除。此操作无法撤销。',
      primaryButton: { value: '取消', action: () => {
      } },
      secondaryButton: { value: '全部重置', action: () => {
        if (!this.configService || !this.settingsService || !this.runtimeStore) {
          return;
        }
        this.configService.resetAllConfiguration();
        this.appSettings = this.settingsService.load();
        this.activeProfileId = '';
        this.activeProfileName = '未配置';
        this.rawYaml = '';
        this.loadedYamlProfileId = '';
        this.editProfileId = '';
        this.runtimeStore.resetToIdle('All configuration reset');
        this.validationText = '全部配置已重置';
        this.subStatus = '';
        this.reloadProfiles();
        this.refreshState(true);
      } },
      cancel: () => {
      }
    });
  }

  private canDeleteProfile(profileId: string): boolean {
    return profileId !== 'default' && profileId !== this.activeProfileId && this.profiles.length > 1;
  }

  private createModeSubtitle(): string {
    if (this.createMode === 0) {
      return '支持 .yaml / .yml / .txt，校验通过后才保存';
    }
    if (this.createMode === 2) {
      return '扫描包含 http/https 订阅地址的二维码';
    }
    return '从订阅链接导入配置';
  }

  private validationSummary(result: ConfigValidationResult): string {
    if (!result.ok) {
      return result.errors.join('; ');
    }
    const warnings = result.warnings;
    if (warnings.length > 0) {
      return '校验通过，警告: ' + warnings.join('; ');
    }
    return '校验通过';
  }

  private isSupportedImportFile(fileName: string): boolean {
    const lower = fileName.toLowerCase();
    return lower.endsWith('.yaml') || lower.endsWith('.yml') || lower.endsWith('.txt');
  }

  private importNameFromFileName(fileName: string): string {
    const dot = fileName.lastIndexOf('.');
    const base = dot > 0 ? fileName.substring(0, dot) : fileName;
    return base.length > 0 ? base : '文件导入配置';
  }

  private readTextFileUri(uri: string): ImportedTextFile {
    const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    try {
      const fileSize = fs.statSync(file.fd).size;
      if (fileSize > MAX_IMPORT_FILE_BYTES) {
        throw new Error('CONFIG_TOO_LARGE: 文件超过 5 MiB');
      }
      const decoder = util.TextDecoder.create('utf-8');
      let remaining = fileSize;
      let content = '';
      while (remaining > 0) {
        const chunkSize = Math.min(IMPORT_READ_CHUNK_BYTES, remaining);
        const buffer = new ArrayBuffer(chunkSize);
        const bytesRead = fs.readSync(file.fd, buffer, { length: chunkSize });
        if (bytesRead <= 0) {
          break;
        }
        remaining -= bytesRead;
        content += decoder.decodeToString(new Uint8Array(buffer, 0, bytesRead), { stream: remaining > 0 });
      }
      if (remaining > 0) {
        throw new Error('CONFIG_READ_INCOMPLETE: 文件未完整读取');
      }
      return {
        name: file.name,
        content: content
      };
    } finally {
      fs.closeSync(file);
    }
  }

  private async scanAndCreateSubscription(): Promise<void> {
    if (!this.uiContext || this.subBusy) {
      return;
    }
    this.subBusy = true;
    try {
      const result = await scanBarcode.startScanForResult(this.uiContext);
      const value = result.originalValue.trim();
      if (!this.isHttpSubscriptionUrl(value)) {
        this.subStatus = '识别失败: 二维码不是 http/https 订阅地址';
        return;
      }
      this.subUrl = value;
      this.subStatus = '已识别订阅地址，正在创建';
    } catch (err) {
      this.subStatus = '扫码已取消或失败: ' + this.toErrorText(err);
      return;
    } finally {
      this.subBusy = false;
    }
    await this.addSubscription();
  }

  private isHttpSubscriptionUrl(value: string): boolean {
    const lower = value.toLowerCase();
    return lower.startsWith('https://') || lower.startsWith('http://');
  }

  private isTabletLayout(): boolean {
    return this.rootWidth >= 720;
  }

  private appBg(): string {
    return '#0F1419';
  }

  private surfaceBg(): string {
    return '#161C24';
  }

  private elevatedBg(): string {
    return '#1C2430';
  }

  private inputBg(): string {
    return '#121820';
  }

  private primaryText(): string {
    return '#EEF2F6';
  }

  private secondaryText(): string {
    return '#8B95A5';
  }

  private mutedText(): string {
    return '#5C6675';
  }

  private accentColor(): string {
    return '#2DD4BF';
  }

  private dangerColor(): string {
    return '#F87171';
  }

  private stateAccentColor(): string {
    if (this.statusText === 'Connected') {
      return this.accentColor();
    }
    if (this.statusText === 'Starting') {
      return '#60A5FA';
    }
    if (this.statusText === 'Stopping') {
      return '#A78BFA';
    }
    if (this.statusText === 'Error') {
      return this.dangerColor();
    }
    if (this.statusText === 'Unknown') {
      return '#94A3B8';
    }
    return '#64748B';
  }

  private selectedNodeName(): string {
    const group = this.getSelectedProxyGroup();
    const nodes = group ? group.nodes : this.nodes;
    if (nodes.length === 0) {
      return 'DIRECT';
    }
    for (const node of nodes) {
      if (node.selected) {
        return node.name;
      }
    }
    return nodes[0].name;
  }

  private selectedNodeMeta(): string {
    const group = this.getSelectedProxyGroup();
    const nodes = group ? group.nodes : this.nodes;
    if (nodes.length === 0) {
      return 'Direct · --';
    }
    let node = nodes[0];
    for (const item of nodes) {
      if (item.selected) {
        node = item;
        break;
      }
    }
    return node.type.toUpperCase() + ' · ' + (node.delay > 0 ? node.delay.toString() + ' ms' : '--');
  }

  private selectedProxyGroupLabel(): string {
    const group = this.getSelectedProxyGroup();
    return group ? group.name : 'Proxy';
  }

  private selectedProxyGroupType(): string {
    const group = this.getSelectedProxyGroup();
    return group ? group.type : 'select';
  }

  private hasProxyGroup(name: string): boolean {
    for (const group of this.proxyGroups) {
      if (group.name === name) {
        return true;
      }
    }
    return false;
  }

  private getSelectedProxyGroup(): ProxyGroup | null {
    for (const group of this.proxyGroups) {
      if (group.name === this.selectedProxyGroupName) {
        return group;
      }
    }
    return this.proxyGroups.length > 0 ? this.proxyGroups[0] : null;
  }

  private getSelectedProxyGroupNodes(): ProxyNode[] {
    const group = this.getSelectedProxyGroup();
    return group ? group.nodes : [];
  }

  private getFilteredNodes(): ProxyNode[] {
    const nodes = this.getSelectedProxyGroupNodes();
    const keyword = this.nodeSearchText.trim().toLowerCase();
    if (keyword.length === 0) {
      return nodes;
    }
    return nodes.filter((node: ProxyNode) => {
      return node.name.toLowerCase().indexOf(keyword) >= 0 ||
        node.type.toLowerCase().indexOf(keyword) >= 0 ||
        node.server.toLowerCase().indexOf(keyword) >= 0;
    });
  }

  private selectProxyGroup(name: string): void {
    this.selectedProxyGroupName = name;
    this.nodes = this.getSelectedProxyGroupNodes();
  }

  private async testProxyLatency(scope: string): Promise<void> {
    if (!this.runtimeStore || !this.vpnControlService || !this.configService) {
      return;
    }
    if (this.latencyBusy) {
      return;
    }
    const targetGroups = this.getLatencyTargetGroups(scope);
    if (targetGroups.length === 0) {
      this.validationText = '暂无可测速节点';
      this.runtimeStore.appendEvent('Latency test skipped: no proxy nodes');
      return;
    }

    this.latencyBusy = true;
    this.validationText = scope === 'all' ? '正在测速全部节点' : '正在测速当前组';
    try {
      const requestId = 'lat-' + Date.now().toString();
      const groupNames = targetGroups.map((group: ProxyGroup) => group.name);
      await this.vpnControlService.requestProxyLatency(requestId, this.activeProfileId, groupNames,
        this.delayTestUrl(), 8000);
      const state = await this.waitProxyLatencyResult(requestId, Math.max(25000, groupNames.length * 10000 + 10000));
      this.proxyDelayRecords = state.records;
      this.proxyGroups = this.withMeasuredDelays(this.proxyGroups, this.activeProfileId);
      this.nodes = this.getSelectedProxyGroupNodes();
      if (state.status === 'complete') {
        this.validationText = scope === 'all' ? '测速全部完成' : '当前组测速完成';
      } else {
        this.validationText = state.error.length > 0 ? state.error : '测速失败';
      }
    } catch (err) {
      this.validationText = '测速失败: ' + this.toErrorText(err);
      this.runtimeStore.appendEvent('Latency test error: ' + this.toErrorText(err));
    } finally {
      this.latencyBusy = false;
    }
  }

  private async waitProxyLatencyResult(requestId: string, timeoutMs: number): Promise<ProxyLatencyState> {
    const startedAt = Date.now();
    while (Date.now() - startedAt < timeoutMs) {
      if (this.configService) {
        const state = this.configService.loadProxyLatencyState();
        if (state.requestId === requestId && (state.status === 'complete' || state.status === 'error')) {
          return state;
        }
      }
      await this.sleep(500);
    }
    throw new Error('latency test timeout');
  }

  private async waitProxySelectionResult(requestId: string, timeoutMs: number): Promise<ProxySelectionRequestState> {
    const startedAt = Date.now();
    while (Date.now() - startedAt < timeoutMs) {
      if (this.configService) {
        const state = this.configService.loadProxySelectionRequestState();
        if (state.requestId === requestId && (state.status === 'complete' || state.status === 'error')) {
          return state;
        }
      }
      await this.sleep(200);
    }
    throw new Error('节点切换超时');
  }

  private async sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  private getLatencyTargetGroups(scope: string): ProxyGroup[] {
    if (scope === 'all') {
      return this.proxyGroups;
    }
    const group = this.getSelectedProxyGroup();
    return group ? [group] : [];
  }

  private withMeasuredDelays(groups: ProxyGroup[], profileId: string): ProxyGroup[] {
    return groups.map((group: ProxyGroup) => {
      const nextNodes = group.nodes.map((node: ProxyNode) => {
        const next: ProxyNode = {
          name: node.name,
          type: node.type,
          server: node.server,
          port: node.port,
          group: node.group,
          selected: node.selected,
          delay: this.getMeasuredDelay(profileId, group.name, node.name, node.delay)
        };
        return next;
      });
      const nextGroup: ProxyGroup = {
        name: group.name,
        type: group.type,
        selected: group.selected,
        nodes: nextNodes
      };
      return nextGroup;
    });
  }

  private getMeasuredDelay(profileId: string, groupName: string, nodeName: string, fallback: number): number {
    for (const record of this.proxyDelayRecords) {
      if (record.profileId === profileId && record.groupName === groupName && record.nodeName === nodeName) {
        return record.delay;
      }
    }
    return fallback;
  }

  private delayTestUrl(): string {
    return 'http://www.gstatic.com/generate_204';
  }

  private getFilteredRuntimeEvents(): RuntimeEvent[] {
    const keyword = this.logSearchText.trim().toLowerCase();
    return this.runtimeEvents.filter((event: RuntimeEvent) => {
      const levelOk = this.logLevelFilter === 'all' || event.level === this.logLevelFilter;
      const localizedMessage = this.localizedMessage(event.message).toLowerCase();
      const localizedSource = this.eventSourceLabel(event.source).toLowerCase();
      const localizedLevel = this.eventLevelLabel(event.level).toLowerCase();
      const keywordOk = keyword.length === 0 ||
        event.message.toLowerCase().indexOf(keyword) >= 0 ||
        event.source.toLowerCase().indexOf(keyword) >= 0 ||
        event.level.toLowerCase().indexOf(keyword) >= 0 ||
        localizedMessage.indexOf(keyword) >= 0 ||
        localizedSource.indexOf(keyword) >= 0 ||
        localizedLevel.indexOf(keyword) >= 0;
      return levelOk && keywordOk;
    });
  }

  private setLogLevelFilter(level: string): void {
    this.logLevelFilter = level;
  }

  private updateLogSearch(text: string): void {
    this.logSearchText = text;
  }

  private toggleLogFollow(): void {
    this.logFollow = !this.logFollow;
    if (this.logFollow) {
      this.logsScroller.scrollEdge(Edge.Top);
    }
  }

  private pauseLogFollowForUserScroll(source: ScrollSource): void {
    if (!this.logFollow) {
      return;
    }
    if (source === ScrollSource.DRAG || source === ScrollSource.OTHER_USER_INPUT ||
      source === ScrollSource.SCROLL_BAR) {
      this.logFollow = false;
    }
  }

  private exportDiagnostics(): void {
    if (!this.runtimeStore || !this.configService) {
      return;
    }
    try {
      const profile = this.configService.getActiveProfile();
      if (!profile) {
        this.validationText = '请先创建配置后再导出诊断';
        return;
      }
      const path = this.runtimeStore.exportDiagnostics(this.appSettings, profile, this.selectedProxyGroupLabel(),
        this.selectedNodeName(), this.selectedNodeMeta());
      this.lastDiagnosticPath = path;
      this.diagnosticText = this.runtimeStore.createDiagnosticsText(this.appSettings, profile,
        this.selectedProxyGroupLabel(), this.selectedNodeName(), this.selectedNodeMeta());
      this.validationText = '诊断已导出';
      this.refreshState();
    } catch (err) {
      this.validationText = '诊断导出失败: ' + this.toErrorText(err);
      if (this.runtimeStore) {
        this.runtimeStore.appendEvent('Diagnostics export failed: ' + this.toErrorText(err), 'error', 'diagnostic');
      }
    }
  }

  private async copyDiagnosticText(): Promise<void> {
    if (!this.runtimeStore || !this.configService) {
      return;
    }
    const profile = this.configService.getActiveProfile();
    if (!profile) {
      this.validationText = '请先创建配置后再复制诊断';
      return;
    }
    this.diagnosticText = this.runtimeStore.createDiagnosticsText(this.appSettings, profile,
      this.selectedProxyGroupLabel(), this.selectedNodeName(), this.selectedNodeMeta());
    try {
      await pasteboard.getSystemPasteboard().setData(
        pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.diagnosticText)
      );
      this.validationText = '诊断信息已复制';
      this.runtimeStore.appendEvent('Diagnostics copied to clipboard', 'info', 'diagnostic');
    } catch (err) {
      this.validationText = '复制失败: ' + this.toErrorText(err);
      this.runtimeStore.appendEvent('Diagnostics copy failed: ' + this.toErrorText(err), 'error', 'diagnostic');
    }
  }

  private refreshDiagnosticText(): void {
    if (!this.runtimeStore || !this.configService) {
      return;
    }
    const profile = this.configService.getActiveProfile();
    if (!profile) {
      this.diagnosticText = '';
      this.validationText = '请先创建配置';
      return;
    }
    this.diagnosticText = this.runtimeStore.createDiagnosticsText(this.appSettings, profile,
      this.selectedProxyGroupLabel(), this.selectedNodeName(), this.selectedNodeMeta());
    this.validationText = '诊断信息已刷新';
  }

  private eventTimeText(event: RuntimeEvent): string {
    const date = new Date(event.timestamp);
    return this.pad2(date.getHours()) + ':' + this.pad2(date.getMinutes()) + ':' + this.pad2(date.getSeconds());
  }

  private eventToneColor(level: RuntimeEventLevel): string {
    if (level === 'error') {
      return '#FF7A7A';
    }
    if (level === 'warn') {
      return '#F0C36A';
    }
    if (level === 'debug') {
      return this.mutedText();
    }
    return this.accentColor();
  }

  private snapshotUpdatedText(): string {
    if (!this.runtimeStore) {
      return '--';
    }
    return this.formatDate(this.runtimeStore.getSnapshot().updatedAt);
  }

  private startedAtText(): string {
    if (!this.runtimeStore) {
      return '--';
    }
    return this.formatDate(this.runtimeStore.getSnapshot().startedAt);
  }

  private tunFdText(): string {
    if (!this.runtimeStore) {
      return '-1';
    }
    return this.runtimeStore.getSnapshot().tunFd.toString();
  }

  private mihomoVersionText(): string {
    const prefix = 'mihomo version: ';
    for (const event of this.runtimeEvents) {
      const lower = event.message.toLowerCase();
      if (lower.startsWith(prefix)) {
        return event.message.substring(prefix.length);
      }
    }
    return '未读取';
  }

  private protectHookText(): string {
    for (const event of this.runtimeEvents) {
      const lower = event.message.toLowerCase();
      if (lower.indexOf('protect failed') >= 0 || lower.indexOf('protect hook') >= 0 &&
        lower.indexOf('failed') >= 0) {
        return '异常：' + this.localizedMessage(event.message);
      }
      if (lower.indexOf('protect hook auto-enabled') >= 0 || lower.indexOf('protect callback registered') >= 0) {
        return '已启用';
      }
    }
    return this.statusText === 'Connected' ? '待确认' : '未运行';
  }

  private gracefulStopText(): string {
    for (const event of this.runtimeEvents) {
      const lower = event.message.toLowerCase();
      if (lower.indexOf('mihomo graceful stop: ok') >= 0) {
        return '已验证可用';
      }
      if (lower.indexOf('mihomo graceful stop') >= 0 &&
        (lower.indexOf('failed') >= 0 || lower.indexOf('threw') >= 0)) {
        return '异常：' + this.localizedMessage(event.message);
      }
      if (lower.indexOf('skipping graceful stop') >= 0) {
        return '已跳过：无活动的 TUN 文件描述符';
      }
    }
    return this.tunFdText() !== '-1' ? '可用，待断开验证' : '未运行';
  }

  private pocSmokeSummary(): string {
    if (!this.runtimeStore) {
      return '未运行';
    }
    return this.runtimeStore.getPocSmokeSummary();
  }

  private async selectProxyNode(node: ProxyNode): Promise<void> {
    if (!this.configService || !this.runtimeStore || !this.vpnControlService) {
      return;
    }
    const snapshot = this.runtimeStore.getSnapshot();
    if (snapshot.runtimeState === 'starting' || snapshot.runtimeState === 'stopping') {
      this.validationText = '连接状态切换中，请稍后选择节点';
      return;
    }
    if (snapshot.runtimeState !== 'connected' || snapshot.coreState !== 'running') {
      const ok = this.configService.selectLocalProxy(node.group, node.name, this.activeProfileId);
      this.validationText = ok ? '节点选择已保存，将在连接时应用' : '节点选择失败';
      this.runtimeStore.appendEvent(ok ?
        'Proxy selected for next connection group=' + node.group + ' node=' + node.name :
        'Proxy select failed group=' + node.group + ' node=' + node.name);
      if (ok) {
        this.reloadProfiles();
        this.refreshState();
      }
      return;
    }

    this.validationText = '正在切换节点';
    try {
      const requestId = 'select-' + Date.now().toString();
      await this.vpnControlService.requestProxySelection(requestId, this.activeProfileId, node.group, node.name);
      const result = await this.waitProxySelectionResult(requestId, 10000);
      if (result.status !== 'complete') {
        throw new Error(result.error.length > 0 ? result.error : '节点切换失败');
      }
      this.validationText = '节点已切换';
      this.reloadProfiles();
      this.refreshState();
    } catch (err) {
      this.validationText = '节点切换失败: ' + this.toErrorText(err);
    }
  }

  private refreshDailyTraffic(): void {
    if (!this.uiContext) {
      return;
    }
    try {
      new TrafficStatsService(this.uiContext.filesDir).refreshDailySnapshot();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'daily traffic refresh failed: %{public}s', this.toErrorText(err));
    }
  }

  private openSettingsSelector(type: string): void {
    this.sheetVisible = false;
    this.settingsSelector = type;
  }

  private closeSettingsSelector(): void {
    this.settingsSelector = '';
  }

  private selectRouteMode(mode: VpnRouteMode): void {
    this.updateSettings({ routeMode: mode });
    this.closeSettingsSelector();
  }

  private selectProxyMode(mode: ProxyMode): void {
    this.updateSettings({ proxyMode: mode });
    this.closeSettingsSelector();
  }

  private cycleDnsMode(): void {
    const modes: DnsMode[] = ['default', 'fake-ip', 'redir-host'];
    const index = modes.indexOf(this.appSettings.dnsMode);
    this.updateSettings({ dnsMode: modes[(index + 1) % modes.length] });
  }

  private cycleLogLevel(): void {
    const levels: LogLevel[] = ['info', 'debug', 'warning', 'error'];
    const index = levels.indexOf(this.appSettings.logLevel);
    this.updateSettings({ logLevel: levels[(index + 1) % levels.length] });
  }

  private routeModeLabel(mode: string): string {
    if (mode === 'blocking-default') {
      return '全量接管(推荐)';
    }
    if (mode === 'split-default') {
      return '分段默认路由';
    }
    if (mode === 'default') {
      return '系统默认路由';
    }
    if (mode === 'no-routes') {
      return '不下发路由';
    }
    if (mode === 'exclude-local') {
      return '排除局域网';
    }
    if (mode === 'blocking-split') {
      return '阻塞分段路由';
    }
    if (mode === 'blocking-empty') {
      return '阻塞空路由';
    }
    return mode;
  }

  private proxyModeLabel(mode: string): string {
    if (mode === 'global') {
      return '全局';
    }
    if (mode === 'direct') {
      return '直连';
    }
    return '规则(推荐)';
  }

  private dnsModeLabel(mode: string): string {
    if (mode === 'redir-host') {
      return 'redir-host';
    }
    if (mode === 'fake-ip') {
      return 'fake-ip';
    }
    return '默认';
  }

  private onOffLabel(value: boolean): string {
    return value ? '开启' : '关闭';
  }

  private settingFlagValue(key: string): boolean {
    if (key === 'ipv6') {
      return this.appSettings.ipv6Enabled;
    }
    if (key === 'udp') {
      return this.appSettings.udpEnabled;
    }
    if (key === 'autoRefresh') {
      return this.appSettings.autoRefreshSubscriptionOnConnect;
    }
    return false;
  }

  private toggleSettingFlag(key: string): void {
    if (key === 'ipv6') {
      this.updateSettings({ ipv6Enabled: !this.appSettings.ipv6Enabled });
      return;
    }
    if (key === 'udp') {
      this.updateSettings({ udpEnabled: !this.appSettings.udpEnabled });
      return;
    }
    if (key === 'autoRefresh') {
      this.updateSettings({
        autoRefreshSubscriptionOnConnect: !this.appSettings.autoRefreshSubscriptionOnConnect
      });
      return;
    }
  }

  @Builder AppHeader() {
    Row({ space: 12 }) {
      Column() {
        Text('CG')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.accentColor())
      }
      .width(34)
      .height(34)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor('#172B30')
      .borderRadius(10)

      Column({ space: 2 }) {
        Text(this.selectedSectionIndex === 0 ? 'ClashGuard' : this.currentSectionLabel())
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryText())
          .maxLines(1)
        Text('当前配置 · ' + this.activeProfileLabel())
          .fontSize(11)
          .fontColor(this.mutedText())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Button('诊断')
        .height(34)
        .fontSize(12)
        .fontColor(this.accentColor())
        .backgroundColor(this.elevatedBg())
        .borderRadius(10)
        .onClick(() => {
          this.selectSection(9);
        })
    }
    .width('100%')
    .height(60)
    .padding({ left: 20, right: 20, top: 8, bottom: 8 })
    .backgroundColor(this.appBg())
  }

  @Builder HomePage() {
    Scroll() {
      if (this.isTabletLayout()) {
        Row({ space: 18 }) {
          Column({ space: 16 }) {
            this.ConnectionHero()
            if (this.activeProfileId.length > 0) {
              this.StatusPills()
              if (this.lastError.length > 0) {
                this.ErrorBanner()
              }
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Center)

          Column({ space: 14 }) {
            if (this.activeProfileId.length === 0) {
              this.FirstConfigPrompt()
            } else {
              this.CurrentProxyCard()
              this.TrafficRow()
              this.ProfileChipsSection()
              this.RouteModeSection()
              this.EventSection()
            }
          }
          .layoutWeight(1)
        }
        .width('100%')
        .constraintSize({ minHeight: '100%' })
        .alignItems(VerticalAlign.Top)
        .padding({ left: 20, right: 20, top: 12, bottom: 28 })
      } else {
        Column({ space: 16 }) {
          this.ConnectionHero()
          if (this.activeProfileId.length === 0) {
            this.FirstConfigPrompt()
          } else {
            this.StatusPills()
            if (this.lastError.length > 0) {
              this.ErrorBanner()
            }
            this.CurrentProxyCard()
            this.TrafficRow()
            this.ProfileChipsSection()
            this.RouteModeSection()
            this.EventSection()
          }
        }
        .width('100%')
        .constraintSize({ minHeight: '100%' })
        .justifyContent(FlexAlign.Start)
        .padding({ left: 20, right: 20, top: 12, bottom: 28 })
      }
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
    .layoutWeight(1)
    .width('100%')
    .backgroundColor(this.appBg())
  }

  @Builder FirstConfigPrompt() {
    Column({ space: 16 }) {
      Row({ space: 12 }) {
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.doc_plaintext'))
            .fontSize(25)
            .fontWeight(FontWeight.Medium)
            .fontColor([this.accentColor()])
        }
        .width(48)
        .height(48)
        .backgroundColor('#17302F')
        .borderRadius(12)

        Column({ space: 4 }) {
          Text('添加首个配置')
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.primaryText())
            .width('100%')
          Text('支持订阅链接、本地文件和二维码导入')
            .fontSize(12)
            .fontColor(this.secondaryText())
            .width('100%')
            .maxLines(2)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')

      Button() {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.doc_plaintext'))
            .fontSize(17)
            .fontColor(['#042F2E'])
          Text('添加配置')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor('#042F2E')
        }
        .justifyContent(FlexAlign.Center)
      }
      .height(46)
      .width('100%')
      .backgroundColor(this.accentColor())
      .borderRadius(10)
      .onClick(() => {
        this.subStatus = '';
        this.createMode = 1;
        this.selectSection(3);
      })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.surfaceBg())
    .borderRadius(12)
  }

  @Builder ConnectionHero() {
    Column({ space: 10 }) {
      Row({ space: 16 }) {
        Column() {
          Column() {
            Text(this.statusIconText())
              .fontSize(34)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.stateAccentColor())
          }
          .width(72)
          .height(72)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .backgroundColor(this.statusText === 'Connected' ? '#16302F' : this.elevatedBg())
          .borderRadius(36)
        }
        .width(104)
        .height(104)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(this.surfaceBg())
        .borderRadius(52)
        .border({ width: 2, color: this.stateAccentColor() })

        Column({ space: 8 }) {
          if (this.canConnect()) {
            this.ActiveActionButton('连接', false, () => {
              this.connect();
            })
          } else {
            this.DisabledActionButton('连接')
          }
          if (this.canDisconnect()) {
            this.ActiveActionButton('断开', true, () => {
              this.disconnect();
            })
          } else {
            this.DisabledActionButton('断开')
          }
        }
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.statusSubtitleText().length > 0) {
        Text(this.statusSubtitleText())
          .fontSize(12)
          .fontColor(this.secondaryText())
          .width('100%')
          .maxLines(2)
          .textAlign(TextAlign.Center)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .padding({ top: 4, bottom: 2 })
    .alignItems(HorizontalAlign.Center)
  }

  @Builder ActiveActionButton(label: string, danger: boolean, action: () => void) {
    Row() {
      Text(label)
        .fontSize(16)
        .fontWeight(danger ? FontWeight.Medium : FontWeight.Bold)
        .fontColor(danger ? this.dangerColor() : '#042F2E')
    }
    .width('100%')
    .height(48)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .backgroundColor(danger ? '#2B1B22' : this.accentColor())
    .borderRadius(12)
    .border({ width: 1, color: danger ? '#55303A' : this.accentColor() })
    .onClick(action)
  }

  @Builder DisabledActionButton(label: string) {
    Row() {
      Text(label)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor('#7D8998')
    }
    .width('100%')
    .height(48)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .backgroundColor('#242E3A')
    .borderRadius(12)
    .border({ width: 1, color: '#3A4757' })
  }

  @Builder StatusPills() {
    Row({ space: 8 }) {
      Row({ space: 6 }) {
        Text('●')
          .fontSize(8)
          .fontColor(this.stateAccentColor())
        Text('VPN：' + this.runtimeStateLabel(this.statusText))
          .fontSize(11)
          .fontColor(this.secondaryText())
          .maxLines(1)
      }
      .height(30)
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .padding({ left: 6, right: 6 })
      .backgroundColor(this.elevatedBg())
      .borderRadius(15)

      Row({ space: 6 }) {
        Text('●')
          .fontSize(8)
          .fontColor(this.coreText === 'Running' ? this.accentColor() : this.secondaryText())
        Text('核心：' + this.coreStateLabel(this.coreText))
          .fontSize(11)
          .fontColor(this.secondaryText())
          .maxLines(1)
      }
      .height(30)
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .padding({ left: 6, right: 6 })
      .backgroundColor(this.elevatedBg())
      .borderRadius(15)

      Row({ space: 6 }) {
        Text('●')
          .fontSize(8)
          .fontColor(this.accentColor())
        Text(this.proxyModeLabel(this.appSettings.proxyMode))
          .fontSize(11)
          .fontColor(this.secondaryText())
          .maxLines(1)
      }
      .height(30)
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .padding({ left: 6, right: 6 })
      .backgroundColor(this.elevatedBg())
      .borderRadius(15)
    }
    .width('100%')
  }

  @Builder ErrorBanner() {
    Column({ space: 4 }) {
      Text('运行异常')
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.dangerColor())
        .width('100%')
      Text(this.localizedMessage(this.lastError))
        .fontSize(12)
        .fontColor(this.secondaryText())
        .width('100%')
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#2B1B22')
    .borderRadius(12)
  }

  @Builder CurrentProxyCard() {
    Row({ space: 12 }) {
      Text('◎')
        .fontSize(26)
        .fontColor(this.accentColor())
        .width(38)
        .textAlign(TextAlign.Center)
      Column({ space: 4 }) {
        Text('当前节点 · ' + this.selectedProxyGroupLabel())
          .fontSize(11)
          .fontColor(this.mutedText())
        Text(this.selectedNodeName())
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryText())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.selectedNodeMeta())
          .fontSize(12)
          .fontColor(this.secondaryText())
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text('>')
        .fontSize(18)
        .fontColor(this.mutedText())
    }
    .width('100%')
    .height(82)
    .padding({ left: 14, right: 14 })
    .backgroundColor(this.surfaceBg())
    .borderRadius(12)
    .onClick(() => {
      this.selectSection(1);
    })
  }

  @Builder TrafficRow() {
    Row({ space: 10 }) {
      this.TrafficTile('下载 · ' + this.trafficSourceLabel(), this.formatBytes(this.downloadSpeed) + '/s')
      this.TrafficTile('上传 · ' + this.trafficSourceLabel(), this.formatBytes(this.uploadSpeed) + '/s')
      this.TrafficTile('今日', this.formatBytes(this.todayDownloadBytes + this.todayUploadBytes))
    }
    .width('100%')
  }

  @Builder TrafficTile(label: string, value: string) {
    Column({ space: 5 }) {
      Text(label)
        .fontSize(11)
        .fontColor(this.mutedText())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(value)
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.accentColor())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
    .padding(12)
    .backgroundColor(this.surfaceBg())
    .borderRadius(12)
  }

  @Builder ProfileChipsSection() {
    Column({ space: 8 }) {
      this.SectionTitle('配置', '')
      if (this.profiles.length === 0) {
        Row() {
          Text('暂无配置，请先新建')
            .fontSize(13)
            .fontColor(this.secondaryText())
            .layoutWeight(1)
          Text('新建 >')
            .fontSize(13)
            .fontColor(this.accentColor())
        }
        .height(48)
        .width('100%')
        .padding({ left: 12, right: 12 })
        .backgroundColor(this.elevatedBg())
        .borderRadius(10)
        .onClick(() => {
          this.selectSection(3);
        })
      } else if (this.profiles.length === 1) {
        Row({ space: 10 }) {
          Column({ space: 4 }) {
            Text(this.profileNameLabel(this.profiles[0]))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.accentColor())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text((this.profiles[0].type === 'subscription' ? '订阅' : '本地') + ' · ' +
              this.profileRuleText(this.profiles[0]) + ' · 当前')
              .fontSize(11)
              .fontColor('#78E2D5')
              .maxLines(1)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text('>')
            .fontSize(16)
            .fontColor(this.mutedText())
        }
        .height(58)
        .width('100%')
        .padding({ left: 12, right: 12 })
        .backgroundColor('#17302F')
        .borderRadius(10)
        .onClick(() => {
          this.selectSection(2);
        })
      } else {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(this.profiles, (p: Profile) => {
              Column({ space: 3 }) {
                Text(this.profileNameLabel(p))
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(p.id === this.activeProfileId ? this.accentColor() : this.secondaryText())
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text((p.type === 'subscription' ? '订阅' : '本地') + ' · ' + this.profileRuleText(p) +
                  ' · ' + (p.id === this.activeProfileId ? '当前' : this.profileRelativeText(p)))
                  .fontSize(10)
                  .fontColor(p.id === this.activeProfileId ? '#78E2D5' : this.mutedText())
                  .maxLines(1)
              }
              .height(48)
              .padding({ left: 12, right: 12, top: 7, bottom: 6 })
              .backgroundColor(p.id === this.activeProfileId ? '#17302F' : this.elevatedBg())
              .borderRadius(10)
              .onClick(() => {
                this.switchProfile(p.id);
              })
            }, (p: Profile) => p.id)
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
      }
    }
    .width('100%')
  }

  @Builder RouteModeSection() {
    Column({ space: 8 }) {
      this.SectionTitle('路由模式', '选择')
      Row() {
        Text(this.routeModeLabel(this.appSettings.routeMode))
          .fontSize(13)
          .fontColor(this.primaryText())
          .layoutWeight(1)
        Text('>')
          .fontSize(14)
          .fontColor(this.mutedText())
      }
      .height(44)
      .padding({ left: 12, right: 12 })
      .backgroundColor(this.inputBg())
      .borderRadius(10)
      .onClick(() => {
        this.openSettingsSelector('route');
      })
    }
    .width('100%')
  }

  @Builder EventSection() {
    Column({ space: 8 }) {
      this.SectionTitle('运行事件', '查看全部')
      Column() {
        if (this.runtimeEvents.length === 0) {
          Text('暂无运行事件')
            .fontSize(12)
            .fontColor(this.mutedText())
            .width('100%')
            .padding(12)
        } else {
          ForEach(this.runtimeEvents.slice(0, 1), (event: RuntimeEvent) => {
            Text(this.eventLineText(event))
              .fontSize(12)
              .fontColor(this.secondaryText())
              .width('100%')
              .padding({ left: 12, right: 12, top: 10, bottom: 10 })
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }, (event: RuntimeEvent) => event.timestamp.toString() + event.message)
        }
      }
      .width('100%')
      .backgroundColor(this.surfaceBg())
      .borderRadius(12)
      .onClick(() => {
        this.selectSection(4);
      })
    }
    .width('100%')
  }

  @Builder SectionTitle(title: string, action: string) {
    Row() {
      Text(title)
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.mutedText())
        .layoutWeight(1)
      if (action.length > 0) {
        Text(action)
          .fontSize(12)
          .fontColor(this.accentColor())
          .onClick(() => {
            if (title === '运行事件') {
              this.selectSection(4);
            }
          })
      }
    }
    .width('100%')
  }

  @Builder PageShell() {
    if (this.selectedSectionIndex === 0) {
      this.HomePage()
    } else if (this.selectedSectionIndex === 1) {
      this.ProxyPage()
    } else if (this.selectedSectionIndex === 2) {
      this.ConfigPage()
    } else if (this.selectedSectionIndex === 3) {
      this.CreateConfigPage()
    } else if (this.selectedSectionIndex === 4) {
      this.LogsPage()
    } else if (this.selectedSectionIndex === 5) {
      this.SettingsPage()
    } else if (this.selectedSectionIndex === 6) {
      this.HelpPage()
    } else if (this.selectedSectionIndex === 7) {
      this.AboutPage()
    } else if (this.selectedSectionIndex === 8) {
      this.EditConfigPage()
    } else if (this.selectedSectionIndex === 9) {
      this.DiagnosticsPage()
    }
  }

  @Builder ProxyPage() {
    Scroll() {
      Column({ space: 14 }) {
        if (this.activeProfileId.length === 0) {
          this.EmptyCard('暂无配置', '请先新建配置，再选择和测试代理节点')
          Button('新建配置')
            .height(44)
            .width('100%')
            .fontSize(14)
            .fontColor('#042F2E')
            .backgroundColor(this.accentColor())
            .borderRadius(10)
            .onClick(() => {
              this.selectSection(3);
            })
        } else {
          if (this.proxyGroups.length > 0) {
          Scroll() {
            Row({ space: 8 }) {
              ForEach(this.proxyGroups, (group: ProxyGroup) => {
                this.ProxyGroupChip(group)
              }, (group: ProxyGroup) => group.name)
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
          }

          TextInput({ text: this.nodeSearchText, placeholder: '搜索节点、类型或地址' })
          .height(44)
          .width('100%')
          .fontSize(13)
          .fontColor(this.primaryText())
          .placeholderColor(this.mutedText())
          .backgroundColor(this.inputBg())
          .borderRadius(10)
          .onChange((value: string) => {
            this.nodeSearchText = value;
          })

          Row({ space: 10 }) {
          Button(this.latencyBusy ? '测速中' : '测速全部')
            .height(42)
            .layoutWeight(1)
            .fontSize(13)
            .fontColor(this.accentColor())
            .backgroundColor(this.elevatedBg())
            .borderRadius(10)
            .enabled(!this.latencyBusy)
            .onClick(() => {
              this.testProxyLatency('all');
            })
          Button(this.latencyBusy ? '测速中' : '测速当前组')
            .height(42)
            .layoutWeight(1)
            .fontSize(13)
            .fontColor(this.accentColor())
            .backgroundColor(this.elevatedBg())
            .borderRadius(10)
            .enabled(!this.latencyBusy)
            .onClick(() => {
              this.testProxyLatency('group');
            })
          }
          .width('100%')

          this.SectionTitle(this.getFilteredNodes().length.toString() + ' / ' +
            this.getSelectedProxyGroupNodes().length.toString() + ' 个节点 · ' + this.selectedProxyGroupLabel(), '')

          this.ProxyGroupSummary()

          if (this.nodes.length === 0) {
            this.EmptyCard('暂无节点', '请先在配置页更新或导入包含 proxies 的配置')
          } else if (this.getFilteredNodes().length === 0) {
            this.EmptyCard('无匹配节点', '请调整搜索关键字')
          }

          ForEach(this.getFilteredNodes(), (node: ProxyNode) => {
            this.NodeRow(node)
          }, (node: ProxyNode) => node.group + '-' + node.name + '-' + (node.selected ? 'selected' : 'idle') +
            '-' + node.delay.toString())
        }
      }
      .width('100%')
      .constraintSize({ minHeight: '100%' })
      .padding({ left: 20, right: 20, bottom: 28 })
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
    .layoutWeight(1)
    .width('100%')
    .backgroundColor(this.appBg())
  }

  @Builder ModeChip(title: string, selected: boolean) {
    Text(title)
      .height(38)
      .layoutWeight(1)
      .textAlign(TextAlign.Center)
      .fontSize(14)
      .fontColor(selected ? '#042F2E' : this.secondaryText())
      .backgroundColor(selected ? this.accentColor() : this.elevatedBg())
      .borderRadius(10)
  }

  @Builder ProxyGroupChip(group: ProxyGroup) {
    Column({ space: 2 }) {
      Text(group.name)
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(group.name === this.selectedProxyGroupName ? '#042F2E' : this.secondaryText())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(group.type + ' · ' + group.nodes.length.toString())
        .fontSize(10)
        .fontColor(group.name === this.selectedProxyGroupName ? '#0F766E' : this.mutedText())
        .maxLines(1)
    }
    .height(48)
    .width(138)
    .justifyContent(FlexAlign.Center)
    .padding({ left: 10, right: 10 })
    .backgroundColor(group.name === this.selectedProxyGroupName ? this.accentColor() : this.elevatedBg())
    .borderRadius(10)
    .onClick(() => {
      this.selectProxyGroup(group.name);
    })
  }

  @Builder ProxyGroupSummary() {
    Row({ space: 12 }) {
      Text('◎')
        .fontSize(20)
        .fontColor(this.accentColor())
        .width(30)
        .textAlign(TextAlign.Center)
      Column({ space: 4 }) {
        Text(this.selectedProxyGroupLabel())
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryText())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('当前: ' + this.selectedNodeName())
          .fontSize(12)
          .fontColor(this.secondaryText())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text(this.selectedProxyGroupType())
        .fontSize(11)
        .fontColor(this.mutedText())
        .maxLines(1)
    }
    .width('100%')
    .height(66)
    .padding({ left: 12, right: 12 })
    .backgroundColor(this.surfaceBg())
    .borderRadius(12)
  }

  @Builder NodeRow(node: ProxyNode) {
    Row({ space: 12 }) {
      Text(node.selected ? '●' : '○')
        .fontSize(18)
        .fontColor(node.selected ? this.accentColor() : this.mutedText())
        .width(28)
        .textAlign(TextAlign.Center)
      Column({ space: 5 }) {
        Text(node.name)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryText())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(node.type.toUpperCase() + ' · ' + (node.server.length > 0 ? node.server : '未填写地址'))
          .fontSize(12)
          .fontColor(this.secondaryText())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text(node.delay > 0 ? node.delay.toString() + ' ms' : '--')
        .fontSize(12)
        .fontColor(this.accentColor())
        .width(58)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .height(76)
    .padding({ left: 12, right: 12 })
    .backgroundColor(this.surfaceBg())
    .borderRadius(12)
    .onClick(() => {
      this.selectProxyNode(node);
    })
  }

  @Builder ConfigPage() {
    if (this.isTabletLayout()) {
      Row({ space: 16 }) {
        Scroll() {
          Column({ space: 14 }) {
            this.ProfileListPanel()
            this.SubscriptionPanel()
          }
          .padding({ left: 20, bottom: 28 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)

        Scroll() {
          Column({ space: 14 }) {
            if (this.profiles.length > 0) {
              this.YamlEditorPanel()
            }
          }
          .padding({ right: 20, bottom: 28 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
      .layoutWeight(1)
      .backgroundColor(this.appBg())
    } else {
      Scroll() {
        Column({ space: 14 }) {
          this.ProfileListPanel()
          this.SubscriptionPanel()
          if (this.profiles.length > 0) {
            this.YamlEditorPanel()
          }
        }
        .width('100%')
        .constraintSize({ minHeight: '100%' })
        .padding({ left: 20, right: 20, bottom: 28 })
      }
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .width('100%')
      .backgroundColor(this.appBg())
    }
  }

  @Builder ProfileListPanel() {
    Column({ space: 10 }) {
      Row() {
        Text('配置列表')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.mutedText())
          .layoutWeight(1)
        Button('+ 新建')
          .height(32)
          .fontSize(12)
          .fontColor(this.accentColor())
          .backgroundColor(this.elevatedBg())
          .borderRadius(9)
          .enabled(!this.subBusy)
          .onClick(() => {
            this.subStatus = '';
            this.createMode = 1;
            this.selectSection(3);
          })
      }
      .width('100%')

      ForEach(this.profiles, (p: Profile) => {
        this.ProfileRow(p)
      }, (p: Profile) => p.id)

      if (this.profiles.length === 0) {
        Column({ space: 6 }) {
          Text('暂无配置')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.primaryText())
          Text('新建配置后即可连接 VPN')
            .fontSize(12)
            .fontColor(this.secondaryText())
        }
        .height(84)
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.surfaceBg())
        .borderRadius(12)
      }

      if (this.subStatus.length > 0) {
        Text(this.localizedMessage(this.subStatus))
          .fontSize(12)
          .fontColor(this.secondaryText())
          .width('100%')
          .padding(10)
          .backgroundColor(this.inputBg())
          .borderRadius(10)
      }
    }
    .width('100%')
  }

  @Builder ProfileRow(p: Profile) {
    Row({ space: 12 }) {
      Text(p.id === this.activeProfileId ? '●' : '○')
        .fontSize(18)
        .fontColor(p.id === this.activeProfileId ? this.accentColor() : this.mutedText())
        .width(28)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.switchProfile(p.id);
        })

      Column({ space: 5 }) {
        Text(this.profileNameLabel(p))
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryText())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.profileTypeLabel(p) + ' · ' + this.profileTrafficText(p) + ' · ' + this.profileRuleText(p))
          .fontSize(12)
          .fontColor(this.secondaryText())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.profileDateText(p))
          .fontSize(11)
          .fontColor(this.mutedText())
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .onClick(() => {
        this.switchProfile(p.id);
      })

      Button('...')
        .width(42)
        .height(42)
        .fontSize(14)
        .fontColor(this.secondaryText())
        .backgroundColor(this.inputBg())
        .borderRadius(10)
        .onClick(() => {
          this.openProfileActions(p.id);
        })
    }
    .width('100%')
    .height(92)
    .padding({ left: 12, right: 12 })
    .backgroundColor(p.id === this.activeProfileId ? '#17302F' : this.surfaceBg())
    .borderRadius(12)
  }

  @Builder SubscriptionPanel() {
    Column({ space: 10 }) {
      this.SectionTitle('订阅管理', '')
      TextInput({ text: this.subUrl, placeholder: 'https://example.com/sub.yaml' })
        .height(44)
        .width('100%')
        .fontSize(13)
        .fontColor(this.primaryText())
        .placeholderColor(this.mutedText())
        .backgroundColor(this.inputBg())
        .borderRadius(10)
        .onChange((value: string) => {
          this.subUrl = value;
        })
      Row({ space: 10 }) {
        Button('添加订阅')
          .height(42)
          .layoutWeight(1)
          .fontSize(13)
          .fontColor(this.accentColor())
          .backgroundColor(this.elevatedBg())
          .borderRadius(10)
          .enabled(!this.subBusy)
          .onClick(() => {
            this.addSubscription();
          })
        Button('刷新订阅')
          .height(42)
          .layoutWeight(1)
          .fontSize(13)
          .fontColor(this.accentColor())
          .backgroundColor(this.elevatedBg())
          .borderRadius(10)
          .enabled(!this.subBusy)
          .onClick(() => {
            this.refreshActiveConfig();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(12)
    .backgroundColor(this.surfaceBg())
    .borderRadius(12)
  }

  @Builder YamlEditorPanel() {
    Column({ space: 10 }) {
      Row() {
        Text('本地 YAML')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.mutedText())
          .layoutWeight(1)
        Button('校验')
          .height(32)
          .fontSize(12)
          .fontColor(this.accentColor())
          .backgroundColor(this.elevatedBg())
          .borderRadius(9)
          .onClick(() => {
            this.validateConfig();
          })
      }
      .width('100%')

      TextArea({ text: this.rawYaml, placeholder: 'Clash/mihomo YAML' })
        .height(this.isTabletLayout() ? 420 : 260)
        .width('100%')
        .fontSize(13)
        .fontColor(this.primaryText())
        .placeholderColor(this.mutedText())
        .backgroundColor(this.inputBg())
        .borderRadius(12)
        .onChange((value: string) => {
          this.rawYaml = value;
        })

      Row({ space: 10 }) {
        Button('导入文件')
          .height(42)
          .layoutWeight(1)
          .fontSize(13)
          .fontColor(this.secondaryText())
          .backgroundColor(this.elevatedBg())
          .borderRadius(10)
          .enabled(!this.subBusy)
          .onClick(() => {
            this.importLocalProfileFromFile();
          })
        Button('保存配置')
          .height(42)
          .layoutWeight(1)
          .fontSize(13)
          .fontColor('#042F2E')
          .backgroundColor(this.accentColor())
          .borderRadius(10)
          .onClick(() => {
            this.saveConfig();
          })
      }
      .width('100%')

      Text(this.localizedMessage(this.validationText))
        .fontSize(12)
        .fontColor(this.secondaryText())
        .width('100%')
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding(12)
    .backgroundColor(this.surfaceBg())
    .borderRadius(12)
  }

  @Builder CreateConfigPage() {
    Scroll() {
      Column({ space: 14 }) {
        this.CreateOptionRow('文件', '本地文件', '从文件导入', 0)
        this.CreateOptionRow('链接', '订阅链接', '从 URL 导入', 1)
        this.CreateOptionRow('扫码', '二维码', '扫描二维码导入', 2)

        Column({ space: 10 }) {
          Text(this.createModeSubtitle())
            .fontSize(13)
            .fontColor(this.secondaryText())
            .width('100%')

          if (this.createMode === 1) {
            TextInput({ text: this.newProfileName, placeholder: '配置名称' })
              .height(44)
              .width('100%')
              .fontSize(13)
              .fontColor(this.primaryText())
              .placeholderColor(this.mutedText())
              .backgroundColor(this.inputBg())
              .borderRadius(10)
              .onChange((value: string) => {
                this.newProfileName = value;
              })

            TextInput({ text: this.subUrl, placeholder: 'https://example.com/sub.yaml' })
              .height(44)
              .width('100%')
              .fontSize(13)
              .fontColor(this.primaryText())
              .placeholderColor(this.mutedText())
              .backgroundColor(this.inputBg())
              .borderRadius(10)
              .onChange((value: string) => {
                this.subUrl = value;
              })

            Button('创建')
              .height(44)
              .width('100%')
              .fontSize(14)
              .fontColor('#042F2E')
              .backgroundColor(this.subBusy ? '#31514F' : this.accentColor())
              .borderRadius(10)
              .enabled(!this.subBusy)
              .onClick(() => {
                this.addSubscription();
              })
          } else if (this.createMode === 0) {
            TextInput({ text: this.newProfileName, placeholder: '配置名称' })
              .height(44)
              .width('100%')
              .fontSize(13)
              .fontColor(this.primaryText())
              .placeholderColor(this.mutedText())
              .backgroundColor(this.inputBg())
              .borderRadius(10)
              .onChange((value: string) => {
                this.newProfileName = value;
              })

            Button('选择文件并导入')
              .height(44)
              .width('100%')
              .fontSize(14)
              .fontColor('#042F2E')
              .backgroundColor(this.subBusy ? '#31514F' : this.accentColor())
              .borderRadius(10)
              .enabled(!this.subBusy)
              .onClick(() => {
                this.importLocalProfileFromFile();
              })
          } else if (this.createMode === 2) {
            TextInput({ text: this.newProfileName, placeholder: '配置名称' })
              .height(44)
              .width('100%')
              .fontSize(13)
              .fontColor(this.primaryText())
              .placeholderColor(this.mutedText())
              .backgroundColor(this.inputBg())
              .borderRadius(10)
              .onChange((value: string) => {
                this.newProfileName = value;
              })

            Button('扫码并创建')
              .height(44)
              .width('100%')
              .fontSize(14)
              .fontColor('#042F2E')
              .backgroundColor(this.subBusy ? '#31514F' : this.accentColor())
              .borderRadius(10)
              .enabled(!this.subBusy)
              .onClick(() => {
                this.scanAndCreateSubscription();
              })
          }

          if (this.subStatus.length > 0) {
            Text(this.localizedMessage(this.subStatus))
              .fontSize(12)
              .fontColor(this.secondaryText())
              .width('100%')
          }
        }
        .width('100%')
        .padding(12)
        .backgroundColor(this.surfaceBg())
        .borderRadius(12)
      }
      .width('100%')
      .constraintSize({ minHeight: '100%' })
      .padding({ left: 20, right: 20, bottom: 28 })
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
    .layoutWeight(1)
    .width('100%')
    .backgroundColor(this.appBg())
  }

  @Builder CreateOptionRow(icon: string, title: string, subtitle: string, mode: number) {
    Row({ space: 12 }) {
      Text(icon)
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.accentColor())
        .width(54)
        .textAlign(TextAlign.Center)
      Column({ space: 4 }) {
        Text(title)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryText())
          .maxLines(1)
        Text(subtitle)
          .fontSize(12)
          .fontColor(this.secondaryText())
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .height(72)
    .width('100%')
    .padding({ left: 12, right: 12 })
    .backgroundColor(this.createMode === mode ? '#17302F' : this.surfaceBg())
    .borderRadius(12)
    .onClick(() => {
      this.createMode = mode;
    })
  }

  @Builder EditConfigPage() {
    Scroll() {
      Column({ space: 14 }) {
        this.YamlEditorPanel()
      }
      .width('100%')
      .constraintSize({ minHeight: '100%' })
      .padding({ left: 20, right: 20, bottom: 28 })
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Auto)
    .layoutWeight(1)
    .width('100%')
    .backgroundColor(this.appBg())
  }

  @Builder LogsPage() {
    Scroll(this.logsScroller) {
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          this.LogFilterChip('全部', 'all')
          this.LogFilterChip('信息', 'info')
          this.LogFilterChip('警告', 'warn')
          this.LogFilterChip('错误', 'error')
        }
        .width('100%')

        TextInput({ text: this.logSearchText, placeholder: '搜索日志' })
          .height(42)
          .fontSize(13)
          .fontColor(this.primaryText())
          .placeholderColor(this.mutedText())
          .backgroundColor(this.inputBg())
          .borderRadius(10)
          .padding({ left: 12, right: 12 })
          .onChange((value: string) => {
            this.updateLogSearch(value);
          })

        Row({ space: 8 }) {
          Button(this.logFollow ? '实时追踪: 开' : '实时追踪: 关')
            .height(34)
            .fontSize(12)
            .fontColor(this.logFollow ? this.accentColor() : this.secondaryText())
            .backgroundColor(this.elevatedBg())
            .borderRadius(10)
            .onClick(() => {
              this.toggleLogFollow();
            })
          Button('复制诊断')
            .height(34)
            .fontSize(12)
            .fontColor(this.accentColor())
            .backgroundColor(this.elevatedBg())
            .borderRadius(10)
            .onClick(() => {
              this.copyDiagnosticText();
            })
          Button('导出')
            .height(34)
            .fontSize(12)
            .fontColor(this.accentColor())
            .backgroundColor(this.elevatedBg())
            .borderRadius(10)
            .onClick(() => {
              this.exportDiagnostics();
            })
        }
        .width('100%')

        if (this.lastDiagnosticPath.length > 0) {
          Text(this.lastDiagnosticPath)
            .fontSize(11)
            .fontColor(this.mutedText())
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }

        ForEach(this.getFilteredRuntimeEvents(), (event: RuntimeEvent) => {
          this.LogEventRow(event)
        }, (event: RuntimeEvent) => event.timestamp.toString() + event.message)
      }
      .width('100%')
      .constraintSize({ minHeight: '100%' })
      .padding({ left: 20, right: 20, bottom: 28 })
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Auto)
    .onWillScroll((_xOffset: number, _yOffset: number, _scrollState: ScrollState, source: ScrollSource) => {
      this.pauseLogFollowForUserScroll(source);
    })
    .layoutWeight(1)
    .width('100%')
    .backgroundColor(this.appBg())
  }

  @Builder LogFilterChip(label: string, level: string) {
    Text(label)
      .fontSize(12)
      .fontColor(this.logLevelFilter === level ? this.accentColor() : this.secondaryText())
      .height(32)
      .padding({ left: 12, right: 12 })
      .backgroundColor(this.logLevelFilter === level ? '#17302F' : this.elevatedBg())
      .borderRadius(10)
      .onClick(() => {
        this.setLogLevelFilter(level);
      })
  }

  @Builder LogEventRow(event: RuntimeEvent) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(this.eventLevelLabel(event.level))
          .fontSize(10)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.eventToneColor(event.level))
        Text(this.eventSourceLabel(event.source))
          .fontSize(10)
          .fontColor(this.mutedText())
        Text(this.eventTimeText(event))
          .fontSize(10)
          .fontColor(this.mutedText())
          .layoutWeight(1)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      Text(this.localizedMessage(event.message))
        .fontSize(12)
        .fontColor(this.secondaryText())
        .width('100%')
        .maxLines(4)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor(this.surfaceBg())
    .borderRadius(10)
  }

  @Builder SettingsPage() {
    Scroll() {
      Column({ space: 14 }) {
        this.SettingsGroup('代理模式')
        this.ProxyModeSettingRow()
        this.RouteModeSettingRow()
        this.DnsModeSettingRow()
        this.LogLevelSettingRow()
        this.SettingsGroup('网络')
        this.ToggleSettingRow('IPv6', '写入运行时 YAML，并传入 VPN 配置', 'ipv6')
        this.ToggleSettingRow('UDP 转发', '保存到连接设置，用于后续原生 UDP 策略', 'udp')
        this.ToggleSettingRow('连接前自动更新订阅', '失败时沿用上一次可用的运行时配置', 'autoRefresh')
        this.SettingsGroup('诊断')
        this.SettingsActionRow('运行状态', 'VPN：' + this.runtimeStateLabel(this.statusText) + ' / 核心：' +
          this.coreStateLabel(this.coreText), '查看', () => {
          this.selectSection(9);
        })
        this.SettingsRow('VPN DNS', '传给 VPN 扩展的 DNS 地址', this.appSettings.vpnDnsAddress)
        this.SettingsActionRow('帮助', '配置、连接与诊断说明', '查看', () => {
          this.selectSection(6);
        })
        this.SettingsActionRow('ClashGuard', 'v1.0.0', '关于', () => {
          this.selectSection(7);
        })
        this.SettingsGroup('存储')
        this.SettingsActionRow('清理缓存', '保留配置和今日流量', '清理', () => {
          this.confirmClearCache();
        })
        this.SettingsActionRow('重置全部配置', '删除配置、订阅、设置与记录', '重置', () => {
          this.confirmResetAllConfiguration();
        })
      }
      .width('100%')
      .constraintSize({ minHeight: '100%' })
      .padding({ left: 20, right: 20, bottom: 28 })
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
    .layoutWeight(1)
    .width('100%')
    .backgroundColor(this.appBg())
  }

  @Builder SettingsGroup(title: string) {
    Text(title)
      .fontSize(11)
      .fontWeight(FontWeight.Bold)
      .fontColor(this.mutedText())
      .width('100%')
      .padding({ top: 6 })
  }

  @Builder ProxyModeSettingRow() {
    Row({ space: 12 }) {
      this.SettingsRowText('启动模式', '规则 / 全局 / 直连会写入运行时 YAML')
      Text(this.proxyModeLabel(this.appSettings.proxyMode))
        .fontSize(12)
        .fontColor(this.accentColor())
        .maxLines(1)
    }
    .height(62)
    .width('100%')
    .padding({ left: 12, right: 12 })
    .backgroundColor(this.surfaceBg())
    .borderRadius(12)
    .onClick(() => {
      this.openSettingsSelector('proxy');
    })
  }

  @Builder RouteModeSettingRow() {
    Row({ space: 12 }) {
      this.SettingsRowText('VPN 路由', '决定 VPN 扩展下发的路由策略')
      Column({ space: 2 }) {
        Text(this.routeModeLabel(this.appSettings.routeMode))
          .fontSize(12)
          .fontColor(this.accentColor())
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.End)
    }
    .height(62)
    .width('100%')
    .padding({ left: 12, right: 12 })
    .backgroundColor(this.surfaceBg())
    .borderRadius(12)
    .onClick(() => {
      this.openSettingsSelector('route');
    })
  }

  @Builder DnsModeSettingRow() {
    Row({ space: 12 }) {
      this.SettingsRowText('DNS 模式', 'default/fake-ip/redir-host 会写入运行时 YAML')
      Text(this.dnsModeLabel(this.appSettings.dnsMode))
        .fontSize(12)
        .fontColor(this.accentColor())
        .maxLines(1)
    }
    .height(62)
    .width('100%')
    .padding({ left: 12, right: 12 })
    .backgroundColor(this.surfaceBg())
    .borderRadius(12)
    .onClick(() => {
      this.cycleDnsMode();
    })
  }

  @Builder LogLevelSettingRow() {
    Row({ space: 12 }) {
      this.SettingsRowText('日志级别', '写入运行时 YAML 的 log-level')
      Text(this.eventLevelLabel(this.appSettings.logLevel))
        .fontSize(12)
        .fontColor(this.accentColor())
        .maxLines(1)
    }
    .height(62)
    .width('100%')
    .padding({ left: 12, right: 12 })
    .backgroundColor(this.surfaceBg())
    .borderRadius(12)
    .onClick(() => {
      this.cycleLogLevel();
    })
  }

  @Builder ToggleSettingRow(title: string, subtitle: string, key: string) {
    Row({ space: 12 }) {
      this.SettingsRowText(title, subtitle)
      Text(this.onOffLabel(this.settingFlagValue(key)))
        .fontSize(12)
        .fontColor(this.settingFlagValue(key) ? this.accentColor() : this.secondaryText())
        .maxLines(1)
    }
    .height(62)
    .width('100%')
    .padding({ left: 12, right: 12 })
    .backgroundColor(this.surfaceBg())
    .borderRadius(12)
    .onClick(() => {
      this.toggleSettingFlag(key);
    })
  }

  @Builder SettingsRowText(title: string, subtitle: string) {
    Column({ space: 4 }) {
      Text(title)
        .fontSize(14)
        .fontColor(this.primaryText())
        .maxLines(1)
      Text(subtitle)
        .fontSize(11)
        .fontColor(this.mutedText())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
  }

  @Builder SettingsRow(title: string, subtitle: string, value: string) {
    Row({ space: 12 }) {
      this.SettingsRowText(title, subtitle)
      Text(value)
        .fontSize(12)
        .fontColor(this.secondaryText())
        .maxLines(1)
    }
    .height(62)
    .width('100%')
    .padding({ left: 12, right: 12 })
    .backgroundColor(this.surfaceBg())
    .borderRadius(12)
  }

  @Builder SettingsActionRow(title: string, subtitle: string, value: string, action: () => void) {
    Row({ space: 12 }) {
      this.SettingsRowText(title, subtitle)
      Text(value)
        .fontSize(12)
        .fontColor(title === '重置全部配置' ? this.dangerColor() : this.accentColor())
        .maxLines(1)
    }
    .height(62)
    .width('100%')
    .padding({ left: 12, right: 12 })
    .backgroundColor(this.surfaceBg())
    .borderRadius(12)
    .onClick(action)
  }

  @Builder DiagnosticsPage() {
    Scroll() {
      Column({ space: 12 }) {
        Row({ space: 8 }) {
          Button('复制诊断')
            .height(34)
            .fontSize(12)
            .fontColor(this.accentColor())
            .backgroundColor(this.elevatedBg())
            .borderRadius(10)
            .onClick(() => {
              this.copyDiagnosticText();
            })
          Button('导出诊断')
            .height(34)
            .fontSize(12)
            .fontColor(this.accentColor())
            .backgroundColor(this.elevatedBg())
            .borderRadius(10)
            .onClick(() => {
              this.exportDiagnostics();
            })
        }
        .width('100%')

        this.DiagCard('运行快照', 'VPN：' + this.runtimeStateLabel(this.statusText) + ' · 核心：' +
          this.coreStateLabel(this.coreText), '更新时间：' + this.snapshotUpdatedText() + ' · 启动时间：' +
          this.startedAtText())
        this.DiagCard('Mihomo 核心', '版本：' + this.mihomoVersionText(),
          '平滑停止：' + this.gracefulStopText())
        this.DiagCard('当前配置', this.activeProfileLabel(), this.activeProfileId)
        this.DiagCard('当前节点', this.selectedProxyGroupLabel() + ' / ' + this.selectedNodeName(), this.selectedNodeMeta())
        this.DiagCard('通信桥接', 'TUN 文件描述符：' + this.tunFdText(), '保护钩子：' + this.protectHookText())
        this.DiagCard('流量统计', '来源=' + this.trafficSourceLabel() + ' · 下载=' +
          this.formatRate(this.downloadSpeed) + ' · 上传=' + this.formatRate(this.uploadSpeed),
          '今日=' + this.formatBytes(this.todayDownloadBytes + this.todayUploadBytes))
        this.DiagCard('设置', '路由=' + this.routeModeLabel(this.appSettings.routeMode) + ' · 模式=' +
          this.proxyModeLabel(this.appSettings.proxyMode), 'DNS=' + this.appSettings.dnsMode + ' · 日志=' +
          this.eventLevelLabel(this.appSettings.logLevel))
        this.DiagCard('最近错误', this.lastError.length > 0 ? this.localizedMessage(this.lastError) : '无',
          this.runtimeEvents.length > 0 ? this.localizedMessage(this.runtimeEvents[0].message) : '暂无事件')
        this.DiagCard('功能自检', this.pocSmokeSummary(), '脚本摘要未接入时显示未运行')
        if (this.lastDiagnosticPath.length > 0) {
          this.DiagCard('导出文件', this.lastDiagnosticPath, '包含运行快照、设置、当前配置和最近 60 条事件')
        }
        if (this.diagnosticText.length > 0) {
          this.DiagCard('诊断摘要', this.diagnosticText.substring(0, Math.min(80, this.diagnosticText.length)),
            '完整内容已复制到系统剪贴板')
        }
      }
      .width('100%')
      .constraintSize({ minHeight: '100%' })
      .padding({ left: 20, right: 20, bottom: 28 })
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
    .layoutWeight(1)
    .width('100%')
    .backgroundColor(this.appBg())
  }

  @Builder DiagCard(title: string, first: string, second: string) {
    Column({ space: 8 }) {
      Text(title)
        .fontSize(11)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.mutedText())
        .width('100%')
      Text(first)
        .fontSize(14)
        .fontColor(this.primaryText())
        .width('100%')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(second)
        .fontSize(12)
        .fontColor(this.secondaryText())
        .width('100%')
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding(12)
    .backgroundColor(this.surfaceBg())
    .borderRadius(12)
  }

  @Builder HelpPage() {
    Column({ space: 12 }) {
      this.DiagCard('帮助', '配置页用于管理 Clash/mihomo YAML 或 URL 订阅。', '连接后首页会展示状态、节点和运行事件。')
      this.DiagCard('VPN 路由', '全量接管(推荐)：接管全部 IPv4 流量。',
        '分段默认路由适用于兼容性场景；其他路由模式主要用于诊断。“阻塞”指 TUN 读写方式。')
      this.DiagCard('启动模式', '规则(推荐)：按配置规则选择代理或直连。',
        '全局：统一使用全局代理节点。直连：不通过代理节点。')
    }
    .width('100%')
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .padding(20)
    .backgroundColor(this.appBg())
  }

  @Builder AboutPage() {
    Scroll() {
      Column({ space: 12 }) {
        this.DiagCard('ClashGuard', '版本 1.0.0', '基于 mihomo 的 HarmonyOS VPN 客户端')
        this.DiagCard('隐私政策', '应用不收集账号、设备标识或使用统计。',
          '订阅地址仅用于用户主动更新；诊断文件仅在用户主动操作时生成。')
        this.DiagCard('开源许可', 'ClashGuard：GNU AGPL v3', 'mihomo 核心：GNU GPL v3')
        this.DiagCard('版权与担保', '© 2026 ClashGuard contributors', '本软件按“原样”提供，不附带任何担保。')
        this.DiagCard('源代码', 'github.com/fly2016git/mihomo_client_ohos',
          '完整隐私政策：仓库根目录 PRIVACY.md')
      }
      .width('100%')
      .constraintSize({ minHeight: '100%' })
      .padding({ left: 20, right: 20, bottom: 28 })
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
    .width('100%')
    .layoutWeight(1)
    .backgroundColor(this.appBg())
  }

  @Builder EmptyCard(title: string, subtitle: string) {
    Column({ space: 8 }) {
      Text(title)
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.primaryText())
      Text(subtitle)
        .fontSize(12)
        .fontColor(this.secondaryText())
        .textAlign(TextAlign.Center)
        .maxLines(2)
    }
    .width('100%')
    .height(150)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.surfaceBg())
    .borderRadius(12)
  }

  @Builder SettingsSelectionSheet() {
    Column() {
      Blank()
        .layoutWeight(1)
        .onClick(() => {
          this.closeSettingsSelector();
        })

      Column({ space: 12 }) {
        Row()
          .width(54)
          .height(5)
          .backgroundColor(this.mutedText())
          .borderRadius(3)

        Row({ space: 12 }) {
          Column({ space: 3 }) {
            Text(this.settingsSelector === 'route' ? 'VPN 路由' : '启动模式')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.primaryText())
            Text(this.settingsSelector === 'route' ? '选择系统流量进入 VPN 的路由方式' : '选择 mihomo 处理已接管流量的方式')
              .fontSize(11)
              .fontColor(this.secondaryText())
              .maxLines(1)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Row() {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(18)
              .fontColor([this.secondaryText()])
          }
          .width(36)
          .height(36)
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .backgroundColor(this.elevatedBg())
          .borderRadius(10)
          .onClick(() => {
            this.closeSettingsSelector();
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (this.settingsSelector === 'route') {
          Column({ space: 4 }) {
            this.SettingsModeOption('全量接管(推荐)', '接管全部 IPv4 流量，适合日常使用',
              this.appSettings.routeMode === 'blocking-default', () => {
                this.selectRouteMode('blocking-default');
              })
            this.SettingsModeOption('分段默认路由', '分段接管全部 IPv4 流量，用于兼容性场景',
              this.appSettings.routeMode === 'split-default', () => {
                this.selectRouteMode('split-default');
              })
            this.SettingsModeOption('系统默认路由', '使用一条默认路由接管全部 IPv4 流量',
              this.appSettings.routeMode === 'default', () => {
                this.selectRouteMode('default');
              })
            this.SettingsModeOption('不下发路由', '不接管普通流量，仅用于诊断', this.appSettings.routeMode === 'no-routes', () => {
              this.selectRouteMode('no-routes');
            })
            this.SettingsModeOption('排除局域网', '当前仅路由 VPN 自身网段，实验模式', this.appSettings.routeMode === 'exclude-local', () => {
              this.selectRouteMode('exclude-local');
            })
            this.SettingsModeOption('阻塞分段路由', '分段接管全部 IPv4，TUN 使用阻塞读写',
              this.appSettings.routeMode === 'blocking-split', () => {
                this.selectRouteMode('blocking-split');
              })
            this.SettingsModeOption('阻塞空路由', '不下发路由，TUN 使用阻塞读写，仅用于诊断',
              this.appSettings.routeMode === 'blocking-empty', () => {
                this.selectRouteMode('blocking-empty');
              })
          }
          .width('100%')

          Text('“阻塞”指 TUN 文件描述符的读写方式，不代表阻止网络访问。')
            .fontSize(11)
            .fontColor(this.mutedText())
            .width('100%')
            .maxLines(2)
        } else {
          Column({ space: 4 }) {
            this.SettingsModeOption('规则(推荐)', '按配置规则决定代理或直连，适合日常使用',
              this.appSettings.proxyMode === 'rule', () => {
                this.selectProxyMode('rule');
              })
            this.SettingsModeOption('全局', '所有已接管流量统一通过全局代理节点', this.appSettings.proxyMode === 'global', () => {
              this.selectProxyMode('global');
            })
            this.SettingsModeOption('直连', '流量由 mihomo 直接连接，不经过代理节点', this.appSettings.proxyMode === 'direct', () => {
              this.selectProxyMode('direct');
            })
          }
          .width('100%')
        }
      }
      .width('100%')
      .height(this.settingsSelector === 'route' ? 620 : 330)
      .padding({ left: 20, right: 20, top: 18, bottom: 30 })
      .backgroundColor(this.surfaceBg())
      .borderRadius({ topLeft: 22, topRight: 22 })
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('#99000000')
  }

  @Builder SettingsModeOption(title: string, description: string, selected: boolean, action: () => void) {
    Row({ space: 12 }) {
      Column({ space: 3 }) {
        Text(title)
          .fontSize(14)
          .fontWeight(selected ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(selected ? this.accentColor() : this.primaryText())
          .width('100%')
          .maxLines(1)
        Text(description)
          .fontSize(11)
          .fontColor(this.secondaryText())
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.checkmark'))
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor([selected ? this.accentColor() : '#00000000'])
        .width(24)
    }
    .width('100%')
    .height(60)
    .padding({ left: 12, right: 12 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(selected ? '#17302F' : '#00000000')
    .borderRadius(10)
    .onClick(action)
  }

  @Builder ProfileActionSheet() {
    Column() {
      Blank()
        .layoutWeight(1)
        .onClick(() => {
          this.closeProfileActions();
        })

      Column({ space: 14 }) {
        Row()
          .width(54)
          .height(5)
          .backgroundColor(this.mutedText())
          .borderRadius(3)

        this.SheetActionRow('更新', this.primaryText(), () => {
          const p = this.getProfileById(this.sheetProfileId);
          this.closeProfileActions();
          if (p && p.type === 'subscription') {
            this.refreshSubscription(p.id);
          } else {
            this.refreshActiveConfig();
          }
        })
        this.SheetActionRow('编辑', this.primaryText(), () => {
          this.editProfile(this.sheetProfileId);
        })
        this.SheetActionRow('复制', this.primaryText(), () => {
          this.duplicateProfile(this.sheetProfileId);
        })
        this.SheetActionRow('删除', this.canDeleteProfile(this.sheetProfileId) ? this.dangerColor() : this.mutedText(), () => {
          if (this.canDeleteProfile(this.sheetProfileId)) {
            this.confirmDeleteProfile(this.sheetProfileId);
          }
        })
      }
      .width('100%')
      .padding({ left: 28, right: 28, top: 18, bottom: 30 })
      .backgroundColor(this.surfaceBg())
      .borderRadius({ topLeft: 22, topRight: 22 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#99000000')
  }

  @Builder SheetActionRow(title: string, color: string, action: () => void) {
    Row() {
      Text(title)
        .fontSize(17)
        .fontColor(color)
        .layoutWeight(1)
        .maxLines(1)
    }
    .height(48)
    .width('100%')
    .onClick(action)
  }

  @Builder BottomNav() {
    Row() {
      this.NavItem(0, '首页')
      this.NavItem(1, '节点')
      this.NavItem(2, '配置')
      this.NavItem(4, '日志')
      this.NavItem(5, '设置')
    }
    .height(70)
    .width('100%')
    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(this.appBg())
  }

  @Builder TabletSidebar() {
    Column({ space: 8 }) {
      Text('CG')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.accentColor())
        .height(48)
      this.SideNavItem(0, '首页')
      this.SideNavItem(1, '节点')
      this.SideNavItem(2, '配置')
      this.SideNavItem(4, '日志')
      this.SideNavItem(5, '设置')
      Blank()
      this.SideNavItem(9, '诊断')
    }
    .width(112)
    .height('100%')
    .padding({ left: 12, right: 12, top: 16, bottom: 16 })
    .backgroundColor('#0B1016')
  }

  @Builder NavItem(index: number, label: string) {
    Column() {
      Column({ space: 2 }) {
        Row()
          .width(22)
          .height(3)
          .backgroundColor(this.selectedSectionIndex === index ? this.accentColor() : '#00000000')
          .borderRadius(2)
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph(this.navIcon(index))
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor([this.selectedSectionIndex === index ? this.accentColor() : this.secondaryText()])
        }
        .width(32)
        .height(24)
        Text(label)
          .fontSize(12)
          .lineHeight(18)
          .fontColor(this.selectedSectionIndex === index ? this.accentColor() : this.secondaryText())
          .width(56)
          .height(18)
          .textAlign(TextAlign.Center)
          .maxLines(1)
      }
      .width(56)
      .height(51)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .layoutWeight(1)
    .height(54)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('#00000000')
    .onClick(() => {
      this.selectSection(index);
    })
  }

  @Builder SideNavItem(index: number, label: string) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor(this.selectedSectionIndex === index ? this.accentColor() : this.secondaryText())
        .layoutWeight(1)
        .maxLines(1)
    }
    .height(42)
    .width('100%')
    .padding({ left: 12, right: 12 })
    .backgroundColor(this.selectedSectionIndex === index ? '#17302F' : '#00000000')
    .borderRadius(10)
    .onClick(() => {
      this.selectSection(index);
    })
  }

  @Builder EdgeBackGestureArea() {
    Row()
      .width(28)
      .height('100%')
      .backgroundColor('#01000000')
      .zIndex(100)
      .gesture(
        PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 8 })
          .onActionEnd((event: GestureEvent) => {
            if (event.offsetX >= 72 && Math.abs(event.offsetY) <= 60) {
              this.navigateBack();
            }
          })
      )
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.isTabletLayout()) {
        Row() {
          this.TabletSidebar()
          Column() {
            this.AppHeader()
            this.PageShell()
          }
          .height('100%')
          .layoutWeight(1)
          .backgroundColor(this.appBg())
        }
        .height('100%')
        .width('100%')
        .backgroundColor(this.appBg())
      } else {
        Column() {
          this.AppHeader()
          this.PageShell()
          this.BottomNav()
        }
        .height('100%')
        .width('100%')
        .backgroundColor(this.appBg())
      }

      if (this.sheetVisible) {
        this.ProfileActionSheet()
      }

      if (this.settingsSelector.length > 0) {
        this.SettingsSelectionSheet()
      }

      if (!this.isTabletLayout() &&
        (this.selectedSectionIndex !== 0 || this.sheetVisible || this.settingsSelector.length > 0)) {
        this.EdgeBackGestureArea()
      }
    }
    .height('100%')
    .width('100%')
    .backgroundColor(this.appBg())
    .onAreaChange((_oldArea, newArea) => {
      this.rootWidth = Number(newArea.width);
    })
    .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean, _currentRatio: number) => {
      if (!isVisible) {
        return;
      }
      this.refreshRuntimeView(true);
      setTimeout(() => {
        this.refreshRuntimeView(true);
      }, 500);
    })
  }
}
