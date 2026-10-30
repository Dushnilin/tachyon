/* eslint-disable @typescript-eslint/no-explicit-any */
import { getProxyUrlTransport } from '../helpers/getProxyUrlTransport';
import { formatOutboundType } from '../helpers/formatOutboundType';
import { openConnectionWizardModal } from './connectionWizard';
import { tr } from './helpers/i18n';
import { openServerInfoModalForSection } from './tabs/dashboard/inboundServers';

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
  if (!val) return [];
  if (Array.isArray(val)) {
    return val.map((x) => String(x || '').trim()).filter(Boolean);
  }
  return String(val)
    .split(/[\s,]+/)
    .map((x) => x.trim())
    .filter(Boolean);
}

function stripPrefix(tok: string): string {
  return String(tok || '').replace(/^[+!-]/, '');
}

function getStudioViewMode(type: StudioEntityType): StudioViewMode {
  if (typeof localStorage === 'undefined') {
    return type === 'section' ? 'pipeline' : 'cards';
  }
  try {
    const saved = localStorage.getItem(`tachyon_studio_view_${type}_v1`);
    if (saved === 'cards' || saved === 'pipeline') return saved;
  } catch {
    // ignore
  }
  return type === 'section' ? 'pipeline' : 'cards';
}

function setStudioViewMode(type: StudioEntityType, mode: StudioViewMode): void {
  if (typeof localStorage === 'undefined') return;
  try {
    localStorage.setItem(`tachyon_studio_view_${type}_v1`, mode);
  } catch {
    // ignore
  }
}

function notifyUciChanged(): void {
  try {
    if (typeof uci !== 'undefined' && typeof uci.save === 'function') {
      Promise.resolve(uci.save())
        .then(() => {
          if (
            typeof ui !== 'undefined' &&
            (ui as any).changes &&
            typeof (ui as any).changes.init === 'function'
          ) {
            (ui as any).changes.init();
          }
        })
        .catch(() => null);
    }
  } catch {
    // ignore
  }
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
  links.forEach((link) => {
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
  asArray(raw.community_lists).forEach((tag) => {
    if (!serviceTags.includes(tag)) serviceTags.push(tag);
  });

  const balRefs = asArray(raw.balancer_refs);
  const balancers = balRefs.map((bid) => {
    const bObj =
      (typeof uci !== 'undefined' && uci.get(UCI_PACKAGE, bid)) || {};
    return {
      id: bid,
      name: bObj.name || bObj.label || bid,
      type: String(bObj.balancer_type || 'urltest').toUpperCase(),
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
      const links = asArray(sObj.proxy_links);
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
  let iconText = '🌐';
  const iconBg = 'rgba(255, 255, 255, 0.04)';
  const iconColor = 'var(--text-color-high, #e2e8f0)';
  let faviconDomain = String(raw.icon_domain || '').trim();

  if (keyLower.includes('youtube') || keyLower.includes('yt')) {
    iconText = '▶';
    if (!faviconDomain) faviconDomain = 'youtube.com';
  } else if (keyLower.includes('discord')) {
    iconText = '🎮';
    if (!faviconDomain) faviconDomain = 'discord.com';
  } else if (keyLower.includes('tele') || keyLower.includes('tg')) {
    iconText = '✈️';
    if (!faviconDomain) faviconDomain = 'telegram.org';
  } else if (actionTone === 'block' || keyLower.includes('block')) {
    iconText = '🚫';
  } else if (actionTone === 'bypass' || keyLower.includes('bypass')) {
    iconText = '🟢';
  } else if (actionTone === 'dns' || keyLower.includes('dns')) {
    iconText = '🧭';
  } else if (keyLower.includes('main') || keyLower.includes('основн')) {
    iconText = '⚡';
  } else if (keyLower.includes('fptn')) {
    iconText = '🛡️';
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
        try {
          const rowCheckbox = document.querySelector(
            `#cbi-tachyon-${sectionRef?.sectiontype || ''} tr[data-sid="${sid}"] input[type="checkbox"]`,
          ) as HTMLInputElement | null;
          if (rowCheckbox && rowCheckbox.checked !== next) {
            rowCheckbox.checked = next;
            rowCheckbox.dispatchEvent(new Event('change', { bubbles: true }));
          }
        } catch {
          // ignore
        }
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
  icon: string;
  title: string;
  desc: string;
  defaults: Record<string, any>;
}

function getQuickCreateTemplates(
  type: StudioEntityType,
): QuickCreateTemplate[] {
  if (type === 'section') {
    return [
      {
        id: 'proxy',
        icon: '⚡',
        title: tr('Прокси / VPN секция', 'Proxy / VPN Section'),
        desc: tr(
          'Маршрутизация выбранных сервисов или доменов через подписки, VLESS, AWG или балансировщики',
          'Route selected services or domains through subscriptions, VLESS, AWG, or balancers',
        ),
        defaults: { enabled: '1', action: 'connection' },
      },
      {
        id: 'dpi',
        icon: '🛡️',
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
        icon: '🟢',
        title: tr('Прямой маршрут (Bypass)', 'Direct Route (Bypass)'),
        desc: tr(
          'Отправка российских сайтов, банков или подсетей напрямую в обход всех туннелей',
          'Send domestic sites, banks, or LAN subnets directly bypassing all tunnels',
        ),
        defaults: { enabled: '1', action: 'bypass' },
      },
      {
        id: 'block',
        icon: '🚫',
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
        icon: '🧭',
        title: tr('Специальный DNS-маршрут', 'Custom DNS Route'),
        desc: tr(
          'Разрешение выбранных доменов через выделенный DoH / DoT / UDP DNS-сервер',
          'Resolve specific domains via a dedicated DoH / DoT / UDP DNS server',
        ),
        defaults: { enabled: '1', action: 'dns' },
      },
    ];
  }
  if (type === 'outbound_source') {
    return [
      {
        id: 'subscription',
        icon: '📡',
        title: tr('Подписка по URL', 'Subscription URL'),
        desc: tr(
          'Автообновляемая HTTP/HTTPS подписка (VLESS, Hysteria2, Trojan, SS)',
          'Auto-updated HTTP/HTTPS subscription link (VLESS, Hysteria2, Trojan, SS)',
        ),
        defaults: { enabled: '1', source_type: 'subscription' },
      },
      {
        id: 'proxy_links',
        icon: '🔗',
        title: tr('Прокси-ссылки (Share Links)', 'Proxy Share Links'),
        desc: tr(
          'Одна или несколько ссылок vless://, hysteria2://, tuic://, trojan://, ss://',
          'One or multiple vless://, hysteria2://, tuic://, trojan://, ss:// links',
        ),
        defaults: { enabled: '1', source_type: 'proxy_links' },
      },
      {
        id: 'desync',
        icon: '🛡️',
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
        icon: '🔐',
        title: tr('AmneziaWG / WireGuard', 'AmneziaWG / WireGuard'),
        desc: tr(
          'Защищённый от DPI туннель AmneziaWG 1.5/2.0 или WireGuard (.conf / vpn://)',
          'Censorship-resistant AmneziaWG 1.5/2.0 or WireGuard tunnel (.conf / vpn://)',
        ),
        defaults: { enabled: '1', source_type: 'amnezia_config' },
      },
      {
        id: 'warp',
        icon: '☁️',
        title: 'Cloudflare WARP',
        desc: tr(
          'Встроенный туннель Cloudflare WARP с обфускацией заголовков Amnezia',
          'Built-in Cloudflare WARP tunnel with Amnezia obfuscation',
        ),
        defaults: { enabled: '1', source_type: 'warp' },
      },
      {
        id: 'fptn',
        icon: '🚀',
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
        icon: '🎯',
        title: tr('Списки сервисов и платформ', 'Service & Geo Lists'),
        desc: tr(
          'Готовые списки сервисов (YouTube, Discord, Telegram, ИИ, Meta, реклама)',
          'Match curated service lists (YouTube, Discord, Telegram, AI, Meta, Ads)',
        ),
        defaults: { enabled: '1', condition_type: 'atomic' },
      },
      {
        id: 'domains_ips',
        icon: '🌐',
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
        icon: '🧩',
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
    return [
      {
        id: 'urltest',
        icon: '⚡',
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
          check_interval: '3m',
          tolerance: '50',
          testing_url: 'https://www.gstatic.com/generate_204',
        },
      },
      {
        id: 'priority',
        icon: '🛡️',
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
      },
    ];
  }
  if (type === 'server') {
    return [
      {
        id: 'vless_reality',
        icon: '⚡',
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
        icon: '🚀',
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
        icon: '🛡️',
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
        icon: '🎭',
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
        icon: '💎',
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
        icon: '🔌',
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
      icon: '✨',
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

  const renderTemplateCards = () => {
    templateCardsWrap.innerHTML = '';
    templates.forEach((tpl) => {
      const isSelected = tpl.id === selectedTemplate.id;
      const card = E(
        'button',
        {
          type: 'button',
          class: `tachyon-studio-create__tpl-card ${isSelected ? 'is-selected' : ''}`,
          click: () => {
            selectedTemplate = tpl;
            renderTemplateCards();
          },
        },
        [
          E('span', { class: 'tachyon-studio-create__tpl-icon' }, tpl.icon),
          E('div', { class: 'tachyon-studio-create__tpl-body' }, [
            E('div', { class: 'tachyon-studio-create__tpl-title' }, tpl.title),
            E('div', { class: 'tachyon-studio-create__tpl-desc' }, tpl.desc),
          ]),
        ],
      );
      templateCardsWrap.appendChild(card);
    });
  };

  renderTemplateCards();

  const handleConfirm = () => {
    const rawName = nameInput.value.trim();
    if (!rawName) {
      errorEl.textContent = tr('Введите название.', 'Please enter a name.');
      errorEl.style.display = 'block';
      nameInput.focus();
      return;
    }

    const prefixMap: Record<StudioEntityType, string> = {
      section: 'sec',
      outbound_source: 'src',
      condition: 'cond',
      balancer: 'bal',
      server: 'srv',
      profile: 'prof',
      schedule: 'sched',
    };
    let uciId = /^[A-Za-z0-9_]+$/.test(rawName)
      ? rawName
      : sanitizeUciId(rawName, prefixMap[type] || 'item');

    let suffix = 1;
    const baseId = uciId;
    while (uci.get(UCI_PACKAGE, uciId)) {
      suffix += 1;
      uciId = `${baseId}_${suffix}`;
    }

    uci.add(UCI_PACKAGE, sectionRef.sectiontype || type, uciId);
    if (type === 'section') {
      uci.set(UCI_PACKAGE, uciId, 'label', rawName);
    } else {
      uci.set(UCI_PACKAGE, uciId, 'name', rawName);
    }

    Object.entries(selectedTemplate.defaults || {}).forEach(([k, v]) => {
      uci.set(UCI_PACKAGE, uciId, k, v);
    });

    ui.hideModal();
    notifyUciChanged();
    onCreated();

    if (typeof sectionRef.renderMoreOptionsModal === 'function') {
      window.setTimeout(() => {
        sectionRef.renderMoreOptionsModal(uciId);
      }, 60);
    }
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

  const existingDeck = containerEl.querySelector('.tachyon-studio-deck');
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
      subtitle: string;
      addLabel: string;
      filters: { id: string; label: string }[];
    }
  > = {
    section: {
      badge: 'TACHYON ROUTING PIPELINE',
      title: tr(
        'Конвейер секций маршрутизации',
        'Routing Sections & Traffic Pipeline',
      ),
      subtitle: tr(
        'Пакеты проверяются сверху вниз (#1 → #N). Перетаскивайте карточки или используйте стрелки приоритета.',
        'Packets are matched from top (#1) to bottom. Drag cards or use priority arrows to reorder.',
      ),
      addLabel: `+ ${tr('Новая секция', 'New Section')}`,
      filters: [
        { id: 'all', label: tr('Все секции', 'All Sections') },
        { id: 'proxy', label: tr('Прокси / VPN', 'Proxy / VPN') },
        { id: 'dpi', label: tr('Обход DPI (Desync)', 'DPI Desync') },
        { id: 'system', label: 'DNS / Bypass / Block' },
      ],
    },
    outbound_source: {
      badge: 'GLOBAL SERVER POOL • LAYER 1',
      title: tr(
        'Пул серверов, подписки и туннели',
        'Outbound Sources, Subscriptions & Tunnels',
      ),
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
      title: tr(
        'Условия трафика и наборы правил',
        'Traffic Conditions & Rule Matchers',
      ),
      subtitle: tr(
        'Списки сервисов, домены, подсети и составные логические условия (AND / OR / NOT) для секций.',
        'Reusable service lists, domain/IP sets, and boolean rules (AND / OR / NOT) attached to routing sections.',
      ),
      addLabel: `+ ${tr('Новое условие', 'New Condition')}`,
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
      title: tr(
        'Балансировщики и отказоустойчивость',
        'Balancers & Failover Policies',
      ),
      subtitle: tr(
        'Автовыбор самого быстрого узла по пингу (URLTest) и каскадное резервирование по уровням (Priority).',
        'Latency-based URLTest auto-selection and tiered Priority failover across server pools.',
      ),
      addLabel: `+ ${tr('Новый балансировщик', 'New Balancer')}`,
      filters: [
        { id: 'all', label: tr('Все политики', 'All Policies') },
        { id: 'urltest', label: '⚡ URLTest' },
        { id: 'priority', label: '🛡️ Priority' },
      ],
    },
    server: {
      badge: 'INBOUND SERVER HUB',
      title: tr(
        'Входящие VPN и прокси-серверы на роутере (Inbound)',
        'Inbound VPN & Proxy Servers on Router',
      ),
      subtitle: tr(
        'Поднимите собственный сервер VLESS Reality, Hysteria2, TUIC, AmneziaWG или SOCKS5 для доступа к роутеру извне.',
        'Host your own VLESS Reality, Hysteria2, TUIC, AmneziaWG, or SOCKS5 server for remote access.',
      ),
      addLabel: `+ ${tr('Новый сервер', 'New Inbound Server')}`,
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
      title: tr('Семейные профили устройств', 'Family & Device Profiles'),
      subtitle: tr(
        'Объединяйте домашние устройства в профили для фильтрации контента, SafeSearch и расписаний.',
        'Group household devices to apply SafeSearch, ad blocking, and parental schedules.',
      ),
      addLabel: `+ ${tr('Новый профиль', 'New Profile')}`,
      filters: [{ id: 'all', label: tr('Все профили', 'All Profiles') }],
    },
    schedule: {
      badge: 'PARENTAL TIME POLICIES',
      title: tr(
        'Родительский контроль и расписания',
        'Parental Control & Schedules',
      ),
      subtitle: tr(
        'Ограничение доступа в интернет или отдельных секций по времени суток и дням недели.',
        'Time-based internet access and section restrictions by day of week.',
      ),
      addLabel: `+ ${tr('Новое правило', 'New Schedule')}`,
      filters: [{ id: 'all', label: tr('Все расписания', 'All Schedules') }],
    },
  };

  const meta = headerMeta[type] || headerMeta.section;

  const toolbarEl = E('div', { class: 'tachyon-studio-toolbar' });
  const bodyEl = E('div', { class: 'tachyon-studio-body' });

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
          `⚡ ${tr('Быстрый мастер настройки', 'Setup Wizard')}`,
        ),
      );
    }

    toolbarEl.appendChild(
      E('div', { class: 'tachyon-studio-toolbar__top' }, [
        E('div', { class: 'tachyon-studio-toolbar__titles' }, [
          E('div', { class: 'tachyon-studio-toolbar__title-row' }, [
            E('h3', { class: 'tachyon-studio-toolbar__title' }, meta.title),
            E(
              'span',
              { class: 'tachyon-studio-toolbar__counter' },
              `${enabledCount} / ${sids.length} ${tr('активно', 'active')}`,
            ),
          ]),
          E('p', { class: 'tachyon-studio-toolbar__subtitle' }, meta.subtitle),
        ]),
        E('div', { class: 'tachyon-studio-toolbar__actions' }, [
          ...extraButtons,
          E('div', { class: 'tachyon-studio-view-switch' }, [
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
              `▦ ${tr('Карточки', 'Cards')}`,
            ),
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
              `☰ ${tr('Конвейер', 'Pipeline')}`,
            ),
          ]),
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

    toolbarEl.appendChild(
      E('div', { class: 'tachyon-studio-toolbar__bottom' }, [
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
        if (activeFilter === 'urltest' && btype !== 'urltest') return false;
        if (activeFilter === 'priority' && btype !== 'priority') return false;
        if (q && !`${sid} ${name} ${btype}`.toLowerCase().includes(q))
          return false;
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

    filteredSids.forEach((sid) => {
      const globalOrderIdx = sids.indexOf(sid) + 1;
      const cardEl = renderEntityCard(sid, globalOrderIdx, sids.length);
      bodyEl.appendChild(cardEl);
    });
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
        bodyEl
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
        sectionRef.renderMoreOptionsModal(sid);
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
      const iconContent = tel.faviconDomain
        ? E('img', {
            src: `https://www.google.com/s2/favicons?domain=${encodeURIComponent(tel.faviconDomain)}&sz=64`,
            alt: '',
            class: 'tachyon-studio-card__favicon',
            error: (ev: Event) => {
              const img = ev.currentTarget as HTMLElement;
              if (img && img.parentElement) {
                img.parentElement.textContent = tel.iconText;
              }
            },
          })
        : tel.iconText;

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
                `🎯 ${c.name}`,
              ),
            )
          : tel.serviceTags.length > 0
            ? tel.serviceTags.map((t) =>
                E(
                  'span',
                  { class: 'tachyon-studio-chip tachyon-studio-chip--cond' },
                  `🎯 ${t}`,
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
            `📡 ${s.name}`,
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
            `⚖️ ${b.name} (${b.type})`,
          ),
        );
      });
      if (!outChips.length) {
        outChips.push(
          E(
            'span',
            { class: 'tachyon-studio-chip tachyon-studio-chip--muted' },
            tel.actionTone === 'block'
              ? '🚫 Блокировка (Reject)'
              : tel.actionTone === 'bypass'
                ? '🟢 Прямой выход (WAN)'
                : tel.actionTone === 'dns'
                  ? `🧭 ${raw.routed_dns_server || 'DNS'}`
                  : tr('Встроенный выход', 'Built-in output'),
          ),
        );
      }

      const card = E(
        'div',
        {
          class: `tachyon-studio-card tachyon-studio-card--section ${enabled ? 'is-enabled' : 'is-disabled'}`,
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
                  class: 'tachyon-studio-card__icon',
                  style: `background:${tel.iconBg};color:${tel.iconColor};`,
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
              `📜 ${tr('Правила', 'Rules')}`,
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
              `⧉ ${tr('Клон', 'Clone')}`,
            ),
            E(
              'button',
              {
                type: 'button',
                class:
                  'tachyon-studio-action-btn tachyon-studio-action-btn--primary',
                click: openEditModal,
              },
              `⚙️ ${tr('Изменить', 'Configure')}`,
            ),
            E(
              'button',
              {
                type: 'button',
                class:
                  'tachyon-studio-action-btn tachyon-studio-action-btn--danger',
                click: handleDelete,
              },
              `🗑`,
            ),
          ]),
        ],
      );
      attachDragAndOrderHandlers(card);
      return card;
    }

    // ── CASE 2: OUTBOUND SOURCE ─────────────────────────────────────────────
    if (type === 'outbound_source') {
      const name = raw.name || raw.label || sid;
      const stype = String(raw.source_type || 'subscription').toLowerCase();
      const usedIn = (uci.sections(UCI_PACKAGE, 'section') || [])
        .filter((s: any) => asArray(s.outbound_source_refs).includes(sid))
        .map((s: any) => ({
          id: s['.name'],
          name: s.label || s.name || s['.name'],
        }));

      const links = asArray(raw.proxy_links);
      const parsedLinks = extractLinkProtocolsAndTransports(links);

      const typeBadges: HTMLElement[] = [];
      let icon = '📡';
      let tone: 'proxy' | 'dpi' | 'bypass' = 'proxy';
      if (stype === 'subscription') {
        icon = '📡';
        typeBadges.push(
          E(
            'span',
            { class: 'tachyon-studio-badge tachyon-studio-badge--proxy' },
            tr('ПОДПИСКА', 'SUBSCRIPTION'),
          ),
        );
      } else if (stype === 'proxy_links') {
        icon = '🔗';
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
      } else if (
        ['desync', 'zapret', 'zapret2', 'byedpi', 'wdtt', 'olcrtc'].includes(
          stype,
        )
      ) {
        icon = '🛡️';
        tone = 'dpi';
        const preset = raw.desync_preset || 'auto';
        typeBadges.push(
          E(
            'span',
            { class: 'tachyon-studio-badge tachyon-studio-badge--dpi' },
            `${stype.toUpperCase()} (${preset})`,
          ),
        );
      } else {
        icon = '🚀';
        tone = 'bypass';
        typeBadges.push(
          E(
            'span',
            { class: 'tachyon-studio-badge tachyon-studio-badge--proto' },
            stype.toUpperCase(),
          ),
        );
      }

      if (raw.node_prefix) {
        typeBadges.push(
          E(
            'span',
            { class: 'tachyon-studio-badge tachyon-studio-badge--transport' },
            `🏷 ${raw.node_prefix}`,
          ),
        );
      }

      let paramSummary = '';
      if (stype === 'subscription') {
        const u = String(raw.url || '');
        paramSummary =
          u.length > 58
            ? `${u.slice(0, 38)}…${u.slice(-14)}`
            : u || tr('URL не указан', 'No URL configured');
      } else if (stype === 'proxy_links') {
        paramSummary = `${tr('Прокси-ссылки', 'Proxy links')}: ${links.length} ${parsedLinks.protocols.length ? `(${parsedLinks.protocols.join(', ')})` : ''}`;
      } else if (stype === 'fptn') {
        const tok = String(raw.access_token || '');
        paramSummary = tok ? `FPTN: ${tok.slice(0, 26)}…` : 'FPTN VPN';
      } else if (stype === 'desync') {
        paramSummary = `Desync (${raw.desync_preset || 'auto'})`;
      } else {
        paramSummary = stype.toUpperCase();
      }

      const card = E(
        'div',
        {
          class: `tachyon-studio-card tachyon-studio-card--source ${enabled ? 'is-enabled' : 'is-disabled'}`,
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
                  class: `tachyon-studio-card__icon tachyon-studio-card__icon--${tone}`,
                },
                icon,
              ),
              E('div', { class: 'tachyon-studio-card__title-wrap' }, [
                E('div', { class: 'tachyon-studio-card__title-row' }, [
                  E('span', { class: 'tachyon-studio-card__title' }, name),
                  ...typeBadges,
                ]),
                E('div', { class: 'tachyon-studio-card__sid' }, paramSummary),
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
                tr('Используется в секциях', 'Used in Sections'),
              ),
              E(
                'div',
                { class: 'tachyon-studio-card__chips' },
                usedIn.length
                  ? usedIn.map((u: any) =>
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
                        `📍 ${u.name}`,
                      ),
                    )
                  : [
                      E(
                        'span',
                        {
                          class:
                            'tachyon-studio-chip tachyon-studio-chip--muted',
                        },
                        tr(
                          'В общем пуле (не привязан напрямую)',
                          'Available in pool (not attached yet)',
                        ),
                      ),
                    ],
              ),
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
              `⚙️ ${tr('Изменить', 'Configure')}`,
            ),
            E(
              'button',
              {
                type: 'button',
                class:
                  'tachyon-studio-action-btn tachyon-studio-action-btn--danger',
                click: handleDelete,
              },
              `🗑`,
            ),
          ]),
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

      const ruleChips: HTMLElement[] = [];
      comm.forEach((srv) => {
        ruleChips.push(
          E(
            'span',
            { class: 'tachyon-studio-chip tachyon-studio-chip--cond' },
            `🎯 ${srv}`,
          ),
        );
      });
      doms.slice(0, 4).forEach((d) => {
        ruleChips.push(
          E(
            'span',
            { class: 'tachyon-studio-chip tachyon-studio-chip--source' },
            `🌐 ${d}`,
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
            `📌 ${ip}`,
          ),
        );
      });
      geos.forEach((g) => {
        ruleChips.push(
          E(
            'span',
            { class: 'tachyon-studio-chip tachyon-studio-chip--balancer' },
            `🌍 GeoIP: ${g.toUpperCase()}`,
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
                ctype === 'composite' ? '🧩' : '🎯',
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
                          `📍 ${u.name}`,
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
              `⚙️ ${tr('Изменить', 'Configure')}`,
            ),
            E(
              'button',
              {
                type: 'button',
                class:
                  'tachyon-studio-action-btn tachyon-studio-action-btn--danger',
                click: handleDelete,
              },
              `🗑`,
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
      const usedInObjs = (uci.sections(UCI_PACKAGE, 'section') || [])
        .filter((s: any) => asArray(s.balancer_refs).includes(sid))
        .map((s: any) => ({
          id: s['.name'],
          name: s.label || s.name || s['.name'],
        }));
      const usedIn = usedInObjs.map((u: any) => u.name);

      const interval =
        raw.check_interval || (btype === 'priority' ? '30s' : '3m');
      const tolerance = raw.tolerance || '50';
      const testUrl = raw.testing_url || 'https://www.gstatic.com/generate_204';
      const excCountries = asArray(raw.exclude_countries);
      const incCountries = asArray(raw.include_countries);
      const excServers = asArray(raw.exclude_outbounds);

      const policyChips: HTMLElement[] = [
        E(
          'span',
          { class: 'tachyon-studio-chip tachyon-studio-chip--source' },
          `⏱ ${tr('Интервал', 'Interval')}: ${interval}`,
        ),
      ];
      if (btype === 'urltest') {
        policyChips.push(
          E(
            'span',
            { class: 'tachyon-studio-chip tachyon-studio-chip--cond' },
            `🎯 ${tr('Допуск', 'Tolerance')}: ${tolerance} ms`,
          ),
        );
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
            `🚫 -${excCountries.join(', -')}`,
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
                btype === 'priority' ? '🛡️' : '⚡',
              ),
              E('div', { class: 'tachyon-studio-card__title-wrap' }, [
                E('div', { class: 'tachyon-studio-card__title-row' }, [
                  E('span', { class: 'tachyon-studio-card__title' }, name),
                  E(
                    'span',
                    {
                      class: 'tachyon-studio-badge tachyon-studio-badge--proxy',
                    },
                    btype === 'priority'
                      ? 'PRIORITY • КАСКАД'
                      : 'URLTEST • АВТОВЫБОР',
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
                          `📍 ${u.name}`,
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
              `⚙️ ${tr('Изменить', 'Configure Policy')}`,
            ),
            E(
              'button',
              {
                type: 'button',
                class:
                  'tachyon-studio-action-btn tachyon-studio-action-btn--danger',
                click: handleDelete,
              },
              `🗑`,
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
                proto === 'awg'
                  ? '🛡️'
                  : proto === 'hysteria2' || proto === 'tuic'
                    ? '🚀'
                    : '⚡',
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
                  `${tr('Порт', 'Port')}: :${port} • ${enabled ? tr('Активен', 'Listening') : tr('Остановлен', 'Stopped')}`,
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
              `📱 ${tr('QR / Подключение', 'QR / Client Link')}`,
            ),
            E(
              'button',
              {
                type: 'button',
                class:
                  'tachyon-studio-action-btn tachyon-studio-action-btn--primary',
                click: openEditModal,
              },
              `⚙️ ${tr('Изменить', 'Configure')}`,
            ),
            E(
              'button',
              {
                type: 'button',
                class:
                  'tachyon-studio-action-btn tachyon-studio-action-btn--danger',
                click: handleDelete,
              },
              `🗑`,
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
              type === 'profile' ? '👨‍👩‍👧' : '⏰',
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
            `⚙️ ${tr('Изменить', 'Configure')}`,
          ),
          E(
            'button',
            {
              type: 'button',
              class:
                'tachyon-studio-action-btn tachyon-studio-action-btn--danger',
              click: handleDelete,
            },
            `🗑`,
          ),
        ]),
      ],
    );
    attachDragAndOrderHandlers(card);
    return card;
  };

  deckRoot.appendChild(toolbarEl);
  deckRoot.appendChild(bodyEl);

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
}
