/* eslint-disable @typescript-eslint/no-explicit-any */
import { parseValueList } from '../helpers/parseValueList';
import { getProxyUrlTransport } from '../helpers/getProxyUrlTransport';
import { formatOutboundType } from '../helpers/formatOutboundType';
import { openConnectionWizardModal } from './connectionWizard';
import { tr } from './helpers/i18n';
import { getRouterUiPrefs, setRouterUiPrefs } from './helpers/uiPrefs';
import { ensureOutboundDisplayFlag } from './helpers/country';
import { renderFlagEmojis } from './tabs/dashboard/partials/renderFlagEmojis';
import {
  openServerInfoModalForSection,
  openServerSubscriptionModal,
} from './tabs/dashboard/inboundServers';
import { openSectionIconPickerModal } from './tabs/dashboard/partials/renderOverviewRow';
import {
  renderZapIcon,
  renderShieldIcon,
  renderFileTextIcon,
  renderTrashIcon,
  renderCopyIcon,
  renderSettingsIcon,
  renderTargetIcon,
  renderRadioIcon,
  renderScaleIcon,
  renderPinIcon,
  renderSubRouteIcon,
  renderClockIcon,
  renderBanIcon,
  renderGlobeIcon,
  renderWandIcon,
  renderRocketIcon,
  renderArrowUpRightIcon,
  renderCompassIcon,
  renderQrCodeIcon,
  renderPuzzleIcon,
  renderUsersIcon,
  renderTagIcon,
  renderLockIcon,
  renderCloudIcon,
  renderSparklesIcon,
  renderLayoutGridIcon,
  renderListIcon,
  renderPlaneIcon,
  renderPlayIcon,
  renderGamepad2Icon,
  renderLinkIcon,
  renderActivityIcon,
  renderAlertTriangleIcon,
  renderCommunityListServiceIcon,
  renderRefreshCwIcon,
  renderChevronDownIcon,
  renderChevronUpIcon,
} from '../icons';

const UCI_PACKAGE = 'tachyon';

export type StudioEntityType =
  | 'section'
  | 'outbound_source'
  | 'condition'
  | 'balancer'
  | 'server'
  | 'profile'
  | 'schedule';

export type StudioViewMode = 'cards' | 'pipeline';

export interface StudioDeckMountOptions {
  type: StudioEntityType;
  sectionRef: any;
  containerEl: HTMLElement;
  onShowSectionRules?: (sid: string) => void;
  onCloneSection?: (sid: string) => string | null;
  onNavigateSubTab?: (subTab: string, targetSid?: string) => void;
}

function asArray(val: unknown): string[] {
  return parseValueList(val);
}

function extractSourceLinks(raw: any): string[] {
  if (!raw || typeof raw !== 'object') return [];
  const items = [
    ...asArray(raw.proxy_links),
    ...asArray(raw.selector_proxy_links),
    ...String(raw.proxy_links_text || '')
      .split(/\r?\n/)
      .map((s) => s.trim())
      .filter(Boolean),
    ...String(raw.selector_proxy_links_text || '')
      .split(/\r?\n/)
      .map((s) => s.trim())
      .filter(Boolean),
  ];
  return Array.from(new Set(items));
}

const fptnDecodedCache = new Map<
  string,
  {
    serviceName?: string;
    username?: string;
    servers: { name: string; proto: string; trans: string; link?: string }[];
  }
>();

function parseFptnPayloadObject(
  data: any,
  tokenForLink = '',
): {
  serviceName?: string;
  username?: string;
  servers: { name: string; proto: string; trans: string; link?: string }[];
} {
  if (!data || typeof data !== 'object') return { servers: [] };
  const servers: {
    name: string;
    proto: string;
    trans: string;
    link?: string;
  }[] = [];
  const seen = new Set<string>();
  const addList = (list: unknown, isCensoredZone: boolean) => {
    if (!Array.isArray(list)) return;
    list.forEach((srv: any, idx: number) => {
      if (!srv || typeof srv !== 'object') return;
      const host = String(srv.host || '').trim();
      const port = Number(srv.port || 443);
      const rawSrvName = String(srv.name || host || `FPTN #${idx + 1}`).trim();
      const display = isCensoredZone ? `${rawSrvName} (DPI)` : rawSrvName;
      const key = `${display}|${host}|${port}`;
      if (seen.has(key)) return;
      seen.add(key);
      const transParts = [host ? `${host}:${port}` : `:${port}`];
      if (
        isCensoredZone ||
        Number(srv.is_using_censorship_zone_antidpi) === 1
      ) {
        transParts.push('AntiDPI');
      }
      servers.push({
        name: display,
        proto: 'FPTN',
        trans: transParts.join(' • '),
        link: tokenForLink
          ? `${tokenForLink}#${encodeURIComponent(display)}`
          : '',
      });
    });
  };
  addList(data.servers, false);
  addList(data.censored_zone_servers, true);
  return {
    serviceName: data.service_name
      ? String(data.service_name).trim()
      : undefined,
    username: data.username ? String(data.username).trim() : undefined,
    servers,
  };
}

function parseFptnTokenInfo(tokenRaw: unknown): {
  serviceName?: string;
  username?: string;
  servers: { name: string; proto: string; trans: string; link?: string }[];
  isCompressed?: boolean;
} {
  const fullToken = String(tokenRaw || '')
    .trim()
    .split('#')[0]
    .trim();
  if (!fullToken) return { servers: [] };
  const cached = fptnDecodedCache.get(fullToken);
  if (cached && cached.servers.length > 0) {
    return cached;
  }
  let clean = fullToken;
  if (/^fptn:\/\//i.test(clean)) {
    clean = clean.slice(7);
  } else if (/^fptn:/i.test(clean)) {
    clean = clean.slice(5);
  } else if (/^fptnb:\/\//i.test(clean)) {
    return { servers: [], isCompressed: true };
  } else if (/^fptnb:/i.test(clean)) {
    return { servers: [], isCompressed: true };
  }
  clean = clean.replace(/\s+/g, '').replace(/-/g, '+').replace(/_/g, '/');
  while (clean.length % 4 !== 0) {
    clean += '=';
  }
  try {
    const bin = typeof atob === 'function' ? atob(clean) : '';
    if (!bin) return { servers: [] };
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i += 1) {
      bytes[i] = bin.charCodeAt(i);
    }
    const jsonStr =
      typeof TextDecoder !== 'undefined'
        ? new TextDecoder('utf-8').decode(bytes)
        : bin;
    const data = JSON.parse(jsonStr);
    const parsed = parseFptnPayloadObject(data, fullToken);
    if (parsed.servers.length > 0) {
      fptnDecodedCache.set(fullToken, parsed);
    }
    return parsed;
  } catch {
    return { servers: [] };
  }
}

function stripPrefix(tok: string): string {
  return String(tok || '').replace(/^[+!-]/, '');
}

function getStudioViewMode(type: StudioEntityType): StudioViewMode {
  try {
    if (typeof localStorage !== 'undefined') {
      const saved = localStorage.getItem(`tachyon_studio_view_${type}_v1`);
      if (saved === 'cards' || saved === 'pipeline') return saved;
    }
  } catch {
    // ignore
  }
  try {
    const fromRouter = getRouterUiPrefs()?.studio_views?.[type];
    if (fromRouter === 'cards' || fromRouter === 'pipeline') {
      try {
        if (typeof localStorage !== 'undefined') {
          localStorage.setItem(`tachyon_studio_view_${type}_v1`, fromRouter);
        }
      } catch {
        // ignore
      }
      return fromRouter;
    }
  } catch {
    // ignore
  }
  return type === 'section' ? 'pipeline' : 'cards';
}

function setStudioViewMode(type: StudioEntityType, mode: StudioViewMode): void {
  try {
    if (typeof localStorage !== 'undefined') {
      localStorage.setItem(`tachyon_studio_view_${type}_v1`, mode);
    }
  } catch {
    // ignore
  }
  setRouterUiPrefs({ studio_views: { [type]: mode } });
}

function sanitizeStaleUciDeletes(targetSectionId?: string): void {
  try {
    const state = (typeof uci !== 'undefined' && (uci as any).state) || null;
    if (!state || !state.deletes?.[UCI_PACKAGE]) return;
    const creates = state.creates?.[UCI_PACKAGE] || {};
    const values = state.values?.[UCI_PACKAGE] || {};
    const deletes = state.deletes[UCI_PACKAGE];
    for (const sid in deletes) {
      if (creates[sid] || !values[sid]) {
        delete deletes[sid];
        continue;
      }
      if (deletes[sid] !== true && typeof deletes[sid] === 'object') {
        for (const opt in deletes[sid]) {
          if (!Object.prototype.hasOwnProperty.call(values[sid], opt)) {
            delete deletes[sid][opt];
          }
        }
        if (Object.keys(deletes[sid]).length === 0) {
          delete deletes[sid];
        }
      }
    }
    if (
      targetSectionId &&
      (creates[targetSectionId] || !values[targetSectionId])
    ) {
      delete deletes[targetSectionId];
    }
    if (Object.keys(state.deletes[UCI_PACKAGE]).length === 0) {
      delete state.deletes[UCI_PACKAGE];
    }
  } catch {
    // ignore
  }
}

let pendingUciSaveChain: Promise<unknown> = Promise.resolve(null);

function notifyUciChanged(): Promise<unknown> {
  const runSave = () => {
    try {
      sanitizeStaleUciDeletes();
      if (typeof uci !== 'undefined' && typeof uci.save === 'function') {
        return Promise.resolve(uci.save())
          .then(() => {
            if (
              typeof ui !== 'undefined' &&
              (ui as any).changes &&
              typeof (ui as any).changes.init === 'function'
            ) {
              return (ui as any).changes.init();
            }
            return null;
          })
          .catch(() => null);
      }
    } catch {
      // ignore
    }
    return Promise.resolve(null);
  };
  pendingUciSaveChain = pendingUciSaveChain.then(runSave, runSave);
  return pendingUciSaveChain;
}

function sanitizeUciId(raw: string, fallbackPrefix: string): string {
  const translitMap: Record<string, string> = {
    а: 'a',
    б: 'b',
    в: 'v',
    г: 'g',
    д: 'd',
    е: 'e',
    ё: 'e',
    ж: 'zh',
    з: 'z',
    и: 'i',
    й: 'y',
    к: 'k',
    л: 'l',
    м: 'm',
    н: 'n',
    о: 'o',
    п: 'p',
    р: 'r',
    с: 's',
    т: 't',
    у: 'u',
    ф: 'f',
    х: 'h',
    ц: 'ts',
    ч: 'ch',
    ш: 'sh',
    щ: 'sch',
    ъ: '',
    ы: 'y',
    ь: '',
    э: 'e',
    ю: 'yu',
    я: 'ya',
  };
  const lower = String(raw || '')
    .trim()
    .toLowerCase();
  let out = '';
  for (const ch of lower) {
    if (translitMap[ch] !== undefined) {
      out += translitMap[ch];
    } else if (/[a-z0-9_]/.test(ch)) {
      out += ch;
    } else if (/[\s.-]/.test(ch)) {
      out += '_';
    }
  }
  out = out.replace(/_+/g, '_').replace(/^_+|_+$/g, '');
  if (!out || !/^[a-zA-Z_]/.test(out)) {
    out = `${fallbackPrefix}_${out || Math.floor(Date.now() / 1000) % 100000}`;
  }
  return out.slice(0, 32);
}

function extractLinkProtocolsAndTransports(links: string[]): {
  protocols: string[];
  transports: string[];
} {
  const protoSet = new Set<string>();
  const transSet = new Set<string>();
  const sample = links.length > 100 ? links.slice(0, 100) : links;
  sample.forEach((link) => {
    const schemeMatch = String(link || '')
      .trim()
      .match(/^([a-zA-Z0-9+.-]+):\/\//);
    if (schemeMatch && schemeMatch[1]) {
      const p = formatOutboundType(schemeMatch[1].toLowerCase());
      if (p) protoSet.add(p.toUpperCase());
    }
    const t = getProxyUrlTransport(link);
    if (t) {
      transSet.add(t.toUpperCase());
    }
  });
  return {
    protocols: Array.from(protoSet),
    transports: Array.from(transSet),
  };
}

function resolveSectionTelemetry(sid: string): {
  name: string;
  enabled: boolean;
  action: string;
  actionLabel: string;
  actionTone: 'proxy' | 'dpi' | 'block' | 'bypass' | 'dns';
  iconText: string;
  iconBg: string;
  iconColor: string;
  faviconDomain: string;
  protocols: string[];
  transports: string[];
  sources: { id: string; name: string; type: string }[];
  conditions: { id: string; name: string; count: number }[];
  balancers: { id: string; name: string; type: string }[];
  serviceTags: string[];
} {
  const raw = (typeof uci !== 'undefined' && uci.get(UCI_PACKAGE, sid)) || {};
  const name = raw.label || raw.name || sid;
  const enabled = raw.enabled !== '0';
  const actionRaw = String(raw.action || 'connection').toLowerCase();

  const srcRefs = asArray(raw.outbound_source_refs);
  const sources = srcRefs.map((srcId) => {
    const sObj =
      (typeof uci !== 'undefined' && uci.get(UCI_PACKAGE, srcId)) || {};
    return {
      id: srcId,
      name: sObj.name || sObj.label || srcId,
      type: String(sObj.source_type || 'subscription').toLowerCase(),
    };
  });

  const condRefs = asArray(raw.condition_refs).map(stripPrefix);
  const serviceTags: string[] = [];
  const conditions = condRefs.map((cid) => {
    const cObj =
      (typeof uci !== 'undefined' && uci.get(UCI_PACKAGE, cid)) || {};
    const comm = asArray(cObj.community_lists);
    comm.forEach((tag) => {
      if (!serviceTags.includes(tag)) serviceTags.push(tag);
    });
    const doms = [
      ...asArray(cObj.domain),
      ...asArray(cObj.domain_suffix),
      ...asArray(cObj.ip_cidr),
    ];
    return {
      id: cid,
      name: cObj.name || cObj.label || cid,
      count: comm.length + doms.length,
    };
  });
  if (condRefs.length === 0) {
    asArray(raw.community_lists).forEach((tag) => {
      if (!serviceTags.includes(tag)) serviceTags.push(tag);
    });
  }

  const balRefs = asArray(raw.balancer_refs);
  const balancers = balRefs.map((bid) => {
    const bObj =
      (typeof uci !== 'undefined' && uci.get(UCI_PACKAGE, bid)) || {};
    const btype = String(bObj.balancer_type || 'urltest').toLowerCase();
    const bmode = String(bObj.mode || 'least_test').toLowerCase();
    const tag =
      btype === 'priority'
        ? 'PRIORITY'
        : bmode && bmode !== 'least_test'
          ? bmode.toUpperCase()
          : 'URLTEST';
    return {
      id: bid,
      name: bObj.name || bObj.label || bid,
      type: tag,
    };
  });

  const hasDpiSource =
    ['desync', 'zapret', 'zapret2', 'byedpi'].includes(actionRaw) ||
    sources.some((s) =>
      ['desync', 'zapret', 'zapret2', 'byedpi', 'wdtt', 'olcrtc'].includes(
        s.type,
      ),
    );

  let actionLabel = tr('Прокси / Туннель', 'Proxy / Tunnel');
  let actionTone: 'proxy' | 'dpi' | 'block' | 'bypass' | 'dns' = 'proxy';
  if (actionRaw === 'block') {
    actionLabel = tr('Блокировка (Block)', 'Block');
    actionTone = 'block';
  } else if (actionRaw === 'bypass' || actionRaw === 'direct') {
    actionLabel = tr('Напрямую (Bypass)', 'Bypass (Direct)');
    actionTone = 'bypass';
  } else if (actionRaw === 'dns') {
    actionLabel = 'DNS';
    actionTone = 'dns';
  } else if (hasDpiSource) {
    actionLabel = tr('Обход DPI (Desync)', 'DPI Desync');
    actionTone = 'dpi';
  } else {
    actionLabel = tr('Туннель / Прокси', 'Connection');
    actionTone = 'proxy';
  }

  const protoSet = new Set<string>();
  const transSet = new Set<string>();

  sources.forEach((s) => {
    const sObj =
      (typeof uci !== 'undefined' && uci.get(UCI_PACKAGE, s.id)) || {};
    if (s.type === 'subscription') {
      protoSet.add(tr('Подписка', 'Subscription'));
    } else if (s.type === 'proxy_links') {
      const links = extractSourceLinks(sObj);
      const parsed = extractLinkProtocolsAndTransports(links);
      if (parsed.protocols.length) {
        parsed.protocols.forEach((p) => protoSet.add(p));
      } else {
        protoSet.add('VLESS');
      }
      parsed.transports.forEach((t) => transSet.add(t));
    } else if (s.type === 'fptn') {
      protoSet.add('FPTN');
    } else if (s.type === 'warp') {
      protoSet.add('WARP');
    } else if (s.type === 'awg' || s.type === 'amnezia_config') {
      protoSet.add('AmneziaWG');
    } else if (
      ['desync', 'zapret2', 'zapret', 'byedpi', 'wdtt', 'olcrtc'].includes(
        s.type,
      )
    ) {
      protoSet.add(s.type.toUpperCase());
    } else if (s.type) {
      protoSet.add(s.type.toUpperCase());
    }
  });

  // Inspect store active section outbounds for live VLESS / GRPC / XHTTP transport badges
  try {
    const storeMod = (globalThis as any).tachyonStore || null;
    const secData =
      storeMod && typeof storeMod.get === 'function'
        ? storeMod.get()?.connectionsWidget?.data?.sections?.[sid]
        : null;
    if (secData && Array.isArray(secData.outbounds)) {
      secData.outbounds.forEach((ob: any) => {
        const p = formatOutboundType(ob?.type || ob?.protocol || '');
        if (
          p &&
          !['Direct', 'Block', 'DNS', 'URLTest', 'Selector'].includes(p)
        ) {
          protoSet.add(p.toUpperCase());
        }
        const trRaw = String(
          ob?.transport?.type ||
            ob?.transport ||
            ob?.network ||
            getProxyUrlTransport(ob?.link || ob?.url || '') ||
            '',
        )
          .trim()
          .toUpperCase();
        if (
          trRaw &&
          ['GRPC', 'XHTTP', 'WS', 'HTTPUPGRADE', 'QUIC', 'H2', 'TCP'].includes(
            trRaw,
          )
        ) {
          transSet.add(trRaw);
        }
      });
    }
  } catch {
    // ignore
  }

  const keyLower = `${sid} ${name}`.toLowerCase();
  const iconText = '';
  const iconBg = 'rgba(255, 255, 255, 0.04)';
  const iconColor = 'var(--text-color-high, #e2e8f0)';
  let customIconDomain = '';
  try {
    if (typeof localStorage !== 'undefined' && sid) {
      customIconDomain = localStorage.getItem(`tachyon_sec_icon_${sid}`) || '';
    }
  } catch {
    // ignore
  }
  if (!customIconDomain) {
    customIconDomain = String(raw.icon_domain || '').trim();
  }
  const forceDefaultSvg =
    customIconDomain.toLowerCase() === 'svg' ||
    customIconDomain.toLowerCase() === 'none';
  let faviconDomain = forceDefaultSvg ? '' : customIconDomain;

  if (keyLower.includes('youtube') || keyLower.includes('yt')) {
    if (!faviconDomain && !forceDefaultSvg) faviconDomain = 'youtube.com';
  } else if (keyLower.includes('discord')) {
    if (!faviconDomain && !forceDefaultSvg) faviconDomain = 'discord.com';
  } else if (keyLower.includes('tele') || keyLower.includes('tg')) {
    if (!faviconDomain && !forceDefaultSvg) faviconDomain = 'telegram.org';
  }

  return {
    name,
    enabled,
    action: actionRaw,
    actionLabel,
    actionTone,
    iconText,
    iconBg,
    iconColor,
    faviconDomain,
    protocols: Array.from(protoSet).slice(0, 4),
    transports: Array.from(transSet).slice(0, 4),
    sources,
    conditions,
    balancers,
    serviceTags: serviceTags.slice(0, 8),
  };
}

function syncHiddenGridEnabledCheckbox(
  sid: string,
  enabled: boolean,
  sectionRef: any,
): void {
  try {
    const fieldId = `cbid.${UCI_PACKAGE}.${sid}.enabled`;
    const candidates = [
      document.getElementById(`widget.${fieldId}`),
      document.getElementById(fieldId),
      document.querySelector(
        `#cbi-${UCI_PACKAGE}-${sid} [data-field="${fieldId}"] input[type="checkbox"]`,
      ),
      document.querySelector(
        `#cbi-${UCI_PACKAGE}-${sid} input[type="checkbox"]`,
      ),
      document.querySelector(
        `#cbi-${UCI_PACKAGE}-${sectionRef?.sectiontype || ''} tr[data-sid="${sid}"] input[type="checkbox"]`,
      ),
    ];
    candidates.forEach((node) => {
      const cb = node as HTMLInputElement | null;
      if (cb && cb.type === 'checkbox' && cb.checked !== enabled) {
        cb.checked = enabled;
        cb.dispatchEvent(new Event('change', { bubbles: true }));
      }
    });
  } catch {
    // ignore
  }
}

function createStudioToggleSwitch(
  sid: string,
  enabled: boolean,
  sectionRef: any,
  onChanged: () => void,
): HTMLElement {
  const btn = E(
    'button',
    {
      type: 'button',
      class: `tachyon-studio-switch ${enabled ? 'is-on' : 'is-off'}`,
      role: 'switch',
      'aria-checked': enabled ? 'true' : 'false',
      title: enabled
        ? tr('Включено (нажмите для отключения)', 'Enabled (click to disable)')
        : tr('Выключено (нажмите для включения)', 'Disabled (click to enable)'),
      click: (ev: MouseEvent) => {
        ev.preventDefault();
        ev.stopPropagation();
        const cur = uci.get(UCI_PACKAGE, sid, 'enabled') !== '0';
        const next = !cur;
        uci.set(UCI_PACKAGE, sid, 'enabled', next ? '1' : '0');
        syncHiddenGridEnabledCheckbox(sid, next, sectionRef);
        notifyUciChanged();
        onChanged();
      },
    },
    [E('span', { class: 'tachyon-studio-switch__thumb' })],
  );
  return btn;
}

function moveUciSectionOrder(
  sectionType: string,
  sid: string,
  direction: -1 | 1,
  onDone: () => void,
): void {
  const all = (uci.sections(UCI_PACKAGE, sectionType) || [])
    .map((s: any) => s['.name'])
    .filter(Boolean);
  const idx = all.indexOf(sid);
  if (idx < 0) return;
  const targetIdx = idx + direction;
  if (targetIdx < 0 || targetIdx >= all.length) return;
  const targetSid = all[targetIdx];
  try {
    if (typeof (uci as any).move === 'function') {
      (uci as any).move(UCI_PACKAGE, sid, targetSid);
      notifyUciChanged();
      onDone();
    }
  } catch {
    // ignore
  }
}

interface QuickCreateTemplate {
  id: string;
  icon: string | (() => SVGElement);
  title: string;
  desc: string;
  defaults: Record<string, any>;
}

function getBalancerEngineCapabilities(): {
  isTachyonCore: boolean;
  supportsNativeTachyonBalancers: boolean;
  supportsPoolModes: boolean;
} {
  let activeEngine = 'sing-box';
  try {
    const uciEngine = String(
      uci.get(UCI_PACKAGE, 'settings', 'engine') || '',
    ).trim();
    if (uciEngine) {
      activeEngine = uciEngine;
    }
  } catch {
    // ignore
  }

  let sysInfo: Record<string, any> = {};
  try {
    const storeMod = (globalThis as any).tachyonStore || null;
    sysInfo =
      (storeMod && typeof storeMod.get === 'function'
        ? storeMod.get()?.systemInfoWidget?.data
        : null) || {};
  } catch {
    // ignore
  }

  const isTachyonCore =
    activeEngine === 'tachyon-core' ||
    Boolean(sysInfo.tachyon_core_installed && activeEngine === 'tachyon-core');
  const tcVersion = String(sysInfo.tachyon_core_version || '').trim();
  const parseSemverAtLeast = (
    ver: string,
    minMaj: number,
    minMin: number,
    minPatch: number,
  ): boolean => {
    const m = ver.match(/(\d+)\.(\d+)\.(\d+)/);
    if (!m) return true;
    const maj = Number(m[1] || 0);
    const min = Number(m[2] || 0);
    const pat = Number(m[3] || 0);
    if (maj !== minMaj) return maj > minMaj;
    if (min !== minMin) return min > minMin;
    return pat >= minPatch;
  };
  const supportsNativeTachyonBalancers =
    isTachyonCore &&
    (Boolean(sysInfo.tachyon_core_native_balancers) ||
      parseSemverAtLeast(tcVersion, 0, 3, 9));
  const isExtendedOrLx = Boolean(
    sysInfo.sing_box_extended || sysInfo.sing_box_lx,
  );
  return {
    isTachyonCore,
    supportsNativeTachyonBalancers,
    supportsPoolModes: supportsNativeTachyonBalancers || isExtendedOrLx,
  };
}

function formatBalancerModeBadge(btype: string, modeRaw?: string): string {
  if (btype === 'priority') {
    return tr('PRIORITY • КАСКАД', 'PRIORITY • CASCADE');
  }
  const m = String(modeRaw || 'least_test')
    .trim()
    .toLowerCase();
  switch (m) {
    case 'stability':
      return tr('STABILITY • БЕЗ ДЖИТТЕРА', 'STABILITY • EWMA + JITTER');
    case 'sticky':
      return tr('STICKY • ПРИВЯЗКА СЕССИЙ', 'STICKY • HRW AFFINITY');
    case 'least_load':
      return tr('LEAST LOAD • ПО НАГРУЗКЕ', 'LEAST LOAD • ACTIVE × RTT');
    case 'weighted':
      return tr('WEIGHTED • ВЗВЕШЕННЫЙ 1/RTT²', 'WEIGHTED • SMOOTH WRR');
    case 'passive':
      return tr('PASSIVE • АВТОКАРАНТИН', 'PASSIVE • CIRCUIT BREAKER');
    case 'hedged':
      return tr('HEDGED • ПАРАЛЛЕЛЬНЫЙ РЕЗЕРВ', 'HEDGED • HAPPY EYEBALLS');
    case 'throughput':
      return tr('THROUGHPUT • ПО СКОРОСТИ', 'THROUGHPUT • PEAK BANDWIDTH');
    case 'quota':
      return tr('QUOTA • ПО КВОТЕ ТРАФИКА', 'QUOTA • TRAFFIC CAP');
    case 'round_robin':
      return tr('ROUND-ROBIN • ПО КРУГУ', 'ROUND-ROBIN • POOL');
    case 'random':
      return tr('RANDOM • СЛУЧАЙНЫЙ ПУЛ', 'RANDOM • POOL');
    case 'failover':
      return tr('FAILOVER • ДО ОТКАЗА', 'FAILOVER • PIN UNTIL DOWN');
    default:
      return tr('URLTEST • АВТОВЫБОР', 'URLTEST • FASTEST PING');
  }
}

function getQuickCreateTemplates(
  type: StudioEntityType,
): QuickCreateTemplate[] {
  if (type === 'section') {
    return [
      {
        id: 'proxy',
        icon: () => renderZapIcon(20),
        title: tr('Прокси / VPN секция', 'Proxy / VPN Section'),
        desc: tr(
          'Маршрутизация выбранных сервисов или доменов через подписки, VLESS, AWG или балансировщики',
          'Route selected services or domains through subscriptions, VLESS, AWG, or balancers',
        ),
        defaults: { enabled: '1', action: 'connection' },
      },
      {
        id: 'dpi',
        icon: () => renderShieldIcon(20),
        title: tr(
          'Обход DPI (Desync / Zapret2)',
          'DPI Bypass (Desync / Zapret2)',
        ),
        desc: tr(
          'Обход замедления YouTube, Discord и Telegram без внешнего прокси-сервера',
          'Bypass DPI throttling for YouTube, Discord, or Telegram without a proxy server',
        ),
        defaults: { enabled: '1', action: 'connection' },
      },
      {
        id: 'bypass',
        icon: () => renderArrowUpRightIcon(20),
        title: tr('Прямой маршрут (Bypass)', 'Direct Route (Bypass)'),
        desc: tr(
          'Отправка российских сайтов, банков или подсетей напрямую в обход всех туннелей',
          'Send domestic sites, banks, or LAN subnets directly bypassing all tunnels',
        ),
        defaults: { enabled: '1', action: 'bypass' },
      },
      {
        id: 'block',
        icon: () => renderBanIcon(20),
        title: tr(
          'Блокировка рекламы (Block)',
          'Ad & Telemetry Blocker (Block)',
        ),
        desc: tr(
          'Блокировка рекламы, трекеров и нежелательных доменов на уровне роутера',
          'Block ads, trackers, or unwanted domains at the router level',
        ),
        defaults: { enabled: '1', action: 'block' },
      },
      {
        id: 'dns',
        icon: () => renderCompassIcon(20),
        title: tr('Специальный DNS-маршрут', 'Custom DNS Route'),
        desc: tr(
          'Разрешение выбранных доменов через выделенный DoH / DoT / UDP DNS-сервер или DNS провайдера с WAN-порта',
          'Resolve specific domains via a dedicated DoH / DoT / UDP DNS server or ISP WAN DNS',
        ),
        defaults: { enabled: '1', action: 'dns', disable_fakeip: '1' },
      },
    ];
  }
  if (type === 'outbound_source') {
    return [
      {
        id: 'subscription',
        icon: () => renderRadioIcon(20),
        title: tr('Подписка по URL', 'Subscription URL'),
        desc: tr(
          'Автообновляемая HTTP/HTTPS подписка (VLESS, Hysteria2, Trojan, SS)',
          'Auto-updated HTTP/HTTPS subscription link (VLESS, Hysteria2, Trojan, SS)',
        ),
        defaults: { enabled: '1', source_type: 'subscription' },
      },
      {
        id: 'proxy_links',
        icon: () => renderLinkIcon(20),
        title: tr('Прокси-ссылки (Share Links)', 'Proxy Share Links'),
        desc: tr(
          'Одна или несколько ссылок vless://, hysteria2://, tuic://, trojan://, ss://',
          'One or multiple vless://, hysteria2://, tuic://, trojan://, ss:// links',
        ),
        defaults: { enabled: '1', source_type: 'proxy_links' },
      },
      {
        id: 'desync',
        icon: () => renderShieldIcon(20),
        title: tr(
          'Стратегия DPI Desync / Zapret2',
          'DPI Desync / Zapret2 Strategy',
        ),
        desc: tr(
          'Фрагментация пакетов и подмена ClientHello для YouTube, Discord и Telegram',
          'Packet fragmentation and fake ClientHello for YouTube, Discord & Telegram',
        ),
        defaults: {
          enabled: '1',
          source_type: 'desync',
          desync_preset: 'auto',
        },
      },
      {
        id: 'awg',
        icon: () => renderLockIcon(20),
        title: tr('AmneziaWG / WireGuard', 'AmneziaWG / WireGuard'),
        desc: tr(
          'Защищённый от DPI туннель AmneziaWG 1.5/2.0 или WireGuard (.conf / vpn://)',
          'Censorship-resistant AmneziaWG 1.5/2.0 or WireGuard tunnel (.conf / vpn://)',
        ),
        defaults: { enabled: '1', source_type: 'amnezia_config' },
      },
      {
        id: 'warp',
        icon: () => renderCloudIcon(20),
        title: 'Cloudflare WARP',
        desc: tr(
          'Встроенный туннель Cloudflare WARP с обфускацией заголовков Amnezia',
          'Built-in Cloudflare WARP tunnel with Amnezia obfuscation',
        ),
        defaults: { enabled: '1', source_type: 'warp' },
      },
      {
        id: 'fptn',
        icon: () => renderRocketIcon(20),
        title: 'FPTN VPN',
        desc: tr(
          'Антицензурный VPN FPTN по токену доступа fptn://',
          'FPTN anti-censorship VPN via fptn:// access token',
        ),
        defaults: { enabled: '1', source_type: 'fptn' },
      },
    ];
  }
  if (type === 'condition') {
    return [
      {
        id: 'services',
        icon: () => renderTargetIcon(20),
        title: tr('Списки сервисов и платформ', 'Service & Geo Lists'),
        desc: tr(
          'Готовые списки сервисов (YouTube, Discord, Telegram, ИИ, Meta, реклама)',
          'Match curated service lists (YouTube, Discord, Telegram, AI, Meta, Ads)',
        ),
        defaults: { enabled: '1', condition_type: 'atomic' },
      },
      {
        id: 'domains_ips',
        icon: () => renderGlobeIcon(20),
        title: tr(
          'Свои домены, подсети и устройства',
          'Custom Domains, Subnets & Devices',
        ),
        desc: tr(
          'Домены, ключевые слова, CIDR-подсети или IP/MAC домашних устройств',
          'Match custom domain suffixes, keywords, CIDR subnets, or LAN client IPs/MACs',
        ),
        defaults: { enabled: '1', condition_type: 'atomic' },
      },
      {
        id: 'composite',
        icon: () => renderPuzzleIcon(20),
        title: tr(
          'Составное логическое правило (AND / OR / NOT)',
          'Composite Boolean Rule (AND / OR / NOT)',
        ),
        desc: tr(
          'Объединение нескольких условий с помощью булевой логики',
          'Combine multiple atomic conditions with boolean logic expressions',
        ),
        defaults: {
          enabled: '1',
          condition_type: 'composite',
          operator: 'and',
        },
      },
    ];
  }
  if (type === 'balancer') {
    const caps = getBalancerEngineCapabilities();
    const templates: QuickCreateTemplate[] = [
      {
        id: 'urltest',
        icon: () => renderZapIcon(20),
        title: tr(
          'URLTest (Автовыбор самого быстрого)',
          'URLTest (Fastest Ping Auto-Select)',
        ),
        desc: tr(
          'Регулярное измерение пинга и автоматическое переключение на самый быстрый сервер',
          'Continuously probe servers and route traffic through the lowest-latency alive node',
        ),
        defaults: {
          enabled: '1',
          balancer_type: 'urltest',
          mode: 'least_test',
          check_interval: '3m',
          tolerance: '50',
          testing_url: 'https://www.gstatic.com/generate_204',
        },
      },
    ];

    if (caps.supportsNativeTachyonBalancers) {
      templates.push(
        {
          id: 'stability',
          icon: () => renderActivityIcon(20),
          title: tr(
            'Stability (Стабильный без джиттера и потерь)',
            'Stability (EWMA + Jitter + Loss Filter)',
          ),
          desc: tr(
            'Оценка стабильности по сглаженному пингу EWMA, джиттеру RFC 3550 и штрафам за потери пакетов',
            'Composite score combining EWMA RTT, RFC 3550 jitter, and packet loss penalty',
          ),
          defaults: {
            enabled: '1',
            balancer_type: 'urltest',
            mode: 'stability',
            check_interval: '2m',
            tolerance: '50',
            testing_url: 'https://www.gstatic.com/generate_204',
          },
        },
        {
          id: 'sticky',
          icon: () => renderPinIcon(20),
          title: tr(
            'Sticky Flow (Привязка сессий HRW)',
            'Sticky Flow (Rendezvous HRW Affinity)',
          ),
          desc: tr(
            'Консистентное хэширование Rendezvous HRW: сохраняет один выходной IP для клиента и домена (банки, ИИ, игры)',
            'Rendezvous HRW hashing keeps each client + eTLD+1 domain pinned to the same healthy exit IP',
          ),
          defaults: {
            enabled: '1',
            balancer_type: 'urltest',
            mode: 'sticky',
            sticky_hash: ['source_ip', 'domain'],
            balancer_pool: '4',
            check_interval: '3m',
            tolerance: '80',
            testing_url: 'https://www.gstatic.com/generate_204',
          },
        },
        {
          id: 'least_load',
          icon: () => renderScaleIcon(20),
          title: tr(
            'Least Load (Наименьшая нагрузка × RTT)',
            'Least Load (Active Streams × RTT)',
          ),
          desc: tr(
            'Распределение новых потоков на сервер с минимальным произведением активных соединений и задержки',
            'Routes new connections to the node with the lowest (active_connections + 1) × RTT score',
          ),
          defaults: {
            enabled: '1',
            balancer_type: 'urltest',
            mode: 'least_load',
            balancer_pool: '4',
            check_interval: '3m',
            tolerance: '80',
            testing_url: 'https://www.gstatic.com/generate_204',
          },
        },
        {
          id: 'weighted',
          icon: () => renderScaleIcon(20),
          title: tr(
            'Weighted (Взвешенный Smooth WRR по 1/RTT²)',
            'Weighted (Smooth WRR by 1/RTT²)',
          ),
          desc: tr(
            'Детерминированное распределение трафика между топ-узлами пропорционально квадрату скорости отклика',
            'Smooth weighted round-robin across top healthy nodes proportional to 1/RTT²',
          ),
          defaults: {
            enabled: '1',
            balancer_type: 'urltest',
            mode: 'weighted',
            balancer_pool: '4',
            check_interval: '3m',
            tolerance: '80',
            testing_url: 'https://www.gstatic.com/generate_204',
          },
        },
        {
          id: 'passive',
          icon: () => renderShieldIcon(20),
          title: tr(
            'Passive Circuit Breaker (Автокарантин обрывов)',
            'Passive Circuit Breaker (Early-Abort Quarantine)',
          ),
          desc: tr(
            'Мгновенный карантин серверов при ранних обрывах соединений (< 64 КБ за < 3 с) без ожидания проверки пинга',
            'Automatically quarantines nodes that drop live connections early (< 64 KiB in < 3 s)',
          ),
          defaults: {
            enabled: '1',
            balancer_type: 'urltest',
            mode: 'passive',
            check_interval: '3m',
            tolerance: '50',
            testing_url: 'https://www.gstatic.com/generate_204',
          },
        },
        {
          id: 'hedged',
          icon: () => renderRocketIcon(20),
          title: tr(
            'Hedged (Параллельный резерв Happy Eyeballs)',
            'Hedged (Happy Eyeballs Parallel Backup)',
          ),
          desc: tr(
            'При задержке установки соединения запускает параллельное подключение ко второму серверу и выбирает первый ответивший',
            'Fires a parallel backup dial if primary handshake stalls and uses whichever connects first',
          ),
          defaults: {
            enabled: '1',
            balancer_type: 'urltest',
            mode: 'hedged',
            balancer_pool: '3',
            check_interval: '3m',
            tolerance: '60',
            testing_url: 'https://www.gstatic.com/generate_204',
          },
        },
        {
          id: 'throughput',
          icon: () => renderRocketIcon(20),
          title: tr(
            'Throughput (По пропускной способности)',
            'Throughput (Peak Bandwidth Selection)',
          ),
          desc: tr(
            'Выбор сервера с максимальной реальной скоростью передачи данных на основе пассивных замеров трафика',
            'Prefers nodes with the highest measured peak throughput with exponential decay',
          ),
          defaults: {
            enabled: '1',
            balancer_type: 'urltest',
            mode: 'throughput',
            balancer_pool: '4',
            check_interval: '3m',
            tolerance: '80',
            testing_url: 'https://www.gstatic.com/generate_204',
          },
        },
        {
          id: 'quota',
          icon: () => renderCloudIcon(20),
          title: tr(
            'Quota (Балансировка по квоте трафика)',
            'Quota (Traffic Cap Balancer)',
          ),
          desc: tr(
            'Автоматический перевод новых соединений на другие узлы пула после исчерпания заданного лимита трафика в МиБ',
            'Shifts new streams to remaining under-quota nodes once a node reaches its MiB cap',
          ),
          defaults: {
            enabled: '1',
            balancer_type: 'urltest',
            mode: 'quota',
            quota_mib: '10240',
            balancer_pool: '4',
            check_interval: '3m',
            tolerance: '80',
            testing_url: 'https://www.gstatic.com/generate_204',
          },
        },
      );
    }

    if (caps.supportsPoolModes) {
      templates.push(
        {
          id: 'round_robin',
          icon: () => renderRefreshCwIcon(20),
          title: tr(
            'Round-Robin (Циклический перебор пула)',
            'Round-Robin Pool',
          ),
          desc: tr(
            'Поочерёдное распределение соединений по кругу среди живых серверов пула в пределах допуска пинга',
            'Cycles new connections evenly across healthy nodes in the active latency pool',
          ),
          defaults: {
            enabled: '1',
            balancer_type: 'urltest',
            mode: 'round_robin',
            balancer_pool: '4',
            check_interval: '3m',
            tolerance: '80',
            testing_url: 'https://www.gstatic.com/generate_204',
          },
        },
        {
          id: 'failover',
          icon: () => renderLockIcon(20),
          title: tr(
            'Failover (Удержание узла до отказа)',
            'Failover (Pin Current Until Failure)',
          ),
          desc: tr(
            'Удерживает текущий рабочий сервер без переключений при колебаниях пинга и меняет его только при полном отказе',
            'Stays pinned to the current working server regardless of RTT fluctuations until it fails',
          ),
          defaults: {
            enabled: '1',
            balancer_type: 'urltest',
            mode: 'failover',
            check_interval: '1m',
            tolerance: '100',
            testing_url: 'https://www.gstatic.com/generate_204',
          },
        },
      );
    }

    templates.push({
      id: 'priority',
      icon: () => renderShieldIcon(20),
      title: tr(
        'Priority (Каскадный резерв по уровням)',
        'Priority Cascade (Tiered Failover)',
      ),
      desc: tr(
        'Использование основного уровня серверов с автоматическим переходом на резервный при сбое',
        'Use primary server tier first and automatically fail over to backup tiers on outage',
      ),
      defaults: {
        enabled: '1',
        balancer_type: 'priority',
        check_interval: '30s',
        pick_fastest: '1',
      },
    });

    return templates;
  }
  if (type === 'server') {
    return [
      {
        id: 'vless_reality',
        icon: () => renderZapIcon(20),
        title: 'VLESS + REALITY (TCP / XHTTP / gRPC)',
        desc: tr(
          'Невидимый для DPI сервер VLESS TLS 1.3 REALITY без необходимости покупать домен',
          'Stealth TLS 1.3 REALITY inbound server without owning a domain name',
        ),
        defaults: {
          enabled: '1',
          protocol: 'vless',
          security: 'reality',
          transport: 'tcp',
          listen_port: '443',
        },
      },
      {
        id: 'hysteria2',
        icon: () => renderRocketIcon(20),
        title: 'Hysteria2 (QUIC / UDP)',
        desc: tr(
          'Скоростной QUIC-сервер для мобильных сетей и каналов с потерями пакетов',
          'High-throughput QUIC proxy ideal for congested or lossy mobile networks',
        ),
        defaults: {
          enabled: '1',
          protocol: 'hysteria2',
          listen_port: '8443',
        },
      },
      {
        id: 'awg',
        icon: () => renderLockIcon(20),
        title: 'AmneziaWG 2.0 VPN',
        desc: tr(
          'Полноценный VPN-сервер с защитой от DPI (мусорные пакеты и обфускация заголовков)',
          'Full-device VPN tunnel with DPI-resistant junk packet & header obfuscation',
        ),
        defaults: {
          enabled: '1',
          protocol: 'awg',
          listen_port: '51820',
          awg_version: '2.0',
        },
      },
      {
        id: 'mieru',
        icon: () => renderShieldIcon(20),
        title: 'Mieru (TCP / UDP Multi-Port)',
        desc: tr(
          'Антицензурный мультипортовый протокол (2012-2022) с обфускацией и мультиплексированием',
          'Censorship-resistant multi-port protocol (2012-2022) with AEAD obfuscation and multiplexing',
        ),
        defaults: {
          enabled: '1',
          protocol: 'mieru',
          listen_port: '2012-2022',
          mieru_transport: 'TCP',
          mieru_multiplexing: 'MULTIPLEXING_HIGH',
        },
      },
      {
        id: 'tuic',
        icon: () => renderZapIcon(20),
        title: 'TUIC v5 / AnyTLS / ShadowTLS',
        desc: tr(
          'Современный мультиплексированный QUIC или TLS-padding сервер',
          'Modern multiplexed QUIC or TLS-padding inbound server',
        ),
        defaults: {
          enabled: '1',
          protocol: 'tuic',
          listen_port: '8443',
        },
      },
      {
        id: 'socks_mixed',
        icon: () => renderRadioIcon(20),
        title: 'Mixed SOCKS5 / HTTP Proxy',
        desc: tr(
          'Локальный или внешний прокси-сервер для устройств и Telegram',
          'Lightweight proxy server for LAN devices or Telegram MTProto',
        ),
        defaults: {
          enabled: '1',
          protocol: 'mixed',
          listen_port: '2080',
        },
      },
    ];
  }
  return [
    {
      id: 'default',
      icon: () => renderSparklesIcon(20),
      title: tr('Стандартная запись', 'Standard Item'),
      desc: tr(
        'Создать новую запись и перейти к её детальной настройке',
        'Create a new configuration entry and open its settings modal',
      ),
      defaults: { enabled: '1' },
    },
  ];
}

function openStudioCreateModal(
  sectionRef: any,
  type: StudioEntityType,
  onCreated: () => void,
): void {
  if (typeof ui === 'undefined' || typeof ui.showModal !== 'function') return;

  const templates = getQuickCreateTemplates(type);
  let selectedTemplate = templates[0];

  const nameInput = E('input', {
    type: 'text',
    class: 'cbi-input-text tachyon-studio-create__input',
    placeholder:
      type === 'section'
        ? tr(
            'Например: YouTube, Игры, Нейросети, Рабочий VPN',
            'e.g. YouTube, Gaming, AI Services, Work VPN',
          )
        : type === 'outbound_source'
          ? tr(
              'Например: Основная подписка, Нидерланды VLESS, YouTube Desync',
              'e.g. Main Subscription, EU VLESS, YouTube Desync',
            )
          : type === 'condition'
            ? tr(
                'Например: Стриминг, Игровые порты, Домашние ТВ',
                'e.g. Streaming Sites, Gaming Ports, Home Devices',
              )
            : type === 'balancer'
              ? tr(
                  'Например: Быстрый автовыбор ЕС, Каскадный резерв',
                  'e.g. Fast Europe URLTest, Backup Failover',
                )
              : tr(
                  'Например: Домашний VLESS Reality, Мобильный Hysteria2',
                  'e.g. Home VLESS Reality, Mobile Hysteria2',
                ),
  }) as HTMLInputElement;

  const errorEl = E(
    'div',
    {
      class: 'tachyon-studio-create__error',
      style: 'display: none;',
    },
    '',
  );

  const templateCardsWrap = E('div', {
    class: 'tachyon-studio-create__templates',
  });

  const dnsUseWanCheckbox = E('input', {
    type: 'checkbox',
    class: 'cbi-input-checkbox',
    style: 'margin-right: 8px;',
  }) as HTMLInputElement;

  const dnsOptionsWrap = E(
    'div',
    {
      class: 'tachyon-studio-create__field',
      style: 'display: none; margin-top: 8px;',
    },
    [
      E(
        'label',
        {
          style:
            'display: flex; align-items: center; cursor: pointer; font-size: 13px; gap: 6px;',
        },
        [
          dnsUseWanCheckbox,
          E(
            'span',
            {},
            tr(
              'Брать DNS-серверы провайдера с WAN-порта (ISP DNS)',
              'Use ISP DNS servers from WAN port',
            ),
          ),
        ],
      ),
    ],
  );

  const renderTemplateCards = () => {
    templateCardsWrap.innerHTML = '';
    dnsOptionsWrap.style.display =
      type === 'section' && selectedTemplate?.id === 'dns' ? 'block' : 'none';
    templates.forEach((tpl) => {
      const isSelected = tpl.id === selectedTemplate.id;
      const selectCard = () => {
        selectedTemplate = tpl;
        renderTemplateCards();
      };
      const card = E(
        'div',
        {
          role: 'button',
          tabIndex: 0,
          class: `tachyon-studio-create__tpl-card ${isSelected ? 'is-selected' : ''}`,
          click: selectCard,
        },
        [
          E('span', { class: 'tachyon-studio-create__tpl-icon' }, [
            typeof tpl.icon === 'function' ? tpl.icon() : tpl.icon,
          ]),
          E('div', { class: 'tachyon-studio-create__tpl-body' }, [
            E('div', { class: 'tachyon-studio-create__tpl-title' }, tpl.title),
            E('div', { class: 'tachyon-studio-create__tpl-desc' }, tpl.desc),
          ]),
        ],
      );
      card.setAttribute('aria-pressed', isSelected ? 'true' : 'false');
      card.addEventListener('keydown', (ev: KeyboardEvent) => {
        if (ev.key === 'Enter' || ev.key === ' ') {
          ev.preventDefault();
          selectCard();
        }
      });
      templateCardsWrap.appendChild(card);
    });
  };

  renderTemplateCards();

  let isConfirming = false;
  const handleConfirm = () => {
    if (isConfirming) return;
    const rawName = nameInput.value.trim();
    if (!rawName) {
      errorEl.textContent = tr('Введите название.', 'Please enter a name.');
      errorEl.style.display = 'block';
      nameInput.focus();
      return;
    }

    isConfirming = true;
    const prefixMap: Record<StudioEntityType, string> = {
      section: 'sec',
      outbound_source: 'src',
      condition: 'cond',
      balancer: 'bal',
      server: 'srv',
      profile: 'prof',
      schedule: 'sched',
    };

    pendingUciSaveChain.finally(() => {
      let uciId = /^[A-Za-z0-9_]+$/.test(rawName)
        ? rawName
        : sanitizeUciId(rawName, prefixMap[type] || 'item');

      let suffix = 1;
      const baseId = uciId;
      while (uci.get(UCI_PACKAGE, uciId)) {
        suffix += 1;
        uciId = `${baseId}_${suffix}`;
      }

      const dataStore = sectionRef?.map?.data || uci;
      if (typeof dataStore.add === 'function') {
        dataStore.add(UCI_PACKAGE, sectionRef.sectiontype || type, uciId);
      } else {
        uci.add(UCI_PACKAGE, sectionRef.sectiontype || type, uciId);
      }
      sanitizeStaleUciDeletes(uciId);
      Object.entries(selectedTemplate.defaults || {}).forEach(([k, v]) => {
        uci.set(UCI_PACKAGE, uciId, k, v);
      });
      if (
        type === 'section' &&
        selectedTemplate.id === 'dns' &&
        dnsUseWanCheckbox.checked
      ) {
        uci.set(UCI_PACKAGE, uciId, 'dns_use_wan', '1');
        uci.set(UCI_PACKAGE, uciId, 'dns_type', 'udp');
      }

      if (type === 'section' || type === 'profile') {
        uci.set(UCI_PACKAGE, uciId, 'label', rawName);
      } else {
        const isProxyShareUri =
          /^(?:vless|vmess|trojan|ss|ssr|hysteria2|hy2|hysteria|tuic|anytls|naive\+(?:https|quic|h2|h3)|mieru|mierus|snell|trusttunnel|shadowtls|masque|warp|wg|awg|wireguard|socks5?h?):\/\//i.test(
            rawName,
          );
        let displayName = rawName;
        if (type === 'outbound_source' && isProxyShareUri) {
          const hashIdx = rawName.indexOf('#');
          if (hashIdx >= 0 && hashIdx + 1 < rawName.length) {
            try {
              const decoded = decodeURIComponent(
                rawName.slice(hashIdx + 1),
              ).trim();
              if (decoded) displayName = decoded;
            } catch {
              const rawFrag = rawName.slice(hashIdx + 1).trim();
              if (rawFrag) displayName = rawFrag;
            }
          }
          uci.set(UCI_PACKAGE, uciId, 'source_type', 'proxy_links');
          uci.set(UCI_PACKAGE, uciId, 'proxy_links', [rawName]);
        } else if (
          type === 'outbound_source' &&
          selectedTemplate.id === 'subscription' &&
          /^https?:\/\//i.test(rawName)
        ) {
          uci.set(UCI_PACKAGE, uciId, 'url', rawName);
        }
        uci.set(UCI_PACKAGE, uciId, 'name', displayName);
      }

      ui.hideModal();

      try {
        const mapNode =
          typeof sectionRef.getPreviousModalMap === 'function'
            ? sectionRef.getPreviousModalMap()
            : null;
        const prevMap =
          mapNode &&
          typeof (globalThis as any).L !== 'undefined' &&
          (globalThis as any).L.dom &&
          typeof (globalThis as any).L.dom.findClassInstance === 'function'
            ? (globalThis as any).L.dom.findClassInstance(mapNode)
            : sectionRef.map;
        if (prevMap) {
          prevMap.addedSection = uciId;
        }
      } catch {
        if (sectionRef.map) {
          sectionRef.map.addedSection = uciId;
        }
      }

      onCreated();
      notifyUciChanged().finally(() => {
        onCreated();
        if (typeof sectionRef.renderMoreOptionsModal === 'function') {
          window.setTimeout(() => {
            sectionRef.renderMoreOptionsModal(uciId);
          }, 40);
        }
      });
    });
  };

  nameInput.addEventListener('keydown', (ev: KeyboardEvent) => {
    if (ev.key === 'Enter') {
      ev.preventDefault();
      handleConfirm();
    }
  });

  const modalTitleMap: Record<StudioEntityType, string> = {
    section: tr('Новая секция маршрутизации', 'Create Routing Section'),
    outbound_source: tr(
      'Новый источник или туннель',
      'Add Server Source or Tunnel',
    ),
    condition: tr('Новое условие трафика', 'Create Traffic Condition'),
    balancer: tr('Новый балансировщик', 'Create Balancer Policy'),
    server: tr('Новый входящий сервер (Inbound)', 'Create Inbound Server'),
    profile: tr('Новый семейный профиль', 'Create Family Profile'),
    schedule: tr('Новое правило расписания', 'Create Schedule Rule'),
  };

  ui.showModal(
    modalTitleMap[type] || tr('Создание записи', 'Create Item'),
    [
      E('div', { class: 'tachyon-studio-create' }, [
        E('div', { class: 'tachyon-studio-create__field' }, [
          E(
            'label',
            { class: 'tachyon-studio-create__label' },
            tr('Название', 'Display Name'),
          ),
          nameInput,
          errorEl,
        ]),
        templates.length > 1
          ? E('div', { class: 'tachyon-studio-create__field' }, [
              E(
                'label',
                { class: 'tachyon-studio-create__label' },
                tr('Выберите шаблон архитектуры', 'Choose Preset Architecture'),
              ),
              templateCardsWrap,
            ])
          : E('span'),
        dnsOptionsWrap,
        E('div', { class: 'tachyon-studio-create__footer' }, [
          E(
            'button',
            {
              type: 'button',
              class: 'btn cbi-button',
              click: () => ui.hideModal(),
            },
            tr('Отмена', 'Cancel'),
          ),
          E(
            'button',
            {
              type: 'button',
              class: 'btn cbi-button cbi-button-apply',
              click: handleConfirm,
            },
            `${tr('Создать и настроить', 'Create & Configure')} →`,
          ),
        ]),
      ]),
    ],
    'cbi-modal',
  );

  window.setTimeout(() => nameInput.focus(), 50);
}

export function mountTachyonStudioDeck(options: StudioDeckMountOptions): void {
  const {
    type,
    sectionRef,
    containerEl,
    onShowSectionRules,
    onCloneSection,
    onNavigateSubTab,
  } = options;
  if (!containerEl || !sectionRef) return;

  containerEl.classList.add('tachyon-has-studio-deck');

  const existingDeck = containerEl.querySelector(
    `.tachyon-studio-deck--${type}`,
  );
  if (existingDeck) {
    existingDeck.remove();
  }

  let activeFilter = 'all';
  let searchQuery = '';
  let viewMode: StudioViewMode = getStudioViewMode(type);
  let draggedSid: string | null = null;

  const deckRoot = E('div', {
    class: `tachyon-studio-deck tachyon-studio-deck--${type}`,
  });

  const headerMeta: Record<
    StudioEntityType,
    {
      badge: string;
      title: string;
      panelTitle: string;
      subtitle: string;
      addLabel: string;
      filters: { id: string; label: string }[];
    }
  > = {
    section: {
      badge: 'TACHYON ROUTING PIPELINE',
      title: tr('Настройки секций маршрутизации', 'Routing Sections Settings'),
      panelTitle: tr('Секции маршрутизации', 'Routing Sections'),
      subtitle: tr(
        'Пакеты проверяются сверху вниз (#1 → #N). Перетаскивайте карточки или используйте стрелки приоритета.',
        'Packets are matched from top (#1) to bottom. Drag cards or use priority arrows to reorder.',
      ),
      addLabel: `+ ${tr('Добавить секцию', 'Add Section')}`,
      filters: [
        { id: 'all', label: tr('Все секции', 'All Sections') },
        { id: 'proxy', label: tr('Прокси / VPN', 'Proxy / VPN') },
        { id: 'dpi', label: tr('Обход DPI (Desync)', 'DPI Desync') },
        { id: 'system', label: 'DNS / Bypass / Block' },
      ],
    },
    outbound_source: {
      badge: 'GLOBAL SERVER POOL • LAYER 1',
      title: tr('Настройки узлов и подписок', 'Nodes & Subscriptions Settings'),
      panelTitle: tr('Узлы и подписки', 'Nodes & Subscriptions'),
      subtitle: tr(
        'Единый пул подписок, ссылок VLESS/Hysteria2, туннелей AmneziaWG/WARP и стратегий обхода DPI.',
        'Unified pool of subscriptions, VLESS/Hysteria2 links, AmneziaWG/WARP tunnels, and DPI strategies.',
      ),
      addLabel: `+ ${tr('Добавить источник', 'Add Source')}`,
      filters: [
        { id: 'all', label: tr('Все источники', 'All Sources') },
        { id: 'subscription', label: tr('Подписки', 'Subscriptions') },
        { id: 'links', label: tr('Прокси-ссылки', 'Proxy Links') },
        {
          id: 'tunnel',
          label: tr(
            'Туннели (WARP / FPTN / AWG)',
            'Tunnels (WARP / FPTN / AWG)',
          ),
        },
        { id: 'dpi', label: tr('DPI / Desync', 'DPI / Desync') },
      ],
    },
    condition: {
      badge: 'TRAFFIC MATCHERS & RULES',
      title: tr('Настройки условий трафика', 'Traffic Conditions Settings'),
      panelTitle: tr('Условия трафика', 'Traffic Conditions'),
      subtitle: tr(
        'Списки сервисов, домены, подсети и составные логические условия (AND / OR / NOT) для секций.',
        'Reusable service lists, domain/IP sets, and boolean rules (AND / OR / NOT) attached to routing sections.',
      ),
      addLabel: `+ ${tr('Добавить условие', 'Add Condition')}`,
      filters: [
        { id: 'all', label: tr('Все условия', 'All Conditions') },
        {
          id: 'active',
          label: tr('Привязанные к секциям', 'Attached to Sections'),
        },
        { id: 'services', label: tr('Списки сервисов', 'Service Lists') },
        { id: 'network', label: tr('Домены и подсети', 'Domains & Subnets') },
      ],
    },
    balancer: {
      badge: 'SMART FAILOVER & AUTO-SELECT',
      title: tr('Настройки балансировщиков', 'Balancers & Failover Settings'),
      panelTitle: tr('Балансировщики', 'Balancers'),
      subtitle: tr(
        'Автовыбор по пингу (URLTest), стабильности (EWMA + Jitter), привязке сессий (Sticky HRW), нагрузке (Least Load), скорости (Throughput), квоте (Quota) и каскадному резерву (Priority).',
        'Latency URLTest, Stability EWMA+Jitter, Sticky HRW, Least Load, Weighted, Hedged, Throughput, Quota, and tiered Priority failover.',
      ),
      addLabel: `+ ${tr('Добавить балансировщик', 'Add Balancer')}`,
      filters: [
        { id: 'all', label: tr('Все политики', 'All Policies') },
        { id: 'urltest', label: tr('Пинг / Стабильность', 'Ping / Stability') },
        { id: 'pool', label: tr('Пул / Балансировка', 'Pool / Load Balance') },
        { id: 'priority', label: 'Priority' },
      ],
    },
    server: {
      badge: 'INBOUND SERVER HUB',
      title: tr(
        'Настройки входящих серверов (Inbound)',
        'Inbound Servers Settings',
      ),
      panelTitle: tr('Серверы (Inbound)', 'Inbound Servers'),
      subtitle: tr(
        'Поднимите собственный сервер VLESS Reality, Hysteria2, TUIC, AmneziaWG или SOCKS5 для доступа к роутеру извне.',
        'Host your own VLESS Reality, Hysteria2, TUIC, AmneziaWG, or SOCKS5 server for remote access.',
      ),
      addLabel: `+ ${tr('Добавить сервер', 'Add Inbound Server')}`,
      filters: [
        { id: 'all', label: tr('Все протоколы', 'All Protocols') },
        { id: 'enabled', label: tr('Активные', 'Active Only') },
        { id: 'tls_xray', label: 'VLESS / Trojan / TLS' },
        { id: 'quic', label: 'QUIC (Hysteria2 / TUIC / MASQUE)' },
        { id: 'vpn', label: 'VPN (AmneziaWG / FPTN / OpenConnect)' },
        { id: 'local', label: 'SOCKS / HTTP / MTProto' },
      ],
    },
    profile: {
      badge: 'FAMILY ACCESS PROFILES',
      title: tr('Настройки семейных профилей', 'Family Profiles Settings'),
      panelTitle: tr('Семейные профили', 'Family Profiles'),
      subtitle: tr(
        'Объединяйте домашние устройства в профили для фильтрации контента, SafeSearch и расписаний.',
        'Group household devices to apply SafeSearch, ad blocking, and parental schedules.',
      ),
      addLabel: `+ ${tr('Добавить профиль', 'Add Profile')}`,
      filters: [{ id: 'all', label: tr('Все профили', 'All Profiles') }],
    },
    schedule: {
      badge: 'PARENTAL TIME POLICIES',
      title: tr(
        'Настройки родительского контроля',
        'Parental Control Settings',
      ),
      panelTitle: tr('Родительский контроль', 'Parental Control'),
      subtitle: tr(
        'Ограничение доступа в интернет или отдельных секций по времени суток и дням недели.',
        'Time-based internet access and section restrictions by day of week.',
      ),
      addLabel: `+ ${tr('Добавить правило', 'Add Schedule')}`,
      filters: [{ id: 'all', label: tr('Все расписания', 'All Schedules') }],
    },
  };

  const meta = headerMeta[type] || headerMeta.section;

  const toolbarEl = E('div', { class: 'tachyon-studio-toolbar' });
  const panelEl = E('div', { class: 'tachyon-studio-panel' });
  const panelHeaderEl = E('div', { class: 'tachyon-studio-panel__header' });
  const bodyEl = E('div', { class: 'tachyon-studio-body' });
  let disabledTrayOpen = false;
  const disabledTrayEl = E('div', {
    class: 'tachyon-studio-disabled-tray is-hidden',
  });
  panelEl.appendChild(panelHeaderEl);
  panelEl.appendChild(bodyEl);
  panelEl.appendChild(disabledTrayEl);

  interface SubCacheServerItem {
    name: string;
    proto: string;
    trans: string;
    link?: string;
  }
  interface SubCacheEntryInfo {
    mtime: number;
    servers: SubCacheServerItem[];
    metadata?: {
      title?: string;
      traffic?: {
        used?: number;
        total?: number;
        isUnlimited?: boolean;
      };
      expire?: number;
      webPageUrl?: string;
      supportUrl?: string;
      announce?: string;
      updatedAt?: number;
    };
  }

  const subCacheByUrl = new Map<string, SubCacheEntryInfo>();
  const subCacheBySid = new Map<string, SubCacheEntryInfo>();
  const expandedSourceIds = new Set<string>();
  const updatingSubTargets = new Set<string>();

  const isFsNotFoundError = (err: any): boolean => {
    const msg = `${String(err?.name || '')} ${String(err?.message || err || '')}`;
    return /NotFoundError|ENOENT|No such file or directory|Object not found|-32000/i.test(
      msg,
    );
  };

  const readFsText = (
    path: string,
    allowDirectFallback = true,
  ): Promise<string> => {
    if (typeof fs === 'undefined' || typeof fs.read !== 'function') {
      return Promise.resolve('');
    }
    return fs
      .read(path)
      .catch((err: any) =>
        allowDirectFallback &&
        !isFsNotFoundError(err) &&
        typeof (fs as any).read_direct === 'function'
          ? (fs as any).read_direct(path, 'text')
          : Promise.resolve(''),
      )
      .then((raw: any) => String(raw || ''))
      .catch(() => '');
  };

  const populateSubCacheFromSectionCaches = (): Promise<void> => {
    const subSources = (
      uci.sections(UCI_PACKAGE, 'outbound_source') || []
    ).filter((s: any) => {
      if (!s) return false;
      const t = String(s.source_type || s.type || 'subscription').toLowerCase();
      return t === 'subscription' || t === 'fptn';
    });
    if (subSources.length === 0) return Promise.resolve();

    const secObjs = uci.sections(UCI_PACKAGE, 'section') || [];
    const secNames = Array.from(
      new Set([
        'Main',
        ...secObjs.map((sec: any) => String(sec?.name || sec?.['.name'] || '')),
        ...secObjs.map((sec: any) => String(sec?.['.name'] || '')),
      ]),
    ).filter(Boolean);

    const listCacheDirPromise: Promise<Set<string> | null> =
      typeof fs !== 'undefined' && typeof fs.list === 'function'
        ? fs
            .list('/var/run/tachyon/section-cache')
            .then((entries: any) =>
              Array.isArray(entries)
                ? new Set(
                    entries
                      .map((e: any) => String((e && e.name) || ''))
                      .filter(Boolean),
                  )
                : null,
            )
            .catch(() => null)
        : Promise.resolve(null);

    return listCacheDirPromise
      .then((existingFiles) => {
        const candidates =
          existingFiles !== null
            ? secNames.filter((secName) => existingFiles.has(`${secName}.json`))
            : secNames;
        if (candidates.length === 0) return [];
        const allowDirect = existingFiles !== null;
        return Promise.all(
          candidates.map((secName) =>
            readFsText(
              `/var/run/tachyon/section-cache/${secName}.json`,
              allowDirect,
            ).then((raw) => {
              if (!raw) return null;
              try {
                return JSON.parse(raw);
              } catch {
                return null;
              }
            }),
          ),
        );
      })
      .then((caches) => {
        const validCaches = caches.filter((c) => c && typeof c === 'object');
        if (validCaches.length === 0) return;

        const singleSub = subSources.length === 1 ? subSources[0] : null;
        const fptnSources = subSources.filter(
          (s: any) =>
            String(s.source_type || s.type || '').toLowerCase() === 'fptn',
        );
        const singleFptn = fptnSources.length === 1 ? fptnSources[0] : null;
        subSources.forEach((src: any) => {
          const sid = String(src['.name'] || '');
          const srcStype = String(
            src.source_type || src.type || 'subscription',
          ).toLowerCase();
          const rawSubName = String(src.name || '').trim();
          const subUrl = String(
            src.url || (/^https?:\/\//i.test(rawSubName) ? rawSubName : ''),
          ).trim();
          const existingByUrl =
            srcStype === 'subscription' && subUrl
              ? subCacheByUrl.get(subUrl)
              : undefined;
          const alreadyHasServers = (existingByUrl?.servers.length || 0) > 0;
          const prefix =
            src.prefix_nodes !== '0' && src.node_prefix
              ? String(src.node_prefix).trim()
              : '';
          const srcTitle = String(src.name || src.label || sid).trim();
          const serverMap = new Map<string, SubCacheServerItem>();
          let foundMeta: SubCacheEntryInfo['metadata'] = undefined;
          let foundUpdatedAt = 0;

          validCaches.forEach((c: any) => {
            const meta =
              c.outboundMetadata && typeof c.outboundMetadata === 'object'
                ? c.outboundMetadata
                : {};
            const namesObj =
              (meta.names && typeof meta.names === 'object'
                ? meta.names
                : c.names && typeof c.names === 'object'
                  ? c.names
                  : {}) || {};
            const protocolsObj =
              (meta.protocols && typeof meta.protocols === 'object'
                ? meta.protocols
                : c.types && typeof c.types === 'object'
                  ? c.types
                  : {}) || {};
            const transportsObj =
              meta.transports && typeof meta.transports === 'object'
                ? meta.transports
                : {};
            const prefixesObj =
              meta.prefixes && typeof meta.prefixes === 'object'
                ? meta.prefixes
                : {};
            const sourceIdsObj =
              meta.source_ids && typeof meta.source_ids === 'object'
                ? meta.source_ids
                : {};
            const linksObj =
              c.links && typeof c.links === 'object' ? c.links : {};
            const outboundsArr = Array.from(
              new Set([
                ...Object.keys(namesObj),
                ...(Array.isArray(c.urltestCandidateTags)
                  ? c.urltestCandidateTags
                  : []),
                ...(Array.isArray(c.outbounds) ? c.outbounds : []),
              ]),
            );
            const subInfos = [
              ...(Array.isArray(c.subscriptionMetadata)
                ? c.subscriptionMetadata
                : []),
              ...(Array.isArray(c.subscriptionInfos)
                ? c.subscriptionInfos
                : []),
            ];

            subInfos.forEach((si: any) => {
              if (!si || typeof si !== 'object') return;
              const siTitle = String(si.title || '').trim();
              const siSec = String(
                si.sourceSection || si.source_section || '',
              ).trim();
              if (
                singleSub ||
                (sid &&
                  (siSec === `${sid}-subscription-1` ||
                    siSec === `Pool_${sid}-subscription-1`)) ||
                (prefix && siTitle.toLowerCase() === prefix.toLowerCase()) ||
                (srcTitle && siTitle.toLowerCase() === srcTitle.toLowerCase())
              ) {
                const siUpd = Number(si.updatedAt || 0);
                if (siUpd > foundUpdatedAt) foundUpdatedAt = siUpd;
                foundMeta = {
                  title: siTitle || foundMeta?.title || undefined,
                  traffic: si.traffic ?? foundMeta?.traffic,
                  expire: si.expire ?? foundMeta?.expire,
                  webPageUrl: si.webPageUrl || foundMeta?.webPageUrl,
                  supportUrl: si.supportUrl || foundMeta?.supportUrl,
                  announce: si.announce || foundMeta?.announce,
                  updatedAt: siUpd > 0 ? siUpd : foundMeta?.updatedAt,
                };
              }
            });

            if (alreadyHasServers) return;

            outboundsArr.forEach((code: string) => {
              const cStr = String(code || '');
              if (
                !cStr ||
                cStr === 'direct-out' ||
                cStr === 'block-out' ||
                cStr.endsWith('-urltest-out') ||
                cStr.endsWith('-priority-out') ||
                cStr.startsWith('bal-') ||
                cStr.startsWith('lvl-')
              ) {
                return;
              }
              const rawName = String(namesObj[cStr] || cStr).trim();
              const link = String(linksObj[cStr] || '').trim();
              const rawType = String(protocolsObj[cStr] || '').toUpperCase();
              if (
                rawType === 'URLTEST' ||
                rawType === 'SELECTOR' ||
                rawType === 'DIRECT' ||
                rawType === 'DPI'
              ) {
                return;
              }

              const codeSourceId = String(sourceIdsObj[cStr] || '').trim();
              const codePrefix = String(prefixesObj[cStr] || '').trim();
              let matches = false;
              let cleanName = rawName;
              if (codeSourceId && codeSourceId === sid) {
                matches = true;
              } else if (
                prefix &&
                codePrefix &&
                codePrefix.toLowerCase() === prefix.toLowerCase()
              ) {
                matches = true;
              } else if (prefix) {
                if (rawName.startsWith(`${prefix}: `)) {
                  matches = true;
                  cleanName = rawName.slice(prefix.length + 2).trim();
                } else if (rawName.startsWith(`${prefix} `)) {
                  matches = true;
                  cleanName = rawName.slice(prefix.length + 1).trim();
                }
              } else if (
                srcStype === 'fptn' &&
                (rawType === 'FPTN' || cStr.toLowerCase().includes('fptn')) &&
                (singleFptn ||
                  (srcTitle &&
                    rawName.toLowerCase().startsWith(srcTitle.toLowerCase())))
              ) {
                matches = true;
              } else if (
                singleSub &&
                srcStype === 'subscription' &&
                !codeSourceId
              ) {
                matches = true;
              }

              if (matches && cleanName && !serverMap.has(cleanName)) {
                const proto =
                  rawType ||
                  (link.includes('://')
                    ? link.split('://')[0].toUpperCase()
                    : 'PROXY');
                const trans =
                  String(transportsObj[cStr] || '').toUpperCase() ||
                  (link.includes('://')
                    ? (getProxyUrlTransport(link) || 'TCP').toUpperCase()
                    : '');
                serverMap.set(cleanName, {
                  name: cleanName,
                  proto,
                  trans,
                  link,
                });
              }
            });
          });

          if (alreadyHasServers && existingByUrl) {
            if (foundUpdatedAt > (existingByUrl.mtime || 0)) {
              existingByUrl.mtime = foundUpdatedAt;
            }
            const metaFound = foundMeta as
              | NonNullable<SubCacheEntryInfo['metadata']>
              | undefined;
            if (metaFound) {
              existingByUrl.metadata = {
                ...(existingByUrl.metadata || {}),
                title: existingByUrl.metadata?.title || metaFound.title,
                traffic: metaFound.traffic ?? existingByUrl.metadata?.traffic,
                expire: metaFound.expire ?? existingByUrl.metadata?.expire,
                webPageUrl:
                  metaFound.webPageUrl || existingByUrl.metadata?.webPageUrl,
                supportUrl:
                  metaFound.supportUrl || existingByUrl.metadata?.supportUrl,
                announce:
                  metaFound.announce || existingByUrl.metadata?.announce,
                updatedAt: Math.max(
                  Number(existingByUrl.metadata?.updatedAt || 0),
                  Number(metaFound.updatedAt || 0),
                ),
              };
            }
            subCacheBySid.set(sid, existingByUrl);
            return;
          }

          const servers = Array.from(serverMap.values());
          if (servers.length > 0 || foundMeta) {
            const existingMtime = Math.max(
              (subUrl ? subCacheByUrl.get(subUrl)?.mtime : 0) || 0,
              subCacheBySid.get(sid)?.mtime || 0,
              foundUpdatedAt,
            );
            const entry: SubCacheEntryInfo = {
              mtime: existingMtime,
              servers,
              metadata: foundMeta,
            };
            subCacheBySid.set(sid, entry);
            if (subUrl && !subCacheByUrl.has(subUrl)) {
              subCacheByUrl.set(subUrl, entry);
            }
          }
        });
      });
  };

  const loadSubscriptionCacheMap = () => {
    if (
      type !== 'outbound_source' ||
      typeof fs === 'undefined' ||
      typeof fs.list !== 'function'
    ) {
      return Promise.resolve();
    }
    const dir = '/etc/tachyon/subscription-cache';
    const runtimeDir = '/tmp/tachyon-core/subscriptions';
    const tsDir = '/var/run/tachyon/subscription-update';
    return Promise.all([
      fs.list(dir).catch(() => []),
      fs.list(runtimeDir).catch(() => []),
      fs.list(tsDir).catch(() => []),
    ])
      .then(([entries, runtimeEntries, tsEntries]: any[][]) => {
        const list = Array.isArray(entries) ? entries : [];
        const rtList = Array.isArray(runtimeEntries) ? runtimeEntries : [];
        const tsList = Array.isArray(tsEntries) ? tsEntries : [];
        const jsonBases: string[] = [];
        const urlSet = new Set<string>();
        const metaSet = new Set<string>();
        const rtMetaSet = new Set<string>();
        const tsSet = new Set<string>();
        const linksSet = new Set<string>();
        const mtimeMap = new Map<string, number>();

        list.forEach((ent: any) => {
          const fname = String((ent && ent.name) || '');
          if (fname.endsWith('.url')) {
            urlSet.add(fname.slice(0, -4));
          } else if (fname.endsWith('.metadata.json')) {
            metaSet.add(fname.slice(0, -14));
          } else if (fname.endsWith('.links')) {
            linksSet.add(fname.slice(0, -6));
          } else if (
            fname.endsWith('.json') &&
            fname.includes('-subscription-')
          ) {
            const base = fname.slice(0, -5);
            jsonBases.push(base);
            mtimeMap.set(base, Number(ent.mtime || 0));
          }
        });

        rtList.forEach((ent: any) => {
          const fname = String((ent && ent.name) || '');
          const mtime = Number(ent?.mtime || 0);
          if (fname.endsWith('.metadata.json')) {
            const base = fname.slice(0, -14);
            rtMetaSet.add(base);
            if (mtime > (mtimeMap.get(base) || 0)) mtimeMap.set(base, mtime);
          } else if (
            fname.endsWith('.json') &&
            fname.includes('-subscription-')
          ) {
            const base = fname.slice(0, -5);
            if (mtime > (mtimeMap.get(base) || 0)) mtimeMap.set(base, mtime);
          }
        });

        tsList.forEach((ent: any) => {
          const fname = String((ent && ent.name) || '');
          if (fname.endsWith('.timestamp')) {
            const base = fname.slice(0, -10);
            tsSet.add(base);
            const mtime = Number(ent?.mtime || 0);
            if (mtime > (mtimeMap.get(base) || 0)) mtimeMap.set(base, mtime);
          }
        });

        return Promise.all(
          jsonBases.map((base) =>
            (urlSet.has(base)
              ? readFsText(`${dir}/${base}.url`)
              : Promise.resolve('')
            ).then((u) => ({
              base,
              url: u.trim(),
              mtime: mtimeMap.get(base) || 0,
            })),
          ),
        ).then((infos) => {
          const byUrl = new Map<
            string,
            { base: string; url: string; mtime: number }
          >();
          infos.forEach((inf) => {
            if (!inf.url) return;
            const prev = byUrl.get(inf.url);
            if (!prev || inf.mtime >= prev.mtime) {
              byUrl.set(inf.url, inf);
            }
          });
          const chosen = Array.from(byUrl.values());
          return Promise.all(
            chosen.map((inf) =>
              Promise.all([
                readFsText(`${dir}/${inf.base}.json`),
                metaSet.has(inf.base)
                  ? readFsText(`${dir}/${inf.base}.metadata.json`)
                  : Promise.resolve(''),
                rtMetaSet.has(inf.base)
                  ? readFsText(`${runtimeDir}/${inf.base}.metadata.json`)
                  : Promise.resolve(''),
                tsSet.has(inf.base)
                  ? readFsText(`${tsDir}/${inf.base}.timestamp`)
                  : Promise.resolve(''),
                linksSet.has(inf.base)
                  ? readFsText(`${dir}/${inf.base}.links`)
                  : Promise.resolve(''),
              ]).then(([rawJson, rawMeta, rawRtMeta, rawTs, rawLinks]) => {
                let parsedJson: any = {};
                let parsedMeta: any = undefined;
                let parsedRtMeta: any = undefined;
                try {
                  parsedJson = rawJson ? JSON.parse(rawJson) : {};
                } catch (_e) {
                  parsedJson = {};
                }
                try {
                  parsedMeta = rawMeta ? JSON.parse(rawMeta) : undefined;
                } catch (_e) {
                  parsedMeta = undefined;
                }
                try {
                  parsedRtMeta = rawRtMeta ? JSON.parse(rawRtMeta) : undefined;
                } catch (_e) {
                  parsedRtMeta = undefined;
                }
                if (parsedRtMeta && typeof parsedRtMeta === 'object') {
                  parsedMeta = { ...(parsedMeta || {}), ...parsedRtMeta };
                }
                const tsNum = Number(String(rawTs || '').trim()) || 0;
                const metaUpd = Number(parsedMeta?.updatedAt || 0);
                const bestMtime = Math.max(inf.mtime || 0, tsNum, metaUpd);

                const linkLines = String(rawLinks || '')
                  .split(/\r?\n/)
                  .map((l) => l.trim())
                  .filter((l) => l.includes('://'));
                const linkByTag = new Map<string, string>();
                linkLines.forEach((lnk) => {
                  const hashIdx = lnk.indexOf('#');
                  if (hashIdx >= 0) {
                    try {
                      const tagPart = decodeURIComponent(
                        lnk.slice(hashIdx + 1),
                      ).trim();
                      if (tagPart && !linkByTag.has(tagPart)) {
                        linkByTag.set(tagPart, lnk);
                      }
                    } catch {
                      // ignore malformed URI component
                    }
                  }
                });

                const rawOutbounds = Array.isArray(parsedJson?.outbounds)
                  ? parsedJson.outbounds
                  : [];
                const outbounds = rawOutbounds.filter((ob: any) => {
                  const name = String(
                    ob?.remark || ob?.tag || ob?.name || '',
                  ).trim();
                  const proto = String(ob?.type || '').toUpperCase();
                  return (
                    Boolean(name) &&
                    proto !== 'URLTEST' &&
                    proto !== 'SELECTOR' &&
                    proto !== 'DIRECT'
                  );
                });
                const servers: SubCacheServerItem[] = [];
                outbounds.forEach((ob: any, idx: number) => {
                  const name = String(
                    ob?.remark || ob?.tag || ob?.name || '',
                  ).trim();
                  const proto = String(ob?.type || '').toUpperCase();
                  const trans = String(
                    ob?.transport?.type || 'tcp',
                  ).toUpperCase();
                  const link = String(
                    ob?.share_link ||
                      ob?.__tachyon_link ||
                      ob?.link ||
                      linkByTag.get(name) ||
                      (linkLines.length >= outbounds.length
                        ? linkLines[idx]
                        : '') ||
                      '',
                  ).trim();
                  servers.push({ name, proto, trans, link });
                });

                subCacheByUrl.set(inf.url, {
                  mtime: bestMtime,
                  servers,
                  metadata: parsedMeta,
                });
              }),
            ),
          );
        });
      })
      .then(() => populateSubCacheFromSectionCaches())
      .then(async () => {
        if (typeof fs === 'undefined') return;
        const fptnSources = (
          uci.sections(UCI_PACKAGE, 'outbound_source') || []
        ).filter(
          (s: any) =>
            s &&
            String(s.source_type || s.type || '').toLowerCase() === 'fptn' &&
            s.access_token,
        );
        for (const src of fptnSources) {
          const fullToken = String(src.access_token || '')
            .trim()
            .split('#')[0]
            .trim();
          if (
            !fullToken ||
            !/^fptnb(?::\/\/|:)/i.test(fullToken) ||
            fptnDecodedCache.has(fullToken)
          ) {
            continue;
          }
          let normTok = fullToken;
          if (/^fptnb:\/\//i.test(normTok)) {
            normTok = `fptnb:${normTok.slice(8)}`;
          }
          try {
            let rawOut = '';
            if (typeof (fs as any).exec_direct === 'function') {
              rawOut = String(
                (await (fs as any).exec_direct(
                  '/usr/bin/tachyon-core',
                  ['fptn', 'decode', normTok],
                  'text',
                )) || '',
              );
            } else if (typeof fs.exec === 'function') {
              const res = await fs.exec('/usr/bin/tachyon-core', [
                'fptn',
                'decode',
                normTok,
              ]);
              rawOut = String((res && res.stdout) || '');
            }
            if (rawOut.trim()) {
              const data = JSON.parse(rawOut);
              const parsed = parseFptnPayloadObject(data, fullToken);
              if (parsed.servers.length > 0) {
                fptnDecodedCache.set(fullToken, parsed);
              }
            }
          } catch {
            // ignore decode failures
          }
        }
      })
      .then(() => {
        renderDeck();
      })
      .catch(() => {});
  };

  const triggerSubscriptionUpdate = async (targetSid?: string) => {
    const key = targetSid || '__all__';
    if (updatingSubTargets.has(key) || typeof fs === 'undefined') return;
    updatingSubTargets.add(key);
    renderDeck();

    try {
      const args = targetSid
        ? ['subscription_update_async', targetSid]
        : ['subscription_update_async'];
      const execCmd = async (cmdArgs: string[]): Promise<any> => {
        if (typeof (fs as any).exec_direct === 'function') {
          const out = await (fs as any).exec_direct(
            '/usr/bin/tachyon',
            cmdArgs,
            'text',
          );
          return out ? JSON.parse(out) : null;
        }
        const res = await fs.exec('/usr/bin/tachyon', cmdArgs);
        return res && res.stdout ? JSON.parse(res.stdout) : null;
      };

      const startRes = await execCmd(args).catch(() => null);
      const jobId = startRes?.job_id;
      if (jobId) {
        for (let i = 0; i < 40; i++) {
          await new Promise((r) => setTimeout(r, 1500));
          const st = await execCmd([
            'subscription_update_status',
            String(jobId),
          ]).catch(() => null);
          if (!st || !st.running) break;
        }
      }
      if (
        typeof ui !== 'undefined' &&
        typeof ui.addNotification === 'function'
      ) {
        ui.addNotification(
          null,
          E(
            'p',
            {},
            targetSid
              ? tr('Подписка обновлена.', 'Subscription updated.')
              : tr('Все подписки обновлены.', 'All subscriptions updated.'),
          ),
          'info',
        );
      }
    } catch (_e) {
      // ignore transient RPC errors
    } finally {
      updatingSubTargets.delete(key);
      await loadSubscriptionCacheMap();
      renderDeck();
    }
  };

  const renderDeck = () => {
    const sids: string[] =
      typeof sectionRef.cfgsections === 'function'
        ? sectionRef.cfgsections()
        : (uci.sections(UCI_PACKAGE, sectionRef.sectiontype || type) || [])
            .map((s: any) => s['.name'])
            .filter(Boolean);

    const enabledCount = sids.filter(
      (sid) => uci.get(UCI_PACKAGE, sid, 'enabled') !== '0',
    ).length;
    sids.forEach((sid) => {
      syncHiddenGridEnabledCheckbox(
        sid,
        uci.get(UCI_PACKAGE, sid, 'enabled') !== '0',
        sectionRef,
      );
    });

    toolbarEl.innerHTML = '';
    const filterPills = meta.filters.map((f) =>
      E(
        'button',
        {
          type: 'button',
          class: `tachyon-studio-filter-pill ${activeFilter === f.id ? 'is-active' : ''}`,
          click: () => {
            activeFilter = f.id;
            renderDeck();
          },
        },
        f.label,
      ),
    );

    const searchInput = E('input', {
      type: 'search',
      class: 'tachyon-studio-search',
      placeholder: tr(
        'Поиск по имени, протоколу, сервису или домену...',
        'Search by name, protocol, service or domain...',
      ),
      value: searchQuery,
      input: (ev: Event) => {
        searchQuery = (ev.target as HTMLInputElement).value;
        renderBodyOnly(sids);
      },
    }) as HTMLInputElement;

    const extraButtons: HTMLElement[] = [];
    if (type === 'server') {
      extraButtons.push(
        E(
          'button',
          {
            type: 'button',
            class: 'tachyon-studio-btn tachyon-studio-btn--ghost',
            click: () => {
              if (openServerSubscriptionModal()) {
                return;
              }
              if (
                sectionRef &&
                typeof sectionRef.showSubscriptionModal === 'function'
              ) {
                sectionRef.showSubscriptionModal();
                return;
              }
              const subBtn = containerEl.querySelector(
                '.tachyon-server-subscription-btn',
              ) as HTMLElement | null;
              if (subBtn) {
                subBtn.click();
              }
            },
          },
          [
            renderQrCodeIcon(14),
            E(
              'span',
              {},
              tr('Настроить подписку (URL / QR)', 'Configure subscription'),
            ),
          ],
        ),
      );
    }
    if (type === 'outbound_source') {
      const isUpdatingAll = updatingSubTargets.has('__all__');
      extraButtons.push(
        E(
          'button',
          {
            type: 'button',
            class: 'tachyon-studio-btn tachyon-studio-btn--ghost',
            disabled: isUpdatingAll ? 'disabled' : null,
            click: () => {
              void triggerSubscriptionUpdate();
            },
          },
          [
            E(
              'span',
              {},
              isUpdatingAll
                ? tr('↻ Обновление подписок...', '↻ Updating subscriptions...')
                : tr('↻ Обновить все подписки', '↻ Update All Subscriptions'),
            ),
          ],
        ),
      );
    }
    if (type === 'section' || type === 'outbound_source' || type === 'server') {
      extraButtons.push(
        E(
          'button',
          {
            type: 'button',
            class: 'tachyon-studio-btn tachyon-studio-btn--ghost',
            click: () => {
              if (type === 'server') {
                const wizBtn = containerEl.querySelector(
                  '.tachyon-inbounds-server-header button',
                ) as HTMLElement | null;
                if (wizBtn) {
                  wizBtn.click();
                  return;
                }
              }
              openConnectionWizardModal();
            },
          },
          [
            renderWandIcon(14),
            E('span', {}, tr('Быстрый мастер настройки', 'Setup Wizard')),
          ],
        ),
      );
    }

    const viewSwitchEl = E('div', { class: 'tachyon-studio-view-switch' }, [
      E(
        'button',
        {
          type: 'button',
          class: `tachyon-studio-view-btn ${viewMode === 'pipeline' ? 'is-active' : ''}`,
          title: tr('Компактный конвейер', 'Compact Pipeline View'),
          click: () => {
            viewMode = 'pipeline';
            setStudioViewMode(type, 'pipeline');
            renderDeck();
          },
        },
        [renderListIcon(13), E('span', {}, tr('Конвейер', 'Pipeline'))],
      ),
      E(
        'button',
        {
          type: 'button',
          class: `tachyon-studio-view-btn ${viewMode === 'cards' ? 'is-active' : ''}`,
          title: tr('Bento-карточки', 'Bento Cards View'),
          click: () => {
            viewMode = 'cards';
            setStudioViewMode(type, 'cards');
            renderDeck();
          },
        },
        [renderLayoutGridIcon(13), E('span', {}, tr('Карточки', 'Cards'))],
      ),
    ]);

    toolbarEl.appendChild(
      E('div', { class: 'tachyon-studio-toolbar__top' }, [
        E('div', { class: 'tachyon-studio-toolbar__titles' }, [
          E('div', { class: 'tachyon-studio-toolbar__title-row' }, [
            E('h3', { class: 'tachyon-studio-toolbar__title' }, meta.title),
          ]),
          E('p', { class: 'tachyon-studio-toolbar__subtitle' }, meta.subtitle),
        ]),
        E('div', { class: 'tachyon-studio-toolbar__actions' }, [
          ...extraButtons,
          E(
            'button',
            {
              type: 'button',
              class: 'tachyon-studio-btn tachyon-studio-btn--primary',
              click: () =>
                openStudioCreateModal(sectionRef, type, () => renderDeck()),
            },
            meta.addLabel,
          ),
        ]),
      ]),
    );

    panelHeaderEl.innerHTML = '';
    panelHeaderEl.appendChild(
      E('div', { class: 'tachyon-studio-panel__header-top' }, [
        E('div', { class: 'tachyon-studio-panel__header-left' }, [
          E('h4', { class: 'tachyon-studio-panel__title' }, meta.panelTitle),
          E(
            'span',
            { class: 'tachyon-studio-toolbar__counter' },
            `${enabledCount} / ${sids.length} ${tr('активно', 'active')}`,
          ),
        ]),
        viewSwitchEl,
      ]),
    );
    panelHeaderEl.appendChild(
      E('div', { class: 'tachyon-studio-panel__header-right' }, [
        E('div', { class: 'tachyon-studio-filter-group' }, filterPills),
        searchInput,
      ]),
    );

    renderBodyOnly(sids);
  };

  const renderBodyOnly = (sids: string[]) => {
    bodyEl.innerHTML = '';
    bodyEl.className = `tachyon-studio-body tachyon-studio-body--${viewMode}`;

    const q = searchQuery.trim().toLowerCase();

    const filteredSids = sids.filter((sid) => {
      const raw = uci.get(UCI_PACKAGE, sid) || {};
      const name = String(raw.label || raw.name || sid).toLowerCase();
      const enabled = raw.enabled !== '0';

      if (type === 'section') {
        const tel = resolveSectionTelemetry(sid);
        if (activeFilter === 'proxy' && tel.actionTone !== 'proxy')
          return false;
        if (activeFilter === 'dpi' && tel.actionTone !== 'dpi') return false;
        if (
          activeFilter === 'system' &&
          !['block', 'bypass', 'dns'].includes(tel.actionTone)
        ) {
          return false;
        }
        if (q) {
          const hay = [
            sid,
            tel.name,
            tel.actionLabel,
            ...tel.protocols,
            ...tel.transports,
            ...tel.serviceTags,
            ...tel.sources.map((s) => s.name),
          ]
            .join(' ')
            .toLowerCase();
          if (!hay.includes(q)) return false;
        }
        return true;
      }

      if (type === 'outbound_source') {
        const stype = String(raw.source_type || 'subscription').toLowerCase();
        if (activeFilter === 'subscription' && stype !== 'subscription')
          return false;
        if (activeFilter === 'links' && stype !== 'proxy_links') return false;
        if (
          activeFilter === 'tunnel' &&
          ![
            'warp',
            'fptn',
            'awg',
            'amnezia_config',
            'openvpn',
            'tailscale',
            'tor',
            'interface',
          ].includes(stype)
        ) {
          return false;
        }
        if (
          activeFilter === 'dpi' &&
          !['desync', 'zapret', 'zapret2', 'byedpi', 'wdtt', 'olcrtc'].includes(
            stype,
          )
        ) {
          return false;
        }
        if (q) {
          const hay =
            `${sid} ${name} ${stype} ${raw.url || ''} ${raw.node_prefix || ''}`.toLowerCase();
          if (!hay.includes(q)) return false;
        }
        return true;
      }

      if (type === 'condition') {
        const usedBy = (uci.sections(UCI_PACKAGE, 'section') || []).filter(
          (s: any) => asArray(s.condition_refs).map(stripPrefix).includes(sid),
        );
        const comm = asArray(raw.community_lists);
        if (activeFilter === 'active' && usedBy.length === 0) return false;
        if (activeFilter === 'services' && comm.length === 0) return false;
        if (activeFilter === 'network' && comm.length > 0) return false;
        if (q) {
          const hay =
            `${sid} ${name} ${comm.join(' ')} ${asArray(raw.domain).join(' ')} ${asArray(raw.ip_cidr).join(' ')}`.toLowerCase();
          if (!hay.includes(q)) return false;
        }
        return true;
      }

      if (type === 'balancer') {
        const btype = String(raw.balancer_type || 'urltest').toLowerCase();
        const bmode = String(raw.mode || 'least_test').toLowerCase();
        const poolModes = [
          'sticky',
          'least_load',
          'weighted',
          'hedged',
          'throughput',
          'quota',
          'round_robin',
          'random',
        ];
        if (
          activeFilter === 'urltest' &&
          (btype !== 'urltest' || poolModes.includes(bmode))
        ) {
          return false;
        }
        if (
          activeFilter === 'pool' &&
          (btype !== 'urltest' || !poolModes.includes(bmode))
        ) {
          return false;
        }
        if (activeFilter === 'priority' && btype !== 'priority') return false;
        if (
          q &&
          !`${sid} ${name} ${btype} ${bmode}`.toLowerCase().includes(q)
        ) {
          return false;
        }
        return true;
      }

      if (type === 'server') {
        const proto = String(raw.protocol || 'vless').toLowerCase();
        if (activeFilter === 'enabled' && !enabled) return false;
        if (
          activeFilter === 'tls_xray' &&
          ![
            'vless',
            'vmess',
            'trojan',
            'anytls',
            'shadowtls',
            'naive',
            'trusttunnel',
            'tewfai',
          ].includes(proto)
        ) {
          return false;
        }
        if (
          activeFilter === 'quic' &&
          !['hysteria2', 'tuic', 'masque'].includes(proto)
        ) {
          return false;
        }
        if (
          activeFilter === 'vpn' &&
          !['awg', 'fptn', 'openconnect', 'mieru'].includes(proto)
        ) {
          return false;
        }
        if (
          activeFilter === 'local' &&
          !['socks', 'http', 'mixed', 'shadowsocks', 'mtproto'].includes(proto)
        ) {
          return false;
        }
        if (
          q &&
          !`${sid} ${name} ${proto} ${raw.port || ''}`.toLowerCase().includes(q)
        ) {
          return false;
        }
        return true;
      }

      if (q && !`${sid} ${name}`.toLowerCase().includes(q)) return false;
      return true;
    });

    disabledTrayEl.innerHTML = '';
    disabledTrayEl.classList.add('is-hidden');

    if (!filteredSids.length) {
      bodyEl.appendChild(
        E('div', { class: 'tachyon-studio-empty' }, [
          E(
            'div',
            { class: 'tachyon-studio-empty__title' },
            tr('Записи не найдены', 'No matching entries found'),
          ),
          E(
            'div',
            { class: 'tachyon-studio-empty__sub' },
            tr(
              'Сбросьте фильтр или нажмите кнопку создания в правом верхнем углу.',
              'Try clearing the filter or click the create button above to add a new entry.',
            ),
          ),
        ]),
      );
      return;
    }

    const enabledSids = filteredSids.filter(
      (sid) => uci.get(UCI_PACKAGE, sid, 'enabled') !== '0',
    );
    const disabledSids = filteredSids.filter(
      (sid) => uci.get(UCI_PACKAGE, sid, 'enabled') === '0',
    );

    if (enabledSids.length > 0) {
      enabledSids.forEach((sid) => {
        const globalOrderIdx = sids.indexOf(sid) + 1;
        const cardEl = renderEntityCard(sid, globalOrderIdx, sids.length);
        bodyEl.appendChild(cardEl);
      });
    } else if (disabledSids.length > 0) {
      bodyEl.appendChild(
        E('div', { class: 'tachyon-studio-empty' }, [
          E(
            'div',
            { class: 'tachyon-studio-empty__title' },
            tr('Нет активных записей', 'No active entries'),
          ),
          E(
            'div',
            { class: 'tachyon-studio-empty__sub' },
            tr(
              'Все подходящие записи сейчас отключены и свернуты в блок ниже.',
              'All matching entries are currently disabled and collapsed in the drawer below.',
            ),
          ),
        ]),
      );
    }

    if (disabledSids.length > 0) {
      disabledTrayEl.classList.remove('is-hidden');
      const isOpen =
        disabledTrayOpen || q.length > 0 || enabledSids.length === 0;
      const trayBodyEl = E(
        'div',
        {
          class: `tachyon-studio-disabled-tray__body tachyon-studio-body tachyon-studio-body--${viewMode} ${isOpen ? 'is-open' : ''}`,
        },
        disabledSids.map((sid) => {
          const globalOrderIdx = sids.indexOf(sid) + 1;
          return renderEntityCard(sid, globalOrderIdx, sids.length);
        }),
      );
      const chevronEl = E(
        'span',
        { class: 'tachyon-studio-disabled-tray__chevron' },
        isOpen ? '▾' : '▸',
      );
      const trayHeaderBtn = E(
        'button',
        {
          type: 'button',
          class: `tachyon-studio-disabled-tray__toggle ${isOpen ? 'is-open' : ''}`,
          click: () => {
            disabledTrayOpen = !trayBodyEl.classList.contains('is-open');
            trayBodyEl.classList.toggle('is-open', disabledTrayOpen);
            trayHeaderBtn.classList.toggle('is-open', disabledTrayOpen);
            chevronEl.textContent = disabledTrayOpen ? '▾' : '▸';
          },
        },
        [
          E('span', { class: 'tachyon-studio-disabled-tray__label' }, [
            chevronEl,
            E(
              'span',
              {},
              tr(
                `Отключенные (${disabledSids.length}) — включите переключатель на карточке, чтобы вернуть в активный список`,
                `Disabled (${disabledSids.length}) — toggle switch on card to restore to active list`,
              ),
            ),
          ]),
          E(
            'span',
            { class: 'tachyon-studio-disabled-tray__count' },
            String(disabledSids.length),
          ),
        ],
      );
      disabledTrayEl.appendChild(trayHeaderBtn);
      disabledTrayEl.appendChild(trayBodyEl);
    }
  };

  const renderEntityCard = (
    sid: string,
    orderIndex: number,
    totalCount: number,
  ): HTMLElement => {
    const raw = uci.get(UCI_PACKAGE, sid) || {};
    const enabled = raw.enabled !== '0';

    const attachDragAndOrderHandlers = (card: HTMLElement) => {
      card.setAttribute('draggable', 'true');
      card.addEventListener('dragstart', (ev: DragEvent) => {
        draggedSid = sid;
        card.classList.add('is-dragging');
        if (ev.dataTransfer) {
          ev.dataTransfer.effectAllowed = 'move';
          ev.dataTransfer.setData('text/plain', sid);
        }
      });
      card.addEventListener('dragend', () => {
        draggedSid = null;
        card.classList.remove('is-dragging');
        panelEl
          .querySelectorAll('.is-drag-over')
          .forEach((el) => el.classList.remove('is-drag-over'));
      });
      card.addEventListener('dragover', (ev: DragEvent) => {
        if (!draggedSid || draggedSid === sid) return;
        ev.preventDefault();
        card.classList.add('is-drag-over');
      });
      card.addEventListener('dragleave', () => {
        card.classList.remove('is-drag-over');
      });
      card.addEventListener('drop', (ev: DragEvent) => {
        ev.preventDefault();
        card.classList.remove('is-drag-over');
        if (!draggedSid || draggedSid === sid) return;
        try {
          if (typeof (uci as any).move === 'function') {
            (uci as any).move(UCI_PACKAGE, draggedSid, sid);
            notifyUciChanged();
            renderDeck();
          }
        } catch {
          // ignore
        }
      });
    };

    const renderOrderControls = () =>
      E('div', { class: 'tachyon-studio-card__order' }, [
        E(
          'span',
          {
            class: 'tachyon-studio-card__priority-badge',
            title: tr(
              'Перетащите для изменения приоритета',
              'Drag to reorder priority',
            ),
          },
          `⋮⋮ #${orderIndex}`,
        ),
        E(
          'button',
          {
            type: 'button',
            class: 'tachyon-studio-order-btn',
            disabled: orderIndex <= 1 ? 'disabled' : null,
            title: tr('Выше по приоритету', 'Move Up (Higher Priority)'),
            click: (ev: MouseEvent) => {
              ev.preventDefault();
              ev.stopPropagation();
              moveUciSectionOrder(
                sectionRef.sectiontype || type,
                sid,
                -1,
                renderDeck,
              );
            },
          },
          '↑',
        ),
        E(
          'button',
          {
            type: 'button',
            class: 'tachyon-studio-order-btn',
            disabled: orderIndex >= totalCount ? 'disabled' : null,
            title: tr('Ниже по приоритету', 'Move Down (Lower Priority)'),
            click: (ev: MouseEvent) => {
              ev.preventDefault();
              ev.stopPropagation();
              moveUciSectionOrder(
                sectionRef.sectiontype || type,
                sid,
                1,
                renderDeck,
              );
            },
          },
          '↓',
        ),
      ]);

    const openEditModal = (ev?: Event) => {
      if (ev) {
        ev.preventDefault();
        ev.stopPropagation();
      }
      if (typeof sectionRef.renderMoreOptionsModal === 'function') {
        pendingUciSaveChain.finally(() => {
          sanitizeStaleUciDeletes(sid);
          sectionRef.renderMoreOptionsModal(sid);
        });
      }
    };

    const handleDelete = (ev: Event) => {
      ev.preventDefault();
      ev.stopPropagation();
      const doCleanup = () => {
        try {
          if (typeof uci.remove === 'function' && uci.get(UCI_PACKAGE, sid)) {
            uci.remove(UCI_PACKAGE, sid);
          }
        } catch {
          // ignore
        }
        try {
          const escaped =
            typeof CSS !== 'undefined' && typeof CSS.escape === 'function'
              ? CSS.escape(sid)
              : sid.replace(/["\\]/g, '\\$&');
          const cbiRows = containerEl.querySelectorAll(
            `#cbi-${UCI_PACKAGE}-${escaped}, [data-section-id="${escaped}"]`,
          );
          cbiRows.forEach((row) => {
            if (!row.closest('.tachyon-studio-deck')) {
              row.remove();
            }
          });
        } catch {
          // ignore
        }
        notifyUciChanged();
        renderDeck();
      };
      if (typeof sectionRef.remove === 'function') {
        Promise.resolve(sectionRef.remove(sid)).finally(doCleanup);
      } else {
        doCleanup();
      }
    };

    // ── CASE 1: ROUTING SECTION ─────────────────────────────────────────────
    if (type === 'section') {
      const tel = resolveSectionTelemetry(sid);
      const renderSectionFallbackIcon = () => {
        const keyLower = `${sid} ${tel.name}`.toLowerCase();
        if (keyLower.includes('youtube') || keyLower.includes('yt')) {
          return renderPlayIcon(20);
        } else if (keyLower.includes('discord')) {
          return renderGamepad2Icon(20);
        } else if (keyLower.includes('tele') || keyLower.includes('tg')) {
          return renderPlaneIcon(20);
        } else if (tel.actionTone === 'block' || keyLower.includes('block')) {
          return renderBanIcon(20);
        } else if (tel.actionTone === 'bypass' || keyLower.includes('bypass')) {
          return renderArrowUpRightIcon(20);
        } else if (tel.actionTone === 'dns' || keyLower.includes('dns')) {
          return renderCompassIcon(20);
        } else if (keyLower.includes('main') || keyLower.includes('основн')) {
          return renderZapIcon(20);
        } else if (keyLower.includes('fptn')) {
          return renderShieldIcon(20);
        }
        return renderGlobeIcon(20);
      };

      const iconContent = tel.faviconDomain
        ? E('img', {
            src: `https://www.google.com/s2/favicons?domain=${encodeURIComponent(tel.faviconDomain)}&sz=64`,
            alt: '',
            class: 'tachyon-studio-card__favicon',
            error: (ev: Event) => {
              const img = ev.currentTarget as HTMLElement;
              if (img && img.parentElement) {
                img.parentElement.replaceChildren(renderSectionFallbackIcon());
              }
            },
          })
        : renderSectionFallbackIcon();

      const badgeEls: HTMLElement[] = [
        E(
          'span',
          {
            class: `tachyon-studio-badge tachyon-studio-badge--${tel.actionTone}`,
          },
          tel.actionLabel,
        ),
      ];
      tel.protocols.forEach((p) => {
        badgeEls.push(
          E(
            'span',
            { class: 'tachyon-studio-badge tachyon-studio-badge--proto' },
            p,
          ),
        );
      });
      tel.transports.forEach((t) => {
        badgeEls.push(
          E(
            'span',
            { class: 'tachyon-studio-badge tachyon-studio-badge--transport' },
            t,
          ),
        );
      });

      const condChips =
        tel.conditions.length > 0
          ? tel.conditions.map((c) =>
              E(
                'button',
                {
                  type: 'button',
                  class: 'tachyon-studio-chip tachyon-studio-chip--cond',
                  title: tr(
                    `Открыть условие «${c.name}»`,
                    `Open condition "${c.name}"`,
                  ),
                  click: (ev: MouseEvent) => {
                    ev.preventDefault();
                    ev.stopPropagation();
                    if (onNavigateSubTab) onNavigateSubTab('conditions', c.id);
                  },
                },
                [
                  renderCommunityListServiceIcon(c.name, 11),
                  E('span', {}, c.name),
                ],
              ),
            )
          : tel.serviceTags.length > 0
            ? tel.serviceTags.map((t) =>
                E(
                  'span',
                  { class: 'tachyon-studio-chip tachyon-studio-chip--cond' },
                  [renderCommunityListServiceIcon(t, 11), E('span', {}, t)],
                ),
              )
            : [
                E(
                  'span',
                  { class: 'tachyon-studio-chip tachyon-studio-chip--muted' },
                  tr('Встроенные правила секции', 'Section rules'),
                ),
              ];

      const outChips: HTMLElement[] = [];
      tel.sources.forEach((s) => {
        outChips.push(
          E(
            'button',
            {
              type: 'button',
              class: 'tachyon-studio-chip tachyon-studio-chip--source',
              title: tr(
                `Открыть подключение «${s.name}»`,
                `Open connection "${s.name}"`,
              ),
              click: (ev: MouseEvent) => {
                ev.preventDefault();
                ev.stopPropagation();
                if (onNavigateSubTab) onNavigateSubTab('outbounds', s.id);
              },
            },
            [renderRadioIcon(11), E('span', {}, s.name)],
          ),
        );
      });
      tel.balancers.forEach((b) => {
        outChips.push(
          E(
            'button',
            {
              type: 'button',
              class: 'tachyon-studio-chip tachyon-studio-chip--balancer',
              title: tr(
                `Открыть балансировщик «${b.name}»`,
                `Open balancer "${b.name}"`,
              ),
              click: (ev: MouseEvent) => {
                ev.preventDefault();
                ev.stopPropagation();
                if (onNavigateSubTab) onNavigateSubTab('balancers', b.id);
              },
            },
            [renderScaleIcon(11), E('span', {}, `${b.name} (${b.type})`)],
          ),
        );
      });
      if (!outChips.length) {
        const fallbackContent =
          tel.actionTone === 'block'
            ? [
                renderBanIcon(11),
                E('span', {}, tr('Блокировка (Reject)', 'Block (Reject)')),
              ]
            : tel.actionTone === 'bypass'
              ? [
                  renderArrowUpRightIcon(11),
                  E('span', {}, tr('Прямой выход (WAN)', 'Direct (WAN)')),
                ]
              : tel.actionTone === 'dns'
                ? [
                    renderCompassIcon(11),
                    E('span', {}, raw.routed_dns_server || 'DNS'),
                  ]
                : [E('span', {}, tr('Встроенный выход', 'Built-in output'))];

        outChips.push(
          E(
            'span',
            { class: 'tachyon-studio-chip tachyon-studio-chip--muted' },
            fallbackContent,
          ),
        );
      }

      const card = E(
        'div',
        {
          class: `tachyon-studio-card tachyon-studio-card--section ${enabled ? 'is-enabled' : 'is-disabled'}`,
          'data-sid': sid,
        },
        [
          E('div', { class: 'tachyon-studio-card__head' }, [
            E('div', { class: 'tachyon-studio-card__identity' }, [
              renderOrderControls(),
              E(
                'div',
                {
                  class: 'tachyon-studio-card__icon is-clickable',
                  style: `background:${tel.iconBg};color:${tel.iconColor};cursor:pointer;`,
                  title: tr(
                    'Нажмите, чтобы выбрать иконку секции',
                    'Click to choose section icon',
                  ),
                  click: (ev: MouseEvent) => {
                    ev.preventDefault();
                    ev.stopPropagation();
                    openSectionIconPickerModal(
                      {
                        code: sid,
                        sectionName: sid,
                        displayName: tel.name,
                        action: tel.action,
                        outbounds: [],
                      } as any,
                      () => {
                        notifyUciChanged();
                        renderDeck();
                      },
                    );
                  },
                },
                [iconContent],
              ),
              E('div', { class: 'tachyon-studio-card__title-wrap' }, [
                E('div', { class: 'tachyon-studio-card__title-row' }, [
                  E('span', { class: 'tachyon-studio-card__title' }, tel.name),
                  ...badgeEls,
                ]),
                E(
                  'div',
                  { class: 'tachyon-studio-card__sid' },
                  `ID: ${sid} • ${tel.serviceTags.length ? tel.serviceTags.slice(0, 5).join(', ') : tel.actionLabel}`,
                ),
              ]),
            ]),
            E('div', { class: 'tachyon-studio-card__head-right' }, [
              createStudioToggleSwitch(sid, enabled, sectionRef, renderDeck),
            ]),
          ]),
          E('div', { class: 'tachyon-studio-card__pipeline' }, [
            E('div', { class: 'tachyon-studio-card__pipe-stage' }, [
              E(
                'span',
                { class: 'tachyon-studio-card__pipe-label' },
                tr('Условия трафика', 'Conditions'),
              ),
              E('div', { class: 'tachyon-studio-card__chips' }, condChips),
            ]),
            E('span', { class: 'tachyon-studio-card__pipe-arrow' }, '➔'),
            E('div', { class: 'tachyon-studio-card__pipe-stage' }, [
              E(
                'span',
                { class: 'tachyon-studio-card__pipe-label' },
                tr('Соединение и балансировка', 'Connection & Balancer'),
              ),
              E('div', { class: 'tachyon-studio-card__chips' }, outChips),
            ]),
          ]),
          E('div', { class: 'tachyon-studio-card__footer' }, [
            E(
              'button',
              {
                type: 'button',
                class: 'tachyon-studio-action-btn',
                click: (ev: MouseEvent) => {
                  ev.preventDefault();
                  ev.stopPropagation();
                  if (onShowSectionRules) onShowSectionRules(sid);
                },
              },
              [renderFileTextIcon(13), E('span', {}, tr('Правила', 'Rules'))],
            ),
            E(
              'button',
              {
                type: 'button',
                class: 'tachyon-studio-action-btn',
                title: tr('Клонировать секцию', 'Clone Section'),
                click: (ev: MouseEvent) => {
                  ev.preventDefault();
                  ev.stopPropagation();
                  if (onCloneSection) {
                    const cloned = onCloneSection(sid);
                    if (cloned) {
                      notifyUciChanged();
                      renderDeck();
                    }
                  }
                },
              },
              [renderCopyIcon(13), E('span', {}, tr('Клон', 'Clone'))],
            ),
            E(
              'button',
              {
                type: 'button',
                class:
                  'tachyon-studio-action-btn tachyon-studio-action-btn--primary',
                click: openEditModal,
              },
              [
                renderSettingsIcon(13),
                E('span', {}, tr('Изменить', 'Configure')),
              ],
            ),
            E(
              'button',
              {
                type: 'button',
                class:
                  'tachyon-studio-action-btn tachyon-studio-action-btn--danger',
                title: tr('Удалить', 'Delete'),
                click: handleDelete,
              },
              [renderTrashIcon(13)],
            ),
          ]),
        ],
      );
      attachDragAndOrderHandlers(card);
      return card;
    }

    // ── CASE 2: OUTBOUND SOURCE (Two-Layer Compact Row + Expandable Inspector) ─
    if (type === 'outbound_source') {
      const name = raw.name || raw.label || sid;
      const stype = String(raw.source_type || 'subscription').toLowerCase();
      const isDpiSource = [
        'desync',
        'zapret',
        'zapret2',
        'byedpi',
        'wdtt',
        'olcrtc',
      ].includes(stype);
      const usedIn = (uci.sections(UCI_PACKAGE, 'section') || [])
        .filter((s: any) => asArray(s.outbound_source_refs).includes(sid))
        .map((s: any) => ({
          id: s['.name'],
          name: s.label || s.name || s['.name'],
        }));
      const usedInGroups = !isDpiSource
        ? (uci.sections(UCI_PACKAGE, 'outbound_group') || [])
            .filter((g: any) => {
              const grefs = asArray(g.source_refs);
              return grefs.length === 0 || grefs.includes(sid);
            })
            .map((g: any) => ({
              id: g['.name'],
              name: g.name || g.label || g['.name'],
              explicit: asArray(g.source_refs).includes(sid),
            }))
        : [];

      const rawSubName = String(raw.name || '').trim();
      const subUrl = String(
        raw.url ||
          (stype === 'subscription' && /^https?:\/\//i.test(rawSubName)
            ? rawSubName
            : ''),
      ).trim();
      const resolveSubscriptionCache = (): SubCacheEntryInfo | undefined => {
        if (stype !== 'subscription') return undefined;
        const fromUrl = subUrl ? subCacheByUrl.get(subUrl) : undefined;
        if (fromUrl && (fromUrl.servers.length > 0 || fromUrl.metadata)) {
          return fromUrl;
        }
        const fromSid = subCacheBySid.get(sid);
        if (fromSid && (fromSid.servers.length > 0 || fromSid.metadata)) {
          return fromSid;
        }
        try {
          const storeMod = (globalThis as any).tachyonStore || null;
          const sectionsObj =
            storeMod && typeof storeMod.get === 'function'
              ? storeMod.get()?.connectionsWidget?.data?.sections || {}
              : {};
          const prefix =
            raw.prefix_nodes !== '0' && raw.node_prefix
              ? String(raw.node_prefix).trim()
              : '';
          const srcTitle = String(raw.name || raw.label || sid).trim();
          const allSubCount = (
            uci.sections(UCI_PACKAGE, 'outbound_source') || []
          ).filter(
            (s: any) =>
              s &&
              (s.source_type || s.type || 'subscription') === 'subscription',
          ).length;
          const singleSub = allSubCount === 1;
          const srvMap = new Map<string, SubCacheServerItem>();
          let foundMeta: SubCacheEntryInfo['metadata'] = undefined;

          for (const sec of Object.values(sectionsObj) as any[]) {
            const subInfos = Array.isArray(sec?.subscriptionInfos)
              ? sec.subscriptionInfos
              : [];
            for (const si of subInfos) {
              if (!si || typeof si !== 'object') continue;
              const siTitle = String(si.title || '').trim();
              if (
                singleSub ||
                (prefix && siTitle.toLowerCase() === prefix.toLowerCase()) ||
                (srcTitle && siTitle.toLowerCase() === srcTitle.toLowerCase())
              ) {
                foundMeta = {
                  title: siTitle || undefined,
                  traffic: si.traffic,
                  expire: si.expire,
                  webPageUrl: si.webPageUrl,
                  supportUrl: si.supportUrl,
                  announce: si.announce,
                };
              }
            }
            const obs = Array.isArray(sec?.outbounds) ? sec.outbounds : [];
            for (const ob of obs) {
              if (!ob || ob.urlTestInfo || ob.priorityInfo) continue;
              const code = String(ob.code || '');
              if (
                !code ||
                code === 'direct-out' ||
                code === 'block-out' ||
                code.endsWith('-urltest-out') ||
                code.endsWith('-priority-out')
              ) {
                continue;
              }
              const obPrefix = String(ob.prefix || ob.sourceGroup || '').trim();
              const disp = String(ob.displayName || ob.name || code).trim();
              const link = String(ob.link || '').trim();
              const obType = String(ob.type || '').toUpperCase();
              if (
                obType === 'URLTEST' ||
                obType === 'SELECTOR' ||
                obType === 'DIRECT' ||
                obType === 'DPI'
              ) {
                continue;
              }
              let matches = false;
              let cleanName = disp;
              if (prefix) {
                if (obPrefix.toLowerCase() === prefix.toLowerCase()) {
                  matches = true;
                } else if (disp.startsWith(`${prefix}: `)) {
                  matches = true;
                  cleanName = disp.slice(prefix.length + 2).trim();
                } else if (disp.startsWith(`${prefix} `)) {
                  matches = true;
                  cleanName = disp.slice(prefix.length + 1).trim();
                }
              } else if (singleSub) {
                matches = true;
              }
              if (matches && cleanName && !srvMap.has(cleanName)) {
                const proto =
                  obType ||
                  (link.includes('://')
                    ? link.split('://')[0].toUpperCase()
                    : 'PROXY');
                const trans = link.includes('://')
                  ? (getProxyUrlTransport(link) || 'TCP').toUpperCase()
                  : '';
                srvMap.set(cleanName, {
                  name: cleanName,
                  proto,
                  trans,
                  link,
                });
              }
            }
          }
          if (srvMap.size > 0 || foundMeta) {
            return {
              mtime: fromUrl?.mtime || fromSid?.mtime || 0,
              servers: Array.from(srvMap.values()),
              metadata: foundMeta,
            };
          }
        } catch {
          // ignore store lookup errors
        }
        return fromUrl || fromSid;
      };
      const subCache = resolveSubscriptionCache();

      const formatBytes = (bytes?: number) => {
        const b = Number(bytes || 0);
        if (!Number.isFinite(b) || b <= 0) return '0 B';
        const gb = b / (1024 * 1024 * 1024);
        if (gb >= 1) return `${gb.toFixed(1)} GB`;
        const mb = b / (1024 * 1024);
        return `${mb.toFixed(0)} MB`;
      };

      const formatUpdatedTime = (epochSec?: number) => {
        const ts = Number(epochSec || 0);
        if (!ts || ts <= 0) return '';
        try {
          const d = new Date(ts * 1000);
          return d.toLocaleString([], {
            day: '2-digit',
            month: '2-digit',
            hour: '2-digit',
            minute: '2-digit',
          });
        } catch (_e) {
          return '';
        }
      };

      const links = extractSourceLinks(raw);
      const parsedLinks = extractLinkProtocolsAndTransports(links);
      const fptnParsed =
        stype === 'fptn' ? parseFptnTokenInfo(raw.access_token) : null;
      const fptnServers =
        stype === 'fptn'
          ? fptnParsed?.servers.length
            ? fptnParsed.servers
            : subCache?.servers || []
          : [];

      const typeBadges: HTMLElement[] = [];
      let iconEl: SVGElement = renderRadioIcon(18);
      let tone: 'proxy' | 'dpi' | 'bypass' = 'proxy';
      if (stype === 'subscription') {
        iconEl = renderRadioIcon(18);
        typeBadges.push(
          E(
            'span',
            { class: 'tachyon-studio-badge tachyon-studio-badge--proxy' },
            tr('ПОДПИСКА', 'SUBSCRIPTION'),
          ),
        );
        if (subCache && subCache.servers.length > 0) {
          typeBadges.push(
            E(
              'span',
              { class: 'tachyon-studio-badge tachyon-studio-badge--proto' },
              `${tr('Узлов', 'Nodes')}: ${subCache.servers.length}`,
            ),
          );
        }
        const autoUpd = raw.subscription_update_enabled !== '0';
        const updInt = String(raw.subscription_update_interval || '1h').trim();
        typeBadges.push(
          E(
            'span',
            { class: 'tachyon-studio-badge tachyon-studio-badge--transport' },
            autoUpd
              ? `⟳ ${updInt}`
              : tr('Автообновление: Выкл', 'Auto-update: Off'),
          ),
        );
        if (
          raw.download_via_proxy_enabled === '1' &&
          raw.download_via_proxy_section
        ) {
          const dlSec = uci.get(
            UCI_PACKAGE,
            String(raw.download_via_proxy_section),
          );
          const dlLabel =
            dlSec?.label ||
            dlSec?.name ||
            String(raw.download_via_proxy_section);
          typeBadges.push(
            E(
              'span',
              { class: 'tachyon-studio-badge tachyon-studio-badge--proto' },
              `${tr('Через', 'Via')}: ${dlLabel}`,
            ),
          );
        }
        if (subCache?.metadata?.traffic) {
          const tf = subCache.metadata.traffic;
          const quotaText = tf.isUnlimited
            ? '∞'
            : tf.total
              ? `${formatBytes(tf.used)} / ${formatBytes(tf.total)}`
              : formatBytes(tf.used);
          typeBadges.push(
            E(
              'span',
              { class: 'tachyon-studio-badge tachyon-studio-badge--transport' },
              [renderActivityIcon(10), E('span', {}, ` ${quotaText}`)],
            ),
          );
        }
        const updBadgeTime = formatUpdatedTime(
          subCache?.mtime || (subCache?.metadata as any)?.updatedAt,
        );
        if (updBadgeTime) {
          typeBadges.push(
            E(
              'span',
              {
                class: 'tachyon-studio-badge tachyon-studio-badge--transport',
                title: `${tr('Последнее обновление кэша подписки', 'Subscription cache last updated')}: ${updBadgeTime}`,
              },
              `${tr('Обновлено', 'Updated')}: ${updBadgeTime}`,
            ),
          );
        }
      } else if (stype === 'proxy_links') {
        iconEl = renderLinkIcon(18);
        typeBadges.push(
          E(
            'span',
            { class: 'tachyon-studio-badge tachyon-studio-badge--proxy' },
            `${tr('ССЫЛКИ', 'LINKS')}: ${links.length || 1}`,
          ),
        );
        parsedLinks.protocols.forEach((p) =>
          typeBadges.push(
            E(
              'span',
              { class: 'tachyon-studio-badge tachyon-studio-badge--proto' },
              p,
            ),
          ),
        );
        parsedLinks.transports.forEach((t) =>
          typeBadges.push(
            E(
              'span',
              { class: 'tachyon-studio-badge tachyon-studio-badge--transport' },
              t,
            ),
          ),
        );
      } else if (isDpiSource) {
        iconEl = renderShieldIcon(18);
        tone = 'dpi';
        const preset = raw.desync_preset || 'auto';
        typeBadges.push(
          E(
            'span',
            { class: 'tachyon-studio-badge tachyon-studio-badge--dpi' },
            `${stype.toUpperCase()} (${preset})`,
          ),
        );
      } else if (stype === 'fptn') {
        iconEl = renderRocketIcon(18);
        tone = 'bypass';
        typeBadges.push(
          E(
            'span',
            { class: 'tachyon-studio-badge tachyon-studio-badge--proxy' },
            'FPTN',
          ),
        );
        if (fptnServers.length > 0) {
          typeBadges.push(
            E(
              'span',
              { class: 'tachyon-studio-badge tachyon-studio-badge--proto' },
              `${tr('Узлов', 'Nodes')}: ${fptnServers.length}`,
            ),
          );
        }
        if (raw.bypass_method) {
          typeBadges.push(
            E(
              'span',
              { class: 'tachyon-studio-badge tachyon-studio-badge--transport' },
              String(raw.bypass_method).toUpperCase(),
            ),
          );
        }
      } else {
        iconEl = renderRocketIcon(18);
        tone = 'bypass';
        typeBadges.push(
          E(
            'span',
            { class: 'tachyon-studio-badge tachyon-studio-badge--proto' },
            stype.toUpperCase(),
          ),
        );
      }

      if (raw.node_prefix && raw.prefix_nodes !== '0') {
        typeBadges.push(
          E(
            'span',
            { class: 'tachyon-studio-badge tachyon-studio-badge--transport' },
            [renderTagIcon(10), E('span', {}, raw.node_prefix)],
          ),
        );
      }

      let paramSummary = '';
      if (stype === 'subscription') {
        const u = subUrl;
        const shortU =
          u.length > 52
            ? `${u.slice(0, 34)}…${u.slice(-12)}`
            : u || tr('URL не указан', 'No URL configured');
        const effectiveMtime = Math.max(
          Number(subCache?.mtime || 0),
          Number(subCache?.metadata?.updatedAt || 0),
        );
        const updStr =
          effectiveMtime > 0
            ? ` • ${tr('Обновлено', 'Updated')}: ${formatUpdatedTime(effectiveMtime)}`
            : '';
        paramSummary = `${shortU}${updStr}`;
      } else if (stype === 'proxy_links') {
        paramSummary = `${tr('Узлов', 'Nodes')}: ${links.length}${parsedLinks.protocols.length ? ` (${parsedLinks.protocols.join(', ')})` : ''}`;
      } else if (stype === 'fptn') {
        const tok = String(raw.access_token || '');
        const srvCountStr = fptnServers.length
          ? `${tr('Узлов', 'Nodes')}: ${fptnServers.length}`
          : '';
        const svcStr = fptnParsed?.serviceName
          ? `FPTN (${fptnParsed.serviceName})`
          : tok
            ? `FPTN: ${tok.slice(0, 26)}…`
            : 'FPTN VPN';
        paramSummary = srvCountStr ? `${svcStr} • ${srvCountStr}` : svcStr;
      } else if (stype === 'desync') {
        paramSummary = `Desync (${raw.desync_preset || 'auto'})`;
      } else {
        paramSummary = stype.toUpperCase();
      }

      const sectionChips = usedIn.length
        ? usedIn.map((u: any) =>
            E(
              'button',
              {
                type: 'button',
                class: 'tachyon-studio-chip tachyon-studio-chip--section',
                title: tr(
                  `Открыть секцию «${u.name}»`,
                  `Open section "${u.name}"`,
                ),
                click: (ev: MouseEvent) => {
                  ev.preventDefault();
                  ev.stopPropagation();
                  if (onNavigateSubTab) {
                    onNavigateSubTab('sections', u.id);
                  }
                },
              },
              [renderSubRouteIcon(11), E('span', {}, u.name)],
            ),
          )
        : [
            E(
              'span',
              {
                class: 'tachyon-studio-chip tachyon-studio-chip--muted',
                title: tr(
                  'Источник находится в глобальном пуле и не привязан напрямую к конкретной секции',
                  'Source is in the global pool and not attached directly to a specific section',
                ),
              },
              tr('В пуле', 'In pool'),
            ),
          ];

      const groupChips = usedInGroups.map((g: any) =>
        E(
          'span',
          {
            class: 'tachyon-studio-chip tachyon-studio-chip--balancer',
            title: g.explicit
              ? `${tr('В группе серверов', 'In Outbound Group')}: ${g.name}`
              : `${tr('Доступен в группе (все источники)', 'Included in Group (all sources)')}: ${g.name}`,
          },
          [renderTagIcon(11), E('span', {}, g.name)],
        ),
      );

      const copyProxyLinkToClipboard = (linkStr: string, btn: HTMLElement) => {
        if (!linkStr) return;
        const origTitle = btn.getAttribute('title') || '';
        const doFeedback = () => {
          btn.classList.add('is-copied');
          btn.setAttribute('title', tr('Скопировано!', 'Copied!'));
          window.setTimeout(() => {
            btn.classList.remove('is-copied');
            btn.setAttribute('title', origTitle);
          }, 1500);
        };
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard
            .writeText(linkStr)
            .then(doFeedback)
            .catch(() => {
              const ta = document.createElement('textarea');
              ta.value = linkStr;
              document.body.appendChild(ta);
              ta.select();
              document.execCommand('copy');
              ta.remove();
              doFeedback();
            });
        } else {
          const ta = document.createElement('textarea');
          ta.value = linkStr;
          document.body.appendChild(ta);
          ta.select();
          document.execCommand('copy');
          ta.remove();
          doFeedback();
        }
      };

      const lookupLiveLinkByName = (srvName: string): string => {
        try {
          const storeMod = (globalThis as any).tachyonStore || null;
          const sectionsObj =
            storeMod && typeof storeMod.get === 'function'
              ? storeMod.get()?.connectionsWidget?.data?.sections || {}
              : {};
          for (const sec of Object.values(sectionsObj) as any[]) {
            const obs = Array.isArray(sec?.outbounds) ? sec.outbounds : [];
            for (const ob of obs) {
              const n = String(ob?.displayName || ob?.name || '').trim();
              if (
                (n === srvName || n.endsWith(` ${srvName}`)) &&
                ob?.link &&
                String(ob.link).includes('://')
              ) {
                return String(ob.link);
              }
            }
          }
        } catch {
          // ignore
        }
        return '';
      };

      const renderCompactServersTable = (
        items: { name: string; proto: string; trans?: string; link?: string }[],
      ) => {
        let sortCol: 'idx' | 'name' | 'proto' = 'idx';
        let sortDir: 'asc' | 'desc' = 'asc';
        const tbody = E('tbody', {});
        const thIndicators = new Map<'idx' | 'name' | 'proto', HTMLElement>();

        const indexedItems = items.map((srv, idx) => ({
          ...srv,
          origIdx: idx,
          badge:
            srv.trans && srv.trans !== srv.proto
              ? `${srv.proto} • ${srv.trans}`
              : srv.proto,
        }));

        const populateRows = () => {
          thIndicators.forEach((ind, col) => {
            ind.textContent =
              sortCol === col ? (sortDir === 'asc' ? ' ▲' : ' ▼') : '';
          });

          const sorted = [...indexedItems].sort((a, b) => {
            let cmp = 0;
            if (sortCol === 'idx') {
              cmp = a.origIdx - b.origIdx;
            } else if (sortCol === 'name') {
              cmp = a.name.localeCompare(b.name, 'ru');
            } else if (sortCol === 'proto') {
              cmp = a.badge.localeCompare(b.badge, 'ru');
            }
            return sortDir === 'asc' ? cmp : -cmp;
          });

          tbody.replaceChildren(
            ...sorted.map((srv) => {
              const resolvedLink = srv.link || lookupLiveLinkByName(srv.name);
              const displaySrvName = ensureOutboundDisplayFlag({
                displayName: srv.name,
              });
              return E('tr', {}, [
                E(
                  'td',
                  { class: 'tachyon-studio-server-table__idx' },
                  String(srv.origIdx + 1),
                ),
                E(
                  'td',
                  { class: 'tachyon-studio-server-table__name' },
                  renderFlagEmojis(displaySrvName),
                ),
                E('td', { class: 'tachyon-studio-server-table__proto' }, [
                  E(
                    'span',
                    {
                      class: 'tachyon-studio-badge tachyon-studio-badge--proto',
                    },
                    srv.badge,
                  ),
                ]),
                E(
                  'td',
                  {
                    class: 'tachyon-studio-server-table__actions',
                    style: 'text-align:right;',
                  },
                  resolvedLink
                    ? [
                        E(
                          'button',
                          {
                            type: 'button',
                            class:
                              'tachyon-studio-action-btn tachyon-studio-copy-link-btn',
                            title: tr(
                              'Скопировать ссылку на прокси (Copy proxy link)',
                              'Copy proxy link',
                            ),
                            click: (ev: MouseEvent) => {
                              ev.preventDefault();
                              ev.stopPropagation();
                              copyProxyLinkToClipboard(
                                resolvedLink,
                                ev.currentTarget as HTMLElement,
                              );
                            },
                          },
                          [
                            renderCopyIcon(12),
                            E('span', {}, tr('Копировать', 'Copy link')),
                          ],
                        ),
                      ]
                    : [E('span', { style: 'opacity:0.45;' }, '—')],
                ),
              ]);
            }),
          );
        };

        const makeTh = (col: 'idx' | 'name' | 'proto', label: string) => {
          const ind = E('span', { style: 'font-size: 10px; opacity: 0.75;' });
          thIndicators.set(col, ind);
          return E(
            'th',
            {
              style: 'cursor: pointer; user-select: none;',
              click: (e: MouseEvent) => {
                e.preventDefault();
                e.stopPropagation();
                if (sortCol === col) {
                  sortDir = sortDir === 'asc' ? 'desc' : 'asc';
                } else {
                  sortCol = col;
                  sortDir = 'asc';
                }
                populateRows();
              },
            },
            [E('span', {}, label), ind],
          );
        };

        const tableEl = E('table', { class: 'tachyon-studio-server-table' }, [
          E('thead', {}, [
            E('tr', {}, [
              makeTh('idx', '#'),
              makeTh('name', tr('Сервер', 'Server')),
              makeTh('proto', tr('Протокол', 'Protocol')),
              E(
                'th',
                { style: 'text-align:right;' },
                tr('Ссылка', 'Proxy Link'),
              ),
            ]),
          ]),
          tbody,
        ]);

        populateRows();
        return E('div', { class: 'tachyon-studio-server-table-wrap' }, [
          tableEl,
        ]);
      };

      const inspectorRows: HTMLElement[] = [];
      if (stype === 'subscription') {
        if (subUrl) {
          inspectorRows.push(
            E('div', { class: 'tachyon-studio-source-inspector__row' }, [
              E(
                'span',
                { class: 'tachyon-studio-source-inspector__label' },
                'URL:',
              ),
              E(
                'span',
                {
                  class:
                    'tachyon-studio-source-inspector__val tachyon-studio-source-inspector__val--mono',
                  style: 'word-break: break-all;',
                },
                subUrl,
              ),
            ]),
          );
        }
        const effectiveMtime =
          subCache?.mtime || (subCache?.metadata as any)?.updatedAt || 0;
        if (subCache?.metadata || effectiveMtime > 0) {
          const md = subCache?.metadata || {};
          const infoParts: string[] = [];
          if (md.title)
            infoParts.push(`${tr('Провайдер', 'Title')}: ${md.title}`);
          if (md.traffic) {
            const q = md.traffic.isUnlimited
              ? tr('Безлимит (∞)', 'Unlimited (∞)')
              : md.traffic.total
                ? `${formatBytes(md.traffic.used)} / ${formatBytes(md.traffic.total)}`
                : formatBytes(md.traffic.used);
            infoParts.push(`${tr('Трафик', 'Traffic')}: ${q}`);
          }
          if (md.expire && Number(md.expire) > 0) {
            try {
              const expDate = new Date(
                Number(md.expire) * 1000,
              ).toLocaleDateString();
              infoParts.push(`${tr('Истекает', 'Expires')}: ${expDate}`);
            } catch (_e) {
              // ignore invalid date
            }
          }
          if (effectiveMtime > 0) {
            const updText = formatUpdatedTime(effectiveMtime);
            if (updText) {
              infoParts.push(`${tr('Обновлено', 'Updated')}: ${updText}`);
            }
          }
          if (infoParts.length > 0) {
            inspectorRows.push(
              E('div', { class: 'tachyon-studio-source-inspector__row' }, [
                E(
                  'span',
                  { class: 'tachyon-studio-source-inspector__label' },
                  tr('Подписка:', 'Subscription Info:'),
                ),
                E(
                  'span',
                  { class: 'tachyon-studio-source-inspector__val' },
                  infoParts.join(' • '),
                ),
              ]),
            );
          }
          if (md.announce && String(md.announce).trim()) {
            const rawAnnounce = String(md.announce).trim();
            const lines = rawAnnounce
              .split(/\r?\n/)
              .map((l) => l.trim())
              .filter(Boolean);
            const firstLine = lines[0] || rawAnnounce;
            const isCollapsible = lines.length > 1 || rawAnnounce.length > 110;
            const previewText =
              firstLine.length > 110
                ? `${firstLine.slice(0, 110)}…`
                : lines.length > 1
                  ? `${firstLine} …`
                  : firstLine;
            let expanded = false;
            const textSpan = E(
              'span',
              { style: 'white-space: pre-line;' },
              isCollapsible ? previewText : rawAnnounce,
            );
            const toggleBtn = isCollapsible
              ? E(
                  'span',
                  {
                    style:
                      'margin-left: 6px; font-size: 11px; opacity: 0.75; text-decoration: underline; cursor: pointer; white-space: nowrap;',
                  },
                  tr('Ещё', 'Show more'),
                )
              : null;
            inspectorRows.push(
              E('div', { class: 'tachyon-studio-source-inspector__row' }, [
                E(
                  'span',
                  { class: 'tachyon-studio-source-inspector__label' },
                  tr('Объявление:', 'Announcement:'),
                ),
                E(
                  'span',
                  {
                    class: 'tachyon-studio-source-inspector__val',
                    style: isCollapsible ? 'cursor: pointer;' : '',
                    title: isCollapsible ? rawAnnounce : undefined,
                    click: isCollapsible
                      ? (ev: MouseEvent) => {
                          ev.stopPropagation();
                          expanded = !expanded;
                          textSpan.textContent = expanded
                            ? rawAnnounce
                            : previewText;
                          if (toggleBtn) {
                            toggleBtn.textContent = expanded
                              ? tr('Свернуть', 'Hide')
                              : tr('Ещё', 'Show more');
                          }
                        }
                      : undefined,
                  },
                  toggleBtn ? [textSpan, toggleBtn] : [textSpan],
                ),
              ]),
            );
          }
        }

        if (subCache && subCache.servers.length > 0) {
          inspectorRows.push(
            E(
              'div',
              {
                class:
                  'tachyon-studio-source-inspector__row tachyon-studio-source-inspector__row--block',
              },
              [
                E(
                  'span',
                  { class: 'tachyon-studio-source-inspector__label' },
                  `${tr('Серверы в подписке', 'Servers in subscription')} (${subCache.servers.length}):`,
                ),
                renderCompactServersTable(subCache.servers),
              ],
            ),
          );
        } else {
          inspectorRows.push(
            E('div', { class: 'tachyon-studio-source-inspector__row' }, [
              E(
                'span',
                { class: 'tachyon-studio-source-inspector__label' },
                tr('Серверы в подписке:', 'Servers in subscription:'),
              ),
              E(
                'span',
                {
                  class: 'tachyon-studio-source-inspector__val',
                  style: 'opacity: 0.75;',
                },
                tr(
                  'Кэш узлов ещё не загружен — нажмите «Обновить» на карточке подписки',
                  'Cached nodes not loaded yet — click "Update" on the subscription card',
                ),
              ),
            ]),
          );
        }
      }
      if (stype === 'proxy_links' && links.length > 0) {
        const linkServerItems = links.map((lnk, idx) => {
          const hashIdx = lnk.indexOf('#');
          const tagPart =
            hashIdx >= 0 ? decodeURIComponent(lnk.slice(hashIdx + 1)) : '';
          const protoMatch = lnk.match(/^([a-z0-9+-]+):\/\//i);
          const proto = protoMatch ? protoMatch[1].toUpperCase() : 'LINK';
          const trans = (getProxyUrlTransport(lnk) || 'TCP').toUpperCase();
          return {
            name: tagPart || `${proto} #${idx + 1}`,
            proto,
            trans,
            link: lnk,
          };
        });
        inspectorRows.push(
          E(
            'div',
            {
              class:
                'tachyon-studio-source-inspector__row tachyon-studio-source-inspector__row--block',
            },
            [
              E(
                'span',
                { class: 'tachyon-studio-source-inspector__label' },
                `${tr('Серверы в источнике', 'Servers in source')} (${links.length}):`,
              ),
              renderCompactServersTable(linkServerItems),
            ],
          ),
        );
      }
      if (stype === 'fptn') {
        const fptnMetaParts: string[] = [];
        if (fptnParsed?.serviceName) {
          fptnMetaParts.push(
            `${tr('Сервис', 'Service')}: ${fptnParsed.serviceName}`,
          );
        }
        if (fptnParsed?.username) {
          fptnMetaParts.push(
            `${tr('Пользователь', 'User')}: ${fptnParsed.username}`,
          );
        }
        if (raw.bypass_method) {
          fptnMetaParts.push(
            `${tr('Метод обхода', 'Bypass')}: ${raw.bypass_method}`,
          );
        }
        if (raw.preferred_server) {
          fptnMetaParts.push(
            `${tr('Предпочитаемый сервер', 'Preferred')}: ${raw.preferred_server}`,
          );
        }
        if (fptnMetaParts.length > 0) {
          inspectorRows.push(
            E('div', { class: 'tachyon-studio-source-inspector__row' }, [
              E(
                'span',
                { class: 'tachyon-studio-source-inspector__label' },
                'FPTN:',
              ),
              E(
                'span',
                { class: 'tachyon-studio-source-inspector__val' },
                fptnMetaParts.join(' • '),
              ),
            ]),
          );
        }
        if (fptnServers.length > 0) {
          inspectorRows.push(
            E(
              'div',
              {
                class:
                  'tachyon-studio-source-inspector__row tachyon-studio-source-inspector__row--block',
              },
              [
                E(
                  'span',
                  { class: 'tachyon-studio-source-inspector__label' },
                  `${tr('Серверы в подписке', 'Servers in subscription')} (${fptnServers.length}):`,
                ),
                renderCompactServersTable(fptnServers),
              ],
            ),
          );
        }
      }

      const inspectorEl = E(
        'div',
        {
          class: 'tachyon-studio-source-inspector',
          click: (ev: MouseEvent) => ev.stopPropagation(),
        },
        inspectorRows,
      );

      let isExpanded = expandedSourceIds.has(sid);
      const chevronEl = E(
        'button',
        {
          type: 'button',
          class: 'tachyon-studio-action-btn',
          title: tr('Развернуть детали и серверы', 'Toggle details & servers'),
          style:
            'padding: 4px 8px; font-size: 12px; display: inline-flex; align-items: center; justify-content: center;',
        },
        [isExpanded ? renderChevronUpIcon(12) : renderChevronDownIcon(12)],
      );
      const toggleInspector = (ev: MouseEvent) => {
        const target = ev.target as HTMLElement | null;
        if (
          target &&
          target !== chevronEl &&
          !chevronEl.contains(target) &&
          target.closest('.tachyon-studio-source-inspector')
        ) {
          return;
        }
        ev.preventDefault();
        ev.stopPropagation();
        const prevTop =
          card && typeof card.getBoundingClientRect === 'function'
            ? card.getBoundingClientRect().top
            : null;
        isExpanded = !isExpanded;
        if (isExpanded) expandedSourceIds.add(sid);
        else expandedSourceIds.delete(sid);
        card.classList.toggle('is-expanded', isExpanded);
        chevronEl.innerHTML = '';
        chevronEl.appendChild(
          isExpanded ? renderChevronUpIcon(12) : renderChevronDownIcon(12),
        );
        if (
          prevTop !== null &&
          card &&
          typeof card.getBoundingClientRect === 'function'
        ) {
          const restoreAnchor = () => {
            const nextTop = card.getBoundingClientRect().top;
            const delta = nextTop - prevTop;
            if (Math.abs(delta) > 1) {
              const mainContent = document.getElementById('maincontent');
              if (
                mainContent &&
                mainContent.scrollHeight > mainContent.clientHeight
              ) {
                mainContent.scrollTop += delta;
              }
              if (
                typeof window !== 'undefined' &&
                typeof window.scrollBy === 'function'
              ) {
                window.scrollBy(0, delta);
              }
            }
          };
          restoreAnchor();
          if (typeof requestAnimationFrame === 'function') {
            requestAnimationFrame(restoreAnchor);
          }
        }
      };
      chevronEl.addEventListener('click', toggleInspector);

      const isSubUpdating =
        updatingSubTargets.has(sid) || updatingSubTargets.has('__all__');
      const updateSubBtn =
        stype === 'subscription'
          ? E(
              'button',
              {
                type: 'button',
                class: 'tachyon-studio-action-btn',
                disabled: isSubUpdating ? 'disabled' : null,
                title: tr(
                  'Обновить эту подписку сейчас',
                  'Update this subscription now',
                ),
                click: (ev: MouseEvent) => {
                  ev.preventDefault();
                  ev.stopPropagation();
                  void triggerSubscriptionUpdate(sid);
                },
              },
              [
                renderRefreshCwIcon(12),
                E(
                  'span',
                  {},
                  isSubUpdating
                    ? tr('Обновление...', 'Updating...')
                    : tr('Обновить', 'Update'),
                ),
              ],
            )
          : null;

      const card = E(
        'div',
        {
          class: `tachyon-studio-card tachyon-studio-card--source tachyon-studio-card--source-compact ${enabled ? 'is-enabled' : 'is-disabled'} ${isExpanded ? 'is-expanded' : ''}`,
          'data-sid': sid,
          click: toggleInspector,
        },
        [
          E('div', { class: 'tachyon-studio-card__head' }, [
            E('div', { class: 'tachyon-studio-card__identity' }, [
              renderOrderControls(),
              E(
                'div',
                {
                  class: `tachyon-studio-card__icon tachyon-studio-card__icon--${tone}`,
                },
                [iconEl],
              ),
              E('div', { class: 'tachyon-studio-card__title-wrap' }, [
                E('div', { class: 'tachyon-studio-card__title-row' }, [
                  E('span', { class: 'tachyon-studio-card__title' }, name),
                  ...typeBadges,
                ]),
                E('div', { class: 'tachyon-studio-card__sid' }, paramSummary),
                usedInGroups.length > 0
                  ? E(
                      'div',
                      {
                        style:
                          'display: flex; align-items: center; flex-wrap: wrap; gap: 4px; margin-top: 4px;',
                      },
                      [
                        E(
                          'span',
                          {
                            style:
                              'font-size: 10px; font-weight: 600; letter-spacing: 0.04em; opacity: 0.65; margin-right: 2px;',
                          },
                          tr('В группах:', 'In groups:'),
                        ),
                        ...groupChips,
                      ],
                    )
                  : E('span'),
              ]),
            ]),
            E('div', { class: 'tachyon-studio-source-compact__right' }, [
              E(
                'div',
                { class: 'tachyon-studio-source-compact__sections' },
                sectionChips,
              ),
              ...(updateSubBtn ? [updateSubBtn] : []),
              E(
                'button',
                {
                  type: 'button',
                  class:
                    'tachyon-studio-action-btn tachyon-studio-action-btn--primary',
                  click: openEditModal,
                },
                [
                  renderSettingsIcon(13),
                  E('span', {}, tr('Изменить', 'Configure')),
                ],
              ),
              E(
                'button',
                {
                  type: 'button',
                  class:
                    'tachyon-studio-action-btn tachyon-studio-action-btn--danger',
                  title: tr('Удалить', 'Delete'),
                  click: handleDelete,
                },
                [renderTrashIcon(13)],
              ),
              createStudioToggleSwitch(sid, enabled, sectionRef, renderDeck),
              chevronEl,
            ]),
          ]),
          inspectorEl,
        ],
      );
      attachDragAndOrderHandlers(card);
      return card;
    }

    // ── CASE 3: CONDITION ───────────────────────────────────────────────────
    if (type === 'condition') {
      const name = raw.name || raw.label || sid;
      const ctype = String(raw.condition_type || 'atomic').toLowerCase();
      const invert = raw.invert === '1';
      const usedIn = (uci.sections(UCI_PACKAGE, 'section') || [])
        .filter((s: any) =>
          asArray(s.condition_refs).map(stripPrefix).includes(sid),
        )
        .map((s: any) => ({
          id: s['.name'],
          name: s.label || s.name || s['.name'],
        }));

      const comm = asArray(raw.community_lists);
      const doms = [
        ...asArray(raw.domain),
        ...asArray(raw.domain_suffix),
        ...asArray(raw.domain_keyword),
      ];
      const ips = asArray(raw.ip_cidr);
      const geos = asArray(raw.geoip_country);
      const ports = asArray(raw.ports);
      const inbounds = asArray(raw.source_inbounds);

      const detectListDuplicateCount = (items: string[]) => {
        const seen = new Set<string>();
        let dupes = 0;
        items.forEach((it) => {
          const norm = String(it || '')
            .trim()
            .toLowerCase()
            .replace(/^domain:/, '');
          if (!norm) return;
          if (seen.has(norm)) dupes += 1;
          else seen.add(norm);
        });
        return dupes;
      };
      const domDupes = detectListDuplicateCount(doms);
      const ipDupes = detectListDuplicateCount(ips);
      const condIssueParts: string[] = [];
      if (domDupes > 0) {
        condIssueParts.push(
          `${tr('Повторы доменов', 'Duplicate domains')}: ${domDupes}`,
        );
      }
      if (ipDupes > 0) {
        condIssueParts.push(`${tr('Повторы IP', 'Duplicate IPs')}: ${ipDupes}`);
      }

      const ruleChips: HTMLElement[] = [];
      comm.forEach((srv) => {
        ruleChips.push(
          E(
            'span',
            { class: 'tachyon-studio-chip tachyon-studio-chip--cond' },
            [renderCommunityListServiceIcon(srv, 11), E('span', {}, srv)],
          ),
        );
      });
      inbounds.forEach((ib) => {
        ruleChips.push(
          E(
            'span',
            { class: 'tachyon-studio-chip tachyon-studio-chip--section' },
            [renderRadioIcon(11), E('span', {}, `Inbound: ${ib}`)],
          ),
        );
      });
      doms.slice(0, 4).forEach((d) => {
        ruleChips.push(
          E(
            'span',
            { class: 'tachyon-studio-chip tachyon-studio-chip--source' },
            [renderGlobeIcon(11), E('span', {}, d)],
          ),
        );
      });
      if (doms.length > 4) {
        ruleChips.push(
          E(
            'span',
            { class: 'tachyon-studio-chip tachyon-studio-chip--muted' },
            `+${doms.length - 4} ${tr('доменов', 'domains')}`,
          ),
        );
      }
      ips.slice(0, 3).forEach((ip) => {
        ruleChips.push(
          E(
            'span',
            { class: 'tachyon-studio-chip tachyon-studio-chip--balancer' },
            [renderPinIcon(11), E('span', {}, ip)],
          ),
        );
      });
      geos.forEach((g) => {
        ruleChips.push(
          E(
            'span',
            { class: 'tachyon-studio-chip tachyon-studio-chip--balancer' },
            [renderGlobeIcon(11), E('span', {}, `GeoIP: ${g.toUpperCase()}`)],
          ),
        );
      });
      ports.forEach((p) => {
        ruleChips.push(
          E(
            'span',
            { class: 'tachyon-studio-chip tachyon-studio-chip--muted' },
            `:${p}`,
          ),
        );
      });
      if (!ruleChips.length) {
        ruleChips.push(
          E(
            'span',
            { class: 'tachyon-studio-chip tachyon-studio-chip--muted' },
            raw.expression ||
              tr(
                'Нажмите Изменить для выбора сервисов или доменов',
                'Click Configure to add services or domains',
              ),
          ),
        );
      }

      const card = E(
        'div',
        {
          class: `tachyon-studio-card tachyon-studio-card--condition ${enabled ? 'is-enabled' : 'is-disabled'}`,
          'data-sid': sid,
          click: openEditModal,
        },
        [
          E('div', { class: 'tachyon-studio-card__head' }, [
            E('div', { class: 'tachyon-studio-card__identity' }, [
              renderOrderControls(),
              E(
                'div',
                {
                  class:
                    'tachyon-studio-card__icon tachyon-studio-card__icon--proxy',
                },
                [
                  ctype === 'composite'
                    ? renderPuzzleIcon(20)
                    : renderTargetIcon(20),
                ],
              ),
              E('div', { class: 'tachyon-studio-card__title-wrap' }, [
                E('div', { class: 'tachyon-studio-card__title-row' }, [
                  E('span', { class: 'tachyon-studio-card__title' }, name),
                  E(
                    'span',
                    {
                      class: 'tachyon-studio-badge tachyon-studio-badge--proto',
                    },
                    ctype === 'composite'
                      ? tr('СОСТАВНОЕ', 'COMPOSITE')
                      : tr('АТОМАРНОЕ', 'ATOMIC'),
                  ),
                  invert
                    ? E(
                        'span',
                        {
                          class:
                            'tachyon-studio-badge tachyon-studio-badge--block',
                        },
                        'NOT (ИНВЕРСИЯ)',
                      )
                    : E('span'),
                  condIssueParts.length > 0
                    ? E(
                        'span',
                        {
                          class:
                            'tachyon-studio-badge tachyon-studio-badge--block',
                          title: condIssueParts.join(' • '),
                        },
                        [
                          renderAlertTriangleIcon(11),
                          E('span', {}, ` ${condIssueParts.join(', ')}`),
                        ],
                      )
                    : E('span'),
                ]),
                E(
                  'div',
                  { class: 'tachyon-studio-card__sid' },
                  usedIn.length
                    ? `${tr('Секции', 'Used in')}: ${usedIn.map((u: any) => u.name).join(', ')}`
                    : tr(
                        'Не привязано к секциям',
                        'Not attached to any section yet',
                      ),
                ),
              ]),
            ]),
            E('div', { class: 'tachyon-studio-card__head-right' }, [
              createStudioToggleSwitch(sid, enabled, sectionRef, renderDeck),
            ]),
          ]),
          E('div', { class: 'tachyon-studio-card__pipeline' }, [
            E('div', { class: 'tachyon-studio-card__pipe-stage' }, [
              E(
                'span',
                { class: 'tachyon-studio-card__pipe-label' },
                tr(
                  'Сводка правила (сервисы, домены, подсети)',
                  'Matched Services, Domains & Subnets',
                ),
              ),
              E('div', { class: 'tachyon-studio-card__chips' }, ruleChips),
            ]),
            ...(usedIn.length > 0
              ? [
                  E('span', { class: 'tachyon-studio-card__pipe-arrow' }, '➔'),
                  E('div', { class: 'tachyon-studio-card__pipe-stage' }, [
                    E(
                      'span',
                      { class: 'tachyon-studio-card__pipe-label' },
                      tr('Используется в секциях', 'Used in Sections'),
                    ),
                    E(
                      'div',
                      { class: 'tachyon-studio-card__chips' },
                      usedIn.map((u: any) =>
                        E(
                          'button',
                          {
                            type: 'button',
                            class:
                              'tachyon-studio-chip tachyon-studio-chip--section',
                            title: tr(
                              `Открыть секцию «${u.name}»`,
                              `Open section "${u.name}"`,
                            ),
                            click: (ev: MouseEvent) => {
                              ev.preventDefault();
                              ev.stopPropagation();
                              if (onNavigateSubTab) {
                                onNavigateSubTab('sections', u.id);
                              }
                            },
                          },
                          [renderSubRouteIcon(11), E('span', {}, u.name)],
                        ),
                      ),
                    ),
                  ]),
                ]
              : []),
          ]),
          E('div', { class: 'tachyon-studio-card__footer' }, [
            E(
              'button',
              {
                type: 'button',
                class:
                  'tachyon-studio-action-btn tachyon-studio-action-btn--primary',
                click: openEditModal,
              },
              [
                renderSettingsIcon(13),
                E('span', {}, tr('Изменить', 'Configure')),
              ],
            ),
            E(
              'button',
              {
                type: 'button',
                class:
                  'tachyon-studio-action-btn tachyon-studio-action-btn--danger',
                title: tr('Удалить', 'Delete'),
                click: handleDelete,
              },
              [renderTrashIcon(13)],
            ),
          ]),
        ],
      );
      attachDragAndOrderHandlers(card);
      return card;
    }

    // ── CASE 4: BALANCER ────────────────────────────────────────────────────
    if (type === 'balancer') {
      const name = raw.name || raw.label || sid;
      const btype = String(raw.balancer_type || 'urltest').toLowerCase();
      const bmode = String(raw.mode || 'least_test').toLowerCase();
      const usedInObjs = (uci.sections(UCI_PACKAGE, 'section') || [])
        .filter((s: any) => asArray(s.balancer_refs).includes(sid))
        .map((s: any) => ({
          id: s['.name'],
          name: s.label || s.name || s['.name'],
        }));
      const usedIn = usedInObjs.map((u: any) => u.name);

      const interval =
        raw.check_interval || (btype === 'priority' ? '30s' : '3m');
      const intervalJitter = String(
        raw.check_interval_jitter || raw.urltest_check_interval_jitter || '',
      ).trim();
      const tolerance = raw.tolerance || '50';
      const testUrl = raw.testing_url || 'https://www.gstatic.com/generate_204';
      const excCountries = asArray(raw.exclude_countries);
      const incCountries = asArray(raw.include_countries);
      const excServers = asArray(raw.exclude_outbounds);
      const balancerPool = Number(raw.balancer_pool || 0);
      const stickyHash = asArray(raw.sticky_hash);
      const quotaMib = Number(raw.quota_mib || 0);
      const interruptConns = raw.interrupt_exist_connections === '1';

      const policyChips: HTMLElement[] = [
        E(
          'span',
          { class: 'tachyon-studio-chip tachyon-studio-chip--source' },
          [
            renderClockIcon(11),
            E(
              'span',
              {},
              `${tr('Интервал', 'Interval')}: ${interval}${intervalJitter && intervalJitter !== '0' ? ` (±${intervalJitter.replace(/^[±+-]+/, '')})` : ''}`,
            ),
          ],
        ),
      ];
      if (btype === 'urltest') {
        policyChips.push(
          E(
            'span',
            { class: 'tachyon-studio-chip tachyon-studio-chip--cond' },
            [
              renderTargetIcon(11),
              E('span', {}, `${tr('Допуск', 'Tolerance')}: ${tolerance} ms`),
            ],
          ),
        );
        if (
          balancerPool > 0 &&
          [
            'sticky',
            'least_load',
            'weighted',
            'hedged',
            'throughput',
            'quota',
            'round_robin',
            'random',
          ].includes(bmode)
        ) {
          policyChips.push(
            E(
              'span',
              { class: 'tachyon-studio-chip tachyon-studio-chip--section' },
              `${tr('Пул', 'Pool')}: Top-${balancerPool}`,
            ),
          );
        }
        if (bmode === 'sticky' && stickyHash.length > 0) {
          policyChips.push(
            E(
              'span',
              { class: 'tachyon-studio-chip tachyon-studio-chip--balancer' },
              [
                renderPinIcon(11),
                E('span', {}, `HRW: ${stickyHash.join('+')}`),
              ],
            ),
          );
        }
        if (bmode === 'quota' && quotaMib > 0) {
          policyChips.push(
            E(
              'span',
              { class: 'tachyon-studio-chip tachyon-studio-chip--balancer' },
              `${tr('Лимит', 'Quota')}: ${quotaMib} MiB`,
            ),
          );
        }
        if (interruptConns) {
          policyChips.push(
            E(
              'span',
              { class: 'tachyon-studio-chip tachyon-studio-chip--muted' },
              tr('Сброс сессий при смене', 'Reset active sessions'),
            ),
          );
        }
      } else if (btype === 'priority') {
        const rawLvls = raw.outbound_group_levels;
        const lvlList: string[] = Array.isArray(rawLvls)
          ? rawLvls.map((v: any) => String(v).trim()).filter(Boolean)
          : String(rawLvls || '')
                .trim()
                .startsWith('srv:')
            ? [String(rawLvls).trim()]
            : asArray(rawLvls);
        lvlList.forEach((lvlRef, idx) => {
          const label =
            lvlRef === 'direct'
              ? 'Direct (WAN)'
              : lvlRef.startsWith('srv:')
                ? `🎯 ${lvlRef.slice(4)}`
                : uci.get(UCI_PACKAGE, lvlRef, 'name') ||
                  uci.get(UCI_PACKAGE, lvlRef, 'label') ||
                  lvlRef;
          policyChips.push(
            E(
              'span',
              { class: 'tachyon-studio-chip tachyon-studio-chip--cond' },
              `#${idx + 1}: ${label}`,
            ),
          );
        });
      }
      if (incCountries.length) {
        policyChips.push(
          E(
            'span',
            { class: 'tachyon-studio-chip tachyon-studio-chip--section' },
            `+${incCountries.join(', ')}`,
          ),
        );
      }
      if (excCountries.length) {
        policyChips.push(
          E(
            'span',
            { class: 'tachyon-studio-chip tachyon-studio-chip--balancer' },
            [renderBanIcon(11), E('span', {}, `-${excCountries.join(', -')}`)],
          ),
        );
      }
      if (excServers.length) {
        policyChips.push(
          E(
            'span',
            { class: 'tachyon-studio-chip tachyon-studio-chip--muted' },
            `-${excServers.length} ${tr('серв.', 'servers')}`,
          ),
        );
      }

      const card = E(
        'div',
        {
          class: `tachyon-studio-card tachyon-studio-card--balancer ${enabled ? 'is-enabled' : 'is-disabled'}`,
          'data-sid': sid,
        },
        [
          E('div', { class: 'tachyon-studio-card__head' }, [
            E('div', { class: 'tachyon-studio-card__identity' }, [
              renderOrderControls(),
              E(
                'div',
                {
                  class:
                    'tachyon-studio-card__icon tachyon-studio-card__icon--proxy',
                },
                [
                  btype === 'priority'
                    ? renderShieldIcon(20)
                    : renderZapIcon(20),
                ],
              ),
              E('div', { class: 'tachyon-studio-card__title-wrap' }, [
                E('div', { class: 'tachyon-studio-card__title-row' }, [
                  E('span', { class: 'tachyon-studio-card__title' }, name),
                  E(
                    'span',
                    {
                      class: 'tachyon-studio-badge tachyon-studio-badge--proxy',
                    },
                    formatBalancerModeBadge(btype, bmode),
                  ),
                ]),
                E(
                  'div',
                  { class: 'tachyon-studio-card__sid' },
                  `${usedIn.length ? `${tr('Секции', 'Sections')}: ${usedIn.join(', ')} • ` : ''}${testUrl}`,
                ),
              ]),
            ]),
            E('div', { class: 'tachyon-studio-card__head-right' }, [
              createStudioToggleSwitch(sid, enabled, sectionRef, renderDeck),
            ]),
          ]),
          E('div', { class: 'tachyon-studio-card__pipeline' }, [
            E('div', { class: 'tachyon-studio-card__pipe-stage' }, [
              E(
                'span',
                { class: 'tachyon-studio-card__pipe-label' },
                tr(
                  'Параметры выбора и фильтрации',
                  'Selection & Filter Parameters',
                ),
              ),
              E('div', { class: 'tachyon-studio-card__chips' }, policyChips),
            ]),
            ...(usedInObjs.length > 0
              ? [
                  E('span', { class: 'tachyon-studio-card__pipe-arrow' }, '➔'),
                  E('div', { class: 'tachyon-studio-card__pipe-stage' }, [
                    E(
                      'span',
                      { class: 'tachyon-studio-card__pipe-label' },
                      tr('Используется в секциях', 'Used in Sections'),
                    ),
                    E(
                      'div',
                      { class: 'tachyon-studio-card__chips' },
                      usedInObjs.map((u: any) =>
                        E(
                          'button',
                          {
                            type: 'button',
                            class:
                              'tachyon-studio-chip tachyon-studio-chip--section',
                            title: tr(
                              `Открыть секцию «${u.name}»`,
                              `Open section "${u.name}"`,
                            ),
                            click: (ev: MouseEvent) => {
                              ev.preventDefault();
                              ev.stopPropagation();
                              if (onNavigateSubTab) {
                                onNavigateSubTab('sections', u.id);
                              }
                            },
                          },
                          [renderSubRouteIcon(11), E('span', {}, u.name)],
                        ),
                      ),
                    ),
                  ]),
                ]
              : []),
          ]),
          E('div', { class: 'tachyon-studio-card__footer' }, [
            E(
              'button',
              {
                type: 'button',
                class:
                  'tachyon-studio-action-btn tachyon-studio-action-btn--primary',
                click: openEditModal,
              },
              [
                renderSettingsIcon(13),
                E('span', {}, tr('Изменить', 'Configure Policy')),
              ],
            ),
            E(
              'button',
              {
                type: 'button',
                class:
                  'tachyon-studio-action-btn tachyon-studio-action-btn--danger',
                title: tr('Удалить', 'Delete'),
                click: handleDelete,
              },
              [renderTrashIcon(13)],
            ),
          ]),
        ],
      );
      attachDragAndOrderHandlers(card);
      return card;
    }

    // ── CASE 5: INBOUND SERVER ──────────────────────────────────────────────
    if (type === 'server') {
      const name = raw.name || raw.label || sid;
      const proto = String(raw.protocol || 'vless').toLowerCase();
      const port =
        raw.listen_port ||
        raw.port ||
        (proto === 'mieru'
          ? '2012-2022'
          : proto === 'awg'
            ? '51820'
            : proto === 'hysteria2' || proto === 'tuic'
              ? '8443'
              : '443');
      const transport = String(
        proto === 'mieru'
          ? raw.mieru_transport || 'TCP'
          : raw.transport ||
              (proto === 'hysteria2' || proto === 'tuic' || proto === 'masque'
                ? 'QUIC'
                : proto === 'awg'
                  ? 'UDP'
                  : 'TCP'),
      ).toUpperCase();
      const security = String(
        raw.security ||
          (proto === 'vless'
            ? 'REALITY'
            : proto === 'awg'
              ? 'AWG 2.0'
              : proto === 'mieru'
                ? 'AEAD'
                : 'TLS'),
      ).toUpperCase();

      let routingMode = String(raw.routing_mode || 'rules').toLowerCase();
      let routingSectionId = String(raw.routing_section || '').trim();
      if (routingMode === 'rules') {
        const allSecs = uci.sections(UCI_PACKAGE, 'section') || [];
        for (const sec of allSecs) {
          const secInb = asArray(sec?.source_inbounds);
          if (secInb.includes(sid)) {
            routingMode = 'section';
            routingSectionId = String(sec['.name'] || '');
            break;
          }
        }
      }
      let routingSummaryLabel = tr(
        'Маршрут: По правилам роутера',
        'Route: By router rules',
      );
      if (routingMode === 'direct') {
        routingSummaryLabel = tr(
          'Маршрут: Напрямую (WAN)',
          'Route: Direct (WAN)',
        );
      } else if (routingMode === 'section' && routingSectionId) {
        const targetSec = uci.get(UCI_PACKAGE, routingSectionId);
        const targetTitle =
          targetSec?.label || targetSec?.name || routingSectionId;
        routingSummaryLabel = `${tr('Через секцию', 'Via section')}: ${targetTitle}`;
      }

      const triggerServerInfoModal = (ev: MouseEvent) => {
        ev.preventDefault();
        ev.stopPropagation();
        if (openServerInfoModalForSection(sid)) {
          return;
        }
        const backingBtn = containerEl.querySelector(
          `#cbi-${UCI_PACKAGE}-${sid} .fkp-server-icon-button, tr[data-sid="${sid}"] .fkp-server-icon-button, tr[data-sid="${sid}"] .cbi-button-action`,
        ) as HTMLElement | null;
        if (backingBtn) {
          backingBtn.click();
        } else {
          openEditModal();
        }
      };

      const card = E(
        'div',
        {
          class: `tachyon-studio-card tachyon-studio-card--server ${enabled ? 'is-enabled' : 'is-disabled'}`,
          'data-sid': sid,
          click: openEditModal,
        },
        [
          E('div', { class: 'tachyon-studio-card__head' }, [
            E('div', { class: 'tachyon-studio-card__identity' }, [
              E(
                'div',
                {
                  class: `tachyon-studio-card__icon ${enabled ? 'tachyon-studio-card__icon--bypass' : 'tachyon-studio-card__icon--proxy'}`,
                },
                [
                  proto === 'awg'
                    ? renderShieldIcon(20)
                    : proto === 'hysteria2' || proto === 'tuic'
                      ? renderRocketIcon(20)
                      : renderZapIcon(20),
                ],
              ),
              E('div', { class: 'tachyon-studio-card__title-wrap' }, [
                E('div', { class: 'tachyon-studio-card__title-row' }, [
                  E('span', { class: 'tachyon-studio-card__title' }, name),
                  E(
                    'span',
                    {
                      class: 'tachyon-studio-badge tachyon-studio-badge--proto',
                    },
                    proto.toUpperCase(),
                  ),
                  E(
                    'span',
                    {
                      class:
                        'tachyon-studio-badge tachyon-studio-badge--transport',
                    },
                    transport,
                  ),
                  security && security !== 'NONE'
                    ? E(
                        'span',
                        {
                          class:
                            'tachyon-studio-badge tachyon-studio-badge--proxy',
                        },
                        security,
                      )
                    : E('span'),
                ]),
                E(
                  'div',
                  { class: 'tachyon-studio-card__sid' },
                  `${tr('Порт', 'Port')}: :${port} • ${routingSummaryLabel} • ${enabled ? tr('Активен', 'Listening') : tr('Остановлен', 'Stopped')}`,
                ),
              ]),
            ]),
            E('div', { class: 'tachyon-studio-card__head-right' }, [
              createStudioToggleSwitch(sid, enabled, sectionRef, renderDeck),
            ]),
          ]),
          E('div', { class: 'tachyon-studio-card__footer' }, [
            E(
              'button',
              {
                type: 'button',
                class: 'tachyon-studio-action-btn',
                title: tr(
                  'QR-код и ссылка для подключения клиента',
                  'Show QR code & client share links',
                ),
                click: triggerServerInfoModal,
              },
              [
                renderQrCodeIcon(13),
                E('span', {}, tr('QR / Подключение', 'QR / Client Link')),
              ],
            ),
            E(
              'button',
              {
                type: 'button',
                class:
                  'tachyon-studio-action-btn tachyon-studio-action-btn--primary',
                click: openEditModal,
              },
              [
                renderSettingsIcon(13),
                E('span', {}, tr('Изменить', 'Configure')),
              ],
            ),
            E(
              'button',
              {
                type: 'button',
                class:
                  'tachyon-studio-action-btn tachyon-studio-action-btn--danger',
                title: tr('Удалить', 'Delete'),
                click: handleDelete,
              },
              [renderTrashIcon(13)],
            ),
          ]),
        ],
      );
      return card;
    }

    // ── CASE 6: PROFILE / SCHEDULE ──────────────────────────────────────────
    const name = raw.name || raw.label || sid;
    const card = E(
      'div',
      {
        class: `tachyon-studio-card ${enabled ? 'is-enabled' : 'is-disabled'}`,
        'data-sid': sid,
        click: openEditModal,
      },
      [
        E('div', { class: 'tachyon-studio-card__head' }, [
          E('div', { class: 'tachyon-studio-card__identity' }, [
            renderOrderControls(),
            E(
              'div',
              {
                class:
                  'tachyon-studio-card__icon tachyon-studio-card__icon--proxy',
              },
              [type === 'profile' ? renderUsersIcon(20) : renderClockIcon(20)],
            ),
            E('div', { class: 'tachyon-studio-card__title-wrap' }, [
              E('div', { class: 'tachyon-studio-card__title-row' }, [
                E('span', { class: 'tachyon-studio-card__title' }, name),
              ]),
              E('div', { class: 'tachyon-studio-card__sid' }, `ID: ${sid}`),
            ]),
          ]),
          E('div', { class: 'tachyon-studio-card__head-right' }, [
            createStudioToggleSwitch(sid, enabled, sectionRef, renderDeck),
          ]),
        ]),
        E('div', { class: 'tachyon-studio-card__footer' }, [
          E(
            'button',
            {
              type: 'button',
              class:
                'tachyon-studio-action-btn tachyon-studio-action-btn--primary',
              click: openEditModal,
            },
            [
              renderSettingsIcon(13),
              E('span', {}, tr('Изменить', 'Configure')),
            ],
          ),
          E(
            'button',
            {
              type: 'button',
              class:
                'tachyon-studio-action-btn tachyon-studio-action-btn--danger',
              title: tr('Удалить', 'Delete'),
              click: handleDelete,
            },
            [renderTrashIcon(13)],
          ),
        ]),
      ],
    );
    attachDragAndOrderHandlers(card);
    return card;
  };

  deckRoot.appendChild(toolbarEl);
  deckRoot.appendChild(panelEl);

  const tableAnchor =
    containerEl.querySelector('.cbi-section-node') ||
    containerEl.querySelector('.cbi-section-table') ||
    containerEl.firstChild;
  if (tableAnchor && tableAnchor.parentNode === containerEl) {
    containerEl.insertBefore(deckRoot, tableAnchor);
  } else {
    containerEl.prepend(deckRoot);
  }

  renderDeck();
  if (type === 'outbound_source') {
    void loadSubscriptionCacheMap();
  }
}
