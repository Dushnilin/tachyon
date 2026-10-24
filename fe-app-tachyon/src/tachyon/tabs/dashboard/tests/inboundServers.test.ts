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
if (!globalThis.document) {
  globalThis.document = {
    body: { style: {} },
    createElement: () => ({ style: {} }),
    createElementNS: () => ({ style: {} }),
    querySelectorAll: () => [],
    querySelector: () => null,
    getElementById: () => null,
  } as any;
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

describe('inboundServers', () => {
  beforeAll(async () => {
    const mod = await import('../inboundServers');
    extractServerInboundSectionId = mod.extractServerInboundSectionId;
    getConfiguredServerInbounds = mod.getConfiguredServerInbounds;
    computeInboundsRuntimeSummary = mod.computeInboundsRuntimeSummary;
    resetInboundTrafficStateForTests = mod.resetInboundTrafficStateForTests;
  });

  beforeEach(() => {
    resetInboundTrafficStateForTests();
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
});
