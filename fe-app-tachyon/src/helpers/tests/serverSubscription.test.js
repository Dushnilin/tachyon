import fs from 'node:fs';
import path from 'node:path';
import { webcrypto } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { parse } from '@babel/parser';
import { describe, expect, it } from 'vitest';

const root = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  '../../../..',
);
const source = fs.readFileSync(
  path.join(
    root,
    'luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/server.js',
  ),
  'utf8',
);
const ast = parse(source, {
  allowReturnOutsideFunction: true,
  sourceType: 'script',
});
const functions = new Map(
  ast.program.body
    .filter((node) => node.type === 'FunctionDeclaration')
    .map((node) => [node.id.name, source.slice(node.start, node.end)]),
);
const names = [
  'normalizeHost',
  'isIpv4',
  'isIpv6',
  'isHostname',
  'isHost',
  'formatHostForUri',
  'subscriptionServerProtocol',
  'subscriptionServerSupported',
  'subscriptionUrl',
  'subscriptionToken',
  'configureServerSubscription',
  'randomBytes',
  'randomHex',
  'base64Encode',
  'generateBase64Key',
  'generateShadowsocksPassword',
  'getWidget',
  'getControlWidget',
  'setWidgetValue',
  'getCurrentOptionValue',
  'autoConfigureStreamTransport',
];

function load(window = { crypto: webcrypto }) {
  const E = (tag, attrs, children) => ({ tag, attrs, children });
  return new Function(
    'window',
    'E',
    '_',
    'showSubscriptionModal',
    `const UCI_PACKAGE='tachyon';${names.map((name) => functions.get(name)).join('\n')};return {subscriptionUrl,subscriptionToken,subscriptionServerSupported,configureServerSubscription,generateShadowsocksPassword,autoConfigureStreamTransport};`,
  )(
    window,
    E,
    (text) => text,
    () => {},
  );
}

describe('server subscription configuration', () => {
  const options = {
    host: 'vpn.example.com',
    port: '443',
    scheme: 'https',
    format: 'base64',
    token: 'a'.repeat(64),
  };
  it('builds a client URL independently of the LuCI login/session', () => {
    expect(load().subscriptionUrl(options)).toBe(
      `https://vpn.example.com/cgi-bin/tachyon-sub/${options.token}?format=base64`,
    );
  });
  it('supports IPv6, custom ports and the text format', () => {
    expect(
      load().subscriptionUrl({
        ...options,
        host: '[2001:db8::1]',
        port: 8443,
        format: 'plain',
      }),
    ).toBe(
      `https://[2001:db8::1]:8443/cgi-bin/tachyon-sub/${options.token}?format=plain`,
    );
  });
  it.each([
    'evil.example/@host',
    'https://vpn.example.com',
    'vpn.example.com?token=x',
    'bad..example',
    ':::',
  ])('rejects an invalid host: %s', (host) => {
    expect(load().subscriptionUrl({ ...options, host })).toBe('');
  });
  it.each([
    { port: 0 },
    { port: 65536 },
    { port: 12.5 },
    { token: 'short' },
    { scheme: 'javascript' },
    { format: 'json' },
  ])('rejects unsafe or incomplete options: %j', (change) => {
    expect(load().subscriptionUrl({ ...options, ...change })).toBe('');
  });
  it('recognizes Mieru inside JSON Inbound and excludes Tailscale, AWG and unknown JSON', () => {
    const { subscriptionServerSupported: supported } = load();
    expect(
      supported({ protocol: 'json_inbound', inbound_json: '{"type":"mieru"}' }),
    ).toBe(true);
    expect(supported({ protocol: 'vless' })).toBe(true);
    expect(supported({ protocol: 'tailscale' })).toBe(false);
    expect(supported({ protocol: 'awg' })).toBe(false);
    expect(
      supported({ protocol: 'json_inbound', inbound_json: '{"type":"socks"}' }),
    ).toBe(false);
    expect(
      supported({ protocol: 'json_inbound', inbound_json: 'broken' }),
    ).toBe(false);
  });
  it('uses a 256-bit CSPRNG token and refuses insecure fallback', () => {
    expect(load().subscriptionToken()).toMatch(/^[0-9a-f]{64}$/);
    expect(() => load({}).subscriptionToken()).toThrow(
      'Secure random generator',
    );
  });
  it('places a non-submit Configure subscription button before the existing description', () => {
    const section = { description: 'Accept external proxy connections' };
    load().configureServerSubscription(section);
    const [toolbar, description] = section.description.children;
    expect(toolbar.children[0].attrs.type).toBe('button');
    expect(toolbar.children[0].children).toBe('Configure subscription');
    expect(description.children).toBe('Accept external proxy connections');
  });
  it('preserves unchecked states and stages only subscription options without parsing the page', async () => {
    const inputs = [];
    const buttons = [];
    const writes = [];
    let saves = 0;
    const E = (tag, attrs = {}, children) => {
      // LuCI sets HTML attributes: even checked="false" means checked.
      const node = {
        tag,
        attrs,
        children,
        style: { display: attrs.style?.includes('display:none') ? 'none' : '' },
        value: attrs.value || '',
        checked: attrs.checked != null,
        disabled: attrs.disabled != null,
        addEventListener() {},
      };
      if (tag === 'input') inputs.push(node);
      if (tag === 'button') buttons.push(node);
      return node;
    };
    const settings = {
      server_subscription_enabled: '0',
      server_subscription_mode: 'selected',
      server_subscription_servers: ['vless'],
    };
    const modalFunctions = [...names, 'asList', 'showSubscriptionModal'];
    new Function(
      'window',
      'E',
      '_',
      'uci',
      'ui',
      `const UCI_PACKAGE='tachyon';${modalFunctions.map((name) => functions.get(name)).join('\n')};showSubscriptionModal({});`,
    )(
      { crypto: webcrypto, location: { hostname: 'router.example' } },
      E,
      (text) => text,
      {
        get: (_p, _s, key) => settings[key],
        set: (_p, _s, key) => writes.push(key),
        save: async () => {
          saves++;
        },
        sections: () => [
          { '.name': 'vless', protocol: 'vless' },
          { '.name': 'tailscale', protocol: 'tailscale' },
          { '.name': 'off', protocol: 'vless', enabled: '0' },
          { '.name': 'hy2', protocol: 'hysteria2' },
        ],
      },
      {
        showModal() {},
        hideModal() {},
        changes: { async init() {} },
        addNotification() {},
      },
    );
    const checkboxes = inputs.filter((node) => node.attrs.type === 'checkbox');
    expect(checkboxes.map((node) => node.checked)).toEqual([
      false,
      false,
      true,
      false,
      false,
      false,
    ]);
    expect(checkboxes.slice(2).map((node) => node.disabled)).toEqual([
      false,
      true,
      true,
      false,
    ]);
    await buttons.find((node) => node.children === 'Save').attrs.click();
    expect(saves).toBe(1);
    expect(writes).toHaveLength(8);
    expect(writes.every((key) => key.startsWith('server_subscription_'))).toBe(
      true,
    );
  });

  it('generates valid-length Shadowsocks 2022 base64 keys and AEAD secrets', () => {
    const { generateShadowsocksPassword } = load({
      crypto: webcrypto,
      btoa: (str) => Buffer.from(str, 'binary').toString('base64'),
    });
    const key128 = generateShadowsocksPassword('2022-blake3-aes-128-gcm');
    expect(Buffer.from(key128, 'base64')).toHaveLength(16);

    const key256 = generateShadowsocksPassword('2022-blake3-aes-256-gcm');
    expect(Buffer.from(key256, 'base64')).toHaveLength(32);

    const keyChacha = generateShadowsocksPassword(
      '2022-blake3-chacha20-poly1305',
    );
    expect(Buffer.from(keyChacha, 'base64')).toHaveLength(32);

    const aead = generateShadowsocksPassword('2022-blake3-chacha8-poly1305');
    expect(Buffer.from(aead, 'base64')).toHaveLength(32);
  });

  it('auto-configures stream transport parameters for ws, httpupgrade, http, grpc and xhttp', () => {
    const store = new Map();
    globalThis.document = { getElementById: () => null };
    globalThis.uci = {
      get: (_pkg, sec, opt) => store.get(`${sec}.${opt}`),
      set: (_pkg, sec, opt, val) => store.set(`${sec}.${opt}`, val),
      unset: (_pkg, sec, opt) => store.delete(`${sec}.${opt}`),
      sections: () => [],
    };
    const { autoConfigureStreamTransport } = load();

    autoConfigureStreamTransport(
      's1',
      'vless',
      'reality',
      'ws',
      'www.microsoft.com',
    );
    expect(store.get('s1.transport_path')).toMatch(/^\/vless-ws-[0-9a-f]{6}$/);
    expect(store.get('s1.transport_host')).toBe('www.microsoft.com');
    expect(store.get('s1.vless_flow')).toBe('none');

    autoConfigureStreamTransport(
      's1',
      'vmess',
      'tls',
      'grpc',
      'vpn.example.com',
    );
    expect(store.get('s1.transport_service_name')).toMatch(
      /^vmess_grpc_[0-9a-f]{6}$/,
    );
    expect(store.get('s1.tls_alpn')).toEqual(['h2']);

    autoConfigureStreamTransport(
      's1',
      'vless',
      'reality',
      'xhttp',
      'www.microsoft.com',
    );
    expect(store.get('s1.transport_xhttp_mode')).toBe('auto');
    expect(store.get('s1.transport_path')).toMatch(
      /^\/vless-xhttp-[0-9a-f]{6}$/,
    );
  });
});
