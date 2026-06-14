import { Want, common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { vpnExtension } from '@kit.NetworkKit';
import { ConfigService } from '../config/ConfigService';
import { SettingsService } from '../settings/SettingsService';
import { SubscriptionService } from '../subscription/SubscriptionService';
import { RuntimeStore } from './RuntimeStore';

const BUNDLE_NAME = 'com.example.mihomopoc';
const VPN_ABILITY_NAME = 'MihomoPocVpnAbility';

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
    let profile = this.configService.getProfile(profileId) ?? this.configService.ensureDefaultProfile();
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
        requestedAt: new Date().toISOString(),
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
    await vpnExtension.startVpnExtensionAbility(want);
    await this.startBackgroundRunning();
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

  private async wait(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
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
