import { describe, it, expect } from 'vitest';
import {
  aggregateClientConnections,
  aggregateTopDomains,
} from '../connections';

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

  it('resolves localhost IPv4/IPv6 and dynamic router LAN/WAN IPv4/IPv6 addresses when missing in hostnames', () => {
    const rawConns = [
      {
        metadata: { sourceIP: '127.0.0.1' },
        upload: 10,
        download: 20,
      },
      {
        metadata: { sourceIP: '::1' },
        upload: 15,
        download: 25,
      },
      {
        metadata: { sourceIP: '203.0.113.10' },
        upload: 100,
        download: 200,
      },
      {
        metadata: { sourceIP: '[2001:db8:1::1]' },
        upload: 40,
        download: 60,
      },
      {
        metadata: { sourceIP: 'fd00::1' },
        upload: 20,
        download: 30,
      },
      {
        metadata: { sourceIP: '10.100.100.153' },
        upload: 5,
        download: 5,
      },
    ];

    const hostnames = new Map<string, string>([
      ['10.100.100.153', '26:70:52:CD:8E:F9'],
    ]);

    const result = aggregateClientConnections(rawConns, hostnames, {
      routerHostname: 'OpenWrt-Edge',
      wanIps: ['203.0.113.10', '2001:db8:1::1'],
      lanIps: ['192.168.1.1', 'fd00::1'],
    });
    expect(result).toHaveLength(6);

    const localhostV4 = result.find((c) => c.ip === '127.0.0.1');
    expect(localhostV4?.name).toBe('OpenWrt-Edge');

    const localhostV6 = result.find((c) => c.ip === '::1');
    expect(localhostV6?.name).toBe('OpenWrt-Edge');

    const wanV4 = result.find((c) => c.ip === '203.0.113.10');
    expect(wanV4?.name).toMatch(/Роутер \(WAN\)|Router \(WAN\)/);

    const wanV6 = result.find((c) => c.ip === '2001:db8:1::1');
    expect(wanV6?.name).toMatch(/Роутер \(WAN\)|Router \(WAN\)/);

    const lanV6 = result.find((c) => c.ip === 'fd00::1');
    expect(lanV6?.name).toBe('OpenWrt-Edge');

    const macConn = result.find((c) => c.ip === '10.100.100.153');
    expect(macConn?.name).toBe('26:70:52:CD:8E:F9');

    // Default fallback without explicit routerContext uses generic router label
    const fallbackResult = aggregateClientConnections(
      [{ metadata: { sourceIP: '::1' }, upload: 1, download: 2 }],
      new Map(),
    );
    expect(fallbackResult[0].name).toMatch(/Роутер|Router/);
  });

  it('aggregates top domains and filters out IPv4/IPv6 addresses', () => {
    const rawConns = [
      {
        metadata: { host: 'youtube.com' },
        upload: 100,
        download: 500,
      },
      {
        metadata: { host: 'youtube.com' },
        upload: 200,
        download: 300,
      },
      {
        metadata: { host: 'discord.com' },
        upload: 50,
        download: 50,
      },
      {
        metadata: { host: '1.1.1.1' }, // IP, should be skipped
        upload: 10,
        download: 10,
      },
      {
        metadata: { host: '2606:4700::6810' }, // IPv6, should be skipped
        upload: 10,
        download: 10,
      },
      {
        metadata: { host: '[2001:db8::1]' }, // bracketed IPv6, should be skipped
        upload: 10,
        download: 10,
      },
      {
        metadata: { host: 'fe80::1%eth0' }, // zone-scoped link-local IPv6, should be skipped
        upload: 10,
        download: 10,
      },
      {
        metadata: {}, // no host
        upload: 10,
        download: 10,
      },
    ];

    const result = aggregateTopDomains(rawConns);
    expect(result).toHaveLength(2);
    expect(result[0].domain).toBe('youtube.com');
    expect(result[0].count).toBe(2);
    expect(result[0].traffic).toBe(1100);
    expect(result[1].domain).toBe('discord.com');
    expect(result[1].count).toBe(1);
  });

  it('keeps the order and totals for repeated domains around IP literals', () => {
    const hosts = [
      ' [fe80::1%eth0] ',
      'a.example',
      '[fe80::1%eth0]',
      'b.example',
      ' a.example ',
      '192.0.2.1',
      'b.example',
      '192.0.2.1',
      'fe80::1%',
      ' ',
    ];
    const connections = hosts.map((host) => ({
      metadata: { host },
      upload: '2',
      download: 3,
    }));

    expect(aggregateTopDomains(connections)).toEqual([
      { domain: 'a.example', count: 2, traffic: 10 },
      { domain: 'b.example', count: 2, traffic: 10 },
      { domain: 'fe80::1%', count: 1, traffic: 5 },
    ]);
    expect(aggregateTopDomains(connections.slice(1, 2))).toEqual([
      { domain: 'a.example', count: 1, traffic: 5 },
    ]);
  });
});
