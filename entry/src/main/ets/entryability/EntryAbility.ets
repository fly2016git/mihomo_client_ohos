import { AbilityConstant, bundleManager, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { vpnExtension } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { ConfigService } from '../config/ConfigService';
import { ConfigValidationService } from '../config/ConfigValidationService';
import { BundledGeoIpService } from '../geo/BundledGeoIpService';
import { RuntimeStore } from '../runtime/RuntimeStore';
import { UiRefreshBus } from '../runtime/UiRefreshBus';
import { SubscriptionService } from '../subscription/SubscriptionService';

const DOMAIN = 0x0000;
const TAG = 'MihomoPocEntry';
const BUNDLE_NAME = 'com.fly.clashguard';
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
const MVP_INVALID_YAML =
  'proxies:\n' +
    '  - name: broken\n' +
    '    port: [\n';

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

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    this.ensureBundledGeoIp();
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
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onBackground');
  }

  private ensureBundledGeoIp(): void {
    try {
      const result = BundledGeoIpService.ensureInstalled(this.context.filesDir, this.context.resourceManager);
      hilog.info(DOMAIN, TAG, 'GeoIP database %{public}s path=%{public}s bytes=%{public}d',
        result.copied ? 'restored from bundle' : 'cache ready', result.path, result.bytes);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'GeoIP database initialization failed: %{public}s', this.toErrorText(err));
    }
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
    if (!this.isDebugBuild()) {
      hilog.warn(DOMAIN, TAG, 'ignored POC request in release build poc=%{public}s', poc);
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
    if (!this.isDebugBuild()) {
      hilog.warn(DOMAIN, TAG, 'ignored debug command in release build command=%{public}s', command);
      return;
    }

    try {
      const configService = new ConfigService(this.context.filesDir);
      const runtimeStore = new RuntimeStore(this.context.filesDir);
      if (command === 'setInvalidConfig') {
        const result = configService.forceWriteDefaultRawYamlForSmoke(MVP_INVALID_CONFIG);
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
      if (command === 'validateConfig') {
        const validationCase = (params?.['validationCase'] as string | undefined) ?? 'valid';
        const content = validationCase === 'invalidSyntax' ? MVP_INVALID_YAML : MVP_DEFAULT_CONFIG;
        const validationService = new ConfigValidationService(this.context.filesDir);
        validationService.validate(content).then((result) => {
          runtimeStore.appendEvent('MVP command validateConfig case=' + validationCase + ' ok=' + result.ok);
          hilog.info(DOMAIN, TAG, 'mvpCommand validateConfig complete case=%{public}s ok=%{public}s',
            validationCase, result.ok ? 'true' : 'false');
        }).catch((err: Object) => {
          hilog.error(DOMAIN, TAG, 'mvpCommand validateConfig failed case=%{public}s err=%{public}s',
            validationCase, this.toErrorText(err));
        });
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
      if (command === 'selectProxy') {
        const requestId = (params?.['requestId'] as string | undefined) ?? 'select-smoke-' + Date.now().toString();
        const profileId = (params?.['profileId'] as string | undefined) ?? '';
        const groupName = (params?.['groupName'] as string | undefined) ?? '';
        const nodeName = (params?.['nodeName'] as string | undefined) ?? '';
        configService.saveProxySelectionRequestState({
          requestId,
          profileId,
          groupName,
          nodeName,
          status: 'running',
          updatedAt: Date.now(),
          error: ''
        });
        vpnExtension.startVpnExtensionAbility({
          bundleName: BUNDLE_NAME,
          abilityName: VPN_ABILITY_NAME,
          parameters: {
            command: 'selectProxy',
            requestId,
            profileId,
            groupName,
            nodeName,
            requestedAt: new Date().toISOString(),
            requestedBy: source + ':mvpCommand'
          }
        }).then(() => {
          hilog.info(DOMAIN, TAG, 'mvpCommand selectProxy returned ok request=%{public}s', requestId);
        }).catch((err: Object) => {
          hilog.error(DOMAIN, TAG, 'mvpCommand selectProxy failed request=%{public}s err=%{public}s',
            requestId, this.toErrorText(err));
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
    subscriptionService.addSubscriptionAndUpdate(subscriptionName, subscriptionUrl).then((result) => {
      if (!result.profile || !result.result.ok) {
        runtimeStore.appendEvent('MVP command prepareSubscription failed err=' + result.result.error);
        hilog.error(DOMAIN, TAG,
          'mvpCommand prepareSubscription failed source=%{public}s status=%{public}d err=%{public}s',
          source, result.result.statusCode, result.result.error);
        return;
      }
      const activeProfile = configService.setActiveProfile(result.profile.id);
      runtimeStore.appendEvent('MVP command prepareSubscription ok profile=' + result.profile.id +
        ' bytes=' + result.result.bytes);
      hilog.info(DOMAIN, TAG,
        'mvpCommand prepareSubscription ok source=%{public}s profile=%{public}s active=%{public}s status=%{public}d bytes=%{public}d',
        source, result.profile.id, activeProfile ? 'true' : 'false', result.result.statusCode, result.result.bytes);
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
    if (typeof value === 'string') {
      const lowerName = name.toLowerCase();
      if (lowerName.indexOf('url') >= 0 || lowerName.indexOf('uri') >= 0) {
        return this.redactUrl(value);
      }
      if (lowerName.indexOf('token') >= 0 || lowerName.indexOf('password') >= 0 ||
        lowerName.indexOf('secret') >= 0 || lowerName.indexOf('authorization') >= 0) {
        return '<redacted>';
      }
    }
    return value;
  }

  private isDebugBuild(): boolean {
    try {
      const bundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      return bundleInfo.appInfo.debug;
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'failed to resolve build mode err=%{public}s', this.toErrorText(err));
      return false;
    }
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
