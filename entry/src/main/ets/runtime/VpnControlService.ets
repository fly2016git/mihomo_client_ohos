import { Want, common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { vpnExtension } from '@kit.NetworkKit';
import { ConfigService } from '../config/ConfigService';
import { SettingsService } from '../settings/SettingsService';
import { SubscriptionService } from '../subscription/SubscriptionService';
import { RuntimeStore } from './RuntimeStore';
import { VpnConnectPolicy, VpnConnectRequestState } from './VpnConnectPolicy';
import { ProxyRuntimePolicy } from './ProxyRuntimePolicy';

const BUNDLE_NAME = 'com.fly.fluxgate';
const VPN_ABILITY_NAME = 'MihomoPocVpnAbility';
const CONNECT_ACK_TIMEOUT_MS = 1200;
const CONNECT_ACK_POLL_MS = 100;
const CONNECT_REQUEST_NOT_ACKNOWLEDGED = 'VPN_CONNECT_REQUEST_NOT_ACKNOWLEDGED';

export class VpnControlService {
  private configService: ConfigService;
  private runtimeStore: RuntimeStore;
  private settingsService: SettingsService;
  private subscriptionService: SubscriptionService;
  private uiContext?: common.UIAbilityContext;
  private backgroundRunning: boolean = false;

  constructor(filesDir: string, uiContext?: common.UIAbilityContext) {
    this.configService = new ConfigService(filesDir);
    this.runtimeStore = new RuntimeStore(filesDir);
    this.settingsService = new SettingsService(filesDir);
    this.subscriptionService = new SubscriptionService(filesDir);
    this.uiContext = uiContext;
  }

  async connect(profileId: string): Promise<void> {
    const settings = this.settingsService.load();
    let profile = this.configService.getProfile(profileId);
    if (!profile) {
      throw new Error('NO_ACTIVE_PROFILE: 请先创建配置');
    }
    if (settings.autoRefreshSubscriptionOnConnect && profile.type === 'subscription') {
      this.runtimeStore.appendEvent('Auto refresh subscription before connect profile=' + profile.name);
      const refreshResult = await this.subscriptionService.update(profile.id);
      if (refreshResult.ok) {
        this.runtimeStore.appendEvent('Auto refresh subscription ok bytes=' + refreshResult.bytes.toString());
        profile = this.configService.getProfile(profile.id) ?? profile;
      } else {
        this.runtimeStore.appendEvent('Auto refresh subscription failed, using cached runtime: ' + refreshResult.error);
      }
    }
    const rawYaml = this.configService.loadRawYaml(profile.id);
    this.configService.writeTextFile(profile.runtimePath, this.configService.generateRuntimeYaml(rawYaml, settings));
    const requestedAt = Date.now();
    this.runtimeStore.update({
      runtimeState: 'starting',
      coreState: 'loading',
      activeProfileId: profile.id,
      activeProfileName: profile.name,
      lastError: '',
      lastEvent: 'Connect requested'
    });
    this.runtimeStore.appendEvent('Connect requested profile=' + profile.name);

    const want: Want = {
      bundleName: BUNDLE_NAME,
      abilityName: VPN_ABILITY_NAME,
      parameters: {
        command: 'connect',
        profileId: profile.id,
        requestedAt: new Date(requestedAt).toISOString(),
        requestedBy: 'ui',
        vpnRouteMode: settings.routeMode,
        vpnDnsAddress: settings.vpnDnsAddress,
        vpnRouteInterface: 'vpn-tun',
        vpnRouteDefaultFlag: true,
        tunReadinessProbeMs: 0,
        ipv6Enabled: settings.ipv6Enabled,
        udpEnabled: settings.udpEnabled,
        proxyMode: settings.proxyMode,
        dnsMode: settings.dnsMode,
        logLevel: settings.logLevel
      }
    };
    try {
      await vpnExtension.startVpnExtensionAbility(want);
      let requestState = await this.waitForConnectRequestState(profile.id, requestedAt);
      if (requestState === 'pending') {
        this.runtimeStore.appendEvent('Connect request retry after VPN authorization', 'warn', 'ui');
        await vpnExtension.startVpnExtensionAbility(want);
        requestState = await this.waitForConnectRequestState(profile.id, requestedAt);
      }
      if (requestState === 'pending') {
        throw new Error(CONNECT_REQUEST_NOT_ACKNOWLEDGED);
      }
      if (requestState === 'failed') {
        const snapshot = this.runtimeStore.getSnapshot();
        throw new Error(snapshot.lastError.length > 0 ? snapshot.lastError : 'VPN_CONNECT_REQUEST_REJECTED');
      }
      await this.startBackgroundRunning();
    } catch (err) {
      const connectError = err instanceof Error ? err : new Error(this.toErrorText(err));
      await this.failPendingConnect(profile.id, requestedAt, connectError);
      throw connectError;
    }
  }

  async disconnect(): Promise<void> {
    this.runtimeStore.update({
      runtimeState: 'stopping',
      coreState: 'stopping',
      lastEvent: 'Disconnect requested'
    });
    this.runtimeStore.appendEvent('Disconnect requested');
    await vpnExtension.startVpnExtensionAbility({
      bundleName: BUNDLE_NAME,
      abilityName: VPN_ABILITY_NAME,
      parameters: {
        command: 'disconnect',
        requestedAt: new Date().toISOString(),
        requestedBy: 'ui'
      }
    });
    await this.wait(3500);
    await this.stopBackgroundRunning();
    const snapshot = this.runtimeStore.getSnapshot();
    if (snapshot.runtimeState !== 'error' && snapshot.coreState !== 'error') {
      this.runtimeStore.update({
        runtimeState: 'idle',
        coreState: 'stopped',
        tunFd: -1,
        startedAt: 0,
        uploadSpeed: 0,
        downloadSpeed: 0,
        lastError: '',
        lastEvent: 'Disconnect finalized idle'
      });
      this.runtimeStore.appendEvent('Disconnect finalized idle');
    }
  }

  async requestProxyLatency(requestId: string, profileId: string, groupNames: string[], primaryUrl: string,
    fallbackUrl: string, timeoutMs: number): Promise<void> {
    this.ensureProxyRuntimeReady(profileId, 'Latency test');
    this.configService.saveProxyLatencyState({
      requestId,
      status: 'running',
      updatedAt: Date.now(),
      error: '',
      records: this.configService.loadProxyLatencyState().records
    });
    this.runtimeStore.appendEvent('Latency test requested groups=' + groupNames.length.toString());
    await vpnExtension.startVpnExtensionAbility({
      bundleName: BUNDLE_NAME,
      abilityName: VPN_ABILITY_NAME,
      parameters: {
        command: 'latency',
        requestId,
        profileId,
        groupNames: groupNames.join('\n'),
        primaryUrl,
        fallbackUrl,
        timeoutMs,
        requestedAt: new Date().toISOString(),
        requestedBy: 'ui'
      }
    });
  }

  async requestProxySelection(requestId: string, profileId: string, groupName: string,
    nodeName: string): Promise<void> {
    this.ensureProxyRuntimeReady(profileId, 'Proxy selection');
    this.configService.saveProxySelectionRequestState({
      requestId,
      profileId,
      groupName,
      nodeName,
      status: 'running',
      updatedAt: Date.now(),
      error: ''
    });
    this.runtimeStore.appendEvent('Proxy selection requested group=' + groupName + ' node=' + nodeName);
    await vpnExtension.startVpnExtensionAbility({
      bundleName: BUNDLE_NAME,
      abilityName: VPN_ABILITY_NAME,
      parameters: {
        command: 'selectProxy',
        requestId,
        profileId,
        groupName,
        nodeName,
        requestedAt: new Date().toISOString(),
        requestedBy: 'ui'
      }
    });
  }

  private async wait(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  private connectRequestState(profileId: string, requestedAt: number): VpnConnectRequestState {
    const snapshot = this.runtimeStore.getSnapshot();
    return VpnConnectPolicy.resolve(snapshot.runtimeState, snapshot.coreState, snapshot.tunFd,
      snapshot.activeProfileId, profileId, this.runtimeStore.getRuntimeEvents(), requestedAt);
  }

  private async waitForConnectRequestState(profileId: string, requestedAt: number): Promise<VpnConnectRequestState> {
    const deadline = Date.now() + CONNECT_ACK_TIMEOUT_MS;
    let state = this.connectRequestState(profileId, requestedAt);
    while (state === 'pending' && Date.now() < deadline) {
      await this.wait(CONNECT_ACK_POLL_MS);
      state = this.connectRequestState(profileId, requestedAt);
    }
    return state;
  }

  private async failPendingConnect(profileId: string, requestedAt: number, err: Object): Promise<void> {
    if (this.connectRequestState(profileId, requestedAt) !== 'pending') {
      return;
    }
    const errorText = this.toErrorText(err);
    this.runtimeStore.update({
      runtimeState: 'error',
      coreState: 'stopped',
      tunFd: -1,
      lastError: errorText,
      lastEvent: 'Connect failed'
    });
    this.runtimeStore.appendEvent('Connect failed: ' + errorText, 'error', 'ui');
    try {
      await vpnExtension.stopVpnExtensionAbility({
        bundleName: BUNDLE_NAME,
        abilityName: VPN_ABILITY_NAME
      });
    } catch (stopErr) {
      this.runtimeStore.appendEvent('Unacknowledged VPN extension stop failed: ' + this.toErrorText(stopErr),
        'warn', 'ui');
    }
    await this.stopBackgroundRunning();
  }

  private ensureProxyRuntimeReady(profileId: string, operation: string): void {
    const snapshot = this.runtimeStore.getSnapshot();
    if (ProxyRuntimePolicy.isReady(snapshot.runtimeState, snapshot.coreState, snapshot.activeProfileId, profileId)) {
      return;
    }
    this.runtimeStore.appendEvent(operation + ' skipped: proxy runtime not ready', 'info', 'ui');
    throw new Error('PROXY_RUNTIME_NOT_READY');
  }

  private async startBackgroundRunning(): Promise<void> {
    if (this.backgroundRunning || !this.uiContext) {
      return;
    }

    try {
      const agent = await wantAgent.getWantAgent({
        wants: [
          {
            bundleName: BUNDLE_NAME,
            abilityName: 'EntryAbility'
          }
        ],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 1001,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      await backgroundTaskManager.startBackgroundRunning(
        this.uiContext,
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER,
        agent);
      this.backgroundRunning = true;
      this.runtimeStore.appendEvent('Background running started');
    } catch (err) {
      this.runtimeStore.appendEvent('Background running failed: ' + this.toErrorText(err));
    }
  }

  private async stopBackgroundRunning(): Promise<void> {
    if (!this.backgroundRunning || !this.uiContext) {
      return;
    }

    try {
      await backgroundTaskManager.stopBackgroundRunning(this.uiContext);
      this.runtimeStore.appendEvent('Background running stopped');
    } catch (err) {
      this.runtimeStore.appendEvent('Background running stop failed: ' + this.toErrorText(err));
    } finally {
      this.backgroundRunning = false;
    }
  }

  private toErrorText(err: Object): string {
    if (err instanceof Error) {
      return err.name + ': ' + err.message;
    }
    return JSON.stringify(err);
  }
}
