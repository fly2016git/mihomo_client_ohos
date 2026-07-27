import fs from '@ohos.file.fs';
import { ConfigService } from '../config/ConfigService';

export const CURRENT_AGREEMENT_VERSION = '2026-07-27';

interface AgreementState {
  version: string;
  acceptedAt: number;
}

export class AgreementService {
  private configService: ConfigService;

  constructor(filesDir: string) {
    this.configService = new ConfigService(filesDir);
  }

  hasAcceptedCurrent(): boolean {
    const path = this.agreementPath();
    if (!this.configService.pathExists(path)) {
      return false;
    }
    try {
      const state = JSON.parse(fs.readTextSync(path)) as Partial<AgreementState>;
      return state.version === CURRENT_AGREEMENT_VERSION && typeof state.acceptedAt === 'number' &&
        state.acceptedAt > 0;
    } catch (_) {
      return false;
    }
  }

  acceptCurrent(): void {
    const state: AgreementState = {
      version: CURRENT_AGREEMENT_VERSION,
      acceptedAt: Date.now()
    };
    this.configService.writeTextFileAtomic(this.agreementPath(), JSON.stringify(state));
  }

  private agreementPath(): string {
    return this.configService.ensureLayout().stateDir + '/agreement.json';
  }
}
