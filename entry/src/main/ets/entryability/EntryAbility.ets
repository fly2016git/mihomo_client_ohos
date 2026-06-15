import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { vpnExtension } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { ConfigService } from '../config/ConfigService';
import { RuntimeStore } from '../runtime/RuntimeStore';
import { UiRefreshBus } from '../runtime/UiRefreshBus';
import { SubscriptionService } from '../subscription/SubscriptionService';
import { Profile, SubscriptionUpdateResult } from '../models/MvpTypes';

const DOMAIN = 0x0000;
const TAG = 'MihomoPocEntry';
const BUNDLE_NAME = 'com.example.mihomopoc';
const VPN_ABILITY_NAME = 'MihomoPocVpnAbility';
const MVP_DEFAULT_CONFIG =
  'mode: direct\n' +
    'log-level: info\n' +
    'proxies: []\n' +
    'proxy-groups: []\n' +
    'rules:\n' +
    '  - MATCH,DIRECT\n';
const MVP_INVALID_CONFIG =
  'script:\n' +
    '  code: reject\n' +
    'proxy-providers:\n' +
    '  demo:\n' +
    '    type: http\n' +
    'mode: direct\n' +
    'rules:\n' +
    '  - MATCH,DIRECT\n';

interface MvpCommandParams extends Record<string, Object> {
  command: string;
  profileId: string;
  requestedAt: string;
  requestedBy: string;
  vpnRouteMode: Object;
  vpnDnsAddress: Object;
  tunReadinessProbeMs: Object;
  vpnRouteInterface: Object;
  vpnRouteDefaultFlag: Object;
}

export default class EntryAbility extends UIAbility {
  private windowStage?: window.WindowStage;
  private lastContentReloadAt: number = 0;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, TAG, 'Ability onCreate want=%{public}s', this.wantToLogText(want));
    this.notifyUiRuntimeRefresh('onCreate');
    this.tryHandleMvpCommand(want, 'onCreate');
    this.tryStartVpnPocFromWant(want, 'onCreate');
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'Ability onNewWant want=%{public}s', this.wantToLogText(want));
    this.notifyUiRuntimeRefresh('onNewWant');
    this.tryHandleMvpCommand(want, 'onNewWant');
    this.tryStartVpnPocFromWant(want, 'onNewWant');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageCreate');
    this.windowStage = windowStage;

    this.loadMainContent('onWindowStageCreate');
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageDestroy');
    this.windowStage = undefined;
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onForeground');
    this.notifyUiRuntimeRefresh('onForeground');
    this.reloadMainContentSoon('onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onBackground');
  }

  private notifyUiRuntimeRefresh(source: string): void {
    try {
      UiRefreshBus.emit();
      this.context.eventHub.emit('runtimeRefresh', Date.now());
      AppStorage.SetOrCreate('runtimeRefreshSignal', Date.now());
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'notifyUiRuntimeRefresh failed source=%{public}s err=%{public}s',
        source, JSON.stringify(err));
    }
  }

  private reloadMainContentSoon(source: string): void {
    const now = Date.now();
    if (now - this.lastContentReloadAt < 1000) {
      return;
    }
    this.lastContentReloadAt = now;
    setTimeout(() => {
      this.loadMainContent(source);
    }, 150);
  }

  private loadMainContent(source: string): void {
    if (!this.windowStage) {
      return;
    }
    this.windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load content source=%{public}s cause=%{public}s',
          source, JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Succeeded loading content source=%{public}s', source);
      this.notifyUiRuntimeRefresh('loadContent:' + source);
    });
  }

  private tryStartVpnPocFromWant(want: Want, source: string): void {
    const params = want.parameters as Record<string, Object> | undefined;
    const poc = (params?.['poc'] as string | undefined)?.toUpperCase();
    if (poc !== 'POC-04' && poc !== 'POC-05' && poc !== 'POC-06') {
      return;
    }

    vpnExtension.startVpnExtensionAbility({
      bundleName: BUNDLE_NAME,
      abilityName: VPN_ABILITY_NAME,
      parameters: {
        poc,
        requestedAt: new Date().toISOString(),
        requestedBy: source
      }
    }).then(() => {
      hilog.info(DOMAIN, TAG, 'startVpnExtensionAbility returned ok poc=%{public}s source=%{public}s',
        poc, source);
    }).catch((err: Object) => {
      hilog.error(DOMAIN, TAG, 'startVpnExtensionAbility failed poc=%{public}s source=%{public}s err=%{public}s',
        poc, source, JSON.stringify(err));
    });
  }

  private tryHandleMvpCommand(want: Want, source: string): void {
    const params = want.parameters as Record<string, Object> | undefined;
    const command = (params?.['mvpCommand'] as string | undefined) ?? '';
    if (command.length === 0) {
      return;
    }

    try {
      const configService = new ConfigService(this.context.filesDir);
      const runtimeStore = new RuntimeStore(this.context.filesDir);
      if (command === 'setInvalidConfig') {
        const result = configService.saveDefaultRawYaml(MVP_INVALID_CONFIG);
        runtimeStore.appendEvent('MVP command setInvalidConfig ok=' + result.ok);
        hilog.info(DOMAIN, TAG, 'mvpCommand setInvalidConfig source=%{public}s ok=%{public}s',
          source, result.ok ? 'true' : 'false');
        return;
      }
      if (command === 'setDefaultConfig') {
        const result = configService.saveDefaultRawYaml(MVP_DEFAULT_CONFIG);
        runtimeStore.resetToIdle('MVP command setDefaultConfig');
        runtimeStore.appendEvent('MVP command setDefaultConfig ok=' + result.ok);
        hilog.info(DOMAIN, TAG, 'mvpCommand setDefaultConfig source=%{public}s ok=%{public}s',
          source, result.ok ? 'true' : 'false');
        return;
      }
      if (command === 'resetRuntime') {
        runtimeStore.resetToIdle('MVP command resetRuntime');
        hilog.info(DOMAIN, TAG, 'mvpCommand resetRuntime source=%{public}s', source);
        return;
      }
      if (command === 'prepareSubscription') {
        this.handlePrepareSubscriptionCommand(params, configService, runtimeStore, source);
        return;
      }
      if (command === 'connectProduct') {
        const connectParams: MvpCommandParams = {
          command: 'connect',
          profileId: (params?.['profileId'] as string | undefined) ?? 'default',
          requestedAt: new Date().toISOString(),
          requestedBy: source + ':mvpCommand',
          vpnRouteMode: '',
          vpnDnsAddress: '',
          tunReadinessProbeMs: 0,
          vpnRouteInterface: '',
          vpnRouteDefaultFlag: true
        };
        this.copyOptionalParam(params, connectParams, 'vpnRouteMode');
        this.copyOptionalParam(params, connectParams, 'vpnDnsAddress');
        this.copyOptionalParam(params, connectParams, 'tunReadinessProbeMs');
        this.copyOptionalParam(params, connectParams, 'vpnRouteInterface');
        this.copyOptionalParam(params, connectParams, 'vpnRouteDefaultFlag');
        vpnExtension.startVpnExtensionAbility({
          bundleName: BUNDLE_NAME,
          abilityName: VPN_ABILITY_NAME,
          parameters: connectParams
        }).then(() => {
          hilog.info(DOMAIN, TAG, 'mvpCommand connectProduct returned ok source=%{public}s', source);
        }).catch((err: Object) => {
          hilog.error(DOMAIN, TAG, 'mvpCommand connectProduct failed source=%{public}s err=%{public}s',
            source, JSON.stringify(err));
        });
        return;
      }
      if (command === 'disconnectProduct') {
        vpnExtension.startVpnExtensionAbility({
          bundleName: BUNDLE_NAME,
          abilityName: VPN_ABILITY_NAME,
          parameters: {
            command: 'disconnect',
            requestedAt: new Date().toISOString(),
            requestedBy: source + ':mvpCommand'
          }
        }).then(() => {
          hilog.info(DOMAIN, TAG, 'mvpCommand disconnectProduct returned ok source=%{public}s', source);
        }).catch((err: Object) => {
          hilog.error(DOMAIN, TAG, 'mvpCommand disconnectProduct failed source=%{public}s err=%{public}s',
            source, JSON.stringify(err));
        });
        return;
      }
      hilog.warn(DOMAIN, TAG, 'unknown mvpCommand=%{public}s source=%{public}s', command, source);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'mvpCommand failed command=%{public}s source=%{public}s err=%{public}s',
        command, source, JSON.stringify(err));
    }
  }

  private handlePrepareSubscriptionCommand(params: Record<string, Object> | undefined, configService: ConfigService,
    runtimeStore: RuntimeStore, source: string): void {
    const subscriptionUrl = (params?.['subscriptionUrl'] as string | undefined) ?? '';
    const subscriptionName = (params?.['subscriptionName'] as string | undefined) ?? 'Subscription';
    if (subscriptionUrl.trim().length === 0) {
      runtimeStore.appendEvent('MVP command prepareSubscription failed: missing subscriptionUrl');
      hilog.error(DOMAIN, TAG, 'mvpCommand prepareSubscription failed source=%{public}s err=%{public}s',
        source, 'missing subscriptionUrl');
      return;
    }

    const subscriptionService = new SubscriptionService(this.context.filesDir);
    subscriptionService.addSubscription(subscriptionName, subscriptionUrl).then((profile: Profile) => {
      runtimeStore.appendEvent('MVP command prepareSubscription added profile=' + profile.id);
      hilog.info(DOMAIN, TAG, 'mvpCommand prepareSubscription added source=%{public}s profile=%{public}s',
        source, profile.id);
      return subscriptionService.update(profile.id).then((result: SubscriptionUpdateResult) => {
        if (!result.ok) {
          runtimeStore.appendEvent('MVP command prepareSubscription failed profile=' + profile.id +
            ' err=' + result.error);
          hilog.error(DOMAIN, TAG,
            'mvpCommand prepareSubscription failed source=%{public}s profile=%{public}s status=%{public}d err=%{public}s',
            source, profile.id, result.statusCode, result.error);
          return;
        }
        const activeProfile = configService.setActiveProfile(profile.id);
        runtimeStore.appendEvent('MVP command prepareSubscription ok profile=' + profile.id +
          ' bytes=' + result.bytes);
        hilog.info(DOMAIN, TAG,
          'mvpCommand prepareSubscription ok source=%{public}s profile=%{public}s active=%{public}s status=%{public}d bytes=%{public}d',
          source, profile.id, activeProfile ? 'true' : 'false', result.statusCode, result.bytes);
      });
    }).catch((err: Object) => {
      const errorText = this.toErrorText(err);
      runtimeStore.appendEvent('MVP command prepareSubscription failed: ' + errorText);
      hilog.error(DOMAIN, TAG, 'mvpCommand prepareSubscription failed source=%{public}s err=%{public}s',
        source, errorText);
    });
  }

  private copyOptionalParam(source: Record<string, Object> | undefined, target: Record<string, Object>, name: string): void {
    if (!source) {
      return;
    }
    const value = source[name];
    if (value !== undefined) {
      target[name] = value;
    }
  }

  private wantToLogText(want: Want): string {
    const params = want.parameters as Record<string, Object> | undefined;
    const safeParams: Record<string, Object> = {};
    if (params) {
      const keys = Object.keys(params);
      for (let i = 0; i < keys.length; i++) {
        const key = keys[i];
        safeParams[key] = this.sanitizeParamValue(key, params[key]);
      }
    }
    return JSON.stringify({
      bundleName: want.bundleName ?? '',
      abilityName: want.abilityName ?? '',
      uri: want.uri ? this.redactUrl(want.uri) : '',
      parameters: safeParams
    });
  }

  private sanitizeParamValue(name: string, value: Object): Object {
    if (typeof value === 'string' && name.toLowerCase().indexOf('url') >= 0) {
      return this.redactUrl(value);
    }
    return value;
  }

  private redactUrl(url: string): string {
    const schemeIndex = url.indexOf('://');
    if (schemeIndex < 0) {
      return '<redacted-url>';
    }
    const hostStart = schemeIndex + 3;
    let hostEnd = url.indexOf('/', hostStart);
    if (hostEnd < 0) {
      hostEnd = url.indexOf('?', hostStart);
    }
    if (hostEnd < 0) {
      hostEnd = url.indexOf('#', hostStart);
    }
    if (hostEnd < 0) {
      return url + '/<redacted>';
    }
    return url.substring(0, hostEnd) + '/<redacted>';
  }

  private toErrorText(err: Object): string {
    if (err instanceof Error) {
      return err.name + ': ' + err.message;
    }
    return JSON.stringify(err);
  }
}
