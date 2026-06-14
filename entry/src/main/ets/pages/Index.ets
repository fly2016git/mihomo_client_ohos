import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ConfigService } from '../config/ConfigService';
import { Profile, ProxyNode, RuntimeSnapshot } from '../models/MvpTypes';
import { RuntimeStore } from '../runtime/RuntimeStore';
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
  @State sheetVisible: boolean = false;
  @State sheetProfileId: string = '';
  @State createMode: number = 1;
  @State newProfileName: string = '新配置';
  @State editProfileId: string = '';
  @State rootWidth: number = 390;

  private configService?: ConfigService;
  private runtimeStore?: RuntimeStore;
  private vpnControlService?: VpnControlService;
  private subscriptionService?: SubscriptionService;
  private pollTimer: number = -1;

  aboutToAppear(): void {
    const context = getContext(this) as common.UIAbilityContext;
    const filesDir = context.filesDir;
    this.configService = new ConfigService(filesDir);
    this.runtimeStore = new RuntimeStore(filesDir);
    this.vpnControlService = new VpnControlService(filesDir, context);
    this.subscriptionService = new SubscriptionService(filesDir);
    const profile = this.configService.ensureDefaultProfile();
    this.activeProfileId = profile.id;
    this.rawYaml = this.configService.loadRawYaml(profile.id);
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
    this.nodes = this.configService.listProxyNodes(active.id);
  }

  private refreshState(): void {
    if (!this.runtimeStore || !this.configService) {
      return;
    }
    try {
      const snapshot = this.runtimeStore.getSnapshot();
      this.applySnapshot(snapshot);
      this.events = this.runtimeStore.getEvents();
      this.reloadProfiles();
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
    if (this.nodes.length === 0) {
      return 'DIRECT';
    }
    for (const node of this.nodes) {
      if (node.selected) {
        return node.name;
      }
    }
    return this.nodes[0].name;
  }

  private selectedNodeMeta(): string {
    if (this.nodes.length === 0) {
      return 'Direct · --';
    }
    const node = this.nodes[0];
    return node.type.toUpperCase() + ' · ' + (node.delay > 0 ? node.delay.toString() + ' ms' : '--');
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

      this.StatusPill('Rule', this.accentColor())
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
        Text('当前节点 · Proxy')
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
              Text((p.type === 'subscription' ? 'sub' : 'local') + ' · ' + (p.active ? 'active' : this.profileRelativeText(p)))
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
      this.SectionTitle('路由模式', 'M2-2 接入持久化')
      Row() {
        Text('blocking-default')
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
        Row({ space: 8 }) {
          this.ModeChip('规则', true)
          this.ModeChip('全局', false)
          this.ModeChip('直连', false)
        }
        .width('100%')

        this.SectionTitle(this.nodes.length.toString() + ' 个节点来自 ' + this.activeProfileName, '')

        if (this.nodes.length === 0) {
          this.EmptyCard('暂无节点', '请先在配置页更新或导入包含 proxies 的配置')
        }

        ForEach(this.nodes, (node: ProxyNode) => {
          this.NodeRow(node)
        }, (node: ProxyNode) => node.name)
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
        Text(this.profileTypeLabel(p) + ' · ' + this.profileTrafficText(p))
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
    Scroll() {
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          this.ModeChip('全部', true)
          this.ModeChip('Info', false)
          this.ModeChip('Warn', false)
          this.ModeChip('Error', false)
        }
        .width('100%')

        ForEach(this.events, (line: string) => {
          Text(line)
            .fontSize(12)
            .fontColor(this.secondaryText())
            .width('100%')
            .padding({ left: 12, right: 12, top: 10, bottom: 10 })
            .backgroundColor(this.surfaceBg())
            .borderRadius(10)
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }, (line: string) => line)
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

  @Builder SettingsPage() {
    Scroll() {
      Column({ space: 14 }) {
        this.SettingsGroup('代理模式')
        this.SettingsRow('启动模式', '规则 / 全局 / 直连', '规则')
        this.SettingsRow('DNS 模式', 'fake-ip / redir-host 后续接入', '默认')
        this.SettingsGroup('网络')
        this.SettingsRow('IPv6', 'M2-2 接入 runtime YAML', '关闭')
        this.SettingsRow('UDP 转发', '沿用 mihomo 配置能力', '开启')
        this.SettingsRow('连接后自动更新订阅', 'M2-2 接入', '关闭')
        this.SettingsGroup('诊断')
        this.SettingsRow('Runtime', this.statusText + ' / Core: ' + this.coreText, '查看')
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

  @Builder SettingsRow(title: string, subtitle: string, value: string) {
    Row({ space: 12 }) {
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
        this.DiagCard('Runtime 快照', 'VPN: ' + this.statusText, 'Core: ' + this.coreText)
        this.DiagCard('Active Profile', this.activeProfileName, this.activeProfileId)
        this.DiagCard('当前节点', 'Proxy / ' + this.selectedNodeName(), this.selectedNodeMeta())
        this.DiagCard('Bridge', 'tunFd: 来自 RuntimeSnapshot', this.lastError.length > 0 ? this.lastError : '最近错误: 无')
        this.DiagCard('POC 回归', 'POC-05/06 与 smoke 结果待读取', 'M2-4 接入结构化诊断')
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
