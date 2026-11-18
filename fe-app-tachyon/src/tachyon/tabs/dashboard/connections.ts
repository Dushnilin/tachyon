import { tr } from '../../helpers/i18n';
import { store } from '../../services/store.service';
import { unbracketHost } from '../../../validators/hostPort';
import { validateIPWithZone } from '../../../validators/validateIp';
import {
  extractServerInboundSectionId,
  getConfiguredServerInbounds,
  IServerInboundConfig,
} from './inboundServers';
import { IConnection } from './partials';

export interface IRouterConnectionContext {
  routerHostname?: string;
  lanIps?: string[];
  wanIps?: string[];
}

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

function normalizeLookupIp(ip: string): string {
  return unbracketHost(ip.trim()).split('%')[0];
}

function getDynamicRouterIdentity(routerContext?: IRouterConnectionContext): {
  routerHostname: string;
  lanIps: Set<string>;
  wanIps: Set<string>;
} {
  const sysInfo = store.get()?.diagnosticsSystemInfo;
  const globalObj = (typeof globalThis !== 'undefined' ? globalThis : {}) as {
    L?: { env?: { hostname?: string } };
  };
  const routerHostname =
    routerContext?.routerHostname?.trim() ||
    sysInfo?.router_hostname?.trim() ||
    globalObj.L?.env?.hostname?.trim() ||
    tr('Роутер', 'Router');

  const lanIps = new Set<string>();
  const wanIps = new Set<string>();
  for (const candidate of [
    sysInfo?.lan_ip,
    sysInfo?.lan_ipv6,
    ...(routerContext?.lanIps || []),
  ]) {
    if (candidate && candidate.trim()) {
      lanIps.add(normalizeLookupIp(candidate));
    }
  }
  for (const candidate of [
    sysInfo?.wan_ip,
    sysInfo?.wan_ipv6,
    ...(routerContext?.wanIps || []),
  ]) {
    if (candidate && candidate.trim()) {
      wanIps.add(normalizeLookupIp(candidate));
    }
  }
  return { routerHostname, lanIps, wanIps };
}

export function aggregateClientConnections(
  rawConnections: Array<{
    metadata?: { sourceIP?: string; inbound?: string; type?: string };
    rule?: string;
    upload?: number | string;
    download?: number | string;
  }>,
  hostnames: Map<string, string>,
  routerContext?: IRouterConnectionContext,
): IConnection[] {
  const map = new Map<string, IConnection>();
  const servers = getConfiguredServerInbounds();
  const serverById = new Map<string, IServerInboundConfig>();
  for (const srv of servers) {
    serverById.set(srv.sectionId, srv);
  }
  const routerIdentity = getDynamicRouterIdentity(routerContext);

  for (const conn of rawConnections) {
    const rawIp = conn.metadata?.sourceIP;
    if (!rawIp) continue;
    const ip = unbracketHost(rawIp.trim());
    const lookupIp = normalizeLookupIp(ip);

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
      let name = hostnames.get(ip) ?? hostnames.get(lookupIp);
      if (!name) {
        if (lookupIp === '127.0.0.1' || lookupIp === '::1') {
          name = routerIdentity.routerHostname;
        } else if (routerIdentity.wanIps.has(lookupIp)) {
          name = tr('Роутер (WAN)', 'Router (WAN)');
        } else if (routerIdentity.lanIps.has(lookupIp)) {
          name = routerIdentity.routerHostname;
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
  const map = new Map<string, { count: number; traffic: number } | null>();

  for (const conn of rawConnections) {
    const rawHost = conn.metadata?.host?.trim();
    if (!rawHost) continue;
    const existing = map.get(rawHost);
    // Cache IP addresses as well as domain totals for this snapshot.
    if (existing === null) continue;
    if (
      existing === undefined &&
      validateIPWithZone(unbracketHost(rawHost)).valid
    ) {
      map.set(rawHost, null);
      continue;
    }

    const up = Number(conn.upload) || 0;
    const down = Number(conn.download) || 0;
    const traffic = up + down;

    if (existing) {
      existing.count++;
      existing.traffic += traffic;
    } else {
      map.set(rawHost, { count: 1, traffic });
    }
  }

  const domains: ITopDomain[] = [];
  for (const [domain, data] of map) {
    if (data)
      domains.push({ domain, count: data.count, traffic: data.traffic });
  }
  return domains
    .sort((a, b) => b.count - a.count || b.traffic - a.traffic)
    .slice(0, limit);
}
