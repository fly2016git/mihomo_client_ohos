import { CoreState, RuntimeState } from '../models/MvpTypes';

export type ProxyRuntimeAccessState = 'ready' | 'transitioning' | 'disconnected' | 'error';

export class ProxyRuntimePolicy {
  static resolve(runtimeState: RuntimeState, coreState: CoreState, runtimeProfileId: string,
    activeProfileId: string): ProxyRuntimeAccessState {
    if (runtimeState === 'starting' || runtimeState === 'stopping' || coreState === 'loading' ||
      coreState === 'stopping') {
      return 'transitioning';
    }
    if (runtimeState === 'connected' && coreState === 'running' && activeProfileId.length > 0 &&
      runtimeProfileId === activeProfileId) {
      return 'ready';
    }
    if (runtimeState === 'error' || runtimeState === 'unknown' || coreState === 'error' ||
      coreState === 'unknown' || runtimeState === 'connected') {
      return 'error';
    }
    return 'disconnected';
  }

  static isReady(runtimeState: RuntimeState, coreState: CoreState, runtimeProfileId: string,
    activeProfileId: string): boolean {
    return ProxyRuntimePolicy.resolve(runtimeState, coreState, runtimeProfileId, activeProfileId) === 'ready';
  }
}
