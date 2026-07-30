import { describe, it, expect } from '@ohos/hypium';
import { DEFAULT_APP_SETTINGS, makeSubscriptionMeta } from '../main/ets/models/MvpTypes';
import { SubscriptionUrlPolicy } from '../main/ets/subscription/SubscriptionUrlPolicy';
import { ProxyRuntimePolicy } from '../main/ets/runtime/ProxyRuntimePolicy';

export default function localUnitTest() {
  describe('FluxGate model and policy tests', () => {
    it('uses production-safe default settings', 0, () => {
      expect(DEFAULT_APP_SETTINGS.routeMode).assertEqual('blocking-default');
      expect(DEFAULT_APP_SETTINGS.proxyMode).assertEqual('rule');
      expect(DEFAULT_APP_SETTINGS.ipv6Enabled).assertFalse();
      expect(DEFAULT_APP_SETTINGS.autoRefreshSubscriptionOnConnect).assertFalse();
    });

    it('creates empty subscription metadata', 0, () => {
      const meta = makeSubscriptionMeta('https://example.com/subscription');
      expect(meta.url).assertEqual('https://example.com/subscription');
      expect(meta.failureCount).assertEqual(0);
      expect(meta.lastError).assertEqual('');
    });

    it('accepts https subscription URLs', 0, () => {
      const result = SubscriptionUrlPolicy.validate('https://example.com/config.yaml?token=secret');
      expect(result.ok).assertTrue();
      expect(result.normalizedUrl.startsWith('https://')).assertTrue();
    });

    it('rejects public cleartext subscription URLs', 0, () => {
      const result = SubscriptionUrlPolicy.validate('http://example.com/config.yaml');
      expect(result.ok).assertFalse();
      expect(result.error).assertContain('HTTPS');
    });

    it('allows loopback http for local diagnostics', 0, () => {
      const result = SubscriptionUrlPolicy.validate('http://127.0.0.1:8080/config.yaml');
      expect(result.ok).assertTrue();
    });

    it('resolves safe relative redirects and blocks downgrade', 0, () => {
      const relative = SubscriptionUrlPolicy.validateRedirect('/next.yaml', 'https://example.com/config.yaml');
      const downgrade = SubscriptionUrlPolicy.validateRedirect('http://127.0.0.1/next.yaml',
        'https://example.com/config.yaml');
      expect(relative.ok).assertTrue();
      expect(relative.normalizedUrl.startsWith('https://example.com/')).assertTrue();
      expect(downgrade.ok).assertFalse();
    });

    it('opens proxy controls only for the connected active profile', 0, () => {
      expect(ProxyRuntimePolicy.isReady('connected', 'running', 'profile-a', 'profile-a')).assertTrue();
      expect(ProxyRuntimePolicy.isReady('idle', 'stopped', 'profile-a', 'profile-a')).assertFalse();
      expect(ProxyRuntimePolicy.isReady('connected', 'running', 'profile-a', 'profile-b')).assertFalse();
      expect(ProxyRuntimePolicy.resolve('starting', 'loading', 'profile-a', 'profile-a'))
        .assertEqual('transitioning');
      expect(ProxyRuntimePolicy.resolve('error', 'error', 'profile-a', 'profile-a')).assertEqual('error');
    });
  });
}
