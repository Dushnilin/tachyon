import { tr } from '../../helpers/i18n';
import {
  extractServerInboundSectionId,
  getConfiguredServerInbounds,
  IServerInboundConfig,
} from './inboundServers';
import { IConnection } from './partials';

export interface ITopDomain {
  domain: string;
  count: number;
  traffic: number;
}

function formatInboundServerClientLabel(srv: IServerInboundConfig): string {
  const label = (srv.label || srv.sectionId || '').trim();
  const proto = (srv.protocolShort || '').trim();
  if (!label) return proto || 'Inbound';
  if (
    !proto ||
    label.toLowerCase().includes(proto.toLowerCase()) ||
    label.toLowerCase().includes((srv.protocol || '').toLowerCase())
  ) {
    return label;
  }
  return `${label} (${proto})`;
}

function resolveInboundClientFallbackName(
  conn: unknown,
  ip: string,
  serverById: Map<string, IServerInboundConfig>,
  servers: IServerInboundConfig[],
): string | undefined {
  const sectionId = extractServerInboundSectionId(conn);
  if (sectionId) {
    const srv = serverById.get(sectionId);
    if (srv) {
      return formatInboundServerClientLabel(srv);
    }
    return sectionId;
  }

  for (const srv of servers) {
    if (!srv.enabled) continue;
    if (srv.awgClientAddress && ip === srv.awgClientAddress) {
      return formatInboundServerClientLabel(srv);
    }
    if (srv.protocol === 'awg' && ip.startsWith('10.8.')) {
      return formatInboundServerClientLabel(srv);
    }
    if (srv.protocol === 'fptn' && ip.startsWith('10.88.')) {
      return formatInboundServerClientLabel(srv);
    }
    if (srv.protocol === 'masque' && ip.startsWith('10.89.')) {
      return formatInboundServerClientLabel(srv);
    }
    if (srv.protocol === 'openconnect' && ip.startsWith('10.90.')) {
      return formatInboundServerClientLabel(srv);
    }
  }

  return undefined;
}

export function aggregateClientConnections(
  rawConnections: Array<{
    metadata?: { sourceIP?: string; inbound?: string; type?: string };
    rule?: string;
    upload?: number | string;
    download?: number | string;
  }>,
  hostnames: Map<string, string>,
): IConnection[] {
  const map = new Map<string, IConnection>();
  const servers = getConfiguredServerInbounds();
  const serverById = new Map<string, IServerInboundConfig>();
  for (const srv of servers) {
    serverById.set(srv.sectionId, srv);
  }

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
      if (!existing.name) {
        existing.name = resolveInboundClientFallbackName(
          conn,
          ip,
          serverById,
          servers,
        );
      }
    } else {
      let name = hostnames.get(ip);
      if (!name) {
        if (ip === '127.0.0.1') {
          name = 'Flint-2';
        } else if (ip === '95.165.105.233') {
          name = tr('Роутер (WAN)', 'Router (WAN)');
        } else {
          name = resolveInboundClientFallbackName(
            conn,
            ip,
            serverById,
            servers,
          );
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
