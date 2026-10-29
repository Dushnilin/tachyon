/* eslint-disable @typescript-eslint/no-explicit-any */
import {
  isUserActivelyScrolling,
  preserveScrollForPage,
  svgEl,
} from '../../../helpers';
import { prettyBytes } from '../../../helpers/prettyBytes';
import { fetchHostnames } from '../../fetchers/fetchHostnames';
import { ensureOutboundDisplayFlag } from '../../helpers/country';
import { tr } from '../../helpers/i18n';
import { isActiveLuciTab } from '../../helpers/isActiveLuciTab';
import { TachyonShellMethods } from '../../methods';
import { store } from '../../services';
import { renderFlagEmojis } from './partials/renderFlagEmojis';
import { readSectionErrors } from '../../methods/custom/getDashboardSections';
import {
  computeTrafficRates,
  createInitialTrafficRatesState,
  TrafficRatesState,
} from './metrics';

const UCI_PACKAGE = 'tachyon';
const RECENT_CLIENT_TTL_MS = 45_000;
const SERVER_TAB_POLL_INTERVAL_MS = 3000;

export interface IServerInboundConfig {
  sectionId: string;
  label: string;
  country: string;
  enabled: boolean;
  protocol: string;
  protocolShort: string;
  protocolFull: string;
  security: string;
  transport: string;
  listen: string;
  port: string;
  routingMode: string;
  routingSection: string;
  routingLabel: string;
  openFirewallPort: boolean;
  isolateLan: boolean;
  username: string;
  awgClientAddress: string;
}

export interface IInboundConnectedClient {
  ip: string;
  name?: string;
  activeConns: number;
  upload: number;
  download: number;
  targets: string[];
  chain: string;
  isOnline: boolean;
  lastSeenAt: number;
}

export interface IInboundRuntimeStats {
  sectionId: string;
  activeConns: number;
  activeClientsCount: number;
  upload: number;
  download: number;
  upSpeed: number;
  downSpeed: number;
  clients: IInboundConnectedClient[];
}

export interface IAllInboundsSummary {
  enabledCount: number;
  totalCount: number;
  activeInboundsCount: number;
  totalActiveConns: number;
  totalActiveClients: number;
  totalUpload: number;
  totalDownload: number;
  totalUpSpeed: number;
  totalDownSpeed: number;
  bySection: Map<string, IInboundRuntimeStats>;
}

interface ISeenInboundConn {
  id: string;
  sectionId: string;
  clientIp: string;
  upload: number;
  download: number;
  target: string;
  chain: string;
  lastSeenAt: number;
}

interface IClosedClientRecord {
  upload: number;
  download: number;
  lastTarget: string;
  lastChain: string;
  lastSeenAt: number;
}

export interface IServerSectionControllerCallbacks {
  sectionRef: any;
  showServerInfoModal?: (sectionId: string) => void;
  showSubscriptionModal?: () => void;
}

let registeredServerController: IServerSectionControllerCallbacks | null = null;
const seenInboundConns = new Map<string, ISeenInboundConn>();
const closedSectionTotals = new Map<
  string,
  { upload: number; download: number }
>();
const closedClientTotals = new Map<string, Map<string, IClosedClientRecord>>();
let totalInboundRatesState: TrafficRatesState =
  createInitialTrafficRatesState();
const sectionRatesStates = new Map<string, TrafficRatesState>();
let lastKnownRawConnections: any[] = [];
let lastKnownHostnames = new Map<string, string>();
let serverTabPollTimer: ReturnType<typeof setInterval> | null = null;
let selectedServerSectionFilter: string | null = null;
let serverTabLifecycleInitialized = false;

const SHORT_PROTOCOL_LABELS: Record<string, string> = {
  vless: 'VLESS',
  vmess: 'VMess',
  trojan: 'Trojan',
  shadowsocks: 'SS',
  socks: 'SOCKS5',
  http: 'HTTP',
  mixed: 'Mixed',
  hysteria2: 'HY2',
  tuic: 'TUIC',
  anytls: 'AnyTLS',
  naive: 'Naive',
  shadowtls: 'ShadowTLS',
  fptn: 'FPTN',
  mtproto: 'MTProto',
  mieru: 'Mieru',
  trusttunnel: 'TrustTunnel',
  tewfai: 'TewFai',
  masque: 'MASQUE',
  openconnect: 'OpenConnect',
  awg: 'AWG',
  tailscale: 'Tailscale',
  json_inbound: 'JSON',
};

const FULL_PROTOCOL_LABELS: Record<string, string> = {
  vless: 'VLESS',
  vmess: 'VMess',
  trojan: 'Trojan',
  shadowsocks: 'Shadowsocks',
  socks: 'SOCKS5',
  http: 'HTTP',
  mixed: 'Mixed (SOCKS/HTTP)',
  hysteria2: 'Hysteria2',
  tuic: 'TUIC',
  anytls: 'AnyTLS',
  naive: 'NaiveProxy',
  shadowtls: 'ShadowTLS',
  fptn: 'FPTN',
  mtproto: 'MTProto',
  mieru: 'Mieru',
  trusttunnel: 'TrustTunnel',
  tewfai: 'TewFai',
  masque: 'MASQUE',
  openconnect: 'OpenConnect',
  awg: 'AmneziaWG',
  tailscale: 'Tailscale',
  json_inbound: 'JSON Inbound',
};

const DEFAULT_PORTS_BY_PROTOCOL: Record<string, string> = {
  vless: '443',
  vmess: '443',
  trojan: '443',
  shadowsocks: '8388',
  socks: '1080',
  http: '8080',
  mixed: '2080',
  hysteria2: '8443',
  tuic: '8443',
  anytls: '443',
  naive: '443',
  shadowtls: '443',
  fptn: '443',
  mtproto: '443',
  mieru: '8443',
  trusttunnel: '443',
  tewfai: '443',
  masque: '443',
  openconnect: '443',
  awg: '51820',
};

export function resetInboundTrafficStateForTests() {
  seenInboundConns.clear();
  closedSectionTotals.clear();
  closedClientTotals.clear();
  totalInboundRatesState = createInitialTrafficRatesState();
  sectionRatesStates.clear();
  lastKnownRawConnections = [];
  lastKnownHostnames = new Map();
  selectedServerSectionFilter = null;
}

export function extractServerInboundSectionId(conn: any): string | null {
  if (!conn || typeof conn !== 'object') {
    return null;
  }

  const metaInbound =
    typeof conn.metadata?.inbound === 'string'
      ? conn.metadata.inbound.trim()
      : '';
  if (metaInbound) {
    const match = metaInbound.match(
      /(?:^|\/)server-([A-Za-z0-9_.-]+)-in(?:-inner)?$/,
    );
    if (match && match[1]) {
      return match[1];
    }
  }

  const metaType =
    typeof conn.metadata?.type === 'string' ? conn.metadata.type.trim() : '';
  if (metaType) {
    const match = metaType.match(
      /(?:^|\/)server-([A-Za-z0-9_.-]+)-in(?:-inner)?$/,
    );
    if (match && match[1]) {
      return match[1];
    }
  }

  const rule = typeof conn.rule === 'string' ? conn.rule : '';
  if (rule) {
    const match = rule.match(
      /inbound=\[?server-([A-Za-z0-9_.-]+)-in(?:-inner)?\]?/,
    );
    if (match && match[1]) {
      return match[1];
    }
  }

  return null;
}

function safeUciSections(sectionType: string): any[] {
  try {
    if (typeof uci !== 'undefined' && typeof uci.sections === 'function') {
      const res = uci.sections(UCI_PACKAGE, sectionType);
      return Array.isArray(res) ? res : [];
    }
  } catch {
    // Ignore when UCI is not loaded
  }
  return [];
}

function resolveEffectiveSecurity(raw: any, protocol: string): string {
  if (protocol === 'awg') {
    const ver = `${raw.awg_version || '2.0'}`.trim();
    return ver === 'wg' ? 'WireGuard' : `AWG ${ver}`;
  }
  if (protocol === 'tailscale') {
    return 'WireGuard Mesh';
  }
  if (
    [
      'hysteria2',
      'tuic',
      'anytls',
      'naive',
      'fptn',
      'trusttunnel',
      'tewfai',
      'masque',
      'openconnect',
    ].includes(protocol)
  ) {
    return 'TLS';
  }
  if (
    [
      'shadowsocks',
      'socks',
      'http',
      'mixed',
      'mtproto',
      'shadowtls',
      'mieru',
      'json_inbound',
    ].includes(protocol)
  ) {
    return '';
  }
  const sec =
    `${raw.security || (protocol === 'vless' ? 'reality' : protocol === 'trojan' ? 'tls' : 'none')}`.toLowerCase();
  if (sec === 'reality') return 'Reality';
  if (sec === 'tls') return 'TLS';
  return '';
}

function resolveEffectiveTransport(raw: any, protocol: string): string {
  if (['vless', 'vmess', 'trojan'].includes(protocol)) {
    const t = `${raw.transport || 'tcp'}`.toLowerCase();
    if (t === 'ws') return 'WS';
    if (t === 'grpc') return 'gRPC';
    if (t === 'httpupgrade') return 'HTTPUpgrade';
    if (t === 'xhttp') return 'XHTTP';
    if (t === 'http') return 'HTTP';
    return 'TCP';
  }
  if (protocol === 'mieru') {
    return `${raw.mieru_transport || 'TCP'}`.toUpperCase();
  }
  if (['hysteria2', 'tuic', 'masque'].includes(protocol)) {
    return 'QUIC';
  }
  if (protocol === 'awg') {
    return 'UDP';
  }
  if (protocol === 'trusttunnel') {
    return raw.trusttunnel_quic === '1' ? 'TCP + QUIC' : 'TCP';
  }
  if (protocol === 'tewfai') {
    const trVal = Array.isArray(raw.tewfai_inbound_transport)
      ? raw.tewfai_inbound_transport.join(',')
      : `${raw.tewfai_inbound_transport || 'tcp'}`.toLowerCase();
    return trVal.includes('quic') || trVal.includes('h3') ? 'QUIC' : 'TCP';
  }
  return '';
}

export function getConfiguredServerInbounds(
  rawServersOverride?: any[],
  rawRoutingSectionsOverride?: any[],
): IServerInboundConfig[] {
  const rawServers = rawServersOverride ?? safeUciSections('server');
  const rawSections = rawRoutingSectionsOverride ?? safeUciSections('section');
  const sectionLabels = new Map<string, string>();

  for (const sec of rawSections) {
    const id = `${sec?.['.name'] || ''}`.trim();
    if (id) {
      sectionLabels.set(id, `${sec.label || sec.name || id}`.trim());
    }
  }

  return rawServers
    .map((raw): IServerInboundConfig | null => {
      const sectionId = `${raw?.['.name'] || ''}`.trim();
      if (!sectionId) return null;

      const enabled = !['0', 'false', 'no', 'off'].includes(
        `${raw.enabled ?? '1'}`.trim().toLowerCase(),
      );
      let protocol = `${raw.protocol || 'vless'}`.trim().toLowerCase();
      let jsonPort = '';

      if (protocol === 'json_inbound' && raw.inbound_json) {
        try {
          const parsed = JSON.parse(`${raw.inbound_json}`);
          if (parsed && typeof parsed.type === 'string' && parsed.type) {
            protocol = parsed.type.toLowerCase();
          }
          if (parsed && parsed.listen_port) {
            jsonPort = `${parsed.listen_port}`;
          }
        } catch {
          // Keep json_inbound
        }
      }

      const label = `${raw.label || raw.name || sectionId}`.trim();
      const country = `${raw.server_country || 'RU'}`.trim().toUpperCase();
      const protocolShort =
        SHORT_PROTOCOL_LABELS[protocol] || protocol.toUpperCase();
      const protocolFull = FULL_PROTOCOL_LABELS[protocol] || protocolShort;
      const security = resolveEffectiveSecurity(raw, protocol);
      const transport = resolveEffectiveTransport(raw, protocol);
      const listen = `${raw.listen || '0.0.0.0'}`.trim();
      const port =
        protocol === 'tailscale'
          ? 'Mesh'
          : `${raw.listen_port || jsonPort || DEFAULT_PORTS_BY_PROTOCOL[protocol] || '443'}`.trim();

      const routingMode = `${raw.routing_mode || 'rules'}`.trim();
      const routingSection = `${raw.routing_section || ''}`.trim();
      let routingLabel = tr('По правилам Tachyon', 'Tachyon Rules');
      if (routingMode === 'direct') {
        routingLabel = tr('Напрямую (WAN)', 'Direct (WAN)');
      } else if (routingMode === 'section') {
        const targetLabel =
          sectionLabels.get(routingSection) || routingSection || '—';
        routingLabel = `${tr('Секция', 'Section')}: ${targetLabel}`;
      }

      const openFirewallPort = !['0', 'false'].includes(
        `${raw.open_firewall_port ?? '1'}`.trim().toLowerCase(),
      );
      const isolateLan = `${raw.isolate_lan_for_users || '0'}` === '1';
      const username = `${raw.server_username || ''}`.trim();
      const awgClientAddress = `${raw.awg_client_address || ''}`
        .trim()
        .replace(/\/\d+$/, '');

      return {
        sectionId,
        label,
        country,
        enabled,
        protocol,
        protocolShort,
        protocolFull,
        security,
        transport,
        listen,
        port,
        routingMode,
        routingSection,
        routingLabel,
        openFirewallPort,
        isolateLan,
        username,
        awgClientAddress,
      };
    })
    .filter((item): item is IServerInboundConfig => item !== null);
}

function cleanTargetHost(conn: any): string {
  const host = `${conn?.metadata?.host || ''}`.trim();
  const dstIp = `${conn?.metadata?.destinationIP || ''}`.trim();
  const dstPort = `${conn?.metadata?.destinationPort || ''}`.trim();
  const base = host || dstIp;
  if (!base) return '';
  if (dstPort && dstPort !== '443' && dstPort !== '80' && !base.includes(':')) {
    return `${base}:${dstPort}`;
  }
  return base;
}

function cleanOutboundChain(conn: any): string {
  const chains = Array.isArray(conn?.chains) ? conn.chains : [];
  if (chains.length === 0) return '';
  const first = `${chains[0] || ''}`.trim();
  return first.replace(/-out$/, '');
}

function resolveClientDisplayName(
  ip: string,
  server: IServerInboundConfig,
  hostnames: Map<string, string>,
): string | undefined {
  const dhcpName = hostnames.get(ip);
  if (dhcpName) return dhcpName;

  if (server.protocol === 'awg') {
    if (
      (server.awgClientAddress && ip === server.awgClientAddress) ||
      ip.startsWith('10.')
    ) {
      return 'AmneziaWG Peer';
    }
  }
  if (server.protocol === 'fptn' && ip.startsWith('10.88.')) {
    return server.username || 'FPTN VPN';
  }
  if (server.protocol === 'masque' && ip.startsWith('10.89.')) {
    return 'MASQUE VPN';
  }
  if (server.protocol === 'openconnect' && ip.startsWith('10.90.')) {
    return server.username || 'OpenConnect VPN';
  }
  if (server.username && ip.startsWith('10.')) {
    return server.username;
  }
  return undefined;
}

export function computeInboundsRuntimeSummary(
  servers: IServerInboundConfig[],
  rawConnections: any[],
  hostnames: Map<string, string> = lastKnownHostnames,
  now = Date.now(),
): IAllInboundsSummary {
  lastKnownRawConnections = Array.isArray(rawConnections) ? rawConnections : [];
  if (hostnames && hostnames.size > 0) {
    lastKnownHostnames = hostnames;
  }

  const serverById = new Map<string, IServerInboundConfig>();
  for (const s of servers) {
    serverById.set(s.sectionId, s);
  }

  const incomingIds = new Set<string>();
  const activeConnsBySection = new Map<string, any[]>();

  for (const conn of lastKnownRawConnections) {
    const sectionId = extractServerInboundSectionId(conn);
    if (!sectionId) continue;

    const connId = `${conn.id || ''}`.trim();
    const clientIp = `${conn.metadata?.sourceIP || ''}`.trim() || 'unknown';
    const up = Math.max(0, Number(conn.upload) || 0);
    const down = Math.max(0, Number(conn.download) || 0);
    const target = cleanTargetHost(conn);
    const chain = cleanOutboundChain(conn);

    if (!activeConnsBySection.has(sectionId)) {
      activeConnsBySection.set(sectionId, []);
    }
    activeConnsBySection.get(sectionId)!.push(conn);

    if (connId) {
      incomingIds.add(connId);
      seenInboundConns.set(connId, {
        id: connId,
        sectionId,
        clientIp,
        upload: up,
        download: down,
        target,
        chain,
        lastSeenAt: now,
      });
    }
  }

  // Fold any connections that just closed into closedSectionTotals & closedClientTotals
  for (const [connId, seen] of Array.from(seenInboundConns.entries())) {
    if (!incomingIds.has(connId)) {
      seenInboundConns.delete(connId);

      const secTotals = closedSectionTotals.get(seen.sectionId) || {
        upload: 0,
        download: 0,
      };
      secTotals.upload += seen.upload;
      secTotals.download += seen.download;
      closedSectionTotals.set(seen.sectionId, secTotals);

      if (!closedClientTotals.has(seen.sectionId)) {
        closedClientTotals.set(seen.sectionId, new Map());
      }
      const clientMap = closedClientTotals.get(seen.sectionId)!;
      const prevClient = clientMap.get(seen.clientIp) || {
        upload: 0,
        download: 0,
        lastTarget: '',
        lastChain: '',
        lastSeenAt: seen.lastSeenAt,
      };
      prevClient.upload += seen.upload;
      prevClient.download += seen.download;
      if (seen.target) prevClient.lastTarget = seen.target;
      if (seen.chain) prevClient.lastChain = seen.chain;
      prevClient.lastSeenAt = Math.max(prevClient.lastSeenAt, seen.lastSeenAt);
      clientMap.set(seen.clientIp, prevClient);
    }
  }

  const bySection = new Map<string, IInboundRuntimeStats>();
  const globalClientIps = new Set<string>();
  let totalActiveConns = 0;
  let totalUpload = 0;
  let totalDownload = 0;
  let activeInboundsCount = 0;

  for (const server of servers) {
    const sectionId = server.sectionId;
    const rawSecConns = activeConnsBySection.get(sectionId) || [];
    const closedSec = closedSectionTotals.get(sectionId) || {
      upload: 0,
      download: 0,
    };

    let activeUpload = 0;
    let activeDownload = 0;

    const clientTempMap = new Map<
      string,
      {
        activeConns: number;
        activeUpload: number;
        activeDownload: number;
        targets: Set<string>;
        chain: string;
        lastSeenAt: number;
      }
    >();

    for (const conn of rawSecConns) {
      const ip = `${conn.metadata?.sourceIP || ''}`.trim() || 'unknown';
      const up = Math.max(0, Number(conn.upload) || 0);
      const down = Math.max(0, Number(conn.download) || 0);
      const target = cleanTargetHost(conn);
      const chain = cleanOutboundChain(conn);

      activeUpload += up;
      activeDownload += down;

      const entry = clientTempMap.get(ip) || {
        activeConns: 0,
        activeUpload: 0,
        activeDownload: 0,
        targets: new Set<string>(),
        chain: '',
        lastSeenAt: now,
      };
      entry.activeConns += 1;
      entry.activeUpload += up;
      entry.activeDownload += down;
      if (target && entry.targets.size < 3) {
        entry.targets.add(target);
      }
      if (chain) {
        entry.chain = chain;
      }
      entry.lastSeenAt = now;
      clientTempMap.set(ip, entry);
    }

    // Merge recently active clients (within RECENT_CLIENT_TTL_MS) so brief HTTP requests stay visible
    const closedClientsForSec = closedClientTotals.get(sectionId);
    if (closedClientsForSec) {
      for (const [ip, closedRec] of Array.from(closedClientsForSec.entries())) {
        if (now - closedRec.lastSeenAt > RECENT_CLIENT_TTL_MS) {
          if (!clientTempMap.has(ip)) {
            continue;
          }
        }
        const entry = clientTempMap.get(ip) || {
          activeConns: 0,
          activeUpload: 0,
          activeDownload: 0,
          targets: new Set<string>(),
          chain: closedRec.lastChain,
          lastSeenAt: closedRec.lastSeenAt,
        };
        if (closedRec.lastTarget && entry.targets.size === 0) {
          entry.targets.add(closedRec.lastTarget);
        }
        if (!entry.chain && closedRec.lastChain) {
          entry.chain = closedRec.lastChain;
        }
        clientTempMap.set(ip, entry);
      }
    }

    const sectionUpload = closedSec.upload + activeUpload;
    const sectionDownload = closedSec.download + activeDownload;

    const prevRateState =
      sectionRatesStates.get(sectionId) || createInitialTrafficRatesState();
    const { rates: secRates, nextState: nextSecRateState } =
      computeTrafficRates(sectionUpload, sectionDownload, now, prevRateState);
    sectionRatesStates.set(sectionId, nextSecRateState);

    const clients: IInboundConnectedClient[] = Array.from(
      clientTempMap.entries(),
    )
      .map(([ip, info]) => {
        const closedRec = closedClientsForSec?.get(ip);
        const clientUp = (closedRec?.upload || 0) + info.activeUpload;
        const clientDown = (closedRec?.download || 0) + info.activeDownload;
        const isOnline = info.activeConns > 0;
        if (isOnline && ip !== 'unknown') {
          globalClientIps.add(ip);
        } else if (ip !== 'unknown') {
          globalClientIps.add(ip);
        }
        return {
          ip,
          name: resolveClientDisplayName(ip, server, lastKnownHostnames),
          activeConns: info.activeConns,
          upload: clientUp,
          download: clientDown,
          targets: Array.from(info.targets),
          chain: info.chain,
          isOnline,
          lastSeenAt: info.lastSeenAt,
        };
      })
      .sort((a, b) => {
        if (a.isOnline !== b.isOnline) return a.isOnline ? -1 : 1;
        if (b.activeConns !== a.activeConns)
          return b.activeConns - a.activeConns;
        return b.download + b.upload - (a.download + a.upload);
      });

    const activeConns = rawSecConns.length;
    if (activeConns > 0 || clients.length > 0) {
      activeInboundsCount += 1;
    }

    if (server.enabled) {
      totalActiveConns += activeConns;
      totalUpload += sectionUpload;
      totalDownload += sectionDownload;
    }

    bySection.set(sectionId, {
      sectionId,
      activeConns,
      activeClientsCount: clients.length,
      upload: sectionUpload,
      download: sectionDownload,
      upSpeed: secRates.up,
      downSpeed: secRates.down,
      clients,
    });
  }

  const { rates: totalRates, nextState: nextTotalRateState } =
    computeTrafficRates(
      totalUpload,
      totalDownload,
      now,
      totalInboundRatesState,
    );
  totalInboundRatesState = nextTotalRateState;

  return {
    enabledCount: servers.filter((s) => s.enabled).length,
    totalCount: servers.length,
    activeInboundsCount,
    totalActiveConns,
    totalActiveClients: globalClientIps.size,
    totalUpload,
    totalDownload,
    totalUpSpeed: totalRates.up,
    totalDownSpeed: totalRates.down,
    bySection,
  };
}

export function switchToServersTab(): boolean {
  if (typeof document === 'undefined' || !document.querySelector) {
    return false;
  }
  const tabLink = document.querySelector<HTMLElement>(
    '.cbi-tab[data-tab="cbi-tachyon-server"] a, ' +
      '.cbi-tab-disabled[data-tab="cbi-tachyon-server"] a, ' +
      '.cbi-tab[data-tab="server"] a, ' +
      '.cbi-tab-disabled[data-tab="server"] a, ' +
      'li[data-tab="cbi-tachyon-server"] a, ' +
      'li[data-tab="server"] a',
  );
  if (tabLink && typeof tabLink.click === 'function') {
    tabLink.click();
    return true;
  }
  return false;
}

export function navigateToServerInbound(
  sectionId: string,
  options: { openModal?: boolean; openInfoModal?: boolean } = {},
) {
  switchToServersTab();

  const triggerHighlightAndModal = () => {
    if (typeof document !== 'undefined' && document.getElementById) {
      const card =
        document.getElementById(`tachyon-inbound-card-${sectionId}`) ||
        document.getElementById(`cbi-${UCI_PACKAGE}-${sectionId}`);
      if (card && typeof card.scrollIntoView === 'function') {
        card.scrollIntoView({ block: 'center', behavior: 'smooth' });
        card.classList?.add('tachyon-inbound-card--highlight');
        setTimeout(() => {
          card.classList?.remove('tachyon-inbound-card--highlight');
        }, 2000);
      }
    }

    if (options.openInfoModal) {
      if (registeredServerController?.showServerInfoModal) {
        registeredServerController.showServerInfoModal(sectionId);
        return;
      }
    }

    if (options.openModal) {
      if (
        registeredServerController?.sectionRef &&
        typeof registeredServerController.sectionRef.renderMoreOptionsModal ===
          'function'
      ) {
        void registeredServerController.sectionRef.renderMoreOptionsModal(
          sectionId,
        );
        return;
      }
      if (typeof document !== 'undefined' && document.querySelector) {
        const editBtn = document.querySelector<HTMLElement>(
          `#cbi-${UCI_PACKAGE}-${sectionId} .cbi-button-edit`,
        );
        if (editBtn && typeof editBtn.click === 'function') {
          editBtn.click();
        }
      }
    }
  };

  if (
    typeof window !== 'undefined' &&
    typeof window.setTimeout === 'function'
  ) {
    window.setTimeout(triggerHighlightAndModal, 60);
  } else {
    triggerHighlightAndModal();
  }
}

function createSettingsGearSvg() {
  return svgEl(
    'svg',
    {
      width: '12',
      height: '12',
      viewBox: '0 0 24 24',
      fill: 'none',
      stroke: 'currentColor',
      'stroke-width': '2',
      'stroke-linecap': 'round',
      'stroke-linejoin': 'round',
      class: 'tachyon-inbound-row__gear',
    },
    [
      svgEl('circle', { cx: '12', cy: '12', r: '3' }),
      svgEl('path', {
        d: 'M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z',
      }),
    ],
  );
}

const COLLAPSE_STORAGE_KEY_DASHBOARD = 'tachyon_inbounds_collapsed_dashboard';
const COLLAPSE_STORAGE_KEY_SERVERS = 'tachyon_inbounds_collapsed_servers';

function isCollapsedInStorage(storageKey: string): boolean {
  try {
    if (typeof localStorage !== 'undefined' && localStorage.getItem) {
      return localStorage.getItem(storageKey) === '1';
    }
  } catch {
    // Ignore storage errors
  }
  return false;
}

function setCollapsedInStorage(storageKey: string, collapsed: boolean) {
  try {
    if (typeof localStorage !== 'undefined' && localStorage.setItem) {
      localStorage.setItem(storageKey, collapsed ? '1' : '0');
    }
  } catch {
    // Ignore storage errors
  }
}

function createChevronSvg(collapsed: boolean) {
  return svgEl(
    'svg',
    {
      width: '14',
      height: '14',
      viewBox: '0 0 24 24',
      fill: 'none',
      stroke: 'currentColor',
      'stroke-width': '2.2',
      'stroke-linecap': 'round',
      'stroke-linejoin': 'round',
      class: 'tachyon-inbounds-chevron',
      style: `transition: transform 0.18s ease; transform: rotate(${collapsed ? '-90deg' : '0deg'});`,
    },
    [svgEl('polyline', { points: '6 9 12 15 18 9' })],
  );
}

export function formatActiveServersCount(
  enabled: number,
  total: number,
): string {
  if (enabled === total) {
    const isOne = enabled % 10 === 1 && enabled % 100 !== 11;
    const ruWord = isOne ? 'активный' : 'активных';
    return `${enabled} ${tr(ruWord, 'active')}`;
  }
  return `${enabled} / ${total} ${tr('активных', 'active')}`;
}

function getUi(): any {
  if (typeof ui !== 'undefined' && ui && typeof ui.showModal === 'function') {
    return ui;
  }
  if (typeof window !== 'undefined') {
    const w = window as any;
    if (w.ui && typeof w.ui.showModal === 'function') return w.ui;
    if (w.L && typeof w.L.showModal === 'function') return w.L;
  }
  if (typeof globalThis !== 'undefined') {
    const g = globalThis as any;
    if (g.ui && typeof g.ui.showModal === 'function') return g.ui;
    if (g.L && typeof g.L.showModal === 'function') return g.L;
  }
  return null;
}

export function showInboundClientsModal(
  server: IServerInboundConfig,
  summary: IAllInboundsSummary,
  isTachyonRunning = true,
) {
  const uiObj = getUi();
  if (!uiObj || typeof uiObj.showModal !== 'function') {
    return;
  }

  const st = summary.bySection.get(server.sectionId);
  const clients = st?.clients || [];
  const activeConns = st?.activeConns || 0;
  const totalDown = st?.download || 0;
  const totalUp = st?.upload || 0;
  const isPortListening = server.enabled && isTachyonRunning;
  const portDisplay = server.port === 'Mesh' ? 'Mesh' : `:${server.port}`;

  const summaryEl = E(
    'div',
    { class: 'tachyon-inbound-clients-modal__summary' },
    [
      E('span', {
        class: isPortListening
          ? 'tachyon-service-dot tachyon-service-dot--online'
          : 'tachyon-service-dot tachyon-service-dot--offline',
      }),
      E('span', { class: 'tachyon-protocol-pill' }, server.protocolShort),
      E(
        'span',
        {
          class: `tachyon-service-pill ${isPortListening ? 'tachyon-port-pill--online' : 'tachyon-port-pill--offline'}`,
          title: isPortListening
            ? tr(
                `Порт ${portDisplay} доступен (прослушивается)`,
                `Port ${portDisplay} is active and listening`,
              )
            : tr(
                `Порт ${portDisplay} недоступен`,
                `Port ${portDisplay} is unavailable`,
              ),
        },
        portDisplay,
      ),
      E(
        'span',
        { class: 'tachyon-stat-pill tachyon-stat-pill--conns' },
        `${activeConns} ${tr('соед.', 'conns')}`,
      ),
      E(
        'span',
        {
          class:
            'tachyon-traffic-pill tachyon-traffic-pill--compact tachyon-traffic-pill--down',
          title: tr(
            'Суммарный входящий трафик за сессию',
            'Total session download',
          ),
        },
        `↓ ${prettyBytes(totalDown)}`,
      ),
      E(
        'span',
        {
          class:
            'tachyon-traffic-pill tachyon-traffic-pill--compact tachyon-traffic-pill--up',
          title: tr(
            'Суммарный исходящий трафик за сессию',
            'Total session upload',
          ),
        },
        `↑ ${prettyBytes(totalUp)}`,
      ),
    ],
  );

  let contentBody: HTMLElement;

  if (clients.length === 0) {
    contentBody = E('div', { class: 'tachyon-inbound-clients-modal__empty' }, [
      E('div', { style: 'font-size: 32px; margin-bottom: 8px;' }, '💤'),
      E(
        'div',
        { style: 'font-weight: 600; font-size: 13.5px; margin-bottom: 4px;' },
        tr('Нет активных подключений', 'No active connections'),
      ),
      E(
        'div',
        { style: 'font-size: 12px; opacity: 0.8;' },
        tr(
          'Сервер работает и готов принимать подключения клиентов.',
          'The server is running and ready to accept client connections.',
        ),
      ),
    ]);
  } else {
    const rows = clients.map((client) => {
      const dotClass = client.isOnline
        ? 'tachyon-service-dot tachyon-service-dot--online tachyon-service-dot--active-pulse'
        : 'tachyon-service-dot tachyon-service-dot--neutral';

      const statusBadge = client.isOnline
        ? E(
            'span',
            {
              class: 'tachyon-port-pill--online',
              style:
                'padding: 1px 7px; border-radius: 9px; font-size: 10.5px; display: inline-block;',
            },
            tr('Онлайн', 'Online'),
          )
        : E(
            'span',
            {
              class: 'tachyon-stat-pill--idle',
              style:
                'padding: 1px 7px; border-radius: 9px; font-size: 10.5px; display: inline-block;',
            },
            tr('Недавно', 'Recent'),
          );

      const targetText =
        client.targets && client.targets.length > 0
          ? client.targets.slice(0, 2).join(', ')
          : client.chain || '—';

      return E('tr', { class: 'tr cbi-section-table-row' }, [
        E('td', { class: 'td' }, [
          E('span', { class: 'tachyon-inbound-clients-modal__client-cell' }, [
            E('span', { class: dotClass }),
            E('span', { style: 'font-weight: 600;' }, client.name || client.ip),
          ]),
        ]),
        E('td', { class: 'td' }, [
          E(
            'span',
            { class: 'tachyon-service-pill tachyon-service-pill--version' },
            client.ip,
          ),
        ]),
        E('td', { class: 'td', style: 'text-align: center;' }, [
          E(
            'span',
            { class: 'tachyon-stat-pill tachyon-stat-pill--conns' },
            client.isOnline
              ? `${client.activeConns} ${tr('соед.', 'conns')}`
              : `0 ${tr('соед.', 'conns')}`,
          ),
        ]),
        E('td', { class: 'td' }, [
          E('div', { style: 'display: inline-flex; gap: 4px;' }, [
            E(
              'span',
              {
                class:
                  'tachyon-traffic-pill tachyon-traffic-pill--compact tachyon-traffic-pill--down',
              },
              `↓ ${prettyBytes(client.download)}`,
            ),
            E(
              'span',
              {
                class:
                  'tachyon-traffic-pill tachyon-traffic-pill--compact tachyon-traffic-pill--up',
              },
              `↑ ${prettyBytes(client.upload)}`,
            ),
          ]),
        ]),
        E('td', { class: 'td' }, [
          E(
            'span',
            {
              class: 'tachyon-route-pill',
              style:
                'max-width: 140px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; display: inline-block;',
              title: targetText,
            },
            targetText,
          ),
        ]),
        E('td', { class: 'td', style: 'text-align: center;' }, [statusBadge]),
      ]);
    });

    contentBody = E(
      'div',
      { class: 'tachyon-inbound-clients-modal__table-wrap' },
      [
        E(
          'table',
          {
            class:
              'table cbi-section-table tachyon-inbound-clients-modal__table',
          },
          [
            E('thead', {}, [
              E('tr', { class: 'tr cbi-section-table-titles' }, [
                E(
                  'th',
                  { class: 'th' },
                  tr('Устройство / Хост', 'Device / Host'),
                ),
                E('th', { class: 'th' }, tr('IP-адрес', 'IP Address')),
                E(
                  'th',
                  { class: 'th', style: 'text-align: center;' },
                  tr('Соединения', 'Connections'),
                ),
                E('th', { class: 'th' }, tr('Трафик', 'Traffic')),
                E(
                  'th',
                  { class: 'th' },
                  tr('Маршрут / Цель', 'Route / Target'),
                ),
                E(
                  'th',
                  { class: 'th', style: 'text-align: center;' },
                  tr('Статус', 'Status'),
                ),
              ]),
            ]),
            E('tbody', {}, rows),
          ],
        ),
      ],
    );
  }

  const modalContainer = E('div', { class: 'tachyon-inbound-clients-modal' }, [
    summaryEl,
    contentBody,
    E('div', { class: 'right', style: 'margin-top: 8px;' }, [
      E(
        'button',
        {
          type: 'button',
          class: 'btn',
          click: () => {
            if (typeof uiObj?.hideModal === 'function') {
              uiObj.hideModal();
            } else if (typeof (window as any)?.L?.hideModal === 'function') {
              (window as any).L.hideModal();
            }
          },
        },
        tr('Закрыть', 'Close'),
      ),
    ]),
  ]);

  uiObj.showModal(
    `👥 ${tr('Подключённые клиенты', 'Connected clients')}: «${server.label}» (${server.protocolFull}${server.security ? ' • ' + server.security : ''})`,
    modalContainer,
  );
}

export function renderCollapsibleInboundsBlock(params: {
  container: HTMLElement;
  servers: IServerInboundConfig[];
  summary: IAllInboundsSummary;
  isTachyonRunning: boolean;
  storageKey: string;
  showGoToServersLink: boolean;
  onRerender: () => void;
}) {
  const {
    container,
    servers,
    summary,
    isTachyonRunning,
    storageKey,
    showGoToServersLink,
    onRerender,
  } = params;

  const isCollapsed = isCollapsedInStorage(storageKey);

  if (
    selectedServerSectionFilter &&
    !servers.some((s) => s.sectionId === selectedServerSectionFilter)
  ) {
    selectedServerSectionFilter = null;
  }

  const toggleCollapse = (ev?: Event) => {
    if (ev) {
      ev.preventDefault();
      ev.stopPropagation();
    }
    setCollapsedInStorage(storageKey, !isCollapsed);
    onRerender();
  };

  const sectionErrors: Record<string, string> =
    (typeof window !== 'undefined' &&
      (window as unknown as { __tachyonSectionErrors?: Record<string, string> })
        .__tachyonSectionErrors) ||
    {};

  const erroredServers = servers.filter((s) =>
    Boolean(sectionErrors[s.sectionId]),
  );

  const chipNodes = servers.map((s) => {
    const st = summary.bySection.get(s.sectionId);
    const activeConns = st?.activeConns || 0;
    const activeClients = st?.activeClientsCount || 0;
    const totalDown = st?.download || 0;
    const totalUp = st?.upload || 0;
    const isSelected = selectedServerSectionFilter === s.sectionId;
    const serverError = sectionErrors[s.sectionId] || '';

    const dotClass = serverError
      ? 'tachyon-service-dot tachyon-service-dot--offline'
      : !s.enabled || !isTachyonRunning
        ? 'tachyon-service-dot tachyon-service-dot--offline'
        : activeConns > 0
          ? 'tachyon-service-dot tachyon-service-dot--online tachyon-service-dot--active-pulse'
          : 'tachyon-service-dot tachyon-service-dot--online';

    const canShowQr = !['tailscale', 'json_inbound'].includes(s.protocol);
    const portDisplay = s.port === 'Mesh' ? 'Mesh' : `:${s.port}`;
    const isPortListening = s.enabled && isTachyonRunning;
    const portClass = isPortListening
      ? 'tachyon-service-pill tachyon-port-pill--online'
      : 'tachyon-service-pill tachyon-port-pill--offline';
    const portTitle = isPortListening
      ? tr(
          `Порт ${portDisplay} доступен (прослушивается)`,
          `Port ${portDisplay} is active and listening`,
        )
      : tr(
          `Порт ${portDisplay} недоступен`,
          `Port ${portDisplay} is unavailable`,
        );

    const displayName = renderFlagEmojis(
      ensureOutboundDisplayFlag({
        displayName: s.label,
        country: s.country,
      }),
    );

    return E(
      'div',
      {
        id: `tachyon-inbound-card-${s.sectionId}`,
        class: `tachyon-inbound-card tachyon-inbound-chip${isSelected ? ' tachyon-inbound-card--selected tachyon-inbound-chip--selected' : ''}${!s.enabled ? ' tachyon-inbound-card--disabled' : ''}${serverError ? ' tachyon-inbound-chip--error' : ''}`,
        title: serverError
          ? `⚠️ ${s.label}: ${serverError}`
          : tr(
              `Клиенты и статистика «${s.label}» (${s.protocolFull}${s.security ? ' • ' + s.security : ''}, порт ${s.port})`,
              `Clients and statistics for "${s.label}" (${s.protocolFull}${s.security ? ' • ' + s.security : ''}, port ${s.port})`,
            ),
        click: (ev: MouseEvent) => {
          ev.preventDefault();
          ev.stopPropagation();
          showInboundClientsModal(s, summary, isTachyonRunning);
        },
      },
      [
        E('div', { class: 'tachyon-inbound-card__top' }, [
          E(
            'div',
            {
              class:
                'tachyon-inbound-card__title-group tachyon-inbound-chip__left',
            },
            [
              E('span', { class: dotClass }),
              E(
                'span',
                {
                  class:
                    'tachyon-inbound-card__name tachyon-inbound-chip__name',
                  title: s.label,
                },
                displayName,
              ),
            ],
          ),
          E('div', { class: 'tachyon-inbound-card__badges' }, [
            E('span', { class: 'tachyon-protocol-pill' }, s.protocolShort),
            E(
              'span',
              {
                class: portClass,
                title: portTitle,
              },
              portDisplay,
            ),
            ...(serverError
              ? [
                  E(
                    'span',
                    {
                      class: 'tachyon-inbound-chip__error-pill',
                      title: serverError,
                    },
                    `⚠️ ${tr('Ошибка', 'Error')}`,
                  ),
                ]
              : []),
          ]),
        ]),
        E('div', { class: 'tachyon-inbound-card__bottom' }, [
          E('div', { class: 'tachyon-inbound-card__metrics' }, [
            ...(!s.enabled || !isTachyonRunning
              ? [
                  E(
                    'span',
                    { class: 'tachyon-stat-pill tachyon-stat-pill--idle' },
                    !s.enabled
                      ? tr('Отключен', 'Disabled')
                      : tr('Остановлен', 'Stopped'),
                  ),
                ]
              : activeConns > 0
                ? [
                    E(
                      'span',
                      {
                        class: 'tachyon-stat-pill tachyon-stat-pill--conns',
                        title: `${activeClients} ${tr('устр.', 'dev')} • ${activeConns} ${tr('соед.', 'conns')}`,
                      },
                      `${activeConns} ${tr('соед.', 'conns')}`,
                    ),
                  ]
                : [
                    E(
                      'span',
                      {
                        class: 'tachyon-stat-pill tachyon-stat-pill--idle',
                        title: tr(
                          'Нет активных соединений (режим ожидания)',
                          'No active connections (standby mode)',
                        ),
                      },
                      tr('Ожидание', 'Idle'),
                    ),
                  ]),
            ...(totalDown > 0
              ? [
                  E(
                    'span',
                    {
                      class:
                        'tachyon-traffic-pill tachyon-traffic-pill--compact tachyon-traffic-pill--down',
                      title: tr(
                        'Суммарный входящий трафик за сессию',
                        'Total session download',
                      ),
                    },
                    `↓ ${prettyBytes(totalDown)}`,
                  ),
                ]
              : []),
            ...(totalUp > 0
              ? [
                  E(
                    'span',
                    {
                      class:
                        'tachyon-traffic-pill tachyon-traffic-pill--compact tachyon-traffic-pill--up',
                      title: tr(
                        'Суммарный исходящий трафик за сессию',
                        'Total session upload',
                      ),
                    },
                    `↑ ${prettyBytes(totalUp)}`,
                  ),
                ]
              : []),
          ]),
          E(
            'div',
            {
              class:
                'tachyon-inbound-card__actions tachyon-inbound-chip__right',
            },
            [
              ...(canShowQr
                ? [
                    E(
                      'button',
                      {
                        type: 'button',
                        class: 'tachyon-inbound-mini-btn',
                        title: tr(
                          'Ссылка подключения и QR-код',
                          'Connection link & QR code',
                        ),
                        click: (ev: MouseEvent) => {
                          ev.preventDefault();
                          ev.stopPropagation();
                          navigateToServerInbound(s.sectionId, {
                            openInfoModal: true,
                          });
                        },
                      },
                      'ⓘ',
                    ),
                  ]
                : []),
              E(
                'button',
                {
                  type: 'button',
                  class: 'tachyon-inbound-mini-btn',
                  title: tr(
                    'Открыть настройки инбаунда',
                    'Open inbound settings',
                  ),
                  click: (ev: MouseEvent) => {
                    ev.preventDefault();
                    ev.stopPropagation();
                    navigateToServerInbound(s.sectionId, { openModal: true });
                  },
                },
                createSettingsGearSvg(),
              ),
            ],
          ),
        ]),
      ],
    );
  });

  const countText = formatActiveServersCount(
    summary.enabledCount,
    summary.totalCount,
  );

  const headerEl = E(
    'div',
    {
      class: `tachyon-dual-card__header tachyon-inbounds-collapsible__header${isCollapsed ? ' tachyon-inbounds-collapsible__header--collapsed' : ''}`,
      click: toggleCollapse,
    },
    [
      E('div', { class: 'tachyon-inbounds-collapsible__title-group' }, [
        createChevronSvg(isCollapsed),
        E(
          'span',
          { class: 'tachyon-dual-card__title-text' },
          tr('Входящие серверы', 'Inbound Servers'),
        ),
        E('span', { class: 'tachyon-protocol-pill' }, countText),
      ]),
      E('div', { class: 'tachyon-inbound-card__header-actions' }, [
        E(
          'span',
          {
            class: 'tachyon-stat-pill tachyon-stat-pill--conns',
            title: tr(
              'Подключённые клиенты и активные соединения',
              'Connected clients and active connections',
            ),
          },
          `${summary.totalActiveClients} ${tr('устр.', 'dev')} • ${summary.totalActiveConns} ${tr('соед.', 'conns')}`,
        ),
        E(
          'span',
          {
            class: 'tachyon-stat-pill tachyon-stat-pill--down',
            title: tr('Текущая входящая скорость', 'Current downlink speed'),
          },
          `↓ ${prettyBytes(summary.totalDownSpeed)}/s`,
        ),
        E(
          'span',
          {
            class: 'tachyon-stat-pill tachyon-stat-pill--up',
            title: tr('Текущая исходящая скорость', 'Current uplink speed'),
          },
          `↑ ${prettyBytes(summary.totalUpSpeed)}/s`,
        ),
        E(
          'span',
          {
            class: 'tachyon-traffic-pill tachyon-traffic-pill--down',
            title: tr(
              'Суммарный входящий трафик за сессию',
              'Total session download',
            ),
          },
          `↓ ${prettyBytes(summary.totalDownload)}`,
        ),
        E(
          'span',
          {
            class: 'tachyon-traffic-pill tachyon-traffic-pill--up',
            title: tr(
              'Суммарный исходящий трафик за сессию',
              'Total session upload',
            ),
          },
          `↑ ${prettyBytes(summary.totalUpload)}`,
        ),
        ...(showGoToServersLink
          ? [
              E(
                'button',
                {
                  type: 'button',
                  class:
                    'tachyon-dual-card__badge tachyon-dual-card__badge--clickable',
                  title: tr(
                    'Перейти во вкладку «Серверы»',
                    'Go to Servers tab',
                  ),
                  click: (ev: MouseEvent) => {
                    ev.preventDefault();
                    ev.stopPropagation();
                    switchToServersTab();
                  },
                },
                tr('Серверы →', 'Servers →'),
              ),
            ]
          : []),
      ]),
    ],
  );

  const cardEl = E(
    'div',
    {
      class: `tachyon_dashboard-page__widgets-section__item tachyon-dual-card tachyon-inbounds-collapsible-card${isCollapsed ? ' tachyon-inbounds-collapsible-card--collapsed' : ''}`,
    },
    [
      headerEl,
      ...(erroredServers.length > 0
        ? [
            E(
              'div',
              { class: 'tachyon-inbound-error-banner' },
              erroredServers.map((s) =>
                E('div', { class: 'tachyon-inbound-error-banner__item' }, [
                  E(
                    'strong',
                    {},
                    `⚠️ ${s.label} (${s.protocolShort} :${s.port}): `,
                  ),
                  E('span', {}, sectionErrors[s.sectionId] || ''),
                ]),
              ),
            ),
          ]
        : []),
      ...(isCollapsed
        ? []
        : [E('div', { class: 'tachyon-inbounds-chip-grid' }, chipNodes)]),
    ],
  );

  preserveScrollForPage(() => {
    container.replaceChildren(cardEl);
  }, container);
}

export function renderInboundServersDashboardWidget(options?: {
  rawConnections?: any[];
  hostnames?: Map<string, string>;
  serversOverride?: IServerInboundConfig[];
}) {
  if (typeof document === 'undefined' || !document.getElementById) {
    return;
  }
  const container = document.getElementById('dashboard-widget-inbounds');
  if (!container) return;

  const servers = options?.serversOverride ?? getConfiguredServerInbounds();
  const enabledServers = servers.filter((s) => s.enabled);

  if (enabledServers.length === 0) {
    container.replaceChildren();
    return;
  }

  if (isUserActivelyScrolling()) {
    return;
  }

  const srvState = store.get().servicesInfoWidget;
  const isTachyonRunning = Boolean(srvState?.data?.tachyonRunning);
  const rawConns = options?.rawConnections ?? lastKnownRawConnections;
  const hostnames = options?.hostnames ?? lastKnownHostnames;

  const summary = computeInboundsRuntimeSummary(
    enabledServers,
    isTachyonRunning ? rawConns : [],
    hostnames,
  );

  renderCollapsibleInboundsBlock({
    container,
    servers: enabledServers,
    summary,
    isTachyonRunning,
    storageKey: COLLAPSE_STORAGE_KEY_DASHBOARD,
    showGoToServersLink: true,
    onRerender: () => renderInboundServersDashboardWidget(options),
  });
}

export function renderServerTabInboundsOverview(options?: {
  rawConnections?: any[];
  hostnames?: Map<string, string>;
  serversOverride?: IServerInboundConfig[];
}) {
  if (typeof document === 'undefined' || !document.getElementById) {
    return;
  }
  const container = document.getElementById('tachyon-server-inbounds-overview');
  if (!container) return;

  const servers = options?.serversOverride ?? getConfiguredServerInbounds();
  if (servers.length === 0) {
    container.replaceChildren();
    return;
  }

  if (isUserActivelyScrolling()) {
    return;
  }

  const rawConns = options?.rawConnections ?? lastKnownRawConnections;
  const hostnames = options?.hostnames ?? lastKnownHostnames;
  const summary = computeInboundsRuntimeSummary(servers, rawConns, hostnames);

  renderCollapsibleInboundsBlock({
    container,
    servers,
    summary,
    isTachyonRunning: true,
    storageKey: COLLAPSE_STORAGE_KEY_SERVERS,
    showGoToServersLink: false,
    onRerender: () => renderServerTabInboundsOverview(options),
  });
}

async function pollInboundsForServersTab() {
  if (typeof document !== 'undefined' && document.hidden) {
    return;
  }
  const overviewEl =
    typeof document !== 'undefined' && document.getElementById
      ? document.getElementById('tachyon-server-inbounds-overview')
      : null;
  if (!overviewEl || !overviewEl.isConnected) {
    return;
  }

  try {
    const [res, hostnames] = await Promise.all([
      TachyonShellMethods.getClashApiConnections(),
      fetchHostnames(),
      readSectionErrors(),
    ]);
    if (hostnames && hostnames.size > 0) {
      lastKnownHostnames = hostnames;
    }
    if (res.success && res.data && typeof res.data === 'object') {
      const payload = res.data as any;
      if (Array.isArray(payload.connections)) {
        lastKnownRawConnections = payload.connections;
      }
    }
  } catch {
    // Ignore transient errors
  }

  renderServerTabInboundsOverview();
  renderInboundServersDashboardWidget();
}

function startServerTabPolling() {
  if (serverTabPollTimer) return;
  void pollInboundsForServersTab();
  serverTabPollTimer = setInterval(() => {
    void pollInboundsForServersTab();
  }, SERVER_TAB_POLL_INTERVAL_MS);
}

function stopServerTabPolling() {
  if (!serverTabPollTimer) return;
  clearInterval(serverTabPollTimer);
  serverTabPollTimer = null;
}

export function registerServerSectionController(
  sectionRef: any,
  callbacks: Omit<IServerSectionControllerCallbacks, 'sectionRef'> = {},
) {
  registeredServerController = {
    sectionRef,
    ...callbacks,
  };

  if (!serverTabLifecycleInitialized) {
    serverTabLifecycleInitialized = true;
    store.subscribe((next, prev, diff) => {
      if (
        diff.tabService &&
        next.tabService.current !== prev.tabService.current
      ) {
        if (next.tabService.current === 'server') {
          renderServerTabInboundsOverview();
          startServerTabPolling();
        } else {
          stopServerTabPolling();
        }
      }
    });
  }

  if (
    typeof window !== 'undefined' &&
    typeof window.requestAnimationFrame === 'function'
  ) {
    window.requestAnimationFrame(() => {
      renderServerTabInboundsOverview();
      if (
        store.get().tabService.current === 'server' ||
        isActiveLuciTab('server')
      ) {
        startServerTabPolling();
      }
    });
  }
}
