import { describe, it, expect } from '@ohos/hypium';
import { DEFAULT_APP_SETTINGS, makeSubscriptionMeta, RuntimeEvent } from '../main/ets/models/MvpTypes';
import { SubscriptionUrlPolicy } from '../main/ets/subscription/SubscriptionUrlPolicy';
import { VpnConnectPolicy } from '../main/ets/runtime/VpnConnectPolicy';
import { ProxyRuntimePolicy } from '../main/ets/runtime/ProxyRuntimePolicy';
import { ConfigYamlValidator } from '../main/ets/config/ConfigYamlValidator';

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

    it('retries only when a VPN connect request is not acknowledged', 0, () => {
      const requestedAt = Date.now();
      const acknowledgedEvents: RuntimeEvent[] = [{
        timestamp: requestedAt,
        level: 'info',
        source: 'vpn',
        message: 'Starting VPN profile=测试配置'
      }];
      expect(VpnConnectPolicy.resolve('starting', 'loading', -1, 'profile-a', 'profile-a', [], requestedAt))
        .assertEqual('pending');
      expect(VpnConnectPolicy.resolve('starting', 'loading', -1, 'profile-a', 'profile-a', acknowledgedEvents,
        requestedAt)).assertEqual('acknowledged');
      expect(VpnConnectPolicy.resolve('connected', 'running', 32, 'profile-a', 'profile-a', [], requestedAt))
        .assertEqual('acknowledged');
      expect(VpnConnectPolicy.resolve('error', 'stopped', -1, 'profile-a', 'profile-a', [], requestedAt))
        .assertEqual('failed');
    });

    it('accepts supported Mihomo YAML without native validation', 0, () => {
      const content = 'proxies: []\nproxy-groups:\n  - name: Proxy\n    type: select\n' +
        '    proxies:\n      - DIRECT\nrules:\n  - MATCH,Proxy\n';
      expect(ConfigYamlValidator.validate(content).length).assertEqual(0);
    });

    it('rejects malformed YAML before configuration creation', 0, () => {
      const content = 'proxies:\n  - name: broken\n    port: [\n';
      expect(ConfigYamlValidator.validate(content)[0]).assertContain('配置格式无效');
    });

    it('rejects non-YAML subscription responses', 0, () => {
      expect(ConfigYamlValidator.validate('<html>access denied</html>')[0]).assertContain('配置格式无效');
    });

    it('rejects invalid Mihomo traffic block types', 0, () => {
      const content = 'proxies: invalid\nproxy-groups: []\nrules: []\n';
      expect(ConfigYamlValidator.validate(content)[0]).assertContain('proxies 必须是列表');
    });

    it('rejects duplicate YAML keys', 0, () => {
      const content = 'proxies: []\nproxies: []\nproxy-groups: []\nrules: []\n';
      expect(ConfigYamlValidator.validate(content)[0]).assertContain('配置格式无效');
    });
  });
}
