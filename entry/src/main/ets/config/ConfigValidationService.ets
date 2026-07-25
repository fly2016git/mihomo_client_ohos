import { ConfigValidationResult } from '../models/MvpTypes';
import pocNative from '../native/PocNative';
import { ConfigService } from './ConfigService';

interface NativeConfigValidationResult {
  ok: boolean;
  error: string;
}

export class ConfigValidationService {
  private configService: ConfigService;

  constructor(filesDir: string) {
    this.configService = new ConfigService(filesDir);
  }

  async validate(content: string): Promise<ConfigValidationResult> {
    const local = this.configService.validateRawYaml(content);
    if (!local.ok) {
      return local;
    }

    try {
      const rawResult = await pocNative.validateMihomoConfig(content);
      const nativeResult = JSON.parse(rawResult) as NativeConfigValidationResult;
      if (nativeResult.ok) {
        return local;
      }
      return {
        ok: false,
        unsupportedKeys: local.unsupportedKeys,
        errors: this.appendUnique(local.errors, 'YAML 解析失败: ' + this.safeError(nativeResult.error)),
        warnings: local.warnings
      };
    } catch (err) {
      return {
        ok: false,
        unsupportedKeys: local.unsupportedKeys,
        errors: this.appendUnique(local.errors, '核心配置校验不可用: ' + this.toErrorText(err)),
        warnings: local.warnings
      };
    }
  }

  private appendUnique(items: string[], value: string): string[] {
    return items.indexOf(value) >= 0 ? items : items.concat([value]);
  }

  private safeError(value: string): string {
    return value && value.length > 0 ? value : '未知 YAML 错误';
  }

  private toErrorText(err: Object): string {
    if (err instanceof Error) {
      return err.message;
    }
    return JSON.stringify(err);
  }
}
