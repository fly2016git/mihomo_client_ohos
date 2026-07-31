import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import fs from '@ohos.file.fs';
import { ConfigService } from '../../../main/ets/config/ConfigService';
import { DEFAULT_APP_SETTINGS, makeSubscriptionMeta, RuntimeEvent } from '../../../main/ets/models/MvpTypes';
import { SubscriptionUrlPolicy } from '../../../main/ets/subscription/SubscriptionUrlPolicy';
import { VpnConnectPolicy } from '../../../main/ets/runtime/VpnConnectPolicy';
import { ProxyRuntimePolicy } from '../../../main/ets/runtime/ProxyRuntimePolicy';

export default function abilityTest() {
  describe('FluxGate device policy tests', () => {
    it('uses the recommended defaults', 0, () => {
      expect(DEFAULT_APP_SETTINGS.routeMode).assertEqual('blocking-default');
      expect(DEFAULT_APP_SETTINGS.proxyMode).assertEqual('rule');
    });

    it('initializes subscription state without stale errors', 0, () => {
      const meta = makeSubscriptionMeta('https://example.com/config.yaml');
      expect(meta.failureCount).assertEqual(0);
      expect(meta.lastStatusCode).assertEqual(0);
      expect(meta.lastError).assertEqual('');
    });

    it('enforces secure subscription transport', 0, () => {
      expect(SubscriptionUrlPolicy.validate('https://example.com/config.yaml').ok).assertTrue();
      expect(SubscriptionUrlPolicy.validate('http://example.com/config.yaml').ok).assertFalse();
    });

    it('gates proxy controls by runtime state and active profile', 0, () => {
      expect(ProxyRuntimePolicy.isReady('connected', 'running', 'profile-a', 'profile-a')).assertTrue();
      expect(ProxyRuntimePolicy.isReady('idle', 'stopped', 'profile-a', 'profile-a')).assertFalse();
      expect(ProxyRuntimePolicy.isReady('connected', 'running', 'profile-a', 'profile-b')).assertFalse();
    });

    it('detects first authorization requests that need one retry', 0, () => {
      const requestedAt = Date.now();
      const events: RuntimeEvent[] = [{
        timestamp: requestedAt,
        level: 'info',
        source: 'vpn',
        message: 'Starting VPN profile=测试配置'
      }];
      expect(VpnConnectPolicy.resolve('starting', 'loading', -1, 'profile-a', 'profile-a', [], requestedAt))
        .assertEqual('pending');
      expect(VpnConnectPolicy.resolve('starting', 'loading', -1, 'profile-a', 'profile-a', events, requestedAt))
        .assertEqual('acknowledged');
    });

    it('generates an authenticated loopback controller for safe latency tests', 0, () => {
      const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
      const root = context.filesDir + '/controller-config-test-' + Date.now().toString();
      const service = new ConfigService(root);
      const runtime = service.generateRuntimeYaml(
        'mode: direct\nproxies: []\nproxy-groups: []\nrules:\n  - MATCH,DIRECT\n');
      expect(runtime).assertContain('external-controller: 127.0.0.1:19090');
      expect(runtime).assertContain('secret: ');
      expect(runtime.indexOf('FLUXGATE_CONTROLLER_SECRET')).assertEqual(-1);
      expect(service.getMihomoControllerSecret().length >= 64).assertTrue();
    });

    it('restores a damaged profile index from backup', 0, () => {
      const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
      const root = context.filesDir + '/profile-recovery-test-' + Date.now().toString();
      const service = new ConfigService(root);
      const profile = service.createLocalProfile('恢复测试',
        'mode: rule\nproxies: []\nproxy-groups: []\nrules:\n  - MATCH,DIRECT\n');
      const layout = service.ensureLayout();
      service.writeTextFile(layout.profilesPath, '{invalid json');

      const recovered = service.loadProfilesState();
      const stateFiles = fs.listFileSync(layout.stateDir);
      expect(recovered.activeProfileId).assertEqual(profile.id);
      expect(recovered.profiles.length).assertEqual(1);
      expect(stateFiles.some((name: string) => name.startsWith('profiles.json.corrupt-'))).assertTrue();
    });
  });
}
