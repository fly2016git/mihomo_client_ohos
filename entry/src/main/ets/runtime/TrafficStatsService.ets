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

export class TrafficStatsService {
  private configService: ConfigService;
  private runtimeStore: RuntimeStore;
  private lastUploadTotal: number = -1;
  private lastDownloadTotal: number = -1;

  constructor(filesDir: string) {
    this.configService = new ConfigService(filesDir);
    this.runtimeStore = new RuntimeStore(filesDir);
  }

  async resetBaseline(): Promise<void> {
    const stats = this.readStatsFile();
    const now = Date.now();
    this.lastUploadTotal = stats.upTotal;
    this.lastDownloadTotal = stats.downTotal;
    const daily = this.loadDailyState(now);
    this.runtimeStore.update({
      uploadSpeed: 0,
      downloadSpeed: 0,
      todayUploadBytes: daily.uploadBytes,
      todayDownloadBytes: daily.downloadBytes,
      trafficSource: 'native-mihomo'
    });
  }

  async sampleAndUpdate(): Promise<void> {
    const stats = this.readStatsFile();
    const now = Date.now();
    if (this.lastUploadTotal < 0 || this.lastDownloadTotal < 0) {
      this.lastUploadTotal = stats.upTotal;
      this.lastDownloadTotal = stats.downTotal;
      return;
    }

    const uploadDelta = Math.max(stats.upTotal - this.lastUploadTotal, 0);
    const downloadDelta = Math.max(stats.downTotal - this.lastDownloadTotal, 0);
    const daily = this.addDailyTraffic(now, uploadDelta, downloadDelta);

    this.lastUploadTotal = stats.upTotal;
    this.lastDownloadTotal = stats.downTotal;
    this.runtimeStore.update({
      uploadSpeed: Math.max(Math.round(stats.up), 0),
      downloadSpeed: Math.max(Math.round(stats.down), 0),
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
}
