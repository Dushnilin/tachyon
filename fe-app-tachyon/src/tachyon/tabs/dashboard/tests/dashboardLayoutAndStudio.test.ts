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
      if (name === 'style') {
        el.style.cssText = String(val);
        return;
      }
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
    click() {
      const cbs = listeners.click || [];
      cbs.forEach((fn) => fn({ preventDefault() {}, stopPropagation() {} }));
    },
    focus() {},
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

  it('excludes block, bypass, and dns sections from routing sections block on dashboard', () => {
    const onSelectSection = vi.fn();
    const blocks = renderOverviewMod.renderDashboardSectionsAndNodes({
      sections: [
        {
          code: 'block',
          sectionName: 'block',
          displayName: 'block',
          action: 'block',
          serviceStatus: { serviceType: 'block', enabled: true },
          outbounds: [],
          configError: false,
        },
        {
          code: 'ByPass',
          sectionName: 'ByPass',
          displayName: 'ByPass',
          action: 'bypass',
          serviceStatus: { serviceType: 'bypass', enabled: true },
          outbounds: [],
          configError: false,
        },
        {
          code: 'YandexDns',
          sectionName: 'YandexDns',
          displayName: 'YandexDns',
          action: 'dns',
          serviceStatus: { serviceType: 'dns', enabled: true },
          outbounds: [],
          configError: false,
        },
        {
          code: 'dns-ai',
          sectionName: 'dns-ai',
          displayName: 'dns-ai',
          action: 'dns',
          serviceStatus: { serviceType: 'dns', enabled: true },
          outbounds: [],
          configError: false,
        },
        {
          code: 'Youtube',
          sectionName: 'Youtube',
          displayName: 'Youtube',
          action: 'desync',
          outbounds: [],
          configError: false,
        },
        {
          code: 'Discord',
          sectionName: 'Discord',
          displayName: 'Discord',
          action: 'desync',
          outbounds: [],
          configError: false,
        },
        {
          code: 'media_dpi',
          sectionName: 'media_dpi',
          displayName: 'Core Desync (Direct)',
          action: 'desync',
          outbounds: [],
          configError: false,
        },
        {
          code: 'Geo_block',
          sectionName: 'Geo_block',
          displayName: 'Geo Block',
          action: 'connection',
          outbounds: [
            {
              code: 'geo-vless',
              displayName: 'NL Rotterdam',
              type: 'vless',
              selected: true,
              latency: 40,
            },
          ],
        },
      ],
      selectedSectionCode: 'Youtube',
      onSelectSection,
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

    const sectionNames = wrap
      .querySelectorAll('.tachyon-routing-row__name')
      .map((el: any) => el.textContent);

    expect(sectionNames).toEqual([
      'Youtube',
      'Discord',
      'Core Desync (Direct)',
      'Geo Block',
    ]);
    expect(sectionNames).toContain('Core Desync (Direct)');
    expect(sectionNames).not.toContain('block');
    expect(sectionNames).not.toContain('ByPass');
    expect(sectionNames).not.toContain('YandexDns');
    expect(sectionNames).not.toContain('dns-ai');
    expect(wrap.textContent).toContain('NL Rotterdam');
    let geoRow = wrap
      .querySelectorAll('.tachyon-routing-row__name')
      .find((node: any) => node.textContent === 'Geo Block');
    while (
      geoRow &&
      geoRow.getAttribute('data-section-row-metrics') !== 'Geo_block'
    ) {
      geoRow = geoRow.parentNode;
    }
    expect(geoRow).toBeDefined();
    geoRow.click();
    expect(onSelectSection).toHaveBeenCalledWith('Geo_block');
  });

  it.each([
    ['Geo_block', 'Geo Block'],
    ['proxy', 'Geo Block'],
    ['block', 'Proxy'],
    ['reject', 'Proxy'],
    ['dns_proxy', 'Proxy'],
    ['direct', 'Proxy'],
    ['desync_proxy', 'Proxy'],
  ])(
    'classifies connection section %s (%s) by its action',
    (sectionName, displayName) => {
      expect(
        renderOverviewMod.resolveSectionCategory({
          code: sectionName,
          sectionName,
          displayName,
          action: 'connection',
          outbounds: [{ code: 'vless-node', type: 'vless', selected: true }],
        }),
      ).toBe('proxy');
    },
  );

  it.each([
    ['DESYNC', 'dpi'],
    ['BLOCK', 'block'],
    ['DNS', 'dns'],
    ['DIRECT', 'direct'],
  ])(
    'keeps connection sections with a %s engine in the %s category',
    (type, category) => {
      expect(
        renderOverviewMod.resolveSectionCategory({
          code: 'service',
          sectionName: 'service',
          displayName: 'Service',
          action: 'connection',
          outbounds: [{ code: 'service-node', type, selected: true }],
        }),
      ).toBe(category);
    },
  );

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

  it('triggers showServerInfoModal when clicking QR / Client Link on server Studio Deck card', async () => {
    const inboundServersMod = await import('../inboundServers');
    const showServerInfoModalMock = vi.fn();
    const containerEl = createDummyElement('div');
    const mockServerSectionRef = {
      sectiontype: 'server',
      cfgsections: () => ['TewFai'],
      renderMoreOptionsModal: vi.fn(),
      remove: vi.fn(),
    };

    inboundServersMod.registerServerSectionController(mockServerSectionRef, {
      showServerInfoModal: showServerInfoModalMock,
    });

    (globalThis as any).uci.get = (
      _pkg: string,
      sec: string,
      opt?: string,
    ): any => {
      const serverData: Record<string, any> = {
        '.name': 'TewFai',
        '.type': 'server',
        enabled: '1',
        name: 'TewFai',
        protocol: 'tewfai',
        listen_port: '8443',
      };
      if (sec === 'TewFai') {
        return opt ? serverData[opt] : serverData;
      }
      return undefined;
    };

    studioDeckMod.mountTachyonStudioDeck({
      type: 'server',
      sectionRef: mockServerSectionRef,
      containerEl,
    });

    const actionBtns = containerEl.querySelectorAll(
      '.tachyon-studio-action-btn',
    );
    expect(actionBtns.length).toBeGreaterThanOrEqual(2);
    const qrBtn = actionBtns[0];
    qrBtn.click();

    expect(showServerInfoModalMock).toHaveBeenCalledWith('TewFai');
    expect(mockServerSectionRef.renderMoreOptionsModal).not.toHaveBeenCalled();
  });

  it('correctly filters dashboard routing section types and updates upon config change', async () => {
    const layoutMod = await import('../dashboardLayout');
    const { resolveSectionCategory } = await import(
      '../partials/renderOverviewRow'
    );

    // Default filters
    const filter = layoutMod.getDashboardSectionTypeFilter();
    expect(filter.proxy).toBe(true);
    expect(filter.dpi).toBe(true);
    expect(filter.dns).toBe(false);
    expect(filter.direct).toBe(false);
    expect(filter.block).toBe(false);

    // Classification
    expect(
      resolveSectionCategory({ action: 'block', '.name': 'block' } as any),
    ).toBe('block');
    expect(
      resolveSectionCategory({ action: 'bypass', '.name': 'ByPass' } as any),
    ).toBe('direct');
    expect(
      resolveSectionCategory({ action: 'dns', '.name': 'YandexDns' } as any),
    ).toBe('dns');
    expect(
      resolveSectionCategory({ action: 'desync', '.name': 'yt' } as any),
    ).toBe('dpi');
    expect(
      resolveSectionCategory({
        action: 'proxy',
        protocol: 'vless',
        '.name': 'main',
      } as any),
    ).toBe('proxy');

    // Update filter
    layoutMod.saveDashboardSectionTypeFilter({
      ...filter,
      dns: true,
      block: true,
    });

    const updated = layoutMod.getDashboardSectionTypeFilter();
    expect(updated.dns).toBe(true);
    expect(updated.block).toBe(true);
    expect(updated.direct).toBe(false);
  });

  it('does not render comment lines as domain chips on condition Studio Deck card', async () => {
    const containerEl = createDummyElement('div');
    const mockCondSectionRef = {
      sectiontype: 'condition',
      cfgsections: () => ['main_cond'],
      renderMoreOptionsModal: vi.fn(),
      remove: vi.fn(),
    };

    (globalThis as any).uci.sections = (_pkg: string, type: string) => {
      if (type === 'section') {
        return [
          {
            '.name': 'main_sec',
            name: 'Main',
            condition_refs: ['main_cond'],
          },
        ];
      }
      return [];
    };

    (globalThis as any).uci.get = (
      _pkg: string,
      sec: string,
      opt?: string,
    ): any => {
      const condData: Record<string, any> = {
        '.name': 'main_cond',
        '.type': 'condition',
        name: 'Main',
        enabled: '1',
        condition_type: 'atomic',
        community_lists: ['ru_blocked_all'],
        domain: `// ====== Xiaomi ======
Xiaomi
Mi
xiaomi.com`,
      };
      if (sec === 'main_cond') {
        return opt ? condData[opt] : condData;
      }
      return undefined;
    };

    studioDeckMod.mountTachyonStudioDeck({
      type: 'condition',
      sectionRef: mockCondSectionRef,
      containerEl,
    });

    const chips = containerEl.querySelectorAll('.tachyon-studio-chip');
    const chipTexts = chips.map((c: any) => c.textContent.trim());

    // Should NOT contain comments or separator symbols
    expect(chipTexts.some((t: string) => t.includes('//'))).toBe(false);
    expect(chipTexts.some((t: string) => t.includes('======'))).toBe(false);

    // Should contain valid domain entries and service list
    expect(chipTexts.some((t: string) => t.includes('ru_blocked_all'))).toBe(
      true,
    );
    expect(chipTexts.some((t: string) => t.includes('Xiaomi'))).toBe(true);
    expect(chipTexts.some((t: string) => t.includes('Mi'))).toBe(true);
  });

  it('does not trigger fs.read_direct CGI requests for missing section-cache files with many sections (#351)', async () => {
    const containerEl = createDummyElement('div');
    const mockOutboundRef = {
      sectiontype: 'outbound_source',
      cfgsections: () => ['sub1'],
      renderMoreOptionsModal: vi.fn(),
      remove: vi.fn(),
    };

    const manySections = Array.from({ length: 18 }, (_, idx) => ({
      '.name': `sec_${idx + 1}`,
      '.type': 'section',
      name: `Section_${idx + 1}`,
      enabled: '1',
      action: idx < 2 ? 'proxy' : 'direct',
    }));

    (globalThis as any).uci.sections = (_pkg: string, type: string) => {
      if (type === 'section') return manySections;
      if (type === 'outbound_source') {
        return [
          {
            '.name': 'sub1',
            '.type': 'outbound_source',
            name: 'Sub One',
            source_type: 'subscription',
            url: 'https://sub.example/list',
          },
        ];
      }
      return [];
    };

    const fsReadMock = vi.fn((path: string) => {
      if (
        path === '/var/run/tachyon/section-cache/Main.json' ||
        path === '/var/run/tachyon/section-cache/Section_1.json'
      ) {
        return Promise.resolve(
          JSON.stringify({
            outboundMetadata: {
              names: { 'sub1-node-1': 'DE Frankfurt' },
              protocols: { 'sub1-node-1': 'vless' },
              source_ids: { 'sub1-node-1': 'sub1' },
            },
          }),
        );
      }
      const err: any = new Error('No such file or directory');
      err.name = 'NotFoundError';
      return Promise.reject(err);
    });
    const fsReadDirectMock = vi.fn(() => Promise.resolve(''));
    const fsListMock = vi.fn((dir: string) => {
      if (dir === '/var/run/tachyon/section-cache') {
        return Promise.resolve([
          { name: 'Main.json', type: 'file' },
          { name: 'Section_1.json', type: 'file' },
        ]);
      }
      return Promise.resolve([]);
    });

    (globalThis as any).fs = {
      ...(globalThis as any).fs,
      read: fsReadMock,
      read_direct: fsReadDirectMock,
      list: fsListMock,
    };

    studioDeckMod.mountTachyonStudioDeck({
      type: 'outbound_source',
      sectionRef: mockOutboundRef,
      containerEl,
    });

    await new Promise((resolve) => setTimeout(resolve, 20));

    expect(fsListMock).toHaveBeenCalledWith('/var/run/tachyon/section-cache');
    expect(fsReadDirectMock).not.toHaveBeenCalled();
    const sectionCacheReads = fsReadMock.mock.calls
      .map((c) => String(c[0]))
      .filter((p) => p.startsWith('/var/run/tachyon/section-cache/'));
    expect(sectionCacheReads).toEqual([
      '/var/run/tachyon/section-cache/Main.json',
      '/var/run/tachyon/section-cache/Section_1.json',
    ]);
  });

  it('shows warning banner when block or bypass section is placed below other routing sections', () => {
    // 1. Correct order (block & bypass at top): no warning
    const okIssues = renderOverviewMod.detectMisorderedPolicySections([
      {
        code: 'block',
        sectionName: 'block',
        displayName: 'Block Ads',
        action: 'block',
        outbounds: [],
      },
      {
        code: 'ByPass',
        sectionName: 'ByPass',
        displayName: 'RU Direct',
        action: 'bypass',
        outbounds: [],
      },
      {
        code: 'YandexDns',
        sectionName: 'YandexDns',
        displayName: 'YandexDns',
        action: 'dns',
        outbounds: [],
      },
      {
        code: 'Main',
        sectionName: 'Main',
        displayName: 'Main Proxy',
        action: 'connection',
        outbounds: [],
      },
    ]);
    expect(okIssues).toEqual([]);

    // 2. Misordered: block and bypass placed after Main Proxy and Youtube desync
    const misorderedSections = [
      {
        code: 'Main',
        sectionName: 'Main',
        displayName: 'Main Proxy',
        action: 'connection',
        outbounds: [
          {
            code: 'node-1',
            displayName: 'NL 1',
            type: 'vless',
            selected: true,
            latency: 40,
          },
        ],
      },
      {
        code: 'Youtube',
        sectionName: 'Youtube',
        displayName: 'Youtube',
        action: 'desync',
        outbounds: [],
      },
      {
        code: 'ByPass',
        sectionName: 'ByPass',
        displayName: 'RU Direct',
        action: 'bypass',
        outbounds: [],
      },
      {
        code: 'block',
        sectionName: 'block',
        displayName: 'Block Telemetry',
        action: 'block',
        outbounds: [],
      },
    ];

    const detected =
      renderOverviewMod.detectMisorderedPolicySections(misorderedSections);
    expect(detected).toHaveLength(2);
    expect(detected[0]).toMatchObject({
      sectionName: 'ByPass',
      displayName: 'RU Direct',
      kind: 'bypass',
    });
    expect(detected[1]).toMatchObject({
      sectionName: 'block',
      displayName: 'Block Telemetry',
      kind: 'block',
    });

    const blocks = renderOverviewMod.renderDashboardSectionsAndNodes({
      sections: misorderedSections,
      selectedSectionCode: '',
      onSelectSection: vi.fn(),
      getSectionStats: () => ({
        download: 0,
        upload: 0,
        downloadSpeed: 0,
        uploadSpeed: 0,
        conns: 0,
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

    const warnings = wrap.querySelectorAll('.tachyon-section-order-warning');
    expect(warnings.length).toBe(1);
    expect(warnings[0].textContent).toContain(
      'Block / Bypass section priority violated',
    );
    expect(warnings[0].textContent).toContain('RU Direct');
    expect(warnings[0].textContent).toContain('Block Telemetry');
    expect(warnings[0].textContent).toContain('Main Proxy');
    expect(warnings[0].textContent).toContain('Youtube');
    expect(warnings[0].textContent).toContain('Move above');
    expect(warnings[0].textContent).toContain('To sections');
  });

  it('ignores disabled block/bypass or disabled routing sections and builds singular/plural reorder plans', () => {
    // Disabled block section after Main Proxy must not trigger warning
    const disabledOnly = renderOverviewMod.analyzePolicySectionPriority([
      {
        code: 'Main',
        sectionName: 'Main',
        displayName: 'Main Proxy',
        action: 'connection',
        outbounds: [],
      },
      {
        code: 'block',
        sectionName: 'block',
        displayName: 'Block Ads',
        action: 'block',
        enabled: '0',
        outbounds: [],
      },
    ]);
    expect(disabledOnly.issues).toEqual([]);
    expect(disabledOnly.moves).toEqual([]);

    // Disabled routing section before block must not trigger warning
    const disabledRoute = renderOverviewMod.analyzePolicySectionPriority([
      {
        code: 'OldVpn',
        sectionName: 'OldVpn',
        displayName: 'Old VPN',
        action: 'connection',
        enabled: '0',
        outbounds: [],
      },
      {
        code: 'block',
        sectionName: 'block',
        displayName: 'block',
        action: 'block',
        outbounds: [],
      },
    ]);
    expect(disabledRoute.issues).toEqual([]);

    // Singular violation after multiple routing sections (Discord, YouTube)
    const singular = renderOverviewMod.analyzePolicySectionPriority([
      {
        code: 'discord',
        sectionName: 'discord',
        displayName: 'Discord',
        action: 'connection',
        outbounds: [],
      },
      {
        code: 'youtube',
        sectionName: 'youtube',
        displayName: 'YouTube',
        action: 'connection',
        outbounds: [],
      },
      {
        code: 'block',
        sectionName: 'block',
        displayName: 'block',
        action: 'block',
        outbounds: [],
      },
    ]);
    expect(singular.misplacedLabels).toEqual(['block']);
    expect(singular.precedingLabels).toEqual(['Discord', 'YouTube']);
    expect(singular.firstRoutingSectionName).toBe('discord');
    expect(singular.moves).toEqual([{ from: 'block', to: 'discord' }]);

    const singularDescEn =
      renderOverviewMod.formatPolicySectionOrderWarningDescription(singular);
    expect(singularDescEn).toContain('Section «block»');
    expect(singularDescEn).toContain('«Discord», «YouTube»');

    const prevLang = (globalThis as any).L?.env?.lang;
    (globalThis as any).L = { env: { lang: 'ru' } };
    try {
      const singularDescRu =
        renderOverviewMod.formatPolicySectionOrderWarningDescription(singular);
      expect(singularDescRu).toContain('Секция «block»');
      expect(singularDescRu).toContain('«Discord», «YouTube»');
    } finally {
      (globalThis as any).L = { env: { lang: prevLang || 'en' } };
    }
  });

  it('reorders UCI sections on Move above click, saves, applies, and disables button while saving', async () => {
    const onMovePolicySectionsAbove = vi.fn();
    const sections = [
      {
        code: 'discord',
        sectionName: 'discord',
        displayName: 'Discord',
        action: 'connection',
        outbounds: [],
      },
      {
        code: 'youtube',
        sectionName: 'youtube',
        displayName: 'YouTube',
        action: 'connection',
        outbounds: [],
      },
      {
        code: 'block',
        sectionName: 'block',
        displayName: 'block',
        action: 'block',
        outbounds: [],
      },
    ];

    const blocks = renderOverviewMod.renderDashboardSectionsAndNodes({
      sections,
      selectedSectionCode: '',
      onSelectSection: vi.fn(),
      getSectionStats: () => ({
        download: 0,
        upload: 0,
        downloadSpeed: 0,
        uploadSpeed: 0,
        conns: 0,
      }),
      isTestingAllSections: false,
      onTestAllSections: vi.fn(),
      latencyFetchingSections: {},
      onTestSectionLatency: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowPriorityInfo: vi.fn(),
      onMovePolicySectionsAbove,
      isMovingPolicySections: false,
    });
    const wrap = createDummyElement('div');
    blocks.forEach((b: any) => wrap.appendChild(b));

    const moveBtn = wrap
      .querySelectorAll('.tachyon-section-order-warning__btn')
      .find((b: any) => b.textContent.includes('Move above'));
    expect(moveBtn).toBeDefined();
    moveBtn.click({ preventDefault: vi.fn(), stopPropagation: vi.fn() });
    expect(onMovePolicySectionsAbove).toHaveBeenCalledWith([
      { from: 'block', to: 'discord' },
    ]);

    // Busy state disables button to prevent double clicks
    const busyBlocks = renderOverviewMod.renderDashboardSectionsAndNodes({
      sections,
      selectedSectionCode: '',
      onSelectSection: vi.fn(),
      getSectionStats: () => ({
        download: 0,
        upload: 0,
        downloadSpeed: 0,
        uploadSpeed: 0,
        conns: 0,
      }),
      isTestingAllSections: false,
      onTestAllSections: vi.fn(),
      latencyFetchingSections: {},
      onTestSectionLatency: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowPriorityInfo: vi.fn(),
      onMovePolicySectionsAbove,
      isMovingPolicySections: true,
    });
    const busyWrap = createDummyElement('div');
    busyBlocks.forEach((b: any) => busyWrap.appendChild(b));
    const busyBtn = busyWrap
      .querySelectorAll('.tachyon-section-order-warning__btn')
      .find((b: any) => b.textContent.includes('Moving...'));
    expect(busyBtn).toBeDefined();
    expect(busyBtn.disabled).toBeTruthy();

    // applyPolicySectionPriorityMoves executes uci.move -> uci.save -> ui.changes.apply
    const order = ['discord', 'youtube', 'block', 'bypass'];
    const moveCalls: Array<[string, string, string]> = [];
    const uciMock = {
      sections: vi.fn(() => order.map((name) => ({ '.name': name }))),
      move: vi.fn((pkg: string, from: string, to: string) => {
        moveCalls.push([pkg, from, to]);
        const fromIdx = order.indexOf(from);
        const [item] = order.splice(fromIdx, 1);
        const toIdx = order.indexOf(to);
        order.splice(toIdx, 0, item);
        return true;
      }),
      save: vi.fn().mockResolvedValue(undefined),
    };
    const uiMock = {
      changes: {
        init: vi.fn().mockResolvedValue(undefined),
        apply: vi.fn().mockResolvedValue(undefined),
      },
    };
    const onSuccess = vi.fn().mockResolvedValue(undefined);
    const onNotify = vi.fn();

    const ok = await renderOverviewMod.applyPolicySectionPriorityMoves(
      [
        { from: 'block', to: 'discord' },
        { from: 'bypass', to: 'discord' },
      ],
      { uciObj: uciMock, uiObj: uiMock, onSuccess, onNotify },
    );

    expect(ok).toBe(true);
    expect(moveCalls).toEqual([
      ['tachyon', 'block', 'discord'],
      ['tachyon', 'bypass', 'discord'],
    ]);
    expect(order).toEqual(['block', 'bypass', 'discord', 'youtube']);
    expect(uciMock.save).toHaveBeenCalledTimes(1);
    expect(uiMock.changes.init).toHaveBeenCalledTimes(1);
    expect(uiMock.changes.apply).toHaveBeenCalledWith(true);
    expect(onSuccess).toHaveBeenCalledTimes(1);
    expect(onNotify).toHaveBeenCalledWith(expect.any(String), 'success');
  });

  it('hides sections marked hidden until Show hidden is toggled (#405)', () => {
    const sectionsWithHidden: any[] = [
      {
        code: 'sec_vis-out',
        sectionName: 'sec_vis',
        displayName: 'Visible Section',
        action: 'connection',
        withTagSelect: true,
        outbounds: [
          {
            code: 'n1',
            displayName: 'NL Node',
            type: 'VLESS',
            selected: true,
            latency: 40,
          },
          {
            code: 'n2',
            displayName: 'Hidden Manual',
            type: 'VLESS',
            selected: false,
            latency: 60,
            hidden: true,
          },
        ],
      },
      {
        code: 'sec_hid-out',
        sectionName: 'sec_hid',
        displayName: 'Secret Section',
        action: 'connection',
        withTagSelect: true,
        hidden: true,
        outbounds: [
          {
            code: 'n3',
            displayName: 'DE Node',
            type: 'VLESS',
            selected: true,
            latency: 55,
          },
        ],
      },
    ];

    const onToggleShowHidden = vi.fn();
    const commonProps = {
      sections: sectionsWithHidden,
      selectedSectionCode: '',
      onSelectSection: vi.fn(),
      getSectionStats: () => ({
        download: 0,
        upload: 0,
        downloadSpeed: 0,
        uploadSpeed: 0,
        conns: 0,
      }),
      isTestingAllSections: false,
      onTestAllSections: vi.fn(),
      latencyFetchingSections: {},
      onTestSectionLatency: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowPriorityInfo: vi.fn(),
      onToggleShowHidden,
    };

    const hiddenBlocks = renderOverviewMod.renderDashboardSectionsAndNodes({
      ...commonProps,
      showHidden: false,
    });
    const hiddenWrap = createDummyElement('div');
    hiddenBlocks.forEach((b: any) => hiddenWrap.appendChild(b));

    const visibleNames = hiddenWrap
      .querySelectorAll('.tachyon-routing-row__name')
      .map((n: any) => n.textContent);
    expect(visibleNames).toEqual(['Visible Section']);

    const toggleBtn = hiddenWrap
      .querySelectorAll('.tachyon-routing-sections-block__filter-btn')
      .find((b: any) => b.id === 'dashboard-toggle-hidden-button');
    expect(toggleBtn).toBeTruthy();
    expect(toggleBtn.textContent).toContain('(2)');
    toggleBtn.click();
    expect(onToggleShowHidden).toHaveBeenCalledTimes(1);

    const revealedBlocks = renderOverviewMod.renderDashboardSectionsAndNodes({
      ...commonProps,
      showHidden: true,
    });
    const revealedWrap = createDummyElement('div');
    revealedBlocks.forEach((b: any) => revealedWrap.appendChild(b));
    const revealedNames = revealedWrap
      .querySelectorAll('.tachyon-routing-row__name')
      .map((n: any) => n.textContent);
    expect(revealedNames).toEqual(['Visible Section', 'Secret Section']);

    const onlyHiddenBlocks = renderOverviewMod.renderDashboardSectionsAndNodes({
      ...commonProps,
      sections: [sectionsWithHidden[1]],
      showHidden: false,
    });
    const onlyHiddenWrap = createDummyElement('div');
    onlyHiddenBlocks.forEach((b: any) => onlyHiddenWrap.appendChild(b));
    const onlyHiddenBtn = onlyHiddenWrap
      .querySelectorAll('.tachyon-routing-sections-block__filter-btn')
      .find((b: any) => b.id === 'dashboard-toggle-hidden-button');
    expect(onlyHiddenBtn).toBeTruthy();
    expect(onlyHiddenBtn.textContent).toContain('(1)');
  });

  it('offers all supported outbound source architectures including Tailscale and creates Tailscale source defaults', async () => {
    const uciStore: Record<string, Record<string, any>> = {};
    let modalContent: any[] = [];
    const uiMock = {
      showModal: vi.fn((_title: string, nodes: any[]) => {
        modalContent = nodes;
      }),
      hideModal: vi.fn(),
    };
    const uciMock = {
      sections: vi.fn((_pkg: string, type: string) =>
        Object.values(uciStore).filter((s) => s['.type'] === type),
      ),
      get: vi.fn((_pkg: string, sid: string, opt?: string) => {
        const entry = uciStore[sid];
        if (!entry) return opt ? undefined : null;
        return opt ? entry[opt] : entry;
      }),
      set: vi.fn((_pkg: string, sid: string, opt: string, val: any) => {
        uciStore[sid] = uciStore[sid] || { '.name': sid };
        uciStore[sid][opt] = val;
      }),
      add: vi.fn((_pkg: string, stype: string, sid: string) => {
        uciStore[sid] = { '.name': sid, '.type': stype };
      }),
      unset: vi.fn((_pkg: string, sid: string, opt: string) => {
        if (uciStore[sid]) delete uciStore[sid][opt];
      }),
    };
    const prevUci = (globalThis as any).uci;
    const prevUi = (globalThis as any).ui;
    const prevWindow = (globalThis as any).window;
    (globalThis as any).uci = uciMock;
    (globalThis as any).ui = uiMock;
    (globalThis as any).window = globalThis;

    try {
      const containerEl = createDummyElement('div');
      const mockRef = {
        sectiontype: 'outbound_source',
        map: { data: uciMock, save: vi.fn(() => Promise.resolve()) },
        renderMoreOptionsModal: vi.fn(),
      };

      studioDeckMod.mountTachyonStudioDeck({
        type: 'outbound_source',
        sectionRef: mockRef,
        containerEl,
      });

      const addBtn = containerEl.querySelectorAll(
        '.tachyon-studio-btn--primary',
      )[0];
      expect(addBtn).toBeTruthy();
      addBtn.click();
      expect(uiMock.showModal).toHaveBeenCalledTimes(1);

      const modalRoot = modalContent[0];
      const titles = modalRoot
        .querySelectorAll('.tachyon-studio-create__tpl-title')
        .map((el: any) => String(el.textContent || ''));

      for (const expectedTitle of [
        'Tailscale Mesh VPN',
        'OpenVPN (.ovpn)',
        'CSQTT / WDTT v3',
        'AnyTLS',
        'NaiveProxy',
        'Mieru',
        'Snell',
        'Sudoku',
        'MASQUE (HTTP/3)',
        'ShadowTLS v3',
        'TrustTunnel',
        'TewFai',
        'Tor (SOCKS5)',
        'Outbound JSON',
      ]) {
        expect(titles).toContain(expectedTitle);
      }

      const tailscaleCard = modalRoot
        .querySelectorAll('.tachyon-studio-create__tpl-card')
        .find((c: any) =>
          String(c.textContent || '').includes('Tailscale Mesh VPN'),
        );
      expect(tailscaleCard).toBeTruthy();
      tailscaleCard.click();

      const nameInput = modalRoot.querySelectorAll(
        '.tachyon-studio-create__input',
      )[0];
      nameInput.value = 'ts_home';

      const confirmBtn = modalRoot.querySelectorAll('.cbi-button-apply')[0];
      expect(confirmBtn).toBeTruthy();
      confirmBtn.click();

      await new Promise((resolve) => setTimeout(resolve, 60));

      expect(uciStore.ts_home).toBeTruthy();
      expect(uciStore.ts_home.source_type).toBe('tailscale');
      expect(uciStore.ts_home.tailscale_control_url).toBe(
        'https://controlplane.tailscale.com',
      );
      expect(uciStore.ts_home.tailscale_accept_routes).toBe('1');
      expect(uciStore.ts_home.tailscale_accept_dns).toBe('1');
    } finally {
      (globalThis as any).uci = prevUci;
      (globalThis as any).ui = prevUi;
      (globalThis as any).window = prevWindow;
    }
  });
});
