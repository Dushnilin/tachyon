/* eslint-disable @typescript-eslint/no-explicit-any */
import { describe, it, expect } from 'vitest';
import {
  normalizeConnectionsPayload,
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
});
