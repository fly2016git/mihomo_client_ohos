import { CoreState, RuntimeEvent, RuntimeState } from '../models/MvpTypes';

export type VpnConnectRequestState = 'acknowledged' | 'pending' | 'failed';

export class VpnConnectPolicy {
  static resolve(runtimeState: RuntimeState, coreState: CoreState, tunFd: number, runtimeProfileId: string,
    expectedProfileId: string, events: RuntimeEvent[], requestedAt: number): VpnConnectRequestState {
    if (expectedProfileId.length === 0 || runtimeProfileId !== expectedProfileId) {
      return 'failed';
    }
    if (runtimeState === 'error' || coreState === 'error') {
      return 'failed';
    }
    if (runtimeState === 'connected' || coreState === 'running' || tunFd >= 0) {
      return 'acknowledged';
    }
    const receivedByVpn = events.some((event: RuntimeEvent) => {
      return event.timestamp >= requestedAt && event.source === 'vpn' &&
        event.message.startsWith('Starting VPN profile=');
    });
    if (receivedByVpn) {
      return 'acknowledged';
    }
    if (runtimeState === 'starting' && coreState === 'loading') {
      return 'pending';
    }
    return 'failed';
  }
}
