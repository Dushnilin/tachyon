import { getConfigSections } from './getConfigSections';
import { ClashAPI, Tachyon } from '../../types';
import {
  canUseDirectClashApi,
  getClashHttpUrl,
  getProxyUrlName,
  getProxyUrlTransport,
  isCopyableProxyLink,
} from '../../../helpers';
import { getOutboundTagBySection } from '../../runtimeTags';
import { TachyonShellMethods } from '../shell';
import { detectOutboundCountry } from '../../helpers/country';

interface IGetDashboardSectionsResponse {
  success: boolean;
  data: Tachyon.OutboundGroup[];
}

interface IGetDashboardSectionsOptions {
  includeSubscriptionCopyState?: boolean;
}

type ClashProxyEntry = {
  code: string;
  value: ClashAPI.ProxyBase;
};

type DashboardSectionCache = {
  version?: number;
  section?: string;
  links?: Record<string, string>;
  outboundMetadata?: Tachyon.GetOutboundMetadata;
  urltestGroups?: Record<string, UrlTestCacheGroup>;
  priorityGroups?: Record<string, PriorityCacheGroup>;
  subscriptionMetadata?:
    | Tachyon.SubscriptionMetadata
    | Tachyon.SubscriptionMetadata[];
  // Tags that belong to a URLTest/selector group and should not be shown
  // as standalone nodes in the UI (mirrors hiddenOutboundTags in sing-box).
  hiddenOutboundTags?: Record<string, boolean>;
};

type UrlTestCacheGroup = {
  displayName?: string;
  outbounds?: string[];
  url?: string;
  interval?: string;
  tolerance?: string | number;
  idle_timeout?: string;
  interrupt_exist_connections?: boolean;
};

type PriorityCacheLevel = {
  id?: string;
  displayName?: string;
  order?: number;
  direct?: boolean;
  filter_mode?: string;
  detect_server_country?: string;
  outbounds?: string[];
};

type PriorityCacheGroup = {
  id?: string;
  tag?: string;
  section?: string;
  displayName?: string;
  health_url?: string;
  active_check_interval?: string;
  check_timeout?: string;
  recovery_check_interval?: string;
  pick_fastest?: boolean;
  switch_to_faster_same_priority?: boolean;
  fastest_check_interval?: string;
  interrupt_exist_connections?: boolean;
  pin_dashboard?: boolean;
  outbounds?: string[];
  levels?: PriorityCacheLevel[];
};

type PriorityLevelConfig = {
  id: string;
  displayName: string;
  order: number;
  direct: boolean;
  filterMode: string;
  detectServerCountry: string;
  country: string[];
  serverName: string[];
  regex: string[];
  excludeCountries: string[];
  excludeOutbounds: string[];
  excludeRegex: string[];
  outbounds?: string[];
};

type ItemSettingsValue = string | string[] | PriorityLevelConfig[] | undefined;
type ItemSettings = Record<string, ItemSettingsValue>;

type UrlTestConfig = {
  id: string;
  code: string;
  displayName: string;
  settings: ItemSettings;
  pinDashboard: boolean;
  showDetectedCountries: boolean;
};

type PriorityConfig = {
  id: string;
  code: string;
  displayName: string;
  settings: ItemSettings;
  pinDashboard: boolean;
  healthUrl: string;
  activeCheckInterval: string;
  checkTimeout: string;
  recoveryCheckInterval: string;
  pickFastest: boolean;
  switchToFasterSamePriority: boolean;
  fastestCheckInterval: string;
  interruptExistConnections: boolean;
  showDetectedCountries: boolean;
  levels: PriorityLevelConfig[];
};

type ChildType =
  | 'subscription_url'
  | 'section_interface'
  | 'urltest'
  | 'priority_group'
  | 'priority_level'
  | 'outbound_source'
  | 'outbound_group'
  | 'balancer';

const DASHBOARD_SECTION_CACHE_DIR = '/var/run/tachyon/section-cache';
// Written by singbox/runtime.uc when it quarantines a section that sing-box
// refused to load; absent (or stale-empty) when every section loaded fine.
const SECTION_ERRORS_FILE = '/var/run/tachyon/section-errors.json';
const CLASH_API_FETCH_TIMEOUT_MS = 2500;
let directClashApiFailedAt = 0;
const DIRECT_CLASH_API_COOLDOWN_MS = 10_000;

export function resetDirectClashApiState() {
  directClashApiFailedAt = 0;
}

function getDisplayName(section: Tachyon.ConfigSection) {
  return section.label || section.name || section['.name'];
}

function getSettingsSection(configSections: Tachyon.ConfigSection[]) {
  return configSections.find((section) => section['.type'] === 'settings');
}

function getClashApiSecret(configSections: Tachyon.ConfigSection[]) {
  return getSettingsSection(configSections)?.yacd_secret_key || '';
}

function canFetchClashApiDirectly() {
  if (Date.now() - directClashApiFailedAt < DIRECT_CLASH_API_COOLDOWN_MS) {
    return false;
  }
  return canUseDirectClashApi() && typeof fetch === 'function';
}

async function getClashApiProxies(
  configSections: Tachyon.ConfigSection[],
): Promise<Tachyon.MethodResponse<ClashAPI.Proxies>> {
  if (canFetchClashApiDirectly()) {
    const secret = getClashApiSecret(configSections);
    const controller = new AbortController();
    const timeoutId = setTimeout(
      () => controller.abort(),
      CLASH_API_FETCH_TIMEOUT_MS,
    );

    try {
      const response = await fetch(`${getClashHttpUrl()}/proxies`, {
        headers: secret ? { Authorization: `Bearer ${secret}` } : undefined,
        signal: controller.signal,
      });

      if (response.ok) {
        directClashApiFailedAt = 0;
        return {
          success: true,
          data: (await response.json()) as ClashAPI.Proxies,
        };
      }
      directClashApiFailedAt = Date.now();
    } catch (_error) {
      directClashApiFailedAt = Date.now();
      // Fall back to rpcd below for controllers unavailable from the browser.
    } finally {
      clearTimeout(timeoutId);
    }
  }

  return TachyonShellMethods.getClashApiProxies();
}

function getListValues(value?: string[] | string) {
  if (!value) {
    return [];
  }

  if (Array.isArray(value)) {
    return value.map((item) => `${item}`.trim()).filter(Boolean);
  }

  return `${value}`
    .split(/\s+/)
    .map((item) => item.trim())
    .filter(Boolean);
}

function childSections(
  configSections: Tachyon.ConfigSection[],
  type: ChildType,
) {
  return configSections.filter((section) => section['.type'] === type);
}

function ownedChildSections(
  parent: Tachyon.ConfigSection,
  children: Tachyon.ConfigSection[],
) {
  return children.filter(
    (section): section is Tachyon.ConfigSection =>
      section.section === parent['.name'],
  );
}

function childSectionsByOwner(
  children: Tachyon.ConfigSection[],
  ownerKey: keyof Tachyon.ConfigSection,
  ownerValue: string,
) {
  return children.filter((section) => section[ownerKey] === ownerValue);
}

function compactSettingsMap(settings: Record<string, ItemSettings>) {
  return Object.keys(settings).length ? JSON.stringify(settings) : undefined;
}

function hydrateConfigSections(configSections: Tachyon.ConfigSection[]) {
  const subscriptionUrls = childSections(configSections, 'subscription_url');
  const interfaces = childSections(configSections, 'section_interface');
  const urltests = childSections(configSections, 'urltest');
  const priorityGroups = childSections(configSections, 'priority_group');
  const priorityLevels = childSections(configSections, 'priority_level');
  const outboundSources = childSections(configSections, 'outbound_source');
  const outboundGroups = childSections(configSections, 'outbound_group');
  const balancers = childSections(configSections, 'balancer');

  const sourceById = new Map(outboundSources.map((s) => [s['.name'], s]));
  const groupById = new Map(outboundGroups.map((g) => [g['.name'], g]));
  const balancerById = new Map(balancers.map((b) => [b['.name'], b]));

  return configSections.map((section) => {
    if (section['.type'] !== 'section') {
      return section;
    }

    const next: Tachyon.ConfigSection = { ...section };
    const subscriptionUrlItems = [
      ...ownedChildSections(next, subscriptionUrls),
    ];
    const interfaceItems = [...ownedChildSections(next, interfaces)];
    const legacyUrltestItems = ownedChildSections(next, urltests);
    const legacyPriorityGroupItems = ownedChildSections(next, priorityGroups);

    // Collect effective modular outbound_source items (mirrors connections.uc:section_effective_outbound_sources)
    const effectiveSources: Tachyon.ConfigSection[] = [];
    const seenSrcIds = new Set<string>();
    const addSource = (src?: Tachyon.ConfigSection) => {
      if (!src || src.enabled === '0') return;
      const sid = src['.name'];
      if (!sid || seenSrcIds.has(sid)) return;
      seenSrcIds.add(sid);
      effectiveSources.push(src);
    };
    const addGroupSources = (grpId: string) => {
      const grp = groupById.get(grpId);
      if (!grp || grp.enabled === '0') return;
      const gSources = getListValues(grp.source_refs);
      if (!gSources.length || gSources[0] === '*') {
        outboundSources.forEach(addSource);
      } else {
        gSources.forEach((sid) => addSource(sourceById.get(sid)));
      }
    };

    getListValues(next.outbound_source_refs).forEach((sid) =>
      addSource(sourceById.get(sid)),
    );
    getListValues(next.outbound_group_refs).forEach(addGroupSources);
    getListValues(next.balancer_refs).forEach((bid) => {
      const bal = balancerById.get(bid);
      if (!bal || bal.enabled === '0') return;
      getListValues(bal.source_refs).forEach((sid) =>
        addSource(sourceById.get(sid)),
      );
      getListValues(bal.group_refs).forEach(addGroupSources);
      getListValues(bal.outbound_group_levels).forEach((lvl) => {
        if (lvl.toLowerCase() !== 'direct') addGroupSources(lvl);
      });
    });

    const seenSubUrls = new Set(
      subscriptionUrlItems.map((it) => (it.url || '').trim()).filter(Boolean),
    );
    const extraProxyLinks: string[] = [];
    const extraAmneziaConfigs: string[] = [];
    const extraInterfaces: string[] = [];
    const extraOutboundJsons: string[] = [];

    effectiveSources.forEach((src) => {
      const stype = (src.source_type || 'subscription').toLowerCase();
      if (stype === 'subscription' || src.url) {
        const u = (src.url || '').trim();
        if (u && !seenSubUrls.has(u)) {
          seenSubUrls.add(u);
          subscriptionUrlItems.push(src);
        }
      } else if (stype === 'proxy_links' || stype === 'links') {
        getListValues(src.proxy_links || src.selector_proxy_links).forEach(
          (l) => extraProxyLinks.push(l),
        );
        if (src.proxy_links_text) {
          src.proxy_links_text
            .split(/[\r\n]+/)
            .map((l) => l.trim())
            .filter((l) => l && !l.startsWith('#'))
            .forEach((l) => extraProxyLinks.push(l));
        }
      } else if (stype === 'amnezia_config' || stype === 'awg') {
        const awgCfgs = getListValues(
          src.amnezia_configs || src.selector_amnezia_configs,
        );
        if (awgCfgs.length) {
          awgCfgs.forEach((c) => extraAmneziaConfigs.push(c));
        } else if (src.awg_private_key || src.awg_endpoint) {
          const aname = (
            src.name ||
            src.label ||
            src['.name'] ||
            'AmneziaWG'
          ).trim();
          extraProxyLinks.push(`wireguard://${src['.name']}#${aname}`);
        }
      } else if (stype === 'fptn' && next.action !== 'fptn') {
        let ftoken = (src.access_token || '').trim();
        if (ftoken) {
          if (!ftoken.includes('#')) {
            const fname = (src.name || 'FPTN').trim();
            if (fname) ftoken = `${ftoken}#${fname}`;
          }
          extraProxyLinks.push(ftoken);
        }
      } else if (stype === 'tor') {
        const port = (src.tor_socks_port || '9050').trim() || '9050';
        const tname = (src.name || 'Tor').trim() || 'Tor';
        extraProxyLinks.push(`socks5://127.0.0.1:${port}#${tname}`);
      } else if (stype === 'interface' || stype === 'tailscale') {
        const iname = (
          src.interface_name ||
          src.interface ||
          (stype === 'tailscale' ? 'tailscale0' : '')
        ).trim();
        if (iname) extraInterfaces.push(iname);
      } else if (stype === 'outbound_json' || stype === 'json') {
        getListValues(src.outbound_jsons || src.outbound_json).forEach((j) =>
          extraOutboundJsons.push(j),
        );
      } else if (
        [
          'desync',
          'warp',
          'anytls',
          'naive',
          'mieru',
          'snell',
          'sudoku',
          'masque',
          'openconnect',
          'shadowtls',
          'trusttunnel',
          'openvpn',
        ].includes(stype)
      ) {
        const sname = (src.name || src.label || src['.name'] || stype).trim();
        extraProxyLinks.push(`${stype}://${src['.name']}#${sname}`);
      }
    });

    if (extraProxyLinks.length) {
      next.selector_proxy_links = uniqueCodes([
        ...getListValues(next.selector_proxy_links),
        ...extraProxyLinks,
      ]);
    }
    if (extraAmneziaConfigs.length) {
      next.selector_amnezia_configs = uniqueCodes([
        ...getListValues(next.selector_amnezia_configs),
        ...extraAmneziaConfigs,
      ]);
    }
    if (extraOutboundJsons.length) {
      next.outbound_jsons = uniqueCodes([
        ...getListValues(next.outbound_jsons),
        ...extraOutboundJsons,
      ]);
    }

    // Hydrate urltests from balancer_refs + legacy urltest child sections (mirrors connections.uc:urltests)
    const urltestItems: Tachyon.ConfigSection[] = [];
    const seenUtNames = new Set<string>();
    const seenUtIds = new Set<string>();
    getListValues(next.balancer_refs).forEach((bid) => {
      const bal = balancerById.get(bid);
      if (bal && (bal.balancer_type || 'urltest').toLowerCase() === 'urltest') {
        const bname = bal.name || bal['.name'];
        seenUtNames.add(bname);
        if (bal.enabled !== '0' && !seenUtIds.has(bal['.name'])) {
          seenUtIds.add(bal['.name']);
          let mergedBal: Tachyon.ConfigSection = { ...bal };
          const grefs = getListValues(bal.group_refs);
          if (grefs.length > 0 && !bal.filter_mode) {
            const grp = groupById.get(grefs[0]);
            if (grp) {
              mergedBal = { ...grp, ...bal, '.name': bal['.name'] };
            }
          }
          urltestItems.push(mergedBal);
        }
      }
    });
    legacyUrltestItems.forEach((ut) => {
      const utName = ut.name || ut['.name'];
      if (!seenUtNames.has(utName) && !seenUtIds.has(ut['.name'])) {
        seenUtNames.add(utName);
        seenUtIds.add(ut['.name']);
        urltestItems.push(ut);
      }
    });

    // Hydrate priority_groups from balancer_refs + legacy priority_group child sections (mirrors connections.uc:priority_groups)
    const priorityGroupItems: Tachyon.ConfigSection[] = [];
    const seenPgNames = new Set<string>();
    const seenPgIds = new Set<string>();
    getListValues(next.balancer_refs).forEach((bid) => {
      const bal = balancerById.get(bid);
      if (
        bal &&
        (bal.balancer_type || 'urltest').toLowerCase() === 'priority'
      ) {
        const bname = bal.name || bal['.name'];
        seenPgNames.add(bname);
        if (bal.enabled !== '0' && !seenPgIds.has(bal['.name'])) {
          seenPgIds.add(bal['.name']);
          priorityGroupItems.push(bal);
        }
      }
    });
    legacyPriorityGroupItems.forEach((pg) => {
      const pgName = pg.name || pg['.name'];
      if (!seenPgNames.has(pgName) && !seenPgIds.has(pg['.name'])) {
        seenPgNames.add(pgName);
        seenPgIds.add(pg['.name']);
        priorityGroupItems.push(pg);
      }
    });

    const serviceSourceTypes = new Set([
      'zapret',
      'zapret2',
      'byedpi',
      'desync',
      'wdtt',
      'olcrtc',
    ]);
    const hasNonServiceItems =
      subscriptionUrlItems.length > 0 ||
      extraProxyLinks.length > 0 ||
      getListValues(next.selector_proxy_links).length > 0 ||
      extraAmneziaConfigs.length > 0 ||
      getListValues(next.selector_amnezia_configs).length > 0 ||
      interfaceItems.length > 0 ||
      extraInterfaces.length > 0 ||
      extraOutboundJsons.length > 0 ||
      getListValues(next.outbound_jsons).length > 0 ||
      urltestItems.length > 0 ||
      priorityGroupItems.length > 0;

    if (
      (next.action === 'connection' || next.action === 'proxy') &&
      !hasNonServiceItems &&
      effectiveSources.length > 0 &&
      effectiveSources.every((src) =>
        serviceSourceTypes.has((src.source_type || '').toLowerCase()),
      )
    ) {
      next.action = (
        effectiveSources[0].source_type || 'zapret2'
      ).toLowerCase() as Tachyon.ConfigSection['action'];
    }

    if (subscriptionUrlItems.length) {
      const settings: Record<string, ItemSettings> = {};
      next.subscription_urls = subscriptionUrlItems
        .map((item) => item.url || '')
        .filter(Boolean);
      subscriptionUrlItems.forEach((item) => {
        if (!item.url) {
          return;
        }
        settings[item.url] = {
          // Carried so the dashboard can tell a disabled source from an enabled
          // one. `enabled` is absent on sections written before the flag existed,
          // which means enabled - the same default the backend applies.
          enabled: item.enabled,
          subscription_update_enabled: item.subscription_update_enabled,
          subscription_update_interval: item.subscription_update_interval,
          download_via_proxy_enabled: item.download_via_proxy_enabled,
          download_via_proxy_section: item.download_via_proxy_section,
          auto_user_agent: item.auto_user_agent,
          user_agent: item.user_agent,
          auto_hwid: item.auto_hwid,
          hwid: item.hwid,
          custom_device_headers: item.custom_device_headers,
          device_os: item.device_os,
          ver_os: item.ver_os,
          device_model: item.device_model,
          device_locale: item.device_locale,
          app_version: item.app_version,
          accept_language: item.accept_language,
          show_dashboard_metadata: item.show_dashboard_metadata,
          prefix_nodes:
            item.prefix_nodes ?? (item.node_prefix ? '1' : undefined),
          node_prefix: item.node_prefix,
          node_prefix_bg: item.node_prefix_bg,
          node_prefix_color: item.node_prefix_color,
          include_urltest_groups: item.include_urltest_groups,
          hide_urltest_group_outbounds: item.hide_urltest_group_outbounds,
          urltest_idle_timeout: item.urltest_idle_timeout,
          hide_detour_outbounds: item.hide_detour_outbounds,
        };
      });
      next.subscription_url_settings = compactSettingsMap(settings);
    }

    if (interfaceItems.length || extraInterfaces.length) {
      next.interfaces = uniqueCodes([
        ...interfaceItems.map((item) => item.name || '').filter(Boolean),
        ...extraInterfaces,
      ]);
    }

    if (urltestItems.length) {
      const settings: Record<string, ItemSettings> = {};
      next.urltests = urltestItems.map((item) => item['.name']);
      urltestItems.forEach((item) => {
        settings[item['.name']] = {
          display_name: item.name || item.display_name,
          urltest_check_interval: item.check_interval,
          urltest_tolerance: item.tolerance,
          urltest_testing_url: item.testing_url,
          idle_timeout: item.idle_timeout,
          interrupt_exist_connections: item.interrupt_exist_connections,
          pin_dashboard: item.pin_dashboard,
          urltest_filter_mode: item.filter_mode,
          detect_server_country: item.detect_server_country,
          urltest_include_countries: item.include_countries,
          urltest_include_outbounds: item.include_outbounds,
          urltest_include_regex: item.include_regex,
          urltest_exclude_countries: item.exclude_countries,
          urltest_exclude_outbounds: item.exclude_outbounds,
          urltest_exclude_regex: item.exclude_regex,
        };
      });
      next.urltest_settings = compactSettingsMap(settings);
    }

    if (priorityGroupItems.length) {
      const settings: Record<string, ItemSettings> = {};
      next.priority_groups = priorityGroupItems.map((item) => item['.name']);
      priorityGroupItems.forEach((item) => {
        const groupId = item['.name'];
        const groupRefs = getListValues(item.outbound_group_levels);
        const levels: PriorityLevelConfig[] = groupRefs.length
          ? groupRefs.flatMap((ref, idx): PriorityLevelConfig[] => {
              const synthId = `${groupId}_lvl_${idx + 1}`;
              if (ref.toLowerCase() === 'direct') {
                return [
                  {
                    id: synthId,
                    displayName: 'Direct',
                    order: idx + 1,
                    direct: true,
                    filterMode: 'include',
                    detectServerCountry: 'flag_emoji',
                    country: [],
                    serverName: [],
                    regex: [],
                    excludeCountries: [],
                    excludeOutbounds: [],
                    excludeRegex: [],
                  },
                ];
              }
              const grp = groupById.get(ref);
              if (!grp) return [];
              return [
                {
                  id: synthId,
                  displayName: grp.name || ref,
                  order: idx + 1,
                  direct: false,
                  filterMode: grp.filter_mode || 'include',
                  detectServerCountry:
                    grp.detect_server_country || 'flag_emoji',
                  country: getListValues(grp.include_countries),
                  serverName: getListValues(grp.include_outbounds),
                  regex: getListValues(grp.include_regex),
                  excludeCountries: getListValues(grp.exclude_countries),
                  excludeOutbounds: getListValues(grp.exclude_outbounds),
                  excludeRegex: getListValues(grp.exclude_regex),
                },
              ];
            })
          : childSectionsByOwner(priorityLevels, 'group', groupId)
              .map(
                (level, index): PriorityLevelConfig => ({
                  id: level['.name'],
                  displayName: level.name || level['.name'],
                  order: Number.parseInt(level.order || `${index}`, 10) || 0,
                  direct: level.direct === '1',
                  filterMode: level.filter_mode || 'include',
                  detectServerCountry:
                    level.detect_server_country || 'flag_emoji',
                  country: getListValues(level.country),
                  serverName: getListValues(level.server_name),
                  regex: getListValues(level.regex),
                  excludeCountries: getListValues(level.exclude_countries),
                  excludeOutbounds: getListValues(level.exclude_outbounds),
                  excludeRegex: getListValues(level.exclude_regex),
                }),
              )
              .sort((left, right) =>
                left.order === right.order
                  ? left.id.localeCompare(right.id)
                  : left.order - right.order,
              );

        settings[groupId] = {
          name: item.name,
          health_url: item.health_url,
          active_check_interval: item.active_check_interval,
          check_timeout: item.check_timeout,
          recovery_check_interval: item.recovery_check_interval,
          pick_fastest: item.pick_fastest,
          switch_to_faster_same_priority: item.switch_to_faster_same_priority,
          fastest_check_interval: item.fastest_check_interval,
          interrupt_exist_connections: item.interrupt_exist_connections,
          pin_dashboard: item.pin_dashboard,
          levels,
        };
      });
      next.priority_group_settings = compactSettingsMap(settings);
    }

    return next;
  });
}

function getManualProxyLinks(section: Tachyon.ConfigSection) {
  return getListValues(section.selector_proxy_links);
}

function getConnectionInterfaces(section: Tachyon.ConfigSection) {
  const values = getListValues(section.interfaces);
  return values.length ? values : getListValues(section.interface);
}

function getJsonOutbounds(section: Tachyon.ConfigSection) {
  const values = getListValues(section.outbound_jsons);
  return values.length ? values : getListValues(section.outbound_json);
}

const SINGLE_ENDPOINT_ACTIONS = new Set([
  'vpn',
  'awg',
  'warp',
  'anytls',
  'snell',
  'mieru',
  'naive',
  'sudoku',
  'masque',
  'openvpn',
  'openconnect',
  'tewfai',
  'trusttunnel',
  'shadowtls',
  'desync',
]);

const ACTION_DISPLAY_NAMES: Record<string, string> = {
  awg: 'AmneziaWG',
  warp: 'WARP',
  anytls: 'AnyTLS',
  snell: 'Snell',
  mieru: 'Mieru',
  naive: 'NaiveProxy',
  sudoku: 'Sudoku',
  masque: 'MASQUE',
  openvpn: 'OpenVPN',
  openconnect: 'OpenConnect',
  tewfai: 'TewFai',
  trusttunnel: 'TrustTunnel',
  shadowtls: 'ShadowTLS',
  desync: 'Native Desync',
  fptn: 'FPTN',
};

function isConnectionAction(action?: string) {
  return Boolean(
    action &&
      (SINGLE_ENDPOINT_ACTIONS.has(action) ||
        ['connection', 'proxy', 'outbound', 'fptn', 'group'].includes(action)),
  );
}

function isServiceAction(action?: string) {
  return Boolean(
    action &&
      ['zapret', 'zapret2', 'byedpi', 'desync', 'wdtt', 'olcrtc'].includes(
        action,
      ),
  );
}

function hasSubscriptionSources(section: Tachyon.ConfigSection) {
  return getSubscriptionSourceCount(section) > 0;
}

function getSubscriptionSourceCount(section: Tachyon.ConfigSection) {
  return getListValues(section.subscription_urls).length;
}

function shouldSortByLatency(section: Tachyon.ConfigSection) {
  return section.sort_by_latency === '1';
}

function hasConfiguredUrlTestList(section: Tachyon.ConfigSection) {
  return getListValues(section.urltests).length > 0;
}

function hasConfiguredPriorityList(section: Tachyon.ConfigSection) {
  return getListValues(section.priority_groups).length > 0;
}

function getUrlTestIds(section: Tachyon.ConfigSection) {
  const values = getListValues(section.urltests);
  if (values.length) {
    return values;
  }
  if (section.action === 'group') {
    return ['urltest'];
  }
  if (
    section.action === 'awg' &&
    getListValues(section.selector_amnezia_configs).length > 0
  ) {
    return ['urltest'];
  }
  return section.urltest_enabled === '1' ? ['urltest'] : [];
}

function isUrlTestEnabled(section: Tachyon.ConfigSection) {
  return getUrlTestIds(section).length > 0;
}

function shouldHideNaServers(section: Tachyon.ConfigSection) {
  return (
    section.enabled !== '0' &&
    isConnectionAction(section.action) &&
    section.dashboard_hide_na_servers === '1'
  );
}

// A server is rendered as N/A when it is missing from the sing-box runtime or
// when no latency has ever been measured for it. "Not responding" (-1) is a
// distinct, meaningful state and stays visible.
function isNaOutbound(outbound: Tachyon.Outbound) {
  if (outbound.runtimeAvailable === false) return true;
  return !outbound.latency && outbound.latency !== -1;
}

function shouldUseProxyGroup(section: Tachyon.ConfigSection) {
  return (
    section.action === 'group' ||
    getListValues(section.group_members).length > 0 ||
    section.action === 'fptn' ||
    Boolean(section.access_token) ||
    getListValues(section.selector_amnezia_configs).length > 0 ||
    getManualProxyLinks(section).length > 0 ||
    hasSubscriptionSources(section) ||
    getConnectionInterfaces(section).length > 0 ||
    getJsonOutbounds(section).length > 0 ||
    isUrlTestEnabled(section) ||
    hasConfiguredPriorityList(section)
  );
}

function getSectionProxyConfigType(section: Tachyon.ConfigSection) {
  if (section.action === 'group') {
    return 'urltest' as const;
  }

  if (hasSubscriptionSources(section)) {
    return 'subscription' as const;
  }

  if (isUrlTestEnabled(section) && shouldUseProxyGroup(section)) {
    return 'urltest' as const;
  }

  if (getManualProxyLinks(section).length > 0) {
    return 'selector' as const;
  }

  if (section.action === 'fptn') {
    return 'selector' as const;
  }

  if (getJsonOutbounds(section).length > 0) {
    return 'outbound' as const;
  }

  if (getConnectionInterfaces(section).length > 0) {
    return 'interface' as const;
  }

  if (hasConfiguredPriorityList(section)) {
    return 'selector' as const;
  }

  return undefined;
}

function getJsonOutboundDisplayName(section: Tachyon.ConfigSection) {
  try {
    const parsedOutbound = JSON.parse(section.outbound_json || '{}');
    return parsedOutbound?.tag ? decodeURIComponent(parsedOutbound.tag) : '';
  } catch (_error) {
    return '';
  }
}

function buildManualLinkByCode(section: Tachyon.ConfigSection) {
  const sectionName = section['.name'];

  return new Map(
    getManualProxyLinks(section).map((link, index) => [
      getOutboundTagBySection(`${sectionName}-${index + 1}`),
      link,
    ]),
  );
}

function findManualLink(
  manualLinkByCode: Map<string, string>,
  code: string,
): string {
  const direct = manualLinkByCode.get(code);
  if (direct) return direct;
  for (const [tag, link] of manualLinkByCode.entries()) {
    if (code === tag || code.startsWith(`${tag}/`)) {
      return link;
    }
  }
  return '';
}

function getProxyEntryByCode(proxies: ClashProxyEntry[]) {
  return new Map(proxies.map((proxy) => [proxy.code, proxy]));
}

function uniqueCodes(codes: string[]) {
  return Array.from(new Set(codes.filter(Boolean)));
}

function isSelectorOutbound(outbound: Tachyon.Outbound) {
  return outbound.type?.toLowerCase() === 'selector';
}

function isUrlTestProxyEntry(entry?: ClashProxyEntry) {
  return entry?.value?.type?.toLowerCase() === 'urltest';
}

function getLatencySortValue(outbound: { latency: number }) {
  const latency = Number(outbound.latency);

  return Number.isFinite(latency) && latency > 0
    ? latency
    : Number.POSITIVE_INFINITY;
}

function sortOutboundsForDashboard(
  outbounds: Tachyon.Outbound[],
  options: {
    pinnedCode?: string;
    pinnedCodes?: string[];
    sortByLatency?: boolean;
    sortMode?: 'latency' | 'country_latency' | 'country_alpha' | 'default';
  } = {},
) {
  const pinnedCodes = [
    ...(options.pinnedCode ? [options.pinnedCode] : []),
    ...(options.pinnedCodes || []),
  ].filter(Boolean);
  const pinnedRank = new Map(
    pinnedCodes.map((code, index) => [code, index] as const),
  );
  const sortMode =
    options.sortMode ||
    (options.sortByLatency === true ? 'latency' : 'default');

  const countryInfoMap = new Map<string, { code: string; name: string }>();
  if (sortMode === 'country_latency' || sortMode === 'country_alpha') {
    for (const ob of outbounds) {
      const info = detectOutboundCountry(ob);
      countryInfoMap.set(ob.code, { code: info.code, name: info.name });
    }
  }

  return outbounds
    .map((outbound, index) => ({ outbound, index }))
    .sort((left, right) => {
      const leftPinned = pinnedRank.has(left.outbound.code);
      const rightPinned = pinnedRank.has(right.outbound.code);

      if (leftPinned !== rightPinned) {
        return leftPinned ? -1 : 1;
      }

      if (leftPinned && rightPinned) {
        const rankDiff =
          (pinnedRank.get(left.outbound.code) ?? 0) -
          (pinnedRank.get(right.outbound.code) ?? 0);

        if (rankDiff !== 0) {
          return rankDiff;
        }
      }

      if (sortMode === 'country_latency') {
        const leftCountry = countryInfoMap.get(left.outbound.code)!;
        const rightCountry = countryInfoMap.get(right.outbound.code)!;

        if (leftCountry.code === 'OTHER' && rightCountry.code !== 'OTHER')
          return 1;
        if (leftCountry.code !== 'OTHER' && rightCountry.code === 'OTHER')
          return -1;

        const countryDiff = leftCountry.name.localeCompare(
          rightCountry.name,
          'ru',
        );
        if (countryDiff !== 0) {
          return countryDiff;
        }

        const latencyDiff =
          getLatencySortValue(left.outbound) -
          getLatencySortValue(right.outbound);

        if (latencyDiff !== 0) {
          return latencyDiff;
        }
      } else if (sortMode === 'country_alpha') {
        const leftCountry = countryInfoMap.get(left.outbound.code)!;
        const rightCountry = countryInfoMap.get(right.outbound.code)!;

        if (leftCountry.code === 'OTHER' && rightCountry.code !== 'OTHER')
          return 1;
        if (leftCountry.code !== 'OTHER' && rightCountry.code === 'OTHER')
          return -1;

        const countryDiff = leftCountry.name.localeCompare(
          rightCountry.name,
          'ru',
        );
        if (countryDiff !== 0) {
          return countryDiff;
        }

        const nameDiff = (
          left.outbound.displayName || left.outbound.code
        ).localeCompare(
          right.outbound.displayName || right.outbound.code,
          'ru',
        );
        if (nameDiff !== 0) {
          return nameDiff;
        }
      } else if (sortMode === 'latency') {
        const latencyDiff =
          getLatencySortValue(left.outbound) -
          getLatencySortValue(right.outbound);

        if (latencyDiff !== 0) {
          return latencyDiff;
        }
      }

      return left.index - right.index;
    })
    .map((item) => item.outbound);
}

function sortUrlTestMembers(outbounds: Tachyon.UrlTestMember[]) {
  return outbounds
    .map((outbound, index) => ({ outbound, index }))
    .sort((left, right) => {
      if (left.outbound.selected !== right.outbound.selected) {
        return left.outbound.selected ? -1 : 1;
      }

      const latencyDiff =
        getLatencySortValue(left.outbound) -
        getLatencySortValue(right.outbound);

      if (latencyDiff !== 0) {
        return latencyDiff;
      }

      return left.index - right.index;
    })
    .map((item) => item.outbound);
}

function isSafeSectionName(sectionName: string) {
  return /^[A-Za-z0-9_-]+$/.test(sectionName);
}

function objectMap(value: unknown): Record<string, string> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return {};
  }

  return Object.fromEntries(
    Object.entries(value as Record<string, unknown>)
      .filter(([, item]) => typeof item === 'string')
      .map(([key, item]) => [key, item as string]),
  );
}

function itemSettingsMap(value?: string): Record<string, ItemSettings> {
  if (!value) {
    return {};
  }

  try {
    const parsed = JSON.parse(value) as unknown;

    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      return {};
    }

    return Object.fromEntries(
      Object.entries(parsed as Record<string, unknown>).filter(
        ([, item]) => item && typeof item === 'object' && !Array.isArray(item),
      ),
    ) as Record<string, ItemSettings>;
  } catch (_error) {
    return {};
  }
}

function itemSettingString(
  settings: ItemSettings | undefined,
  key: string,
  fallback = '',
) {
  const value = settings?.[key];
  return typeof value === 'string' ? value : fallback;
}

function itemSettingBoolean(
  settings: ItemSettings | undefined,
  key: string,
  fallback: boolean,
) {
  const value = settings?.[key];
  if (value == null || value === '') {
    return fallback;
  }

  return value === '1' || value === 'true';
}

function isUrlTestFilteringEnabled(settings: ItemSettings | undefined) {
  return ['exclude', 'include', 'mixed'].includes(
    itemSettingString(settings, 'urltest_filter_mode', 'disabled'),
  );
}

function getUrlTestTag(sectionName: string, id: string) {
  return getOutboundTagBySection(
    id === 'urltest'
      ? `${sectionName}-urltest`
      : `${sectionName}-urltest-${id}`,
  );
}

function getPriorityTag(sectionName: string, id: string) {
  return getOutboundTagBySection(`${sectionName}-priority-${id}`);
}

function getUrlTestDisplayName(
  section: Tachyon.ConfigSection,
  id: string,
  settings: ItemSettings | undefined,
) {
  const fallback =
    id === 'urltest' && !hasConfiguredUrlTestList(section)
      ? section.action === 'group'
        ? section.label || section.name || _('Fastest')
        : _('Fastest')
      : id;
  return itemSettingString(settings, 'display_name', fallback);
}

function getUrlTestConfigs(section: Tachyon.ConfigSection): UrlTestConfig[] {
  const settingsMap = itemSettingsMap(section.urltest_settings);
  const sectionName = section['.name'];

  return getUrlTestIds(section).map((id) => {
    const settings = settingsMap[id] || {};
    const filteringEnabled = isUrlTestFilteringEnabled(settings);

    return {
      id,
      code: getUrlTestTag(sectionName, id),
      displayName: getUrlTestDisplayName(section, id, settings),
      settings,
      pinDashboard: itemSettingBoolean(settings, 'pin_dashboard', true),
      showDetectedCountries:
        filteringEnabled &&
        itemSettingString(settings, 'detect_server_country', 'flag_emoji') ===
          'country_is',
    };
  });
}

function priorityLevelConfigsFromSettings(
  settings: ItemSettings | undefined,
): PriorityLevelConfig[] {
  const value = settings?.levels;

  if (!Array.isArray(value)) {
    return [];
  }

  return value
    .flatMap((item, index) => {
      if (!item || typeof item !== 'object' || Array.isArray(item)) {
        return [];
      }

      const level = item as Partial<PriorityLevelConfig> &
        Record<string, unknown>;
      const id = `${level.id || ''}`.trim();

      if (!id) {
        return [];
      }

      return [
        {
          id,
          displayName: `${level.displayName || id}`,
          order:
            typeof level.order === 'number' && Number.isFinite(level.order)
              ? level.order
              : index,
          direct: Boolean(level.direct),
          filterMode: `${level.filterMode || 'include'}` || 'include',
          detectServerCountry:
            `${level.detectServerCountry || 'flag_emoji'}` || 'flag_emoji',
          country: getListValues(level.country as string[] | string),
          serverName: getListValues(level.serverName as string[] | string),
          regex: getListValues(level.regex as string[] | string),
          excludeCountries: getListValues(
            level.excludeCountries as string[] | string,
          ),
          excludeOutbounds: getListValues(
            level.excludeOutbounds as string[] | string,
          ),
          excludeRegex: getListValues(level.excludeRegex as string[] | string),
          outbounds: getListValues(level.outbounds as string[] | string),
        },
      ];
    })
    .sort((left, right) =>
      left.order === right.order
        ? left.id.localeCompare(right.id)
        : left.order - right.order,
    );
}

function getPriorityGroupIds(section: Tachyon.ConfigSection) {
  return getListValues(section.priority_groups);
}

function getPriorityConfigs(section: Tachyon.ConfigSection): PriorityConfig[] {
  const settingsMap = itemSettingsMap(section.priority_group_settings);
  const sectionName = section['.name'];

  return getPriorityGroupIds(section).map((id) => {
    const settings = settingsMap[id] || {};
    const levels = priorityLevelConfigsFromSettings(settings);

    return {
      id,
      code: getPriorityTag(sectionName, id),
      displayName: itemSettingString(settings, 'name', id),
      settings,
      pinDashboard: itemSettingBoolean(settings, 'pin_dashboard', true),
      healthUrl: itemSettingString(
        settings,
        'health_url',
        'https://www.gstatic.com/generate_204',
      ),
      activeCheckInterval: itemSettingString(
        settings,
        'active_check_interval',
        '5s',
      ),
      checkTimeout: itemSettingString(settings, 'check_timeout', '2s'),
      recoveryCheckInterval: itemSettingString(
        settings,
        'recovery_check_interval',
        '15s',
      ),
      pickFastest: itemSettingBoolean(settings, 'pick_fastest', false),
      switchToFasterSamePriority: itemSettingBoolean(
        settings,
        'switch_to_faster_same_priority',
        false,
      ),
      fastestCheckInterval: itemSettingString(
        settings,
        'fastest_check_interval',
        '3m',
      ),
      interruptExistConnections: itemSettingBoolean(
        settings,
        'interrupt_exist_connections',
        true,
      ),
      showDetectedCountries: levels.some(
        (level) => level.detectServerCountry === 'country_is',
      ),
      levels,
    };
  });
}

async function readDashboardSectionCache(
  sectionName: string,
): Promise<DashboardSectionCache | undefined> {
  if (!isSafeSectionName(sectionName)) {
    return undefined;
  }

  const path = `${DASHBOARD_SECTION_CACHE_DIR}/${sectionName}.json`;

  try {
    const raw = await fs.read(path).catch(async () => {
      const directFs = fs as unknown as {
        read_direct?: (p: string, type?: string) => Promise<string>;
        exec_direct?: (
          cmd: string,
          args?: string[],
          type?: string,
        ) => Promise<string>;
      };
      if (typeof directFs.read_direct === 'function') {
        return directFs.read_direct(path, 'text');
      }
      if (typeof directFs.exec_direct === 'function') {
        return directFs.exec_direct('/bin/cat', [path], 'text');
      }
      const res = await fs.exec('/bin/cat', [path]);
      return res?.stdout || '';
    });
    const parsed = JSON.parse(raw) as DashboardSectionCache;

    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      return undefined;
    }

    return parsed;
  } catch (_error) {
    return undefined;
  }
}

// One flat map { section: reason } from the runtime's quarantine record.
export async function readSectionErrors(): Promise<Record<string, string>> {
  try {
    const raw = await fs.read(SECTION_ERRORS_FILE).catch(async () => {
      const directFs = fs as unknown as {
        read_direct?: (p: string, type?: string) => Promise<string>;
      };
      if (typeof directFs.read_direct === 'function') {
        return directFs.read_direct(SECTION_ERRORS_FILE, 'text');
      }
      return '';
    });
    const parsed = JSON.parse(raw) as unknown;

    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      if (typeof window !== 'undefined') {
        (
          window as unknown as {
            __tachyonSectionErrors?: Record<string, string>;
          }
        ).__tachyonSectionErrors = {};
      }
      return {};
    }

    const map = objectMap(parsed);
    if (typeof window !== 'undefined') {
      (
        window as unknown as { __tachyonSectionErrors?: Record<string, string> }
      ).__tachyonSectionErrors = map;
    }
    return map;
  } catch (_error) {
    if (typeof window !== 'undefined') {
      (
        window as unknown as { __tachyonSectionErrors?: Record<string, string> }
      ).__tachyonSectionErrors = {};
    }
    return {};
  }
}

function getUrlTestGroups(dashboardCache?: DashboardSectionCache) {
  const groups = dashboardCache?.urltestGroups;

  if (!groups || typeof groups !== 'object' || Array.isArray(groups)) {
    return {};
  }

  return groups;
}

function getPriorityGroups(dashboardCache?: DashboardSectionCache) {
  const groups = dashboardCache?.priorityGroups;

  if (!groups || typeof groups !== 'object' || Array.isArray(groups)) {
    return {};
  }

  return groups;
}

function getConfiguredSubscriptionPrefixes(
  section: Tachyon.ConfigSection,
): string[] {
  const settings = itemSettingsMap(section.subscription_url_settings);
  const prefixes: string[] = [];
  for (const url of Object.keys(settings)) {
    const item = settings[url];
    if (item && item.prefix_nodes === '1') {
      const p =
        typeof item.node_prefix === 'string' ? item.node_prefix.trim() : '';
      if (p && !prefixes.includes(p)) {
        prefixes.push(p);
      }
    }
  }
  return prefixes;
}

function getConfiguredSubscriptionPrefixStyles(section: Tachyon.ConfigSection) {
  const settings = itemSettingsMap(section.subscription_url_settings);
  const styles: Record<string, { bg?: string; color?: string }> = {};
  for (const url of Object.keys(settings)) {
    const item = settings[url];
    if (item && item.prefix_nodes === '1') {
      const p =
        typeof item.node_prefix === 'string' ? item.node_prefix.trim() : '';
      if (p) {
        const bg =
          typeof item.node_prefix_bg === 'string'
            ? item.node_prefix_bg.trim()
            : '';
        const color =
          typeof item.node_prefix_color === 'string'
            ? item.node_prefix_color.trim()
            : '';
        if (bg || color) {
          styles[p] = { bg: bg || undefined, color: color || undefined };
        }
      }
    }
  }
  if (typeof window !== 'undefined' && Object.keys(styles).length > 0) {
    const win = window as unknown as {
      __tachyonUciPrefixStyles?: Record<
        string,
        { bg?: string; color?: string }
      >;
    };
    win.__tachyonUciPrefixStyles = {
      ...(win.__tachyonUciPrefixStyles || {}),
      ...styles,
    };
  }
  return styles;
}

function dashboardOutboundType(
  code: string,
  runtimeType: string | undefined,
  outboundMetadata?: Tachyon.GetOutboundMetadata,
) {
  const proto = outboundMetadata?.protocols?.[code];
  if (proto === 'amneziawg') return 'AmneziaWG';
  if (proto === 'fptn') return 'FPTN';
  if (proto === 'shadowtls') return 'ShadowTLS';
  return runtimeType || '';
}

function buildOutboundDetails(
  code: string,
  outboundMetadata?: Tachyon.GetOutboundMetadata,
): string | undefined {
  const rawDetails = outboundMetadata?.details?.[code];
  const sec = outboundMetadata?.securities?.[code];
  const hasSec =
    sec &&
    sec !== 'none' &&
    (!rawDetails || !rawDetails.toLowerCase().includes(sec.toLowerCase()));
  if (hasSec && rawDetails) {
    return `${sec}+${rawDetails}`;
  }
  if (hasSec) {
    return sec;
  }
  return rawDetails;
}

function resolveOutboundNameAndPrefix({
  code,
  entry,
  link,
  outboundMetadata,
  preferMetadata = false,
  configuredPrefixes = [],
}: {
  code: string;
  entry?: ClashProxyEntry;
  link: string;
  outboundMetadata?: Tachyon.GetOutboundMetadata;
  preferMetadata?: boolean;
  configuredPrefixes?: string[];
}): { displayName: string; prefix?: string } {
  const isFptn =
    link.startsWith('fptn:') ||
    link.startsWith('fptnb:') ||
    link.startsWith('fptn://') ||
    link.startsWith('fptnb://');
  const metadataName = outboundMetadata?.names?.[code];
  const proxyUrlName = isFptn ? '' : getProxyUrlName(link);
  const fallbackServerName = code.includes('/')
    ? code.split('/').pop()
    : undefined;
  const rawName =
    (preferMetadata ? metadataName : proxyUrlName) ||
    (preferMetadata ? proxyUrlName : metadataName) ||
    entry?.value?.name ||
    fallbackServerName ||
    code;

  let prefix = outboundMetadata?.prefixes?.[code]?.trim() || '';

  if (!prefix && configuredPrefixes.length > 0) {
    for (const p of configuredPrefixes) {
      if (!p) continue;
      if (
        rawName.startsWith(p + ' ') ||
        rawName.startsWith(p + '-') ||
        rawName.startsWith(p + '/') ||
        code.startsWith(p + ' ') ||
        code.startsWith(p + '-') ||
        code.startsWith(p + '/') ||
        entry?.value?.name?.startsWith(p + ' ') ||
        entry?.value?.name?.startsWith(p + '-') ||
        entry?.value?.name?.startsWith(p + '/')
      ) {
        prefix = p;
        break;
      }
    }
  }

  let displayName = rawName;
  if (prefix) {
    if (displayName.startsWith(prefix + ' ')) {
      const stripped = displayName.slice(prefix.length + 1).trim();
      if (stripped) {
        displayName = stripped;
      }
    } else if (displayName.startsWith(prefix + '-')) {
      const stripped = displayName.slice(prefix.length + 1).trim();
      if (stripped) {
        displayName = stripped;
      }
    } else if (displayName.startsWith(prefix + '/')) {
      const stripped = displayName.slice(prefix.length + 1).trim();
      if (stripped) {
        displayName = stripped;
      }
    }
  } else if (/^[A-Za-z0-9_-]+\//.test(displayName)) {
    const parts = displayName.split('/');
    if (parts.length > 1 && parts[parts.length - 1].trim()) {
      prefix = parts.slice(0, -1).join('/');
      displayName = parts[parts.length - 1].trim();
    }
  }

  return {
    displayName,
    prefix: prefix || undefined,
  };
}

function buildUrlTestInfo({
  code,
  displayName,
  config,
  entry,
  groupCache,
  proxyByCode,
  manualLinkByCode,
  cachedProxyLinks,
  outboundMetadata,
  showDetectedCountries,
  selectorNow,
  selectorCodes = [],
  configuredPrefixes = [],
}: {
  code: string;
  displayName: string;
  config?: UrlTestConfig;
  entry?: ClashProxyEntry;
  groupCache?: UrlTestCacheGroup;
  proxyByCode: Map<string, ClashProxyEntry>;
  manualLinkByCode: Map<string, string>;
  cachedProxyLinks: Map<string, string>;
  outboundMetadata?: Tachyon.GetOutboundMetadata;
  showDetectedCountries: boolean;
  selectorNow?: string;
  selectorCodes?: string[];
  configuredPrefixes?: string[];
}): Tachyon.UrlTestInfo {
  const childCodes = uniqueCodes(
    groupCache?.outbounds?.length
      ? groupCache.outbounds
      : entry?.value.all || [],
  );
  const isChildSelectedInSelector = Boolean(
    selectorNow &&
      selectorNow !== code &&
      childCodes.includes(selectorNow) &&
      !selectorCodes.includes(selectorNow),
  );
  const selectedCode = isChildSelectedInSelector
    ? selectorNow!
    : entry?.value.now || '';
  const isManualSelection = isChildSelectedInSelector;

  const outbounds = sortUrlTestMembers(
    childCodes.flatMap((childCode) => {
      const childEntry = proxyByCode.get(childCode);
      const link =
        findManualLink(manualLinkByCode, childCode) ||
        cachedProxyLinks.get(childCode) ||
        '';
      const canCopyLink = isCopyableProxyLink(link);
      const resolved = resolveOutboundNameAndPrefix({
        code: childCode,
        entry: childEntry,
        link,
        outboundMetadata,
        preferMetadata: cachedProxyLinks.has(childCode),
        configuredPrefixes,
      });

      return [
        {
          code: childCode,
          displayName: resolved.displayName,
          prefix: resolved.prefix,
          latency: childEntry?.value?.history?.[0]?.delay || 0,
          type: dashboardOutboundType(
            childCode,
            childEntry?.value?.type,
            outboundMetadata,
          ),
          transport:
            outboundMetadata?.transports?.[childCode] ||
            getProxyUrlTransport(link),
          details: buildOutboundDetails(childCode, outboundMetadata),
          selected: selectedCode === childCode,
          link,
          canCopyLink,
          country: showDetectedCountries
            ? outboundMetadata?.countries?.[childCode]
            : undefined,
        },
      ];
    }),
  );
  const selectedName =
    outbounds.find((outbound) => outbound.code === selectedCode)?.displayName ||
    selectedCode;
  const cfgSettings = config?.settings;

  return {
    code,
    displayName: groupCache?.displayName || displayName,
    selectedCode: selectedCode || undefined,
    selectedName: selectedName || undefined,
    isManualSelection,
    url:
      groupCache?.url ||
      itemSettingString(cfgSettings, 'urltest_testing_url', '') ||
      undefined,
    interval:
      groupCache?.interval ||
      itemSettingString(cfgSettings, 'urltest_check_interval', '') ||
      undefined,
    tolerance:
      groupCache?.tolerance ??
      (itemSettingString(cfgSettings, 'urltest_tolerance', '') || undefined),
    idleTimeout:
      groupCache?.idle_timeout ||
      itemSettingString(cfgSettings, 'idle_timeout', '') ||
      '30m',
    interruptExistConnections:
      groupCache?.interrupt_exist_connections ??
      (cfgSettings?.interrupt_exist_connections !== undefined
        ? itemSettingBoolean(cfgSettings, 'interrupt_exist_connections', true)
        : undefined),
    outbounds,
  };
}

function buildPriorityInfo({
  config,
  entry,
  groupCache,
  proxyByCode,
  manualLinkByCode,
  cachedProxyLinks,
  outboundMetadata,
  showDetectedCountries,
  selectorNow,
  selectorCodes = [],
  configuredPrefixes = [],
}: {
  config: PriorityConfig;
  entry?: ClashProxyEntry;
  groupCache?: PriorityCacheGroup;
  proxyByCode: Map<string, ClashProxyEntry>;
  manualLinkByCode: Map<string, string>;
  cachedProxyLinks: Map<string, string>;
  outboundMetadata?: Tachyon.GetOutboundMetadata;
  showDetectedCountries: boolean;
  selectorNow?: string;
  selectorCodes?: string[];
  configuredPrefixes?: string[];
}): Tachyon.PriorityInfo {
  const cacheLevels = Array.isArray(groupCache?.levels)
    ? groupCache.levels
    : [];
  const configLevelById = new Map(
    config.levels.map((level) => [level.id, level]),
  );
  const levels = (
    cacheLevels.length
      ? cacheLevels.map((level, index): PriorityLevelConfig => {
          const id = `${level.id || ''}`;
          const configLevel = id ? configLevelById.get(id) : undefined;

          return {
            id: id || configLevel?.id || `level-${index + 1}`,
            displayName:
              level.displayName || configLevel?.displayName || `${index + 1}`,
            order:
              typeof level.order === 'number' && Number.isFinite(level.order)
                ? level.order
                : (configLevel?.order ?? index),
            direct: level.direct ?? configLevel?.direct ?? false,
            filterMode:
              level.filter_mode || configLevel?.filterMode || 'include',
            detectServerCountry:
              level.detect_server_country ||
              configLevel?.detectServerCountry ||
              'flag_emoji',
            country: configLevel?.country || [],
            serverName: configLevel?.serverName || [],
            regex: configLevel?.regex || [],
            excludeCountries: configLevel?.excludeCountries || [],
            excludeOutbounds: configLevel?.excludeOutbounds || [],
            excludeRegex: configLevel?.excludeRegex || [],
            outbounds: uniqueCodes(level.outbounds || []),
          };
        })
      : config.levels.map((level) => ({
          ...level,
          outbounds: uniqueCodes(level.outbounds || []),
        }))
  ).sort((left, right) =>
    left.order === right.order
      ? left.id.localeCompare(right.id)
      : left.order - right.order,
  );
  const allChildCodes = levels.flatMap((l) => l.outbounds);
  const isChildSelectedInSelector = Boolean(
    selectorNow &&
      selectorNow !== config.code &&
      allChildCodes.includes(selectorNow) &&
      !selectorCodes.includes(selectorNow),
  );
  const selectedCode = isChildSelectedInSelector
    ? selectorNow!
    : entry?.value.now || '';
  const isManualSelection = isChildSelectedInSelector;

  const outbounds = levels.flatMap((level, levelIndex) => {
    const members = uniqueCodes(level.outbounds || []).map((childCode) => {
      const childEntry = proxyByCode.get(childCode);
      const link =
        findManualLink(manualLinkByCode, childCode) ||
        cachedProxyLinks.get(childCode) ||
        '';
      const canCopyLink = isCopyableProxyLink(link);
      const resolved = resolveOutboundNameAndPrefix({
        code: childCode,
        entry: childEntry,
        link,
        outboundMetadata,
        preferMetadata: cachedProxyLinks.has(childCode),
        configuredPrefixes,
      });

      return {
        code: childCode,
        displayName: resolved.displayName,
        prefix: resolved.prefix,
        latency: childEntry?.value?.history?.[0]?.delay || 0,
        type: dashboardOutboundType(
          childCode,
          childEntry?.value?.type,
          outboundMetadata,
        ),
        transport:
          outboundMetadata?.transports?.[childCode] ||
          getProxyUrlTransport(link),
        details: buildOutboundDetails(childCode, outboundMetadata),
        selected: selectedCode === childCode,
        link,
        canCopyLink,
        country: showDetectedCountries
          ? outboundMetadata?.countries?.[childCode]
          : undefined,
        levelIndex,
        levelName: level.displayName,
        levelId: level.id,
      };
    });

    if (!config.pickFastest) {
      return members;
    }

    return members
      .map((outbound, index) => ({ outbound, index }))
      .sort((left, right) => {
        const latencyDiff =
          getLatencySortValue(left.outbound) -
          getLatencySortValue(right.outbound);

        return latencyDiff !== 0 ? latencyDiff : left.index - right.index;
      })
      .map((item) => item.outbound);
  });
  const selectedName =
    outbounds.find((outbound) => outbound.code === selectedCode)?.displayName ||
    selectedCode;

  return {
    code: config.code,
    displayName: groupCache?.displayName || config.displayName,
    selectedCode: selectedCode || undefined,
    selectedName: selectedName || undefined,
    isManualSelection,
    healthUrl: groupCache?.health_url || config.healthUrl,
    activeCheckInterval:
      groupCache?.active_check_interval || config.activeCheckInterval,
    checkTimeout: groupCache?.check_timeout || config.checkTimeout,
    recoveryCheckInterval:
      groupCache?.recovery_check_interval || config.recoveryCheckInterval,
    pickFastest: groupCache?.pick_fastest ?? config.pickFastest,
    switchToFasterSamePriority:
      groupCache?.switch_to_faster_same_priority ??
      config.switchToFasterSamePriority,
    fastestCheckInterval:
      groupCache?.fastest_check_interval || config.fastestCheckInterval,
    interruptExistConnections:
      groupCache?.interrupt_exist_connections ??
      config.interruptExistConnections,
    outbounds,
  };
}

function buildProxyGroupOutbounds(
  section: Tachyon.ConfigSection,
  proxies: ClashProxyEntry[],
  outboundMetadata?: Tachyon.GetOutboundMetadata,
  urltestGroups: Record<string, UrlTestCacheGroup> = {},
  priorityGroups: Record<string, PriorityCacheGroup> = {},
  cachedProxyLinks: Map<string, string> = new Map(),
  hiddenOutboundTags: Record<string, boolean> = {},
  memberSections: Tachyon.ConfigSection[] = [],
  sortMode?: 'latency' | 'country_latency' | 'country_alpha' | 'default',
) {
  const sectionName = section['.name'];
  const configuredPrefixes = uniqueCodes([
    ...getConfiguredSubscriptionPrefixes(section),
    ...memberSections.flatMap((m) => getConfiguredSubscriptionPrefixes(m)),
  ]);
  getConfiguredSubscriptionPrefixStyles(section);
  for (const m of memberSections) {
    getConfiguredSubscriptionPrefixStyles(m);
  }
  const proxyByCode = getProxyEntryByCode(proxies);
  const selectorTag = getOutboundTagBySection(sectionName);
  const selector = proxyByCode.get(selectorTag);
  const urlTestConfigs = getUrlTestConfigs(section);
  const urlTestConfigByCode = new Map(
    urlTestConfigs.map((config) => [config.code, config]),
  );
  const priorityConfigs = getPriorityConfigs(section);
  const priorityConfigByCode = new Map(
    priorityConfigs.map((config) => [config.code, config]),
  );
  const urlTestEntries = urlTestConfigs.map((config) => ({
    config,
    entry: proxyByCode.get(config.code),
  }));
  const priorityEntries = priorityConfigs.map((config) => ({
    config,
    entry: proxyByCode.get(config.code),
  }));
  const manualLinkByCode = buildManualLinkByCode(section);
  for (const m of memberSections) {
    for (const [k, v] of buildManualLinkByCode(m)) {
      if (!manualLinkByCode.has(k)) {
        manualLinkByCode.set(k, v);
      }
    }
  }
  const rawSelectorCodes = selector?.value?.all ?? [];
  const selectorCodes = rawSelectorCodes.filter(
    (code) => !hiddenOutboundTags[code],
  );
  const urlTestCodes = urlTestConfigs.map((config) => config.code);
  const priorityCodes = priorityConfigs.map((config) => config.code);
  const showDetectedCountries =
    urlTestConfigs.some((config) => config.showDetectedCountries) ||
    priorityConfigs.some((config) => config.showDetectedCountries);
  const builtInUrltestCode = urlTestCodes[0] || '';
  const groupUrlTestMemberCodes = urlTestEntries.flatMap(
    ({ config, entry }) =>
      urltestGroups[config.code]?.outbounds || entry?.value.all || [],
  );
  const groupPriorityMemberCodes = priorityEntries.flatMap(
    ({ config, entry }) =>
      priorityGroups[config.code]?.outbounds || entry?.value.all || [],
  );
  const fallbackCodes =
    section.action === 'group'
      ? uniqueCodes([
          ...urlTestCodes,
          ...priorityCodes,
          ...(groupUrlTestMemberCodes.length > 0 ||
          groupPriorityMemberCodes.length > 0
            ? [...groupUrlTestMemberCodes, ...groupPriorityMemberCodes]
            : [
                ...Array.from(cachedProxyLinks.keys()),
                ...Array.from(manualLinkByCode.keys()),
              ]),
        ]).filter((code) => !hiddenOutboundTags[code])
      : uniqueCodes([
          ...urlTestCodes,
          ...priorityCodes,
          ...Array.from(cachedProxyLinks.keys()),
          ...Array.from(manualLinkByCode.keys()),
          ...urlTestEntries.flatMap(({ entry }) => entry?.value.all || []),
          ...priorityEntries.flatMap(({ entry }) => entry?.value.all || []),
        ]).filter((code) => !hiddenOutboundTags[code]);
  const groupCodes = uniqueCodes([
    ...(selectorCodes.length ? selectorCodes : fallbackCodes),
    ...urlTestCodes,
    ...priorityCodes,
  ]).filter((code) => !hiddenOutboundTags[code]);

  const selectorNow =
    selector?.value?.now ||
    (selectorCodes.length > 0 ? selectorCodes[0] : undefined) ||
    urlTestCodes[0] ||
    priorityCodes[0];

  const outbounds = uniqueCodes(groupCodes).flatMap((code) => {
    if (hiddenOutboundTags[code]) {
      return [];
    }
    const item = proxyByCode.get(code);
    const urlTestConfig = urlTestConfigByCode.get(code);
    const priorityConfig = priorityConfigByCode.get(code);
    const link =
      findManualLink(manualLinkByCode, code) ||
      cachedProxyLinks.get(code) ||
      '';

    if (!item && !urlTestConfig && !priorityConfig && !link) {
      return [];
    }

    const effectiveItem =
      item ||
      (link
        ? ({
            code,
            value: {
              name: outboundMetadata?.names?.[code] || code,
              type: outboundMetadata?.transports?.[code] || 'VLESS',
              udp: true,
              history: [],
              all: [],
              now: '',
            },
          } as ClashProxyEntry)
        : undefined);

    const canCopyLink = isCopyableProxyLink(link);
    const resolved = resolveOutboundNameAndPrefix({
      code,
      entry: effectiveItem,
      link,
      outboundMetadata,
      preferMetadata: cachedProxyLinks.has(code),
      configuredPrefixes,
    });
    const displayName =
      priorityConfig?.displayName ||
      urlTestConfig?.displayName ||
      resolved.displayName;
    const prefix =
      priorityConfig || urlTestConfig ? undefined : resolved.prefix;
    const isRuntimeUrlTest = isUrlTestProxyEntry(item);

    const urlTestInfo =
      urlTestConfig || isRuntimeUrlTest
        ? buildUrlTestInfo({
            code,
            displayName,
            config: urlTestConfig,
            entry: item,
            groupCache: urltestGroups[code],
            proxyByCode,
            manualLinkByCode,
            cachedProxyLinks,
            outboundMetadata,
            showDetectedCountries:
              urlTestConfig?.showDetectedCountries || showDetectedCountries,
            selectorNow,
            selectorCodes,
            configuredPrefixes,
          })
        : undefined;

    const priorityInfo = priorityConfig
      ? buildPriorityInfo({
          config: priorityConfig,
          entry: item,
          groupCache: priorityGroups[code],
          proxyByCode,
          manualLinkByCode,
          cachedProxyLinks,
          outboundMetadata,
          showDetectedCountries: priorityConfig.showDetectedCountries,
          selectorNow,
          selectorCodes,
          configuredPrefixes,
        })
      : undefined;

    const isUrlTestChildSelected = Boolean(
      urlTestInfo?.isManualSelection &&
        urlTestInfo?.selectedCode &&
        urlTestInfo.outbounds.some((m) => m.code === selectorNow),
    );
    const isPriorityChildSelected = Boolean(
      priorityInfo?.isManualSelection &&
        priorityInfo?.selectedCode &&
        priorityInfo.outbounds.some((m) => m.code === selectorNow),
    );

    const isSelected =
      selectorNow === code || isUrlTestChildSelected || isPriorityChildSelected;

    const activeMemberLatency =
      (isUrlTestChildSelected &&
        urlTestInfo?.outbounds.find((m) => m.code === selectorNow)?.latency) ||
      (isPriorityChildSelected &&
        priorityInfo?.outbounds.find((m) => m.code === selectorNow)?.latency) ||
      urlTestInfo?.outbounds.find(
        (m) => m.selected || m.code === urlTestInfo.selectedCode,
      )?.latency ||
      priorityInfo?.outbounds.find(
        (m) => m.selected || m.code === priorityInfo.selectedCode,
      )?.latency ||
      0;

    const itemDelay = Number(effectiveItem?.value.history?.[0]?.delay);
    const validItemDelay =
      Number.isFinite(itemDelay) && itemDelay > 0 ? itemDelay : 0;
    const latency =
      validItemDelay || (activeMemberLatency > 0 ? activeMemberLatency : 0);

    const isGroupType = Boolean(
      priorityConfig || urlTestConfig || isRuntimeUrlTest,
    );

    let sourceGroup = isGroupType
      ? undefined
      : outboundMetadata?.sources?.[code];
    if (!sourceGroup && !isGroupType) {
      if (findManualLink(manualLinkByCode, code)) {
        sourceGroup = 'manual';
      } else {
        const subUrls = getListValues(section.subscription_urls);
        if (prefix && subUrls.length > 0) {
          const subSettings = itemSettingsMap(
            section.subscription_url_settings,
          );
          const matchedIdx = subUrls.findIndex((u) => {
            const st = subSettings[u];
            return (
              st?.prefix_nodes === '1' &&
              typeof st.node_prefix === 'string' &&
              st.node_prefix.trim() === prefix
            );
          });
          if (matchedIdx >= 0) {
            sourceGroup = `sub:${matchedIdx + 1}`;
          }
        }
        if (!sourceGroup && subUrls.length === 1) {
          sourceGroup = 'sub:1';
        }
      }
    }

    return [
      {
        code,
        displayName,
        prefix,
        latency,
        type: priorityConfig
          ? 'Priority'
          : dashboardOutboundType(
              code,
              effectiveItem?.value.type || 'URLTest',
              outboundMetadata,
            ),
        transport: isGroupType
          ? undefined
          : outboundMetadata?.transports?.[code] || getProxyUrlTransport(link),
        details: isGroupType
          ? undefined
          : buildOutboundDetails(code, outboundMetadata),
        selected: isSelected,
        link,
        canCopyLink,
        country: showDetectedCountries
          ? outboundMetadata?.countries?.[code]
          : undefined,
        runtimeAvailable: effectiveItem ? undefined : false,
        urlTestInfo,
        priorityInfo,
        sourceGroup,
      },
    ];
  });

  const sortedOutbounds = sortOutboundsForDashboard(outbounds, {
    pinnedCodes: [
      ...urlTestEntries
        .filter(({ config }) => config.pinDashboard)
        .map(({ config }) => config.code),
      ...priorityEntries
        .filter(({ config }) => config.pinDashboard)
        .map(({ config }) => config.code),
    ],
    sortMode,
    sortByLatency: sortMode === 'latency' || shouldSortByLatency(section),
  });
  const latencyTestCodes = sortedOutbounds
    .filter(
      (outbound) =>
        outbound.runtimeAvailable !== false &&
        !isSelectorOutbound(outbound) &&
        !outbound.priorityInfo,
    )
    .map((outbound) => outbound.code);

  return {
    selector,
    latencyTestCode: selector?.code || builtInUrltestCode,
    latencyTestCodes:
      latencyTestCodes.length > 0 ? latencyTestCodes : undefined,
    outbounds: sortedOutbounds,
  };
}

function metadataMatchesCurrentSource(
  sectionName: string,
  sourceCount: number,
  metadata: Tachyon.SubscriptionMetadata,
) {
  const legacyMetadata = metadata as Tachyon.SubscriptionMetadata & {
    source_index?: number;
    source_section?: string;
  };
  const sourceIndex = metadata.sourceIndex ?? legacyMetadata.source_index;
  const sourceSection =
    metadata.sourceSection || legacyMetadata.source_section || '';
  const hasSourceIndex = typeof sourceIndex === 'number';
  const hasSourceSection = sourceSection !== '';

  if (!hasSourceIndex && !hasSourceSection) {
    return sourceCount <= 1;
  }

  if (sourceCount > 1 && !hasSourceSection) {
    return false;
  }

  if (hasSourceIndex && (sourceIndex < 1 || sourceIndex > sourceCount)) {
    return false;
  }

  if (hasSourceSection) {
    const expectedSourcePrefix = `${sectionName}-subscription-`;

    if (!sourceSection.startsWith(expectedSourcePrefix)) {
      return false;
    }

    const sourceSectionIndex = Number(
      sourceSection.slice(expectedSourcePrefix.length),
    );

    if (
      !Number.isInteger(sourceSectionIndex) ||
      sourceSectionIndex < 1 ||
      sourceSectionIndex > sourceCount
    ) {
      return false;
    }

    if (hasSourceIndex && sourceIndex !== sourceSectionIndex) {
      return false;
    }
  }

  return true;
}

function getSubscriptionMetadataSourceIndex(
  sectionName: string,
  sourceCount: number,
  metadata: Tachyon.SubscriptionMetadata,
) {
  const legacyMetadata = metadata as Tachyon.SubscriptionMetadata & {
    source_index?: number;
    source_section?: string;
  };
  const sourceIndex = metadata.sourceIndex ?? legacyMetadata.source_index;

  if (typeof sourceIndex === 'number') {
    return sourceIndex;
  }

  const sourceSection =
    metadata.sourceSection || legacyMetadata.source_section || '';
  const expectedSourcePrefix = `${sectionName}-subscription-`;

  if (sourceSection.startsWith(expectedSourcePrefix)) {
    const parsed = Number(sourceSection.slice(expectedSourcePrefix.length));
    return Number.isInteger(parsed) ? parsed : undefined;
  }

  return sourceCount <= 1 ? 1 : undefined;
}

function isSubscriptionMetadataVisible(
  section: Tachyon.ConfigSection,
  sourceCount: number,
  metadata: Tachyon.SubscriptionMetadata,
) {
  const sourceIndex = getSubscriptionMetadataSourceIndex(
    section['.name'],
    sourceCount,
    metadata,
  );

  if (!sourceIndex || sourceIndex < 1 || sourceIndex > sourceCount) {
    return true;
  }

  const sourceEntry = getListValues(section.subscription_urls)[sourceIndex - 1];
  const settings = itemSettingsMap(section.subscription_url_settings)[
    sourceEntry
  ];

  return settings?.show_dashboard_metadata !== '0';
}

function getSubscriptionMetadata(
  section: Tachyon.ConfigSection,
  sourceCount: number,
  dashboardCache?: DashboardSectionCache,
  globalShowMetadata = true,
) {
  if (!globalShowMetadata || !dashboardCache?.subscriptionMetadata) {
    return undefined;
  }

  const metadataItems = Array.isArray(dashboardCache.subscriptionMetadata)
    ? dashboardCache.subscriptionMetadata
    : [dashboardCache.subscriptionMetadata];
  const visibleMetadataItems = metadataItems.filter(
    (metadata) =>
      metadata &&
      Object.keys(metadata).length > 1 &&
      metadataMatchesCurrentSource(section['.name'], sourceCount, metadata) &&
      isSubscriptionMetadataVisible(section, sourceCount, metadata),
  );

  if (visibleMetadataItems.length > 0) {
    return visibleMetadataItems;
  }

  return undefined;
}

function getOutboundMetadata(dashboardCache?: DashboardSectionCache) {
  const metadata = dashboardCache?.outboundMetadata;

  if (!metadata || typeof metadata !== 'object') {
    return undefined;
  }

  return {
    names: objectMap(metadata.names),
    countries: objectMap(metadata.countries),
    transports: objectMap(metadata.transports),
    protocols: objectMap(metadata.protocols),
    securities: objectMap(metadata.securities),
    ports: objectMap(metadata.ports),
    details: objectMap(metadata.details),
    prefixes: objectMap(metadata.prefixes),
    sources: objectMap(metadata.sources),
  };
}

function getCachedProxyLinks(
  dashboardCache?: DashboardSectionCache,
  includeHidden = false,
) {
  const hidden = dashboardCache?.hiddenOutboundTags ?? {};
  return new Map(
    Object.entries(objectMap(dashboardCache?.links)).filter(
      ([code, link]) =>
        isCopyableProxyLink(link) && (includeHidden || !hidden[code]),
    ),
  );
}

export async function getDashboardSections(
  options: IGetDashboardSectionsOptions = {},
): Promise<IGetDashboardSectionsResponse> {
  const includeSubscriptionCopyState =
    options.includeSubscriptionCopyState ?? true;
  const configSections = hydrateConfigSections(await getConfigSections());
  const sectionErrorsPromise = readSectionErrors();
  const clashProxies = await getClashApiProxies(configSections);

  if (
    (!clashProxies.success || !clashProxies.data?.proxies) &&
    configSections.length === 0
  ) {
    return {
      success: false,
      data: [],
    };
  }

  const proxies =
    clashProxies.success && clashProxies.data?.proxies
      ? Object.entries(clashProxies.data.proxies).map(([key, value]) => ({
          code: key,
          value,
        }))
      : [];
  const serviceStatusCache = new Map<
    string,
    Promise<Tachyon.ServiceStatus | undefined>
  >();

  const getServiceStatus = (
    serviceType:
      | 'zapret'
      | 'zapret2'
      | 'byedpi'
      | 'desync'
      | 'wdtt'
      | 'olcrtc'
      | 'fptn',
  ) => {
    if (!serviceStatusCache.has(serviceType)) {
      serviceStatusCache.set(
        serviceType,
        (async () => {
          try {
            if (serviceType === 'zapret') {
              const result = await TachyonShellMethods.getZapretStatus();
              if (result.success && result.data) {
                const s = result.data;
                return {
                  serviceType: 'zapret',
                  configured: Boolean(s.configured),
                  ready: Boolean(s.ready),
                  conflict: Boolean(s.conflict),
                  runningProcesses: s.running_process_count,
                  expectedProcesses: s.expected_process_count,
                  restartCount: s.restart_count,
                  unstable: Boolean(s.runtime_unstable),
                  statusMessage: s.status_message,
                };
              }
            } else if (serviceType === 'zapret2') {
              const result = await TachyonShellMethods.getZapret2Status();
              if (result.success && result.data) {
                const s = result.data;
                return {
                  serviceType: 'zapret2',
                  configured: Boolean(s.configured),
                  ready: Boolean(s.ready),
                  conflict: Boolean(s.conflict),
                  runningProcesses: s.running_process_count,
                  expectedProcesses: s.expected_process_count,
                  restartCount: 0,
                  unstable: false,
                  statusMessage: s.status_message,
                };
              }
            } else if (serviceType === 'byedpi') {
              const result = await TachyonShellMethods.getByedpiStatus();
              if (result.success && result.data) {
                const s = result.data;
                return {
                  serviceType: 'byedpi',
                  configured: Boolean(s.configured),
                  ready: Boolean(s.ready),
                  conflict: Boolean(s.conflict),
                  runningProcesses: s.running_process_count,
                  expectedProcesses: s.expected_process_count,
                  restartCount: s.restart_count,
                  unstable: Boolean(s.runtime_unstable),
                  statusMessage: s.status_message,
                };
              }
            } else if (serviceType === 'wdtt') {
              const result = await TachyonShellMethods.getWdttStatus();
              if (result.success && result.data) {
                const s = result.data;
                return {
                  serviceType: 'wdtt',
                  configured: Boolean(s.configured),
                  ready: Boolean(s.ready),
                  conflict: Boolean(s.conflict),
                  runningProcesses: s.running_process_count,
                  expectedProcesses: s.expected_process_count,
                  restartCount: s.restart_count,
                  unstable: Boolean(s.runtime_unstable),
                  statusMessage: s.status_message,
                };
              }
            } else if (serviceType === 'olcrtc') {
              const result = await TachyonShellMethods.getOlcrtcStatus();
              if (result.success && result.data) {
                const s = result.data;
                return {
                  serviceType: 'olcrtc',
                  configured: Boolean(s.configured),
                  ready: Boolean(s.ready),
                  conflict: Boolean(s.conflict),
                  runningProcesses: s.running_process_count,
                  expectedProcesses: s.expected_process_count,
                  restartCount: s.restart_count,
                  unstable: Boolean(s.runtime_unstable),
                  statusMessage: s.status_message,
                };
              }
            } else if (serviceType === 'fptn') {
              const result = await TachyonShellMethods.getFptnStatus();
              if (result.success && result.data) {
                const s = result.data;
                return {
                  serviceType: 'fptn',
                  configured: Boolean(s.configured),
                  ready: Boolean(s.ready),
                  conflict: false,
                  runningProcesses: s.service_running ? 1 : 0,
                  expectedProcesses: s.configured ? 1 : 0,
                  restartCount: 0,
                  unstable: false,
                  statusMessage:
                    s.status_message || (s.ready ? _('Running') : _('Stopped')),
                };
              }
            } else if (serviceType === 'desync') {
              // desync runs inside tachyon-core — there is no separate process.
              // Reflect readiness from the tachyon-core/sing-box engine status.
              const result = await TachyonShellMethods.getSingBoxStatus();
              if (result.success && result.data) {
                const s = result.data;
                const isRunning = Boolean(s.running);
                return {
                  serviceType: 'desync' as const,
                  configured: true,
                  ready: isRunning,
                  conflict: false,
                  runningProcesses: isRunning ? 1 : 0,
                  expectedProcesses: 1,
                  restartCount: 0,
                  unstable: false,
                  statusMessage: isRunning ? _('Running') : _('Stopped'),
                };
              }
              // Fallback when the RPC call fails: report as running to avoid
              // confusing "N/A" — desync has no standalone process to check.
              return {
                serviceType: 'desync' as const,
                configured: true,
                ready: true,
                conflict: false,
                runningProcesses: 1,
                expectedProcesses: 1,
                restartCount: 0,
                unstable: false,
                statusMessage: _('Running'),
              };
            }
          } catch (_error) {
            // Status fetch failed — show section without status
          }
          return undefined;
        })(),
      );
    }
    return serviceStatusCache.get(serviceType)!;
  };

  const sectionErrors = await sectionErrorsPromise;
  const settingsSection = getSettingsSection(configSections);
  const globalCountryGrouping =
    (settingsSection?.dashboard_country_grouping as
      | 'chips'
      | 'accordion'
      | 'none'
      | undefined) || 'chips';
  const globalChipsGrouping =
    (settingsSection?.dashboard_chips_grouping as
      | 'regions'
      | 'smart_top'
      | 'latency'
      | 'alphabetical'
      | undefined) || 'regions';
  const globalChipsLatencyMode =
    (settingsSection?.dashboard_country_chips_latency_mode as
      | 'min'
      | 'max'
      | undefined) || 'min';
  const globalSortMode =
    (settingsSection?.dashboard_sort_mode as
      | 'latency'
      | 'country_latency'
      | 'country_alpha'
      | 'default'
      | undefined) || 'latency';
  const globalHoverFreeze = settingsSection?.dashboard_hover_freeze !== '0';
  const globalShowSubscriptionMetadata =
    settingsSection?.dashboard_show_subscription_metadata !== '0';

  const data = await Promise.all(
    configSections
      .filter(
        (section) =>
          section.enabled !== '0' &&
          (isConnectionAction(section.action) ||
            isServiceAction(section.action)),
      )
      .map(async (section) => {
        const displayName = getDisplayName(section);
        const sectionName = section['.name'];
        const sectionAction = section.action;
        const proxyConfigType = getSectionProxyConfigType(section);
        const sectionSortByLatency = shouldSortByLatency(section);
        const effectiveSortMode =
          !sectionSortByLatency && !section.dashboard_sort_mode
            ? 'default'
            : (section.dashboard_sort_mode as typeof globalSortMode) ||
              globalSortMode ||
              'latency';
        const effectiveCountryGrouping =
          (section.dashboard_country_grouping as typeof globalCountryGrouping) ||
          globalCountryGrouping;
        const effectiveChipsGrouping =
          (section.dashboard_chips_grouping as typeof globalChipsGrouping) ||
          globalChipsGrouping;
        const effectiveChipsLatencyMode =
          (section.dashboard_country_chips_latency_mode as typeof globalChipsLatencyMode) ||
          globalChipsLatencyMode;

        if (isConnectionAction(sectionAction) && shouldUseProxyGroup(section)) {
          const subscriptionSourceCount = getSubscriptionSourceCount(section);
          const subscriptionEnabled = subscriptionSourceCount > 0;
          const dashboardCache = await readDashboardSectionCache(sectionName);
          let outboundMetadata = getOutboundMetadata(dashboardCache);
          const subscriptionMetadata = subscriptionEnabled
            ? getSubscriptionMetadata(
                section,
                subscriptionSourceCount,
                dashboardCache,
                globalShowSubscriptionMetadata,
              )
            : undefined;
          const cachedProxyLinks = includeSubscriptionCopyState
            ? getCachedProxyLinks(dashboardCache)
            : new Map<string, string>();
          const urltestGroups = getUrlTestGroups(dashboardCache);
          const priorityGroups = getPriorityGroups(dashboardCache);
          const hiddenOutboundTags = dashboardCache?.hiddenOutboundTags ?? {};
          const memberNames =
            sectionAction === 'group'
              ? getListValues(section.group_members).map((m) => m.trim())
              : [];
          const memberSections =
            memberNames.length > 0
              ? configSections.filter((s) => memberNames.includes(s['.name']))
              : [];

          if (memberSections.length > 0) {
            const memberCaches = await Promise.all(
              memberSections.map((m) => readDashboardSectionCache(m['.name'])),
            );
            for (const mCache of memberCaches) {
              if (!mCache) continue;
              const mMeta = getOutboundMetadata(mCache);
              if (mMeta) {
                outboundMetadata = {
                  names: { ...mMeta.names, ...outboundMetadata?.names },
                  countries: {
                    ...mMeta.countries,
                    ...outboundMetadata?.countries,
                  },
                  transports: {
                    ...mMeta.transports,
                    ...outboundMetadata?.transports,
                  },
                  protocols: {
                    ...mMeta.protocols,
                    ...outboundMetadata?.protocols,
                  },
                  securities: {
                    ...mMeta.securities,
                    ...outboundMetadata?.securities,
                  },
                  ports: { ...mMeta.ports, ...outboundMetadata?.ports },
                  details: {
                    ...mMeta.details,
                    ...outboundMetadata?.details,
                  },
                  prefixes: {
                    ...mMeta.prefixes,
                    ...outboundMetadata?.prefixes,
                  },
                  sources: {
                    ...mMeta.sources,
                    ...outboundMetadata?.sources,
                  },
                };
              }
              if (includeSubscriptionCopyState) {
                for (const [k, v] of getCachedProxyLinks(mCache)) {
                  if (!cachedProxyLinks.has(k)) {
                    cachedProxyLinks.set(k, v);
                  }
                }
              }
            }
          }

          const { selector, latencyTestCode, latencyTestCodes, outbounds } =
            buildProxyGroupOutbounds(
              section,
              proxies,
              outboundMetadata,
              urltestGroups,
              priorityGroups,
              cachedProxyLinks,
              hiddenOutboundTags,
              memberSections,
              effectiveSortMode,
            );

          const hideNa = shouldHideNaServers(section);
          const hasTestedServers = outbounds.some((o) => !isNaOutbound(o));
          const filteredOutbounds =
            hideNa && hasTestedServers
              ? outbounds.filter((o) => !isNaOutbound(o))
              : outbounds;

          return {
            withTagSelect: true,
            code: selector?.code || latencyTestCode || sectionName,
            sectionName,
            displayName,
            action: sectionAction,
            latencyTestCode,
            latencyTestCodes,
            proxyConfigType,
            subscriptionSourceCount,
            subscriptionMetadata,
            dashboardSettings: {
              countryGrouping: effectiveCountryGrouping,
              chipsGrouping: effectiveChipsGrouping,
              countryChipsLatencyMode: effectiveChipsLatencyMode,
              sortMode: effectiveSortMode,
              hoverFreeze: globalHoverFreeze,
            },
            outbounds: filteredOutbounds,
          };
        }

        if (SINGLE_ENDPOINT_ACTIONS.has(sectionAction || '')) {
          const outboundTag = getOutboundTagBySection(sectionName);
          const outbound = proxies.find((proxy) => proxy.code === outboundTag);
          const defaultLabel =
            ACTION_DISPLAY_NAMES[sectionAction || ''] ||
            (sectionAction || '').toUpperCase();
          const customName =
            outbound?.value?.name && outbound.value.name !== outboundTag
              ? outbound.value.name
              : '';

          return {
            withTagSelect: false,
            code: outbound?.code || sectionName,
            sectionName,
            displayName,
            action: sectionAction,
            outbounds: [
              {
                code: outbound?.code || sectionName,
                displayName:
                  section.label ||
                  section.name ||
                  section.interface ||
                  customName ||
                  defaultLabel,
                latency: outbound?.value?.history?.length
                  ? outbound.value.history[0].delay > 0
                    ? outbound.value.history[0].delay
                    : -1
                  : 0,
                type:
                  ACTION_DISPLAY_NAMES[sectionAction || ''] ||
                  outbound?.value?.type ||
                  (sectionAction || '').toUpperCase(),
                selected: true,
                canCopyLink: false,
                runtimeAvailable: Boolean(outbound),
              },
            ],
          };
        }

        if (sectionAction === 'outbound') {
          const outboundTag = getOutboundTagBySection(sectionName);
          const outbound = proxies.find((proxy) => proxy.code === outboundTag);

          return {
            withTagSelect: false,
            code: outbound?.code || sectionName,
            sectionName,
            displayName,
            action: sectionAction,
            outbounds: [
              {
                code: outbound?.code || sectionName,
                displayName:
                  getJsonOutboundDisplayName(section) ||
                  outbound?.value?.name ||
                  '',
                latency: outbound?.value?.history?.[0]?.delay || 0,
                type: outbound?.value?.type || '',
                selected: true,
                canCopyLink: false,
              },
            ],
          };
        }

        if (isServiceAction(sectionAction)) {
          const serviceType =
            sectionAction as Tachyon.ServiceStatus['serviceType'];
          const serviceStatus = await getServiceStatus(serviceType);

          const statusLabel = serviceStatus
            ? serviceStatus.ready
              ? _('Running')
              : serviceStatus.conflict
                ? _('Conflict')
                : serviceStatus.configured
                  ? _('Stopped')
                  : _('Not configured')
            : _('Unknown');

          return {
            withTagSelect: false,
            code: sectionName,
            sectionName,
            displayName,
            action: sectionAction,
            serviceStatus,
            outbounds: [
              {
                code: sectionName,
                displayName: statusLabel,
                latency: 0,
                type: serviceType.toUpperCase(),
                selected: true,
                canCopyLink: false,
              },
            ],
          };
        }

        return {
          withTagSelect: false,
          code: sectionName,
          sectionName,
          displayName,
          action: sectionAction,
          outbounds: [],
        };
      }),
  );

  return {
    success: true,
    data: data.map((group) =>
      sectionErrors[group.sectionName]
        ? { ...group, configError: sectionErrors[group.sectionName] }
        : group,
    ),
  };
}
