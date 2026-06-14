export interface PocStatus {
  ok: boolean;
  code: number;
  message: string;
}

declare const pocNative: {
  loadGoCore(): PocStatus;
  add(left: number, right: number): number;
  startWorker(intervalMs: number): PocStatus;
  stopWorker(): PocStatus;
  getLastEvent(): string;
  panicProbe(): PocStatus;
  registerProtect(callback: (fd: number) => number | boolean | Promise<number | boolean>): PocStatus;
  runTcpTest(host: string, port: number, useProtect: boolean): Promise<string>;
  runUdpTest(host: string, port: number, useProtect: boolean): Promise<string>;
  getPendingProtectFd(): number;
  loadMihomoCore(): Promise<PocStatus>;
  pingMihomo(): Promise<PocStatus>;
  getMihomoVersion(): Promise<PocStatus>;
  startMihomoConfig(homeDir: string, config: string): Promise<PocStatus>;
  startMihomoConfigFile(homeDir: string, configPath: string): Promise<PocStatus>;
  startMihomoConfigFileWithTunFd(homeDir: string, configPath: string, tunFd: number): Promise<PocStatus>;
  stopMihomo(): Promise<PocStatus>;
  startTunFdReadinessProbe(tunFd: number, durationMs: number): PocStatus;
  startTunFdPollProbe(tunFd: number, durationMs: number): PocStatus;
  testMihomoProxyDelay(node: string, url: string, timeoutMs: number): Promise<string>;
  testMihomoGroupDelay(group: string, url: string, timeoutMs: number): Promise<string>;
};

export default pocNative;
