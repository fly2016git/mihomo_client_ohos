import url from '@ohos.url';

export interface SubscriptionUrlCheck {
  ok: boolean;
  normalizedUrl: string;
  error: string;
}

export class SubscriptionUrlPolicy {
  static validate(input: string, baseUrl: string = ''): SubscriptionUrlCheck {
    const value = input.trim();
    if (value.length === 0) {
      return SubscriptionUrlPolicy.failure('SUBSCRIPTION_INVALID_URL: URL 不能为空');
    }

    try {
      const parsed = baseUrl.length > 0 ? url.URL.parseURL(value, baseUrl) : url.URL.parseURL(value);
      const protocol = parsed.protocol.toLowerCase();
      const hostname = parsed.hostname.toLowerCase();
      if (protocol === 'https:') {
        return { ok: true, normalizedUrl: parsed.toString(), error: '' };
      }
      if (protocol === 'http:' && SubscriptionUrlPolicy.isLoopbackHost(hostname)) {
        return { ok: true, normalizedUrl: parsed.toString(), error: '' };
      }
      if (protocol === 'http:') {
        return SubscriptionUrlPolicy.failure('SUBSCRIPTION_INSECURE_URL: 订阅地址必须使用 HTTPS');
      }
      return SubscriptionUrlPolicy.failure('SUBSCRIPTION_UNSUPPORTED_SCHEME: 仅支持 HTTPS');
    } catch (_) {
      return SubscriptionUrlPolicy.failure('SUBSCRIPTION_INVALID_URL: URL 格式无效');
    }
  }

  static validateRedirect(location: string, currentUrl: string): SubscriptionUrlCheck {
    const next = SubscriptionUrlPolicy.validate(location, currentUrl);
    if (!next.ok) {
      return next;
    }
    const current = SubscriptionUrlPolicy.validate(currentUrl);
    if (current.ok && current.normalizedUrl.toLowerCase().startsWith('https://') &&
      next.normalizedUrl.toLowerCase().startsWith('http://')) {
      return SubscriptionUrlPolicy.failure('SUBSCRIPTION_INSECURE_REDIRECT: 禁止从 HTTPS 降级到 HTTP');
    }
    return next;
  }

  private static isLoopbackHost(hostname: string): boolean {
    return hostname === 'localhost' || hostname === '127.0.0.1' || hostname === '[::1]' || hostname === '::1';
  }

  private static failure(error: string): SubscriptionUrlCheck {
    return { ok: false, normalizedUrl: '', error };
  }
}
