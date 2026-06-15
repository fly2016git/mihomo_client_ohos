export type ProfileType = 'local' | 'subscription';
export type RuntimeState = 'idle' | 'starting' | 'connected' | 'stopping' | 'error' | 'unknown';
export type CoreState = 'stopped' | 'loading' | 'running' | 'stopping' | 'error' | 'unknown';
export type VpnRouteMode = 'default' | 'split-default' | 'blocking-empty' | 'blocking-split' | 'blocking-default' |
  'no-routes' | 'exclude-local';
export type ProxyMode = 'rule' | 'global' | 'direct';
export type DnsMode = 'default' | 'fake-ip' | 'redir-host';
export type LogLevel = 'debug' | 'info' | 'warning' | 'error';
export type RuntimeEventLevel = 'debug' | 'info' | 'warn' | 'error';
export type RuntimeEventSource = 'ui' | 'vpn' | 'core' | 'subscription' | 'config' | 'diagnostic';
export type TrafficStatsSource = 'none' | 'tun-interface' | 'native-mihomo';

export interface MihomoLayout {
  baseDir: string;
  homeDir: string;
  profileDir: string;
  runDir: string;
  cacheDir: string;
  geoDir: string;
  logsDir: string;
  stateDir: string;
  profilesPath: string;
  runtimePath: string;
  settingsPath: string;
  proxySelectionPath: string;
  proxyLatencyPath: string;
  trafficDailyPath: string;
  trafficStatsPath: string;
}

export interface Profile {
  id: string;
  name: string;
  type: ProfileType;
  active: boolean;
  sourceUrl: string;
  subscription?: SubscriptionMeta;
  rawPath: string;
  runtimePath: string;
  homeDir: string;
  createdAt: number;
  updatedAt: number;
  lastValidatedAt: number;
  lastError: string;
}

export interface ProxyNode {
  name: string;
  type: string;
  server: string;
  port: string;
  group: string;
  selected: boolean;
  delay: number;
}

export interface ProxyGroup {
  name: string;
  type: string;
  selected: string;
  nodes: ProxyNode[];
}

export interface ProxySelection {
  profileId: string;
  groupName: string;
  nodeName: string;
  updatedAt: number;
}

export interface ProxySelectionState {
  selections: ProxySelection[];
}

export type ProxyLatencyStatus = 'idle' | 'running' | 'complete' | 'error';

export interface ProxyLatencyRecord {
  profileId: string;
  groupName: string;
  nodeName: string;
  delay: number;
  updatedAt: number;
}

export interface ProxyLatencyState {
  requestId: string;
  status: ProxyLatencyStatus;
  updatedAt: number;
  error: string;
  records: ProxyLatencyRecord[];
}

export interface ConfigValidationResult {
  ok: boolean;
  unsupportedKeys: string[];
  errors: string[];
  warnings: string[];
}

export interface RuntimeSnapshot {
  runtimeState: RuntimeState;
  coreState: CoreState;
  activeProfileId: string;
  activeProfileName: string;
  tunFd: number;
  startedAt: number;
  updatedAt: number;
  lastError: string;
  lastEvent: string;
  uploadSpeed: number;
  downloadSpeed: number;
  todayUploadBytes: number;
  todayDownloadBytes: number;
  trafficSource: TrafficStatsSource;
}

export interface RuntimeEvent {
  timestamp: number;
  level: RuntimeEventLevel;
  source: RuntimeEventSource;
  message: string;
}

export interface ProfilesState {
  activeProfileId: string;
  profiles: Profile[];
}

export const DEFAULT_PROFILE_ID = 'default';

export interface AppSettings {
  routeMode: VpnRouteMode;
  proxyMode: ProxyMode;
  dnsMode: DnsMode;
  vpnDnsAddress: string;
  ipv6Enabled: boolean;
  udpEnabled: boolean;
  autoRefreshSubscriptionOnConnect: boolean;
  autoStart: boolean;
  logLevel: LogLevel;
}

export const DEFAULT_APP_SETTINGS: AppSettings = {
  routeMode: 'blocking-default',
  proxyMode: 'rule',
  dnsMode: 'default',
  vpnDnsAddress: '10.7.0.3',
  ipv6Enabled: false,
  udpEnabled: true,
  autoRefreshSubscriptionOnConnect: false,
  autoStart: false,
  logLevel: 'info'
};

export interface SubscriptionMeta {
  url: string;
  userAgent: string;
  lastFetchedAt: number;
  lastSuccessAt: number;
  failureCount: number;
  lastStatusCode: number;
  lastError: string;
  lastBytes: number;
}

export interface SubscriptionUpdateResult {
  ok: boolean;
  profileId: string;
  statusCode: number;
  bytes: number;
  fromCache: boolean;
  rawPath: string;
  runtimePath: string;
  error: string;
  updatedAt: number;
}

export function makeSubscriptionMeta(url: string): SubscriptionMeta {
  return {
    url: url,
    userAgent: 'ClashX Pro/1.118.0',
    lastFetchedAt: 0,
    lastSuccessAt: 0,
    failureCount: 0,
    lastStatusCode: 0,
    lastError: '',
    lastBytes: 0
  };
}
