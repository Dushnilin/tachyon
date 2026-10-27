/* eslint-disable @typescript-eslint/no-explicit-any */
import { describe, it, expect, vi, beforeEach, beforeAll } from 'vitest';

class MockMutationObserver {
  observe() {}
  disconnect() {}
  takeRecords() {
    return [];
  }
}
if (!globalThis.MutationObserver) {
  globalThis.MutationObserver = MockMutationObserver as any;
}
class MockElement {
  tagName: string;
  className: string = '';
  classList: {
    add: (...names: string[]) => void;
    remove: (...names: string[]) => void;
    contains: (name: string) => boolean;
  };
  attributes: Record<string, string> = {};
  children: (MockElement | string)[] = [];
  textContent: string = '';
  style: Record<string, string> = {};

  constructor(tagName: string) {
    this.tagName = tagName;
    const classes = new Set<string>();
    this.classList = {
      add: (...names: string[]) => names.forEach((n) => classes.add(n)),
      remove: (...names: string[]) => names.forEach((n) => classes.delete(n)),
      contains: (name: string) =>
        classes.has(name) || this.className.split(/\s+/).includes(name),
    };
  }

  setAttribute(k: string, v: string) {
    this.attributes[k] = v;
    if (k === 'class' || k === 'className') this.className = v;
  }
  getAttribute(k: string) {
    return this.attributes[k] ?? (k === 'class' ? this.className : undefined);
  }
  appendChild(child: any) {
    this.children.push(child);
    if (typeof child === 'string') {
      this.textContent += child;
    } else if (child && typeof child.textContent === 'string') {
      this.textContent += child.textContent;
    }
    return child;
  }
  replaceChildren(...newChildren: any[]) {
    this.children = [];
    this.textContent = '';
    for (const c of newChildren) {
      this.appendChild(c);
    }
  }
  querySelectorAll(sel: string): MockElement[] {
    const results: MockElement[] = [];
    const check = (el: MockElement) => {
      const cls = sel.startsWith('.') ? sel.slice(1) : sel;
      if (el.className && el.className.split(/\s+/).includes(cls)) {
        results.push(el);
      }
      for (const c of el.children) {
        if (c instanceof MockElement) check(c);
      }
    };
    for (const c of this.children) {
      if (c instanceof MockElement) check(c);
    }
    return results;
  }
}

if (!globalThis.document) {
  globalThis.document = {
    body: { style: {} },
    createElement: (tag: string) => new MockElement(tag),
    createElementNS: (_ns: string, tag: string) => new MockElement(tag),
    querySelectorAll: () => [],
    querySelector: () => null,
    getElementById: () => null,
  } as any;
}
if (!(globalThis as any).E) {
  (globalThis as any).E = (tag: string, attrs?: any, children?: any) => {
    const el = new MockElement(tag);
    if (attrs) {
      for (const [k, v] of Object.entries(attrs)) {
        if (k === 'class' || k === 'className') {
          el.className = v as string;
        } else if (k === 'style') {
          el.style = typeof v === 'string' ? { cssText: v } : (v as any);
        } else if (typeof v === 'function') {
          (el as any)[k] = v;
        } else {
          el.setAttribute(k, String(v));
        }
      }
    }
    if (children) {
      const arr = Array.isArray(children) ? children : [children];
      for (const c of arr) {
        if (c != null && c !== '') el.appendChild(c);
      }
    }
    return el;
  };
}
if (!(globalThis as any).rpc) {
  (globalThis as any).rpc = { declare: vi.fn() };
}
if (!(globalThis as any).localStorage) {
  (globalThis as any).localStorage = { getItem: vi.fn(), setItem: vi.fn() };
}

let extractServerInboundSectionId: any;
let getConfiguredServerInbounds: any;
let computeInboundsRuntimeSummary: any;
let resetInboundTrafficStateForTests: any;
let renderCollapsibleInboundsBlock: any;
let formatActiveServersCount: any;
let showInboundClientsModal: any;

describe('inboundServers', () => {
  beforeAll(async () => {
    const mod = await import('../inboundServers');
    extractServerInboundSectionId = mod.extractServerInboundSectionId;
    getConfiguredServerInbounds = mod.getConfiguredServerInbounds;
    computeInboundsRuntimeSummary = mod.computeInboundsRuntimeSummary;
    resetInboundTrafficStateForTests = mod.resetInboundTrafficStateForTests;
    renderCollapsibleInboundsBlock = mod.renderCollapsibleInboundsBlock;
    formatActiveServersCount = mod.formatActiveServersCount;
    showInboundClientsModal = mod.showInboundClientsModal;
  });

  beforeEach(() => {
    resetInboundTrafficStateForTests();
    (globalThis as any).L = { env: { lang: 'ru' } };
    (globalThis as any).uci = {
      sections: vi.fn().mockReturnValue([]),
      get: vi.fn().mockReturnValue(undefined),
    };
  });

  describe('extractServerInboundSectionId', () => {
    it('extracts sectionId from metadata.type (sing-box / tachyon-core format)', () => {
      expect(
        extractServerInboundSectionId({
          metadata: {
            type: 'fptn/server-FptnSrv-in',
            sourceIP: '10.88.0.4',
          },
        }),
      ).toBe('FptnSrv');

      expect(
        extractServerInboundSectionId({
          metadata: {
            type: 'vless/server-VlessReality-in',
            sourceIP: '192.168.1.206',
          },
        }),
      ).toBe('VlessReality');
    });

    it('extracts sectionId from metadata.inbound or rule fallback', () => {
      expect(
        extractServerInboundSectionId({
          metadata: {
            inbound: 'server-TrojanTls-in',
          },
        }),
      ).toBe('TrojanTls');

      expect(
        extractServerInboundSectionId({
          metadata: {
            type: 'mixed',
          },
          rule: 'inbound=server-Socks5Srv-in domain_suffix=google.com => route(main-out)',
        }),
      ).toBe('Socks5Srv');
    });

    it('returns null for regular LAN TProxy connections', () => {
      expect(
        extractServerInboundSectionId({
          metadata: {
            type: 'tproxy/tproxy-in',
            sourceIP: '192.168.1.100',
          },
          rule: 'inbound=tproxy-in => route(main-out)',
        }),
      ).toBeNull();
    });
  });

  describe('getConfiguredServerInbounds & computeInboundsRuntimeSummary', () => {
    it('aggregates configured inbounds, active connections, clients, and cumulative traffic', () => {
      (globalThis as any).uci = {
        sections: vi.fn().mockImplementation((_pkg: string, type: string) => {
          if (type === 'server') {
            return [
              {
                '.name': 'VlessReality',
                enabled: '1',
                label: 'Auto VLESS Reality',
                protocol: 'vless',
                security: 'reality',
                transport: 'tcp',
                listen_port: '20443',
                open_firewall_port: '1',
                routing_mode: 'rules',
              },
              {
                '.name': 'FptnSrv',
                enabled: '1',
                label: 'Auto FPTN',
                protocol: 'fptn',
                security: 'tls',
                listen_port: '28443',
                routing_mode: 'section',
                routing_section: 'XboxDns',
              },
              {
                '.name': 'DisabledSrv',
                enabled: '0',
                label: 'Disabled Hysteria2',
                protocol: 'hysteria2',
                listen_port: '24443',
              },
            ];
          }
          if (type === 'section') {
            return [
              {
                '.name': 'XboxDns',
                label: 'Xbox & CDN',
              },
            ];
          }
          return [];
        }),
      };

      const inbounds = getConfiguredServerInbounds();
      expect(inbounds).toHaveLength(3);
      expect(inbounds[0].protocolShort).toBe('VLESS');
      expect(inbounds[0].security).toBe('Reality');
      expect(inbounds[0].openFirewallPort).toBe(true);
      expect(inbounds[1].routingLabel).toContain('Xbox & CDN');

      const hostnames = new Map<string, string>([
        ['192.168.1.206', 'OpenWrt-206'],
      ]);

      const rawConnections = [
        {
          id: 'conn-1',
          metadata: {
            network: 'tcp',
            type: 'vless/server-VlessReality-in',
            sourceIP: '192.168.1.206',
            sourcePort: '51234',
            host: 'www.cloudflare.com',
            destinationPort: '443',
          },
          download: 4096,
          upload: 1024,
          chains: ['main-out'],
          rule: 'inbound=server-VlessReality-in => route(main-out)',
        },
        {
          id: 'conn-2',
          metadata: {
            network: 'tcp',
            type: 'fptn/server-FptnSrv-in',
            sourceIP: '10.88.0.4',
            sourcePort: '49156',
            host: 'www.gstatic.com',
            destinationPort: '443',
          },
          download: 2048,
          upload: 512,
          chains: ['XboxDns-out'],
          rule: 'inbound=server-FptnSrv-in => route(XboxDns-out)',
        },
      ];

      const summary1 = computeInboundsRuntimeSummary(
        inbounds,
        rawConnections,
        hostnames,
        1000,
      );

      expect(summary1.totalCount).toBe(3);
      expect(summary1.enabledCount).toBe(2);
      expect(summary1.activeInboundsCount).toBe(2);
      expect(summary1.totalActiveConns).toBe(2);
      expect(summary1.totalActiveClients).toBe(2);
      expect(summary1.totalDownload).toBe(6144);
      expect(summary1.totalUpload).toBe(1536);

      const vlessStats = summary1.bySection.get('VlessReality')!;
      expect(vlessStats.activeConns).toBe(1);
      expect(vlessStats.clients[0].name).toBe('OpenWrt-206');
      expect(vlessStats.clients[0].download).toBe(4096);

      // When conn-1 closes, cumulative traffic is preserved while activeConns drops to 0
      const summary2 = computeInboundsRuntimeSummary(
        inbounds,
        [rawConnections[1]],
        hostnames,
        3000,
      );
      expect(summary2.totalActiveConns).toBe(1);
      expect(summary2.totalDownload).toBe(6144);
      expect(summary2.bySection.get('VlessReality')?.activeConns).toBe(0);
      expect(summary2.bySection.get('VlessReality')?.download).toBe(4096);
    });
  });

  describe('formatActiveServersCount', () => {
    it('returns unabbreviated text with correct Russian grammar', () => {
      expect(formatActiveServersCount(1, 1)).toBe('1 активный');
      expect(formatActiveServersCount(2, 2)).toBe('2 активных');
      expect(formatActiveServersCount(5, 5)).toBe('5 активных');
      expect(formatActiveServersCount(1, 2)).toBe('1 / 2 активных');
    });
  });

  describe('renderCollapsibleInboundsBlock', () => {
    it('renders 2-row card layout with unabbreviated badge, green port pill, and no collapse btn or client bar', () => {
      const container = (globalThis as any).E('div');
      const inbounds = [
        {
          sectionId: 'VlessReality',
          label: 'Auto VLESS Reality',
          country: '',
          enabled: true,
          protocol: 'vless',
          protocolShort: 'VLESS',
          protocolFull: 'VLESS (Reality)',
          security: 'Reality',
          port: '20443',
        },
      ];
      const summary = {
        totalCount: 1,
        enabledCount: 1,
        activeInboundsCount: 1,
        totalActiveConns: 3,
        totalActiveClients: 2,
        totalDownload: 1048576,
        totalUpload: 524288,
        totalDownSpeed: 1024,
        totalUpSpeed: 512,
        bySection: new Map([
          [
            'VlessReality',
            {
              sectionId: 'VlessReality',
              activeConns: 3,
              activeClientsCount: 2,
              download: 1048576,
              upload: 524288,
              upSpeed: 512,
              downSpeed: 1024,
              clients: [
                {
                  ip: '192.168.1.50',
                  name: 'Client-1',
                  activeConns: 3,
                  download: 1048576,
                  upload: 524288,
                  upSpeed: 512,
                  downSpeed: 1024,
                  lastSeenAt: Date.now(),
                  isOnline: true,
                  targets: ['example.com'],
                  chain: 'main-out',
                },
              ],
            },
          ],
        ]),
        recentClients: [],
      };

      renderCollapsibleInboundsBlock({
        container,
        servers: inbounds,
        summary,
        isTachyonRunning: true,
        storageKey: 'tachyon_test_collapse',
        showGoToServersLink: true,
        onRerender: vi.fn(),
      });

      // Verify header does not contain sigma symbol ∑
      const trafficPills = container.querySelectorAll('.tachyon-traffic-pill');
      expect(trafficPills.length).toBeGreaterThan(0);
      for (const pill of trafficPills) {
        expect(pill.textContent).not.toContain('∑');
      }

      // Verify active count badge is unabbreviated
      const protoPills = container.querySelectorAll('.tachyon-protocol-pill');
      expect(
        protoPills.some((p: any) => p.textContent.includes('1 активный')),
      ).toBe(true);

      // Verify collapse button is removed from header
      const collapseBtns = container.querySelectorAll(
        '.tachyon-inbound-collapse-btn',
      );
      expect(collapseBtns.length).toBe(0);

      // Verify active clients bar is removed from spoiler
      const clientBars = container.querySelectorAll(
        '.tachyon-inbounds-active-clients-bar',
      );
      expect(clientBars.length).toBe(0);

      // Verify port pill has online (green) status
      const onlinePortPills = container.querySelectorAll(
        '.tachyon-port-pill--online',
      );
      expect(onlinePortPills.length).toBeGreaterThan(0);

      // Verify card structure has top and bottom rows
      const cards = container.querySelectorAll('.tachyon-inbound-card');
      expect(cards.length).toBe(1);
      const topRows = container.querySelectorAll('.tachyon-inbound-card__top');
      const bottomRows = container.querySelectorAll(
        '.tachyon-inbound-card__bottom',
      );
      expect(topRows.length).toBe(1);
      expect(bottomRows.length).toBe(1);
    });

    it('renders offline (red) port pill and disabled card when server is disabled', () => {
      const container = (globalThis as any).E('div');
      const inbounds = [
        {
          sectionId: 'DisabledSrv',
          label: 'Disabled Server',
          country: '',
          enabled: false,
          protocol: 'vless',
          protocolShort: 'VLESS',
          protocolFull: 'VLESS',
          security: '',
          port: '20443',
        },
      ];
      const summary = {
        totalCount: 1,
        enabledCount: 0,
        activeInboundsCount: 0,
        totalActiveConns: 0,
        totalActiveClients: 0,
        totalDownload: 0,
        totalUpload: 0,
        totalDownSpeed: 0,
        totalUpSpeed: 0,
        bySection: new Map(),
        recentClients: [],
      };

      renderCollapsibleInboundsBlock({
        container,
        servers: inbounds,
        summary,
        isTachyonRunning: true,
        storageKey: 'tachyon_test_collapse',
        showGoToServersLink: false,
        onRerender: vi.fn(),
      });

      const offlinePortPills = container.querySelectorAll(
        '.tachyon-port-pill--offline',
      );
      expect(offlinePortPills.length).toBe(1);
    });

    it('renders idle status with amber class when activeConns is 0', () => {
      const container = (globalThis as any).E('div');
      const inbounds = [
        {
          sectionId: 'VlessReality',
          label: 'Idle Server',
          country: '',
          enabled: true,
          protocol: 'vless',
          protocolShort: 'VLESS',
          protocolFull: 'VLESS',
          security: '',
          port: '20443',
        },
      ];
      const summary = {
        totalCount: 1,
        enabledCount: 1,
        activeInboundsCount: 0,
        totalActiveConns: 0,
        totalActiveClients: 0,
        totalDownload: 0,
        totalUpload: 0,
        totalDownSpeed: 0,
        totalUpSpeed: 0,
        bySection: new Map([
          [
            'VlessReality',
            {
              sectionId: 'VlessReality',
              activeConns: 0,
              activeClientsCount: 0,
              download: 0,
              upload: 0,
              upSpeed: 0,
              downSpeed: 0,
              clients: [],
            },
          ],
        ]),
        recentClients: [],
      };

      renderCollapsibleInboundsBlock({
        container,
        servers: inbounds,
        summary,
        isTachyonRunning: true,
        storageKey: 'tachyon_test_collapse',
        showGoToServersLink: false,
        onRerender: vi.fn(),
      });

      const idlePill = container.querySelectorAll('.tachyon-stat-pill--idle');
      expect(idlePill.length).toBeGreaterThan(0);
      expect(idlePill[0].textContent).toContain('Ожидание');
    });

    it('opens connected clients modal when clicking the card', () => {
      const showModalMock = vi.fn();
      (globalThis as any).ui = {
        showModal: showModalMock,
        hideModal: vi.fn(),
      };

      const container = (globalThis as any).E('div');
      const inbounds = [
        {
          sectionId: 'VlessReality',
          label: 'Auto VLESS Reality',
          country: '',
          enabled: true,
          protocol: 'vless',
          protocolShort: 'VLESS',
          protocolFull: 'VLESS',
          security: '',
          port: '20443',
        },
      ];
      const summary = {
        totalCount: 1,
        enabledCount: 1,
        activeInboundsCount: 1,
        totalActiveConns: 1,
        totalActiveClients: 1,
        totalDownload: 1000,
        totalUpload: 500,
        totalDownSpeed: 0,
        totalUpSpeed: 0,
        bySection: new Map([
          [
            'VlessReality',
            {
              sectionId: 'VlessReality',
              activeConns: 1,
              activeClientsCount: 1,
              download: 1000,
              upload: 500,
              upSpeed: 0,
              downSpeed: 0,
              clients: [
                {
                  ip: '10.100.100.206',
                  name: '3E:33:55:3E:94:25',
                  activeConns: 1,
                  download: 1000,
                  upload: 500,
                  upSpeed: 0,
                  downSpeed: 0,
                  lastSeenAt: Date.now(),
                  isOnline: true,
                  targets: ['google.com'],
                  chain: 'main-out',
                },
              ],
            },
          ],
        ]),
        recentClients: [],
      };

      renderCollapsibleInboundsBlock({
        container,
        servers: inbounds,
        summary,
        isTachyonRunning: true,
        storageKey: 'tachyon_test_collapse',
        showGoToServersLink: false,
        onRerender: vi.fn(),
      });

      const card = container.querySelectorAll('.tachyon-inbound-card')[0];
      expect(card).toBeDefined();

      // Trigger click on card
      const fakeEv = { preventDefault: vi.fn(), stopPropagation: vi.fn() };
      card.click(fakeEv);

      expect(showModalMock).toHaveBeenCalledTimes(1);
      const title = showModalMock.mock.calls[0][0];
      expect(title).toContain('Auto VLESS Reality');

      const modalEl = showModalMock.mock.calls[0][1];
      expect(modalEl).toBeDefined();
      const tables = modalEl.querySelectorAll(
        '.tachyon-inbound-clients-modal__table',
      );
      expect(tables.length).toBe(1);
    });

    it('falls back to window.L.showModal when ui is not on window/globalThis', () => {
      delete (globalThis as any).ui;
      delete (globalThis as any).window?.ui;
      const lShowModal = vi.fn();
      (globalThis as any).window = (globalThis as any).window || {};
      (globalThis as any).window.L = {
        showModal: lShowModal,
        hideModal: vi.fn(),
      };

      const server = {
        sectionId: 'test_sec',
        label: 'Shadowsocks Node',
        country: '',
        enabled: true,
        protocol: 'shadowsocks',
        protocolShort: 'SS',
        protocolFull: 'Shadowsocks',
        security: '',
        port: '8388',
      };
      const summary = {
        totalCount: 1,
        enabledCount: 1,
        activeInboundsCount: 1,
        totalActiveConns: 0,
        totalActiveClients: 0,
        totalDownload: 0,
        totalUpload: 0,
        totalDownSpeed: 0,
        totalUpSpeed: 0,
        bySection: new Map(),
        recentClients: [],
      };

      showInboundClientsModal(server, summary, true);

      expect(lShowModal).toHaveBeenCalledTimes(1);
      expect(lShowModal.mock.calls[0][0]).toContain('Shadowsocks Node');
    });
  });
});
