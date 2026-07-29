import fs from '@ohos.file.fs';
import { ConfigService } from '../config/ConfigService';
import { RuntimeStore } from './RuntimeStore';

interface FileTrafficStats {
  ok: boolean;
  source: string;
  up: number;
  down: number;
  upTotal: number;
  downTotal: number;
  running: boolean;
  updatedAt: number;
  error: string;
}

interface DailyTrafficState {
  date: string;
  uploadBytes: number;
  downloadBytes: number;
  source: string;
  updatedAt: number;
}

export interface LiveTrafficSnapshot {
  uploadSpeed: number;
  downloadSpeed: number;
  source: string;
  updatedAt: number;
}

export class TrafficStatsService {
  private configService: ConfigService;
  private runtimeStore: RuntimeStore;
  private lastUploadTotal: number = -1;
  private lastDownloadTotal: number = -1;
  private lastSampleUpdatedAt: number = 0;
  private lastLiveUploadTotal: number = -1;
  private lastLiveDownloadTotal: number = -1;
  private lastLiveUpdatedAt: number = 0;

  constructor(filesDir: string) {
    this.configService = new ConfigService(filesDir);
    this.runtimeStore = new RuntimeStore(filesDir);
  }

  async resetBaseline(): Promise<void> {
    const stats = this.readStatsFile();
    const now = Date.now();
    this.lastUploadTotal = stats.upTotal;
    this.lastDownloadTotal = stats.downTotal;
    this.lastSampleUpdatedAt = stats.updatedAt;
    const daily = this.loadDailyState(now);
    this.runtimeStore.update({
      uploadSpeed: 0,
      downloadSpeed: 0,
      todayUploadBytes: daily.uploadBytes,
      todayDownloadBytes: daily.downloadBytes,
      trafficSource: 'native-mihomo'
    });
  }

  readLiveSnapshot(): LiveTrafficSnapshot {
    const stats = this.readStatsFile();
    let uploadSpeed = Math.max(Math.round(stats.up), 0);
    let downloadSpeed = Math.max(Math.round(stats.down), 0);
    if (this.lastLiveUploadTotal >= 0 && this.lastLiveDownloadTotal >= 0 && this.lastLiveUpdatedAt > 0) {
      const elapsedMs = stats.updatedAt - this.lastLiveUpdatedAt;
      const uploadDelta = Math.max(stats.upTotal - this.lastLiveUploadTotal, 0);
      const downloadDelta = Math.max(stats.downTotal - this.lastLiveDownloadTotal, 0);
      uploadSpeed = Math.max(uploadSpeed, this.bytesPerSecond(uploadDelta, elapsedMs));
      downloadSpeed = Math.max(downloadSpeed, this.bytesPerSecond(downloadDelta, elapsedMs));
    }
    this.lastLiveUploadTotal = stats.upTotal;
    this.lastLiveDownloadTotal = stats.downTotal;
    this.lastLiveUpdatedAt = stats.updatedAt;
    return {
      uploadSpeed,
      downloadSpeed,
      source: stats.source,
      updatedAt: stats.updatedAt
    };
  }

  refreshDailySnapshot(): void {
    const now = Date.now();
    const daily = this.loadDailyState(now);
    this.saveDailyState(daily);
    this.runtimeStore.update({
      uploadSpeed: 0,
      downloadSpeed: 0,
      todayUploadBytes: daily.uploadBytes,
      todayDownloadBytes: daily.downloadBytes,
      trafficSource: daily.uploadBytes > 0 || daily.downloadBytes > 0 ? 'native-mihomo' : 'none'
    });
  }

  async sampleAndUpdate(): Promise<void> {
    const stats = this.readStatsFile();
    const now = Date.now();
    if (this.lastUploadTotal < 0 || this.lastDownloadTotal < 0) {
      this.lastUploadTotal = stats.upTotal;
      this.lastDownloadTotal = stats.downTotal;
      this.lastSampleUpdatedAt = stats.updatedAt;
      return;
    }

    const uploadDelta = Math.max(stats.upTotal - this.lastUploadTotal, 0);
    const downloadDelta = Math.max(stats.downTotal - this.lastDownloadTotal, 0);
    const elapsedMs = stats.updatedAt - this.lastSampleUpdatedAt;
    const daily = this.addDailyTraffic(now, uploadDelta, downloadDelta);

    this.lastUploadTotal = stats.upTotal;
    this.lastDownloadTotal = stats.downTotal;
    this.lastSampleUpdatedAt = stats.updatedAt;
    this.runtimeStore.update({
      uploadSpeed: Math.max(Math.round(stats.up), this.bytesPerSecond(uploadDelta, elapsedMs)),
      downloadSpeed: Math.max(Math.round(stats.down), this.bytesPerSecond(downloadDelta, elapsedMs)),
      todayUploadBytes: daily.uploadBytes,
      todayDownloadBytes: daily.downloadBytes,
      trafficSource: 'native-mihomo'
    });
  }

  stopAndKeepDaily(): void {
    const daily = this.loadDailyState(Date.now());
    this.runtimeStore.update({
      uploadSpeed: 0,
      downloadSpeed: 0,
      todayUploadBytes: daily.uploadBytes,
      todayDownloadBytes: daily.downloadBytes,
      trafficSource: daily.source === 'native-mihomo' ? 'native-mihomo' : 'none'
    });
  }

  private readStatsFile(): FileTrafficStats {
    const layout = this.configService.ensureLayout();
    if (!this.configService.pathExists(layout.trafficStatsPath)) {
      throw new Error('TRAFFIC_STATS_UNAVAILABLE: stats file missing');
    }
    const parsed = JSON.parse(fs.readTextSync(layout.trafficStatsPath)) as FileTrafficStats;
    const error = parsed.error ? parsed.error : '';
    if (!parsed.ok) {
      throw new Error('TRAFFIC_STATS_UNAVAILABLE: ' + error);
    }
    const updatedAt = this.safeNumber(parsed.updatedAt);
    if (updatedAt > 0 && Date.now() - updatedAt > 10000) {
      throw new Error('TRAFFIC_STATS_UNAVAILABLE: stats file stale');
    }
    return {
      ok: true,
      source: 'native-mihomo',
      up: this.safeNumber(parsed.up),
      down: this.safeNumber(parsed.down),
      upTotal: this.safeNumber(parsed.upTotal),
      downTotal: this.safeNumber(parsed.downTotal),
      running: parsed.running === true,
      updatedAt,
      error
    };
  }

  private addDailyTraffic(timestamp: number, uploadDelta: number, downloadDelta: number): DailyTrafficState {
    const daily = this.loadDailyState(timestamp);
    daily.uploadBytes += uploadDelta;
    daily.downloadBytes += downloadDelta;
    daily.source = 'native-mihomo';
    daily.updatedAt = timestamp;
    this.saveDailyState(daily);
    return daily;
  }

  private loadDailyState(timestamp: number): DailyTrafficState {
    const today = this.localDateText(timestamp);
    const layout = this.configService.ensureLayout();
    if (!this.configService.pathExists(layout.trafficDailyPath)) {
      return this.createDailyState(today, timestamp);
    }
    try {
      const parsed = JSON.parse(fs.readTextSync(layout.trafficDailyPath)) as DailyTrafficState;
      if (parsed.date !== today) {
        return this.createDailyState(today, timestamp);
      }
      return {
        date: today,
        uploadBytes: typeof parsed.uploadBytes === 'number' ? parsed.uploadBytes : 0,
        downloadBytes: typeof parsed.downloadBytes === 'number' ? parsed.downloadBytes : 0,
        source: parsed.source ? parsed.source : 'native-mihomo',
        updatedAt: typeof parsed.updatedAt === 'number' ? parsed.updatedAt : timestamp
      };
    } catch (_) {
      return this.createDailyState(today, timestamp);
    }
  }

  private saveDailyState(state: DailyTrafficState): void {
    const layout = this.configService.ensureLayout();
    this.configService.writeTextFileAtomic(layout.trafficDailyPath, JSON.stringify(state));
  }

  private createDailyState(date: string, timestamp: number): DailyTrafficState {
    return {
      date,
      uploadBytes: 0,
      downloadBytes: 0,
      source: 'native-mihomo',
      updatedAt: timestamp
    };
  }

  private localDateText(timestamp: number): string {
    const date = new Date(timestamp);
    return date.getFullYear().toString() + '-' + this.pad2(date.getMonth() + 1) + '-' + this.pad2(date.getDate());
  }

  private pad2(value: number): string {
    return value < 10 ? '0' + value.toString() : value.toString();
  }

  private safeNumber(input: number): number {
    const value = Number(input);
    return Number.isFinite(value) ? value : 0;
  }

  private bytesPerSecond(deltaBytes: number, elapsedMs: number): number {
    if (deltaBytes <= 0 || elapsedMs <= 0) {
      return 0;
    }
    return Math.max(Math.round(deltaBytes * 1000 / elapsedMs), 0);
  }
}
