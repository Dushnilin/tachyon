import { describe, expect, it, vi } from 'vitest';
import { canUseDirectClashApi, getClashUIUrl } from '../getClashApiUrl';

describe('canUseDirectClashApi', () => {
  it('allows direct Clash API access from HTTP LuCI', () => {
    vi.stubGlobal('window', {
      location: { hostname: 'router.example', protocol: 'http:' },
    });

    expect(canUseDirectClashApi()).toBe(true);
  });

  it('blocks direct Clash API access from HTTPS LuCI', () => {
    vi.stubGlobal('window', {
      location: { hostname: 'router.example', protocol: 'https:' },
    });

    expect(canUseDirectClashApi()).toBe(false);
  });

  it('blocks direct Clash API access outside a browser location', () => {
    vi.stubGlobal('window', undefined);

    expect(canUseDirectClashApi()).toBe(false);
  });
});

describe('getClashUIUrl (#385)', () => {
  it('returns plain /ui URL when no secret is configured', () => {
    vi.stubGlobal('window', {
      location: { hostname: '192.168.1.1', protocol: 'http:' },
    });
    vi.stubGlobal('uci', { get: () => '' });

    expect(getClashUIUrl()).toBe('http://192.168.1.1:9090/ui');
  });

  it('embeds hostname, port and secret query params when yacd_secret_key is set', () => {
    vi.stubGlobal('window', {
      location: { hostname: '192.168.1.1', protocol: 'http:' },
    });
    vi.stubGlobal('uci', {
      get: (_pkg, _sec, opt) =>
        opt === 'yacd_secret_key' ? 'my secret#1' : '',
    });

    expect(getClashUIUrl()).toBe(
      'http://192.168.1.1:9090/ui/?hostname=192.168.1.1&port=9090&secret=my%20secret%231',
    );
  });
});
