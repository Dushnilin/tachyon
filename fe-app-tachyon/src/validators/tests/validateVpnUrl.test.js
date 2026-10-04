import { afterEach, describe, expect, it } from 'vitest';
import { deflateSync } from 'node:zlib';
import { store } from '../../tachyon/services/store.service';
import { supportsVpnUrl } from '../validateVpnUrl';
import { validateProxyUrl } from '../validateProxyUrl';
import { isCopyableProxyLink } from '../../helpers/isCopyableProxyLink';

const key = Buffer.from(Array.from({ length: 32 }, (_, i) => i + 1)).toString(
  'base64',
);
const conf = `[Interface]\nPrivateKey = ${key}\nAddress = 10.77.0.2/32\nJc = 4\n[Peer]\nPublicKey = ${key}\nEndpoint = [2001:db8::1]:51820\n`;
const encode = (text) => 'vpn://' + Buffer.from(text).toString('base64url');
const original = store.get();
function core(version, lx, engine = 'sing-box') {
  store.set({
    activeEngine: engine,
    diagnosticsSystemInfo: {
      ...original.diagnosticsSystemInfo,
      sing_box_version: version,
      sing_box_lx: lx,
    },
  });
}
afterEach(() => store.reset());

describe('vpn:// import', () => {
  it('requires active LX, including plain WireGuard exports', () => {
    for (const version of ['1.14.2', '1.14.1-extended-2.7.2']) {
      core(version, 0);
      expect(supportsVpnUrl()).toBe(false);
      expect(validateProxyUrl(encode(conf)).valid).toBe(false);
    }
    core('1.14.2-lx.11', 1, 'steer');
    expect(validateProxyUrl(encode(conf)).valid).toBe(false);
    core('1.14.2-lx.11', 0);
    expect(supportsVpnUrl()).toBe(true);
    expect(validateProxyUrl(encode(conf)).valid).toBe(true);
  });
  it('accepts plain INI and selected native JSON containers', () => {
    core('1.14.2-lx.11', 1);
    expect(validateProxyUrl(encode(conf)).valid).toBe(true);
    const payload = {
      defaultContainer: 'amnezia-awg2',
      containers: [
        {
          container: 'amnezia-awg2',
          awg: { last_config: JSON.stringify({ config: conf }) },
        },
      ],
    };
    expect(validateProxyUrl(encode(JSON.stringify(payload))).valid).toBe(true);
    payload.defaultContainer = 'unsupported';
    expect(validateProxyUrl(encode(JSON.stringify(payload))).valid).toBe(false);
    expect(validateProxyUrl(encode(conf + '\n[Peer]\n')).valid).toBe(false);
    expect(validateProxyUrl(encode(conf.replace(key, 'invalid'))).valid).toBe(
      false,
    );
  });
  it('checks the compressed envelope and leaves full deflate validation to backend', () => {
    core('1.14.2-lx.11', 1);
    const bytes = Buffer.from(conf);
    const size = Buffer.alloc(4);
    size.writeUInt32BE(bytes.length);
    const payload = Buffer.concat([size, deflateSync(bytes)]);
    expect(
      validateProxyUrl('vpn://' + payload.toString('base64url')).valid,
    ).toBe(true);
    payload.writeUInt32BE(65537);
    expect(
      validateProxyUrl('vpn://' + payload.toString('base64url')).valid,
    ).toBe(false);
    expect(validateProxyUrl('vpn://invalid!').valid).toBe(false);
  });
  it('preserves copy support without accepting additional URI aliases', () => {
    core('1.14.2-lx.11', 1);
    expect(isCopyableProxyLink(encode(conf))).toBe(true);
    for (const scheme of ['wg', 'wireguard', 'awg']) {
      expect(validateProxyUrl(scheme + '://example.com').valid).toBe(false);
      expect(isCopyableProxyLink(scheme + '://example.com')).toBe(false);
    }
  });
});
