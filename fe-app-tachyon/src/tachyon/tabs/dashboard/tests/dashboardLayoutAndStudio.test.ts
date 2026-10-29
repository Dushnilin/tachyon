/* eslint-disable @typescript-eslint/no-explicit-any */
import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

const storage = new Map<string, string>();

function createDummyElement(tag: string): any {
  const children: any[] = [];
  const attrs: Record<string, string> = {};
  const listeners: Record<string, Array<(ev: any) => void>> = {};
  const el: any = {
    tagName: tag.toUpperCase(),
    children,
    childNodes: children,
    style: {} as Record<string, string>,
    className: '',
    dataset: {} as Record<string, string>,
    classList: {
      add(c: string) {
        const set = new Set(
          (el.className || el.class || '').split(/\s+/).filter(Boolean),
        );
        set.add(c);
        el.className = Array.from(set).join(' ');
        el.class = el.className;
      },
      remove(c: string) {
        const set = new Set(
          (el.className || el.class || '').split(/\s+/).filter(Boolean),
        );
        set.delete(c);
        el.className = Array.from(set).join(' ');
        el.class = el.className;
      },
      contains(c: string) {
        const list = (el.class || el.className || '').split(/\s+/);
        return list.includes(c);
      },
    },
    get textContent(): string {
      let text = '';
      for (const c of children) {
        if (typeof c === 'string' || typeof c === 'number') {
          text += c;
        } else if (c && typeof c.textContent === 'string') {
          text += c.textContent;
        }
      }
      return text;
    },
    set textContent(val: string) {
      children.length = 0;
      if (val) children.push(val);
    },
    set innerHTML(val: string) {
      children.length = 0;
      if (val) children.push(val);
    },
    get innerHTML(): string {
      return el.textContent;
    },
    setAttribute(name: string, val: string) {
      attrs[name] = String(val);
      (el as any)[name] = val;
      if (name === 'class') el.className = String(val);
    },
    getAttribute(name: string) {
      return attrs[name] ?? (el as any)[name] ?? null;
    },
    removeAttribute(name: string) {
      delete attrs[name];
      delete (el as any)[name];
    },
    addEventListener(type: string, cb: (ev: any) => void) {
      if (!listeners[type]) listeners[type] = [];
      listeners[type].push(cb);
    },
    appendChild(node: any) {
      if (node !== null && node !== undefined && node !== '') {
        if (typeof node === 'object') {
          node.parentNode = el;
        }
        children.push(node);
      }
      return node;
    },
    prepend(node: any) {
      if (node !== null && node !== undefined && node !== '') {
        if (typeof node === 'object') {
          node.parentNode = el;
        }
        children.unshift(node);
      }
    },
    insertBefore(newNode: any, refNode: any) {
      if (newNode && typeof newNode === 'object') {
        newNode.parentNode = el;
      }
      const idx = children.indexOf(refNode);
      if (idx >= 0) children.splice(idx, 0, newNode);
      else children.push(newNode);
      return newNode;
    },
    remove() {
      if (el.parentNode && Array.isArray(el.parentNode.children)) {
        const i = el.parentNode.children.indexOf(el);
        if (i >= 0) el.parentNode.children.splice(i, 1);
      }
    },
    get firstChild() {
      return children[0] || null;
    },
    cloneNode() {
      return createDummyElement(tag);
    },
    querySelectorAll(selector: string): any[] {
      const results: any[] = [];
      function traverse(node: any) {
        if (!node || typeof node !== 'object') return;
        if (selector.startsWith('.')) {
          const targetClasses = selector.split('.').filter(Boolean);
          const classes = (node.class || node.className || '').split(/\s+/);
          if (targetClasses.every((tc: string) => classes.includes(tc))) {
            results.push(node);
          }
        }
        if (Array.isArray(node.children)) {
          for (const child of node.children) {
            traverse(child);
          }
        }
      }
      traverse(el);
      return results;
    },
    querySelector(selector: string): any {
      return el.querySelectorAll(selector)[0] || null;
    },
  };
  return el;
}

globalThis.document = {
  body: createDummyElement('body'),
  createElement: (tag: string) => createDummyElement(tag),
  createElementNS: (_ns: string, tag: string) => createDummyElement(tag),
  querySelectorAll: () => [],
  querySelector: () => null,
  getElementById: () => null,
} as any;

(globalThis as any).localStorage = {
  getItem: (k: string) => storage.get(k) ?? null,
  setItem: (k: string, v: string) => storage.set(k, String(v)),
};

const uciState: Record<string, Record<string, any>> = {
  settings: { '.type': 'settings', '.name': 'settings' },
  Main: {
    '.type': 'section',
    '.name': 'Main',
    enabled: '1',
    action: 'connection',
    outbound_source_refs: ['src_vitalik', 'src_links'],
  },
  src_vitalik: {
    '.type': 'outbound_source',
    '.name': 'src_vitalik',
    enabled: '1',
    name: 'Vitalik',
    source_type: 'subscription',
    url: 'https://vitalik.one/sub/token',
  },
  src_links: {
    '.type': 'outbound_source',
    '.name': 'src_links',
    enabled: '1',
    name: 'DirectLinks',
    source_type: 'proxy_links',
    proxy_links: [
      'vless://uuid@example.com:443?type=grpc&security=reality#Node1',
      'vless://uuid@example.com:443?type=xhttp&security=reality#Node2',
    ],
  },
};

(globalThis as any).uci = {
  get: vi.fn((_pkg: string, sid: string, opt?: string) => {
    const sec = uciState[sid];
    if (!sec) return null;
    if (!opt) return sec;
    return sec[opt] ?? null;
  }),
  set: vi.fn((_pkg: string, sid: string, opt: string, val: any) => {
    if (!uciState[sid]) uciState[sid] = { '.name': sid };
    uciState[sid][opt] = val;
  }),
  sections: vi.fn((_pkg: string, type: string) =>
    Object.values(uciState).filter((s) => s['.type'] === type),
  ),
  save: vi.fn().mockResolvedValue(undefined),
};

(globalThis as any).E = (tag: string, attrs?: any, children?: any) => {
  const el = createDummyElement(tag);
  if (attrs && typeof attrs === 'object' && !Array.isArray(attrs)) {
    Object.entries(attrs).forEach(([k, v]) => {
      if (k === 'click' && typeof v === 'function') {
        el.addEventListener('click', v);
      } else {
        el.setAttribute(k, String(v));
      }
    });
  }
  const childList =
    attrs && (Array.isArray(attrs) || typeof attrs === 'string')
      ? attrs
      : children;
  if (childList !== undefined && childList !== null) {
    const arr = Array.isArray(childList) ? childList : [childList];
    for (const c of arr) {
      if (c !== null && c !== undefined && c !== '') {
        el.appendChild(c);
      }
    }
  }
  return el;
};

let dashboardLayoutMod: any;
let renderOverviewMod: any;
let studioDeckMod: any;

describe('Dashboard Widgets, Presets, Transport Badges & Studio Deck', () => {
  beforeAll(async () => {
    dashboardLayoutMod = await import('../dashboardLayout');
    renderOverviewMod = await import('../partials/renderOverviewRow');
    studioDeckMod = await import('../../../studioDeck');
  });

  beforeEach(() => {
    storage.clear();
    delete uciState.settings.dashboard_layout_json;
  });

  it('defines 5 distinct dashboard presets and 7 widgets with 4-5 views each', () => {
    expect(dashboardLayoutMod.DASHBOARD_PRESETS).toHaveLength(5);
    expect(dashboardLayoutMod.DASHBOARD_WIDGET_CATALOG).toHaveLength(7);
    for (const widget of dashboardLayoutMod.DASHBOARD_WIDGET_CATALOG) {
      expect(widget.views.length).toBeGreaterThanOrEqual(4);
    }

    const stdCfg = dashboardLayoutMod.applyDashboardPreset('standard');
    expect(stdCfg.widgets.map((w: any) => w.id)).toEqual([
      'kpi',
      'traffic_chart',
      'system_status',
      'router_services',
      'inbounds',
      'active_clients',
      'routing_sections',
    ]);

    const commandCfg =
      dashboardLayoutMod.applyDashboardPreset('command_center');
    expect(commandCfg.preset).toBe('command_center');
    expect(dashboardLayoutMod.getWidgetViewMode('kpi', commandCfg)).toBe(
      'compact_strip',
    );

    const bentoCfg = dashboardLayoutMod.applyDashboardPreset('bento_cards');
    expect(bentoCfg.preset).toBe('bento_cards');
    expect(
      dashboardLayoutMod.getWidgetViewMode('routing_sections', bentoCfg),
    ).toBe('cards_grid');
  });

  it('shows VLESS + GRPC + XHTTP transport badges, green LED status dot, and fixes Main subtitle', () => {
    const blocks = renderOverviewMod.renderDashboardSectionsAndNodes({
      sections: [
        {
          code: 'Discord',
          sectionName: 'Discord',
          displayName: 'Discord',
          action: 'desync',
          outbounds: [],
          serviceStatus: { ready: true, label: 'Работает' },
          configError: false,
        },
        {
          code: 'Main',
          sectionName: 'Main',
          displayName: 'Main',
          action: 'connection',
          outbounds: [
            {
              code: 'vless-grpc-1',
              displayName: 'NL Amsterdam 1',
              type: 'vless',
              transport: 'grpc',
              selected: true,
              latency: 42,
              group: 'sub',
            },
            {
              code: 'vless-xhttp-2',
              displayName: 'DE Frankfurt 2',
              type: 'vless',
              link: 'vless://id@host:443?type=xhttp#DE',
              selected: false,
              latency: 55,
              group: 'sub',
            },
          ],
          configError: false,
        },
      ],
      selectedSectionCode: 'Main',
      onSelectSection: vi.fn(),
      getSectionStats: () => ({
        download: 0,
        upload: 0,
        downloadSpeed: 0,
        uploadSpeed: 0,
      }),
      isTestingAllSections: false,
      onTestAllSections: vi.fn(),
      latencyFetchingSections: {},
      onTestSectionLatency: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowPriorityInfo: vi.fn(),
    });

    const wrap = createDummyElement('div');
    blocks.forEach((b: any) => wrap.appendChild(b));

    const allText = wrap.textContent;
    // Main should NOT be misclassified as AI ("Нейросети и ИИ-платформы")
    expect(allText).not.toContain('Нейросети и ИИ-платформы');
    // Transport badges GRPC and XHTTP should appear alongside VLESS
    const transportBadges = wrap
      .querySelectorAll('.tachyon-routing-row__engine-badge--transport')
      .map((b: any) => b.textContent);
    expect(transportBadges).toContain('GRPC');
    expect(transportBadges).toContain('XHTTP');

    // Green glowing LED dot should be rendered instead of "● Работает" text
    expect(allText).not.toContain('● Работает');
    const onlineDots = wrap.querySelectorAll(
      '.tachyon-routing-row__status-dot.is-online',
    );
    expect(onlineDots.length).toBeGreaterThanOrEqual(2);
  });

  it('mounts Tachyon Studio Deck on GridSection containers and hides legacy Forkop tables', () => {
    const containerEl = createDummyElement('div');
    const mockSectionRef = {
      sectiontype: 'section',
      cfgsections: () => ['Main'],
      renderMoreOptionsModal: vi.fn(),
      remove: vi.fn(),
    };

    studioDeckMod.mountTachyonStudioDeck({
      type: 'section',
      sectionRef: mockSectionRef,
      containerEl,
    });

    expect(containerEl.classList.contains('tachyon-has-studio-deck')).toBe(
      true,
    );
    const deck = containerEl.querySelector('.tachyon-studio-deck');
    expect(deck).not.toBeNull();
    expect(deck.textContent).toContain('Main');
    expect(deck.textContent).toContain('VLESS');
    expect(deck.textContent).toContain('GRPC');
    expect(deck.textContent).toContain('XHTTP');
  });
});
