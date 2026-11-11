/* eslint-disable @typescript-eslint/no-explicit-any */
import { describe, it, expect } from 'vitest';
import { styles as monitoringStyles } from '../styles';
import {
  normalizeConnectionsPayload,
  getConnectionDataSource,
  getConnectionTupleKey,
  mergeCoreAndConntrackConnections,
  getListValues,
  getUrlTestIds,
  getUrlTestTag,
  getDisplayName,
  buildRouteDisplayNames,
  getRouteDisplayNameByTag,
  getRouteTagFromRule,
  getServerDisplayNameByInboundTag,
  getDeviceName,
  getServerSourceNameByIp,
  getDeviceFilterLabel,
  getSourceCellParts,
  getTargetCellParts,
  getNetwork,
  formatMatchedRuleSummary,
  getRouteTooltip,
  sortConnections,
  normalizeSearchValue,
  getSearchValues,
  filterVisibleConnections,
  MonitoredConnection,
} from '../filters';

describe('monitoring filters and resolution', () => {
  it('normalizes connections payload', () => {
    expect(normalizeConnectionsPayload(null)).toEqual({});
    expect(normalizeConnectionsPayload([])).toEqual({});
    expect(normalizeConnectionsPayload('invalid')).toEqual({});
    expect(normalizeConnectionsPayload({ connections: [] })).toEqual({
      connections: [],
    });
  });

  it('extracts list values correctly', () => {
    expect(getListValues()).toEqual([]);
    expect(getListValues(['a', 'b', ''])).toEqual(['a', 'b']);
    expect(getListValues('one two   three')).toEqual(['one', 'two', 'three']);
  });

  it('determines urltest IDs and tags', () => {
    expect(getUrlTestIds({} as any)).toEqual([]);
    expect(getUrlTestIds({ urltest_enabled: '1' } as any)).toEqual(['urltest']);
    expect(getUrlTestIds({ urltests: ['t1', 't2'] } as any)).toEqual([
      't1',
      't2',
    ]);

    expect(getUrlTestTag('mysection', 'urltest')).toBe('mysection-urltest-out');
    expect(getUrlTestTag('mysection', 'custom')).toBe(
      'mysection-urltest-custom-out',
    );
  });

  it('resolves display name from section', () => {
    expect(
      getDisplayName({
        label: 'Label Name',
        name: 'Raw Name',
        '.name': 's1',
      } as any),
    ).toBe('Label Name');
    expect(getDisplayName({ name: 'Raw Name', '.name': 's1' } as any)).toBe(
      'Raw Name',
    );
    expect(getDisplayName({ '.name': 's1' } as any)).toBe('s1');
  });

  it('builds route display names and resolves tags correctly', () => {
    const { routeDisplayNames, serverDisplayNames } = buildRouteDisplayNames([
      {
        '.name': 'proxy_sec',
        '.type': 'section',
        label: 'My Proxy',
        enabled: '1',
      } as any,
      {
        '.name': 'srv1',
        '.type': 'server',
        label: 'Shadowsocks Inbound',
        enabled: '1',
      } as any,
    ]);

    expect(routeDisplayNames['bypass-out']).toBe('Bypass');
    expect(routeDisplayNames['proxy_sec-out']).toBe('My Proxy');
    expect(serverDisplayNames['server-srv1-in']).toBe('Shadowsocks Inbound');

    expect(getRouteDisplayNameByTag('bypass-out')).toBe('Bypass');
    expect(getRouteDisplayNameByTag('proxy_sec-1-out')).toBe('My Proxy');
    expect(getRouteDisplayNameByTag('proxy_sec')).toBe('My Proxy');
    expect(getRouteDisplayNameByTag('nonexistent')).toBe('');

    expect(getServerDisplayNameByInboundTag('server-srv1-in')).toBe(
      'Shadowsocks Inbound',
    );
  });

  it('extracts route tag from rule string', () => {
    expect(getRouteTagFromRule('rule => route("proxy_sec-out")')).toBe(
      'proxy_sec-out',
    );
    expect(getRouteTagFromRule("rule => route('bypass-out')")).toBe(
      'bypass-out',
    );
    expect(getRouteTagFromRule('invalid rule')).toBe('');
  });

  it('resolves device names and labels', () => {
    const devices = {
      '192.168.1.50': 'IP: 192.168.1.50 — Smart TV',
      '192.168.1.60': 'Laptop',
      '192.168.1.70': '192.168.1.70',
    };

    expect(getDeviceName('192.168.1.50', devices)).toBe('Smart TV');
    expect(getDeviceName('192.168.1.60', devices)).toBe('Laptop');
    expect(getDeviceName('192.168.1.70', devices)).toBe('');
    expect(getDeviceName('192.168.1.99', devices)).toBe('');

    expect(getDeviceFilterLabel('192.168.1.50', [], devices)).toBe(
      'Smart TV (192.168.1.50)',
    );
    expect(getDeviceFilterLabel('192.168.1.99', [], devices)).toBe(
      '192.168.1.99',
    );
  });

  it('resolves server source name by IP when connection inbound matches a known server', () => {
    buildRouteDisplayNames([
      {
        '.name': 'myserver',
        '.type': 'server',
        label: 'My Inbound Server',
        enabled: '1',
      } as any,
    ]);

    const conn: MonitoredConnection = {
      id: 'conn-1',
      lastSeenAt: Date.now(),
      metadata: {
        sourceIP: '10.0.0.5',
        type: 'mixed/server-myserver-in',
      },
    };

    expect(getServerSourceNameByIp('10.0.0.5', [conn])).toBe(
      'My Inbound Server',
    );
    expect(getServerSourceNameByIp('10.0.0.99', [conn])).toBe('');
  });

  it('formats cell parts for source and target', () => {
    const conn: MonitoredConnection = {
      id: 'c1',
      lastSeenAt: Date.now(),
      metadata: {
        sourceIP: '192.168.1.50',
        destinationIP: '1.1.1.1',
        destinationPort: 443,
        host: 'one.one.one.one',
        network: 'tcp',
      },
      chains: ['proxy_sec'],
    };

    const target = getTargetCellParts(conn);
    expect(target.primary).toBe('one.one.one.one');
    expect(target.searchValue).toContain('1.1.1.1');

    const source = getSourceCellParts(conn, [conn], {
      '192.168.1.50': 'IP: 192.168.1.50 — Smart TV',
    });
    expect(source.primary).toBe('Smart TV');
    expect(source.ip).toBe('192.168.1.50');
    expect(source.copyValue).toBe('Smart TV (192.168.1.50)');

    expect(getNetwork(conn)).toBe('tcp');
  });

  it('sorts connections correctly by tab', () => {
    const conn1: MonitoredConnection = {
      id: '1',
      lastSeenAt: 1000,
      start: '2026-01-01T00:00:00Z',
      closedAt: 5000,
    };
    const conn2: MonitoredConnection = {
      id: '2',
      lastSeenAt: 2000,
      start: '2026-01-01T00:01:00Z',
      closedAt: 3000,
    };

    const sortedActive = sortConnections([conn1, conn2], 'active');
    expect(sortedActive[0].id).toBe('2'); // conn2 started later

    const sortedClosed = sortConnections([conn1, conn2], 'closed');
    expect(sortedClosed[0].id).toBe('1'); // conn1 closed later (5000 vs 3000)
  });

  it('normalizes search value and extracts searchable tokens', () => {
    expect(normalizeSearchValue('  YouTube  COM ')).toBe('youtube com');

    const conn: MonitoredConnection = {
      id: 'conn-search-1',
      lastSeenAt: Date.now(),
      metadata: {
        sourceIP: '192.168.1.10',
        destinationIP: '8.8.8.8',
        destinationPort: 53,
        host: 'dns.google',
        network: 'udp',
      },
    };

    const searchTokens = getSearchValues(conn, [conn], {});
    expect(searchTokens).toContain('conn-search-1');
    expect(searchTokens).toContain('dns.google:53');
    expect(searchTokens).toContain('udp');
  });

  it('filters visible connections based on device, route, and search query', () => {
    buildRouteDisplayNames([
      {
        '.name': 'vpn_sec',
        '.type': 'section',
        label: 'VPN Tunnel',
        enabled: '1',
      } as any,
    ]);

    const activeConns: MonitoredConnection[] = [
      {
        id: '1',
        lastSeenAt: 1000,
        metadata: {
          sourceIP: '192.168.1.100',
          host: 'github.com',
          destinationPort: 443,
          network: 'tcp',
        },
        chains: ['vpn_sec'],
      },
      {
        id: '2',
        lastSeenAt: 1100,
        metadata: {
          sourceIP: '192.168.1.101',
          host: 'google.com',
          destinationPort: 443,
          network: 'tcp',
        },
        chains: ['bypass-out'],
      },
    ];

    // Filter by all
    const all = filterVisibleConnections({
      deviceFilter: 'all',
      routeFilter: 'all',
      searchQuery: '',
      tab: 'active',
      activeConnections: activeConns,
      closedConnections: [],
    });
    expect(all.length).toBe(2);

    // Filter by device
    const deviceFiltered = filterVisibleConnections({
      deviceFilter: '192.168.1.100',
      routeFilter: 'all',
      searchQuery: '',
      tab: 'active',
      activeConnections: activeConns,
      closedConnections: [],
    });
    expect(deviceFiltered.length).toBe(1);
    expect(deviceFiltered[0].id).toBe('1');

    // Filter by route
    const routeFiltered = filterVisibleConnections({
      deviceFilter: 'all',
      routeFilter: 'VPN Tunnel',
      searchQuery: '',
      tab: 'active',
      activeConnections: activeConns,
      closedConnections: [],
    });
    expect(routeFiltered.length).toBe(1);
    expect(routeFiltered[0].id).toBe('1');

    // Filter by search
    const searchFiltered = filterVisibleConnections({
      deviceFilter: 'all',
      routeFilter: 'all',
      searchQuery: 'google',
      tab: 'active',
      activeConnections: activeConns,
      closedConnections: [],
    });
    expect(searchFiltered.length).toBe(1);
    expect(searchFiltered[0].id).toBe('2');
  });

  it.each(['active', 'closed'] as const)(
    'searches session targets instead of candidate rule sets in the %s tab',
    (tab) => {
      const rule =
        'rule_set=[zapret-community-rutracker_lampa-rs zapret-community-youtube-rs] => route(zapret-out)';
      const connections: MonitoredConnection[] = [
        {
          id: 'dota',
          lastSeenAt: 1000,
          metadata: { host: 'cdn.dota2.net', network: 'tcp' },
          rule,
        },
        {
          id: 'image',
          lastSeenAt: 1000,
          metadata: { host: 'i.ytimg.com', network: 'udp' },
          rulePayload: rule,
        },
        {
          id: 'tracker',
          lastSeenAt: 1000,
          metadata: { host: 'rutracker.net', network: 'tcp' },
          rule,
          rulePayload: rule,
        },
      ];
      const search = (searchQuery: string) =>
        filterVisibleConnections({
          deviceFilter: 'all',
          routeFilter: 'all',
          searchQuery,
          tab,
          activeConnections: tab === 'active' ? connections : [],
          closedConnections: tab === 'closed' ? connections : [],
        })
          .map((connection) => connection.id)
          .sort();

      expect(search('rutracker')).toEqual(['tracker']);
      expect(search('  RuTracker  ')).toEqual(['tracker']);
      expect(search('rutracker.net')).toEqual(['tracker']);
      expect(search('.net')).toEqual(['dota', 'tracker']);
      expect(search('.com')).toEqual(['image']);
      expect(search('rutracker_lampa')).toEqual([]);
      expect(search('community:rutracker_lampa')).toEqual([]);
      expect(search('youtube')).toEqual([]);
      expect(search('')).toEqual(['dota', 'image', 'tracker']);
    },
  );

  it('distinguishes QUIC from plain UDP and builds matched rule tooltips', () => {
    const plainUdp: MonitoredConnection = {
      id: 'u1',
      lastSeenAt: 1000,
      metadata: {
        network: 'udp',
        destinationIP: '8.8.8.8',
        destinationPort: 53,
      },
    };
    const quicByPort443Host: MonitoredConnection = {
      id: 'q1',
      lastSeenAt: 1000,
      metadata: {
        network: 'udp',
        host: 'gemini.google.com',
        destinationPort: 443,
      },
      chains: ['Main-out', 'NL VLESS #1'],
      rule: 'inbound=[tproxy-in tproxy6-in] rule_set=[Main-community-google_ai-rs] => route(Main-out)',
      rulePayload: 'rule_set=Main-community-google_ai-rs',
    };
    const quicByProtocol: MonitoredConnection = {
      id: 'q2',
      lastSeenAt: 1000,
      metadata: {
        network: 'udp',
        protocol: 'quic',
        destinationPort: 8443,
      },
    };

    expect(getNetwork(plainUdp)).toBe('udp');
    expect(getNetwork(quicByPort443Host)).toBe('quic');
    expect(getNetwork(quicByProtocol)).toBe('quic');

    expect(formatMatchedRuleSummary(quicByPort443Host)).toBe(
      'rule_set=community:google_ai',
    );
    const tooltip = getRouteTooltip(quicByPort443Host, 'Main');
    expect(tooltip).toContain('Section: Main');
    expect(tooltip).toContain(
      'Matched condition: rule_set=community:google_ai',
    );
    expect(tooltip).toContain('Node: NL VLESS #1');

    const prevL = (globalThis as any).L;
    try {
      (globalThis as any).L = { env: { lang: 'ru' } };
      const ruTooltip = getRouteTooltip(quicByPort443Host, 'Main');
      expect(ruTooltip).toContain('Секция: Main');
      expect(ruTooltip).toContain(
        'Сработавшее условие: rule_set=community:google_ai',
      );
      expect(ruTooltip).toContain('Правило:');
      expect(ruTooltip).toContain('Узел: NL VLESS #1');
      expect(ruTooltip).not.toContain('Matched condition:');
    } finally {
      (globalThis as any).L = prevL;
    }
  });

  it('prevents protocol badges from truncating tcp/udp/quic into single-letter ellipsis', () => {
    const networkRuleMatch = monitoringStyles.match(
      /\.tachyon_monitoring-page__network\s*\{([^}]+)\}/,
    );
    expect(networkRuleMatch).not.toBeNull();
    const networkDeclarations = networkRuleMatch?.[1] || '';
    expect(networkDeclarations).toContain('box-sizing: border-box');
    expect(networkDeclarations).toContain('max-width: none');
    expect(networkDeclarations).toContain('overflow: visible');
    expect(networkDeclarations).toContain('text-overflow: clip');

    const col2WidthMatch = monitoringStyles.match(
      /\.tachyon_monitoring-page__table th:nth-child\(2\)\s*\{\s*width:\s*([\d.]+)%/,
    );
    expect(col2WidthMatch).not.toBeNull();
    expect(Number(col2WidthMatch?.[1])).toBeGreaterThanOrEqual(8);
  });

  it('filters connections by multiple selected routes, sources, and network protocols', () => {
    buildRouteDisplayNames([
      {
        '.name': 'main',
        '.type': 'section',
        label: 'Main',
        enabled: '1',
      } as any,
      {
        '.name': 'zapret3_youtube_section',
        '.type': 'section',
        label: 'zapret3_youtube_section',
        action: 'zapret2',
        enabled: '1',
      } as any,
    ]);

    const connections: MonitoredConnection[] = [
      {
        id: 'c1',
        lastSeenAt: 1000,
        chains: ['main-out'],
        metadata: {
          network: 'tcp',
          sourceIP: '192.168.1.8',
          host: 'api.telegram.org',
        },
      },
      {
        id: 'c2',
        lastSeenAt: 1000,
        chains: ['zapret3_youtube_section-out'],
        metadata: {
          network: 'udp',
          sourceIP: '192.168.1.44',
          host: 'www.youtube.com',
          destinationPort: 443,
        },
      },
      {
        id: 'c3',
        lastSeenAt: 1000,
        chains: ['bypass-out'],
        metadata: {
          network: 'tcp',
          sourceIP: 'vless_h',
          host: 'mtalk.google.com',
          destinationPort: 5228,
        },
      },
      {
        id: 'c4',
        lastSeenAt: 1000,
        chains: ['direct-out'],
        metadata: {
          network: 'udp',
          sourceIP: 'vless_h',
          destinationIP: '8.8.8.8',
          destinationPort: 53,
        },
      },
    ];

    const byTwoRoutes = filterVisibleConnections({
      routeFilters: new Set(['Main', 'Bypass']),
      searchQuery: '',
      tab: 'active',
      activeConnections: connections,
      closedConnections: [],
    });
    expect(byTwoRoutes.map((c) => c.id)).toEqual(['c1', 'c3']);

    const byTwoDevices = filterVisibleConnections({
      deviceFilters: ['192.168.1.44', 'vless_h'],
      searchQuery: '',
      tab: 'active',
      activeConnections: connections,
      closedConnections: [],
    });
    expect(byTwoDevices.map((c) => c.id)).toEqual(['c2', 'c3', 'c4']);

    const byQuicAndTcp = filterVisibleConnections({
      networkFilters: new Set(['quic', 'tcp']),
      searchQuery: '',
      tab: 'active',
      activeConnections: connections,
      closedConnections: [],
    });
    expect(byQuicAndTcp.map((c) => c.id)).toEqual(['c1', 'c2', 'c3']);
  });

  it('deduplicates core and conntrack connections by 5-tuple and filters by dataSourceFilter', () => {
    const coreConns = [
      {
        id: 'core-1',
        metadata: {
          network: 'tcp',
          sourceIP: '192.168.1.50',
          sourcePort: '54321',
          destinationIP: '142.250.74.110',
          destinationPort: '443',
          host: 'www.youtube.com',
        },
        chains: ['youtube-out'],
      },
    ];
    const conntrackConns = [
      {
        // Duplicate 5-tuple of core-1 -> must be deduplicated
        id: 'ct:tcp:192.168.1.50:54321:142.250.74.110:443',
        dataSource: 'conntrack' as const,
        metadata: {
          network: 'tcp',
          type: 'conntrack',
          sourceIP: '192.168.1.50',
          sourcePort: '54321',
          destinationIP: '142.250.74.110',
          destinationPort: '443',
        },
        chains: ['direct-out'],
      },
      {
        // Unique conntrack session bypassing core -> must be preserved
        id: 'ct:udp:192.168.1.50:60123:1.1.1.1:443',
        dataSource: 'conntrack' as const,
        metadata: {
          network: 'udp',
          type: 'conntrack',
          sourceIP: '192.168.1.50',
          sourcePort: '60123',
          destinationIP: '1.1.1.1',
          destinationPort: '443',
        },
        chains: ['zapret2-out'],
      },
    ];

    expect(getConnectionTupleKey(coreConns[0])).toBe(
      'tcp|192.168.1.50|54321|142.250.74.110|443',
    );
    const merged = mergeCoreAndConntrackConnections(coreConns, conntrackConns);
    expect(merged.map((c) => c.id)).toEqual([
      'core-1',
      'ct:udp:192.168.1.50:60123:1.1.1.1:443',
    ]);
    expect(getConnectionDataSource(merged[0])).toBe('core');
    expect(getConnectionDataSource(merged[1])).toBe('conntrack');

    const monitored = merged.map((c, idx) => ({
      ...c,
      id: c.id || String(idx),
      lastSeenAt: 1000,
    }));

    expect(
      filterVisibleConnections({
        dataSourceFilter: 'all',
        searchQuery: '',
        tab: 'active',
        activeConnections: monitored,
        closedConnections: [],
      }).map((c) => c.id),
    ).toEqual(['core-1', 'ct:udp:192.168.1.50:60123:1.1.1.1:443']);

    expect(
      filterVisibleConnections({
        dataSourceFilter: 'core',
        searchQuery: '',
        tab: 'active',
        activeConnections: monitored,
        closedConnections: [],
      }).map((c) => c.id),
    ).toEqual(['core-1']);

    expect(
      filterVisibleConnections({
        dataSourceFilter: 'conntrack',
        searchQuery: '',
        tab: 'active',
        activeConnections: monitored,
        closedConnections: [],
      }).map((c) => c.id),
    ).toEqual(['ct:udp:192.168.1.50:60123:1.1.1.1:443']);
  });
});
