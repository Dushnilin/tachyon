/* eslint-disable @typescript-eslint/no-explicit-any */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

class MockMutationObserver {
  observe() {}
  disconnect() {}
  takeRecords() {
    return [];
  }
}
globalThis.MutationObserver = MockMutationObserver as any;

globalThis.document = {
  body: {} as any,
  createElement: () => ({}) as any,
  getElementById: () => null,
  querySelector: () => null,
  querySelectorAll: () => [],
} as any;

(globalThis as any).rpc = { declare: vi.fn() };
(globalThis as any).localStorage = { getItem: vi.fn(), setItem: vi.fn() };

// Define mocks before importing
vi.mock('../../../helpers', () => ({
  canUseDirectClashApi: vi.fn().mockReturnValue(true),
  onMount: vi.fn().mockImplementation(() => Promise.resolve()),
  getClashWsUrl: vi.fn(),
  isCopyableProxyLink: vi.fn(),
  preserveScrollForPage: vi.fn((cb) => cb()),
}));

vi.mock('../../../helpers/isActiveLuciTab', () => ({
  isActiveLuciTab: vi.fn().mockReturnValue(true),
}));

vi.mock('../../../services/runtimeUiState.service', () => ({
  getCachedRuntimeUiState: vi.fn().mockReturnValue(null),
  refreshRuntimeUiState: vi.fn().mockResolvedValue(null),
  subscribeRuntimeUiState: vi.fn(),
}));

describe('dashboard initController', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    (globalThis as any).E = vi
      .fn()
      .mockImplementation((tag) => document.createElement(tag));
    (globalThis as any).ui = {
      showModal: vi.fn(),
      hideModal: vi.fn(),
      addNotification: vi.fn(),
    } as any;
    (globalThis as any).uci = {
      sections: vi.fn().mockResolvedValue([]),
    } as any;
  });

  it('should export initController function', async () => {
    const { initController } = await import('../initController');
    expect(typeof initController).toBe('function');
  });

  // -1 is what the dashboard stores for "did not answer". Rendering it as "-1ms"
  // in green is worse than useless: the row looks like a measurement, and a
  // better one than most real ones.
  it('never shows a negative latency as a measurement', async () => {
    const { formatUrlTestLatency, getUrlTestLatencyClass } = await import(
      '../initController'
    );

    expect(formatUrlTestLatency(-1)).toBe('N/A');
    expect(getUrlTestLatencyClass(-1)).toBe(
      'tachyon_dashboard-page__outbound-grid__item__latency--empty',
    );

    expect(formatUrlTestLatency(72)).toBe('72ms');
    expect(getUrlTestLatencyClass(72)).toBe(
      'tachyon_dashboard-page__outbound-grid__item__latency--green',
    );
  });

  it('formats service row values correctly', async () => {
    const { formatServiceRowValue } = await import('../initController');

    // Stopped
    expect(formatServiceRowValue({ running: 0 })).toBe('✗');
    expect(formatServiceRowValue({ running: 0, version: '0.1.3' })).toBe(
      '✗ [v0.1.3]',
    );
    expect(formatServiceRowValue({ running: 0, version: 'v0.1.3' })).toBe(
      '✗ [v0.1.3]',
    );

    // Running with memory, uptime and version
    expect(
      formatServiceRowValue({
        running: 1,
        memoryMb: 16,
        uptimePretty: '1ч 47м',
        version: '0.1.3',
      }),
    ).toBe('✓ (16 MB) • 1ч 47м [v0.1.3]');

    // Running with extra cache suffix
    expect(
      formatServiceRowValue({
        running: 1,
        memoryMb: 2,
        uptimePretty: '3ч 57м',
        extraSuffix: ' [Cache: 1.1 MB]',
      }),
    ).toBe('✓ (2 MB) • 3ч 57м [Cache: 1.1 MB]');

    // Running with no memory but uptime
    expect(
      formatServiceRowValue({
        running: 1,
        uptimePretty: '6ч 29м',
      }),
    ).toBe('✓ • 6ч 29м');
  });

  it('formats service tooltips correctly', async () => {
    const { formatServiceTooltip } = await import('../initController');

    expect(formatServiceTooltip({})).toBeUndefined();
    expect(formatServiceTooltip({ pid: 21427, uptimePretty: '1ч 47м' })).toBe(
      'PID: 21427 • Uptime: 1ч 47м',
    );
    expect(formatServiceTooltip({ pid: 2450 })).toBe('PID: 2450');
  });

  it('renders modern service row items with pills and status dot', async () => {
    const { renderServiceRowItem } = await import('../initController');
    const runningItem = renderServiceRowItem('Tachyon Core', {
      running: 1,
      memoryMb: 22,
      uptimePretty: '2ч 51м',
      tooltip: 'PID: 1234 • Uptime: 2ч 51м',
    });
    expect(runningItem.attributes.class).toContain('row--success');
    expect(runningItem.attributes.title).toBe('PID: 1234 • Uptime: 2ч 51м');

    const stoppedItem = renderServiceRowItem('Dnsmasq (DNS)', {
      running: 0,
    });
    expect(stoppedItem.attributes.class).toContain('row--error');
  });

  it('localizes uptime strings based on UI language', async () => {
    const { formatLocalizedUptime } = await import('../initController');

    // In English environment (vitest default):
    expect(formatLocalizedUptime('3ч 12м')).toBe('3h 12m');
    expect(formatLocalizedUptime('2д 5ч')).toBe('2d 5h');
    expect(formatLocalizedUptime('45с')).toBe('45s');
    expect(formatLocalizedUptime('15м')).toBe('15m');
    expect(formatLocalizedUptime(undefined, 3720)).toBe('1h 2m');
    expect(formatLocalizedUptime(undefined, 45)).toBe('45s');
  });

  it('renders system widget when service is stopped', async () => {
    const { renderSystemServicesWidget } = await import('../initController');
    const { store } = await import('../../../services/store.service');

    const container = {
      replaceChildren: vi.fn(),
    };
    (globalThis.document as any).getElementById = vi.fn((id: string) => {
      if (id === 'dashboard-widget-system-services') return container;
      return null;
    });

    store.set({
      servicesInfoWidget: {
        loading: false,
        failed: false,
        data: {
          tachyonRunning: 0,
          tachyonCore: 0,
          dnsmasqRunning: 1,
        } as any,
      },
    });

    await renderSystemServicesWidget();
    expect(container.replaceChildren).toHaveBeenCalled();
  });

  it('extractTestedTags extracts codes from proxy_list, group, and proxy', async () => {
    const { extractTestedTags } = await import('../initController');

    // proxy_list
    expect(
      extractTestedTags('proxy_list', 'sec', JSON.stringify(['us-1', 'us-2'])),
    ).toEqual(['us-1', 'us-2']);

    // proxy
    expect(extractTestedTags('proxy', 'sec', 'de-1')).toEqual(['de-1']);
    expect(extractTestedTags('proxy', 'sec', '["de-2"]')).toEqual(['de-2']);

    // invalid json in proxy_list
    expect(extractTestedTags('proxy_list', 'sec', 'invalid')).toEqual([]);
  });

  it('applyTestedLatenciesResults sets positive delay for responding nodes and -1 for unresponsive nodes', async () => {
    const { applyTestedLatenciesResults, customProxyLatencies } = await import(
      '../initController'
    );
    const { TachyonShellMethods } = await import('../../../methods');

    const now = Date.now();
    vi.spyOn(TachyonShellMethods, 'getClashApiProxies').mockResolvedValue({
      success: true,
      data: {
        proxies: {
          'server-ok': {
            history: [{ time: new Date(now).toISOString(), delay: 145 }],
          },
          'server-timeout': {
            history: [],
          },
          'server-old': {
            history: [
              { time: new Date(now - 60000).toISOString(), delay: 200 },
            ],
          },
        },
      } as any,
    });

    const beforeTimes = new Map<string, string>();
    beforeTimes.set('server-old', new Date(now - 60000).toISOString());

    await applyTestedLatenciesResults(
      ['server-ok', 'server-timeout', 'server-old'],
      now,
      beforeTimes,
    );

    expect(customProxyLatencies.get('server-ok')).toBe(145);
    expect(customProxyLatencies.get('server-timeout')).toBe(-1);
    expect(customProxyLatencies.get('server-old')).toBe(-1);
  });

  it('expands URLTest child outbounds when leaf nodes are hidden in latencyTestCodes', async () => {
    const {
      extractTestedTags,
      applyTestedLatenciesResults,
      customProxyLatencies,
    } = await import('../initController');
    const { store } = await import('../../../services/store.service');
    const { TachyonShellMethods } = await import('../../../methods');

    store.set({
      sectionsWidget: {
        loading: false,
        failed: false,
        latencyFetchingSections: {},
        latencyProgressSections: {},
        subscriptionUpdatingSections: {},
        selectorSwitchingSections: {},
        data: [
          {
            code: 'Discord-out',
            sectionName: 'Discord',
            displayName: 'Discord',
            withTagSelect: true,
            latencyTestCodes: ['Discord-urltest-out'],
            outbounds: [
              {
                code: 'Discord-urltest-out',
                displayName: 'Discord (URLTest)',
                type: 'URLTest',
                latency: 0,
                selected: true,
                urlTestInfo: {
                  tag: 'Discord-urltest-out',
                  url: 'https://discordapp.com/',
                  interval: '3m',
                  tolerance: 50,
                  idleTimeout: '30m',
                  interruptExistConnections: false,
                  outbounds: [
                    {
                      code: 'shadow-fi-1',
                      displayName: 'Finland | Hysteria',
                      type: 'Hysteria2',
                      latency: 0,
                      selected: false,
                    },
                    {
                      code: 'shadow-nl-1',
                      displayName: 'Netherlands | VLESS',
                      type: 'VLESS',
                      latency: 0,
                      selected: false,
                    },
                  ],
                },
              },
            ],
          } as any,
        ],
      },
    });

    const tags = extractTestedTags('proxy_list', 'Discord', '@section:Discord');
    expect(tags).toEqual(['Discord-urltest-out', 'shadow-fi-1', 'shadow-nl-1']);

    const now = Date.now();
    vi.spyOn(TachyonShellMethods, 'getClashApiProxies').mockResolvedValue({
      success: true,
      data: {
        proxies: {
          'Discord-urltest-out': {
            type: 'URLTest',
            now: 'shadow-fi-1',
            all: ['shadow-fi-1', 'shadow-nl-1'],
            history: [],
          },
          'shadow-fi-1': {
            type: 'Hysteria2',
            history: [{ time: new Date(now).toISOString(), delay: 58 }],
          },
          'shadow-nl-1': {
            type: 'VLESS',
            history: [{ time: new Date(now).toISOString(), delay: 112 }],
          },
        },
      } as any,
    });

    await applyTestedLatenciesResults(tags, now);
    expect(customProxyLatencies.get('shadow-fi-1')).toBe(58);
    expect(customProxyLatencies.get('shadow-nl-1')).toBe(112);
    expect(customProxyLatencies.get('Discord-urltest-out')).toBe(58);
  });

  describe('getSectionConnectionStats', () => {
    it('returns totals directly when totalProxySections <= 1', async () => {
      const { getSectionConnectionStats } = await import('../initController');

      const rawConns = [{ chains: ['main'], upload: 100, download: 200 }];
      const totals = {
        downloadTotal: 5000,
        uploadTotal: 1000,
        downSpeed: 250,
        upSpeed: 50,
      };

      const result = getSectionConnectionStats('main', 1, rawConns, totals);
      expect(result).toEqual({
        conns: 1,
        upload: 1000,
        download: 5000,
        downSpeed: 250,
        upSpeed: 50,
      });
    });

    it('aggregates connections, upload and download per section matching chains and metadata.chains', async () => {
      const { getSectionConnectionStats } = await import('../initController');

      const rawConns = [
        { id: 'a', chains: ['main', 'proxy-out'], upload: 500, download: 1500 },
        { id: 'b', metadata: { chains: ['MAIN'] }, upload: 200, download: 400 },
        { id: 'c', chains: ['other-section'], upload: 1000, download: 2000 },
      ] as any;

      const totals = {
        downloadTotal: 10000,
        uploadTotal: 5000,
        downSpeed: 1000,
        upSpeed: 500,
      };

      const rates = new Map([
        ['a', { down: 700, up: 300 }],
        ['b', { down: 300, up: 200 }],
        ['c', { down: 200, up: 100 }],
      ]);
      const resultMain = getSectionConnectionStats(
        'main',
        2,
        rawConns,
        totals,
        rates,
      );
      expect(resultMain.conns).toBe(2);
      expect(resultMain.upload).toBe(700);
      expect(resultMain.download).toBe(1900);
      expect(resultMain.downSpeed).toBe(1000);
      expect(resultMain.upSpeed).toBe(500);

      const resultOther = getSectionConnectionStats(
        'other-section',
        2,
        rawConns,
        totals,
        rates,
      );
      expect(resultOther.conns).toBe(1);
      expect(resultOther.upload).toBe(1000);
      expect(resultOther.download).toBe(2000);
      expect(resultOther.downSpeed).toBe(200);
      expect(resultOther.upSpeed).toBe(100);
    });

    it.each([
      'vpn-urltest-out',
      'vpn-urltest-fast-out',
      'vpn-priority-failover-out',
    ])(
      'attributes a group-only chain %s to its owning section',
      async (tag) => {
        const { getSectionConnectionStats } = await import('../initController');
        const conns = [{ id: 'group', chains: [tag], download: 1000 }];
        const rates = new Map([['group', { down: 100, up: 10 }]]);
        expect(getSectionConnectionStats('vpn', 2, conns, {}, rates)).toEqual({
          conns: 1,
          upload: 0,
          download: 1000,
          downSpeed: 100,
          upSpeed: 10,
        });
      },
    );

    it('checks the fallback rule after exhausting a sparse chain', async () => {
      const { getSectionConnectionStats } = await import('../initController');
      const chains: string[] = [];
      chains[2] = 'other-out';
      const conns = [
        { chains, rule: 'ROUTE(VPN-OUT)', download: 3 },
        { chains, rulePayload: 'Rule_Set=VPN-example', upload: 4 },
        { chains, rule: 'route(vpn-work-out)', download: 5 },
      ];
      expect(getSectionConnectionStats('VPN', 2, conns, {})).toEqual({
        conns: 2,
        upload: 4,
        download: 3,
        downSpeed: 0,
        upSpeed: 0,
      });
    });

    it('keeps the conversion error for an invalid chain entry after a match', async () => {
      const { getSectionConnectionStats } = await import('../initController');
      const malformed = JSON.parse('["vpn-out", {"toString": null}]');
      expect(() =>
        getSectionConnectionStats('vpn', 2, [{ chains: malformed }], {}),
      ).toThrow(TypeError);
    });

    it('attributes rates to the section selector, not a reused balancer name', async () => {
      const { getSectionConnectionStats } = await import('../initController');
      const conns = [
        { id: 'v', chains: ['VPN-OUT'], download: 1000 },
        {
          id: 'w',
          chains: ['warp-out', 'warp-urltest-bal_vpn_Fast-out'],
          download: 2000,
        },
        { id: 'other', chains: ['vpn-work-out'], download: 9000 },
      ];
      const rates = new Map([
        ['v', { down: 100, up: 10 }],
        ['w', { down: 200, up: 20 }],
        ['other', { down: 900, up: 90 }],
      ]);
      expect(getSectionConnectionStats('vpn', 3, conns, {}, rates)).toEqual({
        conns: 1,
        upload: 0,
        download: 1000,
        downSpeed: 100,
        upSpeed: 10,
      });
      expect(getSectionConnectionStats('warp', 3, conns, {}, rates)).toEqual({
        conns: 1,
        upload: 0,
        download: 2000,
        downSpeed: 200,
        upSpeed: 20,
      });
    });

    it('matches Tachyon 2.0 sel-*, bal-*, desync-sec-*, and tailscale-sec-* tags', async () => {
      const { getSectionConnectionStats } = await import('../initController');
      const conns = [
        {
          id: 'c1',
          chains: ['sel-vpn', 'R-VPN Moscow'],
          upload: 10,
          download: 90,
        },
        {
          id: 'c2',
          chains: ['bal-Main-bal_Main_SoftPortal', 'Unlim EE'],
          upload: 20,
          download: 80,
        },
        { id: 'c3', chains: ['desync-sec-youtube'], upload: 5, download: 45 },
        { id: 'c4', chains: ['tailscale-sec-ts'], upload: 15, download: 35 },
      ];
      const rates = new Map([
        ['c1', { down: 9, up: 1 }],
        ['c2', { down: 8, up: 2 }],
      ]);

      expect(getSectionConnectionStats('vpn', 4, conns, {}, rates)).toEqual({
        conns: 1,
        upload: 10,
        download: 90,
        downSpeed: 9,
        upSpeed: 1,
      });
      expect(getSectionConnectionStats('Main', 4, conns, {}, rates)).toEqual({
        conns: 1,
        upload: 20,
        download: 80,
        downSpeed: 8,
        upSpeed: 2,
      });
      expect(getSectionConnectionStats('youtube', 4, conns, {}, rates)).toEqual(
        {
          conns: 1,
          upload: 5,
          download: 45,
          downSpeed: 0,
          upSpeed: 0,
        },
      );
      expect(getSectionConnectionStats('ts', 4, conns, {}, rates)).toEqual({
        conns: 1,
        upload: 15,
        download: 35,
        downSpeed: 0,
        upSpeed: 0,
      });
    });

    it('matches single-source leaf tags without double-counting shared leaf nodes across other section groups', async () => {
      const { getSectionConnectionStats } = await import('../initController');
      const routeAllSec = {
        code: 'iface-src_iface_awg_de',
        sectionName: 'route_all',
        outbounds: [
          {
            code: 'iface-src_iface_awg_de',
            displayName: 'AWG DE',
            latency: 10,
            type: 'wireguard',
            selected: true,
          },
        ],
      } as any;
      const vpnSec = {
        code: 'sel-vpn',
        sectionName: 'vpn',
        outbounds: [
          {
            code: 'R-VPN Moscow',
            displayName: 'R-VPN Moscow',
            latency: 20,
            type: 'vless',
            selected: true,
          },
        ],
      } as any;
      const telegramSec = {
        code: 'sel-telegram',
        sectionName: 'telegram',
        outbounds: [
          {
            code: 'R-VPN Moscow',
            displayName: 'R-VPN Moscow',
            latency: 20,
            type: 'vless',
            selected: true,
          },
        ],
      } as any;

      const conns = [
        {
          id: 'r1',
          chains: ['iface-src_iface_awg_de'],
          upload: 100,
          download: 500,
        },
        {
          id: 'v1',
          chains: ['sel-vpn', 'R-VPN Moscow'],
          upload: 50,
          download: 250,
        },
      ];

      expect(
        getSectionConnectionStats(
          'route_all',
          3,
          conns,
          {},
          new Map(),
          routeAllSec,
        ),
      ).toEqual({
        conns: 1,
        upload: 100,
        download: 500,
        downSpeed: 0,
        upSpeed: 0,
      });
      expect(
        getSectionConnectionStats('vpn', 3, conns, {}, new Map(), vpnSec),
      ).toEqual({
        conns: 1,
        upload: 50,
        download: 250,
        downSpeed: 0,
        upSpeed: 0,
      });
      expect(
        getSectionConnectionStats(
          'telegram',
          3,
          conns,
          {},
          new Map(),
          telegramSec,
        ),
      ).toEqual({
        conns: 0,
        upload: 0,
        download: 0,
        downSpeed: 0,
        upSpeed: 0,
      });
    });
  });

  it('keeps #dashboard-widget-tailscale hidden during initial loading when no native Tailscale server is enabled', async () => {
    const { renderTailscaleWidget } = await import('../initController');
    const { store } = await import('../../../services/store.service');

    const container = {
      style: { display: 'none' },
      replaceChildren: vi.fn(),
    };
    (globalThis.document as any).getElementById = vi.fn((id: string) => {
      if (id === 'dashboard-widget-tailscale') return container;
      return null;
    });
    (globalThis as any).uci = {
      sections: vi.fn().mockReturnValue([]),
    } as any;

    store.set({
      tailscaleWidget: {
        loading: true,
        failed: false,
        data: null,
      },
    });

    await renderTailscaleWidget();
    expect(container.style.display).toBe('none');
    expect(container.replaceChildren).toHaveBeenCalledWith();

    store.set({
      tailscaleWidget: {
        loading: false,
        failed: false,
        data: {
          configured: true,
          backend_state: 'Running',
          peers: [],
        } as any,
      },
    });

    await renderTailscaleWidget();
    expect(container.style.display).toBe('');
    expect(container.replaceChildren).toHaveBeenCalledTimes(2);
  });

  describe('dashboard buttons, latency feedback, and Sources update button', () => {
    function makeTestElement(tag: string): any {
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
              (el.className || '').split(/\s+/).filter(Boolean),
            );
            set.add(c);
            el.className = Array.from(set).join(' ');
            el.class = el.className;
          },
          remove(c: string) {
            const set = new Set(
              (el.className || '').split(/\s+/).filter(Boolean),
            );
            set.delete(c);
            el.className = Array.from(set).join(' ');
            el.class = el.className;
          },
          contains(c: string) {
            return (el.className || '').split(/\s+/).includes(c);
          },
        },
        get textContent(): string {
          return children
            .map((c) =>
              typeof c === 'string' || typeof c === 'number'
                ? String(c)
                : c?.textContent || '',
            )
            .join('');
        },
        set textContent(val: string) {
          children.length = 0;
          if (val !== undefined && val !== null && val !== '') {
            children.push(String(val));
          }
        },
        set innerHTML(val: string) {
          children.length = 0;
          if (val) children.push(val);
        },
        setAttribute(name: string, val: string) {
          attrs[name] = String(val);
          if (name === 'class') {
            el.className = String(val);
            el.class = el.className;
          } else if (name.startsWith('data-')) {
            const camel = name
              .slice(5)
              .replace(/-([a-z])/g, (_, ch) => ch.toUpperCase());
            el.dataset[camel] = String(val);
          } else {
            el[name] = val;
          }
        },
        getAttribute(name: string) {
          if (name === 'class') return el.className || null;
          return attrs[name] ?? el[name] ?? null;
        },
        removeAttribute(name: string) {
          delete attrs[name];
          delete el[name];
        },
        addEventListener(type: string, cb: (ev: any) => void) {
          if (!listeners[type]) listeners[type] = [];
          listeners[type].push(cb);
        },
        click() {
          for (const cb of listeners.click || []) {
            cb({ preventDefault() {}, stopPropagation() {} });
          }
        },
        appendChild(node: any) {
          if (node !== null && node !== undefined && node !== '') {
            if (typeof node === 'object') {
              const prevIdx = children.indexOf(node);
              if (prevIdx >= 0) children.splice(prevIdx, 1);
              node.parentNode = el;
              node.parentElement = el;
            }
            children.push(node);
          }
          return node;
        },
        prepend(node: any) {
          if (node !== null && node !== undefined && node !== '') {
            if (typeof node === 'object') node.parentNode = el;
            children.unshift(node);
          }
        },
        insertBefore(newNode: any, refNode: any) {
          if (newNode && typeof newNode === 'object') newNode.parentNode = el;
          const idx = children.indexOf(refNode);
          if (idx >= 0) children.splice(idx, 0, newNode);
          else children.push(newNode);
          return newNode;
        },
        get firstChild() {
          return children[0] || null;
        },
        cloneNode(deep?: boolean) {
          const cloned = makeTestElement(tag);
          for (const [k, v] of Object.entries(attrs)) {
            cloned.setAttribute(k, v);
          }
          if (deep) {
            for (const c of children) {
              cloned.appendChild(
                typeof c === 'object' && c?.cloneNode ? c.cloneNode(true) : c,
              );
            }
          }
          return cloned;
        },
        replaceChildren(...nodes: any[]) {
          children.length = 0;
          for (const n of nodes) el.appendChild(n);
        },
        replaceWith(nextNode: any) {
          if (el.parentNode && Array.isArray(el.parentNode.children)) {
            const idx = el.parentNode.children.indexOf(el);
            if (idx >= 0) el.parentNode.children.splice(idx, 1, nextNode);
          }
        },
        remove() {
          if (el.parentNode && Array.isArray(el.parentNode.children)) {
            const idx = el.parentNode.children.indexOf(el);
            if (idx >= 0) el.parentNode.children.splice(idx, 1);
          }
        },
        closest() {
          return null;
        },
        querySelectorAll(selector: string): any[] {
          const results: any[] = [];
          const matches = (node: any) => {
            if (!node || typeof node !== 'object') return false;
            if (selector.startsWith('.')) {
              const wanted = selector.split('.').filter(Boolean);
              const cls = (node.className || node.class || '').split(/\s+/);
              return wanted.every((w) => cls.includes(w));
            }
            if (selector.startsWith('#')) {
              return node.id === selector.slice(1);
            }
            return node.tagName === selector.toUpperCase();
          };
          const walk = (node: any) => {
            if (!node || typeof node !== 'object') return;
            if (matches(node)) results.push(node);
            if (Array.isArray(node.children)) {
              for (const child of node.children) walk(child);
            }
          };
          walk(el);
          return results;
        },
        querySelector(selector: string): any {
          return el.querySelectorAll(selector)[0] || null;
        },
      };
      return el;
    }

    function createDomE() {
      return (tag: string, attrs?: any, children?: any) => {
        const el = makeTestElement(tag);
        if (attrs && typeof attrs === 'object' && !Array.isArray(attrs)) {
          for (const [k, v] of Object.entries(attrs)) {
            if (v === undefined || v === null) continue;
            if (k === 'click' && typeof v === 'function') {
              el.addEventListener('click', v as (ev: any) => void);
            } else {
              el.setAttribute(k, v === true ? '' : String(v));
            }
          }
        }
        const childList =
          attrs &&
          (Array.isArray(attrs) ||
            typeof attrs === 'string' ||
            typeof attrs === 'number')
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
    }

    let savedDocument: any;
    let savedE: any;
    let savedUi: any;
    let savedUci: any;
    let savedFs: any;
    let savedRaf: any;
    let bodyEl: any;
    let byIdMap: Map<string, any>;

    beforeEach(() => {
      savedDocument = globalThis.document;
      savedE = (globalThis as any).E;
      savedUi = (globalThis as any).ui;
      savedUci = (globalThis as any).uci;
      savedFs = (globalThis as any).fs;
      savedRaf = (globalThis as any).requestAnimationFrame;

      bodyEl = makeTestElement('body');
      byIdMap = new Map();

      globalThis.document = {
        body: bodyEl,
        documentElement: { lang: 'en' },
        createElement: (tag: string) => makeTestElement(tag),
        createElementNS: (_ns: string, tag: string) => makeTestElement(tag),
        getElementById: (id: string) => byIdMap.get(id) ?? null,
        querySelector: (selector: string) => bodyEl.querySelector(selector),
        querySelectorAll: (selector: string) =>
          bodyEl.querySelectorAll(selector),
        addEventListener: vi.fn(),
      } as any;
      (globalThis as any).E = createDomE();
    });

    afterEach(() => {
      vi.useRealTimers();
      vi.restoreAllMocks();
      globalThis.document = savedDocument;
      (globalThis as any).E = savedE;
      (globalThis as any).ui = savedUi;
      (globalThis as any).uci = savedUci;
      (globalThis as any).fs = savedFs;
      (globalThis as any).requestAnimationFrame = savedRaf;
    });

    it('onStoreUpdate triggers re-render when action states change even if data is unchanged', async () => {
      const { onStoreUpdate } = await import('../initController');
      const { store } = await import('../../../services/store.service');

      const gridEl = makeTestElement('div');
      gridEl.id = 'dashboard-sections-grid';
      gridEl.replaceChildren = vi.fn();
      byIdMap.set('dashboard-sections-grid', gridEl);

      const scheduledCallbacks: Array<() => void> = [];
      (globalThis as any).requestAnimationFrame = vi.fn((cb: () => void) => {
        scheduledCallbacks.push(cb);
        return scheduledCallbacks.length;
      });

      const flushRaf = async () => {
        while (scheduledCallbacks.length > 0) {
          scheduledCallbacks.shift()!();
          await Promise.resolve();
        }
      };

      const sharedData = [
        {
          code: 'main-out',
          sectionName: 'main',
          displayName: 'Main',
          withTagSelect: true,
          subscriptionSourceCount: 1,
          outbounds: [
            {
              code: 'node-1',
              displayName: 'Node 1',
              type: 'VLESS',
              latency: 0,
              selected: true,
            },
          ],
        },
      ] as any;

      const baseSectionsWidget = {
        loading: false,
        failed: false,
        data: sharedData,
        latencyFetchingSections: {},
        latencyProgressSections: {},
        subscriptionUpdatingSections: {},
        selectorSwitchingSections: {},
      };

      const prevState = {
        ...store.get(),
        sectionsWidget: baseSectionsWidget,
      };
      const subUpdatingState = {
        ...prevState,
        sectionsWidget: {
          ...baseSectionsWidget,
          subscriptionUpdatingSections: { main: true },
        },
      };
      store.set({ sectionsWidget: subUpdatingState.sectionsWidget });

      await onStoreUpdate(subUpdatingState, prevState, {
        sectionsWidget: subUpdatingState.sectionsWidget,
      });
      expect(scheduledCallbacks.length).toBeGreaterThanOrEqual(1);
      await flushRaf();
      expect(gridEl.replaceChildren).toHaveBeenCalledTimes(1);

      const latFetchingState = {
        ...prevState,
        sectionsWidget: {
          ...baseSectionsWidget,
          latencyFetchingSections: { main: true },
        },
      };
      store.set({ sectionsWidget: latFetchingState.sectionsWidget });
      await onStoreUpdate(latFetchingState, prevState, {
        sectionsWidget: latFetchingState.sectionsWidget,
      });
      expect(scheduledCallbacks.length).toBeGreaterThanOrEqual(1);
      await flushRaf();
      expect(gridEl.replaceChildren).toHaveBeenCalledTimes(2);

      // Finishing latency test back to {} with identical data still re-renders
      store.set({ sectionsWidget: baseSectionsWidget });
      await onStoreUpdate(prevState, latFetchingState, {
        sectionsWidget: baseSectionsWidget,
      });
      expect(scheduledCallbacks.length).toBeGreaterThanOrEqual(1);
      await flushRaf();
      expect(gridEl.replaceChildren).toHaveBeenCalledTimes(3);

      // Selector switch state change also triggers re-render
      const switchingState = {
        ...prevState,
        sectionsWidget: {
          ...baseSectionsWidget,
          selectorSwitchingSections: { main: 'node-1' },
        },
      };
      store.set({ sectionsWidget: switchingState.sectionsWidget });
      await onStoreUpdate(switchingState, prevState, {
        sectionsWidget: switchingState.sectionsWidget,
      });
      expect(scheduledCallbacks.length).toBeGreaterThanOrEqual(1);
      await flushRaf();
      expect(gridEl.replaceChildren).toHaveBeenCalledTimes(4);
    });

    it('updates live progress labels on both accordion and modal latency test buttons', async () => {
      const {
        renderSectionAccordionBody,
        renderSectionInspectorModalContent,
        updateLatencyProgressInline,
        canTestSectionLatency,
      } = await import('../initController');
      const { store } = await import('../../../services/store.service');

      const vpnSection = {
        code: 'vpn-out',
        sectionName: 'vpn',
        displayName: 'VPN',
        withTagSelect: true,
        outbounds: [
          {
            code: 'fi-1',
            displayName: 'FI 1',
            type: 'VLESS',
            latency: 0,
            selected: true,
          },
        ],
      } as any;

      const directOnlySection = {
        code: 'direct-out',
        sectionName: 'direct_only',
        displayName: 'Direct Only',
        withTagSelect: false,
        outbounds: [
          {
            code: 'direct-out',
            displayName: 'Direct',
            type: 'DIRECT',
            latency: 0,
            selected: true,
          },
        ],
      } as any;

      expect(canTestSectionLatency(vpnSection)).toBe(true);
      expect(canTestSectionLatency(directOnlySection)).toBe(false);

      store.set({
        sectionsWidget: {
          loading: false,
          failed: false,
          data: [vpnSection, directOnlySection],
          latencyFetchingSections: { vpn: true },
          latencyProgressSections: {
            vpn: { completed: 0, total: 4, failed: 0 },
          },
          subscriptionUpdatingSections: {},
          selectorSwitchingSections: {},
        },
      });

      const gridEl = makeTestElement('div');
      gridEl.id = 'dashboard-sections-grid';
      const accordionBody = renderSectionAccordionBody(vpnSection, 1);
      gridEl.appendChild(accordionBody);
      byIdMap.set('dashboard-sections-grid', gridEl);

      const modalEl = renderSectionInspectorModalContent(
        vpnSection,
        [vpnSection],
        1,
      );
      byIdMap.set('tachyon-section-inspector-modal', modalEl);

      const accBtn = accordionBody.querySelector(
        '.dashboard-sections-grid-item-test-latency',
      );
      const modalBtn = modalEl.querySelector(
        '.dashboard-sections-grid-item-test-latency',
      );
      expect(accBtn).not.toBeNull();
      expect(modalBtn).not.toBeNull();
      expect(accBtn!.getAttribute('data-latency-section')).toBe('vpn');
      expect(modalBtn!.getAttribute('data-latency-section')).toBe('vpn');
      expect(
        accBtn!.querySelector(
          '.dashboard-sections-grid-item-test-latency__label',
        )?.textContent,
      ).toBe('Test latency: 0/4');
      expect(
        modalBtn!.querySelector(
          '.dashboard-sections-grid-item-test-latency__label',
        )?.textContent,
      ).toBe('Test latency: 0/4');

      // Direct-only !withTagSelect section must not render a Test latency button
      const directAccordion = renderSectionAccordionBody(directOnlySection, 1);
      expect(
        directAccordion.querySelector(
          '.dashboard-sections-grid-item-test-latency',
        ),
      ).toBeNull();

      // Inline progress update refreshes BOTH buttons cleanly
      const updated = updateLatencyProgressInline({
        loading: false,
        failed: false,
        data: [vpnSection],
        latencyFetchingSections: { vpn: true },
        latencyProgressSections: {
          vpn: { completed: 3, total: 4, failed: 0 },
        },
        subscriptionUpdatingSections: {},
        selectorSwitchingSections: {},
      });
      expect(updated).toBe(true);
      expect(
        accBtn!.querySelector(
          '.dashboard-sections-grid-item-test-latency__label',
        )?.textContent,
      ).toBe('Test latency: 3/4');
      expect(
        modalBtn!.querySelector(
          '.dashboard-sections-grid-item-test-latency__label',
        )?.textContent,
      ).toBe('Test latency: 3/4');

      // Returns false if active fetching section has no mounted button
      byIdMap.clear();
      expect(
        updateLatencyProgressInline({
          loading: false,
          failed: false,
          data: [vpnSection],
          latencyFetchingSections: { vpn: true },
          latencyProgressSections: {
            vpn: { completed: 4, total: 4, failed: 0 },
          },
          subscriptionUpdatingSections: {},
          selectorSwitchingSections: {},
        }),
      ).toBe(false);
    });

    it('shows toast feedback for latency tests and deduplicates owned jobs', async () => {
      const {
        handleTestLatency,
        followLatencyTestState,
        customProxyLatencies,
      } = await import('../initController');
      const { store } = await import('../../../services/store.service');
      const { TachyonShellMethods } = await import('../../../methods');

      store.set({
        sectionsWidget: {
          loading: false,
          failed: false,
          data: [
            {
              code: 'wg-out',
              sectionName: 'wg',
              displayName: 'WireGuard',
              withTagSelect: false,
              outbounds: [],
            } as any,
            {
              code: 'multi-out',
              sectionName: 'multi',
              displayName: 'Multi',
              withTagSelect: true,
              outbounds: [],
            } as any,
          ],
          latencyFetchingSections: {},
          latencyProgressSections: {},
          subscriptionUpdatingSections: {},
          selectorSwitchingSections: {},
        },
      });

      const latencySpy = vi.spyOn(
        TachyonShellMethods,
        'getClashApiProxyLatency',
      );
      latencySpy.mockResolvedValueOnce({
        success: true,
        data: { delay: 42 },
      } as any);

      await handleTestLatency('proxy', 'wg', 'wg-out');
      let toasts = bodyEl.querySelectorAll('.toast');
      expect(toasts).toHaveLength(1);
      expect(toasts[0].className).toContain('toast-success');
      expect(toasts[0].textContent).toContain('42 ms');

      // Unreachable single proxy
      latencySpy.mockResolvedValueOnce({
        success: true,
        data: { delay: 0 },
      } as any);
      await handleTestLatency('proxy', 'wg', 'wg-out');
      toasts = bodyEl.querySelectorAll('.toast');
      expect(toasts).toHaveLength(2);
      expect(toasts[1].className).toContain('toast-error');
      expect(toasts[1].textContent).toContain('unreachable');

      // Failed latencyTestStart
      vi.spyOn(TachyonShellMethods, 'getClashApiProxies').mockResolvedValue({
        success: true,
        data: { proxies: {} },
      } as any);
      const startSpy = vi
        .spyOn(TachyonShellMethods, 'latencyTestStart')
        .mockResolvedValueOnce({
          success: false,
          error: 'Core busy',
        } as any);

      await handleTestLatency(
        'proxy_list',
        'multi',
        JSON.stringify(['n1', 'n2']),
      );
      toasts = bodyEl.querySelectorAll('.toast');
      expect(toasts).toHaveLength(3);
      expect(toasts[2].className).toContain('toast-error');
      expect(toasts[2].textContent).toContain('Core busy');
      expect(
        store.get().sectionsWidget.latencyFetchingSections.multi,
      ).toBeUndefined();

      // Owned proxy_list completion: 1/2 responding + duplicate guard on followLatencyTestState
      startSpy.mockResolvedValueOnce({
        success: true,
        data: { success: true, job_id: 'lat-owned-1', message: 'ok' },
      } as any);
      vi.spyOn(TachyonShellMethods, 'waitLatencyTestJob').mockResolvedValueOnce(
        {
          success: true,
          data: {
            kind: 'latency',
            job_id: 'lat-owned-1',
            latency_type: 'proxy_list',
            section: 'multi',
            tag: JSON.stringify(['n1', 'n2']),
            success: true,
            running: false,
          },
        } as any,
      );
      const nowIso = new Date().toISOString();
      vi.spyOn(TachyonShellMethods, 'getClashApiProxies').mockResolvedValue({
        success: true,
        data: {
          proxies: {
            n1: { history: [{ time: nowIso, delay: 88 }] },
            n2: { history: [] },
          },
        },
      } as any);
      vi.spyOn(TachyonShellMethods, 'uiActionAck').mockResolvedValue({
        success: true,
        data: { success: true, job_id: 'lat-owned-1', message: '' },
      } as any);

      await handleTestLatency(
        'proxy_list',
        'multi',
        JSON.stringify(['n1', 'n2']),
      );
      expect(customProxyLatencies.get('n1')).toBe(88);
      expect(customProxyLatencies.get('n2')).toBe(-1);
      toasts = bodyEl.querySelectorAll('.toast');
      expect(toasts).toHaveLength(4);
      expect(toasts[3].className).toContain('toast-success');
      expect(toasts[3].textContent).toContain('1/2 responding');

      // Resumed / unowned job must not produce duplicate or spurious toasts
      await followLatencyTestState({
        kind: 'latency',
        job_id: 'lat-owned-1',
        latency_type: 'proxy_list',
        section: 'multi',
        tag: JSON.stringify(['n1', 'n2']),
        success: true,
        running: false,
      });
      await followLatencyTestState({
        kind: 'latency',
        job_id: 'lat-unowned-bg',
        latency_type: 'proxy_list',
        section: 'multi',
        tag: JSON.stringify(['n1', 'n2']),
        success: true,
        running: false,
      });
      expect(bodyEl.querySelectorAll('.toast')).toHaveLength(4);
    });

    it('renders spinning loader on Sources Update button and notifies real status', async () => {
      vi.useFakeTimers();
      const { mountTachyonStudioDeck } = await import('../../../studioDeck');

      const subSection: Record<string, any> = {
        '.type': 'outbound_source',
        '.name': 'src_sub',
        enabled: '1',
        name: 'MySub',
        source_type: 'subscription',
        url: 'https://example.com/sub',
      };

      (globalThis as any).uci = {
        get: vi.fn((_pkg: string, sid: string, opt?: string) =>
          sid === 'src_sub' ? (opt ? subSection[opt] : subSection) : null,
        ),
        set: vi.fn(),
        sections: vi.fn((_pkg: string, type: string) =>
          type === 'outbound_source' ? [subSection] : [],
        ),
        save: vi.fn().mockResolvedValue(undefined),
      };
      (globalThis as any).ui = {
        showModal: vi.fn(),
        hideModal: vi.fn(),
        addNotification: vi.fn(),
      };

      const execMock = vi
        .fn()
        // 1) success flow
        .mockResolvedValueOnce({
          stdout: JSON.stringify({ success: true, job_id: 'sub-job-1' }),
        })
        .mockResolvedValueOnce({
          stdout: JSON.stringify({ running: false, success: true }),
        })
        // 2) failed job status flow
        .mockResolvedValueOnce({
          stdout: JSON.stringify({ success: true, job_id: 'sub-job-2' }),
        })
        .mockResolvedValueOnce({
          stdout: JSON.stringify({
            running: false,
            success: false,
            message: 'HTTP 502 Bad Gateway',
          }),
        })
        // 3) failed start flow
        .mockResolvedValueOnce({
          stdout: JSON.stringify({
            success: false,
            message: 'Invalid subscription URL',
          }),
        });

      (globalThis as any).fs = {
        list: vi.fn().mockResolvedValue([]),
        read: vi.fn().mockResolvedValue(''),
        exec: execMock,
      };

      const containerEl = makeTestElement('div');
      const sectionRef = {
        sectiontype: 'outbound_source',
        cfgsections: () => ['src_sub'],
        renderMoreOptionsModal: vi.fn(),
        remove: vi.fn(),
      };

      mountTachyonStudioDeck({
        type: 'outbound_source',
        sectionRef,
        containerEl,
      });

      const findCardUpdateBtn = () =>
        containerEl
          .querySelectorAll('.tachyon-studio-action-btn')
          .find((btn: any) =>
            (btn.getAttribute('title') || '').includes(
              'Update this subscription',
            ),
          );

      // 1) Success path: shows spinning loader while running, then 'info' notification
      const btn1 = findCardUpdateBtn();
      expect(btn1).toBeTruthy();
      btn1.click();

      const btnWhileUpdating = findCardUpdateBtn();
      expect(btnWhileUpdating.getAttribute('disabled')).toBe('disabled');
      expect(
        btnWhileUpdating.querySelector('.lucide-loader-circle'),
      ).not.toBeNull();
      expect(btnWhileUpdating.textContent).toContain('Updating...');

      await vi.advanceTimersByTimeAsync(1500);
      await vi.waitFor(() => {
        expect((globalThis as any).ui.addNotification).toHaveBeenCalledTimes(1);
      });
      expect((globalThis as any).ui.addNotification).toHaveBeenLastCalledWith(
        null,
        expect.anything(),
        'info',
      );
      expect(
        findCardUpdateBtn().querySelector('.lucide-loader-circle'),
      ).toBeNull();

      // 2) Failed polling status: shows 'error' notification with backend message
      findCardUpdateBtn().click();
      await vi.advanceTimersByTimeAsync(1500);
      await vi.waitFor(() => {
        expect((globalThis as any).ui.addNotification).toHaveBeenCalledTimes(2);
      });
      const secondCall = (globalThis as any).ui.addNotification.mock.calls[1];
      expect(secondCall[2]).toBe('error');
      expect(secondCall[1].textContent).toBe('HTTP 502 Bad Gateway');

      // 3) Failed start: shows 'error' notification with startRes.message
      findCardUpdateBtn().click();
      await vi.waitFor(() => {
        expect((globalThis as any).ui.addNotification).toHaveBeenCalledTimes(3);
      });
      const thirdCall = (globalThis as any).ui.addNotification.mock.calls[2];
      expect(thirdCall[2]).toBe('error');
      expect(thirdCall[1].textContent).toBe('Invalid subscription URL');
    });
  });
});
