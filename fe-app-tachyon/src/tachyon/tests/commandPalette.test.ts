/* eslint-disable @typescript-eslint/no-explicit-any */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { store } from '../services/store.service';

function createMockElement(tag: string): any {
  const attrs: Record<string, string> = {};
  const listeners: Record<string, Array<(ev: any) => void>> = {};
  const el: any = {
    tagName: tag.toUpperCase(),
    parentElement: null as any,
    children: [] as any[],
    style: { cssText: '' },
    className: '',
    value: '',
    _text: '',
    get textContent(): string {
      if (el._text) return el._text;
      return el.children.map((c: any) => c.textContent || '').join('');
    },
    set textContent(v: string) {
      el._text = String(v);
    },
    focus: vi.fn(),
    setAttribute(k: string, v: string) {
      attrs[k] = String(v);
      if (k === 'class') el.className = String(v);
    },
    getAttribute(k: string) {
      if (k === 'class') return el.className || attrs.class || null;
      return k in attrs ? attrs[k] : null;
    },
    addEventListener(type: string, cb: (ev: any) => void) {
      if (!listeners[type]) listeners[type] = [];
      listeners[type].push(cb);
    },
    triggerInput(val: string) {
      el.value = String(val);
      for (const fn of listeners.input || []) fn({ target: el });
    },
    dispatchKey(key: string, extra: Record<string, any> = {}) {
      const ev = {
        key,
        code: extra.code || '',
        ctrlKey: Boolean(extra.ctrlKey),
        metaKey: Boolean(extra.metaKey),
        preventDefault: vi.fn(),
      };
      for (const fn of listeners.keydown || []) fn(ev);
      return ev;
    },
    appendChild(child: any) {
      if (child != null) {
        child.parentElement = el;
        el.children.push(child);
      }
      return child;
    },
    replaceChildren(...nodes: any[]) {
      el._text = '';
      el.children = [];
      for (const n of nodes) el.appendChild(n);
    },
    remove() {
      if (el.parentElement) {
        el.parentElement.children = el.parentElement.children.filter(
          (c: any) => c !== el,
        );
      }
      el.parentElement = null;
    },
    querySelectorAll(sel: string): any[] {
      const out: any[] = [];
      const visit = (node: any) => {
        for (const ch of node.children || []) {
          if (sel.startsWith('#') && ch.getAttribute?.('id') === sel.slice(1)) {
            out.push(ch);
          } else if (
            sel.startsWith('.') &&
            String(ch.className || '')
              .split(/\s+/)
              .includes(sel.slice(1))
          ) {
            out.push(ch);
          }
          visit(ch);
        }
      };
      visit(el);
      return out;
    },
    querySelector(sel: string) {
      return el.querySelectorAll(sel)[0] || null;
    },
  };
  return el;
}

describe('commandPalette', () => {
  const docListeners: Record<string, Array<(ev: any) => void>> = {};
  let bodyEl: any;
  const storage = new Map<string, string>();

  beforeEach(() => {
    vi.resetModules();
    storage.clear();
    for (const k of Object.keys(docListeners)) delete docListeners[k];
    bodyEl = createMockElement('body');

    (globalThis as any).localStorage = {
      getItem: (k: string) => storage.get(k) ?? null,
      setItem: (k: string, v: string) => storage.set(k, String(v)),
      removeItem: (k: string) => storage.delete(k),
    };
    (globalThis as any).document = {
      documentElement: {
        lang: 'ru',
        style: { setProperty: () => {} },
        setAttribute: () => {},
      },
      body: bodyEl,
      createElement: (tag: string) => createMockElement(tag),
      createTextNode: (t: string) => ({
        tagName: '#TEXT',
        textContent: String(t),
        children: [],
      }),
      addEventListener: (type: string, cb: (ev: any) => void) => {
        if (!docListeners[type]) docListeners[type] = [];
        docListeners[type].push(cb);
      },
      querySelector: () => null,
    };
    (globalThis as any).uci = {
      sections: (_pkg: string, type: string) => {
        if (type === 'section') {
          return [{ '.name': 'MAIN', label: 'Основной маршрут' }];
        }
        if (type === 'balancer') {
          return [{ '.name': 'b1', name: 'Автовыбор Европы' }];
        }
        return [];
      },
    };
  });

  afterEach(() => {
    delete (globalThis as any).localStorage;
    delete (globalThis as any).document;
    delete (globalThis as any).uci;
    store.reset(['sectionsWidget']);
  });

  it('builds humanized node/balancer/theme items and supports filtering & Ctrl+K navigation', async () => {
    store.set({
      sectionsWidget: {
        loading: false,
        failed: false,
        runtimeCached: false,
        latencyFetchingSections: {},
        latencyProgressSections: {},
        selectorSwitchingSections: {},
        subscriptionUpdatingSections: {},
        subscriptionUpdatingTargets: {},
        data: [
          {
            withTagSelect: false,
            code: 'sel-MAIN',
            sectionName: 'MAIN',
            displayName: 'sel-MAIN',
            outbounds: [
              {
                code: 'bal-MAIN-b1',
                displayName: 'bal-MAIN-b1',
                type: 'urltest',
                selected: true,
                latency: 45,
              },
            ],
          },
        ],
      },
    });

    const activated: string[] = [];
    const {
      buildCommandPaletteItems,
      initCommandPalette,
      _resetCommandPaletteForTests,
    } = await import('../commandPalette');
    _resetCommandPaletteForTests();

    const deps = {
      getNavItems: () => [
        {
          key: 'dashboard',
          labelRu: 'Дашборд',
          labelEn: 'Dashboard',
          subtitleRu: 'Статус',
          subtitleEn: 'Status',
        },
      ],
      activateNav: (key: string) => activated.push(key),
      setLayoutWidth: vi.fn(),
    };

    const balancerMatches = buildCommandPaletteItems('Автовыбор', deps);
    expect(balancerMatches.some((i) => i.title === 'Автовыбор Европы')).toBe(
      true,
    );
    expect(balancerMatches.every((i) => !i.title.includes('bal-MAIN-b1'))).toBe(
      true,
    );

    const themeMatches = buildCommandPaletteItems('Dracula', deps);
    expect(themeMatches.some((i) => i.id === 'theme:dracula')).toBe(true);

    initCommandPalette(deps);
    for (const fn of docListeners.keydown || []) {
      fn({ ctrlKey: true, key: 'k', code: 'KeyK', preventDefault: vi.fn() });
    }

    const overlay = bodyEl.querySelector('#tachyon-cmdk-overlay');
    expect(overlay).toBeTruthy();

    const input = overlay.querySelector('#tachyon-cmdk-input');
    input.triggerInput('Дашборд');
    const items = buildCommandPaletteItems('Дашборд', deps);
    expect(items[0].id).toBe('nav:dashboard');

    input.dispatchKey('ArrowDown');
    input.dispatchKey('ArrowUp');
    input.dispatchKey('Enter');
    expect(activated).toEqual(['dashboard']);
    expect(bodyEl.querySelector('#tachyon-cmdk-overlay')).toBeNull();
  });
});
