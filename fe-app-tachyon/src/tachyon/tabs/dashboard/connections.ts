import { tr } from '../../helpers/i18n';
import { IConnection } from './partials';

export interface ITopDomain {
  domain: string;
  count: number;
  traffic: number;
}

export function aggregateClientConnections(
  rawConnections: Array<{
    metadata?: { sourceIP?: string };
    upload?: number | string;
    download?: number | string;
  }>,
  hostnames: Map<string, string>,
): IConnection[] {
  const map = new Map<string, IConnection>();

  for (const conn of rawConnections) {
    const ip = conn.metadata?.sourceIP;
    if (!ip) continue;

    const up = Number(conn.upload) || 0;
    const down = Number(conn.download) || 0;

    if (map.has(ip)) {
      const existing = map.get(ip)!;
      existing.count++;
      existing.upload += up;
      existing.download += down;
    } else {
      let name = hostnames.get(ip);
      if (!name) {
        if (ip === '127.0.0.1') {
          name = 'Flint-2';
        } else if (ip === '95.165.105.233') {
          name = tr('Роутер (WAN)', 'Router (WAN)');
        }
      }
      map.set(ip, { ip, count: 1, upload: up, download: down, name });
    }
  }

  return Array.from(map.values()).sort(
    (a, b) => b.download + b.upload - (a.download + a.upload),
  );
}

export function aggregateTopDomains(
  rawConnections: Array<{
    metadata?: { host?: string };
    upload?: number | string;
    download?: number | string;
  }>,
  limit = 6,
): ITopDomain[] {
  const map = new Map<string, { count: number; traffic: number }>();

  for (const conn of rawConnections) {
    const rawHost = conn.metadata?.host?.trim();
    if (!rawHost) continue;
    // Skip raw IP addresses
    if (/^[0-9.]+$/.test(rawHost) || /^[0-9a-fA-F:]+$/.test(rawHost)) continue;

    const up = Number(conn.upload) || 0;
    const down = Number(conn.download) || 0;
    const traffic = up + down;

    if (map.has(rawHost)) {
      const existing = map.get(rawHost)!;
      existing.count++;
      existing.traffic += traffic;
    } else {
      map.set(rawHost, { count: 1, traffic });
    }
  }

  return Array.from(map.entries())
    .map(([domain, data]) => ({
      domain,
      count: data.count,
      traffic: data.traffic,
    }))
    .sort((a, b) => b.count - a.count || b.traffic - a.traffic)
    .slice(0, limit);
}
