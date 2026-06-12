export type ProfileType = 'local' | 'subscription';
export type RuntimeState = 'idle' | 'starting' | 'connected' | 'stopping' | 'error' | 'unknown';
export type CoreState = 'stopped' | 'loading' | 'running' | 'stopping' | 'error' | 'unknown';

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
}

export interface ProfilesState {
  activeProfileId: string;
  profiles: Profile[];
}

export const DEFAULT_PROFILE_ID = 'default';

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
