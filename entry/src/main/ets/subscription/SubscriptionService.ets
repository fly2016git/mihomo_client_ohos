import http from '@ohos.net.http';
import fs from '@ohos.file.fs';
import { util } from '@kit.ArkTS';
import { ConfigService } from '../config/ConfigService';
import { ConfigValidationService } from '../config/ConfigValidationService';
import { Profile, SubscriptionMeta, SubscriptionUpdateResult, makeSubscriptionMeta } from '../models/MvpTypes';
import { SettingsService } from '../settings/SettingsService';
import { SubscriptionUrlPolicy } from './SubscriptionUrlPolicy';

const MAX_REDIRECTS = 5;
const MAX_BYTES = 5 * 1024 * 1024; // 5 MiB
const TIMEOUT_MS = 15000;
const DEFAULT_USER_AGENT = 'ClashX Pro/1.118.0';

export interface SubscriptionCreateResult {
  profile: Profile | null;
  result: SubscriptionUpdateResult;
}

export class SubscriptionService {
  private configService: ConfigService;
  private configValidationService: ConfigValidationService;
  private settingsService: SettingsService;

  constructor(filesDir: string) {
    this.configService = new ConfigService(filesDir);
    this.configValidationService = new ConfigValidationService(filesDir);
    this.settingsService = new SettingsService(filesDir);
  }

  validateUrl(url: string): string | null {
    const result = SubscriptionUrlPolicy.validate(url);
    return result.ok ? null : result.error;
  }

  async addSubscription(name: string, url: string): Promise<Profile> {
    const check = SubscriptionUrlPolicy.validate(url);
    if (!check.ok) {
      throw new Error(check.error);
    }
    return this.configService.createSubscriptionProfile(name, check.normalizedUrl);
  }

  async addSubscriptionAndUpdate(name: string, url: string): Promise<SubscriptionCreateResult> {
    const profile = await this.addSubscription(name, url);
    const result = await this.update(profile.id);
    if (!result.ok) {
      this.configService.deleteProfile(profile.id);
      return {
        profile: null,
        result
      };
    }
    if (!this.configService.getActiveProfile()) {
      this.configService.setActiveProfile(profile.id);
    }
    return {
      profile: this.configService.getProfile(profile.id) ?? profile,
      result
    };
  }

  async update(profileId: string): Promise<SubscriptionUpdateResult> {
    const profile = this.configService.getProfile(profileId);
    if (!profile) {
      return this.makeResult(profileId, false, 'SUBSCRIPTION_PROFILE_NOT_FOUND: profile not found', 0, 0);
    }
    if (profile.type !== 'subscription' || !profile.subscription) {
      return this.makeResult(profileId, false, 'SUBSCRIPTION_NOT_SUBSCRIPTION: profile is not a subscription', 0, 0);
    }

    const url = profile.subscription.url;
    const urlCheck = SubscriptionUrlPolicy.validate(url);
    if (!urlCheck.ok) {
      this.recordFailure(profile, 0, urlCheck.error);
      return this.makeResult(profileId, false, urlCheck.error, 0, 0);
    }
    const userAgent = profile.subscription.userAgent && profile.subscription.userAgent.length > 0 ?
      profile.subscription.userAgent : DEFAULT_USER_AGENT;
    const layout = this.configService.ensureLayout();
    const cacheDir = layout.cacheDir + '/subscriptions';
    this.ensureDir(cacheDir);

    const tmpPath = cacheDir + '/' + profileId + '.download.tmp';

    // --- HTTP Download ---
    let statusCode = 0;
    let bodyBytes = 0;
    let responseBody = '';
    let finalResponseResult: string | ArrayBuffer | Object | null = null;

    const httpRequest = http.createHttp();
    try {
      let currentUrl = urlCheck.normalizedUrl;
      let redirects = 0;
      let lastResponseResult: string | ArrayBuffer | Object = '';

      while (redirects <= MAX_REDIRECTS) {
        const httpResponse = await httpRequest.request(currentUrl, {
          method: http.RequestMethod.GET,
          header: {
            'User-Agent': userAgent,
            'Accept': 'text/plain, application/yaml, application/x-yaml, */*'
          },
          connectTimeout: TIMEOUT_MS,
          readTimeout: TIMEOUT_MS,
          maxLimit: MAX_BYTES
        });

        statusCode = httpResponse.responseCode;
        lastResponseResult = httpResponse.result as string | ArrayBuffer | Object;
        const location = this.getHeaderValue(httpResponse.header, 'Location') ||
          this.getHeaderValue(httpResponse.header, 'location');

        if ((statusCode === 301 || statusCode === 302 || statusCode === 307 || statusCode === 308) && location) {
          const redirect = SubscriptionUrlPolicy.validateRedirect(location, currentUrl);
          if (!redirect.ok) {
            this.recordFailure(profile, statusCode, redirect.error);
            return this.makeResult(profileId, false, redirect.error, statusCode, 0);
          }
          currentUrl = redirect.normalizedUrl;
          redirects++;
          continue;
        }
        break;
      }

      finalResponseResult = lastResponseResult;

      if (redirects > MAX_REDIRECTS) {
        this.recordFailure(profile, 0, 'SUBSCRIPTION_REDIRECT_LOOP');
        return this.makeResult(profileId, false, 'SUBSCRIPTION_REDIRECT_LOOP: too many redirects', statusCode, 0);
      }

      if (statusCode === 304) {
        const now = Date.now();
        profile.subscription.lastFetchedAt = now;
        profile.subscription.lastStatusCode = 304;
        profile.subscription.failureCount = 0;
        profile.subscription.lastError = '';
        this.configService.updateProfile(profile);
        return this.makeResult(profileId, true, 'not modified', 304, 0);
      }

      if (statusCode !== 200) {
        const errMsg = 'SUBSCRIPTION_HTTP_ERROR: HTTP ' + statusCode;
        this.recordFailure(profile, statusCode, errMsg);
        return this.makeResult(profileId, false, errMsg, statusCode, 0);
      }

      // Read response body
      if (typeof finalResponseResult === 'string') {
        responseBody = finalResponseResult as string;
        bodyBytes = responseBody.length;
      } else if (finalResponseResult instanceof ArrayBuffer) {
        const textDecoder = util.TextDecoder.create('utf-8');
        const arr = new Uint8Array(finalResponseResult as ArrayBuffer);
        responseBody = textDecoder.decodeToString(arr);
        bodyBytes = (finalResponseResult as ArrayBuffer).byteLength;
      } else {
        responseBody = JSON.stringify(finalResponseResult);
        bodyBytes = responseBody.length;
      }

      if (bodyBytes === 0) {
        const errMsg = 'SUBSCRIPTION_EMPTY_BODY: response body is empty';
        this.recordFailure(profile, statusCode, errMsg);
        return this.makeResult(profileId, false, errMsg, statusCode, 0);
      }

      if (bodyBytes > MAX_BYTES) {
        const errMsg = 'SUBSCRIPTION_TOO_LARGE: ' + bodyBytes + ' bytes exceeds ' + MAX_BYTES;
        this.recordFailure(profile, statusCode, errMsg);
        return this.makeResult(profileId, false, errMsg, statusCode, bodyBytes);
      }

    } catch (err) {
      const errMsg = 'SUBSCRIPTION_DOWNLOAD_FAILED: ' + this.redactSensitiveText(this.toErrorText(err));
      this.recordFailure(profile, 0, errMsg);
      return this.makeResult(profileId, false, errMsg, 0, 0);
    } finally {
      try {
        httpRequest.destroy();
      } catch (_) {
        // The completed request result remains valid even if native resource cleanup reports an error.
      }
    }

    // --- Validate and Atomically Replace ---
    let runtimeTmp = '';
    try {
      // Write temp file
      this.writeTextFile(tmpPath, responseBody);

      // Validate YAML
      const validation = await this.configValidationService.validate(responseBody);
      if (!validation.ok) {
        this.deleteIfExists(tmpPath);
        const errMsg = 'SUBSCRIPTION_CONFIG_INVALID: ' + validation.errors.join('; ');
        this.recordFailure(profile, statusCode, errMsg);
        return this.makeResult(profileId, false, errMsg, statusCode, bodyBytes);
      }

      // Generate runtime YAML
      const runtimeYaml = this.configService.generateRuntimeYaml(responseBody, this.settingsService.load());
      runtimeTmp = profile.runtimePath + '.tmp';

      // Write runtime tmp
      this.writeTextFile(runtimeTmp, runtimeYaml);

      // Atomic replace: raw YAML
      fs.renameSync(tmpPath, profile.rawPath);

      // Atomic replace: runtime YAML
      fs.renameSync(runtimeTmp, profile.runtimePath);

      // Update profile metadata
      const now = Date.now();
      profile.subscription.lastFetchedAt = now;
      profile.subscription.lastSuccessAt = now;
      profile.subscription.lastStatusCode = statusCode;
      profile.subscription.lastBytes = bodyBytes;
      profile.subscription.failureCount = 0;
      profile.subscription.lastError = '';
      profile.updatedAt = now;
      profile.lastValidatedAt = now;
      profile.lastError = '';

      this.configService.updateProfile(profile);

      return {
        ok: true,
        profileId: profileId,
        statusCode: statusCode,
        bytes: bodyBytes,
        fromCache: false,
        rawPath: profile.rawPath,
        runtimePath: profile.runtimePath,
        error: '',
        updatedAt: now
      };
    } catch (err) {
      this.deleteIfExists(tmpPath);
      if (runtimeTmp.length > 0) {
        this.deleteIfExists(runtimeTmp);
      }
      const errMsg = 'SUBSCRIPTION_WRITE_FAILED: ' + this.redactSensitiveText(this.toErrorText(err));
      this.recordFailure(profile, statusCode, errMsg);
      return this.makeResult(profileId, false, errMsg, statusCode, bodyBytes);
    }
  }

  private recordFailure(profile: Profile, statusCode: number, error: string): void {
    profile.subscription!.lastFetchedAt = Date.now();
    profile.subscription!.lastStatusCode = statusCode;
    profile.subscription!.failureCount += 1;
    profile.subscription!.lastError = error;
    try {
      this.configService.updateProfile(profile);
    } catch (_err) {
      // ignore save failure during error recording
    }
  }

  private makeResult(profileId: string, ok: boolean, error: string, statusCode: number, bytes: number):
    SubscriptionUpdateResult {
    return {
      ok: ok,
      profileId: profileId,
      statusCode: statusCode,
      bytes: bytes,
      fromCache: false,
      rawPath: '',
      runtimePath: '',
      error: error,
      updatedAt: Date.now()
    };
  }

  private getHeaderValue(headers: Object, name: string): string | null {
    if (!headers || typeof headers !== 'object') {
      return null;
    }
    const rec = headers as Record<string, string>;
    if (typeof rec[name] === 'string') {
      return rec[name];
    }
    const keys = Object.keys(rec);
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      if (key.toLowerCase() === name.toLowerCase()) {
        return rec[key];
      }
    }
    return null;
  }

  private ensureDir(path: string): void {
    try {
      if (fs.accessSync(path)) {
        return;
      }
    } catch (_err) {
      // path does not exist
    }
    fs.mkdirSync(path, true);
  }

  private writeTextFile(path: string, content: string): void {
    const file = fs.openSync(path, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, content);
    } finally {
      fs.closeSync(file);
    }
  }

  private deleteIfExists(path: string): void {
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (_err) {
      // ignore
    }
  }

  private toErrorText(err: Object): string {
    if (err instanceof Error) {
      return err.name + ': ' + err.message;
    }
    return JSON.stringify(err);
  }

  private redactSensitiveText(text: string): string {
    return text.replace(/https?:\/\/[^\s'\"<>]+/gi, '<redacted-url>');
  }
}
