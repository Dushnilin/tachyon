import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const source = fs.readFileSync(
  path.resolve(
    path.dirname(fileURLToPath(import.meta.url)),
    '../../../../luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/dns_speed_test.js',
  ),
  'utf8',
);
const module = new Function('baseclass', '_', source)(
  { extend: (value) => value },
  (value) => value,
);

describe('DNS speed test host settings', () => {
  it('normalizes URLs, IDNs and repeated hostnames', () => {
    expect(
      module.normalizeDomains(
        'https://Example.com/games\nexample.com\nhttps://пример.рф/',
      ),
    ).toEqual(['example.com', 'xn--e1afmkfd.xn--p1ai']);
  });
  it.each([
    '',
    'https://user:pass@example.com/',
    'a..example',
    '-a.example',
    '1.1.1.1',
    'localhost',
    'a'.repeat(64) + '.example',
  ])('rejects invalid domain input: %s', (value) => {
    expect(() => module.normalizeDomains(value)).toThrow();
  });
  it('limits the host list to 32 entries', () => {
    expect(() =>
      module.normalizeDomains(
        Array.from({ length: 33 }, (_, i) => `host${i}.example`).join('\n'),
      ),
    ).toThrow();
  });
  it('never displays failure or missing data as a fast response', () => {
    expect(module.formatMs(null)).toBe('Unavailable');
    expect(module.formatMs(NaN)).toBe('Unavailable');
    expect(module.formatMs(48.701)).toBe('48.70 ms');
  });
});

// LuCI builds each DynamicList before attaching the form to the document.
function controllerFixture() {
  const timers = [];
  const element = (tag, attrs = {}, children = []) => {
    const classes = new Set((attrs.class || '').split(' '));
    return {
      tag,
      attrs,
      id: attrs.id || '',
      isConnected: false,
      children: Array.isArray(children) ? children : [children],
      classList: {
        add: (name) => classes.add(name),
        toggle: (name, enabled) =>
          enabled ? classes.add(name) : classes.delete(name),
        contains: (name) => classes.has(name),
      },
      addEventListener: vi.fn(),
      setAttribute: vi.fn(),
      appendChild(child) {
        this.children.push(child);
      },
      querySelector(selector) {
        return this.children.find((child) =>
          selector === 'input[type="hidden"]'
            ? child.tag === 'input'
            : child.classList?.contains(selector.slice(1)),
        );
      },
      querySelectorAll() {
        return this.children;
      },
    };
  };
  const domains = ['example.com'];
  let state = { domains, running: false, results: [] };
  const exec = vi.fn(async () => ({ code: 0, stdout: JSON.stringify(state) }));
  const loaded = new Function(
    'baseclass',
    '_',
    'E',
    'window',
    'MutationObserver',
    'fs',
    source,
  )(
    { extend: (value) => value },
    (value) => value,
    element,
    {
      localStorage: { getItem: () => JSON.stringify(domains) },
      setTimeout: (fn) => timers.push(fn),
    },
    class {
      observe() {}
    },
    { exec },
  );
  const controller = loaded.createController();
  const toolbar = controller.renderToolbar(() => ({ protocol: 'doh' }));
  const list = (id, value) =>
    element('div', { id }, [element('div', {}, [{ tag: 'input', value }])]);
  const result = (server, median) => ({
    server,
    stats: { median, success: 1, total: 1 },
  });
  return {
    controller,
    toolbar,
    list,
    result,
    exec,
    poll: async (results) => {
      state = { ...state, results };
      toolbar.isConnected = true;
      await timers.shift()();
    },
    button: (node) =>
      node.children[0].querySelector('.tachyon-dns-speed-value'),
  };
}

describe('DNS speed test DynamicList lifecycle', () => {
  const originalFormat = Object.getOwnPropertyDescriptor(
    String.prototype,
    'format',
  );
  beforeAll(() =>
    Object.defineProperty(String.prototype, 'format', {
      configurable: true,
      value(...args) {
        let i = 0;
        return this.replace(/%s/g, () => args[i++]);
      },
    }),
  );
  afterAll(() => {
    if (originalFormat)
      Object.defineProperty(String.prototype, 'format', originalFormat);
    else delete String.prototype.format;
  });
  it('updates primary, bootstrap and fallback lists built off-document', async () => {
    const f = controllerFixture();
    const lists = [
      f.list('primary', 'https://dns.example/query'),
      f.list('bootstrap', '1.1.1.1'),
      f.list('fallback', '8.8.8.8'),
    ];
    lists.forEach((node, i) =>
      f.controller.attachList(node, { alwaysEnabled: i > 0 }),
    );
    lists.forEach((node) => {
      node.isConnected = true;
    });
    await f.poll(
      lists.map((node, i) =>
        f.result(node.children[0].children[0].value, 10 + i),
      ),
    );
    expect(lists.map((node) => f.button(node).textContent)).toEqual([
      '10.00 ms',
      '11.00 ms',
      '12.00 ms',
    ]);
    expect(lists.every((node) => !f.button(node).disabled)).toBe(true);
  });

  it('replaces a rerendered field without discarding other detached lists', async () => {
    const f = controllerFixture();
    const old = f.list('primary', 'old.example');
    const other = f.list('bootstrap', '1.1.1.1');
    const current = f.list('primary', 'new.example');
    [old, other, current].forEach((node) => f.controller.attachList(node));
    await f.poll([
      f.result('old.example', 99),
      f.result('new.example', 12),
      f.result('1.1.1.1', 13),
    ]);
    expect(f.button(old).textContent).toBe('—');
    expect(f.button(current).textContent).toBe('12.00 ms');
    expect(f.button(other).textContent).toBe('13.00 ms');
  });
});
