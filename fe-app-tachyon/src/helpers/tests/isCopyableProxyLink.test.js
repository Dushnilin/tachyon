import { describe, expect, it } from 'vitest';
import { isCopyableProxyLink } from '../isCopyableProxyLink';

const copyableLinks = [
  'vless://uuid@example.com:443',
  'vmess://encoded',
  'trojan://password@example.com:443',
  'ss://encoded@example.com:443',
  'ssr://encoded',
  'hysteria2://password@example.com:443',
  'hy2://password@example.com:443',
  'tuic://uuid:password@example.com:443',
  'socks4://example.com:1080',
  'socks4a://example.com:1080',
  'socks5://user:pass@example.com:1080',
  'http://example.com:80',
  'https://user:pass@example.com:443',
  'csqtt://connect?v=2&host=example.com&peer=46000&password=secret',
  'wdtt://example.com:46000:46001:secret:csqtt',
  'qwdtt://config?v=1&ip=example.com&dtls=46000&pass=secret',
];

const nonCopyableLinks = [
  '',
  'direct',
  'block',
  'urltest',
  'wireguard://example.com',
  'tcp://127.0.0.1:8080',
];

describe('isCopyableProxyLink', () => {
  describe.each(copyableLinks)('copyable proxy URI %s', (link) => {
    it('returns true', () => {
      expect(isCopyableProxyLink(link)).toBe(true);
    });
  });

  describe.each(nonCopyableLinks)('non-copyable value %s', (link) => {
    it('returns false', () => {
      expect(isCopyableProxyLink(link)).toBe(false);
    });
  });
});
