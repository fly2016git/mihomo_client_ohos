interface UrlParts {
  protocol: string;
  hostname: string;
  port: string;
  serialized: string;
}

class MockURL {
  protocol: string = '';
  hostname: string = '';
  port: string = '';
  private serialized: string = '';

  constructor(input: string = '', base?: string | MockURL) {
    if (input.length === 0) {
      return;
    }
    const baseText = typeof base === 'string' ? base : base?.toString();
    const parts = parseUrl(input, baseText ?? '');
    this.protocol = parts.protocol;
    this.hostname = parts.hostname;
    this.port = parts.port;
    this.serialized = parts.serialized;
  }

  toString(): string {
    return this.serialized;
  }
}

class MockUrlApi {
  parseURL(input: string, base?: string | MockURL): MockURL {
    return new MockURL(input, base);
  }
}

function parseUrl(input: string, base: string): UrlParts {
  let candidate = input;
  if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(candidate)) {
    if (base.length === 0) {
      throw new Error('relative URL requires a base URL');
    }
    const baseParts = parseAbsoluteUrl(base);
    const origin = baseParts.protocol + '//' + baseParts.hostname +
      (baseParts.port.length > 0 ? ':' + baseParts.port : '');
    if (candidate.startsWith('//')) {
      candidate = baseParts.protocol + candidate;
    } else if (candidate.startsWith('/')) {
      candidate = origin + candidate;
    } else {
      const suffixIndex = base.search(/[?#]/);
      const baseWithoutSuffix = suffixIndex >= 0 ? base.substring(0, suffixIndex) : base;
      const lastSlash = baseWithoutSuffix.lastIndexOf('/');
      candidate = baseWithoutSuffix.substring(0, lastSlash + 1) + candidate;
    }
  }
  return parseAbsoluteUrl(candidate);
}

function parseAbsoluteUrl(input: string): UrlParts {
  if (/\s|\\/.test(input)) {
    throw new Error('invalid URL');
  }
  const match = input.match(/^([a-z][a-z0-9+.-]*:)\/\/([^/?#]+)(.*)$/i);
  if (!match || match[2].includes('@')) {
    throw new Error('invalid URL');
  }
  const authority = match[2];
  let hostname = authority;
  let port = '';
  if (authority.startsWith('[')) {
    const bracket = authority.indexOf(']');
    if (bracket < 0) {
      throw new Error('invalid URL');
    }
    hostname = authority.substring(0, bracket + 1);
    if (authority.length > bracket + 1) {
      if (authority.charAt(bracket + 1) !== ':') {
        throw new Error('invalid URL');
      }
      port = authority.substring(bracket + 2);
    }
  } else {
    const colon = authority.lastIndexOf(':');
    if (colon >= 0) {
      hostname = authority.substring(0, colon);
      port = authority.substring(colon + 1);
    }
  }
  if (hostname.length === 0 || (port.length > 0 && !/^\d+$/.test(port))) {
    throw new Error('invalid URL');
  }
  return {
    protocol: match[1].toLowerCase(),
    hostname: hostname.toLowerCase(),
    port: port,
    serialized: match[1].toLowerCase() + '//' + authority + match[3]
  };
}

class MockUrlModule {
  URL: MockUrlApi = new MockUrlApi();
}

export default new MockUrlModule();
