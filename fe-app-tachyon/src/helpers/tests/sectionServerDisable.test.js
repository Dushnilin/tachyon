import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parse } from '@babel/parser';
import { describe, expect, it, vi } from 'vitest';

const source = fs.readFileSync(
  path.resolve(
    path.dirname(fileURLToPath(import.meta.url)),
    '../../../../luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/section.js',
  ),
  'utf8',
);
const ast = parse(source, {
  allowReturnOutsideFunction: true,
  sourceType: 'script',
});
const helpers = [
  'readDependentServerNotices',
  'writeDependentServerNotices',
  'showDependentServerNotice',
  'restoreDependentServerNotices',
  'disableServersUsingDisabledSections',
  'configureDependentServerDisable',
].map((name) => {
  const node = ast.program.body.find(
    (item) => item.type === 'FunctionDeclaration' && item.id.name === name,
  );
  if (!node) throw new Error(`Function ${name} not found`);
  return source.slice(node.start, node.end);
});

function setup(
  sections,
  servers,
  parseFields = async () => 'parsed',
  storage = new Map(),
) {
  const uci = {
    sections: (_pkg, type) => (type === 'section' ? sections : servers),
    set: vi.fn((_pkg, id, key, value) => {
      servers.find((server) => server['.name'] === id)[key] = value;
    }),
  };
  const notifications = [];
  const ui = {
    addNotification: vi.fn(() => {
      const node = {
        id: '',
        dismissed: false,
        querySelector: () => ({
          addEventListener: (_type, fn) => {
            node.dismiss = fn;
          },
        }),
        remove: () => {
          node.dismissed = true;
        },
      };
      notifications.push(node);
      return node;
    }),
  };
  const document = {
    getElementById: (id) =>
      notifications.find((node) => node.id === id && !node.dismissed),
  };
  const window = {
    localStorage: {
      getItem: (key) => storage.get(key) || null,
      setItem: (key, value) => storage.set(key, value),
      removeItem: (key) => storage.delete(key),
    },
  };
  const E = (tag, attributes, children) => ({ tag, attributes, children });
  const translate = (message) => ({
    format: (...args) =>
      args.reduce((text, arg) => text.replace('%s', arg), message),
    toString: () => message,
  });
  const configure = new Function(
    'uci',
    'ui',
    'E',
    '_',
    'UCI_PACKAGE',
    'window',
    'document',
    `${helpers.join('\n')}; return { configure: configureDependentServerDisable, restore: restoreDependentServerNotices };`,
  )(uci, ui, E, translate, 'tachyon', window, document);
  const originalParse = vi.fn(parseFields);
  const map = { parse: originalParse };
  configure.configure(map);
  return {
    map,
    uci,
    ui,
    configure: configure.configure,
    restore: configure.restore,
    originalParse,
    storage,
    notifications,
    window,
  };
}

const vpn = () => ({ '.name': 'vpn', label: 'VPN', enabled: '0' });
const server = (name, overrides = {}) => ({
  '.name': name,
  label: name,
  enabled: '1',
  routing_mode: 'section',
  routing_section: 'vpn',
  ...overrides,
});

describe('disabling servers that depend on a disabled section', () => {
  it('disables only enabled servers using selected-section routing and preserves references', async () => {
    const servers = [
      server('vless'),
      server('hysteria', { enabled: undefined }),
      server('already-disabled', { enabled: '0' }),
      server('direct', { routing_mode: 'direct' }),
      server('rules', { routing_mode: 'rules' }),
      server('default', { routing_mode: undefined }),
      server('other', { routing_section: 'other' }),
      server('missing', { routing_section: 'missing' }),
    ];
    const { map, uci, ui } = setup(
      [vpn(), { '.name': 'other', enabled: '1' }],
      servers,
    );
    expect(await map.parse()).toBe('parsed');
    expect(uci.set.mock.calls).toEqual([
      ['tachyon', 'vless', 'enabled', '0'],
      ['tachyon', 'hysteria', 'enabled', '0'],
    ]);
    expect(
      servers.every(
        (item) => item.routing_mode !== 'section' || item.routing_section,
      ),
    ).toBe(true);
    expect(ui.addNotification).toHaveBeenCalledTimes(1);
    const message = ui.addNotification.mock.calls[0][1].children[0].children;
    expect(message).toContain('VPN');
    expect(message).toContain('vless, hysteria');
    await map.parse();
    expect(ui.addNotification).toHaveBeenCalledTimes(1);
  });

  it('runs after all fields, including a server checkbox parsed later in another tab', async () => {
    const section = { '.name': 'vpn', enabled: '1' };
    const inbound = server('vless');
    const { map, uci } = setup([section], [inbound], async () => {
      await Promise.all([
        Promise.resolve().then(() => {
          section.enabled = '0';
        }),
        Promise.resolve().then(() => {
          inbound.enabled = '1';
        }),
      ]);
    });
    await map.parse();
    expect(inbound.enabled).toBe('0');
    expect(uci.set).toHaveBeenCalledTimes(1);
  });

  it('honors a routing mode changed to Direct in the same save', async () => {
    const inbound = server('vless');
    const { map, uci, ui } = setup([vpn()], [inbound], async () => {
      inbound.routing_mode = 'direct';
    });
    await map.parse();
    expect(inbound.enabled).toBe('1');
    expect(uci.set).not.toHaveBeenCalled();
    expect(ui.addNotification).not.toHaveBeenCalled();
  });

  it('does not mutate dependencies when form validation fails', async () => {
    const inbound = server('vless');
    const { map, uci, ui } = setup([vpn()], [inbound], async () => {
      throw new Error('invalid port');
    });
    await expect(map.parse()).rejects.toThrow('invalid port');
    expect(inbound.enabled).toBe('1');
    expect(uci.set).not.toHaveBeenCalled();
    expect(ui.addNotification).not.toHaveBeenCalled();
  });

  it('keeps read-only maps unchanged', async () => {
    const { map, uci, ui } = setup([vpn()], [server('vless')]);
    map.readonly = true;
    await map.parse();
    expect(uci.set).not.toHaveBeenCalled();
    expect(ui.addNotification).not.toHaveBeenCalled();
  });

  it('does not re-enable servers when their section is re-enabled', async () => {
    const section = vpn();
    const inbound = server('vless');
    const { map, uci, ui } = setup([section], [inbound]);
    await map.parse();
    section.enabled = '1';
    await map.parse();
    expect(inbound.enabled).toBe('0');
    expect(inbound.routing_section).toBe('vpn');
    expect(inbound.routing_mode).toBe('section');
    expect(uci.set).toHaveBeenCalledTimes(1);
    expect(ui.addNotification).toHaveBeenCalledTimes(1);
  });

  it('installs once per map and independently for a modal map', async () => {
    const { map, configure, originalParse } = setup([vpn()], [server('vless')]);
    configure(map);
    const modalParse = vi.fn(async () => 'modal');
    const modal = { parse: modalParse };
    configure(modal);
    expect(await modal.parse()).toBe('modal');
    expect(await map.parse()).toBe('parsed');
    expect(originalParse).toHaveBeenCalledTimes(1);
    expect(modalParse).toHaveBeenCalledTimes(1);
  });

  it('does nothing until a successful parse, so dismissal does not disable servers', () => {
    const inbound = server('vless');
    const { uci, ui } = setup([vpn()], [inbound]);
    expect(inbound.enabled).toBe('1');
    expect(uci.set).not.toHaveBeenCalled();
    expect(ui.addNotification).not.toHaveBeenCalled();
  });

  it('restores the notification after page reload until explicitly dismissed', async () => {
    const first = setup([vpn()], [server('vless')]);
    await first.map.parse();
    const reloaded = setup([], [], undefined, first.storage);
    reloaded.restore();
    reloaded.restore();
    expect(reloaded.ui.addNotification).toHaveBeenCalledTimes(1);
    expect(
      reloaded.ui.addNotification.mock.calls[0][1].children[0].children,
    ).toContain('vless');
    reloaded.notifications[0].dismiss();
    expect(first.storage.size).toBe(0);
    const dismissed = setup([], [], undefined, first.storage);
    dismissed.restore();
    expect(dismissed.ui.addNotification).not.toHaveBeenCalled();
  });

  it('keeps separate section notices and replaces repeated events for the same section', async () => {
    const section = vpn();
    const inbound = server('vless');
    const other = server('hysteria', { routing_section: 'other' });
    const test = setup(
      [section, { '.name': 'other', enabled: '0' }],
      [inbound, other],
    );
    await test.map.parse();
    inbound.enabled = '1';
    await test.map.parse();
    expect(JSON.parse([...test.storage.values()][0])).toHaveLength(2);
    expect(test.notifications.filter((node) => !node.dismissed)).toHaveLength(
      2,
    );
    test.notifications.find((node) => node.id.endsWith('other')).dismiss();
    expect(JSON.parse([...test.storage.values()][0])).toHaveLength(1);
  });

  it('ignores corrupt storage and still disables servers if browser storage is blocked', async () => {
    const test = setup([vpn()], [server('vless')]);
    test.storage.set('tachyon:disabled-section-servers:v1', '{broken');
    test.restore();
    expect(test.ui.addNotification).not.toHaveBeenCalled();
    test.window.localStorage.setItem = () => {
      throw new Error('blocked');
    };
    await test.map.parse();
    expect(test.uci.set).toHaveBeenCalledTimes(1);
    expect(test.ui.addNotification).toHaveBeenCalledTimes(1);
  });
});
