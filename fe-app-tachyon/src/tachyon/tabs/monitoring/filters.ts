import { prettyBytes } from '../../../helpers/prettyBytes';
import { tr } from '../../helpers/i18n';
import { cleanBalancerTagId, getOutboundTagBySection } from '../../runtimeTags';
import { Tachyon } from '../../types';
import { getDashboardSectionTypeFilter } from '../dashboard/dashboardLayout';
import {
  formatDuration,
  formatEndpoint,
  normalizeString,
  parseStartedAt,
} from './formatters';

export type MonitoringTabId = 'active' | 'closed';
export type ConnectionDataSource = 'core' | 'conntrack';
export type ConnectionSourceFilter = 'all' | 'core' | 'conntrack';

export type LocalDeviceChoices = Record<string, string>;

export interface ClashConnectionMetadata {
  chains?: string[];
  destinationIP?: string;
  destinationPort?: string | number;
  host?: string;
  inbound?: string;
  network?: string;
  processPath?: string;
  protocol?: string;
  sniffProtocol?: string;
  sourceIP?: string;
  sourcePort?: string | number;
  type?: string;
}

export interface ClashConnection {
  chains?: string[];
  dataSource?: ConnectionDataSource;
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
  startedAtMs?: number;
}

export function getConnectionDataSource(
  connection: ClashConnection,
): ConnectionDataSource {
  if (
    connection.dataSource === 'conntrack' ||
    normalizeString(connection.id).startsWith('ct:') ||
    normalizeString(connection.metadata?.type).toLowerCase() === 'conntrack'
  ) {
    return 'conntrack';
  }
  return 'core';
}

export function getConnectionTupleKey(connection: ClashConnection): string {
  const meta = connection.metadata || {};
  const proto = normalizeString(meta.network || 'tcp').toLowerCase();
  const src = normalizeString(meta.sourceIP);
  const sport = normalizeString(meta.sourcePort);
  const dst = normalizeString(meta.destinationIP);
  const dport = normalizeString(meta.destinationPort);
  if (!src || !sport || !dst || !dport) {
    return '';
  }
  return `${proto}|${src}|${sport}|${dst}|${dport}`;
}

export function mergeCoreAndConntrackConnections(
  coreConnections: ClashConnection[] = [],
  conntrackConnections: ClashConnection[] = [],
): ClashConnection[] {
  const result: ClashConnection[] = [];
  const seenTuples = new Set<string>();
  const seenIds = new Set<string>();

  for (const conn of coreConnections) {
    if (!conn || typeof conn !== 'object') continue;
    const id = normalizeString(conn.id);
    if (id) seenIds.add(id);
    const tkey = getConnectionTupleKey(conn);
    if (tkey) seenTuples.add(tkey);
    result.push({
      ...conn,
      dataSource: getConnectionDataSource(conn),
    });
  }

  for (const ct of conntrackConnections) {
    if (!ct || typeof ct !== 'object') continue;
    const id = normalizeString(ct.id);
    if (id && seenIds.has(id)) continue;
    const tkey = getConnectionTupleKey(ct);
    if (tkey && seenTuples.has(tkey)) continue;
    if (id) seenIds.add(id);
    if (tkey) seenTuples.add(tkey);
    result.push({
      ...ct,
      dataSource: 'conntrack',
    });
  }

  return result;
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
  const cleanId = cleanBalancerTagId(sectionName, id);
  return getOutboundTagBySection(
    cleanId === 'urltest'
      ? `${sectionName}-urltest`
      : `${sectionName}-urltest-${cleanId}`,
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

export function isExcludedRoutingName(name: string, action = ''): boolean {
  const lower = normalizeString(name).toLowerCase();
  const act = normalizeString(action).toLowerCase();
  if (!lower || lower === '-') return true;
  if (act === 'connection') {
    return false;
  }
  if (
    !act &&
    routeSections.some(
      (s) =>
        s.displayName.toLowerCase() === lower ||
        s.sectionName.toLowerCase() === lower,
    )
  ) {
    return false;
  }
  if (
    act === 'zapret' ||
    act === 'zapret2' ||
    act === 'byedpi' ||
    act === 'desync' ||
    act === 'wdtt' ||
    act === 'olcrtc' ||
    lower.includes('zapret') ||
    lower.includes('byedpi') ||
    lower.includes('desync') ||
    lower.includes('wdtt') ||
    lower.includes('olcrtc')
  ) {
    return false;
  }
  return (
    act === 'block' ||
    act === 'reject' ||
    act === 'bypass' ||
    act === 'direct' ||
    act === 'dns' ||
    lower === 'block' ||
    lower === 'reject' ||
    lower === 'bypass' ||
    lower === 'direct' ||
    lower === 'dns' ||
    lower === 'wan' ||
    lower.includes('failover') ||
    lower.includes('block') ||
    lower.includes('reject') ||
    lower.includes('bypass') ||
    lower.includes('direct') ||
    lower.includes('dns') ||
    lower.includes('wan')
  );
}

export function buildRouteDisplayNames(sections: Tachyon.ConfigSection[]): {
  routeDisplayNames: Record<string, string>;
  serverDisplayNames: Record<string, string>;
  routeSections: Array<{ sectionName: string; displayName: string }>;
} {
  const map: Record<string, string> = {
    'bypass-out': 'Bypass',
    bypass: 'Bypass',
    'direct-out': 'direct',
    direct: 'direct',
    'lo-direct-out': 'direct',
    'lan-direct-out': 'direct',
    'block-out': 'block',
    block: 'block',
    reject: 'block',
    'dns-out': 'DNS',
    dns: 'DNS',
    'hijack-dns': 'DNS',
    'main-dns-server': 'DNS',
    'bootstrap-dns-server': 'DNS',
    'fallback-dns-server': 'DNS',
    'fakeip-dns-server': 'DNS',
    'tachyon-failover': 'Failover',
    'zapret-out': 'Zapret',
    'zapret2-out': 'Zapret2',
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

  const DPI_SECTION_ACTIONS = new Set([
    'zapret',
    'zapret2',
    'byedpi',
    'desync',
    'wdtt',
    'olcrtc',
  ]);

  sections
    .filter((section) => section['.type'] === 'section')
    .filter((section) => section.enabled !== '0')
    .forEach((section) => {
      const sectionName = section['.name'];
      const displayName = getDisplayName(section);
      const action = normalizeString(section.action).toLowerCase();
      const lowerName = normalizeString(sectionName).toLowerCase();
      const lowerDisplayName = normalizeString(displayName).toLowerCase();

      if (!sectionName || !displayName) {
        return;
      }

      const isDpiSection =
        DPI_SECTION_ACTIONS.has(action) ||
        lowerName.includes('zapret') ||
        lowerDisplayName.includes('zapret') ||
        lowerName.includes('byedpi') ||
        lowerDisplayName.includes('byedpi') ||
        lowerName.includes('desync') ||
        lowerDisplayName.includes('desync') ||
        lowerName.includes('wdtt') ||
        lowerDisplayName.includes('wdtt') ||
        lowerName.includes('olcrtc') ||
        lowerDisplayName.includes('olcrtc');

      const typeFilter = getDashboardSectionTypeFilter();
      let isCategoryAllowed = true;
      if (isDpiSection) {
        isCategoryAllowed = typeFilter.dpi !== false;
      } else if (
        isExcludedRoutingName(sectionName, action) ||
        isExcludedRoutingName(displayName, action)
      ) {
        isCategoryAllowed = false;
      } else {
        isCategoryAllowed = typeFilter.proxy !== false;
      }

      if (isCategoryAllowed) {
        routeSectionItems.push({ sectionName, displayName });
      }
      map[getOutboundTagBySection(sectionName)] = displayName;
      map[`${sectionName}-dns-server`] = displayName;
      map[`dns-${sectionName}`] = displayName;
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
    if (
      tag === sectionName ||
      tag === `${sectionName}-dns-server` ||
      tag === `dns-${sectionName}`
    ) {
      return true;
    }
    return tag.startsWith(`${sectionName}-`) && tag.endsWith('-out');
  });

  if (manualSection?.displayName) {
    return manualSection.displayName;
  }

  if (tag.endsWith('-dns-server') || tag.startsWith('dns-')) {
    return 'DNS';
  }

  return '';
}

export function getRouteTagFromRule(rule?: string): string {
  const norm = normalizeString(rule);
  const match = norm.match(/=>\s*route\(([^)]+)\)/);
  if (match?.[1]) {
    return normalizeString(match[1]).replace(/^['"]|['"]$/g, '');
  }
  const directMatch = norm.match(
    /=>\s*(hijack-dns|reject|direct-out|bypass-out|block-out|dns-out|direct|bypass|block|dns)\b/i,
  );
  if (directMatch?.[1]) {
    return directMatch[1].toLowerCase();
  }
  const outboundMatch = norm.match(/\boutbound=([^\s,)]+)/i);
  if (outboundMatch?.[1]) {
    return normalizeString(outboundMatch[1]).replace(/^['"]|['"]$/g, '');
  }
  return '';
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
  const inbound = normalizeString(connection.metadata?.inbound);
  if (inbound) {
    return inbound;
  }

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
  const deviceName = getDeviceName(ip, localDeviceChoices);
  const label = deviceName ? `${deviceName} (${ip})` : ip;
  return serverName ? `${label} · ${serverName}` : label;
}

export function getSourceCellParts(
  connection: MonitoredConnection,
  _connections: MonitoredConnection[] = [],
  localDeviceChoices: LocalDeviceChoices = {},
) {
  const ip = getConnectionSourceIp(connection);
  const inboundTag = getConnectionInboundTag(connection);
  const serverName = getServerDisplayNameByInboundTag(inboundTag);
  const deviceName = getDeviceName(ip, localDeviceChoices);
  const primary = (ip ? deviceName || ip : serverName || inboundTag) || '-';
  const copyValue = deviceName ? `${deviceName} (${ip})` : primary;

  return {
    primary,
    ip: deviceName ? ip : '',
    inbound: serverName || inboundTag,
    copyValue,
    searchValue: [deviceName, ip, serverName, inboundTag]
      .filter(Boolean)
      .join(' '),
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
  const metadata = connection.metadata || {};
  const rawNet = normalizeString(metadata.network).toLowerCase();
  const proto = normalizeString(metadata.protocol).toLowerCase();
  const sniffProto = normalizeString(metadata.sniffProtocol).toLowerCase();
  const metaType = normalizeString(metadata.type).toLowerCase();
  const ruleStr = normalizeString(connection.rule).toLowerCase();

  if (
    rawNet === 'quic' ||
    proto === 'quic' ||
    sniffProto === 'quic' ||
    metaType.includes('quic') ||
    /\bprotocol=quic\b/.test(ruleStr)
  ) {
    return 'quic';
  }

  if (rawNet === 'udp') {
    const portNum = Number(metadata.destinationPort);
    const hasSniffedHost = Boolean(normalizeString(metadata.host));
    if (portNum === 443 && hasSniffedHost) {
      return 'quic';
    }
  }

  return rawNet || '-';
}

function extractReadableRulePart(raw: string): string {
  if (!raw) return '';
  return raw
    .replace(/\binbound=\[[^\]]+\]\s*/gi, '')
    .replace(/\binbound=[^\s]+\s*/gi, '')
    .replace(/([a-z0-9_.-]+)-community-([a-z0-9_.-]+)-rs\b/gi, 'community:$2')
    .replace(/\bcommunity-([a-z0-9_.-]+)-rs\b/gi, 'community:$1')
    .replace(/\s+/g, ' ')
    .trim();
}

export function formatMatchedRuleSummary(
  connection: MonitoredConnection,
): string {
  const payload = normalizeString(connection.rulePayload);
  const rule = normalizeString(connection.rule);
  if (payload) {
    return extractReadableRulePart(payload);
  }
  if (rule) {
    return extractReadableRulePart(rule);
  }
  return '';
}

export function getRouteTooltip(
  connection: MonitoredConnection,
  routeLabel?: string,
): string {
  const resolvedRoute = routeLabel || getRoute(connection);
  const lines: string[] = [];
  if (resolvedRoute && resolvedRoute !== '-') {
    lines.push(`${tr('Секция', 'Section')}: ${resolvedRoute}`);
  }

  const payload = normalizeString(connection.rulePayload);
  const rule = normalizeString(connection.rule);
  if (payload) {
    lines.push(
      `${tr('Сработавшее условие', 'Matched condition')}: ${extractReadableRulePart(payload)}`,
    );
  }
  if (rule) {
    const cleanedRule = extractReadableRulePart(rule);
    if (cleanedRule && cleanedRule !== extractReadableRulePart(payload)) {
      lines.push(`${tr('Правило', 'Rule')}: ${cleanedRule}`);
    }
  }

  const chains = Array.isArray(connection.chains)
    ? connection.chains
    : Array.isArray(connection.metadata?.chains)
      ? connection.metadata.chains
      : [];
  const leafNode = normalizeString(chains[chains.length - 1]);
  if (
    leafNode &&
    leafNode !== resolvedRoute &&
    leafNode !== `${resolvedRoute}-out` &&
    !leafNode.endsWith('-out')
  ) {
    lines.push(`${tr('Узел', 'Node')}: ${leafNode}`);
  }

  return lines.join('\n') || resolvedRoute || '-';
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

  const net = getNetwork(connection);
  const dstPort = normalizeString(connection.metadata?.destinationPort);
  return [
    connection.id,
    getConnectionDataSource(connection),
    target.primary,
    dstPort,
    net,
    net === 'quic' ? 'udp' : '',
    getRoute(connection),
    // Rule expressions can list unrelated candidate rule sets for this route.
    formatConnectionDuration(connection, pausedAt),
    formatBytes(connection.download),
    formatBytes(connection.upload),
    source.primary,
    source.copyValue,
    source.searchValue,
  ].filter(Boolean);
}

export interface FilterConnectionsOptions {
  dataSourceFilter?: ConnectionSourceFilter;
  deviceFilter?: string;
  routeFilter?: string;
  deviceFilters?: Iterable<string>;
  routeFilters?: Iterable<string>;
  networkFilters?: Iterable<string>;
  searchQuery: string;
  tab: MonitoringTabId;
  activeConnections: MonitoredConnection[];
  closedConnections: MonitoredConnection[];
  localDeviceChoices?: LocalDeviceChoices;
  allFilterValue?: string;
  pausedAt?: number | null;
}

function normalizeMultiFilterSet(
  multiValues: Iterable<string> | undefined,
  singleValue: string | undefined,
  allFilterValue: string,
): Set<string> {
  const result = new Set<string>();
  if (multiValues) {
    for (const item of multiValues) {
      const normalized = normalizeString(item);
      if (normalized && normalized !== allFilterValue) {
        result.add(normalized);
      }
    }
  } else if (singleValue && singleValue !== allFilterValue) {
    result.add(singleValue);
  }
  return result;
}

export function filterVisibleConnections(
  options: FilterConnectionsOptions,
): MonitoredConnection[] {
  const {
    dataSourceFilter = 'all',
    deviceFilter,
    routeFilter,
    deviceFilters,
    routeFilters,
    networkFilters,
    searchQuery,
    tab,
    activeConnections,
    closedConnections,
    localDeviceChoices = {},
    allFilterValue = 'all',
    pausedAt,
  } = options;

  const normalizedSourceFilter: ConnectionSourceFilter =
    dataSourceFilter === 'core' || dataSourceFilter === 'conntrack'
      ? dataSourceFilter
      : 'all';

  const activeDeviceSet = normalizeMultiFilterSet(
    deviceFilters,
    deviceFilter,
    allFilterValue,
  );
  const activeRouteSet = normalizeMultiFilterSet(
    routeFilters,
    routeFilter,
    allFilterValue,
  );
  const activeNetworkSet = new Set<string>();
  if (networkFilters) {
    for (const net of networkFilters) {
      const normalized = normalizeString(net).toLowerCase();
      if (normalized && normalized !== allFilterValue) {
        activeNetworkSet.add(normalized);
      }
    }
  }

  const allConnections = [...activeConnections, ...closedConnections];
  const sourceList = tab === 'active' ? activeConnections : closedConnections;
  const sorted = sortConnections(sourceList, tab);
  const normalizedSearch = normalizeSearchValue(searchQuery);

  return sorted.filter((connection) => {
    if (
      normalizedSourceFilter !== 'all' &&
      getConnectionDataSource(connection) !== normalizedSourceFilter
    ) {
      return false;
    }

    const sourceIp = getConnectionSourceIp(connection);
    const isMatchingDevice =
      activeDeviceSet.size === 0 || activeDeviceSet.has(sourceIp);

    const connRoute = getRoute(connection);
    const isMatchingRoute =
      activeRouteSet.size === 0 || activeRouteSet.has(connRoute);

    const connNet = (getNetwork(connection) || '').toLowerCase();
    const isMatchingNetwork =
      activeNetworkSet.size === 0 || activeNetworkSet.has(connNet);

    if (!isMatchingDevice || !isMatchingRoute || !isMatchingNetwork) {
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
