import fs from '@ohos.file.fs';
import { ConfigService } from '../config/ConfigService';
import { RuntimeSnapshot } from '../models/MvpTypes';

const MAX_EVENTS = 60;

interface RuntimeStateFile {
  snapshot: RuntimeSnapshot;
  events: string[];
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
    state.snapshot.updatedAt = Date.now();
    this.saveStateFile(state);
  }

  appendEvent(message: string): void {
    const state = this.loadStateFile();
    const line = this.formatEvent(message);
    state.events = [line].concat(state.events).slice(0, MAX_EVENTS);
    state.snapshot.lastEvent = message;
    state.snapshot.updatedAt = Date.now();
    this.saveStateFile(state);
  }

  getEvents(): string[] {
    return this.loadStateFile().events;
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
      downloadSpeed: 0
    });
    this.appendEvent(message);
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
      if (!parsed.snapshot || !parsed.events) {
        throw new Error('invalid runtime state');
      }
      return parsed;
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
        downloadSpeed: 0
      },
      events: [this.formatEvent('Ready')]
    };
  }

  private formatEvent(message: string): string {
    return new Date().toLocaleTimeString() + ' ' + message;
  }
}
