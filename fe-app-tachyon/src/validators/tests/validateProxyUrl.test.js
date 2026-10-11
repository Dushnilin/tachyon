import { describe, it, expect } from 'vitest';
import { validateProxyUrl } from '../validateProxyUrl';

const validUrls = [
  ['shadowsocks', 'ss://YWVzLTI1Ni1nY206cGFzcw@example.com:8388'],
  [
    'vless',
    'vless://94792286-7bbe-4f33-8b36-18d1bbf70723@example.com:443?type=tcp&encryption=none&security=none',
  ],
  [
    'vmess',
    `vmess://${Buffer.from(
      JSON.stringify({
        v: '2',
        ps: 'Example VMess',
        add: 'example.com',
        port: '443',
        id: '94792286-7bbe-4f33-8b36-18d1bbf70723',
        aid: '0',
        scy: 'auto',
        net: 'ws',
        type: 'none',
        host: 'example.com',
        path: '/ws',
        tls: 'tls',
        sni: 'example.com',
      }),
    ).toString('base64')}`,
  ],
  ['trojan', 'trojan://password@example.com:443'],
  ['socks4', 'socks4://127.0.0.1:1080'],
  ['socks4a', 'socks4a://example.com:1080'],
  ['socks5', 'socks5://user:pass@example.com:1080'],
  ['http', 'http://127.0.0.1:80'],
  ['https', 'https://user:pass@example.com:443'],
  ['hysteria2', 'hysteria2://password@example.com:443'],
  ['hy2', 'hy2://password@example.com:443'],
];

describe('validateProxyUrl', () => {
  describe.each(validUrls)('Valid proxy URL: %s', (_desc, url) => {
    it(`returns valid=true for "${url}"`, () => {
      const res = validateProxyUrl(url);
      expect(res.valid).toBe(true);
    });
  });

  it('trims surrounding whitespace before dispatching', () => {
    const res = validateProxyUrl('  socks5://user:pass@example.com:1080  ');

    expect(res.valid).toBe(true);
  });

  it('returns a clear error for unsupported protocols', () => {
    const res = validateProxyUrl('wireguard://example.com');

    expect(res.valid).toBe(false);
    expect(res.message).toContain('vmess://');
    expect(res.message).toContain('socks4a://');
    expect(res.message).toContain('http://');
    expect(res.message).toContain('https://');
    expect(res.message).toContain('hy2://');
  });

  it('accepts native HTTP and HTTPS proxy URLs', () => {
    expect(validateProxyUrl('http://127.0.0.1:8080').valid).toBe(true);
    expect(validateProxyUrl('https://user:pass@example.com:443').valid).toBe(
      true,
    );
  });

  it('accepts valid FPTN token URLs', () => {
    const validB64 = Buffer.from('test_token_content').toString('base64');
    expect(validateProxyUrl(`fptn:${validB64}`).valid).toBe(true);
    expect(validateProxyUrl(`fptnb:${validB64}`).valid).toBe(true);
    expect(validateProxyUrl(`fptn://${validB64}`).valid).toBe(true);
    expect(validateProxyUrl(`fptnb://${validB64}`).valid).toBe(true);
    expect(validateProxyUrl(`fptn:${validB64}#MyServer`).valid).toBe(true);
  });

  it('rejects invalid FPTN token URLs', () => {
    expect(validateProxyUrl('fptn:').valid).toBe(false);
    expect(validateProxyUrl('fptn:!bad_b64!').valid).toBe(false);
  });
});
