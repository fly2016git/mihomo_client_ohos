import { Want } from '@kit.AbilityKit';
import fs from '@ohos.file.fs';
import { connection, VpnExtensionAbility, vpnExtension } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ConfigService } from '../config/ConfigService';
import { RuntimeStore } from '../runtime/RuntimeStore';
import { TrafficStatsService } from '../runtime/TrafficStatsService';
import { Profile, ProxyLatencyRecord, ProxyLatencyState } from '../models/MvpTypes';
import { SettingsService } from '../settings/SettingsService';
import pocNative, { PocStatus } from '../native/PocNative';

const DOMAIN = 0x0001;
const TAG = 'MihomoPocVpn';
const TUN_EAGAIN_POLL_MS = 50;
const DEFAULT_UDP_ECHO_HOST = '192.168.3.62';
const DEFAULT_UDP_ECHO_PORT = 53535;
const DEFAULT_RAW_UDP_PREFLIGHT = false;
const DEFAULT_TUN_PACKET_DUMP = false;
const POC04_MINIMAL_CONFIG =
  'mixed-port: 0\n' +
    'port: 0\n' +
    'socks-port: 0\n' +
    'redir-port: 0\n' +
    'tproxy-port: 0\n' +
    'allow-lan: false\n' +
    'mode: direct\n' +
    'log-level: info\n' +
    'ipv6: false\n' +
    'find-process-mode: off\n' +
    'profile:\n' +
    '  store-selected: false\n' +
    '  store-fake-ip: false\n' +
    'dns:\n' +
    '  enable: false\n' +
    'tun:\n' +
    '  enable: false\n' +
    'proxies: []\n' +
    'proxy-groups: []\n' +
    'rules:\n' +
    '  - MATCH,DIRECT\n';
const POC05_RAW_SUBSCRIPTION =
  'mixed-port: 7890\n' +
    'allow-lan: true\n' +
    'mode: rule\n' +
    'log-level: debug\n' +
    'external-controller: 127.0.0.1:9090\n' +
    'dns:\n' +
    '  enable: true\n' +
    'tun:\n' +
    '  enable: true\n' +
    'proxies: []\n' +
    'proxy-groups: []\n' +
    'rules:\n' +
    '  - MATCH,DIRECT\n';
const POC05_UNSUPPORTED_SUBSCRIPTION =
  'script:\n' +
    '  code: reject\n' +
    'proxy-providers:\n' +
    '  demo:\n' +
    '    type: http\n' +
    POC05_RAW_SUBSCRIPTION;
const POC05_RUNTIME_CONFIG =
  'mixed-port: 0\n' +
    'port: 0\n' +
    'socks-port: 0\n' +
    'redir-port: 0\n' +
    'tproxy-port: 0\n' +
    'allow-lan: false\n' +
    'mode: direct\n' +
    'log-level: info\n' +
    'ipv6: false\n' +
    'find-process-mode: off\n' +
    'profile:\n' +
    '  store-selected: false\n' +
    '  store-fake-ip: false\n' +
    'dns:\n' +
    '  enable: false\n' +
    'tun:\n' +
    '  enable: false\n' +
    'proxies: []\n' +
    'proxy-groups: []\n' +
    'rules:\n' +
    '  - MATCH,DIRECT\n';
const POC05_RUNTIME_SWITCH_CONFIG =
  'mixed-port: 0\n' +
    'port: 0\n' +
    'socks-port: 0\n' +
    'redir-port: 0\n' +
    'tproxy-port: 0\n' +
    'allow-lan: false\n' +
    'mode: rule\n' +
    'log-level: warning\n' +
    'ipv6: false\n' +
    'find-process-mode: off\n' +
    'profile:\n' +
    '  store-selected: false\n' +
    '  store-fake-ip: false\n' +
    'dns:\n' +
    '  enable: false\n' +
    'tun:\n' +
    '  enable: false\n' +
    'proxies: []\n' +
    'proxy-groups: []\n' +
    'rules:\n' +
    '  - MATCH,DIRECT\n';
const POC06_INVALID_CONFIG =
  'mixed-port: [\n' +
    'rules:\n' +
    '  - MATCH,DIRECT\n';

interface UdpTarget {
  host: string;
  port: number;
  label: string;
}

interface Poc03Options {
  udpEchoHost: string;
  udpEchoPort: number;
  rawUdpPreflight: boolean;
  tunPacketDump: boolean;
}

interface ProductVpnOptions {
  routeMode: string;
  dnsAddress: string;
  tunReadinessProbeMs: number;
  routeInterface: string;
  routeDefaultFlag: boolean;
  ipv6Enabled: boolean;
  udpEnabled: boolean;
}

interface NativeDelayItem {
  name: string;
  delay: number;
  ok: boolean;
  error: string;
}

interface NativeDelayResult {
  ok: boolean;
  groupName: string;
  nodeName: string;
  url: string;
  timeoutMs: number;
  delays: NativeDelayItem[];
  error: string;
}

interface TunSnapshot {
  packets: number;
  bytes: number;
  loopbackPackets: number;
}

interface Poc05Layout {
  baseDir: string;
  homeDir: string;
  profileDir: string;
  runDir: string;
  cacheDir: string;
  geoDir: string;
  rawPath: string;
  runtimePath: string;
}

type Poc06State = 'idle' | 'starting' | 'connected' | 'stopping' | 'error';

class TestResult {
  ok: boolean;
  error: string;
  useProtect: boolean;
  host: string;
  port: number;
  connectMs: number;
  writeMs: number;
  readMs: number;
  sendMs: number;
  recvMs: number;
  bytesRead: number;
  bytesRecv: number;
  hasResponse: boolean;

  constructor() {
    this.ok = false;
    this.error = '';
    this.useProtect = false;
    this.host = '';
    this.port = 0;
    this.connectMs = 0;
    this.writeMs = 0;
    this.readMs = 0;
    this.sendMs = 0;
    this.recvMs = 0;
    this.bytesRead = 0;
    this.bytesRecv = 0;
    this.hasResponse = false;
  }

  static fromJson(json: string): TestResult {
    const result = new TestResult();
    try {
      const parsed: Record<string, Object> = JSON.parse(json) as Record<string, Object>;
      result.ok = (parsed['ok'] as boolean) ?? false;
      result.error = (parsed['error'] as string) ?? '';
      result.useProtect = (parsed['useProtect'] as boolean) ?? false;
      result.host = (parsed['host'] as string) ?? '';
      result.port = (parsed['port'] as number) ?? 0;
      result.connectMs = (parsed['connectMs'] as number) ?? 0;
      result.writeMs = (parsed['writeMs'] as number) ?? 0;
      result.readMs = (parsed['readMs'] as number) ?? 0;
      result.sendMs = (parsed['sendMs'] as number) ?? 0;
      result.recvMs = (parsed['recvMs'] as number) ?? 0;
      result.bytesRead = (parsed['bytesRead'] as number) ?? 0;
      result.bytesRecv = (parsed['bytesRecv'] as number) ?? 0;
      result.hasResponse = (parsed['hasResponse'] as boolean) ?? false;
    } catch (_) {
      result.error = 'JSON parse failed: ' + json;
    }
    return result;
  }
}

export default class MihomoPocVpnAbility extends VpnExtensionAbility {
  private vpnContext: vpnExtension.VpnExtensionContext | null = null;
  private vpnConnection: vpnExtension.VpnConnection | null = null;
  private tunFd: number = -1;
  private connectCount: number = 0;

  // POC-03: TUN packet counter
  private tunPackets: number = 0;
  private tunBytes: number = 0;
  private tunLoopbackPackets: number = 0;
  private tunReading: boolean = false;

  // POC-03: protect callback registration state
  private protectRegistered: boolean = false;
  private forceProtectFailure: boolean = false;
  private poc03Results: string[] = [];
  private poc04Results: string[] = [];
  private poc05Results: string[] = [];
  private poc06Results: string[] = [];
  private poc06State: Poc06State = 'idle';
  private startInProgress: boolean = false;
  private destroyInProgress: boolean = false;
  private trafficStatsService?: TrafficStatsService;
  private trafficTimer: number = -1;
  private trafficStatsFailed: boolean = false;
  private trafficSampleInFlight: boolean = false;
  private poc04Started: boolean = false;
  private mihomoStartedBy: string = '';
  private poc03Options: Poc03Options = {
    udpEchoHost: DEFAULT_UDP_ECHO_HOST,
    udpEchoPort: DEFAULT_UDP_ECHO_PORT,
    rawUdpPreflight: DEFAULT_RAW_UDP_PREFLIGHT,
    tunPacketDump: DEFAULT_TUN_PACKET_DUMP
  };

  onCreate(want: Want): void {
    this.vpnContext = this.context;
    hilog.info(DOMAIN, TAG, 'onCreate want=%{public}s', JSON.stringify(want));
  }

  onRequest(want: Want, startId: number): void {
    hilog.info(DOMAIN, TAG, 'onRequest startId=%{public}d want=%{public}s', startId, JSON.stringify(want));
    if (this.isProductConnectWant(want)) {
      this.startVpnForProduct(want, 'onRequest').catch((err: Object) => {
        hilog.error(DOMAIN, TAG, 'product onRequest async failed: %{public}s', this.toErrorText(err));
      });
      return;
    }
    if (this.isProductDisconnectWant(want)) {
      this.stopVpnForProduct('onRequest').catch((err: Object) => {
        hilog.error(DOMAIN, TAG, 'product disconnect async failed: %{public}s', this.toErrorText(err));
      });
      return;
    }
    if (this.isProductLatencyWant(want)) {
      this.runProductLatency(want).catch((err: Object) => {
        hilog.error(DOMAIN, TAG, 'product latency async failed: %{public}s', this.toErrorText(err));
      });
      return;
    }
    this.startVpnForPoc(want, 'onRequest').catch((err: Object) => {
      hilog.error(DOMAIN, TAG, 'onRequest async failed: %{public}s', this.toErrorText(err));
    });
  }

  async onConnect(want: Want): Promise<void> {
    if (this.isProductConnectWant(want)) {
      await this.startVpnForProduct(want, 'onConnect');
      return;
    }
    if (this.isProductLatencyWant(want)) {
      await this.runProductLatency(want);
      return;
    }
    await this.startVpnForPoc(want, 'onConnect');
  }

  private isProductConnectWant(want: Want): boolean {
    const params = want.parameters as Record<string, Object> | undefined;
    return this.getStringParam(params, 'command', '').toLowerCase() === 'connect';
  }

  private isProductDisconnectWant(want: Want): boolean {
    const params = want.parameters as Record<string, Object> | undefined;
    return this.getStringParam(params, 'command', '').toLowerCase() === 'disconnect';
  }

  private isProductLatencyWant(want: Want): boolean {
    const params = want.parameters as Record<string, Object> | undefined;
    return this.getStringParam(params, 'command', '').toLowerCase() === 'latency';
  }

  private async startVpnForProduct(want: Want, source: string): Promise<void> {
    const store = new RuntimeStore(this.context.filesDir);
    const configService = new ConfigService(this.context.filesDir);
    const params = want.parameters as Record<string, Object> | undefined;
    const requestedProfileId = this.getStringParam(params, 'profileId', 'default');
    const vpnOptions = this.parseProductVpnOptions(params);
    const profile = configService.getProfile(requestedProfileId) ?? configService.ensureDefaultProfile();

    hilog.info(DOMAIN, TAG,
      'product %{public}s connect profile=%{public}s routeMode=%{public}s dns=%{public}s readProbeMs=%{public}d',
      source, profile.id, vpnOptions.routeMode, vpnOptions.dnsAddress, vpnOptions.tunReadinessProbeMs);
    hilog.info(DOMAIN, TAG, 'product route options interface=%{public}s defaultFlag=%{public}s',
      vpnOptions.routeInterface.length > 0 ? vpnOptions.routeInterface : '<empty>',
      vpnOptions.routeDefaultFlag ? 'true' : 'false');
    if (this.startInProgress) {
      store.update({
        runtimeState: 'error',
        coreState: 'error',
        lastError: 'BUSY',
        lastEvent: 'Connect rejected: busy'
      });
      store.appendEvent('Connect rejected: busy');
      return;
    }

    this.startInProgress = true;
    this.setPoc06State('starting', 'product connect profile=' + profile.id);
    store.update({
      runtimeState: 'starting',
      coreState: 'loading',
      activeProfileId: profile.id,
      activeProfileName: profile.name,
      tunFd: -1,
      lastError: '',
      lastEvent: 'Starting VPN'
    });
    store.appendEvent('Starting VPN profile=' + profile.name);

    try {
      if (!this.vpnContext) {
        throw new Error('VPN_CREATE_FAILED: vpn context is null');
      }
      if (this.vpnConnection && this.tunFd >= 0) {
        await this.destroyVpn();
      }

      this.ensureProductRuntimeReady(configService, profile);
      this.vpnConnection = vpnExtension.createVpnConnection(this.vpnContext);
      const vpnConfig = this.createPocConfig(vpnOptions);
      hilog.info(DOMAIN, TAG, 'product creating vpn config=%{public}s', JSON.stringify(vpnConfig));
      this.tunFd = await this.vpnConnection.create(vpnConfig);
      hilog.info(DOMAIN, TAG, 'product tunFd created fd=%{public}d', this.tunFd);
      store.update({
        tunFd: this.tunFd,
        lastEvent: 'VPN created'
      });
      store.appendEvent('VPN created fd=' + this.tunFd);

      await this.registerProductProtect(store);

      const loadStatus = await pocNative.loadMihomoCore();
      if (!loadStatus.ok) {
        throw new Error('CORE_LOAD_FAILED: ' + loadStatus.message);
      }
      store.update({
        coreState: 'loading',
        lastEvent: 'Core loaded'
      });
      store.appendEvent('Core loaded');
      try {
        const versionStatus = await pocNative.getMihomoVersion();
        store.appendEvent('Mihomo version: ' + (versionStatus.ok ? versionStatus.message :
          'unavailable code=' + versionStatus.code.toString()), versionStatus.ok ? 'info' : 'warn', 'core');
      } catch (err) {
        store.appendEvent('Mihomo version unavailable: ' + this.toErrorText(err), 'warn', 'core');
      }

      const startStatus = await pocNative.startMihomoConfigFileWithTunFd(
        profile.homeDir, profile.runtimePath, this.tunFd);
      if (!startStatus.ok) {
        throw new Error('CORE_START_FAILED: ' + startStatus.message);
      }
      store.appendEvent('Core start status: ' + startStatus.message);
      hilog.info(DOMAIN, TAG, 'MVP-01B core start status: %{public}s', startStatus.message);

      // MVP-01B: startWithConfig auto-enables the outbound protect hook in the
      // same Go runtime entry as mihomo startup. Do not call enableProtectHook()
      // again from the JS thread; on device this second cgo entry can crash.
      store.appendEvent('Protect hook auto-enabled by Go bridge');
      hilog.info(DOMAIN, TAG, 'MVP-01B protect hook auto-enabled by startWithConfig');

      if (vpnOptions.tunReadinessProbeMs > 0) {
        const pollProbeStatus = pocNative.startTunFdPollProbe(this.tunFd, vpnOptions.tunReadinessProbeMs);
        store.appendEvent('TUN poll probe started ok=' + pollProbeStatus.ok);
        hilog.warn(DOMAIN, TAG, 'TUN poll probe requested ms=%{public}d ok=%{public}s msg=%{public}s',
          vpnOptions.tunReadinessProbeMs, pollProbeStatus.ok ? 'true' : 'false', pollProbeStatus.message);
      } else {
        store.appendEvent('TUN poll probe disabled');
      }
      this.poc04Started = true;
      this.mihomoStartedBy = 'MVP-01A';
      this.setPoc06State('connected', 'product connect ok');
      store.update({
        runtimeState: 'connected',
        coreState: 'running',
        activeProfileId: profile.id,
        activeProfileName: profile.name,
        tunFd: this.tunFd,
        startedAt: Date.now(),
        lastError: '',
        lastEvent: 'Connected'
      });
      store.appendEvent('Connected profile=' + profile.name);
      await this.startTrafficPolling(store);
    } catch (err) {
      const errorText = this.toErrorText(err);
      this.setPoc06State('error', 'product connect failed ' + errorText);
      store.update({
        runtimeState: 'error',
        coreState: 'error',
        lastError: errorText,
        lastEvent: 'Connect failed'
      });
      store.appendEvent('Connect failed: ' + errorText);
      await this.destroyVpn();
    } finally {
      this.startInProgress = false;
    }
  }

  private async startTrafficPolling(store: RuntimeStore): Promise<void> {
    this.stopTrafficPolling(false);
    const layout = new ConfigService(this.context.filesDir).ensureLayout();
    store.appendEvent('Traffic stats writer starting', 'info', 'vpn');
    const writerStatus = await pocNative.startMihomoTrafficStatsWriter(layout.trafficStatsPath);
    if (!writerStatus.ok) {
      store.appendEvent('Traffic stats writer failed: ' + writerStatus.message, 'warn', 'vpn');
      return;
    }
    await this.sleep(300);
    this.trafficStatsService = new TrafficStatsService(this.context.filesDir);
    this.trafficStatsFailed = false;
    this.trafficSampleInFlight = false;
    try {
      await this.trafficStatsService.resetBaseline();
      store.appendEvent('Traffic stats source=native-mihomo', 'info', 'vpn');
    } catch (err) {
      this.trafficStatsFailed = true;
      store.appendEvent('Traffic stats unavailable: ' + this.toErrorText(err), 'warn', 'vpn');
      return;
    }

    this.trafficTimer = setInterval(async () => {
      if (!this.trafficStatsService || this.trafficSampleInFlight) {
        return;
      }
      this.trafficSampleInFlight = true;
      try {
        await this.trafficStatsService.sampleAndUpdate();
      } catch (err) {
        if (!this.trafficStatsFailed) {
          this.trafficStatsFailed = true;
          new RuntimeStore(this.context.filesDir).appendEvent('Traffic stats stopped: ' + this.toErrorText(err),
            'warn', 'vpn');
        }
        this.stopTrafficPolling(true);
      } finally {
        this.trafficSampleInFlight = false;
      }
    }, 1000);
  }

  private stopTrafficPolling(updateRuntime: boolean): void {
    if (this.trafficTimer >= 0) {
      clearInterval(this.trafficTimer);
      this.trafficTimer = -1;
    }
    this.trafficSampleInFlight = false;
    if (updateRuntime && this.trafficStatsService) {
      try {
        this.trafficStatsService.stopAndKeepDaily();
      } catch (_) {
      }
    }
    this.trafficStatsService = undefined;
  }

  private ensureProductRuntimeReady(configService: ConfigService, profile: Profile): void {
    configService.ensureLayout();
    const rawYaml = configService.loadRawYaml(profile.id);
    const validation = configService.validateRawYaml(rawYaml);
    if (!validation.ok) {
      throw new Error('CONFIG_UNSUPPORTED_FIELD: ' + validation.errors.join('; '));
    }
    const settings = new SettingsService(this.context.filesDir).load();
    configService.writeTextFile(profile.runtimePath, configService.generateRuntimeYaml(rawYaml, settings));
  }

  private async registerProductProtect(store: RuntimeStore): Promise<void> {
    const regStatus = pocNative.registerProtect(async (fd: number): Promise<number> => {
      if (!this.vpnConnection) {
        return -901;
      }
      try {
        await this.vpnConnection.protect(fd);
        return 0;
      } catch (err) {
        store.appendEvent('Protect failed fd=' + fd + ' err=' + this.toErrorText(err));
        return -902;
      }
    });
    this.protectRegistered = regStatus.ok;
    if (!regStatus.ok) {
      throw new Error('PROTECT_REGISTER_FAILED: ' + regStatus.message);
    }
    store.appendEvent('Protect callback registered');
  }

  private async runProductLatency(want: Want): Promise<void> {
    const store = new RuntimeStore(this.context.filesDir);
    const configService = new ConfigService(this.context.filesDir);
    const params = want.parameters as Record<string, Object> | undefined;
    const requestId = this.getStringParam(params, 'requestId', 'latency-' + Date.now().toString());
    const profileId = this.getStringParam(params, 'profileId', 'default');
    const groupNames = this.parseLatencyGroupNames(this.getStringParam(params, 'groupNames', ''));
    const url = this.getStringParam(params, 'url', 'http://www.gstatic.com/generate_204');
    const timeoutMs = this.getNumberParam(params, 'timeoutMs', 8000);
    const previous = configService.loadProxyLatencyState().records;
    const remaining = previous.filter((record: ProxyLatencyRecord) => {
      return record.profileId !== profileId || groupNames.indexOf(record.groupName) < 0;
    });

    hilog.info(DOMAIN, TAG, 'product latency request id=%{public}s profile=%{public}s groups=%{public}d',
      requestId, profileId, groupNames.length);

    if (groupNames.length === 0) {
      this.saveProductLatencyState(configService, requestId, 'error', 'no latency groups requested', previous);
      store.appendEvent('Latency test error: no latency groups requested');
      return;
    }

    if (this.mihomoStartedBy.length === 0) {
      this.saveProductLatencyState(configService, requestId, 'error',
        'mihomo not running in VPN process', previous);
      store.appendEvent('Latency test error: mihomo not running in VPN process');
      return;
    }

    const now = Date.now();
    const nextRecords: ProxyLatencyRecord[] = [];
    const errors: string[] = [];
    let tested = 0;
    let failed = 0;

    for (const groupName of groupNames) {
      try {
        const json = await pocNative.testMihomoGroupDelay(groupName, url, timeoutMs);
        const result = this.parseNativeDelayResult(json);
        if (!result.ok && result.error.length > 0) {
          errors.push(groupName + ': ' + result.error);
        }
        for (const item of result.delays) {
          if (item.ok && item.delay > 0) {
            nextRecords.push({
              profileId,
              groupName,
              nodeName: item.name,
              delay: item.delay,
              updatedAt: now
            });
            tested += 1;
          } else {
            failed += 1;
            if (item.error.length > 0) {
              errors.push(item.name + ': ' + item.error);
            }
          }
        }
      } catch (err) {
        failed += 1;
        errors.push(groupName + ': ' + this.toErrorText(err));
      }
    }

    const errorText = errors.length > 0 ? errors[0] : '';
    const records = remaining.concat(nextRecords);
    const status = tested > 0 ? 'complete' : 'error';
    configService.saveProxyLatencyState({
      requestId,
      status,
      updatedAt: Date.now(),
      error: status === 'complete' ? errorText : (errorText.length > 0 ? errorText : 'latency test failed'),
      records
    });
    store.appendEvent('Latency test native scope=request groups=' + groupNames.length.toString() +
      ' ok=' + tested.toString() + ' failed=' + failed.toString());
    if (errorText.length > 0) {
      store.appendEvent('Latency test error: ' + errorText);
    }
  }

  private saveProductLatencyState(configService: ConfigService, requestId: string, status: 'error',
    error: string, records: ProxyLatencyRecord[]): void {
    const state: ProxyLatencyState = {
      requestId,
      status,
      updatedAt: Date.now(),
      error,
      records
    };
    configService.saveProxyLatencyState(state);
  }

  private async stopVpnForProduct(source: string): Promise<void> {
    const store = new RuntimeStore(this.context.filesDir);
    hilog.info(DOMAIN, TAG, 'product %{public}s disconnect fd=%{public}d', source, this.tunFd);
    store.update({
      runtimeState: 'stopping',
      coreState: 'stopping',
      lastError: '',
      lastEvent: 'Stopping VPN'
    });
    store.appendEvent('Stopping VPN');

    try {
      const hasTunFd = this.tunFd >= 0;

      // MVP-01B disconnect protocol:
      // 1. If fd-backed TUN, attempt graceful stop via hub.Parse(stoppedConfig)
      //    which drains mihomo TUN reader goroutines. Otherwise call stop.
      // 2. Brief cooldown before destroying VPN/TUN fd.
      if (hasTunFd) {
        // Try graceful stop: switch mihomo to no-TUN config to drain reader goroutines
        try {
          const gracefulStatus: PocStatus = await pocNative.gracefulStopMihomo();
          store.appendEvent('Mihomo graceful stop: ' + (gracefulStatus.ok ? 'ok' : 'failed code=' + gracefulStatus.code));
          hilog.info(DOMAIN, TAG, 'MVP-01B gracefulStopMihomo ok=%{public}s code=%{public}d',
            gracefulStatus.ok ? 'true' : 'false', gracefulStatus.code);
        } catch (err) {
          hilog.warn(DOMAIN, TAG, 'MVP-01B gracefulStopMihomo threw: %{public}s', this.toErrorText(err));
          store.appendEvent('Mihomo graceful stop threw: ' + this.toErrorText(err));
        }
      } else {
        store.appendEvent('MVP-01B disconnect: no active TUN fd, skipping graceful stop');
      }

      // Brief cooldown before destroying VPN/TUN fd
      await this.sleep(500);

      this.stopTrafficPolling(true);
      await this.destroyVpn();
      store.update({
        runtimeState: 'idle',
        coreState: 'stopped',
        tunFd: -1,
        uploadSpeed: 0,
        downloadSpeed: 0,
        lastError: '',
        lastEvent: 'Disconnected'
      });
      store.appendEvent('Disconnected');
      hilog.info(DOMAIN, TAG, 'product disconnect complete');
    } catch (err) {
      const errorText = this.toErrorText(err);
      store.update({
        runtimeState: 'error',
        coreState: 'error',
        lastError: errorText,
        lastEvent: 'Disconnect failed'
      });
      store.appendEvent('Disconnect failed: ' + errorText);
      hilog.error(DOMAIN, TAG, 'product disconnect failed: %{public}s', errorText);
    }
  }

  private async startVpnForPoc(want: Want, source: string): Promise<void> {
    this.connectCount += 1;
    hilog.info(DOMAIN, TAG, '%{public}s start count=%{public}d want=%{public}s',
      source, this.connectCount, JSON.stringify(want));

    if (!this.vpnContext) {
      hilog.error(DOMAIN, TAG, '%{public}s failed: vpn context is null', source);
      return;
    }

    const params = want.parameters as Record<string, Object> | undefined;
    const pocName = this.getStringParam(params, 'poc', 'POC-03').toUpperCase();
    if (this.startInProgress) {
      hilog.warn(DOMAIN, TAG, 'POC-06 busy start rejected poc=%{public}s state=%{public}s fd=%{public}d',
        pocName, this.poc06State, this.tunFd);
      this.poc06Results.push('POC-06 busy start rejected poc=' + pocName + ' state=' + this.poc06State);
      return;
    }
    if (pocName === 'POC-06') {
      this.poc06Results = [];
    }

    this.startInProgress = true;
    this.setPoc06State('starting', source + ' start poc=' + pocName);
    try {
      if (this.vpnConnection && this.tunFd >= 0) {
        hilog.warn(DOMAIN, TAG, 'existing vpn detected, destroy before recreate tunFd=%{public}d', this.tunFd);
        await this.destroyVpn();
      }

      this.poc03Options = this.parsePoc03Options(want);
      hilog.info(DOMAIN, TAG,
        'POC options poc=%{public}s udpEcho=%{public}s:%{public}d rawUdpPreflight=%{public}s tunPacketDump=%{public}s',
        pocName,
        this.poc03Options.udpEchoHost, this.poc03Options.udpEchoPort,
        this.poc03Options.rawUdpPreflight ? 'true' : 'false',
        this.poc03Options.tunPacketDump ? 'true' : 'false');

      if (pocName !== 'POC-04' && pocName !== 'POC-05' && this.poc03Options.rawUdpPreflight) {
        await this.runRawUdpPreflight();
      }

      this.vpnConnection = vpnExtension.createVpnConnection(this.vpnContext);
      const config = this.createPocConfig();
      hilog.info(DOMAIN, TAG, 'creating vpn config=%{public}s', JSON.stringify(config));

      this.tunFd = await this.vpnConnection.create(config);
      hilog.info(DOMAIN, TAG, 'tunFd created fd=%{public}d', this.tunFd);

      await this.probeTunFd(this.tunFd);

      hilog.info(DOMAIN, TAG, 'POC-03 about to init after tun probe fd=%{public}d', this.tunFd);
      if (pocName === 'POC-04') {
        await this.initPoc04();
        hilog.info(DOMAIN, TAG, 'POC-04 init returned fd=%{public}d', this.tunFd);
      } else if (pocName === 'POC-05') {
        await this.initPoc05();
        hilog.info(DOMAIN, TAG, 'POC-05 init returned fd=%{public}d', this.tunFd);
      } else if (pocName === 'POC-06') {
        await this.initPoc06();
        hilog.info(DOMAIN, TAG, 'POC-06 init returned fd=%{public}d', this.tunFd);
      } else {
        hilog.info(DOMAIN, TAG, 'POC-03 skip synchronous loadGoCore preflight in VPN process');
        // POC-03: Ensure Go core loaded, register protect callback, start TUN reader
        await this.initPoc03();
        hilog.info(DOMAIN, TAG, 'POC-03 init returned fd=%{public}d', this.tunFd);
      }

      if (pocName !== 'POC-06') {
        this.setPoc06State('connected', source + ' complete poc=' + pocName);
      }
      hilog.info(DOMAIN, TAG, '%{public}s complete fd=%{public}d', source, this.tunFd);
    } catch (err) {
      this.setPoc06State('error', source + ' failed poc=' + pocName + ' err=' + this.toErrorText(err));
      hilog.error(DOMAIN, TAG, '%{public}s failed: %{public}s', source, this.toErrorText(err));
      await this.destroyVpn();
    } finally {
      this.startInProgress = false;
    }
  }

  async onDisconnect(): Promise<void> {
    hilog.info(DOMAIN, TAG, 'onDisconnect start fd=%{public}d', this.tunFd);
    await this.destroyVpn();
    try {
      const store = new RuntimeStore(this.context.filesDir);
      store.update({
        runtimeState: 'idle',
        coreState: 'stopped',
        tunFd: -1,
        lastError: '',
        lastEvent: 'Disconnected'
      });
      store.appendEvent('Disconnected');
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'runtime store update on disconnect failed: %{public}s', this.toErrorText(err));
    }
    hilog.info(DOMAIN, TAG, 'onDisconnect complete');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy fd=%{public}d', this.tunFd);
    // Do not destroy the VPN from lifecycle teardown. The extension can be
    // destroyed when the UI leaves foreground, while the VPN session must stay
    // alive until an explicit disconnect/onDisconnect path runs.
  }

  // ---------- POC-01: VPN config and TUN probe ----------

  private createPocConfig(options?: ProductVpnOptions): vpnExtension.VpnConfig {
    const routeMode = options?.routeMode ?? 'split-default';
    const dnsAddress = options?.dnsAddress ?? '10.7.0.3';
    const routeInterface = options?.routeInterface ?? 'vpn-tun';
    const routeDefaultFlag = options?.routeDefaultFlag ?? true;
    const localRoute: connection.RouteInfo = {
      interface: routeInterface,
      destination: {
        address: { address: '10.7.0.0', family: 1 },
        prefixLength: 24
      },
      gateway: { address: '0.0.0.0', family: 1 },
      hasGateway: false,
      isDefaultRoute: false,
      isExcludedRoute: false
    };
    const defaultRoute: connection.RouteInfo = {
      interface: routeInterface,
      destination: {
        address: { address: '0.0.0.0', family: 1 },
        prefixLength: 0
      },
      gateway: { address: '0.0.0.0', family: 1 },
      hasGateway: false,
      isDefaultRoute: routeDefaultFlag,
      isExcludedRoute: false
    };
    const splitDefaultRoutes: connection.RouteInfo[] = [
      {
        interface: routeInterface,
        destination: {
          address: { address: '0.0.0.0', family: 1 },
          prefixLength: 1
        },
        gateway: { address: '0.0.0.0', family: 1 },
        hasGateway: false,
        isDefaultRoute: routeDefaultFlag,
        isExcludedRoute: false
      },
      {
        interface: routeInterface,
        destination: {
          address: { address: '128.0.0.0', family: 1 },
          prefixLength: 1
        },
        gateway: { address: '0.0.0.0', family: 1 },
        hasGateway: false,
        isDefaultRoute: routeDefaultFlag,
        isExcludedRoute: false
      }
    ];

    // Resolve routes and blocking mode
    let routes: connection.RouteInfo[];
    let isBlocking: boolean;
    switch (routeMode) {
      case 'blocking-empty':
        routes = [];
        isBlocking = true;
        break;
      case 'blocking-split':
        routes = splitDefaultRoutes;
        isBlocking = true;
        break;
      case 'blocking-default':
        routes = [defaultRoute];
        isBlocking = true;
        break;
      case 'no-routes':
        routes = [];
        isBlocking = false;
        break;
      case 'exclude-local':
        routes = [localRoute];
        isBlocking = true;
        break;
      case 'default':
        routes = [defaultRoute];
        isBlocking = false;
        break;
      default: // split-default
        routes = splitDefaultRoutes;
        isBlocking = false;
        break;
    }

    hilog.info(DOMAIN, TAG,
      'createPocConfig routeMode=%{public}s isBlocking=%{public}s routeCount=%{public}d dns=%{public}s interface=%{public}s defaultFlag=%{public}s routes=%{public}s',
      routeMode, isBlocking ? 'true' : 'false', routes.length, dnsAddress,
      routeInterface.length > 0 ? routeInterface : '<empty>', routeDefaultFlag ? 'true' : 'false',
      JSON.stringify(routes));

    return {
      addresses: [
        {
          address: { address: '10.7.0.2', family: 1 },
          prefixLength: 24
        }
      ],
      routes: routes,
      dnsAddresses: [dnsAddress],
      mtu: 1500,
      isIPv4Accepted: true,
      isIPv6Accepted: options?.ipv6Enabled ?? false,
      isBlocking: isBlocking,
      blockedApplications: ['com.example.mihomopoc']
    };
  }

  private async probeTunFd(fd: number): Promise<void> {
    const writeBuffer = new Uint8Array([
      0x45, 0x00, 0x00, 0x14, 0x00, 0x00, 0x40, 0x00, 0x40, 0x01,
      0x00, 0x00, 0x0a, 0x07, 0x00, 0x02, 0x0a, 0x07, 0x00, 0x01
    ]).buffer;

    try {
      const written = await fs.write(fd, writeBuffer);
      hilog.info(DOMAIN, TAG, 'tunFd write probe ok bytes=%{public}d fd=%{public}d', written, fd);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'tunFd write probe failed fd=%{public}d err=%{public}s',
        fd, this.toErrorText(err));
    }

    try {
      const readBuffer = new ArrayBuffer(2048);
      const readBytes = await fs.read(fd, readBuffer);
      hilog.info(DOMAIN, TAG, 'tunFd read probe ok bytes=%{public}d fd=%{public}d', readBytes, fd);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'tunFd read probe failed or no packet available fd=%{public}d err=%{public}s',
        fd, this.toErrorText(err));
    }
  }

  // ---------- POC-03: TUN reader (packet counter for loopback detection) ----------

  private startTunReader(): void {
    if (this.tunReading) {
      hilog.warn(DOMAIN, TAG, 'tun reader already running');
      return;
    }
    this.tunReading = true;
    this.tunPackets = 0;
    this.tunBytes = 0;
    this.tunLoopbackPackets = 0;
    const fd = this.tunFd;
    hilog.info(DOMAIN, TAG, 'tun reader starting fd=%{public}d', fd);

    // Fire and forget - runs in background
    this.runTunReaderLoop(fd);
  }

  private async runTunReaderLoop(fd: number): Promise<void> {
    const readBuf = new ArrayBuffer(2048);
    while (this.tunReading && fd >= 0) {
      try {
        const bytesRead = await fs.read(fd, readBuf);
        if (bytesRead > 0) {
          this.tunPackets += 1;
          this.tunBytes += bytesRead;
          const packetSummary = this.describeIpv4Packet(readBuf, bytesRead);
          if (this.tunPackets % 50 === 1) {
            hilog.info(DOMAIN, TAG, 'tun packets=%{public}d bytes=%{public}d loopback=%{public}d',
              this.tunPackets, this.tunBytes, this.tunLoopbackPackets);
          }
          if (this.poc03Options.tunPacketDump && this.tunPackets <= 12) {
            hilog.info(DOMAIN, TAG, 'tun packet #%{public}d %{public}s',
              this.tunPackets, packetSummary);
          }
        } else {
          await this.sleep(TUN_EAGAIN_POLL_MS);
        }
      } catch (err) {
        if (this.tunReading) {
          const errorText = this.toErrorText(err);
          if (this.isTryAgainError(errorText)) {
            await this.sleep(TUN_EAGAIN_POLL_MS);
            continue;
          }
          hilog.info(DOMAIN, TAG, 'tun reader stopping: %{public}s', errorText);
        }
        break;
      }
    }
    hilog.info(DOMAIN, TAG, 'tun reader stopped packets=%{public}d bytes=%{public}d',
      this.tunPackets, this.tunBytes);
  }

  private stopTunReader(): void {
    this.tunReading = false;
    hilog.info(DOMAIN, TAG, 'tun reader stop requested final packets=%{public}d bytes=%{public}d',
      this.tunPackets, this.tunBytes);
  }

  private getTunSnapshot(): TunSnapshot {
    const snap: TunSnapshot = {
      packets: this.tunPackets,
      bytes: this.tunBytes,
      loopbackPackets: this.tunLoopbackPackets
    };
    return snap;
  }

  // ---------- POC-03: Protect callback and socket tests ----------

  private async runRawUdpPreflight(): Promise<void> {
    hilog.info(DOMAIN, TAG, 'POC-03 raw UDP preflight before VPN begin');
    for (const target of this.getUdpTargets(true)) {
      try {
        const udpJson = await pocNative.runUdpTest(target.host, target.port, false);
        hilog.info(DOMAIN, TAG,
          'POC-03 raw UDP preflight label=%{public}s host=%{public}s port=%{public}d result=%{public}s',
          target.label, target.host, target.port, udpJson);
      } catch (err) {
        hilog.error(DOMAIN, TAG,
          'POC-03 raw UDP preflight label=%{public}s host=%{public}s port=%{public}d threw=%{public}s',
          target.label, target.host, target.port, this.toErrorText(err));
      }
    }
    hilog.info(DOMAIN, TAG, 'POC-03 raw UDP preflight before VPN end');
  }

  private async initPoc03(): Promise<void> {
    this.poc03Results = [];

    // Step 1: Avoid synchronous Go calls on the VPN Extension ArkTS thread.
    // The first Go call is made by runTcpTest/runUdpTest on a NAPI async worker thread.
    this.poc03Results.push('POC-03 init begin');
    hilog.info(DOMAIN, TAG, 'POC-03 init begin fd=%{public}d', this.tunFd);
    this.poc03Results.push('POC-03 loadGoCore skipped in VPN main thread');
    hilog.info(DOMAIN, TAG, 'POC-03 loadGoCore skipped in VPN main thread');

    // Step 2: Register protect callback
    try {
      hilog.info(DOMAIN, TAG, 'POC-03 calling registerProtect');
      const regStatus = pocNative.registerProtect(async (fd: number): Promise<number> => {
        hilog.info(DOMAIN, TAG, 'POC-03 protect callback: protecting fd=%{public}d', fd);
        if (this.forceProtectFailure) {
          hilog.warn(DOMAIN, TAG, 'POC-03 protect forced failure fd=%{public}d', fd);
          return -900;
        }
        if (!this.vpnConnection) {
          hilog.error(DOMAIN, TAG, 'POC-03 protect skipped: no vpnConnection fd=%{public}d', fd);
          return -901;
        }
        try {
          await this.vpnConnection.protect(fd);
          hilog.info(DOMAIN, TAG, 'POC-03 protect success fd=%{public}d', fd);
          return 0;
        } catch (err) {
          hilog.error(DOMAIN, TAG, 'POC-03 protect failed fd=%{public}d err=%{public}s',
            fd, this.toErrorText(err));
          return -902;
        }
      });

      this.protectRegistered = regStatus.ok;
      hilog.info(DOMAIN, TAG, 'POC-03 registerProtect returned ok=%{public}s code=%{public}d msg=%{public}s',
        regStatus.ok ? 'true' : 'false', regStatus.code, regStatus.message);
      this.poc03Results.push('POC-03 registerProtect ok=' + regStatus.ok + ' msg=' + regStatus.message);
      if (!regStatus.ok) {
        hilog.error(DOMAIN, TAG, 'POC-03 protect callback registration failed: %{public}s', regStatus.message);
      }
    } catch (err) {
      const msg = 'POC-03 registerProtect threw: ' + this.toErrorText(err);
      this.poc03Results.push(msg);
      hilog.error(DOMAIN, TAG, '%{public}s', msg);
    }

    // Step 3: Start TUN reader for loopback detection
    hilog.info(DOMAIN, TAG, 'POC-03 starting tun reader');
    this.startTunReader();

    // Step 4: Wait briefly for TUN reader to stabilize
    hilog.info(DOMAIN, TAG, 'POC-03 waiting before socket tests');
    await this.sleep(300);

    // Step 5: Run POC-03 socket tests
    hilog.info(DOMAIN, TAG, 'POC-03 calling socket tests');
    await this.runPoc03SocketTests();
    hilog.info(DOMAIN, TAG, 'POC-03 socket tests returned');
  }

  private async runPoc03SocketTests(): Promise<void> {
    hilog.info(DOMAIN, TAG, 'POC-03 socket tests begin');
    let failures = 0;

    // --- Test 1: TCP with protect (expected: success) ---
    const tcpBefore = this.getTunSnapshot();
    this.poc03Results.push('POC-03 TCP test WITH protect...');

    try {
      const tcpResultJson = await pocNative.runTcpTest('1.1.1.1', 80, true);
      const tcpResult = TestResult.fromJson(tcpResultJson);
      await this.sleep(500);
      const tcpAfter = this.getTunSnapshot();
      const tunDelta = tcpAfter.loopbackPackets - tcpBefore.loopbackPackets;
      const totalTunDelta = tcpAfter.packets - tcpBefore.packets;

      this.poc03Results.push(
        'POC-03 TCP+protect: ok=' + tcpResult.ok +
        ' connectMs=' + tcpResult.connectMs +
        ' readMs=' + tcpResult.readMs +
        ' bytes=' + tcpResult.bytesRead +
        ' error=' + tcpResult.error +
        ' loopbackDelta=' + tunDelta +
        ' totalTunDelta=' + totalTunDelta
      );
      if (tcpResult.error.length > 0) {
        this.poc03Results.push('POC-03 TCP+protect error: ' + tcpResult.error);
      }
      if (!tcpResult.ok) {
        failures += 1;
        hilog.error(DOMAIN, TAG, 'POC-03 TCP+protect FAILED: %{public}s', tcpResultJson);
      } else if (tunDelta > 2) {
        this.poc03Results.push('POC-03 WARNING: loopbackDelta=' + tunDelta + ' - possible loopback!');
        hilog.warn(DOMAIN, TAG, 'POC-03 possible loopback: loopbackDelta=%{public}d totalTunDelta=%{public}d',
          tunDelta, totalTunDelta);
      } else {
        hilog.info(DOMAIN, TAG, 'POC-03 TCP+protect PASS loopbackDelta=%{public}d totalTunDelta=%{public}d',
          tunDelta, totalTunDelta);
      }
    } catch (err) {
      failures += 1;
      this.poc03Results.push('POC-03 TCP+protect threw: ' + this.toErrorText(err));
    }

    await this.sleep(300);

    // --- Test 2: TCP with forced protect failure (expected: clear failure before connect) ---
    this.poc03Results.push('POC-03 TCP test WITH forced protect failure...');
    this.forceProtectFailure = true;

    try {
      const tcpFailJson = await pocNative.runTcpTest('1.1.1.1', 80, true);
      const tcpFailResult = TestResult.fromJson(tcpFailJson);
      this.poc03Results.push(
        'POC-03 TCP forced protect failure: ok=' + tcpFailResult.ok +
        ' error=' + tcpFailResult.error
      );
      if (tcpFailResult.ok || tcpFailResult.error.indexOf('protect() failed') < 0) {
        failures += 1;
        hilog.error(DOMAIN, TAG, 'POC-03 forced protect failure did not fail clearly: %{public}s', tcpFailJson);
      } else {
        hilog.info(DOMAIN, TAG, 'POC-03 forced protect failure PASS: %{public}s', tcpFailJson);
      }
    } catch (err) {
      failures += 1;
      this.poc03Results.push('POC-03 TCP forced protect failure threw: ' + this.toErrorText(err));
    } finally {
      this.forceProtectFailure = false;
    }

    await this.sleep(300);

    // --- Test 3: UDP/DNS test with protect (expected: at least one resolver responds) ---
    const udpBefore = this.getTunSnapshot();
    this.poc03Results.push('POC-03 UDP/DNS test WITH protect...');

    try {
      let udpPassed = false;
      let lastUdpJson = '';
      let lastUdpResult = new TestResult();
      for (const target of this.getUdpTargets(false)) {
        const udpResultJson = await pocNative.runUdpTest(target.host, target.port, true);
        const udpResult = TestResult.fromJson(udpResultJson);
        lastUdpJson = udpResultJson;
        lastUdpResult = udpResult;
        this.poc03Results.push(
          'POC-03 UDP+protect label=' + target.label +
          ' host=' + target.host +
          ' port=' + target.port +
          ' ok=' + udpResult.ok +
          ' sendMs=' + udpResult.sendMs +
          ' recvMs=' + udpResult.recvMs +
          ' bytes=' + udpResult.bytesRecv +
          ' error=' + udpResult.error
        );
        if (udpResult.ok) {
          udpPassed = true;
          break;
        }
      }

      await this.sleep(300);
      const udpAfter = this.getTunSnapshot();
      const tunDeltaUdp = udpAfter.loopbackPackets - udpBefore.loopbackPackets;
      const totalTunDeltaUdp = udpAfter.packets - udpBefore.packets;

      if (!udpPassed) {
        failures += 1;
        if (lastUdpResult.error.length > 0) {
          this.poc03Results.push('POC-03 UDP+protect last error: ' + lastUdpResult.error);
        }
        hilog.error(DOMAIN, TAG, 'POC-03 UDP+protect FAILED: %{public}s', lastUdpJson);
      } else {
        hilog.info(DOMAIN, TAG, 'POC-03 UDP+protect PASS loopbackDelta=%{public}d totalTunDelta=%{public}d',
          tunDeltaUdp, totalTunDeltaUdp);
      }
    } catch (err) {
      failures += 1;
      this.poc03Results.push('POC-03 UDP+protect threw: ' + this.toErrorText(err));
    }

    // --- Summary ---
    this.poc03Results.push('POC-03 self-test done failures=' + failures);
    this.poc03Results.push(
      'POC-03 final tun packets=' + this.tunPackets + ' bytes=' + this.tunBytes +
      ' loopbackPackets=' + this.tunLoopbackPackets
    );
    for (const line of this.poc03Results) {
      hilog.info(DOMAIN, TAG, 'POC-03: %{public}s', line);
    }
  }

  // ---------- POC-04: mihomo fixed config minimal run ----------

  private async initPoc04(): Promise<void> {
    this.poc04Results = [];
    this.poc04Started = false;

    const homeDir = this.context.filesDir + '/poc04-mihomo';
    hilog.info(DOMAIN, TAG, 'POC-04 init begin homeDir=%{public}s fd=%{public}d', homeDir, this.tunFd);
    this.poc04Results.push('POC-04 init begin homeDir=' + homeDir);

    try {
      const loadStatus = await pocNative.loadMihomoCore();
      this.poc04Results.push('POC-04 load ok=' + loadStatus.ok + ' code=' + loadStatus.code +
        ' msg=' + loadStatus.message);
      hilog.info(DOMAIN, TAG, 'POC-04 load mihomo core ok=%{public}s code=%{public}d msg=%{public}s',
        loadStatus.ok ? 'true' : 'false', loadStatus.code, loadStatus.message);
      if (!loadStatus.ok) {
        this.poc04Results.push('POC-04 self-test done failures=1');
        return;
      }

      const pingStatus = await pocNative.pingMihomo();
      this.poc04Results.push('POC-04 ping ok=' + pingStatus.ok + ' code=' + pingStatus.code +
        ' msg=' + pingStatus.message);
      hilog.info(DOMAIN, TAG, 'POC-04 ping mihomo ok=%{public}s code=%{public}d msg=%{public}s',
        pingStatus.ok ? 'true' : 'false', pingStatus.code, pingStatus.message);
      if (!pingStatus.ok) {
        this.poc04Results.push('POC-04 self-test done failures=1');
        return;
      }

      const versionStatus = await pocNative.getMihomoVersion();
      this.poc04Results.push('POC-04 version ok=' + versionStatus.ok + ' msg=' + versionStatus.message);
      hilog.info(DOMAIN, TAG, 'POC-04 mihomo version ok=%{public}s code=%{public}d msg=%{public}s',
        versionStatus.ok ? 'true' : 'false', versionStatus.code, versionStatus.message);
      if (!versionStatus.ok) {
        this.poc04Results.push('POC-04 self-test done failures=1');
        return;
      }

      const startStatus = await pocNative.startMihomoConfig(homeDir, POC04_MINIMAL_CONFIG);
      this.poc04Started = startStatus.ok;
      this.mihomoStartedBy = startStatus.ok ? 'POC-04' : '';
      this.poc04Results.push('POC-04 start ok=' + startStatus.ok + ' code=' + startStatus.code +
        ' msg=' + startStatus.message);
      hilog.info(DOMAIN, TAG, 'POC-04 start fixed config ok=%{public}s code=%{public}d msg=%{public}s',
        startStatus.ok ? 'true' : 'false', startStatus.code, startStatus.message);
      if (!startStatus.ok) {
        this.poc04Results.push('POC-04 self-test done failures=1');
        return;
      }

      await this.sleep(1000);

      const stopStatus = await pocNative.stopMihomo();
      this.poc04Started = false;
      this.mihomoStartedBy = '';
      this.poc04Results.push('POC-04 stop ok=' + stopStatus.ok + ' code=' + stopStatus.code +
        ' msg=' + stopStatus.message);
      hilog.info(DOMAIN, TAG, 'POC-04 stop ok=%{public}s code=%{public}d msg=%{public}s',
        stopStatus.ok ? 'true' : 'false', stopStatus.code, stopStatus.message);

      this.poc04Results.push('POC-04 self-test done failures=' + (stopStatus.ok ? 0 : 1));
    } catch (err) {
      this.poc04Results.push('POC-04 threw: ' + this.toErrorText(err));
      this.poc04Results.push('POC-04 self-test done failures=1');
      hilog.error(DOMAIN, TAG, 'POC-04 failed: %{public}s', this.toErrorText(err));
    }

    for (const line of this.poc04Results) {
      hilog.info(DOMAIN, TAG, 'POC-04: %{public}s', line);
    }
  }

  // ---------- POC-05: mihomo sandbox config files ----------

  private async initPoc05(): Promise<void> {
    this.poc05Results = [];
    this.poc04Started = false;
    this.mihomoStartedBy = '';

    const layout = this.createPoc05Layout();
    let failures = 0;
    hilog.info(DOMAIN, TAG, 'POC-05 init begin baseDir=%{public}s fd=%{public}d', layout.baseDir, this.tunFd);
    this.poc05Results.push('POC-05 init begin baseDir=' + layout.baseDir);

    try {
      const hadRawBeforeWrite = this.pathExists(layout.rawPath);
      const hadRuntimeBeforeWrite = this.pathExists(layout.runtimePath);
      this.poc05Results.push('POC-05 persisted files before write raw=' + hadRawBeforeWrite +
        ' runtime=' + hadRuntimeBeforeWrite);
      hilog.info(DOMAIN, TAG, 'POC-05 persisted files before write raw=%{public}s runtime=%{public}s',
        hadRawBeforeWrite ? 'true' : 'false', hadRuntimeBeforeWrite ? 'true' : 'false');

      this.ensureDirSync(layout.homeDir);
      this.ensureDirSync(layout.profileDir);
      this.ensureDirSync(layout.runDir);
      this.ensureDirSync(layout.cacheDir);
      this.ensureDirSync(layout.geoDir);
      this.poc05Results.push('POC-05 directories ready home=' + layout.homeDir + ' profiles=' +
        layout.profileDir + ' run=' + layout.runDir + ' cache=' + layout.cacheDir + ' geo=' + layout.geoDir);
      hilog.info(DOMAIN, TAG,
        'POC-05 directories ready home=%{public}s profiles=%{public}s run=%{public}s cache=%{public}s geo=%{public}s',
        layout.homeDir, layout.profileDir, layout.runDir, layout.cacheDir, layout.geoDir);

      const rawBytes = this.writeTextFile(layout.rawPath, POC05_RAW_SUBSCRIPTION);
      this.poc05Results.push('POC-05 raw subscription saved path=' + layout.rawPath + ' bytes=' + rawBytes);
      hilog.info(DOMAIN, TAG, 'POC-05 raw subscription saved path=%{public}s bytes=%{public}d',
        layout.rawPath, rawBytes);

      const unsupported = this.getUnsupportedConfigKeys(POC05_UNSUPPORTED_SUBSCRIPTION);
      const rejectedUnsupported = unsupported.indexOf('script') >= 0 && unsupported.indexOf('proxy-providers') >= 0;
      this.poc05Results.push('POC-05 unsupported config rejected keys=' + unsupported.join(',') +
        ' ok=' + rejectedUnsupported);
      hilog.info(DOMAIN, TAG, 'POC-05 unsupported config rejected keys=%{public}s ok=%{public}s',
        unsupported.join(','), rejectedUnsupported ? 'true' : 'false');
      if (!rejectedUnsupported) {
        failures += 1;
      }

      const rawUnsupported = this.getUnsupportedConfigKeys(POC05_RAW_SUBSCRIPTION);
      this.poc05Results.push('POC-05 raw subscription unsupported keys=' + rawUnsupported.join(','));
      if (rawUnsupported.length > 0) {
        failures += 1;
      }

      const runtimeBytes = this.writeTextFile(layout.runtimePath, POC05_RUNTIME_CONFIG);
      this.poc05Results.push('POC-05 runtime config saved path=' + layout.runtimePath + ' bytes=' + runtimeBytes);
      hilog.info(DOMAIN, TAG, 'POC-05 runtime config saved path=%{public}s bytes=%{public}d',
        layout.runtimePath, runtimeBytes);

      const readback = fs.readTextSync(layout.runtimePath);
      const readbackOk = readback === POC05_RUNTIME_CONFIG;
      this.poc05Results.push('POC-05 runtime config readback ok=' + readbackOk);
      hilog.info(DOMAIN, TAG, 'POC-05 runtime config readback ok=%{public}s',
        readbackOk ? 'true' : 'false');
      if (!readbackOk) {
        failures += 1;
      }

      const pathsInSandbox = this.isSubPath(layout.homeDir, layout.baseDir) &&
        this.isSubPath(layout.profileDir, layout.baseDir) &&
        this.isSubPath(layout.runDir, layout.baseDir) &&
        this.isSubPath(layout.cacheDir, layout.baseDir) &&
        this.isSubPath(layout.geoDir, layout.baseDir) &&
        this.isSubPath(layout.rawPath, layout.baseDir) &&
        this.isSubPath(layout.runtimePath, layout.baseDir);
      this.poc05Results.push('POC-05 sandbox path check ok=' + pathsInSandbox);
      hilog.info(DOMAIN, TAG, 'POC-05 sandbox path check ok=%{public}s',
        pathsInSandbox ? 'true' : 'false');
      if (!pathsInSandbox) {
        failures += 1;
      }

      const loadStatus = await pocNative.loadMihomoCore();
      this.poc05Results.push('POC-05 load ok=' + loadStatus.ok + ' code=' + loadStatus.code +
        ' msg=' + loadStatus.message);
      hilog.info(DOMAIN, TAG, 'POC-05 load mihomo core ok=%{public}s code=%{public}d msg=%{public}s',
        loadStatus.ok ? 'true' : 'false', loadStatus.code, loadStatus.message);
      if (!loadStatus.ok) {
        failures += 1;
        this.poc05Results.push('POC-05 self-test done failures=' + failures);
        this.logPoc05Results();
        return;
      }

      const startStatus = await pocNative.startMihomoConfigFile(layout.homeDir, layout.runtimePath);
      this.poc04Started = startStatus.ok;
      this.mihomoStartedBy = startStatus.ok ? 'POC-05' : '';
      this.poc05Results.push('POC-05 start generated config ok=' + startStatus.ok + ' code=' +
        startStatus.code + ' msg=' + startStatus.message);
      hilog.info(DOMAIN, TAG, 'POC-05 start generated config ok=%{public}s code=%{public}d msg=%{public}s',
        startStatus.ok ? 'true' : 'false', startStatus.code, startStatus.message);
      if (!startStatus.ok) {
        failures += 1;
        this.poc05Results.push('POC-05 self-test done failures=' + failures);
        this.logPoc05Results();
        return;
      }

      await this.sleep(1000);

      const switchBytes = this.writeTextFile(layout.runtimePath, POC05_RUNTIME_SWITCH_CONFIG);
      const switchReadback = fs.readTextSync(layout.runtimePath);
      const switchReadbackOk = switchReadback === POC05_RUNTIME_SWITCH_CONFIG;
      this.poc05Results.push('POC-05 switch config saved bytes=' + switchBytes +
        ' readbackOk=' + switchReadbackOk);
      hilog.info(DOMAIN, TAG, 'POC-05 switch config saved bytes=%{public}d readbackOk=%{public}s',
        switchBytes, switchReadbackOk ? 'true' : 'false');
      if (!switchReadbackOk) {
        failures += 1;
      }

      const switchStatus = await pocNative.startMihomoConfigFile(layout.homeDir, layout.runtimePath);
      this.poc04Started = this.poc04Started || switchStatus.ok;
      this.mihomoStartedBy = this.poc04Started ? 'POC-05' : '';
      this.poc05Results.push('POC-05 reload switched config ok=' + switchStatus.ok + ' code=' +
        switchStatus.code + ' msg=' + switchStatus.message);
      hilog.info(DOMAIN, TAG, 'POC-05 reload switched config ok=%{public}s code=%{public}d msg=%{public}s',
        switchStatus.ok ? 'true' : 'false', switchStatus.code, switchStatus.message);
      if (!switchStatus.ok) {
        failures += 1;
      }

      await this.sleep(1000);

      const stopStatus = await pocNative.stopMihomo();
      this.poc04Started = false;
      this.mihomoStartedBy = '';
      this.poc05Results.push('POC-05 stop ok=' + stopStatus.ok + ' code=' + stopStatus.code +
        ' msg=' + stopStatus.message);
      hilog.info(DOMAIN, TAG, 'POC-05 stop ok=%{public}s code=%{public}d msg=%{public}s',
        stopStatus.ok ? 'true' : 'false', stopStatus.code, stopStatus.message);
      if (!stopStatus.ok) {
        failures += 1;
      }

      this.poc05Results.push('POC-05 self-test done failures=' + failures);
    } catch (err) {
      this.poc05Results.push('POC-05 threw: ' + this.toErrorText(err));
      this.poc05Results.push('POC-05 self-test done failures=1');
      hilog.error(DOMAIN, TAG, 'POC-05 failed: %{public}s', this.toErrorText(err));
    }

    this.logPoc05Results();
  }

  private logPoc05Results(): void {
    for (const line of this.poc05Results) {
      hilog.info(DOMAIN, TAG, 'POC-05: %{public}s', line);
    }
  }

  // ---------- POC-06: lifecycle and recovery ----------

  private async initPoc06(): Promise<void> {
    let failures = 0;
    const layout = this.createPoc05Layout();
    hilog.info(DOMAIN, TAG, 'POC-06 init begin fd=%{public}d state=%{public}s', this.tunFd, this.poc06State);
    this.poc06Results.push('POC-06 init begin fd=' + this.tunFd + ' state=' + this.poc06State);

    try {
      this.ensureDirSync(layout.homeDir);
      this.ensureDirSync(layout.runDir);

      const loadStatus = await pocNative.loadMihomoCore();
      this.poc06Results.push('POC-06 load ok=' + loadStatus.ok + ' code=' + loadStatus.code +
        ' msg=' + loadStatus.message);
      hilog.info(DOMAIN, TAG, 'POC-06 load mihomo core ok=%{public}s code=%{public}d msg=%{public}s',
        loadStatus.ok ? 'true' : 'false', loadStatus.code, loadStatus.message);
      if (!loadStatus.ok) {
        failures += 1;
        this.poc06Results.push('POC-06 self-test done failures=' + failures);
        this.logPoc06Results();
        return;
      }

      const badConfigPath = layout.runDir + '/poc06-invalid.yaml';
      const badBytes = this.writeTextFile(badConfigPath, POC06_INVALID_CONFIG);
      this.poc06Results.push('POC-06 invalid config saved path=' + badConfigPath + ' bytes=' + badBytes);
      const badStatus = await pocNative.startMihomoConfigFile(layout.homeDir, badConfigPath);
      const badFailedAsExpected = !badStatus.ok;
      this.poc06Results.push('POC-06 invalid config rejected ok=' + badFailedAsExpected +
        ' code=' + badStatus.code + ' msg=' + badStatus.message);
      hilog.info(DOMAIN, TAG,
        'POC-06 invalid config rejected ok=%{public}s code=%{public}d msg=%{public}s',
        badFailedAsExpected ? 'true' : 'false', badStatus.code, badStatus.message);
      if (!badFailedAsExpected) {
        failures += 1;
        this.poc04Started = true;
        this.mihomoStartedBy = 'POC-06';
        const cleanupStatus = await pocNative.stopMihomo();
        this.poc04Started = false;
        this.mihomoStartedBy = '';
        this.poc06Results.push('POC-06 invalid config cleanup stop ok=' + cleanupStatus.ok +
          ' code=' + cleanupStatus.code + ' msg=' + cleanupStatus.message);
      }
      this.setPoc06State('idle', 'invalid config failure handled');

      const runtimeBytes = this.writeTextFile(layout.runtimePath, POC05_RUNTIME_CONFIG);
      this.poc06Results.push('POC-06 recovery runtime config saved bytes=' + runtimeBytes);
      this.setPoc06State('starting', 'recovery start after invalid config');
      const startStatus = await pocNative.startMihomoConfigFile(layout.homeDir, layout.runtimePath);
      this.poc04Started = startStatus.ok;
      this.mihomoStartedBy = startStatus.ok ? 'POC-06' : '';
      this.poc06Results.push('POC-06 recovery start ok=' + startStatus.ok + ' code=' +
        startStatus.code + ' msg=' + startStatus.message);
      hilog.info(DOMAIN, TAG, 'POC-06 recovery start ok=%{public}s code=%{public}d msg=%{public}s',
        startStatus.ok ? 'true' : 'false', startStatus.code, startStatus.message);
      if (!startStatus.ok) {
        failures += 1;
        this.setPoc06State('error', 'recovery start failed');
        this.poc06Results.push('POC-06 self-test done failures=' + failures);
        this.logPoc06Results();
        return;
      }
      this.setPoc06State('connected', 'recovery start ok');

      const busyBefore = this.poc06Results.length;
      await this.startVpnForPoc(this.createPoc06Want('busyProbe'), 'POC-06-busyProbe');
      const busyRejected = this.poc06Results.length > busyBefore &&
        this.poc06Results[this.poc06Results.length - 1].indexOf('busy start rejected') >= 0;
      this.poc06Results.push('POC-06 duplicate start rejected ok=' + busyRejected);
      hilog.info(DOMAIN, TAG, 'POC-06 duplicate start rejected ok=%{public}s',
        busyRejected ? 'true' : 'false');
      if (!busyRejected) {
        failures += 1;
      }

      this.setPoc06State('stopping', 'first stop');
      const stopStatus = await pocNative.stopMihomo();
      this.poc04Started = false;
      this.mihomoStartedBy = '';
      this.poc06Results.push('POC-06 first stop ok=' + stopStatus.ok + ' code=' +
        stopStatus.code + ' msg=' + stopStatus.message);
      hilog.info(DOMAIN, TAG, 'POC-06 first stop ok=%{public}s code=%{public}d msg=%{public}s',
        stopStatus.ok ? 'true' : 'false', stopStatus.code, stopStatus.message);
      if (!stopStatus.ok) {
        failures += 1;
      }
      this.setPoc06State(stopStatus.ok ? 'idle' : 'error', 'first stop complete');

      const secondStopStatus = await pocNative.stopMihomo();
      const secondStopOk = secondStopStatus.ok;
      this.poc06Results.push('POC-06 second stop idempotent ok=' + secondStopOk + ' code=' +
        secondStopStatus.code + ' msg=' + secondStopStatus.message);
      hilog.info(DOMAIN, TAG,
        'POC-06 second stop idempotent ok=%{public}s code=%{public}d msg=%{public}s',
        secondStopOk ? 'true' : 'false', secondStopStatus.code, secondStopStatus.message);
      if (!secondStopOk) {
        failures += 1;
      }

      await this.destroyVpn();
      const destroyOk = this.tunFd < 0 && this.vpnConnection === null;
      this.poc06Results.push('POC-06 destroy recovery ok=' + destroyOk + ' fd=' + this.tunFd);
      hilog.info(DOMAIN, TAG, 'POC-06 destroy recovery ok=%{public}s fd=%{public}d',
        destroyOk ? 'true' : 'false', this.tunFd);
      if (!destroyOk) {
        failures += 1;
        this.setPoc06State('error', 'destroy recovery failed');
      } else {
        this.setPoc06State('idle', 'destroy recovery complete');
      }

      this.poc06Results.push('POC-06 final state=' + this.poc06State);
      this.poc06Results.push('POC-06 self-test done failures=' + failures);
    } catch (err) {
      failures += 1;
      this.setPoc06State('error', 'threw ' + this.toErrorText(err));
      this.poc06Results.push('POC-06 threw: ' + this.toErrorText(err));
      this.poc06Results.push('POC-06 self-test done failures=' + failures);
      hilog.error(DOMAIN, TAG, 'POC-06 failed: %{public}s', this.toErrorText(err));
      await this.destroyVpn();
    }

    this.logPoc06Results();
  }

  private logPoc06Results(): void {
    for (const line of this.poc06Results) {
      hilog.info(DOMAIN, TAG, 'POC-06: %{public}s', line);
    }
  }

  // ---------- VPN destroy ----------

  private async destroyVpn(): Promise<void> {
    if (this.destroyInProgress) {
      hilog.warn(DOMAIN, TAG, 'POC-06 destroy already in progress state=%{public}s fd=%{public}d',
        this.poc06State, this.tunFd);
      this.poc06Results.push('POC-06 duplicate destroy ignored state=' + this.poc06State);
      return;
    }

    this.destroyInProgress = true;
    this.setPoc06State('stopping', 'destroyVpn begin fd=' + this.tunFd);
    if (this.poc04Started) {
      hilog.warn(DOMAIN, TAG,
        '%{public}s stop skipped on destroy: MihomoOhosStop c-shared bridge is unstable in fd-backed TUN smoke',
        this.mihomoStartedBy.length > 0 ? this.mihomoStartedBy : 'mihomo');
      this.poc04Started = false;
      this.mihomoStartedBy = '';
    }

    this.stopTrafficPolling(true);

    // POC-03: Stop TUN reader first
    this.stopTunReader();

    // Log POC-03 results
    if (this.poc03Results.length > 0) {
      hilog.info(DOMAIN, TAG, 'POC-03 results on destroy: %{public}s',
        JSON.stringify(this.poc03Results));
    }
    if (this.poc04Results.length > 0) {
      hilog.info(DOMAIN, TAG, 'POC-04 results on destroy: %{public}s',
        JSON.stringify(this.poc04Results));
    }
    if (this.poc05Results.length > 0) {
      hilog.info(DOMAIN, TAG, 'POC-05 results on destroy: %{public}s',
        JSON.stringify(this.poc05Results));
    }

    const fd = this.tunFd;
    try {
      if (this.vpnConnection) {
        await this.vpnConnection.destroy();
        hilog.info(DOMAIN, TAG, 'vpn destroyed fd=%{public}d', fd);
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'vpn destroy failed fd=%{public}d err=%{public}s',
        fd, this.toErrorText(err));
      this.setPoc06State('error', 'vpn destroy failed fd=' + fd);
    } finally {
      this.vpnConnection = null;
      this.tunFd = -1;
      this.protectRegistered = false;
      this.destroyInProgress = false;
      if (this.poc06State !== 'error') {
        this.setPoc06State('idle', 'destroyVpn complete fd=' + fd);
      }
    }
  }

  // ---------- Helpers ----------

  private async sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(resolve, ms);
    });
  }

  private setPoc06State(next: Poc06State, reason: string): void {
    const previous = this.poc06State;
    this.poc06State = next;
    const line = 'POC-06 state ' + previous + ' -> ' + next + ' reason=' + reason;
    this.poc06Results.push(line);
    hilog.info(DOMAIN, TAG, '%{public}s', line);
  }

  private createPoc06Want(reason: string): Want {
    return {
      parameters: {
        poc: 'POC-06',
        requestedAt: new Date().toISOString(),
        requestedBy: reason
      }
    };
  }

  private toErrorText(err: Object): string {
    if (err instanceof Error) {
      return err.name + ': ' + err.message;
    }
    return JSON.stringify(err);
  }

  private parseLatencyGroupNames(raw: string): string[] {
    const names: string[] = [];
    for (const item of raw.split('\n')) {
      const name = item.trim();
      if (name.length > 0 && names.indexOf(name) < 0) {
        names.push(name);
      }
    }
    return names;
  }

  private parseNativeDelayResult(json: string): NativeDelayResult {
    try {
      const parsed = JSON.parse(json) as NativeDelayResult;
      return {
        ok: typeof parsed.ok === 'boolean' ? parsed.ok : false,
        groupName: parsed.groupName ? parsed.groupName : '',
        nodeName: parsed.nodeName ? parsed.nodeName : '',
        url: parsed.url ? parsed.url : '',
        timeoutMs: typeof parsed.timeoutMs === 'number' ? parsed.timeoutMs : 0,
        delays: parsed.delays ? parsed.delays : [],
        error: parsed.error ? parsed.error : ''
      };
    } catch (err) {
      return {
        ok: false,
        groupName: '',
        nodeName: '',
        url: '',
        timeoutMs: 0,
        delays: [],
        error: this.toErrorText(err)
      };
    }
  }

  private isTryAgainError(errorText: string): boolean {
    return errorText.indexOf('Try again') >= 0 || errorText.indexOf('EAGAIN') >= 0 ||
      errorText.indexOf('EWOULDBLOCK') >= 0;
  }

  private describeIpv4Packet(buffer: ArrayBuffer, bytesRead: number): string {
    if (bytesRead < 20) {
      return 'short bytes=' + bytesRead;
    }

    const view = new DataView(buffer);
    const version = view.getUint8(0) >> 4;
    if (version !== 4) {
      return 'ipVersion=' + version + ' bytes=' + bytesRead;
    }

    const ihl = (view.getUint8(0) & 0x0f) * 4;
    if (bytesRead < ihl || ihl < 20) {
      return 'badIhl=' + ihl + ' bytes=' + bytesRead;
    }

    const proto = view.getUint8(9);
    const src = this.ipv4ToString(view.getUint8(12), view.getUint8(13), view.getUint8(14), view.getUint8(15));
    const dst = this.ipv4ToString(view.getUint8(16), view.getUint8(17), view.getUint8(18), view.getUint8(19));
    const len = view.getUint16(2);
    if ((proto === 6 || proto === 17) && bytesRead >= ihl + 4) {
      const srcPort = view.getUint16(ihl);
      const dstPort = view.getUint16(ihl + 2);
      if (this.isPocLoopbackCandidate(proto, dst, dstPort)) {
        this.tunLoopbackPackets += 1;
      }
      return 'proto=' + (proto === 6 ? 'tcp' : 'udp') + ' ' + src + ':' + srcPort + ' -> ' +
        dst + ':' + dstPort + ' len=' + len + ' bytes=' + bytesRead;
    }
    if (proto === 1 && bytesRead >= ihl + 2) {
      return 'proto=icmp type=' + view.getUint8(ihl) + ' code=' + view.getUint8(ihl + 1) +
        ' ' + src + ' -> ' + dst + ' len=' + len + ' bytes=' + bytesRead;
    }
    return 'proto=' + proto + ' ' + src + ' -> ' + dst + ' len=' + len + ' bytes=' + bytesRead;
  }

  private ipv4ToString(a: number, b: number, c: number, d: number): string {
    return a + '.' + b + '.' + c + '.' + d;
  }

  private isPocLoopbackCandidate(proto: number, dst: string, dstPort: number): boolean {
    if (proto === 6 && dst === '1.1.1.1' && dstPort === 80) {
      return true;
    }
    if (proto === 17 && dst === this.poc03Options.udpEchoHost && dstPort === this.poc03Options.udpEchoPort) {
      return true;
    }
    if (proto === 17 && dstPort === 53 && (dst === '1.1.1.1' || dst === '8.8.8.8')) {
      return true;
    }
    return false;
  }

  private getUdpTargets(includePublicDns: boolean): UdpTarget[] {
    const targets: UdpTarget[] = [];
    if (this.poc03Options.udpEchoHost.length > 0 && this.poc03Options.udpEchoPort > 0) {
      targets.push({
        host: this.poc03Options.udpEchoHost,
        port: this.poc03Options.udpEchoPort,
        label: 'local-echo'
      });
    }
    if (includePublicDns) {
      targets.push({ host: '1.1.1.1', port: 53, label: 'cloudflare-dns' });
      targets.push({ host: '8.8.8.8', port: 53, label: 'google-dns' });
    }
    return targets;
  }

  private createPoc05Layout(): Poc05Layout {
    const baseDir = this.context.filesDir + '/poc05-mihomo';
    return {
      baseDir,
      homeDir: baseDir + '/home',
      profileDir: baseDir + '/profiles',
      runDir: baseDir + '/run',
      cacheDir: baseDir + '/cache',
      geoDir: baseDir + '/geo',
      rawPath: baseDir + '/profiles/subscription-raw.yaml',
      runtimePath: baseDir + '/run/config.yaml'
    };
  }

  private ensureDirSync(path: string): void {
    if (this.pathExists(path)) {
      return;
    }
    fs.mkdirSync(path, true);
  }

  private writeTextFile(path: string, content: string): number {
    const file = fs.openSync(path, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      return fs.writeSync(file.fd, content);
    } finally {
      fs.closeSync(file);
    }
  }

  private pathExists(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (_) {
      return false;
    }
  }

  private getUnsupportedConfigKeys(yaml: string): string[] {
    const unsupported: string[] = [];
    const lines = yaml.split('\n');
    for (const rawLine of lines) {
      const line = rawLine.trim();
      if (line === 'script:' && unsupported.indexOf('script') < 0) {
        unsupported.push('script');
      }
      if (line === 'proxy-providers:' && unsupported.indexOf('proxy-providers') < 0) {
        unsupported.push('proxy-providers');
      }
      if (line === 'rule-providers:' && unsupported.indexOf('rule-providers') < 0) {
        unsupported.push('rule-providers');
      }
      if (line === 'external-ui:' && unsupported.indexOf('external-ui') < 0) {
        unsupported.push('external-ui');
      }
    }
    return unsupported;
  }

  private isSubPath(path: string, root: string): boolean {
    return path === root || path.startsWith(root + '/');
  }

  private parsePoc03Options(want: Want): Poc03Options {
    const params = want.parameters as Record<string, Object> | undefined;
    return {
      udpEchoHost: this.getStringParam(params, 'udpEchoHost', DEFAULT_UDP_ECHO_HOST),
      udpEchoPort: this.getNumberParam(params, 'udpEchoPort', DEFAULT_UDP_ECHO_PORT),
      rawUdpPreflight: this.getBooleanParam(params, 'poc03RawUdpPreflight',
        this.getBooleanParam(params, 'rawUdpPreflight', DEFAULT_RAW_UDP_PREFLIGHT)),
      tunPacketDump: this.getBooleanParam(params, 'poc03TunPacketDump',
        this.getBooleanParam(params, 'tunPacketDump', DEFAULT_TUN_PACKET_DUMP))
    };
  }

  private parseProductVpnOptions(params: Record<string, Object> | undefined): ProductVpnOptions {
    const routeMode = this.getStringParam(params, 'vpnRouteMode', 'split-default');
    const routeInterfaceParam = this.getStringParam(params, 'vpnRouteInterface', 'vpn-tun');
    // Accept any route mode; createPocConfig handles the switch
    const validModes = ['default', 'split-default', 'blocking-empty', 'blocking-split',
      'blocking-default', 'no-routes', 'exclude-local'];
    const resolvedMode = validModes.indexOf(routeMode) >= 0 ? routeMode : 'split-default';
    return {
      routeMode: resolvedMode,
      dnsAddress: this.getStringParam(params, 'vpnDnsAddress', '10.7.0.3'),
      tunReadinessProbeMs: this.getNumberParam(params, 'tunReadinessProbeMs', 0),
      routeInterface: routeInterfaceParam === 'none' ? '' : routeInterfaceParam,
      routeDefaultFlag: this.getBooleanParam(params, 'vpnRouteDefaultFlag', true),
      ipv6Enabled: this.getBooleanParam(params, 'ipv6Enabled', false),
      udpEnabled: this.getBooleanParam(params, 'udpEnabled', true)
    };
  }

  private getStringParam(params: Record<string, Object> | undefined, name: string, fallback: string): string {
    if (!params) {
      return fallback;
    }
    const value = params[name];
    if (value === undefined) {
      return fallback;
    }
    if (typeof value === 'string' && value.length > 0) {
      return value;
    }
    return fallback;
  }

  private getNumberParam(params: Record<string, Object> | undefined, name: string, fallback: number): number {
    if (!params) {
      return fallback;
    }
    const value = params[name];
    if (value === undefined) {
      return fallback;
    }
    if (typeof value === 'number' && Number.isFinite(value) && value > 0) {
      return Math.floor(value);
    }
    if (typeof value === 'string') {
      const parsed = Number.parseInt(value, 10);
      if (Number.isFinite(parsed) && parsed > 0) {
        return parsed;
      }
    }
    return fallback;
  }

  private getBooleanParam(params: Record<string, Object> | undefined, name: string, fallback: boolean): boolean {
    if (!params) {
      return fallback;
    }
    const value = params[name];
    if (value === undefined) {
      return fallback;
    }
    if (typeof value === 'boolean') {
      return value;
    }
    if (typeof value === 'string') {
      const lowered = value.toLowerCase();
      if (lowered === 'true' || lowered === '1' || lowered === 'yes') {
        return true;
      }
      if (lowered === 'false' || lowered === '0' || lowered === 'no') {
        return false;
      }
    }
    if (typeof value === 'number') {
      return value !== 0;
    }
    return fallback;
  }
}
