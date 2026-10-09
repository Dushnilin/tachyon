import { prettyBytes } from '../../../helpers/prettyBytes';
import { getOutboundTagBySection } from '../../runtimeTags';
import { Tachyon } from '../../types';
import {
  formatDuration,
  formatEndpoint,
  normalizeString,
  parseStartedAt,
} from './formatters';

export type MonitoringTabId = 'active' | 'closed';

export type LocalDeviceChoices = Record<string, string>;

export interface ClashConnectionMetadata {
  chains?: string[];
  destinationIP?: string;
  destinationPort?: string | number;
  host?: string;
  network?: string;
  processPath?: string;
  sourceIP?: string;
  sourcePort?: string | number;
  type?: string;
}

export interface ClashConnection {
  chains?: string[];
  download?: number;
  id?: string;
  metadata?: ClashConnectionMetadata;
  rule?: string;
  rulePayload?: string;
  start?: string;
  upload?: number;
}

export interface ClashConnectionsPayload {
  connections?: ClashConnection[];
}

export interface MonitoredConnection extends ClashConnection {
  id: string;
  closedAt?: number;
  lastSeenAt: number;
}

export function normalizeConnectionsPayload(
  value: unknown,
): ClashConnectionsPayload {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return {};
  }

  return value as ClashConnectionsPayload;
}

export function getListValues(value?: string[] | string): string[] {
  if (!value) {
    return [];
  }

  if (Array.isArray(value)) {
    return value.map((item) => normalizeString(item)).filter(Boolean);
  }

  return normalizeString(value)
    .split(/\s+/)
    .map((item) => item.trim())
    .filter(Boolean);
}

export function getUrlTestIds(section: Tachyon.ConfigSection): string[] {
  const values = getListValues(section.urltests);
  return values.length
    ? values
    : section.urltest_enabled === '1'
      ? ['urltest']
      : [];
}

export function getUrlTestTag(sectionName: string, id: string): string {
  return getOutboundTagBySection(
    id === 'urltest'
      ? `${sectionName}-urltest`
      : `${sectionName}-urltest-${id}`,
  );
}

export function getDisplayName(section: Tachyon.ConfigSection): string {
  return (
    normalizeString(section.label) ||
    normalizeString(section.name) ||
    section['.name']
  );
}

let routeDisplayNames: Record<string, string> = {};
let serverDisplayNames: Record<string, string> = {};
let routeSections: Array<{ sectionName: string; displayName: string }> = [];

export function getRouteDisplayNames(): Record<string, string> {
  return routeDisplayNames;
}

export function getServerDisplayNames(): Record<string, string> {
  return serverDisplayNames;
}

export function getRouteSections(): Array<{
  sectionName: string;
  displayName: string;
}> {
  return routeSections;
}

export function setRouteDisplayNames(
  names: Record<string, string>,
  servers: Record<string, string> = {},
  sections: Array<{ sectionName: string; displayName: string }> = [],
): void {
  routeDisplayNames = names;
  serverDisplayNames = servers;
  routeSections = sections;
}

export function buildRouteDisplayNames(sections: Tachyon.ConfigSection[]): {
  routeDisplayNames: Record<string, string>;
  serverDisplayNames: Record<string, string>;
  routeSections: Array<{ sectionName: string; displayName: string }>;
} {
  const map: Record<string, string> = {
    'bypass-out': 'Bypass',
    'direct-out': 'direct',
    'tachyon-failover': 'Failover',
  };
  const serverMap: Record<string, string> = {};
  const routeSectionItems: Array<{ sectionName: string; displayName: string }> =
    [];
  const urltestsBySection = new Map<string, string[]>();

  sections
    .filter((section) => section['.type'] === 'urltest')
    .forEach((section) => {
      const owner = normalizeString(section.section);
      const id = normalizeString(section.id) || section['.name'];
      if (!owner || !id) {
        return;
      }

      urltestsBySection.set(owner, [
        ...(urltestsBySection.get(owner) || []),
        id,
      ]);
    });

  sections
    .filter((section) => section['.type'] === 'section')
    .filter((section) => section.enabled !== '0')
    .forEach((section) => {
      const sectionName = section['.name'];
      const displayName = getDisplayName(section);

      if (!sectionName || !displayName) {
        return;
      }

      routeSectionItems.push({ sectionName, displayName });
      map[getOutboundTagBySection(sectionName)] = displayName;
      const urltestIds =
        urltestsBySection.get(sectionName) || getUrlTestIds(section);
      urltestIds.forEach((id) => {
        map[getUrlTestTag(sectionName, id)] = displayName;
      });
    });

  sections
    .filter((section) => section['.type'] === 'server')
    .filter((section) => section.enabled !== '0')
    .forEach((section) => {
      const sectionName = section['.name'];
      const displayName = getDisplayName(section);

      if (!sectionName || !displayName) {
        return;
      }

      serverMap[`server-${sectionName}-in`] = displayName;
    });

  routeDisplayNames = map;
  serverDisplayNames = serverMap;
  routeSections = routeSectionItems.sort(
    (a, b) => b.sectionName.length - a.sectionName.length,
  );

  return {
    routeDisplayNames: map,
    serverDisplayNames: serverMap,
    routeSections,
  };
}

export function getRouteDisplayNameByTag(tag: string): string {
  if (!tag) {
    return '';
  }

  if (routeDisplayNames[tag]) {
    return routeDisplayNames[tag];
  }

  const manualSection = routeSections.find(({ sectionName }) => {
    if (tag === sectionName) {
      return true;
    }
    return tag.startsWith(`${sectionName}-`) && tag.endsWith('-out');
  });

  return manualSection?.displayName || '';
}

export function getRouteTagFromRule(rule?: string): string {
  const match = normalizeString(rule).match(/=>\s*route\(([^)]+)\)/);
  return normalizeString(match?.[1]).replace(/^['"]|['"]$/g, '');
}

export function formatConnectionDuration(
  connection: MonitoredConnection,
  pausedAt?: number | null,
): string {
  const startedAt = parseStartedAt(connection);
  const finishedAt = connection.closedAt || pausedAt || Date.now();

  return formatDuration(finishedAt - startedAt);
}

export function formatBytes(value?: number): string {
  return prettyBytes(Number.isFinite(value) ? Number(value) : 0);
}

export function getConnectionSourceIp(connection: ClashConnection): string {
  return normalizeString(connection.metadata?.sourceIP);
}

export function getConnectionInboundTag(connection: ClashConnection): string {
  const metadataType = normalizeString(connection.metadata?.type);
  const metadataTypeParts = metadataType.split('/');
  const metadataTag = normalizeString(
    metadataTypeParts.length > 1
      ? metadataTypeParts[metadataTypeParts.length - 1]
      : metadataType,
  );

  if (metadataTag) {
    return metadataTag;
  }

  const ruleInbound = normalizeString(connection.rule).match(
    /(?:^|\s)inbound=([^\s]+)/,
  );

  return normalizeString(ruleInbound?.[1]);
}

export function getServerDisplayNameByInboundTag(tag: string): string {
  return normalizeString(serverDisplayNames[tag]);
}

export function getDeviceName(
  ip: string,
  localDeviceChoices: LocalDeviceChoices = {},
): string {
  const raw = normalizeString(localDeviceChoices[ip]);
  if (!raw) return '';
  const match = raw.match(/^(?:IP|MAC):\s*[^\s—]+\s*—\s*(.+)$/i);
  if (match && match[1]) {
    return match[1].trim();
  }
  if (!raw.startsWith('IP:') && !raw.startsWith('MAC:') && raw !== ip) {
    return raw;
  }
  return '';
}

export function getServerSourceNameByIp(
  ip: string,
  connections: MonitoredConnection[] = [],
): string {
  if (!ip) {
    return '';
  }

  for (const connection of connections) {
    if (getConnectionSourceIp(connection) !== ip) {
      continue;
    }

    const serverName = getServerDisplayNameByInboundTag(
      getConnectionInboundTag(connection),
    );

    if (serverName) {
      return serverName;
    }
  }

  return '';
}

export function getDeviceFilterLabel(
  ip: string,
  connections: MonitoredConnection[] = [],
  localDeviceChoices: LocalDeviceChoices = {},
): string {
  const serverName = getServerSourceNameByIp(ip, connections);
  if (serverName) {
    return serverName;
  }

  const deviceName = getDeviceName(ip, localDeviceChoices);
  return deviceName ? `${deviceName} (${ip})` : ip;
}

export function getSourceCellParts(
  connection: MonitoredConnection,
  _connections: MonitoredConnection[] = [],
  localDeviceChoices: LocalDeviceChoices = {},
) {
  const ip = getConnectionSourceIp(connection);
  const inboundTag = getConnectionInboundTag(connection);
  const serverName = getServerDisplayNameByInboundTag(inboundTag);

  if (serverName) {
    return {
      primary: serverName,
      ip: '',
      copyValue: serverName,
      searchValue: [serverName, ip, inboundTag].filter(Boolean).join(' '),
    };
  }

  const deviceName = getDeviceName(ip, localDeviceChoices);

  if (deviceName) {
    return {
      primary: deviceName,
      ip: ip,
      copyValue: `${deviceName} (${ip})`,
      searchValue: `${deviceName} ${ip}`,
    };
  }

  return {
    primary: ip || '-',
    ip: '',
    copyValue: ip || '-',
    searchValue: ip,
  };
}

export function getTargetCellParts(connection: MonitoredConnection): {
  primary: string;
  searchValue: string;
} {
  const metadata = connection.metadata || {};
  const host = normalizeString(metadata.host);
  const destinationIp = normalizeString(metadata.destinationIP);
  const port = metadata.destinationPort;
  const primaryTarget = host || destinationIp;
  const primary = primaryTarget ? formatEndpoint(primaryTarget, port) : '-';

  return {
    primary,
    searchValue: [primary, host, destinationIp].filter(Boolean).join(' '),
  };
}

export function getRoute(connection: MonitoredConnection): string {
  const chains = Array.isArray(connection.chains)
    ? connection.chains
    : Array.isArray(connection.metadata?.chains)
      ? connection.metadata.chains
      : [];
  const routeTag = [...chains].reverse().find(getRouteDisplayNameByTag);
  const fallbackRouteTag = getRouteTagFromRule(connection.rule);
  const route =
    getRouteDisplayNameByTag(routeTag || '') ||
    getRouteDisplayNameByTag(fallbackRouteTag) ||
    normalizeString(routeTag) ||
    normalizeString(fallbackRouteTag);

  return route || '-';
}

export function getNetwork(connection: MonitoredConnection): string {
  return normalizeString(connection.metadata?.network).toLowerCase() || '-';
}

export function sortConnections(
  connections: MonitoredConnection[],
  tab: MonitoringTabId,
): MonitoredConnection[] {
  return [...connections].sort((a, b) => {
    if (tab === 'closed') {
      return (b.closedAt || 0) - (a.closedAt || 0);
    }

    return parseStartedAt(b) - parseStartedAt(a);
  });
}

export function normalizeSearchValue(value: string): string {
  return value.toLowerCase().replace(/\s+/g, ' ').trim();
}

export function getSearchValues(
  connection: MonitoredConnection,
  connections: MonitoredConnection[] = [],
  localDeviceChoices: LocalDeviceChoices = {},
  pausedAt?: number | null,
): string[] {
  const target = getTargetCellParts(connection);
  const source = getSourceCellParts(
    connection,
    connections,
    localDeviceChoices,
  );

  return [
    connection.id,
    target.primary,
    getNetwork(connection),
    getRoute(connection),
    formatConnectionDuration(connection, pausedAt),
    formatBytes(connection.download),
    formatBytes(connection.upload),
    source.primary,
    source.copyValue,
    source.searchValue,
  ].filter(Boolean);
}

export interface FilterConnectionsOptions {
  deviceFilter: string;
  routeFilter: string;
  searchQuery: string;
  tab: MonitoringTabId;
  activeConnections: MonitoredConnection[];
  closedConnections: MonitoredConnection[];
  localDeviceChoices?: LocalDeviceChoices;
  allFilterValue?: string;
  pausedAt?: number | null;
}

export function filterVisibleConnections(
  options: FilterConnectionsOptions,
): MonitoredConnection[] {
  const {
    deviceFilter,
    routeFilter,
    searchQuery,
    tab,
    activeConnections,
    closedConnections,
    localDeviceChoices = {},
    allFilterValue = 'all',
    pausedAt,
  } = options;

  const allConnections = [...activeConnections, ...closedConnections];
  const sourceList = tab === 'active' ? activeConnections : closedConnections;
  const sorted = sortConnections(sourceList, tab);
  const normalizedSearch = normalizeSearchValue(searchQuery);

  return sorted.filter((connection) => {
    const sourceIp = getConnectionSourceIp(connection);
    const isMatchingDevice =
      deviceFilter === allFilterValue || sourceIp === deviceFilter;

    let isMatchingRoute = routeFilter === allFilterValue;
    if (!isMatchingRoute && getRoute(connection) === routeFilter) {
      isMatchingRoute = true;
    }

    if (!isMatchingDevice || !isMatchingRoute) {
      return false;
    }

    if (!normalizedSearch) {
      return true;
    }

    return getSearchValues(
      connection,
      allConnections,
      localDeviceChoices,
      pausedAt,
    ).some((value) => normalizeSearchValue(value).includes(normalizedSearch));
  });
}
