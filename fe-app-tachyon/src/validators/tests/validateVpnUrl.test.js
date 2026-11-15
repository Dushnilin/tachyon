import { afterEach, describe, expect, it } from 'vitest';
import { deflateSync } from 'node:zlib';
import { store } from '../../tachyon/services/store.service';
import {
  compactVpnUri,
  splitAmneziaTextEntries,
  supportsVpnUrl,
  validateVpnUrl,
} from '../validateVpnUrl';
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
  it('supports vpn:// on tachyon-core even without diagnosticsSystemInfo', () => {
    store.set({
      activeEngine: 'tachyon-core',
      diagnosticsSystemInfo: undefined,
    });
    expect(supportsVpnUrl()).toBe(true);
    expect(validateVpnUrl(encode(conf)).valid).toBe(true);
    expect(validateProxyUrl(encode(conf)).valid).toBe(true);
  });
  it('compacts multiline vpn:// URIs and keeps fragments intact', () => {
    core('1.14.2-lx.11', 1);
    const full = encode(conf);
    const body = full.slice(6);
    const splitAt = Math.floor(body.length / 2);
    const multiline = `vpn://${body.slice(0, splitAt)}\n  ${body.slice(splitAt)}#My Server`;
    expect(compactVpnUri(multiline)).toBe(`${full}#My Server`);
    expect(validateVpnUrl(multiline).valid).toBe(true);
    expect(validateProxyUrl(multiline).valid).toBe(true);
  });
  it('inflates 0x000000FF Amnezia header streams synchronously and rejects invalid inner payloads', () => {
    core('1.14.2-lx.11', 1);
    const header = Buffer.from([0x00, 0x00, 0x00, 0xff]);
    const validPayload = Buffer.concat([
      header,
      deflateSync(Buffer.from(conf)),
    ]);
    expect(
      validateVpnUrl('vpn://' + validPayload.toString('base64url')).valid,
    ).toBe(true);

    const noPeerConf = `[Interface]\nPrivateKey = ${key}\nAddress = 10.77.0.2/32\n`;
    const invalidInnerPayload = Buffer.concat([
      header,
      deflateSync(Buffer.from(noPeerConf)),
    ]);
    expect(
      validateVpnUrl('vpn://' + invalidInnerPayload.toString('base64url'))
        .valid,
    ).toBe(false);
  });
  it('substitutes $REMOTE_HOST and $SERVER_IP_ADDRESS placeholders from container metadata', () => {
    core('1.14.2-lx.11', 1);
    const withRemoteHost = {
      defaultContainer: 'amnezia-awg2',
      containers: [
        {
          container: 'amnezia-awg2',
          awg: {
            hostName: '203.0.113.10',
            last_config: JSON.stringify({
              config: conf.replace('[2001:db8::1]', '$REMOTE_HOST'),
            }),
          },
        },
      ],
    };
    expect(validateVpnUrl(encode(JSON.stringify(withRemoteHost))).valid).toBe(
      true,
    );

    const withServerIp = {
      defaultContainer: 'amnezia-awg',
      hostName: '203.0.113.11',
      containers: [
        {
          container: 'amnezia-awg',
          awg: {
            last_config: JSON.stringify({
              config: conf.replace('[2001:db8::1]', '$SERVER_IP_ADDRESS'),
            }),
          },
        },
      ],
    };
    expect(validateVpnUrl(encode(JSON.stringify(withServerIp))).valid).toBe(
      true,
    );

    const missingHost = {
      defaultContainer: 'amnezia-awg',
      containers: [
        {
          container: 'amnezia-awg',
          awg: {
            last_config: JSON.stringify({
              config: conf.replace('[2001:db8::1]:51820', '$REMOTE_HOST'),
            }),
          },
        },
      ],
    };
    expect(validateVpnUrl(encode(JSON.stringify(missingHost))).valid).toBe(
      false,
    );

    const substitutedEndpoint = {
      defaultContainer: 'amnezia-awg',
      hostName: '203.0.113.12:51820',
      containers: [
        {
          container: 'amnezia-awg',
          awg: {
            last_config: JSON.stringify({
              config: conf.replace('[2001:db8::1]:51820', '$REMOTE_HOST'),
            }),
          },
        },
      ],
    };
    expect(
      validateVpnUrl(encode(JSON.stringify(substitutedEndpoint))).valid,
    ).toBe(true);
  });
  it('synthesizes missing [Peer] block from container settings metadata', () => {
    core('1.14.2-lx.11', 1);
    const ifaceOnly = `[Interface]\nPrivateKey = ${key}\nAddress = 10.77.0.2/32\nJc = 4\n`;
    const payload = {
      defaultContainer: 'amnezia-awg',
      hostName: '203.0.113.20',
      containers: [
        {
          container: 'amnezia-awg',
          awg: {
            port: 51820,
            last_config: JSON.stringify({
              config: ifaceOnly,
              server_pub_key: key,
              psk_key: key,
            }),
          },
        },
      ],
    };
    expect(validateVpnUrl(encode(JSON.stringify(payload))).valid).toBe(true);

    const missingPeerKey = {
      defaultContainer: 'amnezia-awg',
      hostName: '203.0.113.20',
      containers: [
        {
          container: 'amnezia-awg',
          awg: {
            port: 51820,
            last_config: JSON.stringify({
              config: ifaceOnly,
            }),
          },
        },
      ],
    };
    expect(validateVpnUrl(encode(JSON.stringify(missingPeerKey))).valid).toBe(
      false,
    );
  });
  it('rejects Amnezia Cloud API keys (api_config / api_key) with descriptive guidance', () => {
    core('1.14.2-lx.11', 1);
    for (const cloudObj of [
      { api_config: 'https://api.example.com/v1', api_key: 'tok-123' },
      { api_config: { endpoint: 'https://api.example.com/v1' } },
      { api_key: 'tok-456' },
    ]) {
      const res = validateVpnUrl(encode(JSON.stringify(cloudObj)));
      expect(res.valid).toBe(false);
      expect(res.message).toContain('Amnezia Cloud API');
    }
  });
  it('splits wrapped multiline vpn:// links and .conf blocks via splitAmneziaTextEntries', () => {
    const full1 = encode(conf);
    const body1 = full1.slice(6);
    const mid1 = Math.floor(body1.length / 2);
    const wrapped1 = `vpn://${body1.slice(0, mid1)}\n${body1.slice(mid1)}`;

    const single = splitAmneziaTextEntries(wrapped1);
    expect(single.confBody).toBe('');
    expect(single.vpnLinks).toEqual([full1]);
    expect(single.entries).toEqual([full1]);

    const full2 = encode(conf.replace('51820', '51821'));
    const body2 = full2.slice(6);
    const mid2 = Math.floor(body2.length / 2);
    const multiText = [
      conf.trim(),
      '',
      `vpn://${body1.slice(0, mid1)}`,
      `  ${body1.slice(mid1)}#First Node`,
      `vpn://${body2.slice(0, mid2)}`,
      `${body2.slice(mid2)}`,
    ].join('\n');

    const mixed = splitAmneziaTextEntries(multiText, 'CustomAWG');
    expect(mixed.confBody).toBe(conf.trim());
    expect(mixed.vpnLinks).toEqual([`${full1}#First Node`, full2]);
    expect(mixed.entries).toEqual([
      JSON.stringify({ name: 'CustomAWG', config: conf.trim() }),
      `${full1}#First Node`,
      full2,
    ]);
  });
});
