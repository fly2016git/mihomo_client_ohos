import fs from '@ohos.file.fs';
import { ConfigService } from '../config/ConfigService';
import {
  AppSettings,
  Profile,
  RuntimeEvent,
  RuntimeEventLevel,
  RuntimeEventSource,
  RuntimeSnapshot,
  TrafficStatsSource
} from '../models/MvpTypes';

const MAX_EVENTS = 60;

interface RuntimeStateFile {
  snapshot: RuntimeSnapshot;
  events: string[];
  runtimeEvents: RuntimeEvent[];
}

export class RuntimeStore {
  private configService: ConfigService;

  constructor(filesDir: string) {
    this.configService = new ConfigService(filesDir);
  }

  getSnapshot(): RuntimeSnapshot {
    return this.loadStateFile().snapshot;
  }

  setSnapshot(next: RuntimeSnapshot): void {
    const state = this.loadStateFile();
    state.snapshot = next;
    this.saveStateFile(state);
  }

  update(patch: Partial<RuntimeSnapshot>): void {
    const state = this.loadStateFile();
    if (patch.runtimeState !== undefined) {
      state.snapshot.runtimeState = patch.runtimeState;
    }
    if (patch.coreState !== undefined) {
      state.snapshot.coreState = patch.coreState;
    }
    if (patch.activeProfileId !== undefined) {
      state.snapshot.activeProfileId = patch.activeProfileId;
    }
    if (patch.activeProfileName !== undefined) {
      state.snapshot.activeProfileName = patch.activeProfileName;
    }
    if (patch.tunFd !== undefined) {
      state.snapshot.tunFd = patch.tunFd;
    }
    if (patch.startedAt !== undefined) {
      state.snapshot.startedAt = patch.startedAt;
    }
    if (patch.lastError !== undefined) {
      state.snapshot.lastError = patch.lastError;
    }
    if (patch.lastEvent !== undefined) {
      state.snapshot.lastEvent = patch.lastEvent;
    }
    if (patch.uploadSpeed !== undefined) {
      state.snapshot.uploadSpeed = patch.uploadSpeed;
    }
    if (patch.downloadSpeed !== undefined) {
      state.snapshot.downloadSpeed = patch.downloadSpeed;
    }
    if (patch.todayUploadBytes !== undefined) {
      state.snapshot.todayUploadBytes = patch.todayUploadBytes;
    }
    if (patch.todayDownloadBytes !== undefined) {
      state.snapshot.todayDownloadBytes = patch.todayDownloadBytes;
    }
    if (patch.trafficSource !== undefined) {
      state.snapshot.trafficSource = patch.trafficSource;
    }
    state.snapshot.updatedAt = Date.now();
    this.saveStateFile(state);
  }

  appendEvent(message: string, level?: RuntimeEventLevel, source?: RuntimeEventSource): void {
    const state = this.loadStateFile();
    const event: RuntimeEvent = {
      timestamp: Date.now(),
      level: level ?? this.inferLevel(message),
      source: source ?? this.inferSource(message),
      message
    };
    const line = this.formatEvent(event);
    state.runtimeEvents = [event].concat(state.runtimeEvents).slice(0, MAX_EVENTS);
    state.events = [line].concat(state.events).slice(0, MAX_EVENTS);
    state.snapshot.lastEvent = message;
    if (event.level === 'error') {
      state.snapshot.lastError = message;
    }
    state.snapshot.updatedAt = Date.now();
    this.saveStateFile(state);
  }

  getEvents(): string[] {
    return this.loadStateFile().events;
  }

  getRuntimeEvents(): RuntimeEvent[] {
    return this.loadStateFile().runtimeEvents;
  }

  getPocSmokeSummary(): string {
    const summary = this.readPocSmokeSummary();
    return summary.length > 0 ? summary : '未运行';
  }

  exportDiagnostics(settings: AppSettings, profile: Profile, selectedGroup: string, selectedNode: string,
    selectedNodeMeta: string): string {
    const layout = this.configService.ensureLayout();
    const state = this.loadStateFile();
    const content = this.createDiagnosticsText(settings, profile, selectedGroup, selectedNode, selectedNodeMeta,
      state.snapshot, state.runtimeEvents);
    const path = layout.logsDir + '/diagnostics-' + this.fileTimestamp(Date.now()) + '.txt';
    this.configService.writeTextFileAtomic(path, content);
    this.appendEvent('Diagnostics exported path=' + path, 'info', 'diagnostic');
    return path;
  }

  createDiagnosticsText(settings: AppSettings, profile: Profile, selectedGroup: string, selectedNode: string,
    selectedNodeMeta: string, snapshot?: RuntimeSnapshot, events?: RuntimeEvent[]): string {
    const resolvedSnapshot = snapshot ?? this.getSnapshot();
    const resolvedEvents = events ?? this.getRuntimeEvents();
    const lines: string[] = [];
    lines.push('FlowGuard Diagnostics');
    lines.push('generatedAt=' + new Date().toISOString());
    lines.push('');
    lines.push('[snapshot]');
    lines.push(JSON.stringify(resolvedSnapshot));
    lines.push('');
    lines.push('[settings]');
    lines.push(JSON.stringify(settings));
    lines.push('');
    lines.push('[activeProfile]');
    lines.push(JSON.stringify(profile));
    lines.push('');
    lines.push('[currentProxy]');
    lines.push('group=' + selectedGroup);
    lines.push('node=' + selectedNode);
    lines.push('meta=' + selectedNodeMeta);
    lines.push('');
    lines.push('[traffic]');
    lines.push('source=' + resolvedSnapshot.trafficSource);
    lines.push('uploadSpeed=' + resolvedSnapshot.uploadSpeed);
    lines.push('downloadSpeed=' + resolvedSnapshot.downloadSpeed);
    lines.push('todayUploadBytes=' + resolvedSnapshot.todayUploadBytes);
    lines.push('todayDownloadBytes=' + resolvedSnapshot.todayDownloadBytes);
    lines.push('');
    lines.push('[pocSmoke]');
    lines.push(this.getPocSmokeSummary());
    lines.push('');
    lines.push('[events]');
    for (const event of resolvedEvents.slice(0, MAX_EVENTS)) {
      lines.push(this.formatEvent(event));
    }
    return lines.join('\n');
  }

  resetToIdle(message: string): void {
    const profile = this.configService.ensureDefaultProfile();
    const now = Date.now();
    this.setSnapshot({
      runtimeState: 'idle',
      coreState: 'stopped',
      activeProfileId: profile.id,
      activeProfileName: profile.name,
      tunFd: -1,
      startedAt: 0,
      updatedAt: now,
      lastError: '',
      lastEvent: message,
      uploadSpeed: 0,
      downloadSpeed: 0,
      todayUploadBytes: 0,
      todayDownloadBytes: 0,
      trafficSource: 'none'
    });
    this.appendEvent(message, 'info', 'ui');
  }

  private loadStateFile(): RuntimeStateFile {
    const layout = this.configService.ensureLayout();
    if (!this.configService.pathExists(layout.runtimePath)) {
      const initial = this.createInitialState();
      this.saveStateFile(initial);
      return initial;
    }

    try {
      const text = fs.readTextSync(layout.runtimePath);
      const parsed = JSON.parse(text) as RuntimeStateFile;
      if (!parsed.snapshot || (!parsed.events && !parsed.runtimeEvents)) {
        throw new Error('invalid runtime state');
      }
      const normalized = this.normalizeStateFile(parsed);
      if (!parsed.runtimeEvents || parsed.runtimeEvents.length === 0 ||
        JSON.stringify(normalized) !== JSON.stringify(parsed)) {
        this.saveStateFile(normalized);
      }
      return normalized;
    } catch (_) {
      const fallback = this.createInitialState();
      this.saveStateFile(fallback);
      return fallback;
    }
  }

  private saveStateFile(state: RuntimeStateFile): void {
    const layout = this.configService.ensureLayout();
    this.configService.writeTextFileAtomic(layout.runtimePath, JSON.stringify(state));
  }

  private createInitialState(): RuntimeStateFile {
    const profile = this.configService.ensureDefaultProfile();
    const now = Date.now();
    return {
      snapshot: {
        runtimeState: 'idle',
        coreState: 'stopped',
        activeProfileId: profile.id,
        activeProfileName: profile.name,
        tunFd: -1,
        startedAt: 0,
        updatedAt: now,
        lastError: '',
        lastEvent: 'Ready',
        uploadSpeed: 0,
        downloadSpeed: 0,
        todayUploadBytes: 0,
        todayDownloadBytes: 0,
        trafficSource: 'none'
      },
      events: [this.formatEvent({
        timestamp: now,
        level: 'info',
        source: 'ui',
        message: 'Ready'
      })],
      runtimeEvents: [{
        timestamp: now,
        level: 'info',
        source: 'ui',
        message: 'Ready'
      }]
    };
  }

  private normalizeStateFile(parsed: RuntimeStateFile): RuntimeStateFile {
    const runtimeEvents = this.normalizeRuntimeEvents(parsed.runtimeEvents, parsed.events);
    return {
      snapshot: this.normalizeSnapshot(parsed.snapshot),
      events: runtimeEvents.map((event: RuntimeEvent) => this.formatEvent(event)),
      runtimeEvents
    };
  }

  private normalizeSnapshot(snapshot: RuntimeSnapshot): RuntimeSnapshot {
    return {
      runtimeState: snapshot.runtimeState,
      coreState: snapshot.coreState,
      activeProfileId: snapshot.activeProfileId,
      activeProfileName: snapshot.activeProfileName,
      tunFd: typeof snapshot.tunFd === 'number' ? snapshot.tunFd : -1,
      startedAt: typeof snapshot.startedAt === 'number' ? snapshot.startedAt : 0,
      updatedAt: typeof snapshot.updatedAt === 'number' ? snapshot.updatedAt : Date.now(),
      lastError: snapshot.lastError ? snapshot.lastError : '',
      lastEvent: snapshot.lastEvent ? snapshot.lastEvent : '',
      uploadSpeed: typeof snapshot.uploadSpeed === 'number' ? snapshot.uploadSpeed : 0,
      downloadSpeed: typeof snapshot.downloadSpeed === 'number' ? snapshot.downloadSpeed : 0,
      todayUploadBytes: typeof snapshot.todayUploadBytes === 'number' ? snapshot.todayUploadBytes : 0,
      todayDownloadBytes: typeof snapshot.todayDownloadBytes === 'number' ? snapshot.todayDownloadBytes : 0,
      trafficSource: this.safeTrafficSource(snapshot.trafficSource)
    };
  }

  private normalizeRuntimeEvents(runtimeEvents: RuntimeEvent[] | undefined, events: string[] | undefined): RuntimeEvent[] {
    if (runtimeEvents && runtimeEvents.length > 0) {
      return runtimeEvents.map((event: RuntimeEvent) => this.normalizeRuntimeEvent(event)).slice(0, MAX_EVENTS);
    }
    const fallbackEvents = events ? events : [];
    return fallbackEvents.map((line: string) => this.runtimeEventFromLine(line)).slice(0, MAX_EVENTS);
  }

  private normalizeRuntimeEvent(event: RuntimeEvent): RuntimeEvent {
    const originalMessage = event.message ? event.message : '';
    const message = this.stripLegacyTimestamp(originalMessage);
    const shouldInfer = message !== originalMessage;
    return {
      timestamp: typeof event.timestamp === 'number' && event.timestamp > 0 ? event.timestamp : Date.now(),
      level: shouldInfer ? this.inferLevel(message) : this.safeLevel(event.level),
      source: shouldInfer ? this.inferSource(message) : this.safeSource(event.source),
      message
    };
  }

  private runtimeEventFromLine(line: string): RuntimeEvent {
    const message = this.stripLegacyTimestamp(line);
    return {
      timestamp: Date.now(),
      level: this.inferLevel(message),
      source: this.inferSource(message),
      message
    };
  }

  private formatEvent(event: RuntimeEvent): string {
    const time = new Date(event.timestamp).toLocaleTimeString();
    return time + ' [' + event.level + '/' + event.source + '] ' + event.message;
  }

  private fileTimestamp(timestamp: number): string {
    const text = new Date(timestamp).toISOString();
    return text.replace(/:/g, '-').replace(/\./g, '-');
  }

  private readPocSmokeSummary(): string {
    const layout = this.configService.ensureLayout();
    const candidates: string[] = [
      layout.logsDir + '/poc-smoke-summary.txt',
      layout.logsDir + '/smoke-summary.txt',
      layout.logsDir + '/poc-regression-summary.txt',
      layout.stateDir + '/poc-smoke-summary.txt',
      layout.stateDir + '/smoke-summary.txt'
    ];
    for (const path of candidates) {
      if (!this.configService.pathExists(path)) {
        continue;
      }
      try {
        const content = fs.readTextSync(path).trim();
        if (content.length > 0) {
          return content;
        }
      } catch (_) {
      }
    }
    return '';
  }

  private safeLevel(level: RuntimeEventLevel): RuntimeEventLevel {
    if (level === 'debug' || level === 'info' || level === 'warn' || level === 'error') {
      return level;
    }
    return 'info';
  }

  private safeSource(source: RuntimeEventSource): RuntimeEventSource {
    if (source === 'ui' || source === 'vpn' || source === 'core' || source === 'subscription' ||
      source === 'config' || source === 'diagnostic') {
      return source;
    }
    return 'ui';
  }

  private safeTrafficSource(source: TrafficStatsSource): TrafficStatsSource {
    if (source === 'tun-interface' || source === 'native-mihomo') {
      return source;
    }
    return 'none';
  }

  private inferLevel(line: string): RuntimeEventLevel {
    const lower = line.toLowerCase();
    if (lower.indexOf('error:') >= 0 || lower.indexOf(' failed:') >= 0 || lower.indexOf(' failed ') >= 0 ||
      lower.endsWith(' failed') || lower.indexOf('失败') >= 0 || lower.indexOf('not running') >= 0 ||
      lower.indexOf('timeout') >= 0) {
      return 'error';
    }
    if (lower.indexOf('warn') >= 0 || lower.indexOf('rejected') >= 0) {
      return 'warn';
    }
    if (lower.indexOf('debug') >= 0) {
      return 'debug';
    }
    return 'info';
  }

  private inferSource(line: string): RuntimeEventSource {
    const lower = line.toLowerCase();
    if (lower.indexOf('core') >= 0 || lower.indexOf('mihomo') >= 0 || lower.indexOf('latency test native') >= 0) {
      return 'core';
    }
    if (lower.indexOf('vpn') >= 0 || lower.indexOf('tun') >= 0 || lower.indexOf('protect') >= 0 ||
      lower.indexOf('connected') >= 0 || lower.indexOf('disconnected') >= 0) {
      return 'vpn';
    }
    if (lower.indexOf('diagnostic') >= 0) {
      return 'diagnostic';
    }
    if (lower.indexOf('config') >= 0 || lower.indexOf('settings') >= 0) {
      return 'config';
    }
    if (lower.indexOf('subscription update') >= 0 || lower.indexOf('subscription add') >= 0 ||
      lower.indexOf('auto refresh subscription') >= 0) {
      return 'subscription';
    }
    return 'ui';
  }

  private stripLegacyTimestamp(line: string): string {
    const matched = line.match(/^\d{1,2}:\d{2}:\d{2}[\u202F\s]*(AM|PM)[\u202F\s]*/i);
    if (matched && matched[0]) {
      return line.substring(matched[0].length);
    }
    const pmIndex = line.indexOf('PM ');
    if (pmIndex >= 0) {
      return line.substring(pmIndex + 3);
    }
    const amIndex = line.indexOf('AM ');
    if (amIndex >= 0) {
      return line.substring(amIndex + 3);
    }
    return line;
  }
}
