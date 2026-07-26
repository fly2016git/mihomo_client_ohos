import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import fs from '@ohos.file.fs';
import { ConfigService } from '../../../main/ets/config/ConfigService';
import { DEFAULT_APP_SETTINGS, makeSubscriptionMeta } from '../../../main/ets/models/MvpTypes';
import { SubscriptionUrlPolicy } from '../../../main/ets/subscription/SubscriptionUrlPolicy';

export default function abilityTest() {
  describe('ClashGuard device policy tests', () => {
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
