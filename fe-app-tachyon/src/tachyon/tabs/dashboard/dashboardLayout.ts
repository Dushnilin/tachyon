/* eslint-disable @typescript-eslint/no-explicit-any */
import { svgEl } from '../../../helpers';
import { tr } from '../../helpers/i18n';
import {
  renderBarChart2Icon,
  renderCompassIcon,
  renderLayersIcon,
  renderLayoutGridIcon,
  renderScaleIcon,
  renderServerIcon,
  renderShieldIcon,
  renderSlidersIcon,
  renderSparklesIcon,
  renderTargetIcon,
  renderTrendingUpIcon,
  renderUsersIcon,
} from '../../../icons';

export type DashboardWidgetId =
  | 'kpi'
  | 'routing_sections'
  | 'traffic_chart'
  | 'system_status'
  | 'router_services'
  | 'active_clients'
  | 'inbounds';

export type DashboardWidgetWidth = 'full' | 'half';

export type DashboardPresetId =
  | 'standard'
  | 'command_center'
  | 'noc_analytics'
  | 'bento_cards'
  | 'minimal_zen'
  | 'custom';

export interface DashboardWidgetPlacement {
  id: DashboardWidgetId;
  enabled: boolean;
  view: string;
  width: DashboardWidgetWidth;
}

export interface DashboardLayoutConfig {
  preset: DashboardPresetId;
  widgets: DashboardWidgetPlacement[];
}

export interface DashboardWidgetViewOption {
  id: string;
  labelRu: string;
  labelEn: string;
  descRu: string;
  descEn: string;
}

export interface DashboardWidgetCatalogEntry {
  id: DashboardWidgetId;
  slotId: string;
  icon: string;
  titleRu: string;
  titleEn: string;
  descRu: string;
  descEn: string;
  defaultView: string;
  defaultWidth: DashboardWidgetWidth;
  views: DashboardWidgetViewOption[];
}

export interface DashboardPresetDefinition {
  id: Exclude<DashboardPresetId, 'custom'>;
  icon: string;
  badgeRu: string;
  badgeEn: string;
  titleRu: string;
  titleEn: string;
  descRu: string;
  descEn: string;
  widgets: DashboardWidgetPlacement[];
}

const STORAGE_KEY = 'tachyon_dashboard_layout_v4';
const LAYOUT_SCHEMA_VERSION = 4;
const LEGACY_STORAGE_KEYS = [
  'tachyon_dashboard_layout_v1',
  'tachyon_dashboard_layout_v2',
  'tachyon_dashboard_layout_v3',
];
const LAYOUT_CHANGE_EVENT = 'tachyon:dashboard-layout-changed';

export function getWidgetIconEl(
  widgetId: string,
  size: number = 16,
): SVGElement {
  switch (widgetId) {
    case 'kpi':
      return renderTrendingUpIcon(size);
    case 'routing_sections':
      return renderCompassIcon(size);
    case 'traffic_chart':
      return renderBarChart2Icon(size);
    case 'system_status':
      return renderSlidersIcon(size);
    case 'router_services':
      return renderServerIcon(size);
    case 'active_clients':
      return renderUsersIcon(size);
    case 'inbounds':
      return renderShieldIcon(size);
    default:
      return renderLayersIcon(size);
  }
}

export function getPresetIconEl(
  presetId: string,
  size: number = 16,
): SVGElement {
  switch (presetId) {
    case 'standard':
      return renderScaleIcon(size);
    case 'command_center':
      return renderTargetIcon(size);
    case 'noc_analytics':
      return renderBarChart2Icon(size);
    case 'bento_cards':
      return renderLayoutGridIcon(size);
    case 'minimal_zen':
      return renderSparklesIcon(size);
    case 'custom':
      return renderSlidersIcon(size);
    default:
      return renderLayersIcon(size);
  }
}

export const DASHBOARD_WIDGET_CATALOG: DashboardWidgetCatalogEntry[] = [
  {
    id: 'kpi',
    slotId: 'dashboard-kpi-row',
    icon: '',
    titleRu: 'Сводные метрики (KPI)',
    titleEn: 'Summary Metrics (KPI)',
    descRu: 'Клиенты, активные секции, общий трафик и средняя задержка',
    descEn: 'Clients, active sections, total traffic and average latency',
    defaultView: 'cards',
    defaultWidth: 'full',
    views: [
      {
        id: 'cards',
        labelRu: 'Карточки со спарклайнами',
        labelEn: 'Sparkline Cards',
        descRu: '4 карточки с мини-графиками динамики и бейджами',
        descEn: '4 cards with trend sparklines and status badges',
      },
      {
        id: 'compact_strip',
        labelRu: 'Компактная лента (1 строка)',
        labelEn: 'Compact Strip (1 Row)',
        descRu: 'Единая узкая панель всех ключевых показателей без спарклайнов',
        descEn: 'Single slim horizontal bar with all key metrics',
      },
      {
        id: 'stat_pills',
        labelRu: 'Крупные плашки-индикаторы',
        labelEn: 'Large Stat Tiles',
        descRu: 'Контрастные цифровые плитки с акцентом на скорость и пинг',
        descEn: 'High-contrast digital tiles focused on speed and latency',
      },
      {
        id: 'glass_telemetry',
        labelRu: 'Телеметрические капсулы',
        labelEn: 'Telemetry Capsules',
        descRu: 'Капсулы со шкалами заполнения и неоновыми индикаторами пульса',
        descEn: 'Capsules with progress bars and neon pulse indicators',
      },
      {
        id: 'minimal_counters',
        labelRu: 'Строгая типографика',
        labelEn: 'Minimal Counters',
        descRu: 'Чистые крупные числа с тонкими разделителями без рамок',
        descEn: 'Clean large numbers with subtle dividers and zero clutter',
      },
    ],
  },
  {
    id: 'routing_sections',
    slotId: 'dashboard-sections-grid',
    icon: '',
    titleRu: 'Секции маршрутизации',
    titleEn: 'Routing Sections',
    descRu: 'Секции правил, протоколы (VLESS/GRPC/XHTTP), серверы и пинг',
    descEn: 'Routing sections, protocols (VLESS/GRPC/XHTTP), servers and ping',
    defaultView: 'rows',
    defaultWidth: 'full',
    views: [
      {
        id: 'rows',
        labelRu: 'Выровненные строки (Таблица)',
        labelEn: 'Aligned Rows (Table)',
        descRu: 'Строго выровненные строки с бейджами протоколов и транспорта',
        descEn: 'Strictly aligned rows with protocol and transport badges',
      },
      {
        id: 'cards_grid',
        labelRu: 'Сетка карточек (Bento 2–3 в ряд)',
        labelEn: 'Cards Grid (Bento 2–3 per row)',
        descRu:
          'Плиточные карточки секций с деталями сервера, селектора и трафика',
        descEn: 'Bento section cards with server, selector and traffic details',
      },
      {
        id: 'compact_tiles',
        labelRu: 'Компактные мини-плитки',
        labelEn: 'Compact Mini-Tiles',
        descRu: 'Плотные мини-плитки (3–4 в ряд) для быстрого обзора и клика',
        descEn:
          'Dense mini-tiles (3–4 per row) for quick status and inspection',
      },
      {
        id: 'protocol_matrix',
        labelRu: 'Матрица протоколов (2 в ряд)',
        labelEn: 'Protocol Matrix (2-Col)',
        descRu: 'Двухколоночная матрица секций с акцентом на узел и задержку',
        descEn: 'Two-column section matrix focused on active node and latency',
      },
    ],
  },
  {
    id: 'traffic_chart',
    slotId: 'dashboard-traffic-chart-card',
    icon: '',
    titleRu: 'Монитор трафика реального времени',
    titleEn: 'Real-Time Traffic Monitor',
    descRu: 'Динамика скорости входящего и исходящего потока',
    descEn: 'Live downlink and uplink throughput visualization',
    defaultView: 'area',
    defaultWidth: 'half',
    views: [
      {
        id: 'area',
        labelRu: 'Волновой график (Area SVG)',
        labelEn: 'Wave Chart (Area SVG)',
        descRu: 'Плавные двухканальные кривые загрузки и отдачи с заливкой',
        descEn: 'Smooth dual-channel downlink/uplink area curves',
      },
      {
        id: 'bars',
        labelRu: 'Столбчатый спектр (Гистограмма)',
        labelEn: 'Bar Spectrum (Histogram)',
        descRu: 'Вертикальные столбики истории скорости с индикацией пиков',
        descEn: 'Vertical throughput bars with peak rate indicator',
      },
      {
        id: 'gauges',
        labelRu: 'Спидометры и шкалы нагрузки',
        labelEn: 'Speed Gauges & Load Bars',
        descRu: 'Наглядные шкалы текущей и пиковой скорости Downlink / Uplink',
        descEn: 'Visual gauges for current and peak Downlink / Uplink speeds',
      },
      {
        id: 'dual_telemetry',
        labelRu: 'Цифровые табло RX / TX',
        labelEn: 'Digital RX / TX Readouts',
        descRu: 'Два крупных табло приёма и отдачи с пиками и мини-спарклайном',
        descEn: 'Dual large RX/TX digital readouts with peak and sparkline',
      },
    ],
  },
  {
    id: 'system_status',
    slotId: 'dashboard-widget-system-services',
    icon: '',
    titleRu: 'Маршрутизация и система',
    titleEn: 'Routing & System Status',
    descRu:
      'Режим перехвата TProxy, переключатель Tachyon Lite и счётчики ядра',
    descEn: 'TProxy interception mode, Tachyon Lite toggle and core counters',
    defaultView: 'card',
    defaultWidth: 'half',
    views: [
      {
        id: 'card',
        labelRu: 'Классическая карточка',
        labelEn: 'Classic Card',
        descRu:
          'Структурированный список параметров маршрутизации и эко-режима',
        descEn: 'Structured list of routing parameters and eco-mode toggle',
      },
      {
        id: 'tiles',
        labelRu: 'Плитки параметров 2×2',
        labelEn: '2×2 Parameter Tiles',
        descRu: 'Крупные плитки: режим, Tachyon Lite, соединения и клиенты',
        descEn: 'Modular tiles for mode, Tachyon Lite, connections and clients',
      },
      {
        id: 'banner',
        labelRu: 'Горизонтальный баннер',
        labelEn: 'Horizontal Banner',
        descRu:
          'Горизонтальная строка статуса системы и быстрого переключения Lite',
        descEn: 'Single-row system status bar with quick Lite mode switch',
      },
      {
        id: 'cockpit_hud',
        labelRu: 'Приборная панель (HUD)',
        labelEn: 'Cockpit HUD',
        descRu: 'Телеметрическая панель ядра с индикаторами режима и нагрузки',
        descEn: 'Core telemetry HUD with interception and load indicators',
      },
    ],
  },
  {
    id: 'router_services',
    slotId: 'dashboard-router-services-strip',
    icon: '',
    titleRu: 'Службы роутера',
    titleEn: 'Router Services',
    descRu: 'Статус процессов Tachyon, Sing-box, Dnsmasq и Zapret2',
    descEn: 'Process health, RAM and uptime for Tachyon, Sing-box, Dnsmasq',
    defaultView: 'strip',
    defaultWidth: 'full',
    views: [
      {
        id: 'strip',
        labelRu: 'Горизонтальная лента',
        labelEn: 'Horizontal Strip',
        descRu: 'Компактная лента служб с индикаторами памяти и аптайма',
        descEn: 'Compact horizontal strip with RAM and uptime pills',
      },
      {
        id: 'cards',
        labelRu: 'Карточки служб',
        labelEn: 'Service Cards',
        descRu: 'Отдельные мини-карточки для каждой службы с RAM и аптаймом',
        descEn: 'Individual mini-cards per service with RAM and uptime',
      },
      {
        id: 'minimal',
        labelRu: 'Мини-пилюли с огоньком',
        labelEn: 'Minimal LED Pills',
        descRu: 'Лаконичные теги служб со светящимся зелёным индикатором',
        descEn: 'Clean service tags with glowing green LED dots',
      },
      {
        id: 'resource_bars',
        labelRu: 'Плитки ресурсов (RAM)',
        labelEn: 'Resource Bars (RAM)',
        descRu:
          'Карточки служб с наглядной шкалой потребления оперативной памяти',
        descEn: 'Service tiles with visual RAM consumption progress bars',
      },
    ],
  },
  {
    id: 'active_clients',
    slotId: 'dashboard-connections-grid',
    icon: '',
    titleRu: 'Активные клиенты и домены',
    titleEn: 'Active Clients & Domains',
    descRu: 'Локальные устройства в сети, их соединения, трафик и топ доменов',
    descEn: 'LAN devices, active connections, session traffic and top domains',
    defaultView: 'collapsible',
    defaultWidth: 'full',
    views: [
      {
        id: 'collapsible',
        labelRu: 'Сворачиваемый список',
        labelEn: 'Collapsible List',
        descRu: 'Компактная шапка, раскрывающая список клиентов по клику',
        descEn: 'Collapsible header that expands client rows on click',
      },
      {
        id: 'expanded',
        labelRu: 'Всегда развёрнутая таблица',
        labelEn: 'Always Expanded Table',
        descRu: 'Постоянно открытый список активных клиентов и трафика',
        descEn: 'Always visible list of active clients and their traffic',
      },
      {
        id: 'domains_focus',
        labelRu: 'Витрина доменов + чипы клиентов',
        labelEn: 'Top Domains + Client Chips',
        descRu:
          'Акцент на популярных доменах в обходе и компактных чипах устройств',
        descEn: 'Focus on top bypassed domains and compact client chips',
      },
      {
        id: 'client_cards',
        labelRu: 'Карточки устройств (Сетка)',
        labelEn: 'Device Cards Grid',
        descRu: 'Плиточная сетка активных устройств с трафиком и числом сессий',
        descEn: 'Grid of active LAN device cards with traffic and sessions',
      },
    ],
  },
  {
    id: 'inbounds',
    slotId: 'dashboard-widget-inbounds',
    icon: '',
    titleRu: 'Входящие серверы (Inbounds)',
    titleEn: 'Inbound Servers',
    descRu: 'Собственные VPN/прокси-серверы, запущенные на роутере',
    descEn: 'Self-hosted VPN/proxy inbound servers running on the router',
    defaultView: 'collapsible',
    defaultWidth: 'full',
    views: [
      {
        id: 'collapsible',
        labelRu: 'Сворачиваемая панель',
        labelEn: 'Collapsible Panel',
        descRu: 'Сводная шапка со списком серверов по клику',
        descEn: 'Summary bar with expandable inbound server cards',
      },
      {
        id: 'expanded_cards',
        labelRu: 'Развёрнутые карточки серверов',
        labelEn: 'Expanded Server Cards',
        descRu: 'Всегда открытая сетка карточек входящих серверов и QR-кодов',
        descEn: 'Always expanded grid of inbound server cards and QR links',
      },
      {
        id: 'compact_chips',
        labelRu: 'Компактные чипы портов',
        labelEn: 'Compact Port Chips',
        descRu:
          'Однострочные чипы активных портов, протоколов и числа клиентов',
        descEn: 'Single-line chips showing active ports, protocols and clients',
      },
      {
        id: 'port_matrix',
        labelRu: 'Таблица портов и протоколов',
        labelEn: 'Port & Protocol Matrix',
        descRu: 'Структурированная таблица входящих серверов, портов и пиров',
        descEn: 'Structured matrix of inbound listeners, ports and peers',
      },
    ],
  },
];

export const DASHBOARD_PRESETS: DashboardPresetDefinition[] = [
  {
    id: 'standard',
    icon: '',
    badgeRu: 'По умолчанию',
    badgeEn: 'Default',
    titleRu: 'Классический (Стандартный)',
    titleEn: 'Classic Standard',
    descRu:
      'Исходная раскладка: карточки KPI сверху, график волны + система в 2 колонки, службы, серверы, клиенты и секции маршрутизации',
    descEn:
      'Original layout: KPI cards on top, wave chart + system status side-by-side, services, inbounds, clients and routing sections',
    widgets: [
      { id: 'kpi', enabled: true, view: 'cards', width: 'full' },
      { id: 'traffic_chart', enabled: true, view: 'area', width: 'half' },
      { id: 'system_status', enabled: true, view: 'card', width: 'half' },
      { id: 'router_services', enabled: true, view: 'strip', width: 'full' },
      { id: 'inbounds', enabled: true, view: 'collapsible', width: 'full' },
      {
        id: 'active_clients',
        enabled: true,
        view: 'collapsible',
        width: 'full',
      },
      { id: 'routing_sections', enabled: true, view: 'rows', width: 'full' },
    ],
  },
  {
    id: 'command_center',
    icon: '',
    badgeRu: 'Маршруты',
    badgeEn: 'Routing',
    titleRu: 'Центр управления',
    titleEn: 'Command Center',
    descRu:
      'Секции маршрутизации на первом месте, узкая лента KPI, спидометры и плитки системы 2×2',
    descEn:
      'Routing sections first, slim KPI strip, speed gauges and 2×2 system tiles',
    widgets: [
      { id: 'routing_sections', enabled: true, view: 'rows', width: 'full' },
      { id: 'kpi', enabled: true, view: 'compact_strip', width: 'full' },
      { id: 'traffic_chart', enabled: true, view: 'gauges', width: 'half' },
      { id: 'system_status', enabled: true, view: 'tiles', width: 'half' },
      { id: 'router_services', enabled: true, view: 'minimal', width: 'full' },
      { id: 'inbounds', enabled: true, view: 'compact_chips', width: 'full' },
      {
        id: 'active_clients',
        enabled: true,
        view: 'collapsible',
        width: 'full',
      },
    ],
  },
  {
    id: 'noc_analytics',
    icon: '',
    badgeRu: 'Трафик и NOC',
    badgeEn: 'NOC Monitor',
    titleRu: 'Аналитика и Трафик',
    titleEn: 'NOC & Traffic Analytics',
    descRu:
      'Телеметрические капсулы KPI, широкий спектр трафика, карточки устройств и шкалы ресурсов служб',
    descEn:
      'Telemetry KPI capsules, full-width bar spectrum, device cards and service resource bars',
    widgets: [
      { id: 'kpi', enabled: true, view: 'glass_telemetry', width: 'full' },
      { id: 'traffic_chart', enabled: true, view: 'bars', width: 'full' },
      {
        id: 'active_clients',
        enabled: true,
        view: 'client_cards',
        width: 'half',
      },
      {
        id: 'router_services',
        enabled: true,
        view: 'resource_bars',
        width: 'half',
      },
      {
        id: 'routing_sections',
        enabled: true,
        view: 'protocol_matrix',
        width: 'full',
      },
      {
        id: 'system_status',
        enabled: true,
        view: 'cockpit_hud',
        width: 'full',
      },
      { id: 'inbounds', enabled: true, view: 'port_matrix', width: 'full' },
    ],
  },
  {
    id: 'bento_cards',
    icon: '',
    badgeRu: 'Модульный',
    badgeEn: 'Bento Grid',
    titleRu: 'Плиточный Bento',
    titleEn: 'Bento Cards Grid',
    descRu:
      'Секции в виде Bento-карточек, цифровые табло трафика, витрина доменов, карточки служб и плитки 2×2',
    descEn:
      'Bento section cards, digital traffic readouts, top domains showcase, service cards and 2×2 system tiles',
    widgets: [
      {
        id: 'routing_sections',
        enabled: true,
        view: 'cards_grid',
        width: 'full',
      },
      { id: 'kpi', enabled: true, view: 'stat_pills', width: 'full' },
      {
        id: 'traffic_chart',
        enabled: true,
        view: 'dual_telemetry',
        width: 'half',
      },
      { id: 'system_status', enabled: true, view: 'tiles', width: 'half' },
      { id: 'router_services', enabled: true, view: 'cards', width: 'half' },
      {
        id: 'active_clients',
        enabled: true,
        view: 'domains_focus',
        width: 'half',
      },
      { id: 'inbounds', enabled: true, view: 'expanded_cards', width: 'full' },
    ],
  },
  {
    id: 'minimal_zen',
    icon: '',
    badgeRu: 'Лаконичный',
    badgeEn: 'Minimal',
    titleRu: 'Минимализм (Дзен)',
    titleEn: 'Minimal Zen',
    descRu:
      'Только главное на одном экране: чистые счётчики KPI, мини-плитки секций и статус служб',
    descEn:
      'Everything on one screen: clean KPI counters, section mini-tiles and LED service pills',
    widgets: [
      { id: 'kpi', enabled: true, view: 'minimal_counters', width: 'full' },
      {
        id: 'routing_sections',
        enabled: true,
        view: 'compact_tiles',
        width: 'full',
      },
      { id: 'system_status', enabled: true, view: 'banner', width: 'half' },
      { id: 'router_services', enabled: true, view: 'minimal', width: 'half' },
      { id: 'traffic_chart', enabled: false, view: 'gauges', width: 'half' },
      {
        id: 'active_clients',
        enabled: false,
        view: 'collapsible',
        width: 'full',
      },
      { id: 'inbounds', enabled: false, view: 'compact_chips', width: 'full' },
    ],
  },
];

function clonePlacements(
  list: DashboardWidgetPlacement[],
): DashboardWidgetPlacement[] {
  return list.map((w) => ({
    id: w.id,
    enabled: Boolean(w.enabled),
    view: String(w.view),
    width: w.width === 'half' ? 'half' : 'full',
  }));
}

export function getPresetDefinition(
  presetId: string,
): DashboardPresetDefinition {
  return (
    DASHBOARD_PRESETS.find((p) => p.id === presetId) || DASHBOARD_PRESETS[0]
  );
}

export function getWidgetCatalogEntry(
  id: DashboardWidgetId,
): DashboardWidgetCatalogEntry | undefined {
  return DASHBOARD_WIDGET_CATALOG.find((w) => w.id === id);
}

export function computeAutoFullWidgetIds(
  widgets: DashboardWidgetPlacement[],
): Set<DashboardWidgetId> {
  const autoFull = new Set<DashboardWidgetId>();
  const enabledList = widgets.filter((w) => w.enabled);
  let i = 0;
  while (i < enabledList.length) {
    const cur = enabledList[i];
    if (cur.width === 'half') {
      const next = enabledList[i + 1];
      if (next && next.width === 'half') {
        i += 2;
        continue;
      }
      autoFull.add(cur.id);
    }
    i += 1;
  }
  return autoFull;
}

export function normalizeDashboardLayoutConfig(
  raw: any,
): DashboardLayoutConfig {
  const defaultPreset = DASHBOARD_PRESETS[0];
  if (!raw || typeof raw !== 'object') {
    return {
      preset: defaultPreset.id,
      widgets: clonePlacements(defaultPreset.widgets),
    };
  }

  const presetCandidate = String(raw.preset || defaultPreset.id);
  const validPresetIds = new Set<string>([
    ...DASHBOARD_PRESETS.map((p) => p.id),
    'custom',
  ]);
  const preset = (
    validPresetIds.has(presetCandidate) ? presetCandidate : defaultPreset.id
  ) as DashboardPresetId;

  const basePreset =
    preset !== 'custom' ? getPresetDefinition(preset) : defaultPreset;

  if (!Array.isArray(raw.widgets) || raw.widgets.length === 0) {
    return {
      preset: preset === 'custom' ? defaultPreset.id : preset,
      widgets: clonePlacements(basePreset.widgets),
    };
  }

  // Migrate legacy v1 'standard' order (where routing_sections was second) to the classic pre-widget order
  if (preset === 'standard') {
    const rawIds = raw.widgets
      .map((w: any) => String(w?.id || ''))
      .filter(Boolean)
      .join(',');
    if (
      rawIds ===
      'kpi,routing_sections,traffic_chart,system_status,router_services,active_clients,inbounds'
    ) {
      return {
        preset: defaultPreset.id,
        widgets: clonePlacements(defaultPreset.widgets),
      };
    }
  }

  const catalogById = new Map<DashboardWidgetId, DashboardWidgetCatalogEntry>();
  for (const entry of DASHBOARD_WIDGET_CATALOG) {
    catalogById.set(entry.id, entry);
  }

  const seen = new Set<DashboardWidgetId>();
  const normalizedWidgets: DashboardWidgetPlacement[] = [];

  for (const item of raw.widgets) {
    if (!item || typeof item !== 'object') continue;
    const id = String(item.id || '') as DashboardWidgetId;
    const cat = catalogById.get(id);
    if (!cat || seen.has(id)) continue;
    seen.add(id);

    const validView = cat.views.some((v) => v.id === item.view)
      ? String(item.view)
      : cat.defaultView;
    const width: DashboardWidgetWidth =
      item.width === 'half' || item.width === 'full'
        ? item.width
        : cat.defaultWidth;
    normalizedWidgets.push({
      id,
      enabled: item.enabled !== false,
      view: validView,
      width,
    });
  }

  for (const fallback of basePreset.widgets) {
    if (!seen.has(fallback.id)) {
      seen.add(fallback.id);
      normalizedWidgets.push({ ...fallback });
    }
  }

  const detectedPreset = detectMatchingPreset(normalizedWidgets);

  return {
    preset: detectedPreset || 'custom',
    widgets: normalizedWidgets,
  };
}

export function detectMatchingPreset(
  widgets: DashboardWidgetPlacement[],
): Exclude<DashboardPresetId, 'custom'> | null {
  for (const preset of DASHBOARD_PRESETS) {
    if (preset.widgets.length !== widgets.length) continue;
    const matches = preset.widgets.every((pw, idx) => {
      const w = widgets[idx];
      return (
        w &&
        w.id === pw.id &&
        w.enabled === pw.enabled &&
        w.view === pw.view &&
        w.width === pw.width
      );
    });
    if (matches) {
      return preset.id;
    }
  }
  return null;
}

let cachedLayoutConfig: DashboardLayoutConfig | null = null;

export function getDashboardLayoutConfig(): DashboardLayoutConfig {
  if (cachedLayoutConfig) {
    return {
      preset: cachedLayoutConfig.preset,
      widgets: clonePlacements(cachedLayoutConfig.widgets),
    };
  }

  // 1. Try localStorage first for instant zero-latency UI
  try {
    if (typeof window !== 'undefined' && window.localStorage) {
      LEGACY_STORAGE_KEYS.forEach((legacyKey) => {
        try {
          window.localStorage.removeItem(legacyKey);
        } catch {
          // ignore
        }
      });
      const saved = window.localStorage.getItem(STORAGE_KEY);
      if (saved) {
        const parsed = JSON.parse(saved);
        if (parsed && parsed.schemaVersion === LAYOUT_SCHEMA_VERSION) {
          cachedLayoutConfig = normalizeDashboardLayoutConfig(parsed);
          return {
            preset: cachedLayoutConfig.preset,
            widgets: clonePlacements(cachedLayoutConfig.widgets),
          };
        }
      }
    }
  } catch {
    // ignore storage errors
  }

  // 2. Fallback to UCI if loaded (only if saved with current schemaVersion)
  try {
    const uciObj = (globalThis as any).uci;
    if (uciObj && typeof uciObj.get === 'function') {
      const uciJson =
        uciObj.get('tachyon', 'main', 'dashboard_layout_json') ||
        uciObj.get('tachyon', 'settings', 'dashboard_layout_json');
      if (uciJson) {
        const parsed = JSON.parse(String(uciJson));
        if (parsed && parsed.schemaVersion === LAYOUT_SCHEMA_VERSION) {
          cachedLayoutConfig = normalizeDashboardLayoutConfig(parsed);
          return {
            preset: cachedLayoutConfig.preset,
            widgets: clonePlacements(cachedLayoutConfig.widgets),
          };
        }
      }
    }
  } catch {
    // ignore uci read error
  }

  const fallback = normalizeDashboardLayoutConfig(null);
  cachedLayoutConfig = fallback;
  return {
    preset: fallback.preset,
    widgets: clonePlacements(fallback.widgets),
  };
}

export function getWidgetPlacement(
  widgetId: DashboardWidgetId,
): DashboardWidgetPlacement {
  const cfg = getDashboardLayoutConfig();
  const found = cfg.widgets.find((w) => w.id === widgetId);
  if (found) return found;
  const cat = getWidgetCatalogEntry(widgetId);
  return {
    id: widgetId,
    enabled: true,
    view: cat?.defaultView || 'default',
    width: cat?.defaultWidth || 'full',
  };
}

export function getWidgetViewMode(widgetId: DashboardWidgetId): string {
  return getWidgetPlacement(widgetId).view;
}

export function isWidgetEnabled(widgetId: DashboardWidgetId): boolean {
  return getWidgetPlacement(widgetId).enabled;
}

export function saveDashboardLayoutConfig(
  nextConfig: DashboardLayoutConfig,
  options?: { syncUci?: boolean; sectionId?: string; silent?: boolean },
): DashboardLayoutConfig {
  const normalized = normalizeDashboardLayoutConfig(nextConfig);
  cachedLayoutConfig = normalized;
  const payload = {
    ...normalized,
    schemaVersion: LAYOUT_SCHEMA_VERSION,
  };

  try {
    if (typeof window !== 'undefined' && window.localStorage) {
      window.localStorage.setItem(STORAGE_KEY, JSON.stringify(payload));
    }
  } catch {
    // ignore storage errors
  }

  if (options?.syncUci !== false) {
    try {
      const uciObj = (globalThis as any).uci;
      if (uciObj && typeof uciObj.set === 'function') {
        const targetSec = options?.sectionId || 'main';
        const prevPreset = uciObj.get('tachyon', targetSec, 'dashboard_preset');
        if (prevPreset !== normalized.preset) {
          uciObj.set(
            'tachyon',
            targetSec,
            'dashboard_preset',
            normalized.preset,
          );
        }
        const serialized = JSON.stringify(payload);
        const prevJson = uciObj.get(
          'tachyon',
          targetSec,
          'dashboard_layout_json',
        );
        if (prevJson !== serialized) {
          uciObj.set('tachyon', targetSec, 'dashboard_layout_json', serialized);
        }
      }
    } catch {
      // ignore uci error
    }
  }

  if (!options?.silent) {
    applyDashboardLayoutToDom(normalized);
    if (typeof window !== 'undefined' && typeof CustomEvent !== 'undefined') {
      window.dispatchEvent(
        new CustomEvent(LAYOUT_CHANGE_EVENT, { detail: normalized }),
      );
    }
  }

  return normalized;
}

export function applyDashboardPreset(
  presetId: Exclude<DashboardPresetId, 'custom'>,
  options?: { syncUci?: boolean; sectionId?: string },
): DashboardLayoutConfig {
  const preset = getPresetDefinition(presetId);
  return saveDashboardLayoutConfig(
    {
      preset: preset.id,
      widgets: clonePlacements(preset.widgets),
    },
    options,
  );
}

export function subscribeDashboardLayoutChanges(
  listener: (cfg: DashboardLayoutConfig) => void,
): () => void {
  if (typeof window === 'undefined') return () => {};
  const handler = (ev: Event) => {
    const customEv = ev as CustomEvent<DashboardLayoutConfig>;
    listener(customEv.detail || getDashboardLayoutConfig());
  };
  window.addEventListener(LAYOUT_CHANGE_EVENT, handler);
  return () => window.removeEventListener(LAYOUT_CHANGE_EVENT, handler);
}

export function applyDashboardLayoutToDom(
  configOverride?: DashboardLayoutConfig,
): void {
  if (typeof document === 'undefined') return;
  const cfg = configOverride || getDashboardLayoutConfig();
  const contentRoot = document.querySelector<HTMLElement>(
    '#dashboard-status .tachyon_dashboard-page__content',
  );
  if (!contentRoot) return;

  contentRoot.setAttribute('data-dashboard-preset', cfg.preset);

  // Legacy wrappers: ensure widget slots are direct children of contentRoot
  for (const wrapperId of [
    'dashboard-kpi-chart-split',
    'dashboard-overview-row',
  ]) {
    const legacyWrap = document.getElementById(wrapperId);
    if (legacyWrap && legacyWrap.parentElement === contentRoot) {
      while (legacyWrap.firstChild) {
        contentRoot.insertBefore(legacyWrap.firstChild, legacyWrap);
      }
      legacyWrap.remove();
    }
  }

  const slotElements: HTMLElement[] = [];
  const autoFullIds = computeAutoFullWidgetIds(cfg.widgets);

  cfg.widgets.forEach((placement, index) => {
    const cat = getWidgetCatalogEntry(placement.id);
    if (!cat) return;

    const slotEl = document.getElementById(cat.slotId);
    if (!slotEl) return;

    const isAutoFull = autoFullIds.has(placement.id);
    slotEl.classList.add('tachyon-dashboard-widget-slot');
    slotEl.classList.toggle(
      'tachyon-dashboard-widget-slot--half',
      placement.width === 'half' && !isAutoFull,
    );
    slotEl.classList.toggle(
      'tachyon-dashboard-widget-slot--full',
      placement.width !== 'half',
    );
    slotEl.classList.toggle(
      'tachyon-dashboard-widget-slot--auto-full',
      isAutoFull,
    );
    slotEl.classList.toggle(
      'tachyon-dashboard-widget-slot--hidden',
      !placement.enabled,
    );
    slotEl.setAttribute('data-widget-id', placement.id);
    slotEl.setAttribute('data-widget-view', placement.view);
    slotEl.setAttribute('data-widget-width', placement.width);
    slotEl.style.order = String(index + 1);

    if (!placement.enabled) {
      slotEl.style.display = 'none';
    } else {
      slotEl.style.display = '';
    }

    slotElements.push(slotEl);
  });

  // Physically reorder DOM slots to match widget order for accessibility & clean grid flow
  for (const slotEl of slotElements) {
    if (slotEl.parentElement === contentRoot) {
      contentRoot.appendChild(slotEl);
    }
  }

  // Refresh the quick preset toolbar active state if mounted
  refreshDashboardPresetToolbarInDom(cfg);
}

export function refreshDashboardPresetToolbarInDom(
  configOverride?: DashboardLayoutConfig,
): void {
  if (typeof document === 'undefined') return;
  const bar = document.getElementById('dashboard-preset-toolbar');
  if (!bar) return;
  const cfg = configOverride || getDashboardLayoutConfig();

  const pills = Array.from(
    bar.querySelectorAll<HTMLElement>('[data-dashboard-preset-btn]'),
  );
  for (const pill of pills) {
    const pid = pill.getAttribute('data-dashboard-preset-btn');
    pill.classList.toggle('is-active', pid === cfg.preset);
  }
}

export function renderDashboardPresetToolbar(
  onLayoutUpdated?: (cfg: DashboardLayoutConfig) => void,
): HTMLElement {
  const cfg = getDashboardLayoutConfig();

  const presetButtons = DASHBOARD_PRESETS.map((preset) => {
    const isActive = cfg.preset === preset.id;
    return E(
      'button',
      {
        type: 'button',
        class: `tachyon-dash-preset-pill ${isActive ? 'is-active' : ''}`,
        'data-dashboard-preset-btn': preset.id,
        title: tr(preset.descRu, preset.descEn),
        click: (ev: MouseEvent) => {
          ev.preventDefault();
          const next = applyDashboardPreset(preset.id);
          refreshDashboardPresetToolbarInDom(next);
          if (onLayoutUpdated) onLayoutUpdated(next);
        },
      } as any,
      [
        E('span', { class: 'tachyon-dash-preset-pill__icon' }, [
          getPresetIconEl(preset.id, 14),
        ]),
        E(
          'span',
          { class: 'tachyon-dash-preset-pill__label' },
          tr(preset.titleRu, preset.titleEn),
        ),
      ],
    );
  });

  const customizeBtn = E(
    'button',
    {
      type: 'button',
      class: `tachyon-dash-preset-pill tachyon-dash-preset-pill--customize ${
        cfg.preset === 'custom' ? 'is-active' : ''
      }`,
      'data-dashboard-preset-btn': 'custom',
      title: tr(
        'Настроить виджеты дашборда, их виды, размер и порядок',
        'Customize dashboard widgets, their views, width and order',
      ),
      click: (ev: MouseEvent) => {
        ev.preventDefault();
        openDashboardCustomizeModal(onLayoutUpdated);
      },
    } as any,
    [
      svgEl(
        'svg',
        {
          width: '14',
          height: '14',
          viewBox: '0 0 24 24',
          fill: 'none',
          stroke: 'currentColor',
          'stroke-width': '2',
          'stroke-linecap': 'round',
          'stroke-linejoin': 'round',
        },
        [
          svgEl('line', { x1: '4', y1: '21', x2: '4', y2: '14' }),
          svgEl('line', { x1: '4', y1: '10', x2: '4', y2: '3' }),
          svgEl('line', { x1: '12', y1: '21', x2: '12', y2: '12' }),
          svgEl('line', { x1: '12', y1: '8', x2: '12', y2: '3' }),
          svgEl('line', { x1: '20', y1: '21', x2: '20', y2: '16' }),
          svgEl('line', { x1: '20', y1: '12', x2: '20', y2: '3' }),
          svgEl('line', { x1: '1', y1: '14', x2: '7', y2: '14' }),
          svgEl('line', { x1: '9', y1: '8', x2: '15', y2: '8' }),
          svgEl('line', { x1: '17', y1: '16', x2: '23', y2: '16' }),
        ],
      ),
      E(
        'span',
        {},
        cfg.preset === 'custom'
          ? tr('Свой макет • Виджеты', 'Custom • Widgets')
          : tr('Виджеты и виды', 'Widgets & Views'),
      ),
    ],
  );

  return E(
    'div',
    {
      id: 'dashboard-preset-toolbar',
      class: 'tachyon-dash-preset-toolbar',
    },
    [
      E('div', { class: 'tachyon-dash-preset-toolbar__left' }, [
        E(
          'span',
          { class: 'tachyon-dash-preset-toolbar__caption' },
          tr('Вид дашборда:', 'Dashboard view:'),
        ),
        E(
          'div',
          { class: 'tachyon-dash-preset-toolbar__pills' },
          presetButtons,
        ),
      ]),
      E('div', { class: 'tachyon-dash-preset-toolbar__right' }, [customizeBtn]),
    ],
  );
}

export function buildDashboardLayoutEditorDom(options?: {
  sectionId?: string;
  onChange?: (cfg: DashboardLayoutConfig) => void;
}): HTMLElement {
  let currentCfg = getDashboardLayoutConfig();
  let draggedIdx: number | null = null;

  const root = E('div', {
    id: options?.sectionId
      ? `dashboard-layout-editor-${options.sectionId}`
      : 'dashboard-layout-editor',
    class: 'tachyon-dash-editor',
  });

  const commitChange = (nextCfg: DashboardLayoutConfig) => {
    currentCfg = saveDashboardLayoutConfig(nextCfg, {
      syncUci: true,
      sectionId: options?.sectionId || 'main',
    });
    (root as any)._layoutConfig = currentCfg;
    renderEditorContent();
    if (options?.onChange) {
      options.onChange(currentCfg);
    }
  };

  function renderPresetMiniPreview(presetWidgets: DashboardWidgetPlacement[]) {
    const enabledWidgets = presetWidgets.filter((w) => w.enabled);
    const autoFull = computeAutoFullWidgetIds(presetWidgets);
    return E(
      'div',
      { class: 'tachyon-dash-preset-card__preview' },
      enabledWidgets.slice(0, 6).map((w) =>
        E('span', {
          class: `tachyon-dash-preset-card__preview-block ${
            w.width === 'half' && !autoFull.has(w.id) ? 'is-half' : 'is-full'
          }`,
          title: `${w.id}: ${w.view}`,
        }),
      ),
    );
  }

  function renderViewMiniSchematic(viewId: string): HTMLElement {
    const cls = 'tachyon-view-mini-schematic';
    if (
      viewId === 'cards' ||
      viewId === 'stat_pills' ||
      viewId === 'glass_telemetry' ||
      viewId === 'client_cards'
    ) {
      return E('span', { class: `${cls} ${cls}--grid4` }, [
        E('i'),
        E('i'),
        E('i'),
        E('i'),
      ]);
    }
    if (
      viewId === 'compact_strip' ||
      viewId === 'minimal_counters' ||
      viewId === 'strip' ||
      viewId === 'minimal' ||
      viewId === 'banner' ||
      viewId === 'compact_chips'
    ) {
      return E('span', { class: `${cls} ${cls}--strip` }, [
        E('i'),
        E('i'),
        E('i'),
      ]);
    }
    if (
      viewId === 'rows' ||
      viewId === 'collapsible' ||
      viewId === 'expanded' ||
      viewId === 'port_matrix'
    ) {
      return E('span', { class: `${cls} ${cls}--rows` }, [
        E('i'),
        E('i'),
        E('i'),
      ]);
    }
    if (viewId === 'bars' || viewId === 'resource_bars') {
      return E('span', { class: `${cls} ${cls}--bars` }, [
        E('i'),
        E('i'),
        E('i'),
        E('i'),
      ]);
    }
    if (
      viewId === 'gauges' ||
      viewId === 'dual_telemetry' ||
      viewId === 'cockpit_hud'
    ) {
      return E('span', { class: `${cls} ${cls}--gauges` }, [E('i'), E('i')]);
    }
    if (
      viewId === 'tiles' ||
      viewId === 'cards_grid' ||
      viewId === 'compact_tiles' ||
      viewId === 'protocol_matrix' ||
      viewId === 'expanded_cards'
    ) {
      return E('span', { class: `${cls} ${cls}--bento` }, [
        E('i'),
        E('i'),
        E('i'),
        E('i'),
      ]);
    }
    return E('span', { class: `${cls} ${cls}--wave` }, [E('i')]);
  }

  function renderEditorContent() {
    const presetsGrid = E(
      'div',
      { class: 'tachyon-dash-editor__presets-grid' },
      DASHBOARD_PRESETS.map((preset) => {
        const isSelected = currentCfg.preset === preset.id;
        return E(
          'div',
          {
            class: `tachyon-dash-preset-card ${isSelected ? 'is-selected' : ''}`,
            click: (ev: MouseEvent) => {
              ev.preventDefault();
              commitChange({
                preset: preset.id,
                widgets: clonePlacements(preset.widgets),
              });
            },
          },
          [
            E('div', { class: 'tachyon-dash-preset-card__top' }, [
              E(
                'span',
                { class: 'tachyon-dash-preset-card__icon' },
                [getPresetIconEl(preset.id, 20)],
              ),
              E('div', { class: 'tachyon-dash-preset-card__titles' }, [
                E(
                  'div',
                  { class: 'tachyon-dash-preset-card__title' },
                  tr(preset.titleRu, preset.titleEn),
                ),
                E(
                  'span',
                  { class: 'tachyon-dash-preset-card__badge' },
                  tr(preset.badgeRu, preset.badgeEn),
                ),
              ]),
              renderPresetMiniPreview(preset.widgets),
            ]),
            E(
              'div',
              { class: 'tachyon-dash-preset-card__desc' },
              tr(preset.descRu, preset.descEn),
            ),
          ],
        );
      }),
    );

    const autoFullIds = computeAutoFullWidgetIds(currentCfg.widgets);

    const buildVisualSlot = (
      placement: DashboardWidgetPlacement,
      idx: number,
    ) => {
      const cat = getWidgetCatalogEntry(placement.id);
      if (!cat) return E('div');

      const isHalf = placement.width === 'half';
      const isAutoFull = autoFullIds.has(placement.id);

      const toggleBtn = E(
        'button',
        {
          type: 'button',
          class: `tachyon-dash-widget-row__check ${
            placement.enabled ? 'is-checked' : ''
          }`,
          title: placement.enabled
            ? tr('Скрыть виджет с дашборда', 'Hide widget from dashboard')
            : tr('Показать виджет на дашборде', 'Show widget on dashboard'),
          click: (ev: MouseEvent) => {
            ev.preventDefault();
            ev.stopPropagation();
            const nextWidgets = clonePlacements(currentCfg.widgets);
            nextWidgets[idx].enabled = !nextWidgets[idx].enabled;
            commitChange({
              preset: detectMatchingPreset(nextWidgets) || 'custom',
              widgets: nextWidgets,
            });
          },
        },
        placement.enabled ? '✓' : '+',
      );

      const viewPills = E(
        'div',
        { class: 'tachyon-dash-widget-row__views' },
        cat.views.map((v) => {
          const isViewActive = placement.view === v.id;
          return E(
            'button',
            {
              type: 'button',
              class: `tachyon-dash-view-chip ${isViewActive ? 'is-active' : ''}`,
              title: tr(v.descRu, v.descEn),
              click: (ev: MouseEvent) => {
                ev.preventDefault();
                ev.stopPropagation();
                const nextWidgets = clonePlacements(currentCfg.widgets);
                nextWidgets[idx].view = v.id;
                nextWidgets[idx].enabled = true;
                commitChange({
                  preset: detectMatchingPreset(nextWidgets) || 'custom',
                  widgets: nextWidgets,
                });
              },
            },
            [
              renderViewMiniSchematic(v.id),
              E('span', {}, tr(v.labelRu, v.labelEn)),
            ],
          );
        }),
      );

      const widthToggle = E(
        'div',
        { class: 'tachyon-dash-widget-row__width-group' },
        [
          E(
            'button',
            {
              type: 'button',
              class: `tachyon-dash-width-btn ${
                placement.width === 'full' ? 'is-active' : ''
              }`,
              title: tr(
                'На всю ширину дашборда (100%)',
                'Full dashboard width (100%)',
              ),
              click: (ev: MouseEvent) => {
                ev.preventDefault();
                ev.stopPropagation();
                if (placement.width === 'full') return;
                const nextWidgets = clonePlacements(currentCfg.widgets);
                nextWidgets[idx].width = 'full';
                commitChange({
                  preset: detectMatchingPreset(nextWidgets) || 'custom',
                  widgets: nextWidgets,
                });
              },
            },
            '100%',
          ),
          E(
            'button',
            {
              type: 'button',
              class: `tachyon-dash-width-btn ${
                placement.width === 'half' ? 'is-active' : ''
              }`,
              title: tr(
                'Половина ширины (50% — ставится в пару с соседним 50% виджетом)',
                'Half width (50% — pairs side-by-side with adjacent 50% widget)',
              ),
              click: (ev: MouseEvent) => {
                ev.preventDefault();
                ev.stopPropagation();
                if (placement.width === 'half') return;
                const nextWidgets = clonePlacements(currentCfg.widgets);
                nextWidgets[idx].width = 'half';
                commitChange({
                  preset: detectMatchingPreset(nextWidgets) || 'custom',
                  widgets: nextWidgets,
                });
              },
            },
            '50%',
          ),
        ],
      );

      const prevBtn = E(
        'button',
        {
          type: 'button',
          class: 'btn cbi-button tachyon-dash-order-btn',
          title: tr('Сдвинуть влево / выше по сетке', 'Move left / up in grid'),
          disabled: idx === 0 ? 'disabled' : undefined,
          click: (ev: MouseEvent) => {
            ev.preventDefault();
            ev.stopPropagation();
            if (idx <= 0) return;
            const nextWidgets = clonePlacements(currentCfg.widgets);
            const tmp = nextWidgets[idx - 1];
            nextWidgets[idx - 1] = nextWidgets[idx];
            nextWidgets[idx] = tmp;
            commitChange({
              preset: detectMatchingPreset(nextWidgets) || 'custom',
              widgets: nextWidgets,
            });
          },
        } as any,
        '◀ ▲',
      );

      const nextBtn = E(
        'button',
        {
          type: 'button',
          class: 'btn cbi-button tachyon-dash-order-btn',
          title: tr(
            'Сдвинуть вправо / ниже по сетке',
            'Move right / down in grid',
          ),
          disabled:
            idx === currentCfg.widgets.length - 1 ? 'disabled' : undefined,
          click: (ev: MouseEvent) => {
            ev.preventDefault();
            ev.stopPropagation();
            if (idx >= currentCfg.widgets.length - 1) return;
            const nextWidgets = clonePlacements(currentCfg.widgets);
            const tmp = nextWidgets[idx + 1];
            nextWidgets[idx + 1] = nextWidgets[idx];
            nextWidgets[idx] = tmp;
            commitChange({
              preset: detectMatchingPreset(nextWidgets) || 'custom',
              widgets: nextWidgets,
            });
          },
        } as any,
        '▼ ▶',
      );

      const activeViewObj =
        cat.views.find((v) => v.id === placement.view) || cat.views[0];

      const cardEl = E(
        'div',
        {
          class: [
            'tachyon-visual-slot-card',
            isHalf && !isAutoFull ? 'is-half' : 'is-full',
            isAutoFull ? 'is-auto-full' : '',
            !placement.enabled ? 'is-disabled' : '',
          ]
            .filter(Boolean)
            .join(' '),
          draggable: 'true',
          'data-slot-idx': String(idx),
        } as any,
        [
          E('div', { class: 'tachyon-visual-slot-card__head' }, [
            E(
              'span',
              {
                class: 'tachyon-visual-slot-card__drag-handle',
                title: tr(
                  'Перетащите мышкой в другое место макета',
                  'Drag to reposition in layout',
                ),
              },
              '⠿',
            ),
            toggleBtn,
            E('span', { class: 'tachyon-dash-widget-row__icon' }, [
              getWidgetIconEl(cat.id, 16),
            ]),
            E('div', { class: 'tachyon-dash-widget-row__info' }, [
              E('div', { class: 'tachyon-visual-slot-card__title-row' }, [
                E(
                  'span',
                  { class: 'tachyon-dash-widget-row__title' },
                  tr(cat.titleRu, cat.titleEn),
                ),
                E(
                  'span',
                  { class: 'tachyon-visual-slot-card__span-badge' },
                  !placement.enabled
                    ? tr('Скрыт', 'Hidden')
                    : isAutoFull
                      ? tr('50% → Авто 100%', '50% → Auto 100%')
                      : isHalf
                        ? tr('1/2 колонки (50%)', '1/2 column (50%)')
                        : tr('Во всю ширину (100%)', 'Full width (100%)'),
                ),
              ]),
              E(
                'div',
                { class: 'tachyon-dash-widget-row__desc' },
                activeViewObj
                  ? `${tr('Вид:', 'View:')} ${tr(
                      activeViewObj.labelRu,
                      activeViewObj.labelEn,
                    )} — ${tr(activeViewObj.descRu, activeViewObj.descEn)}`
                  : tr(cat.descRu, cat.descEn),
              ),
            ]),
            E('div', { class: 'tachyon-visual-slot-card__controls' }, [
              widthToggle,
              E('div', { class: 'tachyon-dash-widget-row__order' }, [
                prevBtn,
                nextBtn,
              ]),
            ]),
          ]),
          E('div', { class: 'tachyon-visual-slot-card__views-wrap' }, [
            E(
              'span',
              { class: 'tachyon-dash-widget-row__views-label' },
              tr('Стиль виджета:', 'Widget style:'),
            ),
            viewPills,
          ]),
        ],
      );

      cardEl.addEventListener('dragstart', (ev: DragEvent) => {
        draggedIdx = idx;
        cardEl.classList.add('is-dragging');
        if (ev.dataTransfer) {
          ev.dataTransfer.effectAllowed = 'move';
          ev.dataTransfer.setData('text/plain', String(idx));
        }
      });

      cardEl.addEventListener('dragend', () => {
        draggedIdx = null;
        cardEl.classList.remove('is-dragging');
      });

      cardEl.addEventListener('dragover', (ev: DragEvent) => {
        ev.preventDefault();
        if (draggedIdx === null || draggedIdx === idx) return;
        cardEl.classList.add('is-drag-over');
      });

      cardEl.addEventListener('dragleave', () => {
        cardEl.classList.remove('is-drag-over');
      });

      cardEl.addEventListener('drop', (ev: DragEvent) => {
        ev.preventDefault();
        cardEl.classList.remove('is-drag-over');
        const fromIdx =
          draggedIdx !== null
            ? draggedIdx
            : Number(ev.dataTransfer?.getData('text/plain'));
        draggedIdx = null;
        if (
          !Number.isFinite(fromIdx) ||
          fromIdx < 0 ||
          fromIdx >= currentCfg.widgets.length ||
          fromIdx === idx
        ) {
          return;
        }
        const nextWidgets = clonePlacements(currentCfg.widgets);
        const [moved] = nextWidgets.splice(fromIdx, 1);
        nextWidgets.splice(idx, 0, moved);
        commitChange({
          preset: detectMatchingPreset(nextWidgets) || 'custom',
          widgets: nextWidgets,
        });
      });

      return cardEl;
    };

    const enabledIndices: number[] = [];
    const disabledIndices: number[] = [];
    currentCfg.widgets.forEach((w, i) => {
      if (w.enabled) enabledIndices.push(i);
      else disabledIndices.push(i);
    });

    const activeCanvasSlots = enabledIndices.map((idx) =>
      buildVisualSlot(currentCfg.widgets[idx], idx),
    );
    const hiddenCanvasSlots = disabledIndices.map((idx) =>
      buildVisualSlot(currentCfg.widgets[idx], idx),
    );

    root.replaceChildren(
      E('div', { class: 'tachyon-dash-editor__section' }, [
        E('div', { class: 'tachyon-dash-editor__section-head' }, [
          E(
            'span',
            { class: 'tachyon-dash-editor__section-title' },
            tr(
              '1. Готовые пресеты дашборда (5 вариантов)',
              '1. Dashboard Presets (5 layouts)',
            ),
          ),
          E(
            'span',
            { class: 'tachyon-dash-editor__section-sub' },
            tr(
              '«Классический (Стандартный)» повторяет исходный вид дашборда до виджетов. Выберите пресет или соберите свой макет ниже',
              '"Classic Standard" matches the original pre-widget dashboard. Choose a preset or build your own layout below',
            ),
          ),
        ]),
        presetsGrid,
      ]),
      E('div', { class: 'tachyon-dash-editor__section' }, [
        E('div', { class: 'tachyon-dash-editor__section-head' }, [
          E(
            'span',
            { class: 'tachyon-dash-editor__section-title' },
            tr(
              '2. Визуальная раскладка дашборда (2-колоночный макет)',
              '2. Visual Dashboard Layout (2-Column Grid Canvas)',
            ),
          ),
          E(
            'span',
            { class: 'tachyon-dash-editor__section-sub' },
            tr(
              'Перетаскивайте блоки мышью (⠿) или кнопками ◀▲ / ▼▶. Два соседних виджета с шириной 50% автоматически встают рядом в 2 колонки',
              'Drag blocks with mouse (⠿) or ◀▲ / ▼▶ buttons. Two adjacent 50% widgets automatically sit side-by-side in 2 columns',
            ),
          ),
        ]),
        E('div', { class: 'tachyon-visual-canvas-grid' }, activeCanvasSlots),
        hiddenCanvasSlots.length > 0
          ? E('div', { class: 'tachyon-visual-hidden-tray' }, [
              E(
                'div',
                { class: 'tachyon-visual-hidden-tray__title' },
                tr(
                  'Скрытые виджеты (нажмите «+», чтобы вернуть на дашборд)',
                  'Hidden widgets (click "+" to restore to dashboard)',
                ),
              ),
              E(
                'div',
                { class: 'tachyon-visual-canvas-grid is-hidden-tray' },
                hiddenCanvasSlots,
              ),
            ])
          : E('span', { style: 'display:none;' }),
      ]),
    );
  }

  (root as any)._layoutConfig = currentCfg;
  renderEditorContent();
  return root;
}

export function renderDashboardLayoutSettingsPanel(
  sectionId = 'main',
): HTMLElement {
  return buildDashboardLayoutEditorDom({ sectionId });
}

export function openDashboardCustomizeModal(
  onLayoutUpdated?: (cfg: DashboardLayoutConfig) => void,
): void {
  const uiObj = (globalThis as any).ui;
  if (!uiObj || typeof uiObj.showModal !== 'function') return;

  const editor = buildDashboardLayoutEditorDom({
    onChange: (cfg) => {
      if (onLayoutUpdated) onLayoutUpdated(cfg);
    },
  });

  const footer = E(
    'div',
    {
      style:
        'display:flex;align-items:center;justify-content:space-between;gap:12px;margin-top:16px;padding-top:12px;border-top:1px solid var(--border-color-low, rgba(148,163,184,0.18));flex-wrap:wrap;',
    },
    [
      E(
        'button',
        {
          type: 'button',
          class: 'btn cbi-button',
          click: (ev: MouseEvent) => {
            ev.preventDefault();
            const next = applyDashboardPreset('standard');
            if (onLayoutUpdated) onLayoutUpdated(next);
            uiObj.hideModal();
          },
        },
        tr('Сбросить к стандартному', 'Reset to Standard'),
      ),
      E(
        'button',
        {
          type: 'button',
          class: 'btn cbi-button cbi-button-apply',
          click: (ev: MouseEvent) => {
            ev.preventDefault();
            uiObj.hideModal();
          },
        },
        tr('Готово', 'Done'),
      ),
    ],
  );

  uiObj.showModal(
    tr(
      'Настройка виджетов и пресетов дашборда',
      'Dashboard Widgets & Presets Setup',
    ),
    [E('div', { class: 'tachyon-dash-customize-modal' }, [editor, footer])],
  );
}
