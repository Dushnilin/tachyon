import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parse } from '@babel/parser';
import { describe, expect, it } from 'vitest';
import { cidrsOverlap, parseCidrRange } from '../../validators/validateSubnet';
import { formatHostForUri, unbracketHost } from '../../validators/hostPort';

const testDir = path.dirname(fileURLToPath(import.meta.url));
const serverViewPath = path.resolve(
  testDir,
  '../../../../luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/server.js',
);

function loadServerFunctions(values) {
  const source = fs.readFileSync(serverViewPath, 'utf8');
  const ast = parse(source, {
    allowReturnOutsideFunction: true,
    sourceType: 'script',
  });
  const functionSources = new Map(
    ast.program.body
      .filter((node) => node.type === 'FunctionDeclaration' && node.id)
      .map((node) => [node.id.name, source.slice(node.start, node.end)]),
  );

  const requiredFunctions = [
    'asList',
    'getFirstListValue',
    'getProtocol',
    'getServerName',
    'getSocksUsername',
    'isSocksAuthenticationEnabled',
    'getDefaultSecurity',
    'normalizeVlessFlow',
    'getEffectiveSecurity',
    'normalizeHost',
    'getBrowserHost',
    'isIpv4',
    'isIpv6',
    'formatHostForUri',
    'isPrivateOrReservedIpv4',
    'isPrivateOrReservedIp',
    'getServerIdentity',
    'encodeQuery',
    'getPublicHost',
    'getServerPort',
    'getTransportParams',
    'serverSafeName',
    'defaultTlsCertificatePath',
    'shouldUseGeneratedTlsCertificatePin',
    'normalizeSha256',
    'normalizeMd5',
    'base64Encode',
    'base64UrlEncode',
    'buildVlessTrojanLink',
    'buildVmessLink',
    'buildShadowsocksLink',
    'buildSocksLink',
    'buildHysteria2Link',
    'buildTuicLink',
    'buildAnytlsLink',
    'buildNaiveLink',
    'buildMieruLink',
    'buildAwgClientConfig',
    'buildClientLink',
    'resetOptionValues',
    'addOptionValue',
    'populateListenAddressChoices',
  ];

  const functions = requiredFunctions
    .map((name) => {
      const fnSrc = functionSources.get(name);
      if (!fnSrc) {
        throw new Error(`Function ${name} not found in server.js`);
      }
      return fnSrc;
    })
    .join('\n');

  const factory = new Function(
    'uci',
    'UCI_PACKAGE',
    'window',
    'main',
    '_',
    `
      const DEFAULT_SERVER_PROTOCOL = 'tailscale';
      const STREAM_PROTOCOLS = ['vless', 'vmess', 'trojan'];
      const SECURITY_BY_PROTOCOL = {
        vless: ['reality', 'tls', 'none'],
        vmess: ['tls', 'none'],
        trojan: ['tls'],
      };
      ${functions}
      return {
        isPrivateOrReservedIp,
        buildVlessTrojanLink,
        buildVmessLink,
        buildShadowsocksLink,
        buildSocksLink,
        buildHysteria2Link,
        buildTuicLink,
        buildAnytlsLink,
        buildNaiveLink,
        buildMieruLink,
        buildAwgClientConfig,
        buildClientLink,
        populateListenAddressChoices,
      };
    `,
  );

  const uci = {
    get(_pkg, sectionId, optionName) {
      return values[`${sectionId}.${optionName}`] ?? '';
    },
  };
  const mainMock = {
    parseCidrRange,
    cidrsOverlap,
    formatHostForUri,
    unbracketHost,
  };
  const translate = (s) => s;
  return factory(
    uci,
    'tachyon',
    { location: { hostname: '2001:db8::99' } },
    mainMock,
    translate,
  );
}

describe('server.ts IPv6 share links, AWG Endpoint, reserved IP & listen choices', () => {
  const certPin =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  it('wraps IPv6 hosts in brackets for VLESS, Trojan, Shadowsocks, SOCKS, Hysteria2, TUIC, AnyTLS, Naive, Mieru links', () => {
    const fns = loadServerFunctions({
      'srv_vless.protocol': 'vless',
      'srv_vless.public_host': '2001:db8::1',
      'srv_vless.listen_port': '443',
      'srv_vless.security': 'tls',
      'srv_vless.tls_server_name': 'vpn.example.com',
      'srv_vless.transport': 'tcp',

      'srv_trojan.protocol': 'trojan',
      'srv_trojan.public_host': '[2001:db8::2]',
      'srv_trojan.listen_port': '8443',
      'srv_trojan.security': 'tls',
      'srv_trojan.transport': 'tcp',

      'srv_ss.protocol': 'shadowsocks',
      'srv_ss.public_host': '2001:db8::3',
      'srv_ss.listen_port': '9443',
      'srv_ss.shadowsocks_method': '2022-blake3-aes-128-gcm',

      'srv_socks.protocol': 'socks',
      'srv_socks.public_host': '2001:db8::4',
      'srv_socks.listen_port': '1080',

      'srv_hy2.protocol': 'hysteria2',
      'srv_hy2.public_host': '2001:db8::5',
      'srv_hy2.listen_port': '4443',

      'srv_tuic.protocol': 'tuic',
      'srv_tuic.public_host': '2001:db8::6',
      'srv_tuic.listen_port': '5443',

      'srv_anytls.protocol': 'anytls',
      'srv_anytls.public_host': '2001:db8::7',
      'srv_anytls.listen_port': '6443',

      'srv_naive.protocol': 'naive',
      'srv_naive.public_host': '2001:db8::8',
      'srv_naive.listen_port': '7443',

      'srv_mieru.protocol': 'mieru',
      'srv_mieru.public_host': '2001:db8::9',
      'srv_mieru.listen_port': '8444',
    });

    const vless = fns.buildVlessTrojanLink(
      'srv_vless',
      { uuid: '11111111-1111-1111-1111-111111111111', name: 'VLESS-v6' },
      { tlsCertificateSha256: certPin },
    );
    expect(vless).toContain('@[2001:db8::1]:443');

    const trojan = fns.buildVlessTrojanLink(
      'srv_trojan',
      { password: 'secret', name: 'Trojan-v6' },
      { tlsCertificateSha256: certPin },
    );
    expect(trojan).toContain('@[2001:db8::2]:8443');

    const ss = fns.buildShadowsocksLink('srv_ss', {
      password: 'ss-password',
      name: 'SS-v6',
    });
    expect(ss).toContain('@[2001:db8::3]:9443');

    const socks = fns.buildSocksLink('srv_socks', {
      username: 'u',
      password: 'p',
      name: 'SOCKS-v6',
    });
    expect(socks).toContain('@[2001:db8::4]:1080');

    const hy2 = fns.buildHysteria2Link(
      'srv_hy2',
      { password: 'p', name: 'Hy2-v6' },
      { tlsCertificateSha256: certPin },
    );
    expect(hy2).toContain('@[2001:db8::5]:4443');

    const tuic = fns.buildTuicLink(
      'srv_tuic',
      {
        uuid: '22222222-2222-2222-2222-222222222222',
        password: 'p',
        name: 'TUIC-v6',
      },
      { tlsCertificateSha256: certPin },
    );
    expect(tuic).toContain('@[2001:db8::6]:5443');

    const anytls = fns.buildAnytlsLink(
      'srv_anytls',
      { password: 'p', name: 'AnyTLS-v6' },
      { tlsCertificateSha256: certPin },
    );
    expect(anytls).toContain('@[2001:db8::7]:6443');

    const naive = fns.buildNaiveLink('srv_naive', {
      username: 'u',
      password: 'p',
      name: 'Naive-v6',
    });
    expect(naive).toContain('@[2001:db8::8]:7443');

    const mieru = fns.buildMieruLink('srv_mieru', {
      username: 'u',
      password: 'p',
      name: 'Mieru-v6',
    });
    expect(mieru).toContain('@[2001:db8::9]?port=8444');
  });

  it('keeps unbracketed IPv6 in VMess JSON add field', () => {
    const fns = loadServerFunctions({
      'srv_vmess.protocol': 'vmess',
      'srv_vmess.public_host': '[2001:db8::42]',
      'srv_vmess.listen_port': '443',
      'srv_vmess.security': 'none',
      'srv_vmess.transport': 'tcp',
    });

    const link = fns.buildVmessLink('srv_vmess', {
      uuid: '33333333-3333-3333-3333-333333333333',
      name: 'VMess-v6',
    });
    expect(link.startsWith('vmess://')).toBe(true);
    const decoded = JSON.parse(
      Buffer.from(link.slice('vmess://'.length), 'base64').toString('utf8'),
    );
    expect(decoded.add).toBe('2001:db8::42');
    expect(decoded.port).toBe('443');
  });

  it('brackets IPv6 Endpoint cleanly in buildAwgClientConfig without double brackets', () => {
    const fns = loadServerFunctions({
      'srv_awg.protocol': 'awg',
      'srv_awg.public_host': '2001:db8::518',
      'srv_awg.listen_port': '51820',
      'srv_awg.awg_client_private_key': 'clientPrivKey==',
      'srv_awg.awg_server_public_key': 'serverPubKey==',
      'srv_awg.awg_client_address': '10.8.0.2/32',
      'srv_awg_bracketed.protocol': 'awg',
      'srv_awg_bracketed.public_host': '[2001:db8::519]',
      'srv_awg_bracketed.listen_port': '51821',
      'srv_awg_bracketed.awg_client_private_key': 'clientPrivKey==',
      'srv_awg_bracketed.awg_server_public_key': 'serverPubKey==',
      'srv_awg_bracketed.awg_client_address': '10.8.0.2/32',
      'srv_awg_v4.protocol': 'awg',
      'srv_awg_v4.public_host': '198.51.100.1',
      'srv_awg_v4.listen_port': '51822',
      'srv_awg_v4.awg_client_private_key': 'clientPrivKey==',
      'srv_awg_v4.awg_server_public_key': 'serverPubKey==',
      'srv_awg_v4.awg_client_address': '10.8.0.2/32',
    });

    const v6Plain = fns.buildAwgClientConfig('srv_awg');
    expect(v6Plain).toContain('Endpoint = [2001:db8::518]:51820');

    const v6Bracketed = fns.buildAwgClientConfig('srv_awg_bracketed');
    expect(v6Bracketed).toContain('Endpoint = [2001:db8::519]:51821');
    expect(v6Bracketed).not.toContain('[[2001:');

    const v4 = fns.buildAwgClientConfig('srv_awg_v4');
    expect(v4).toContain('Endpoint = 198.51.100.1:51822');
  });

  it('detects private/reserved IPv6 and IPv4-mapped IPv6 ranges accurately', () => {
    const fns = loadServerFunctions({});

    expect(fns.isPrivateOrReservedIp('::')).toBe(true);
    expect(fns.isPrivateOrReservedIp('::1')).toBe(true);
    expect(fns.isPrivateOrReservedIp('fc00::1')).toBe(true);
    expect(fns.isPrivateOrReservedIp('fd12:3456::1')).toBe(true);
    expect(fns.isPrivateOrReservedIp('fe80::1')).toBe(true);
    expect(fns.isPrivateOrReservedIp('2001:db8::1')).toBe(true);
    expect(fns.isPrivateOrReservedIp('ff02::1')).toBe(true);
    expect(fns.isPrivateOrReservedIp('::ffff:192.168.1.1')).toBe(true);

    expect(fns.isPrivateOrReservedIp('2606:4700:4700::1111')).toBe(false);
    expect(fns.isPrivateOrReservedIp('[2606:4700:4700::1111]')).toBe(false);
    expect(fns.isPrivateOrReservedIp('1.1.1.1')).toBe(false);
  });

  it('populates IPv6 listen choices alongside IPv4 choices', () => {
    const fns = loadServerFunctions({});
    const added = [];
    const mockOption = {
      clear: () => {},
      value: (v, label) => added.push({ v, label }),
    };
    fns.populateListenAddressChoices(mockOption, {
      lan_ip: '192.168.1.1',
      lan_ipv6: 'fd00::1',
      wan_ips: ['203.0.113.5'],
      wan_ipv6: '2001:db8::5',
    });

    const values = added.map((item) => item.v);
    expect(values).toContain('0.0.0.0');
    expect(values).toContain('::');
    expect(values).toContain('::1');
    expect(values).toContain('fd00::1');
    expect(values).toContain('2001:db8::5');
  });
});
