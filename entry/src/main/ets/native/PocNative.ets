import pocNative, { PocStatus } from 'libpoc_napi.so';

export { PocStatus };

interface PocNativeApi {
  // POC-02
  loadGoCore(): PocStatus;
  add(left: number, right: number): number;
  startWorker(intervalMs: number): PocStatus;
  stopWorker(): PocStatus;
  getLastEvent(): string;
  panicProbe(): PocStatus;

  // POC-03
  registerProtect(callback: (fd: number) => number | boolean | Promise<number | boolean>): PocStatus;
  runTcpTest(host: string, port: number, useProtect: boolean): Promise<string>;
  runUdpTest(host: string, port: number, useProtect: boolean): Promise<string>;
  getPendingProtectFd(): number;

  // POC-04
  loadMihomoCore(): Promise<PocStatus>;
  pingMihomo(): Promise<PocStatus>;
  getMihomoVersion(): Promise<PocStatus>;
  startMihomoConfig(homeDir: string, config: string): Promise<PocStatus>;
  startMihomoConfigFile(homeDir: string, configPath: string): Promise<PocStatus>;
  startMihomoConfigFileWithTunFd(homeDir: string, configPath: string, tunFd: number): Promise<PocStatus>;
  stopMihomo(): Promise<PocStatus>;
  startTunFdReadinessProbe(tunFd: number, durationMs: number): PocStatus;
  startTunFdPollProbe(tunFd: number, durationMs: number): PocStatus;
  holdTunFdReference(tunFd: number): PocStatus;
  releaseTunFdReference(): PocStatus;

  // MVP-01B: protect hook control + graceful stop
  enableProtectHook(): PocStatus;
  disableProtectHook(): Promise<PocStatus>;
  isMihomoRunning(): PocStatus;
  gracefulStopMihomo(): Promise<PocStatus>;

  // M2-3 placeholder: native bridge is not implemented yet.
  selectProxy(group: string, node: string): Promise<PocStatus>;
  testMihomoProxyDelay(node: string, url: string, timeoutMs: number): Promise<string>;
  testMihomoGroupDelay(group: string, url: string, timeoutMs: number): Promise<string>;
  getMihomoTrafficStats(): Promise<string>;
  startMihomoTrafficStatsWriter(statsPath: string): Promise<PocStatus>;
  stopMihomoTrafficStatsWriter(): Promise<PocStatus>;
}

export default pocNative as PocNativeApi;
