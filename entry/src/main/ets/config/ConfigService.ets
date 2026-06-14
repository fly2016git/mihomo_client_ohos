import fs from '@ohos.file.fs';
import {
  AppSettings,
  ConfigValidationResult,
  DEFAULT_APP_SETTINGS,
  DEFAULT_PROFILE_ID,
  DnsMode,
  LogLevel,
  MihomoLayout,
  Profile,
  ProxyGroup,
  ProxyMode,
  ProxyNode,
  ProxySelection,
  ProxySelectionState,
  ProfilesState,
  SubscriptionMeta
} from '../models/MvpTypes';

const DEFAULT_RUNTIME_CONFIG =
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
    '  enable: true\n' +
    '  listen: 0.0.0.0:53\n' +
    '  enhanced-mode: fake-ip\n' +
    '  fake-ip-range: 198.18.0.0/15\n' +
    '  ipv6: false\n' +
    '  nameserver:\n' +
    '    - 223.5.5.5\n' +
    '    - 119.29.29.29\n' +
    '  fallback:\n' +
    '    - 1.1.1.1\n' +
    '    - 8.8.8.8\n' +
    '  default-nameserver:\n' +
    '    - 223.5.5.5\n' +
    '    - 119.29.29.29\n' +
    'tun:\n' +
    '  enable: false\n' +
    'proxies: []\n' +
    'proxy-groups: []\n' +
    'rules:\n' +
    '  - MATCH,DIRECT\n';

const DEFAULT_RAW_CONFIG =
  'mode: direct\n' +
    'log-level: info\n' +
    'proxies: []\n' +
    'proxy-groups: []\n' +
    'rules:\n' +
    '  - MATCH,DIRECT\n';

export class ConfigService {
  private filesDir: string;

  constructor(filesDir: string) {
    this.filesDir = filesDir;
  }

  ensureLayout(): MihomoLayout {
    const baseDir = this.filesDir + '/mihomo';
    const layout: MihomoLayout = {
      baseDir,
      homeDir: baseDir + '/home',
      profileDir: baseDir + '/profiles',
      runDir: baseDir + '/run',
      cacheDir: baseDir + '/cache',
      geoDir: baseDir + '/geo',
      logsDir: baseDir + '/logs',
      stateDir: baseDir + '/state',
      profilesPath: baseDir + '/state/profiles.json',
      runtimePath: baseDir + '/state/runtime.json',
      settingsPath: baseDir + '/state/settings.json',
      proxySelectionPath: baseDir + '/state/proxy-selections.json'
    };

    this.ensureDir(layout.baseDir);
    this.ensureDir(layout.homeDir);
    this.ensureDir(layout.profileDir);
    this.ensureDir(layout.runDir);
    this.ensureDir(layout.cacheDir);
    this.ensureDir(layout.geoDir);
    this.ensureDir(layout.logsDir);
    this.ensureDir(layout.stateDir);
    return layout;
  }

  ensureDefaultProfile(): Profile {
    const layout = this.ensureLayout();
    let state = this.loadProfilesState();
    let profile = this.findProfile(state, DEFAULT_PROFILE_ID);
    const now = Date.now();
    if (!profile) {
      profile = {
        id: DEFAULT_PROFILE_ID,
        name: 'Default',
        type: 'local',
        active: true,
        sourceUrl: '',
        rawPath: layout.profileDir + '/default.raw.yaml',
        runtimePath: layout.runDir + '/default.runtime.yaml',
        homeDir: layout.homeDir,
        createdAt: now,
        updatedAt: now,
        lastValidatedAt: 0,
        lastError: ''
      };
      state = {
        activeProfileId: DEFAULT_PROFILE_ID,
        profiles: [profile]
      };
      this.writeTextFile(profile.rawPath, DEFAULT_RAW_CONFIG);
      this.writeTextFile(profile.runtimePath, DEFAULT_RUNTIME_CONFIG);
      this.saveProfilesState(state);
      return profile;
    }

    if (!this.pathExists(profile.rawPath)) {
      this.writeTextFile(profile.rawPath, DEFAULT_RAW_CONFIG);
    }
    if (!this.pathExists(profile.runtimePath)) {
      this.writeTextFile(profile.runtimePath, DEFAULT_RUNTIME_CONFIG);
    }
    return profile;
  }

  getActiveProfile(): Profile {
    const state = this.loadProfilesState();
    const active = this.findProfile(state, state.activeProfileId);
    if (active) {
      return active;
    }
    return this.ensureDefaultProfile();
  }

  loadRawYaml(profileId: string = DEFAULT_PROFILE_ID): string {
    const profile = this.getProfile(profileId);
    if (!profile || !this.pathExists(profile.rawPath)) {
      return DEFAULT_RAW_CONFIG;
    }
    return fs.readTextSync(profile.rawPath);
  }

  saveDefaultRawYaml(content: string): ConfigValidationResult {
    return this.saveRawYaml(DEFAULT_PROFILE_ID, content);
  }

  saveRawYaml(profileId: string, content: string): ConfigValidationResult {
    const profile = this.getProfile(profileId) ?? this.ensureDefaultProfile();
    const validation = this.validateRawYaml(content);
    const now = Date.now();
    profile.updatedAt = now;
    profile.lastValidatedAt = now;
    profile.lastError = validation.ok ? '' : validation.errors.join('; ');
    this.writeTextFile(profile.rawPath, content);

    if (validation.ok) {
      const runtimeYaml = this.generateRuntimeYaml(content);
      this.writeTextFile(profile.runtimePath, runtimeYaml);
    }

    const state = this.loadProfilesState();
    const nextProfiles = state.profiles.map((item: Profile) => {
      return item.id === profile.id ? profile : item;
    });
    this.saveProfilesState({
      activeProfileId: state.activeProfileId,
      profiles: nextProfiles
    });
    return validation;
  }

  validateRawYaml(content: string): ConfigValidationResult {
    const unsupported = this.getUnsupportedConfigKeys(content);
    const errors: string[] = [];
    if (content.trim().length === 0) {
      errors.push('配置不能为空');
    }
    if (unsupported.length > 0) {
      errors.push('不支持字段: ' + unsupported.join(', '));
    }
    return {
      ok: errors.length === 0,
      unsupportedKeys: unsupported,
      errors,
      warnings: ['MVP-01A 使用移动端安全 runtime 模板，复杂 YAML 转换将在后续版本完善。']
    };
  }

  generateRuntimeYaml(rawYaml: string, settings?: AppSettings): string {
    const resolvedSettings = settings ?? this.loadStoredSettings();
    const rawMode = this.extractTopLevelScalar(rawYaml, 'mode', resolvedSettings.proxyMode);
    const safeMode = this.safeProxyMode(resolvedSettings.proxyMode || rawMode);
    const logLevel = this.safeLogLevel(resolvedSettings.logLevel);
    const dnsMode = this.toRuntimeDnsMode(resolvedSettings.dnsMode);
    const ipv6 = resolvedSettings.ipv6Enabled ? 'true' : 'false';
    return DEFAULT_RUNTIME_CONFIG
      .replace('mode: direct\n', 'mode: ' + safeMode + '\n')
      .replace('log-level: info\n', 'log-level: ' + logLevel + '\n')
      .replace('ipv6: false\n', 'ipv6: ' + ipv6 + '\n')
      .replace('  enhanced-mode: fake-ip\n', '  enhanced-mode: ' + dnsMode + '\n')
      .replace('  ipv6: false\n', '  ipv6: ' + ipv6 + '\n')
      .replace(
        'proxies: []\n' +
          'proxy-groups: []\n' +
          'rules:\n' +
          '  - MATCH,DIRECT\n',
        this.buildRuntimeTrafficBlocks(rawYaml));
  }

  loadProfilesState(): ProfilesState {
    const layout = this.ensureLayout();
    if (!this.pathExists(layout.profilesPath)) {
      const profile = this.createDefaultProfileObject(layout);
      const initial: ProfilesState = {
        activeProfileId: DEFAULT_PROFILE_ID,
        profiles: [profile]
      };
      this.saveProfilesState(initial);
      return initial;
    }

    try {
      const text = fs.readTextSync(layout.profilesPath);
      const parsed = JSON.parse(text) as ProfilesState;
      if (!parsed.profiles || parsed.profiles.length === 0) {
        throw new Error('profiles.json has no profiles');
      }
      return parsed;
    } catch (_) {
      const profile = this.createDefaultProfileObject(layout);
      const fallback: ProfilesState = {
        activeProfileId: DEFAULT_PROFILE_ID,
        profiles: [profile]
      };
      this.saveProfilesState(fallback);
      return fallback;
    }
  }

  saveProfilesState(state: ProfilesState): void {
    const layout = this.ensureLayout();
    this.writeTextFileAtomic(layout.profilesPath, JSON.stringify(state));
  }

  getProfile(profileId: string): Profile | null {
    return this.findProfile(this.loadProfilesState(), profileId);
  }

  createSubscriptionProfile(name: string, url: string): Profile {
    const layout = this.ensureLayout();
    const state = this.loadProfilesState();
    const id = 'sub-' + Date.now().toString(36) + '-' + Math.floor(Math.random() * 10000).toString(36);
    const now = Date.now();
    const profile: Profile = {
      id: id,
      name: name,
      type: 'subscription',
      active: false,
      sourceUrl: url,
      subscription: this.makeEmptySubscriptionMeta(url),
      rawPath: layout.profileDir + '/' + id + '.raw.yaml',
      runtimePath: layout.runDir + '/' + id + '.runtime.yaml',
      homeDir: layout.homeDir,
      createdAt: now,
      updatedAt: now,
      lastValidatedAt: 0,
      lastError: ''
    };
    state.profiles.push(profile);
    this.saveProfilesState(state);
    return profile;
  }

  createLocalProfile(name: string, content: string): Profile {
    const layout = this.ensureLayout();
    const state = this.loadProfilesState();
    const id = 'local-' + Date.now().toString(36) + '-' + Math.floor(Math.random() * 10000).toString(36);
    const now = Date.now();
    const profile: Profile = {
      id: id,
      name: name.length > 0 ? name : '新配置',
      type: 'local',
      active: false,
      sourceUrl: '',
      rawPath: layout.profileDir + '/' + id + '.raw.yaml',
      runtimePath: layout.runDir + '/' + id + '.runtime.yaml',
      homeDir: layout.homeDir,
      createdAt: now,
      updatedAt: now,
      lastValidatedAt: now,
      lastError: ''
    };
    const validation = this.validateRawYaml(content);
    profile.lastError = validation.ok ? '' : validation.errors.join('; ');
    this.writeTextFile(profile.rawPath, content);
    this.writeTextFile(profile.runtimePath, validation.ok ? this.generateRuntimeYaml(content) : DEFAULT_RUNTIME_CONFIG);
    state.profiles.push(profile);
    this.saveProfilesState(state);
    return profile;
  }

  setActiveProfile(profileId: string): Profile | null {
    const state = this.loadProfilesState();
    const profile = this.findProfile(state, profileId);
    if (!profile) {
      return null;
    }
    for (const p of state.profiles) {
      p.active = (p.id === profileId);
    }
    state.activeProfileId = profileId;
    this.saveProfilesState(state);
    return profile;
  }

  listProfiles(): Profile[] {
    return this.loadProfilesState().profiles;
  }

  duplicateProfile(profileId: string): Profile | null {
    const source = this.getProfile(profileId);
    if (!source) {
      return null;
    }

    const layout = this.ensureLayout();
    const state = this.loadProfilesState();
    const id = 'profile-' + Date.now().toString(36) + '-' + Math.floor(Math.random() * 10000).toString(36);
    const now = Date.now();
    const profile: Profile = {
      id: id,
      name: source.name + ' 副本',
      type: source.type,
      active: false,
      sourceUrl: source.sourceUrl,
      rawPath: layout.profileDir + '/' + id + '.raw.yaml',
      runtimePath: layout.runDir + '/' + id + '.runtime.yaml',
      homeDir: layout.homeDir,
      createdAt: now,
      updatedAt: now,
      lastValidatedAt: source.lastValidatedAt,
      lastError: source.lastError
    };
    if (source.subscription) {
      profile.subscription = {
        url: source.subscription.url,
        userAgent: source.subscription.userAgent,
        lastFetchedAt: source.subscription.lastFetchedAt,
        lastSuccessAt: source.subscription.lastSuccessAt,
        failureCount: source.subscription.failureCount,
        lastStatusCode: source.subscription.lastStatusCode,
        lastError: source.subscription.lastError,
        lastBytes: source.subscription.lastBytes
      };
    }

    const rawYaml = this.pathExists(source.rawPath) ? fs.readTextSync(source.rawPath) : DEFAULT_RAW_CONFIG;
    const runtimeYaml = this.pathExists(source.runtimePath) ? fs.readTextSync(source.runtimePath) :
      this.generateRuntimeYaml(rawYaml);
    this.writeTextFile(profile.rawPath, rawYaml);
    this.writeTextFile(profile.runtimePath, runtimeYaml);
    state.profiles.push(profile);
    this.saveProfilesState(state);
    return profile;
  }

  deleteProfile(profileId: string): boolean {
    const state = this.loadProfilesState();
    if (profileId === DEFAULT_PROFILE_ID || state.profiles.length <= 1) {
      return false;
    }

    const profile = this.findProfile(state, profileId);
    if (!profile) {
      return false;
    }

    const remaining = state.profiles.filter((item: Profile) => item.id !== profileId);
    if (remaining.length === 0) {
      return false;
    }

    if (state.activeProfileId === profileId) {
      remaining[0].active = true;
      state.activeProfileId = remaining[0].id;
    }
    for (const item of remaining) {
      if (item.id !== state.activeProfileId) {
        item.active = false;
      }
    }
    state.profiles = remaining;
    this.saveProfilesState(state);
    this.deleteIfExists(profile.rawPath);
    this.deleteIfExists(profile.runtimePath);
    return true;
  }

  listProxyNodes(profileId: string = ''): ProxyNode[] {
    const groups = this.listProxyGroups(profileId);
    if (groups.length === 0) {
      return [];
    }
    return groups[0].nodes;
  }

  listProxyGroups(profileId: string = ''): ProxyGroup[] {
    const profile = profileId.length > 0 ? this.getProfile(profileId) : this.getActiveProfile();
    if (!profile) {
      return [];
    }
    const yaml = this.loadRawYaml(profile.id);
    const sourceNodes = this.extractProxyNodes(yaml, '');
    const parsedGroups = this.extractProxyGroups(yaml);
    if (parsedGroups.length === 0) {
      return [this.buildProxyGroup(profile.id, 'Proxy', 'select', sourceNodes, [], '')];
    }
    return parsedGroups.map((group: ProxyGroup) => {
      return this.buildProxyGroup(profile.id, group.name, group.type, sourceNodes, group.nodes, group.selected);
    });
  }

  selectLocalProxy(groupName: string, nodeName: string, profileId: string = ''): boolean {
    const profile = profileId.length > 0 ? this.getProfile(profileId) : this.getActiveProfile();
    if (!profile || groupName.length === 0 || nodeName.length === 0) {
      return false;
    }
    const groups = this.listProxyGroups(profile.id);
    let group: ProxyGroup | null = null;
    for (const item of groups) {
      if (item.name === groupName) {
        group = item;
        break;
      }
    }
    if (!group || !group.nodes.some((node: ProxyNode) => node.name === nodeName)) {
      return false;
    }
    const state = this.loadProxySelectionState();
    const next: ProxySelection = {
      profileId: profile.id,
      groupName,
      nodeName,
      updatedAt: Date.now()
    };
    const rest = state.selections.filter((item: ProxySelection) => {
      return item.profileId !== profile.id || item.groupName !== groupName;
    });
    this.saveProxySelectionState({ selections: rest.concat([next]) });
    return true;
  }

  countRules(profileId: string = ''): number {
    const profile = profileId.length > 0 ? this.getProfile(profileId) : this.getActiveProfile();
    if (!profile) {
      return 0;
    }
    return this.countRulesInYaml(this.loadRawYaml(profile.id));
  }

  pathExists(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (_) {
      return false;
    }
  }

  writeTextFile(path: string, content: string): number {
    const file = fs.openSync(path, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      return fs.writeSync(file.fd, content);
    } finally {
      fs.closeSync(file);
    }
  }

  writeTextFileAtomic(path: string, content: string): void {
    this.ensureParentDir(path);
    const tmpPath = path + '.tmp.' + Date.now().toString() + '.' + Math.floor(Math.random() * 1000000).toString();
    this.writeTextFile(tmpPath, content);
    try {
      fs.renameSync(tmpPath, path);
    } catch (err) {
      try {
        if (this.pathExists(tmpPath)) {
          fs.unlinkSync(tmpPath);
        }
      } catch (_) {
      }
      throw new Error(String(err));
    }
  }

  private ensureDir(path: string): void {
    if (this.pathExists(path)) {
      return;
    }
    fs.mkdirSync(path, true);
  }

  private ensureParentDir(path: string): void {
    const index = path.lastIndexOf('/');
    if (index <= 0) {
      return;
    }
    this.ensureDir(path.substring(0, index));
  }

  private deleteIfExists(path: string): void {
    try {
      if (this.pathExists(path)) {
        fs.unlinkSync(path);
      }
    } catch (_) {
    }
  }

  private createDefaultProfileObject(layout: MihomoLayout): Profile {
    const now = Date.now();
    return {
      id: DEFAULT_PROFILE_ID,
      name: 'Default',
      type: 'local',
      active: true,
      sourceUrl: '',
      rawPath: layout.profileDir + '/default.raw.yaml',
      runtimePath: layout.runDir + '/default.runtime.yaml',
      homeDir: layout.homeDir,
      createdAt: now,
      updatedAt: now,
      lastValidatedAt: 0,
      lastError: ''
    };
  }

  private findProfile(state: ProfilesState, profileId: string): Profile | null {
    for (const profile of state.profiles) {
      if (profile.id === profileId) {
        return profile;
      }
    }
    return null;
  }

  private getUnsupportedConfigKeys(yaml: string): string[] {
    const unsupported: string[] = [];
    const lines = yaml.split('\n');
    const blocked = ['script', 'proxy-providers', 'rule-providers', 'external-ui', 'interface-name', 'routing-mark'];
    for (const rawLine of lines) {
      const trimmed = rawLine.trim();
      if (trimmed.length === 0 || trimmed.startsWith('#')) {
        continue;
      }
      for (const key of blocked) {
        if (trimmed === key + ':' && unsupported.indexOf(key) < 0) {
          unsupported.push(key);
        }
      }
    }
    return unsupported;
  }

  private extractTopLevelScalar(yaml: string, key: string, fallback: string): string {
    const lines = yaml.split('\n');
    for (const rawLine of lines) {
      if (rawLine.startsWith(' ') || rawLine.startsWith('\t')) {
        continue;
      }
      const prefix = key + ':';
      if (rawLine.startsWith(prefix)) {
        return rawLine.substring(prefix.length).trim();
      }
    }
    return fallback;
  }

  private safeProxyMode(mode: string): ProxyMode {
    if (mode === 'rule' || mode === 'global' || mode === 'direct') {
      return mode;
    }
    return DEFAULT_APP_SETTINGS.proxyMode;
  }

  private safeLogLevel(level: string): LogLevel {
    if (level === 'debug' || level === 'info' || level === 'warning' || level === 'error') {
      return level;
    }
    return DEFAULT_APP_SETTINGS.logLevel;
  }

  private loadStoredSettings(): AppSettings {
    const layout = this.ensureLayout();
    if (!this.pathExists(layout.settingsPath)) {
      return DEFAULT_APP_SETTINGS;
    }
    try {
      const parsed = JSON.parse(fs.readTextSync(layout.settingsPath)) as Partial<AppSettings>;
      return {
        routeMode: DEFAULT_APP_SETTINGS.routeMode,
        proxyMode: this.safeProxyMode(parsed.proxyMode ?? DEFAULT_APP_SETTINGS.proxyMode),
        dnsMode: parsed.dnsMode === 'default' || parsed.dnsMode === 'fake-ip' || parsed.dnsMode === 'redir-host' ?
          parsed.dnsMode : DEFAULT_APP_SETTINGS.dnsMode,
        vpnDnsAddress: parsed.vpnDnsAddress && parsed.vpnDnsAddress.length > 0 ? parsed.vpnDnsAddress :
          DEFAULT_APP_SETTINGS.vpnDnsAddress,
        ipv6Enabled: typeof parsed.ipv6Enabled === 'boolean' ? parsed.ipv6Enabled : DEFAULT_APP_SETTINGS.ipv6Enabled,
        udpEnabled: typeof parsed.udpEnabled === 'boolean' ? parsed.udpEnabled : DEFAULT_APP_SETTINGS.udpEnabled,
        autoRefreshSubscriptionOnConnect: typeof parsed.autoRefreshSubscriptionOnConnect === 'boolean' ?
          parsed.autoRefreshSubscriptionOnConnect : DEFAULT_APP_SETTINGS.autoRefreshSubscriptionOnConnect,
        autoStart: typeof parsed.autoStart === 'boolean' ? parsed.autoStart : DEFAULT_APP_SETTINGS.autoStart,
        logLevel: this.safeLogLevel(parsed.logLevel ?? DEFAULT_APP_SETTINGS.logLevel)
      };
    } catch (_) {
      return DEFAULT_APP_SETTINGS;
    }
  }

  private toRuntimeDnsMode(mode: DnsMode): string {
    if (mode === 'redir-host') {
      return 'redir-host';
    }
    return 'fake-ip';
  }

  private buildRuntimeTrafficBlocks(rawYaml: string): string {
    const proxies = this.extractTopLevelBlock(rawYaml, 'proxies') || 'proxies: []\n';
    const proxyGroups = this.extractTopLevelBlock(rawYaml, 'proxy-groups') || 'proxy-groups: []\n';
    const rules = this.extractTopLevelBlock(rawYaml, 'rules') ||
      'rules:\n' +
        '  - MATCH,DIRECT\n';
    return this.ensureTrailingNewline(proxies) +
      this.ensureTrailingNewline(proxyGroups) +
      this.ensureTrailingNewline(rules);
  }

  private extractTopLevelBlock(yaml: string, key: string): string {
    const lines = yaml.split('\n');
    const blockLines: string[] = [];
    let collecting = false;
    const prefix = key + ':';

    for (const rawLine of lines) {
      if (!collecting) {
        if (rawLine === prefix || rawLine.startsWith(prefix + ' ')) {
          collecting = true;
          blockLines.push(rawLine);
        }
        continue;
      }

      if (this.isTopLevelContentLine(rawLine)) {
        break;
      }
      blockLines.push(rawLine);
    }

    if (blockLines.length === 0) {
      return '';
    }
    return blockLines.join('\n');
  }

  private isTopLevelContentLine(line: string): boolean {
    if (line.trim().length === 0 || line.trim().startsWith('#')) {
      return false;
    }
    return !line.startsWith(' ') && !line.startsWith('\t');
  }

  private ensureTrailingNewline(text: string): string {
    if (text.endsWith('\n')) {
      return text;
    }
    return text + '\n';
  }

  private extractProxyNodes(yaml: string, groupName: string): ProxyNode[] {
    const nodes: ProxyNode[] = [];
    const lines = yaml.split('\n');
    let collecting = false;
    let current: ProxyNode | null = null;

    for (const rawLine of lines) {
      if (!collecting) {
        const trimmed = rawLine.trim();
        if (trimmed === 'proxies:' || trimmed.startsWith('proxies: ')) {
          collecting = true;
        }
        continue;
      }

      if (this.isTopLevelContentLine(rawLine)) {
        break;
      }

      const trimmed = rawLine.trim();
      if (trimmed.length === 0 || trimmed.startsWith('#')) {
        continue;
      }

      if (trimmed.startsWith('- ')) {
        this.pushProxyNode(nodes, current);
        current = {
          name: '',
          type: '',
          server: '',
          port: '',
          group: groupName.length > 0 ? groupName : '默认',
          selected: false,
          delay: 0
        };
        this.readProxyField(trimmed.substring(2).trim(), current);
        continue;
      }

      if (current) {
        this.readProxyField(trimmed, current);
      }
    }

    this.pushProxyNode(nodes, current);
    return nodes;
  }

  private extractProxyGroups(yaml: string): ProxyGroup[] {
    const groups: ProxyGroup[] = [];
    const lines = yaml.split('\n');
    let collecting = false;
    let current: ProxyGroup | null = null;
    let readingProxies = false;

    for (const rawLine of lines) {
      if (!collecting) {
        const trimmed = rawLine.trim();
        if (trimmed === 'proxy-groups:' || trimmed.startsWith('proxy-groups: ')) {
          collecting = true;
        }
        continue;
      }

      if (this.isTopLevelContentLine(rawLine)) {
        break;
      }

      const trimmed = rawLine.trim();
      if (trimmed.length === 0 || trimmed.startsWith('#')) {
        continue;
      }

      if (trimmed.startsWith('- ')) {
        const item = trimmed.substring(2).trim();
        if (readingProxies && current && item.indexOf(':') < 0 && !item.startsWith('{')) {
          current.nodes.push(this.makeBuiltinProxyNode(this.cleanYamlScalar(item), current.name));
          continue;
        }

        this.pushProxyGroup(groups, current);
        current = {
          name: '',
          type: 'select',
          selected: '',
          nodes: []
        };
        readingProxies = false;
        if (item.startsWith('{')) {
          this.readInlineProxyGroup(item, current);
        } else {
          readingProxies = this.readProxyGroupField(item, current);
        }
        continue;
      }

      if (current) {
        readingProxies = this.readProxyGroupField(trimmed, current) || readingProxies;
      }
    }

    this.pushProxyGroup(groups, current);
    return groups;
  }

  private readInlineProxyGroup(line: string, group: ProxyGroup): void {
    group.name = this.extractInlineYamlValue(line, 'name') || group.name;
    group.type = this.extractInlineYamlValue(line, 'type') || group.type;
    const proxies = this.extractInlineArray(line, 'proxies');
    for (const proxy of proxies) {
      group.nodes.push(this.makeBuiltinProxyNode(proxy, group.name));
    }
  }

  private readProxyGroupField(line: string, group: ProxyGroup): boolean {
    const index = line.indexOf(':');
    if (index <= 0) {
      return false;
    }
    const key = line.substring(0, index).trim();
    const rawValue = line.substring(index + 1).trim();
    if (key === 'name') {
      group.name = this.cleanYamlScalar(rawValue);
      return false;
    }
    if (key === 'type') {
      group.type = this.cleanYamlScalar(rawValue);
      return false;
    }
    if (key === 'use' || key === 'proxies') {
      const values = this.extractInlineArray(line, key);
      for (const value of values) {
        group.nodes.push(this.makeBuiltinProxyNode(value, group.name));
      }
      return true;
    }
    return false;
  }

  private pushProxyGroup(groups: ProxyGroup[], group: ProxyGroup | null): void {
    if (!group || group.name.length === 0) {
      return;
    }
    groups.push({
      name: group.name,
      type: group.type.length > 0 ? group.type : 'select',
      selected: group.selected,
      nodes: group.nodes
    });
  }

  private loadProxySelectionState(): ProxySelectionState {
    const layout = this.ensureLayout();
    if (!this.pathExists(layout.proxySelectionPath)) {
      return { selections: [] };
    }
    try {
      const parsed = JSON.parse(fs.readTextSync(layout.proxySelectionPath)) as ProxySelectionState;
      return {
        selections: parsed.selections ? parsed.selections : []
      };
    } catch (_) {
      return { selections: [] };
    }
  }

  private saveProxySelectionState(state: ProxySelectionState): void {
    const layout = this.ensureLayout();
    this.writeTextFileAtomic(layout.proxySelectionPath, JSON.stringify(state));
  }

  private getSelectedProxy(profileId: string, groupName: string): string {
    const state = this.loadProxySelectionState();
    for (const selection of state.selections) {
      if (selection.profileId === profileId && selection.groupName === groupName) {
        return selection.nodeName;
      }
    }
    return '';
  }

  private countRulesInYaml(yaml: string): number {
    const lines = yaml.split('\n');
    let collecting = false;
    let count = 0;
    for (const rawLine of lines) {
      if (!collecting) {
        const trimmed = rawLine.trim();
        if (trimmed === 'rules:' || trimmed.startsWith('rules: ')) {
          collecting = true;
          if (trimmed.startsWith('rules: [') && trimmed.indexOf(']') > trimmed.indexOf('[')) {
            const inline = trimmed.substring(trimmed.indexOf('[') + 1, trimmed.indexOf(']')).trim();
            return inline.length > 0 ? inline.split(',').length : 0;
          }
        }
        continue;
      }
      if (this.isTopLevelContentLine(rawLine)) {
        break;
      }
      const trimmed = rawLine.trim();
      if (trimmed.startsWith('- ')) {
        count++;
      }
    }
    return count;
  }

  private buildProxyGroup(profileId: string, groupName: string, groupType: string, sourceNodes: ProxyNode[],
    declaredNodes: ProxyNode[], yamlSelected: string): ProxyGroup {
    const selection = this.getSelectedProxy(profileId, groupName);
    const nodes = this.resolveGroupNodes(groupName, sourceNodes, declaredNodes, yamlSelected);
    const selected = selection.length > 0 && nodes.some((node: ProxyNode) => node.name === selection) ?
      selection : (yamlSelected.length > 0 ? yamlSelected : (nodes.length > 0 ? nodes[0].name : ''));
    const nextNodes = nodes.map((node: ProxyNode) => {
      const next: ProxyNode = {
        name: node.name,
        type: node.type,
        server: node.server,
        port: node.port,
        group: groupName,
        selected: node.name === selected,
        delay: node.delay
      };
      return next;
    });
    return {
      name: groupName,
      type: groupType.length > 0 ? groupType : 'select',
      selected,
      nodes: nextNodes
    };
  }

  private resolveGroupNodes(groupName: string, sourceNodes: ProxyNode[], declaredNodes: ProxyNode[],
    yamlSelected: string): ProxyNode[] {
    let declaredNames: string[] = declaredNodes.map((node: ProxyNode) => node.name);
    if (declaredNames.length === 0) {
      declaredNames = sourceNodes.map((node: ProxyNode) => node.name);
    }
    if (yamlSelected.length > 0 && declaredNames.indexOf(yamlSelected) < 0) {
      declaredNames = [yamlSelected].concat(declaredNames);
    }
    const resolved: ProxyNode[] = [];
    for (const name of declaredNames) {
      const source = this.findProxyNode(sourceNodes, name);
      if (source) {
        resolved.push({
          name: source.name,
          type: source.type,
          server: source.server,
          port: source.port,
          group: groupName,
          selected: false,
          delay: source.delay
        });
      } else {
        resolved.push(this.makeBuiltinProxyNode(name, groupName));
      }
    }
    return resolved;
  }

  private findProxyNode(nodes: ProxyNode[], name: string): ProxyNode | null {
    for (const node of nodes) {
      if (node.name === name) {
        return node;
      }
    }
    return null;
  }

  private makeBuiltinProxyNode(name: string, groupName: string): ProxyNode {
    const upper = name.toUpperCase();
    return {
      name,
      type: upper === 'DIRECT' || upper === 'REJECT' ? 'builtin' : 'proxy',
      server: upper === 'DIRECT' || upper === 'REJECT' ? upper : '',
      port: '',
      group: groupName,
      selected: false,
      delay: 0
    };
  }

  private extractInlineArray(line: string, key: string): string[] {
    const marker = key + ':';
    const index = line.indexOf(marker);
    if (index < 0) {
      return [];
    }
    const after = line.substring(index + marker.length);
    const start = after.indexOf('[');
    const end = after.indexOf(']');
    if (start < 0 || end <= start) {
      return [];
    }
    return after.substring(start + 1, end)
      .split(',')
      .map((item: string) => this.cleanYamlScalar(item))
      .filter((item: string) => item.length > 0);
  }

  private readProxyField(line: string, node: ProxyNode): void {
    if (line.startsWith('{')) {
      node.name = this.extractInlineYamlValue(line, 'name') || node.name;
      node.type = this.extractInlineYamlValue(line, 'type') || node.type;
      node.server = this.extractInlineYamlValue(line, 'server') || node.server;
      node.port = this.extractInlineYamlValue(line, 'port') || node.port;
      return;
    }

    const index = line.indexOf(':');
    if (index <= 0) {
      return;
    }
    const key = line.substring(0, index).trim();
    const value = this.cleanYamlScalar(line.substring(index + 1));
    if (key === 'name') {
      node.name = value;
    } else if (key === 'type') {
      node.type = value;
    } else if (key === 'server') {
      node.server = value;
    } else if (key === 'port') {
      node.port = value;
    }
  }

  private extractInlineYamlValue(line: string, key: string): string {
    const marker = key + ':';
    let index = line.indexOf(marker);
    if (index < 0) {
      index = line.indexOf(key + ': ');
    }
    if (index < 0) {
      return '';
    }
    const start = index + marker.length;
    const tail = line.substring(start);
    const commaIndex = tail.indexOf(',');
    const raw = commaIndex >= 0 ? tail.substring(0, commaIndex) : tail;
    return this.cleanYamlScalar(raw.replace('{', '').replace('}', ''));
  }

  private cleanYamlScalar(value: string): string {
    let next = value.trim();
    if (next.endsWith(',')) {
      next = next.substring(0, next.length - 1).trim();
    }
    if ((next.startsWith('"') && next.endsWith('"')) || (next.startsWith('\'') && next.endsWith('\''))) {
      next = next.substring(1, next.length - 1);
    }
    return next;
  }

  private pushProxyNode(nodes: ProxyNode[], node: ProxyNode | null): void {
    if (!node || node.name.length === 0) {
      return;
    }
    nodes.push({
      name: node.name,
      type: node.type.length > 0 ? node.type : 'unknown',
      server: node.server,
      port: node.port,
      group: node.group,
      selected: node.selected,
      delay: node.delay
    });
  }

  private extractFirstProxyGroupName(yaml: string): string {
    const lines = yaml.split('\n');
    let collecting = false;
    for (const rawLine of lines) {
      if (!collecting) {
        const trimmed = rawLine.trim();
        if (trimmed === 'proxy-groups:' || trimmed.startsWith('proxy-groups: ')) {
          collecting = true;
        }
        continue;
      }

      if (this.isTopLevelContentLine(rawLine)) {
        break;
      }
      const trimmed = rawLine.trim();
      if (trimmed.startsWith('- ')) {
        const first = trimmed.substring(2).trim();
        if (first.startsWith('{')) {
          return this.extractInlineYamlValue(first, 'name');
        }
        if (first.startsWith('name:')) {
          return this.cleanYamlScalar(first.substring('name:'.length));
        }
      } else if (trimmed.startsWith('name:')) {
        return this.cleanYamlScalar(trimmed.substring('name:'.length));
      }
    }
    return '';
  }

  private makeEmptySubscriptionMeta(url: string): SubscriptionMeta {
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
}
