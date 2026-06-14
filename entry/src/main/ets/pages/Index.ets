import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import pasteboard from '@ohos.pasteboard';
import { ConfigService } from '../config/ConfigService';
import {
  AppSettings,
  DEFAULT_APP_SETTINGS,
  DnsMode,
  LogLevel,
  Profile,
  ProxyGroup,
  ProxyLatencyRecord,
  ProxyLatencyState,
  ProxyMode,
  ProxyNode,
  RuntimeEvent,
  RuntimeEventLevel,
  RuntimeSnapshot,
  VpnRouteMode
} from '../models/MvpTypes';
import { RuntimeStore } from '../runtime/RuntimeStore';
import { SettingsService } from '../settings/SettingsService';
import { SubscriptionService } from '../subscription/SubscriptionService';
import { VpnControlService } from '../runtime/VpnControlService';

const DOMAIN = 0x0001;
const TAG = 'MihomoMvpPage';

@Entry
@Component
struct Index {
  @State statusText: string = 'Idle';
  @State coreText: string = 'Stopped';
  @State activeProfileName: string = 'Default';
  @State activeProfileId: string = '';
  @State lastError: string = '';
  @State rawYaml: string = '';
  @State events: string[] = [];
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
  @State nodes: ProxyNode[] = [];
  @State proxyGroups: ProxyGroup[] = [];
  @State selectedProxyGroupName: string = '';
  @State nodeSearchText: string = '';
  @State proxyDelayRecords: ProxyLatencyRecord[] = [];
  @State latencyBusy: boolean = false;
  @State sheetVisible: boolean = false;
  @State sheetProfileId: string = '';
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

  private configService?: ConfigService;
  private runtimeStore?: RuntimeStore;
  private vpnControlService?: VpnControlService;
  private subscriptionService?: SubscriptionService;
  private settingsService?: SettingsService;
  private logsScroller: Scroller = new Scroller();
  private pollTimer: number = -1;

  aboutToAppear(): void {
    const context = getContext(this) as common.UIAbilityContext;
    const filesDir = context.filesDir;
    this.configService = new ConfigService(filesDir);
    this.runtimeStore = new RuntimeStore(filesDir);
    this.vpnControlService = new VpnControlService(filesDir, context);
    this.subscriptionService = new SubscriptionService(filesDir);
    this.settingsService = new SettingsService(filesDir);
    const profile = this.configService.ensureDefaultProfile();
    this.activeProfileId = profile.id;
    this.rawYaml = this.configService.loadRawYaml(profile.id);
    this.loadSettings();
    this.reloadProfiles();
    this.markRestoredRuntimeUnknown();
    this.refreshState();
    this.pollTimer = setInterval(() => {
      this.refreshState();
    }, 1200);
  }

  aboutToDisappear(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private reloadProfiles(): void {
    if (!this.configService) {
      return;
    }
    this.profiles = this.configService.listProfiles();
    const active = this.configService.getActiveProfile();
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
    const rawYaml = this.configService.loadRawYaml(profile.id);
    const validation = this.configService.validateRawYaml(rawYaml);
    if (!validation.ok) {
      this.validationText = validation.errors.join('; ');
      return;
    }
    this.configService.writeTextFile(profile.runtimePath,
      this.configService.generateRuntimeYaml(rawYaml, this.appSettings));
  }

  private refreshState(): void {
    if (!this.runtimeStore || !this.configService) {
      return;
    }
    try {
      const snapshot = this.runtimeStore.getSnapshot();
      this.applySnapshot(snapshot);
      this.events = this.runtimeStore.getEvents();
      this.runtimeEvents = this.runtimeStore.getRuntimeEvents();
      this.reloadProfiles();
      if (this.selectedSectionIndex === 4 && this.logFollow) {
        this.logsScroller.scrollEdge(Edge.Top);
      }
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
    this.activeProfileId = snapshot.activeProfileId;
    this.activeProfileName = snapshot.activeProfileName || this.activeProfileName || 'Default';
    this.lastError = snapshot.lastError;
    this.uploadSpeed = snapshot.uploadSpeed;
    this.downloadSpeed = snapshot.downloadSpeed;
    if (this.lastError.length === 0 && snapshot.lastEvent.length > 0) {
      this.validationText = snapshot.lastEvent;
    }
  }

  private saveConfig(): void {
    if (!this.configService || !this.runtimeStore) {
      return;
    }
    try {
      const targetId = this.editProfileId.length > 0 ? this.editProfileId : this.activeProfileId;
      const result = this.configService.saveRawYaml(targetId, this.rawYaml);
      if (result.ok) {
        this.validationText = '配置已保存';
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

  private validateConfig(): void {
    if (!this.configService || !this.runtimeStore) {
      return;
    }
    const result = this.configService.validateRawYaml(this.rawYaml);
    this.validationText = result.ok ? '配置校验通过' : result.errors.join('; ');
    this.runtimeStore.appendEvent(result.ok ? 'Config validation ok' : 'Config validation failed');
    this.refreshState();
  }

  private async connect(): Promise<void> {
    if (!this.vpnControlService || !this.configService) {
      return;
    }
    this.busy = true;
    try {
      const profile: Profile = this.configService.getActiveProfile();
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
    return !this.busy && (this.statusText === 'Idle' || this.statusText === 'Error' || this.statusText === 'Unknown');
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

  private selectSection(index: number): void {
    this.selectedSectionIndex = index;
    this.sheetVisible = false;
    if (index === 0 || index === 1 || index === 2) {
      this.reloadProfiles();
    }
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

  private statusTitleText(): string {
    if (this.statusText === 'Connected') {
      return '运行中';
    }
    if (this.statusText === 'Starting') {
      return '启动中';
    }
    if (this.statusText === 'Stopping') {
      return '停止中';
    }
    if (this.statusText === 'Error') {
      return '异常';
    }
    if (this.statusText === 'Unknown') {
      return '待确认';
    }
    return '已停止';
  }

  private statusSubtitleText(): string {
    if (this.statusText === 'Connected') {
      return this.formatBytes(this.uploadSpeed + this.downloadSpeed) + ' 已转发';
    }
    if (this.statusText === 'Starting' || this.statusText === 'Stopping') {
      return this.validationText;
    }
    if (this.statusText === 'Error') {
      return this.lastError.length > 0 ? this.lastError : '请查看日志';
    }
    if (this.statusText === 'Unknown') {
      return '点此重新确认或断开';
    }
    return '点此启动';
  }

  private toggleRuntime(): void {
    if (this.canConnect()) {
      this.connect();
      return;
    }
    if (this.canDisconnect()) {
      this.disconnect();
    }
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

  private profileTypeLabel(profile: Profile): string {
    return profile.type === 'subscription' ? 'URL' : 'LOCAL';
  }

  private profileTrafficText(profile: Profile): string {
    if (profile.subscription && profile.subscription.lastBytes > 0) {
      return this.formatBytes(profile.subscription.lastBytes) + ' 已下载';
    }
    return profile.type === 'subscription' ? '等待更新' : '本地配置';
  }

  private profileRuleText(profile: Profile): string {
    if (!this.configService) {
      return '0 rules';
    }
    return this.configService.countRules(profile.id).toString() + ' rules';
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
      const profile = await this.subscriptionService.addSubscription(name, this.subUrl);
      const result = await this.subscriptionService.update(profile.id);
      this.configService.setActiveProfile(profile.id);
      this.subStatus = result.ok ? '配置已创建并更新' : '配置已创建，更新失败: ' + result.error;
      this.rawYaml = this.configService.loadRawYaml(profile.id);
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

  private createLocalProfile(): void {
    if (!this.configService) {
      return;
    }
    const name = this.newProfileName.trim().length > 0 ? this.newProfileName.trim() : '新配置';
    const profile = this.configService.createLocalProfile(name, this.rawYaml);
    this.configService.setActiveProfile(profile.id);
    this.subStatus = '本地配置已创建';
    this.reloadProfiles();
    this.selectSection(2);
  }

  private async refreshSubscription(profileId: string = ''): Promise<void> {
    if (!this.subscriptionService || !this.configService) {
      return;
    }
    this.subBusy = true;
    try {
      const profile = profileId.length > 0 ? this.configService.getProfile(profileId) : this.configService.getActiveProfile();
      if (!profile || profile.type !== 'subscription') {
        this.subStatus = '当前配置不是 URL 订阅';
        return;
      }
      const result = await this.subscriptionService.update(profile.id);
      this.subStatus = result.ok ? '更新完成: ' + result.statusCode.toString() + ' ' + result.bytes.toString() + 'B' :
        '更新失败: ' + result.error;
      if (profile.active) {
        this.rawYaml = this.configService.loadRawYaml(profile.id);
      }
      this.reloadProfiles();
      this.refreshState();
    } catch (err) {
      this.subStatus = '更新异常: ' + this.toErrorText(err);
    } finally {
      this.subBusy = false;
    }
  }

  private refreshActiveConfig(): void {
    const profile = this.getActiveProfileFromState();
    if (profile && profile.type === 'subscription') {
      this.refreshSubscription(profile.id);
      return;
    }
    if (this.configService) {
      const result = this.configService.validateRawYaml(this.configService.loadRawYaml(this.activeProfileId));
      this.subStatus = result.ok ? '本地配置已校验' : result.errors.join('; ');
      this.reloadProfiles();
    }
  }

  private switchProfile(profileId: string): void {
    if (!this.configService) {
      return;
    }
    const profile = this.configService.setActiveProfile(profileId);
    if (profile) {
      this.rawYaml = this.configService.loadRawYaml(profileId);
      this.subStatus = '已切换到: ' + profile.name;
      this.reloadProfiles();
      this.refreshState();
    }
  }

  private openProfileActions(profileId: string): void {
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
    const ok = this.configService.deleteProfile(profileId);
    this.subStatus = ok ? '配置已删除' : '默认配置或最后一个配置不能删除';
    this.closeProfileActions();
    this.reloadProfiles();
  }

  private canDeleteProfile(profileId: string): boolean {
    return profileId !== 'default' && this.profiles.length > 1;
  }

  private createModeSubtitle(): string {
    if (this.createMode === 0) {
      return '文件导入能力待接入系统文件选择器';
    }
    if (this.createMode === 2) {
      return '二维码扫描能力待接入相机权限';
    }
    return '从 URL 导入订阅配置';
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
      const keywordOk = keyword.length === 0 ||
        event.message.toLowerCase().indexOf(keyword) >= 0 ||
        event.source.toLowerCase().indexOf(keyword) >= 0 ||
        event.level.toLowerCase().indexOf(keyword) >= 0;
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
  }

  private exportDiagnostics(): void {
    if (!this.runtimeStore || !this.configService) {
      return;
    }
    try {
      const profile = this.configService.getActiveProfile();
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
    this.diagnosticText = this.runtimeStore.createDiagnosticsText(this.appSettings, profile,
      this.selectedProxyGroupLabel(), this.selectedNodeName(), this.selectedNodeMeta());
    this.validationText = '诊断信息已刷新';
  }

  private eventTimeText(event: RuntimeEvent): string {
    return new Date(event.timestamp).toLocaleTimeString();
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
        return '异常: ' + event.message;
      }
      if (lower.indexOf('protect hook auto-enabled') >= 0 || lower.indexOf('protect callback registered') >= 0) {
        return 'active';
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
        return '异常: ' + event.message;
      }
      if (lower.indexOf('skipping graceful stop') >= 0) {
        return '跳过: 无 active TUN fd';
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

  private selectProxyNode(node: ProxyNode): void {
    if (!this.configService || !this.runtimeStore) {
      return;
    }
    const ok = this.configService.selectLocalProxy(node.group, node.name, this.activeProfileId);
    if (!ok) {
      this.validationText = '节点选择失败';
      this.runtimeStore.appendEvent('Proxy select failed group=' + node.group + ' node=' + node.name);
      return;
    }
    const running = this.statusText === 'Connected' || this.statusText === 'Starting' || this.coreText === 'Running';
    this.validationText = running ? '节点选择已保存，重连后生效' : '节点选择已保存';
    this.runtimeStore.appendEvent(running ?
      'Proxy selected locally; reconnect required group=' + node.group + ' node=' + node.name :
      'Proxy selected locally group=' + node.group + ' node=' + node.name);
    this.reloadProfiles();
    this.refreshState();
  }

  private cycleRouteMode(): void {
    const modes: VpnRouteMode[] = ['blocking-default', 'split-default', 'default', 'no-routes', 'exclude-local',
      'blocking-split', 'blocking-empty'];
    const index = modes.indexOf(this.appSettings.routeMode);
    this.updateSettings({ routeMode: modes[(index + 1) % modes.length] });
  }

  private cycleProxyMode(): void {
    const modes: ProxyMode[] = ['rule', 'global', 'direct'];
    const index = modes.indexOf(this.appSettings.proxyMode);
    this.updateSettings({ proxyMode: modes[(index + 1) % modes.length] });
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

  private routeModeLabel(mode: VpnRouteMode): string {
    if (mode === 'blocking-default') {
      return 'Blocking Default';
    }
    if (mode === 'split-default') {
      return 'Split Default';
    }
    if (mode === 'default') {
      return 'Default Route';
    }
    if (mode === 'no-routes') {
      return 'No Routes';
    }
    if (mode === 'exclude-local') {
      return 'Exclude Local';
    }
    if (mode === 'blocking-split') {
      return 'Blocking Split';
    }
    return 'Blocking Empty';
  }

  private proxyModeLabel(mode: ProxyMode): string {
    if (mode === 'global') {
      return '全局';
    }
    if (mode === 'direct') {
      return '直连';
    }
    return '规则';
  }

  private dnsModeLabel(mode: DnsMode): string {
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
    if (key === 'autoStart') {
      return this.appSettings.autoStart;
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
    if (key === 'autoStart') {
      this.updateSettings({ autoStart: !this.appSettings.autoStart });
    }
  }

  @Builder AppHeader() {
    Row({ space: 12 }) {
      Column() {
        Text('FG')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.accentColor())
      }
      .width(38)
      .height(38)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor('#172B30')
      .borderRadius(10)

      Column({ space: 2 }) {
        Text(this.selectedSectionIndex === 0 ? 'FlowGuard' : this.currentSectionLabel())
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryText())
          .maxLines(1)
        Text('v0.1 · MVP-01 · ' + this.activeProfileName)
          .fontSize(11)
          .fontColor(this.mutedText())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Button('Diag')
        .height(36)
        .fontSize(12)
        .fontColor(this.accentColor())
        .backgroundColor(this.elevatedBg())
        .borderRadius(10)
        .onClick(() => {
          this.selectSection(9);
        })
    }
    .width('100%')
    .height(68)
    .padding({ left: 20, right: 20, top: 10, bottom: 10 })
    .backgroundColor(this.appBg())
  }

  @Builder HomePage() {
    Scroll() {
      if (this.isTabletLayout()) {
        Row({ space: 18 }) {
          Column({ space: 16 }) {
            this.ConnectionHero()
            this.MainActions()
            this.StatusPills()
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Center)

          Column({ space: 14 }) {
            this.CurrentProxyCard()
            this.TrafficRow()
            this.ProfileChipsSection()
            this.RouteModeSection()
            this.EventSection()
          }
          .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 28 })
      } else {
        Column({ space: 16 }) {
          this.ConnectionHero()
          this.StatusPills()
          if (this.lastError.length > 0) {
            this.ErrorBanner()
          }
          this.CurrentProxyCard()
          this.TrafficRow()
          this.MainActions()
          this.ProfileChipsSection()
          this.RouteModeSection()
          this.EventSection()
        }
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 28 })
      }
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
    .layoutWeight(1)
    .width('100%')
    .backgroundColor(this.appBg())
  }

  @Builder ConnectionHero() {
    Column({ space: 10 }) {
      Column() {
        Column() {
          Text(this.statusIconText())
            .fontSize(44)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.stateAccentColor())
        }
        .width(112)
        .height(112)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(this.statusText === 'Connected' ? '#16302F' : this.elevatedBg())
        .borderRadius(56)
      }
      .width(148)
      .height(148)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor(this.surfaceBg())
      .borderRadius(74)
      .onClick(() => {
        this.toggleRuntime();
      })

      Text(this.statusTitleText())
        .fontSize(25)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.primaryText())
        .maxLines(1)
      Text(this.statusSubtitleText())
        .fontSize(13)
        .fontColor(this.secondaryText())
        .maxLines(2)
        .textAlign(TextAlign.Center)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.activeProfileName + ' · blocking-default')
        .fontSize(11)
        .fontColor(this.mutedText())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: 8, bottom: 4 })
    .alignItems(HorizontalAlign.Center)
  }

  @Builder StatusPills() {
    Row({ space: 8 }) {
      Row({ space: 6 }) {
        Text('●')
          .fontSize(8)
          .fontColor(this.stateAccentColor())
        Text('VPN: ' + this.statusText)
          .fontSize(11)
          .fontColor(this.secondaryText())
          .maxLines(1)
      }
      .height(30)
      .padding({ left: 10, right: 10 })
      .backgroundColor(this.elevatedBg())
      .borderRadius(15)

      Row({ space: 6 }) {
        Text('●')
          .fontSize(8)
          .fontColor(this.coreText === 'Running' ? this.accentColor() : this.secondaryText())
        Text('Core: ' + this.coreText)
          .fontSize(11)
          .fontColor(this.secondaryText())
          .maxLines(1)
      }
      .height(30)
      .padding({ left: 10, right: 10 })
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
      .padding({ left: 10, right: 10 })
      .backgroundColor(this.elevatedBg())
      .borderRadius(15)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder StatusPill(label: string, color: string) {
    Row({ space: 6 }) {
      Text('●')
        .fontSize(8)
        .fontColor(color)
      Text(label)
        .fontSize(11)
        .fontColor(this.secondaryText())
        .maxLines(1)
    }
    .height(30)
    .padding({ left: 10, right: 10 })
    .backgroundColor(this.elevatedBg())
    .borderRadius(15)
  }

  @Builder ErrorBanner() {
    Column({ space: 4 }) {
      Text('启动失败')
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.dangerColor())
        .width('100%')
      Text(this.lastError)
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
      this.TrafficTile('下载', this.formatBytes(this.downloadSpeed) + '/s')
      this.TrafficTile('上传', this.formatBytes(this.uploadSpeed) + '/s')
    }
    .width('100%')
  }

  @Builder TrafficTile(label: string, value: string) {
    Column({ space: 5 }) {
      Text(label)
        .fontSize(11)
        .fontColor(this.mutedText())
      Text(value)
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.accentColor())
        .maxLines(1)
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
    .padding(12)
    .backgroundColor(this.surfaceBg())
    .borderRadius(12)
  }

  @Builder MainActions() {
    Row({ space: 10 }) {
      Button('连接')
        .height(48)
        .layoutWeight(1)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor('#042F2E')
        .backgroundColor(this.canConnect() ? this.accentColor() : '#31514F')
        .borderRadius(14)
        .enabled(this.canConnect())
        .onClick(() => {
          this.connect();
        })
      Button('断开')
        .height(48)
        .layoutWeight(1)
        .fontSize(16)
        .fontColor(this.dangerColor())
        .backgroundColor(this.canDisconnect() ? '#2B1B22' : this.elevatedBg())
        .borderRadius(14)
        .enabled(this.canDisconnect())
        .onClick(() => {
          this.disconnect();
        })
      Button('重载')
        .height(48)
        .width(68)
        .fontSize(13)
        .fontColor(this.secondaryText())
        .backgroundColor(this.elevatedBg())
        .borderRadius(14)
        .onClick(() => {
          this.refreshActiveConfig();
        })
    }
    .width('100%')
  }

  @Builder ProfileChipsSection() {
    Column({ space: 8 }) {
      this.SectionTitle('配置 Profile', '')
      Scroll() {
        Row({ space: 8 }) {
          ForEach(this.profiles, (p: Profile) => {
            Column({ space: 3 }) {
              Text(p.name)
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor(p.active ? this.accentColor() : this.secondaryText())
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text((p.type === 'subscription' ? 'sub' : 'local') + ' · ' + this.profileRuleText(p) +
                ' · ' + (p.active ? 'active' : this.profileRelativeText(p)))
                .fontSize(10)
                .fontColor(p.active ? '#78E2D5' : this.mutedText())
                .maxLines(1)
            }
            .height(48)
            .padding({ left: 12, right: 12, top: 7, bottom: 6 })
            .backgroundColor(p.active ? '#17302F' : this.elevatedBg())
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
    .width('100%')
  }

  @Builder RouteModeSection() {
    Column({ space: 8 }) {
      this.SectionTitle('路由模式', '点击切换')
      Row() {
        Text(this.routeModeLabel(this.appSettings.routeMode))
          .fontSize(13)
          .fontColor(this.primaryText())
          .layoutWeight(1)
        Text(this.appSettings.routeMode)
          .fontSize(11)
          .fontColor(this.mutedText())
          .margin({ right: 10 })
        Text('>')
          .fontSize(14)
          .fontColor(this.mutedText())
      }
      .height(44)
      .padding({ left: 12, right: 12 })
      .backgroundColor(this.inputBg())
      .borderRadius(10)
      .onClick(() => {
        this.cycleRouteMode();
      })
    }
    .width('100%')
  }

  @Builder EventSection() {
    Column({ space: 8 }) {
      this.SectionTitle('运行事件', '查看全部')
      Column() {
        ForEach(this.events.slice(0, 4), (line: string) => {
          Text(line)
            .fontSize(12)
            .fontColor(this.secondaryText())
            .width('100%')
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }, (line: string) => line)
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
        .fontSize(11)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.mutedText())
        .layoutWeight(1)
      if (action.length > 0) {
        Text(action)
          .fontSize(11)
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
      .width('100%')
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
            this.YamlEditorPanel()
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
          this.YamlEditorPanel()
        }
        .width('100%')
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
        Text('Profile 列表')
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

      if (this.subStatus.length > 0) {
        Text(this.subStatus)
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
      Text(p.active ? '●' : '○')
        .fontSize(18)
        .fontColor(p.active ? this.accentColor() : this.mutedText())
        .width(28)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.switchProfile(p.id);
        })

      Column({ space: 5 }) {
        Text(p.name)
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
    .backgroundColor(p.active ? '#17302F' : this.surfaceBg())
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
          .onClick(() => {
            this.subStatus = '文件导入能力待接入系统文件选择器';
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

      Text(this.validationText)
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
        this.CreateOptionRow('FILE', '文件', '从文件导入', 0)
        this.CreateOptionRow('URL', 'URL', '从 URL 导入', 1)
        this.CreateOptionRow('QR', 'QR Code', '从二维码导入', 2)

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
            Button('创建空白本地配置')
              .height(44)
              .width('100%')
              .fontSize(14)
              .fontColor('#042F2E')
              .backgroundColor(this.accentColor())
              .borderRadius(10)
              .onClick(() => {
                this.rawYaml = 'mode: rule\nlog-level: info\nproxies: []\nproxy-groups: []\nrules:\n  - MATCH,DIRECT\n';
                this.createLocalProfile();
              })
          }

          if (this.subStatus.length > 0) {
            Text(this.subStatus)
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
          this.LogFilterChip('Info', 'info')
          this.LogFilterChip('Warn', 'warn')
          this.LogFilterChip('Error', 'error')
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
      .padding({ left: 20, right: 20, bottom: 28 })
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Auto)
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
        Text(event.level.toUpperCase())
          .fontSize(10)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.eventToneColor(event.level))
        Text(event.source)
          .fontSize(10)
          .fontColor(this.mutedText())
        Text(this.eventTimeText(event))
          .fontSize(10)
          .fontColor(this.mutedText())
          .layoutWeight(1)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      Text(event.message)
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
        this.ToggleSettingRow('IPv6', '写入 runtime YAML，并传入 VPN 配置', 'ipv6')
        this.ToggleSettingRow('UDP 转发', '保存到连接设置，用于后续 native UDP 策略', 'udp')
        this.ToggleSettingRow('连接前自动更新订阅', '失败时沿用上一次可用 runtime', 'autoRefresh')
        this.ToggleSettingRow('开机自启', '设置已持久化，系统自启能力后续接入', 'autoStart')
        this.SettingsGroup('诊断')
        this.SettingsRow('Runtime', this.statusText + ' / Core: ' + this.coreText, '查看')
        this.SettingsRow('VPN DNS', '传给 VPN Extension 的 DNS 地址', this.appSettings.vpnDnsAddress)
        this.SettingsRow('FlowGuard', 'v0.1 · MVP-01', '关于')
      }
      .width('100%')
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
      this.SettingsRowText('启动模式', '规则 / 全局 / 直连会写入 runtime YAML')
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
      this.cycleProxyMode();
    })
  }

  @Builder RouteModeSettingRow() {
    Row({ space: 12 }) {
      this.SettingsRowText('VPN 路由', '决定 VPN Extension 下发 default/split/blocking 路由')
      Column({ space: 2 }) {
        Text(this.routeModeLabel(this.appSettings.routeMode))
          .fontSize(12)
          .fontColor(this.accentColor())
          .maxLines(1)
        Text(this.appSettings.routeMode)
          .fontSize(10)
          .fontColor(this.mutedText())
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
      this.cycleRouteMode();
    })
  }

  @Builder DnsModeSettingRow() {
    Row({ space: 12 }) {
      this.SettingsRowText('DNS 模式', 'default/fake-ip/redir-host 会写入 runtime YAML')
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
      this.SettingsRowText('日志级别', '写入 runtime YAML log-level')
      Text(this.appSettings.logLevel)
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

        this.DiagCard('Runtime 快照', 'VPN: ' + this.statusText + ' · Core: ' + this.coreText,
          'updatedAt: ' + this.snapshotUpdatedText() + ' · startedAt: ' + this.startedAtText())
        this.DiagCard('Mihomo Core', 'version: ' + this.mihomoVersionText(),
          'graceful stop: ' + this.gracefulStopText())
        this.DiagCard('Active Profile', this.activeProfileName, this.activeProfileId)
        this.DiagCard('当前节点', this.selectedProxyGroupLabel() + ' / ' + this.selectedNodeName(), this.selectedNodeMeta())
        this.DiagCard('Bridge', 'tunFd: ' + this.tunFdText(), 'protect hook: ' + this.protectHookText())
        this.DiagCard('设置', 'route=' + this.appSettings.routeMode + ' · mode=' + this.appSettings.proxyMode,
          'dns=' + this.appSettings.dnsMode + ' · log=' + this.appSettings.logLevel)
        this.DiagCard('最近错误', this.lastError.length > 0 ? this.lastError : '无',
          this.runtimeEvents.length > 0 ? this.runtimeEvents[0].message : '暂无事件')
        this.DiagCard('POC / Smoke', this.pocSmokeSummary(), '脚本摘要未接入时显示未运行')
        if (this.lastDiagnosticPath.length > 0) {
          this.DiagCard('导出文件', this.lastDiagnosticPath, '包含 snapshot、settings、active profile、最近 60 条事件')
        }
        if (this.diagnosticText.length > 0) {
          this.DiagCard('诊断摘要', this.diagnosticText.substring(0, Math.min(80, this.diagnosticText.length)),
            '完整内容已复制到系统剪贴板')
        }
      }
      .width('100%')
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
    }
    .width('100%')
    .padding(20)
    .backgroundColor(this.appBg())
  }

  @Builder AboutPage() {
    Column({ space: 12 }) {
      this.DiagCard('FlowGuard', 'HarmonyOS mihomo client prototype', 'Runtime: ' + this.statusText + ' · Core: ' + this.coreText)
    }
    .width('100%')
    .padding(20)
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
            this.deleteProfile(this.sheetProfileId);
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
    .height(66)
    .width('100%')
    .padding({ left: 8, right: 8, bottom: 6 })
    .backgroundColor(this.appBg())
  }

  @Builder TabletSidebar() {
    Column({ space: 8 }) {
      Text('FG')
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
    Column({ space: 2 }) {
      Text(label)
        .fontSize(12)
        .fontColor(this.selectedSectionIndex === index ? this.accentColor() : this.secondaryText())
        .maxLines(1)
    }
    .layoutWeight(1)
    .height(48)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.selectedSectionIndex === index ? '#17302F' : '#00000000')
    .borderRadius(12)
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

  build() {
    Stack() {
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
    }
    .height('100%')
    .width('100%')
    .backgroundColor(this.appBg())
    .onAreaChange((_oldArea, newArea) => {
      this.rootWidth = Number(newArea.width);
    })
  }
}
