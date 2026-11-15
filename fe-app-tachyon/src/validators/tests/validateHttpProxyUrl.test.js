import { describe, it, expect } from 'vitest';
import { validateHttpProxyUrl } from '../validateHttpProxyUrl';

const validUrls = [
  ['http with port', 'http://example.com:8080'],
  ['https with port', 'https://example.com:8443'],
  ['http with auth', 'http://user:pass@example.com:8080'],
  ['http username only', 'http://user@example.com:8080'],
  ['http ip with port', 'http://127.0.0.1:8080'],
  ['http ipv6', 'http://[2001:db8::1]:8080'],
  ['https ipv6', 'https://user:pass@[2001:db8::1]:8443'],
];

const invalidUrls = [
  ['missing port', 'http://example.com'],
  ['missing host', 'http://:8080'],
  ['invalid port', 'http://example.com:99999'],
  ['path present', 'https://example.com:443/path'],
  ['query present', 'https://example.com:443?token=abc'],
  ['space present', 'http://exa mple.com:80'],
  ['empty username', 'http://:pass@example.com:80'],
  ['unsupported scheme', 'socks5://example.com:1080'],
  ['unbracketed ipv6 with port', 'http://2001:db8::1:8080'],
];

describe('validateHttpProxyUrl', () => {
  describe.each(validUrls)('valid URL: %s', (_desc, url) => {
    it('returns valid=true', () => {
      expect(validateHttpProxyUrl(url).valid).toBe(true);
    });
  });

  describe.each(invalidUrls)('invalid URL: %s', (_desc, url) => {
    it('returns valid=false', () => {
      expect(validateHttpProxyUrl(url).valid).toBe(false);
    });
  });
});
