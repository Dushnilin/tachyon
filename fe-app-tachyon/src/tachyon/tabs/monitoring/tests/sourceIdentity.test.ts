import { beforeEach, describe, expect, it } from 'vitest';
import {
  buildRouteDisplayNames,
  filterVisibleConnections,
  getConnectionInboundTag,
  getDeviceFilterLabel,
  getSourceCellParts,
  type MonitoredConnection,
} from '../filters';

const devices = { '192.168.1.50': 'IP: 192.168.1.50 — Laptop' };

function connection(sourceIP?: string): MonitoredConnection {
  return {
    id: sourceIP || 'unknown',
    lastSeenAt: 1000,
    metadata: { sourceIP, type: 'mixed/server-mixed-in' },
  };
}

describe('monitoring inbound client identity', () => {
  beforeEach(() => {
    buildRouteDisplayNames([
      {
        '.name': 'mixed',
        '.type': 'server',
        label: 'Shared Mixed',
        enabled: '1',
      },
    ]);
  });

  it('shows the device name and client IP instead of the inbound name', () => {
    const source = getSourceCellParts(connection('192.168.1.50'), [], devices);
    expect(source.primary).toBe('Laptop');
    expect(source.ip).toBe('192.168.1.50');
    expect(source.copyValue).toBe('Laptop (192.168.1.50)');
    expect(source.inbound).toBe('Shared Mixed');
  });

  it.each(['192.168.1.51', '2001:db8::51'])(
    'shows an unknown client by its address: %s',
    (ip) => {
      const source = getSourceCellParts(connection(ip), [], devices);
      expect(source.primary).toBe(ip);
      expect(source.ip).toBe('');
      expect(source.copyValue).toBe(ip);
      expect(source.inbound).toBe('Shared Mixed');
    },
  );

  it('uses the inbound name only when the client address is missing', () => {
    const source = getSourceCellParts(connection());
    expect(source.primary).toBe('Shared Mixed');
    expect(source.copyValue).toBe('Shared Mixed');
  });

  it('falls back to an unknown inbound tag, then a placeholder', () => {
    const conn = connection();
    conn.metadata = { inbound: 'custom-in' };
    expect(getSourceCellParts(conn).primary).toBe('custom-in');
    conn.metadata = {};
    expect(getSourceCellParts(conn).primary).toBe('-');
  });

  it('keeps transparent client names and addresses', () => {
    const conn = connection('192.168.1.50');
    conn.metadata!.type = 'TProxy/tproxy-in';
    const source = getSourceCellParts(conn, [], devices);
    expect(source.primary).toBe('Laptop');
    expect(source.ip).toBe('192.168.1.50');
    expect(source.copyValue).toBe('Laptop (192.168.1.50)');
  });

  it('keeps distinct IPs and inbound names in the source filter labels', () => {
    const connections = [
      connection('192.168.1.50'),
      connection('192.168.1.51'),
    ];
    expect(getDeviceFilterLabel('192.168.1.50', connections, devices)).toBe(
      'Laptop (192.168.1.50) · Shared Mixed',
    );
    expect(getDeviceFilterLabel('192.168.1.51', connections, devices)).toBe(
      '192.168.1.51 · Shared Mixed',
    );
  });

  it.each(['active', 'closed'] as const)(
    'searches and filters %s clients independently on a shared inbound',
    (tab) => {
      const connections = [
        connection('192.168.1.50'),
        connection('192.168.1.51'),
      ];
      const options = {
        tab,
        activeConnections: tab === 'active' ? connections : [],
        closedConnections:
          tab === 'closed'
            ? connections.map((c) => ({ ...c, closedAt: 2000 }))
            : [],
        localDeviceChoices: devices,
        searchQuery: '',
      };
      for (const searchQuery of ['192.168.1.50', 'laptop']) {
        expect(
          filterVisibleConnections({ ...options, searchQuery }).map(
            (c) => c.id,
          ),
        ).toEqual(['192.168.1.50']);
      }
      for (const searchQuery of ['shared mixed', 'server-mixed-in']) {
        expect(
          filterVisibleConnections({ ...options, searchQuery }),
        ).toHaveLength(2);
      }
      expect(
        filterVisibleConnections({
          ...options,
          deviceFilter: '192.168.1.51',
        }).map((c) => c.id),
      ).toEqual(['192.168.1.51']);
    },
  );

  it('resolves inbound metadata, legacy type and rule fallback', () => {
    const conn = connection('192.168.1.50');
    conn.metadata!.inbound = 'server-mixed-in';
    conn.metadata!.type = 'Mixed';
    expect(getConnectionInboundTag(conn)).toBe('server-mixed-in');
    expect(getSourceCellParts(conn).inbound).toBe('Shared Mixed');
    delete conn.metadata!.inbound;
    conn.metadata!.type = 'mixed/server-mixed-in';
    expect(getConnectionInboundTag(conn)).toBe('server-mixed-in');
    delete conn.metadata!.type;
    conn.rule = 'inbound=server-mixed-in => route(main-out)';
    expect(getConnectionInboundTag(conn)).toBe('server-mixed-in');
  });
});
