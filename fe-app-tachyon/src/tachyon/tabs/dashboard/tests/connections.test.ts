import { describe, it, expect } from 'vitest';
import { aggregateClientConnections } from '../connections';

describe('dashboard connections', () => {
  it('aggregates multiple connections per IP and resolves hostname', () => {
    const rawConns = [
      {
        metadata: { sourceIP: '192.168.1.100' },
        upload: 100,
        download: 200,
      },
      {
        metadata: { sourceIP: '192.168.1.100' },
        upload: 50,
        download: 50,
      },
      {
        metadata: { sourceIP: '192.168.1.105' },
        upload: 500,
        download: 1000,
      },
      {
        metadata: {}, // no IP, should be skipped
        upload: 10,
        download: 10,
      },
    ];

    const hostnames = new Map<string, string>([
      ['192.168.1.100', 'Workstation'],
      ['192.168.1.105', 'Smart-TV'],
    ]);

    const result = aggregateClientConnections(rawConns, hostnames);

    expect(result).toHaveLength(2);
    // Ordered descending by total traffic (Smart-TV: 1500 > Workstation: 400)
    expect(result[0]).toEqual({
      ip: '192.168.1.105',
      count: 1,
      upload: 500,
      download: 1000,
      name: 'Smart-TV',
    });
    expect(result[1]).toEqual({
      ip: '192.168.1.100',
      count: 2,
      upload: 150,
      download: 250,
      name: 'Workstation',
    });
  });
});
