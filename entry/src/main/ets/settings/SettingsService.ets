import fs from '@ohos.file.fs';
import { ConfigService } from '../config/ConfigService';
import {
  AppSettings,
  DEFAULT_APP_SETTINGS,
  DnsMode,
  LogLevel,
  ProxyMode,
  VpnRouteMode
} from '../models/MvpTypes';

export class SettingsService {
  private configService: ConfigService;

  constructor(filesDir: string) {
    this.configService = new ConfigService(filesDir);
  }

  load(): AppSettings {
    const layout = this.configService.ensureLayout();
    if (!this.configService.pathExists(layout.settingsPath)) {
      const initial = this.cloneDefault();
      this.save(initial);
      return initial;
    }

    try {
      const parsed = JSON.parse(fs.readTextSync(layout.settingsPath)) as Partial<AppSettings>;
      return this.normalize(parsed);
    } catch (_) {
      const fallback = this.cloneDefault();
      this.save(fallback);
      return fallback;
    }
  }

  save(settings: AppSettings): void {
    const layout = this.configService.ensureLayout();
    this.configService.writeTextFileAtomic(layout.settingsPath, JSON.stringify(this.normalize(settings)));
  }

  update(patch: Partial<AppSettings>): AppSettings {
    const current = this.load();
    const next: AppSettings = {
      routeMode: patch.routeMode ?? current.routeMode,
      proxyMode: patch.proxyMode ?? current.proxyMode,
      dnsMode: patch.dnsMode ?? current.dnsMode,
      vpnDnsAddress: patch.vpnDnsAddress ?? current.vpnDnsAddress,
      ipv6Enabled: patch.ipv6Enabled ?? current.ipv6Enabled,
      udpEnabled: patch.udpEnabled ?? current.udpEnabled,
      autoRefreshSubscriptionOnConnect: patch.autoRefreshSubscriptionOnConnect ??
        current.autoRefreshSubscriptionOnConnect,
      autoStart: patch.autoStart ?? current.autoStart,
      logLevel: patch.logLevel ?? current.logLevel
    };
    this.save(next);
    return next;
  }

  private normalize(input: Partial<AppSettings>): AppSettings {
    return {
      routeMode: this.safeRouteMode(input.routeMode),
      proxyMode: this.safeProxyMode(input.proxyMode),
      dnsMode: this.safeDnsMode(input.dnsMode),
      vpnDnsAddress: this.safeString(input.vpnDnsAddress, DEFAULT_APP_SETTINGS.vpnDnsAddress),
      ipv6Enabled: this.safeBoolean(input.ipv6Enabled, DEFAULT_APP_SETTINGS.ipv6Enabled),
      udpEnabled: this.safeBoolean(input.udpEnabled, DEFAULT_APP_SETTINGS.udpEnabled),
      autoRefreshSubscriptionOnConnect: this.safeBoolean(input.autoRefreshSubscriptionOnConnect,
        DEFAULT_APP_SETTINGS.autoRefreshSubscriptionOnConnect),
      autoStart: this.safeBoolean(input.autoStart, DEFAULT_APP_SETTINGS.autoStart),
      logLevel: this.safeLogLevel(input.logLevel)
    };
  }

  private cloneDefault(): AppSettings {
    return {
      routeMode: DEFAULT_APP_SETTINGS.routeMode,
      proxyMode: DEFAULT_APP_SETTINGS.proxyMode,
      dnsMode: DEFAULT_APP_SETTINGS.dnsMode,
      vpnDnsAddress: DEFAULT_APP_SETTINGS.vpnDnsAddress,
      ipv6Enabled: DEFAULT_APP_SETTINGS.ipv6Enabled,
      udpEnabled: DEFAULT_APP_SETTINGS.udpEnabled,
      autoRefreshSubscriptionOnConnect: DEFAULT_APP_SETTINGS.autoRefreshSubscriptionOnConnect,
      autoStart: DEFAULT_APP_SETTINGS.autoStart,
      logLevel: DEFAULT_APP_SETTINGS.logLevel
    };
  }

  private safeRouteMode(value: VpnRouteMode | undefined): VpnRouteMode {
    const modes: string[] = ['default', 'split-default', 'blocking-empty', 'blocking-split',
      'blocking-default', 'no-routes', 'exclude-local'];
    if (value && modes.indexOf(value) >= 0) {
      return value;
    }
    return DEFAULT_APP_SETTINGS.routeMode;
  }

  private safeProxyMode(value: ProxyMode | undefined): ProxyMode {
    if (value === 'rule' || value === 'global' || value === 'direct') {
      return value;
    }
    return DEFAULT_APP_SETTINGS.proxyMode;
  }

  private safeDnsMode(value: DnsMode | undefined): DnsMode {
    if (value === 'default' || value === 'fake-ip' || value === 'redir-host') {
      return value;
    }
    return DEFAULT_APP_SETTINGS.dnsMode;
  }

  private safeLogLevel(value: LogLevel | undefined): LogLevel {
    if (value === 'debug' || value === 'info' || value === 'warning' || value === 'error') {
      return value;
    }
    return DEFAULT_APP_SETTINGS.logLevel;
  }

  private safeString(value: string | undefined, fallback: string): string {
    if (!value || value.trim().length === 0) {
      return fallback;
    }
    return value.trim();
  }

  private safeBoolean(value: boolean | undefined, fallback: boolean): boolean {
    return typeof value === 'boolean' ? value : fallback;
  }
}
