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

  private isConnectedView(): boolean {
    return this.statusText === 'Connected' || this.statusText === 'Starting';
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
    return '首页';
  }

  private selectSection(index: number): void {
    this.selectedSectionIndex = index;
    this.sheetVisible = false;
    if (index === 0 || index === 1 || index === 2) {
      this.reloadProfiles();
    }
  }

  private statusCardColor(): string {
    if (this.statusText === 'Connected') {
      return '#224C83';
    }
    if (this.statusText === 'Starting' || this.statusText === 'Stopping') {
      return '#9A5F12';
    }
    if (this.statusText === 'Error') {
      return '#9F1D1D';
    }
    if (this.statusText === 'Unknown') {
      return '#5B4B8A';
    }
    return '#858585';
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

  @Builder HomePage() {
    Scroll() {
      Column({ space: 22 }) {
        Row({ space: 22 }) {
          Image($r('app.media.startIcon'))
            .width(72)
            .height(72)
            .objectFit(ImageFit.Contain)

          Text('Clash Meta for Android')
            .fontSize(25)
            .fontWeight(FontWeight.Medium)
            .fontColor('#111111')
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ top: 46, bottom: 10 })

        Row({ space: 26 }) {
          Text(this.statusIconText())
            .fontSize(48)
            .fontColor('#FFFFFF')
            .width(86)
            .textAlign(TextAlign.Center)

          Column({ space: 10 }) {
            Text(this.statusTitleText())
              .fontSize(27)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF')
              .maxLines(1)
            Text(this.statusSubtitleText())
              .fontSize(18)
              .fontColor('#F7F7F7')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .height(118)
        .padding({ left: 26, right: 26 })
        .backgroundColor(this.statusCardColor())
        .borderRadius(8)
        .shadow({ radius: 8, color: '#24000000', offsetX: 0, offsetY: 2 })
        .onClick(() => {
          this.toggleRuntime();
        })

        if (this.isConnectedView()) {
          this.HomeMenuCard('▦', '代理', '规则模式', () => {
            this.selectSection(1);
          })
        }

        this.HomeMenuCard('▤', '配置', this.activeProfileName + ' 已激活', () => {
          this.selectSection(2);
        })

        this.HomeSimpleRow('▣', '日志', () => {
          this.selectSection(4);
        })

        this.HomeSimpleRow('⚙', '设置', () => {
          this.selectSection(5);
        })

        this.HomeSimpleRow('?', '帮助', () => {
          this.selectSection(6);
        })

        this.HomeSimpleRow('i', '关于', () => {
          this.selectSection(7);
        })
      }
      .width('100%')
      .padding({ left: 30, right: 30, bottom: 36 })
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
    .width('100%')
    .height('100%')
  }

  @Builder HomeMenuCard(icon: string, title: string, subtitle: string, action: () => void) {
    Row({ space: 28 }) {
      Text(icon)
        .fontSize(36)
        .fontWeight(FontWeight.Bold)
        .fontColor('#000000')
        .width(88)
        .textAlign(TextAlign.Center)
      Column({ space: 8 }) {
        Text(title)
          .fontSize(22)
          .fontColor('#111111')
          .maxLines(1)
        Text(subtitle)
          .fontSize(16)
          .fontColor('#333333')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .height(126)
    .width('100%')
    .padding({ left: 20, right: 20 })
    .backgroundColor('#FFFFFF')
    .borderRadius(8)
    .shadow({ radius: 10, color: '#1A000000', offsetX: 0, offsetY: 2 })
    .onClick(action)
  }

  @Builder HomeSimpleRow(icon: string, title: string, action: () => void) {
    Row({ space: 28 }) {
      Text(icon)
        .fontSize(36)
        .fontWeight(FontWeight.Bold)
        .fontColor('#000000')
        .width(88)
        .textAlign(TextAlign.Center)
      Text(title)
        .fontSize(22)
        .fontColor('#111111')
        .layoutWeight(1)
        .maxLines(1)
    }
    .height(94)
    .width('100%')
    .padding({ left: 20, right: 20 })
    .onClick(action)
  }

  @Builder PageHeader() {
    Row() {
      Button('‹')
        .width(52)
        .height(52)
        .fontSize(34)
        .fontColor('#111111')
        .backgroundColor('#00000000')
        .onClick(() => {
          if (this.selectedSectionIndex === 3 || this.selectedSectionIndex === 8) {
            this.selectSection(2);
          } else {
            this.selectSection(0);
          }
        })

      Text(this.currentSectionLabel())
        .fontSize(27)
        .fontWeight(FontWeight.Medium)
        .fontColor('#111111')
        .layoutWeight(1)
        .maxLines(1)

      if (this.selectedSectionIndex === 2) {
        Button('↻')
          .width(52)
          .height(52)
          .fontSize(25)
          .fontColor('#111111')
          .backgroundColor('#00000000')
          .enabled(!this.subBusy)
          .onClick(() => {
            this.refreshActiveConfig();
          })

        Button('+')
          .width(52)
          .height(52)
          .fontSize(30)
          .fontColor('#111111')
          .backgroundColor('#00000000')
          .enabled(!this.subBusy)
          .onClick(() => {
            this.subStatus = '';
            this.createMode = 1;
            this.selectSection(3);
          })
      } else {
        Text('')
          .width(104)
      }
    }
    .width('100%')
    .height(92)
    .padding({ left: 22, right: 22, top: 18 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder ProxyPage() {
    Scroll() {
      Column({ space: 16 }) {
        Row({ space: 10 }) {
          this.ModeChip('规则模式', true)
          this.ModeChip('全局', false)
          this.ModeChip('直连', false)
        }
        .width('100%')

        Column({ space: 10 }) {
          Text('节点')
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor('#111111')
            .width('100%')
          Text(this.nodes.length.toString() + ' 个节点来自 ' + this.activeProfileName)
            .fontSize(14)
            .fontColor('#555555')
            .width('100%')
        }
        .width('100%')
        .padding({ top: 8, bottom: 4 })

        if (this.nodes.length === 0) {
          Column({ space: 12 }) {
            Text('暂无节点')
              .fontSize(20)
              .fontColor('#111111')
            Text('请先在配置页更新或导入包含 proxies 的配置')
              .fontSize(14)
              .fontColor('#555555')
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .height(180)
          .justifyContent(FlexAlign.Center)
          .backgroundColor('#FFFFFF')
          .borderRadius(8)
        }

        ForEach(this.nodes, (node: ProxyNode) => {
          Row({ space: 14 }) {
            Text(node.selected ? '◉' : '○')
              .fontSize(26)
              .fontColor(node.selected ? '#224C83' : '#777777')
              .width(42)
              .textAlign(TextAlign.Center)

            Column({ space: 6 }) {
              Text(node.name)
                .fontSize(18)
                .fontColor('#111111')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(node.type.toUpperCase() + ' · ' + (node.server.length > 0 ? node.server : '未填写地址'))
                .fontSize(13)
                .fontColor('#555555')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Text(node.delay > 0 ? node.delay.toString() + ' ms' : '--')
              .fontSize(14)
              .fontColor('#224C83')
              .width(64)
              .textAlign(TextAlign.End)
          }
          .width('100%')
          .height(82)
          .padding({ left: 14, right: 14 })
          .backgroundColor('#FFFFFF')
          .borderRadius(8)
          .shadow({ radius: 6, color: '#10000000', offsetX: 0, offsetY: 1 })
        }, (node: ProxyNode) => node.name)
      }
      .width('100%')
      .padding({ left: 22, right: 22, bottom: 32 })
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
    .layoutWeight(1)
    .width('100%')
  }

  @Builder ModeChip(title: string, selected: boolean) {
    Text(title)
      .height(38)
      .layoutWeight(1)
      .textAlign(TextAlign.Center)
      .fontSize(15)
      .fontColor(selected ? '#FFFFFF' : '#222222')
      .backgroundColor(selected ? '#224C83' : '#FFFFFF')
      .borderRadius(6)
  }

  @Builder ConfigPage() {
    Scroll() {
      Column({ space: 20 }) {
        ForEach(this.profiles, (p: Profile) => {
          Row({ space: 16 }) {
            Text(p.active ? '◉' : '○')
              .fontSize(30)
              .fontColor(p.active ? '#224C83' : '#777777')
              .width(54)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.switchProfile(p.id);
              })

            Column({ space: 8 }) {
              Text(p.name)
                .fontSize(21)
                .fontColor('#111111')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.profileTypeLabel(p))
                .fontSize(16)
                .fontColor('#222222')
              Text(this.profileTrafficText(p))
                .fontSize(14)
                .fontColor('#333333')
                .maxLines(1)
              Text(this.profileDateText(p))
                .fontSize(14)
                .fontColor('#333333')
                .maxLines(1)
              Row() {
                Row()
                  .width(p.subscription && p.subscription.lastBytes > 0 ? 18 : 6)
                  .height(4)
                  .backgroundColor('#224C83')
              }
              .width(190)
              .height(4)
              .backgroundColor('#BDBDBD')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Text(this.profileRelativeText(p))
              .fontSize(18)
              .fontColor('#333333')
              .width(92)
              .textAlign(TextAlign.Center)
              .maxLines(1)

            Button('⋮')
              .width(46)
              .height(64)
              .fontSize(32)
              .fontColor('#000000')
              .backgroundColor('#00000000')
              .onClick(() => {
                this.openProfileActions(p.id);
              })
          }
          .width('100%')
          .height(148)
          .padding({ left: 18, right: 14 })
          .backgroundColor('#FFFFFF')
          .borderRadius(8)
          .shadow({ radius: 8, color: '#18000000', offsetX: 0, offsetY: 2 })
        }, (p: Profile) => p.id)

        if (this.subStatus.length > 0) {
          Text(this.subStatus)
            .fontSize(13)
            .fontColor('#333333')
            .width('100%')
            .padding({ left: 10, right: 10, top: 8, bottom: 8 })
            .backgroundColor('#FFFFFF')
            .borderRadius(8)
        }
      }
      .width('100%')
      .padding({ left: 22, right: 22, bottom: 32 })
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
    .layoutWeight(1)
    .width('100%')
  }

  @Builder CreateConfigPage() {
    Scroll() {
      Column({ space: 34 }) {
        this.CreateOptionRow('⌇', '文件', '从文件导入', 0)
        this.CreateOptionRow('⬇', 'URL', '从 URL 导入', 1)
        this.CreateOptionRow('▦', 'QR Code', '从二维码导入', 2)

        Column({ space: 12 }) {
          Text(this.createModeSubtitle())
            .fontSize(14)
            .fontColor('#555555')
            .width('100%')

          if (this.createMode === 1) {
            TextInput({ text: this.newProfileName, placeholder: '配置名称' })
              .height(46)
              .width('100%')
              .fontSize(15)
              .backgroundColor('#FFFFFF')
              .borderRadius(6)
              .onChange((value: string) => {
                this.newProfileName = value;
              })

            TextInput({ text: this.subUrl, placeholder: 'https://example.com/sub.yaml' })
              .height(46)
              .width('100%')
              .fontSize(15)
              .backgroundColor('#FFFFFF')
              .borderRadius(6)
              .onChange((value: string) => {
                this.subUrl = value;
              })

            Button('创建')
              .height(46)
              .width('100%')
              .fontSize(16)
              .fontColor('#FFFFFF')
              .backgroundColor(this.subBusy ? '#A3A3A3' : '#224C83')
              .borderRadius(6)
              .enabled(!this.subBusy)
              .onClick(() => {
                this.addSubscription();
              })
          } else if (this.createMode === 0) {
            Button('创建空白本地配置')
              .height(46)
              .width('100%')
              .fontSize(16)
              .fontColor('#FFFFFF')
              .backgroundColor('#224C83')
              .borderRadius(6)
              .onClick(() => {
                this.rawYaml = 'mode: rule\nlog-level: info\nproxies: []\nproxy-groups: []\nrules:\n  - MATCH,DIRECT\n';
                this.createLocalProfile();
              })
          }

          if (this.subStatus.length > 0) {
            Text(this.subStatus)
              .fontSize(13)
              .fontColor('#333333')
              .width('100%')
          }
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 44, right: 44, top: 28, bottom: 40 })
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
    .layoutWeight(1)
    .width('100%')
  }

  @Builder CreateOptionRow(icon: string, title: string, subtitle: string, mode: number) {
    Row({ space: 34 }) {
      Text(icon)
        .fontSize(42)
        .fontWeight(FontWeight.Bold)
        .fontColor('#000000')
        .width(70)
        .textAlign(TextAlign.Center)
      Column({ space: 10 }) {
        Text(title)
          .fontSize(24)
          .fontColor('#111111')
          .maxLines(1)
        Text(subtitle)
          .fontSize(18)
          .fontColor('#222222')
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .height(112)
    .width('100%')
    .onClick(() => {
      this.createMode = mode;
    })
  }

  @Builder EditConfigPage() {
    Scroll() {
      Column({ space: 14 }) {
        TextArea({ text: this.rawYaml, placeholder: 'Clash/mihomo YAML' })
          .height(420)
          .width('100%')
          .fontSize(13)
          .fontColor('#111111')
          .backgroundColor('#FFFFFF')
          .borderRadius(8)
          .onChange((value: string) => {
            this.rawYaml = value;
          })

        Row({ space: 10 }) {
          Button('保存')
            .height(44)
            .layoutWeight(1)
            .fontColor('#FFFFFF')
            .backgroundColor('#224C83')
            .borderRadius(6)
            .onClick(() => {
              this.saveConfig();
            })

          Button('校验')
            .height(44)
            .layoutWeight(1)
            .fontColor('#FFFFFF')
            .backgroundColor('#4B5563')
            .borderRadius(6)
            .onClick(() => {
              this.validateConfig();
            })
        }
        .width('100%')

        Text(this.validationText)
          .fontSize(13)
          .fontColor('#333333')
          .width('100%')
      }
      .width('100%')
      .padding({ left: 22, right: 22, bottom: 32 })
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Auto)
    .layoutWeight(1)
    .width('100%')
  }

  @Builder LogsPage() {
    Scroll() {
      Column({ space: 10 }) {
        ForEach(this.events, (line: string) => {
          Text(line)
            .fontSize(13)
            .fontColor('#222222')
            .width('100%')
            .padding({ left: 14, right: 14, top: 10, bottom: 10 })
            .backgroundColor('#FFFFFF')
            .borderRadius(6)
        }, (line: string) => line)
      }
      .width('100%')
      .padding({ left: 22, right: 22, bottom: 32 })
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Auto)
    .layoutWeight(1)
    .width('100%')
  }

  @Builder SettingsPage() {
    Scroll() {
      Column({ space: 16 }) {
        this.SettingsRow('⚙', '应用', 'Runtime: ' + this.statusText + ' / Core: ' + this.coreText)
        this.SettingsRow('▤', '配置文件', this.activeProfileName)
        this.SettingsRow('▦', '节点', this.nodes.length.toString() + ' 个节点')
        this.SettingsRow('⇆', '流量', this.formatBytes(this.uploadSpeed + this.downloadSpeed) + ' 已转发')
      }
      .width('100%')
      .padding({ left: 22, right: 22, bottom: 32 })
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
    .layoutWeight(1)
    .width('100%')
  }

  @Builder SettingsRow(icon: string, title: string, subtitle: string) {
    Row({ space: 28 }) {
      Text(icon)
        .fontSize(34)
        .fontWeight(FontWeight.Bold)
        .fontColor('#000000')
        .width(88)
        .textAlign(TextAlign.Center)
      Column({ space: 6 }) {
        Text(title)
          .fontSize(22)
          .fontColor('#111111')
        Text(subtitle)
          .fontSize(13)
          .fontColor('#555555')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .height(92)
    .width('100%')
  }

  @Builder HelpPage() {
    Column({ space: 16 }) {
      Text('帮助')
        .fontSize(22)
        .fontWeight(FontWeight.Medium)
        .fontColor('#111111')
        .width('100%')
      Text('配置页用于管理 Clash/mihomo YAML 或 URL 订阅；连接后首页会显示代理入口。')
        .fontSize(15)
        .fontColor('#555555')
        .width('100%')
      Text('节点页会从当前激活配置的 proxies 字段自动展示节点。')
        .fontSize(15)
        .fontColor('#555555')
        .width('100%')
    }
    .width('100%')
    .padding(22)
  }

  @Builder AboutPage() {
    Column({ space: 14 }) {
      Text('Clash Meta for Android')
        .fontSize(22)
        .fontWeight(FontWeight.Medium)
        .fontColor('#111111')
        .width('100%')
      Text('HarmonyOS mihomo client prototype')
        .fontSize(14)
        .fontColor('#555555')
        .width('100%')
      Text('Runtime: ' + this.statusText)
        .fontSize(14)
        .fontColor('#333333')
        .width('100%')
      Text('Core: ' + this.coreText)
        .fontSize(14)
        .fontColor('#333333')
        .width('100%')
      Text('Active profile: ' + this.activeProfileName)
        .fontSize(14)
        .fontColor('#333333')
        .width('100%')
    }
    .width('100%')
    .padding(22)
  }

  @Builder ProfileActionSheet() {
    Column() {
      Blank()
        .layoutWeight(1)
        .onClick(() => {
          this.closeProfileActions();
        })

      Column({ space: 22 }) {
        Row()
          .width(64)
          .height(7)
          .backgroundColor('#E3E3E3')
          .borderRadius(4)

        this.SheetActionRow('↻', '更新', '#111111', () => {
          const p = this.getProfileById(this.sheetProfileId);
          this.closeProfileActions();
          if (p && p.type === 'subscription') {
            this.refreshSubscription(p.id);
          } else {
            this.refreshActiveConfig();
          }
        })
        this.SheetActionRow('✎', '编辑', '#111111', () => {
          this.editProfile(this.sheetProfileId);
        })
        this.SheetActionRow('▣', '复制', '#111111', () => {
          this.duplicateProfile(this.sheetProfileId);
        })
        this.SheetActionRow('□', '删除', this.canDeleteProfile(this.sheetProfileId) ? '#B00020' : '#999999', () => {
          if (this.canDeleteProfile(this.sheetProfileId)) {
            this.deleteProfile(this.sheetProfileId);
          }
        })
      }
      .width('100%')
      .padding({ left: 44, right: 44, top: 22, bottom: 36 })
      .backgroundColor('#FFFFFF')
      .borderRadius({ topLeft: 22, topRight: 22 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#66000000')
  }

  @Builder SheetActionRow(icon: string, title: string, color: string, action: () => void) {
    Row({ space: 34 }) {
      Text(icon)
        .fontSize(42)
        .fontWeight(FontWeight.Bold)
        .fontColor(color)
        .width(70)
        .textAlign(TextAlign.Center)
      Text(title)
        .fontSize(22)
        .fontColor(color)
        .layoutWeight(1)
        .maxLines(1)
    }
    .height(72)
    .width('100%')
    .onClick(action)
  }

  build() {
    Stack() {
      Column() {
        if (this.selectedSectionIndex === 0) {
          this.HomePage()
        } else {
          this.PageHeader()
          if (this.selectedSectionIndex === 1) {
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
          }
        }
      }
      .height('100%')
      .width('100%')
      .backgroundColor('#F7F7F7')

      if (this.sheetVisible) {
        this.ProfileActionSheet()
      }
    }
    .height('100%')
    .width('100%')
    .backgroundColor('#F7F7F7')
  }
}
