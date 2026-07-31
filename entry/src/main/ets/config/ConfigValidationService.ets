import { ConfigValidationResult } from '../models/MvpTypes';
import { ConfigService } from './ConfigService';

export class ConfigValidationService {
  private configService: ConfigService;

  constructor(filesDir: string) {
    this.configService = new ConfigService(filesDir);
  }

  async validate(content: string): Promise<ConfigValidationResult> {
    return this.configService.validateRawYaml(content);
  }
}
