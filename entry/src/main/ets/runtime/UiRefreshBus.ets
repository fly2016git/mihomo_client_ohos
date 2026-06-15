type RuntimeRefreshListener = (timestamp: number) => void;

export class UiRefreshBus {
  private static listeners: RuntimeRefreshListener[] = [];

  static add(listener: RuntimeRefreshListener): void {
    if (UiRefreshBus.listeners.indexOf(listener) >= 0) {
      return;
    }
    UiRefreshBus.listeners.push(listener);
  }

  static remove(listener: RuntimeRefreshListener): void {
    UiRefreshBus.listeners = UiRefreshBus.listeners.filter((item: RuntimeRefreshListener) => item !== listener);
  }

  static emit(): void {
    const timestamp = Date.now();
    const snapshot = UiRefreshBus.listeners.slice();
    for (const listener of snapshot) {
      listener(timestamp);
    }
  }
}
