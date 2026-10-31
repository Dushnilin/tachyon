/* eslint-disable @typescript-eslint/no-explicit-any */
import { svgEl } from '../helpers';
import { showToast } from '../helpers/showToast';
import { tr } from './helpers/i18n';
import { renderTachyonDuckMascotSvg } from '../icons/duckMascot';
import { renderZapIcon, renderPlusIcon, renderWandIcon } from '../icons';
import { TachyonShellMethods } from './methods/shell';
import { store } from './services/store.service';
import { openConnectionWizardModal } from './connectionWizard';
import {
  mountLanguageSelector,
  UiLanguageCapabilities,
} from './languageSelector';

export type TachyonUiMode = 'simple' | 'advanced';
export type TachyonSidebarPos = 'left' | 'right';

const UI_MODE_STORAGE_KEY = 'tachyon_ui_mode_v1';
const SIDEBAR_POS_STORAGE_KEY = 'tachyon_sidebar_pos_v1';
const SIDEBAR_COLLAPSED_STORAGE_KEY = 'tachyon_sidebar_collapsed_v1';
const TOPBAR_COLLAPSED_STORAGE_KEY = 'tachyon_topbar_collapsed_v1';
const SIDEBAR_EXPANDED_MENUS_KEY = 'tachyon_sidebar_menus_v1';

export function getUiMode(): TachyonUiMode {
  if (typeof localStorage === 'undefined') return 'simple';
  try {
    const val = localStorage.getItem(UI_MODE_STORAGE_KEY);
    return val === 'advanced' ? 'advanced' : 'simple';
  } catch {
    return 'simple';
  }
}

export function setUiMode(mode: TachyonUiMode): void {
  if (typeof localStorage !== 'undefined') {
    try {
      localStorage.setItem(UI_MODE_STORAGE_KEY, mode);
    } catch {
      // ignore
    }
  }
  if (typeof document !== 'undefined' && document.body) {
    document.body.setAttribute('data-tachyon-ui-mode', mode);
  }
}

export function getSidebarPos(): TachyonSidebarPos {
  if (typeof localStorage === 'undefined') return 'left';
  try {
    const val = localStorage.getItem(SIDEBAR_POS_STORAGE_KEY);
    return val === 'right' ? 'right' : 'left';
  } catch {
    return 'left';
  }
}

export function setSidebarPos(pos: TachyonSidebarPos): void {
  if (typeof localStorage !== 'undefined') {
    try {
      localStorage.setItem(SIDEBAR_POS_STORAGE_KEY, pos);
    } catch {
      // ignore
    }
  }
}

export function getSidebarCollapsed(): boolean {
  if (typeof localStorage === 'undefined') return false;
  try {
    return localStorage.getItem(SIDEBAR_COLLAPSED_STORAGE_KEY) === 'true';
  } catch {
    return false;
  }
}

export function setSidebarCollapsed(collapsed: boolean): void {
  if (typeof localStorage !== 'undefined') {
    try {
      localStorage.setItem(
        SIDEBAR_COLLAPSED_STORAGE_KEY,
        collapsed ? 'true' : 'false',
      );
    } catch {
      // ignore
    }
  }
}

export function getTopbarCollapsed(): boolean {
  if (typeof localStorage === 'undefined') return false;
  try {
    return localStorage.getItem(TOPBAR_COLLAPSED_STORAGE_KEY) === 'true';
  } catch {
    return false;
  }
}

export function setTopbarCollapsed(collapsed: boolean): void {
  if (typeof localStorage !== 'undefined') {
    try {
      localStorage.setItem(
        TOPBAR_COLLAPSED_STORAGE_KEY,
        collapsed ? 'true' : 'false',
      );
    } catch {
      // ignore
    }
  }
}

function getExpandedMenus(): Set<string> {
  if (typeof localStorage === 'undefined') return new Set();
  try {
    const raw = localStorage.getItem(SIDEBAR_EXPANDED_MENUS_KEY);
    if (!raw) return new Set();
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed)) return new Set(parsed);
  } catch {
    // ignore
  }
  return new Set();
}

function saveExpandedMenus(menus: Set<string>): void {
  if (typeof localStorage === 'undefined') return;
  try {
    localStorage.setItem(
      SIDEBAR_EXPANDED_MENUS_KEY,
      JSON.stringify(Array.from(menus)),
    );
  } catch {
    // ignore
  }
}

export interface NavItemDef {
  key: string;
  uciTabId: string;
  luciTab: string;
  subTab?: 'sections' | 'conditions' | 'outbounds' | 'balancers';
  settingsSubTab?:
    | 'dns'
    | 'network'
    | 'services'
    | 'updates'
    | 'ai'
    | 'navigation'
    | 'advanced';
  parentMenu?: 'routing' | 'clients' | 'analytics' | 'system';
  simpleVisible: boolean;
  labelRu: string;
  labelEn: string;
  subtitleRu: string;
  subtitleEn: string;
  iconPaths: Array<{ tag: string; attrs: Record<string, string> }>;
}

interface ParentMenuDef {
  id: 'routing' | 'clients' | 'analytics' | 'system';
  labelRu: string;
  labelEn: string;
  iconPaths: Array<{ tag: string; attrs: Record<string, string> }>;
}

const PARENT_MENUS: ParentMenuDef[] = [
  {
    id: 'routing',
    labelRu: 'Маршруты',
    labelEn: 'Routing',
    iconPaths: [
      { tag: 'circle', attrs: { cx: '6', cy: '19', r: '3' } },
      {
        tag: 'path',
        attrs: { d: 'M9 19h8.5a3.5 3.5 0 0 0 0-7h-11a3.5 3.5 0 0 1 0-7H15' },
      },
      { tag: 'circle', attrs: { cx: '18', cy: '5', r: '3' } },
    ],
  },
  {
    id: 'clients',
    labelRu: 'Клиенты и сеть',
    labelEn: 'Clients & Network',
    iconPaths: [
      {
        tag: 'path',
        attrs: { d: 'M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2' },
      },
      { tag: 'circle', attrs: { cx: '9', cy: '7', r: '4' } },
      { tag: 'path', attrs: { d: 'M22 21v-2a4 4 0 0 0-3-3.87' } },
      { tag: 'path', attrs: { d: 'M16 3.13a4 4 0 0 1 0 7.75' } },
    ],
  },
  {
    id: 'analytics',
    labelRu: 'Аналитика',
    labelEn: 'Analytics',
    iconPaths: [
      { tag: 'polyline', attrs: { points: '22 12 18 12 15 21 9 3 6 12 2 12' } },
    ],
  },
  {
    id: 'system',
    labelRu: 'Настройки',
    labelEn: 'Settings',
    iconPaths: [
      { tag: 'circle', attrs: { cx: '12', cy: '12', r: '3' } },
      {
        tag: 'path',
        attrs: {
          d: 'M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z',
        },
      },
    ],
  },
];

const NAV_ITEMS: NavItemDef[] = [
  {
    key: 'dashboard',
    uciTabId: 'dashboard',
    luciTab: 'dashboard',
    simpleVisible: true,
    labelRu: 'Обзор',
    labelEn: 'Overview',
    subtitleRu: 'Состояние маршрутов и инфраструктуры в реальном времени',
    subtitleEn: 'Real-time routing and infrastructure status',
    iconPaths: [
      {
        tag: 'rect',
        attrs: { x: '3', y: '3', width: '7', height: '7', rx: '1.5' },
      },
      {
        tag: 'rect',
        attrs: { x: '14', y: '3', width: '7', height: '7', rx: '1.5' },
      },
      {
        tag: 'rect',
        attrs: { x: '14', y: '14', width: '7', height: '7', rx: '1.5' },
      },
      {
        tag: 'rect',
        attrs: { x: '3', y: '14', width: '7', height: '7', rx: '1.5' },
      },
    ],
  },
  // Маршруты submenu
  {
    key: 'section:sections',
    uciTabId: 'section',
    luciTab: 'section',
    subTab: 'sections',
    parentMenu: 'routing',
    simpleVisible: true,
    labelRu: 'Секции маршрутов',
    labelEn: 'Routing Sections',
    subtitleRu: 'Правила направления трафика по сервисам и подключениям',
    subtitleEn: 'Traffic routing rules across services and connections',
    iconPaths: [
      { tag: 'circle', attrs: { cx: '6', cy: '19', r: '3' } },
      {
        tag: 'path',
        attrs: { d: 'M9 19h8.5a3.5 3.5 0 0 0 0-7h-11a3.5 3.5 0 0 1 0-7H15' },
      },
      { tag: 'circle', attrs: { cx: '18', cy: '5', r: '3' } },
    ],
  },
  {
    key: 'section:outbounds',
    uciTabId: 'outbounds',
    luciTab: 'section',
    subTab: 'outbounds',
    parentMenu: 'routing',
    simpleVisible: true,
    labelRu: 'Узлы и подписки',
    labelEn: 'Nodes & Sources',
    subtitleRu: 'Глобальный пул подписок, прокси-ссылок, туннелей и Desync',
    subtitleEn: 'Global pool of subscriptions, proxy links, tunnels and Desync',
    iconPaths: [
      {
        tag: 'rect',
        attrs: { x: '2', y: '3', width: '20', height: '7', rx: '2' },
      },
      {
        tag: 'rect',
        attrs: { x: '2', y: '14', width: '20', height: '7', rx: '2' },
      },
      { tag: 'line', attrs: { x1: '6', y1: '6.5', x2: '6.01', y2: '6.5' } },
      { tag: 'line', attrs: { x1: '6', y1: '17.5', x2: '6.01', y2: '17.5' } },
    ],
  },
  {
    key: 'section:conditions',
    uciTabId: 'conditions',
    luciTab: 'section',
    subTab: 'conditions',
    parentMenu: 'routing',
    simpleVisible: false,
    labelRu: 'Условия трафика',
    labelEn: 'Traffic Conditions',
    subtitleRu:
      'Атомарные и составные булевы правила фильтрации (AND / OR / NOT)',
    subtitleEn: 'Atomic and composite boolean traffic matching rules',
    iconPaths: [
      {
        tag: 'polygon',
        attrs: { points: '22 3 2 3 10 12.46 10 19 14 21 14 12.46 22 3' },
      },
    ],
  },
  {
    key: 'section:balancers',
    uciTabId: 'balancers',
    luciTab: 'section',
    subTab: 'balancers',
    parentMenu: 'routing',
    simpleVisible: false,
    labelRu: 'Балансировщики',
    labelEn: 'Balancers',
    subtitleRu:
      'Политики автоматического выбора URLTest и отказоустойчивости Priority',
    subtitleEn: 'URLTest auto-selection and Priority failover policies',
    iconPaths: [
      { tag: 'path', attrs: { d: 'M16 3h5v5' } },
      { tag: 'path', attrs: { d: 'M4 20 21 3' } },
      { tag: 'path', attrs: { d: 'M21 16v5h-5' } },
      { tag: 'path', attrs: { d: 'M15 15l6 6' } },
      { tag: 'path', attrs: { d: 'M4 4l5 5' } },
    ],
  },
  // Клиенты и сеть submenu
  {
    key: 'profile',
    uciTabId: 'profile',
    luciTab: 'profile',
    parentMenu: 'clients',
    simpleVisible: true,
    labelRu: 'Семейные профили',
    labelEn: 'Family Profiles',
    subtitleRu:
      'Группировка домашних устройств, фильтрация контента и SafeSearch',
    subtitleEn: 'Group home devices, content filtering and SafeSearch',
    iconPaths: [
      {
        tag: 'path',
        attrs: { d: 'M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2' },
      },
      { tag: 'circle', attrs: { cx: '9', cy: '7', r: '4' } },
    ],
  },
  {
    key: 'schedule',
    uciTabId: 'schedule',
    luciTab: 'schedule',
    parentMenu: 'clients',
    simpleVisible: true,
    labelRu: 'Родительский контроль',
    labelEn: 'Parental Control',
    subtitleRu: 'Расписание доступа в интернет и лимиты по дням недели',
    subtitleEn: 'Internet access schedules and time rules',
    iconPaths: [
      { tag: 'circle', attrs: { cx: '12', cy: '12', r: '10' } },
      { tag: 'polyline', attrs: { points: '12 6 12 12 16 14' } },
    ],
  },
  {
    key: 'guest_mode',
    uciTabId: 'guest_mode',
    luciTab: 'guest_mode',
    parentMenu: 'clients',
    simpleVisible: true,
    labelRu: 'Гостевой режим',
    labelEn: 'Guest Mode',
    subtitleRu: 'Изоляция гостевых устройств от локальной сети и квоты трафика',
    subtitleEn: 'Isolate guest devices from LAN with daily quotas',
    iconPaths: [
      { tag: 'path', attrs: { d: 'M5 12.55a11 11 0 0 1 14.08 0' } },
      { tag: 'path', attrs: { d: 'M1.42 9a16 16 0 0 1 21.16 0' } },
      { tag: 'path', attrs: { d: 'M8.53 16.11a6 6 0 0 1 6.95 0' } },
      { tag: 'line', attrs: { x1: '12', y1: '20', x2: '12.01', y2: '20' } },
    ],
  },
  {
    key: 'server',
    uciTabId: 'server',
    luciTab: 'server',
    parentMenu: 'clients',
    simpleVisible: true,
    labelRu: 'Серверы (Inbound)',
    labelEn: 'Inbound Servers',
    subtitleRu:
      'Собственные VPN и прокси-серверы на роутере для внешних устройств',
    subtitleEn: 'Host VPN and proxy servers on the router for external devices',
    iconPaths: [
      {
        tag: 'path',
        attrs: { d: 'M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z' },
      },
    ],
  },
  // Аналитика submenu
  {
    key: 'diagnostic',
    uciTabId: 'diagnostic',
    luciTab: 'diagnostic',
    parentMenu: 'analytics',
    simpleVisible: true,
    labelRu: 'Диагностика',
    labelEn: 'Diagnostics',
    subtitleRu:
      'Проверка сервисов, автодоктор, тест скорости DNS и трассировка правил',
    subtitleEn: 'Health checks, doctor, DNS benchmark and rule tracer',
    iconPaths: [
      {
        tag: 'path',
        attrs: {
          d: 'M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z',
        },
      },
    ],
  },
  {
    key: 'monitoring',
    uciTabId: 'monitoring',
    luciTab: 'monitoring',
    parentMenu: 'analytics',
    simpleVisible: true,
    labelRu: 'Мониторинг сессий',
    labelEn: 'Live Monitoring',
    subtitleRu:
      'Активные сессии, коннекты, домены и маршруты в реальном времени',
    subtitleEn: 'Live connections, domains and route inspection',
    iconPaths: [
      { tag: 'polyline', attrs: { points: '22 12 18 12 15 21 9 3 6 12 2 12' } },
    ],
  },
  // Настройки submenu
  {
    key: 'settings:dns',
    uciTabId: 'settings_dns',
    luciTab: 'settings',
    settingsSubTab: 'dns',
    parentMenu: 'system',
    simpleVisible: true,
    labelRu: 'DNS и защита',
    labelEn: 'DNS & Protection',
    subtitleRu:
      'Параметры DNS-резолвера, шифрования DoH/DoT и отказоустойчивости',
    subtitleEn: 'DNS resolver, DoH/DoT encryption and failover settings',
    iconPaths: [
      { tag: 'circle', attrs: { cx: '12', cy: '12', r: '10' } },
      { tag: 'line', attrs: { x1: '2', y1: '12', x2: '22', y2: '12' } },
    ],
  },
  {
    key: 'settings:network',
    uciTabId: 'settings_network',
    luciTab: 'settings',
    settingsSubTab: 'network',
    parentMenu: 'system',
    simpleVisible: true,
    labelRu: 'Сеть и TUN',
    labelEn: 'Network & TUN',
    subtitleRu: 'Параметры перехвата трафика, интерфейсов LAN/WAN и TUN',
    subtitleEn: 'Traffic interception, LAN/WAN interfaces and TUN settings',
    iconPaths: [
      {
        tag: 'rect',
        attrs: { x: '2', y: '2', width: '20', height: '8', rx: '2' },
      },
      {
        tag: 'rect',
        attrs: { x: '2', y: '14', width: '20', height: '8', rx: '2' },
      },
    ],
  },
  {
    key: 'settings:services',
    uciTabId: 'settings_services',
    luciTab: 'settings',
    settingsSubTab: 'services',
    parentMenu: 'system',
    simpleVisible: true,
    labelRu: 'Сервисы и порты',
    labelEn: 'Services & Ports',
    subtitleRu: 'Порты прокси, панель YACD, P2P и сопутствующие службы',
    subtitleEn: 'Proxy ports, YACD panel, P2P and companion services',
    iconPaths: [{ tag: 'circle', attrs: { cx: '12', cy: '12', r: '3' } }],
  },
  {
    key: 'settings:advanced',
    uciTabId: 'settings_advanced',
    luciTab: 'settings',
    settingsSubTab: 'advanced',
    parentMenu: 'system',
    simpleVisible: true,
    labelRu: 'Система и бэкап',
    labelEn: 'System & Backup',
    subtitleRu: 'Выбор ядра, резервное копирование конфигурации и логирование',
    subtitleEn: 'Engine selection, configuration backup and logging',
    iconPaths: [
      {
        tag: 'path',
        attrs: {
          d: 'M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11l5 5v11a2 2 0 0 1-2 2z',
        },
      },
    ],
  },
  {
    key: 'updates',
    uciTabId: 'updates',
    luciTab: 'updates',
    parentMenu: 'system',
    simpleVisible: true,
    labelRu: 'Компоненты и ядро',
    labelEn: 'Components & Core',
    subtitleRu:
      'Управление ядром Tachyon Core, модулями и обновлениями системы',
    subtitleEn: 'Manage Tachyon Core, engine components and updates',
    iconPaths: [
      {
        tag: 'path',
        attrs: {
          d: 'M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z',
        },
      },
      { tag: 'polyline', attrs: { points: '3.27 6.96 12 12.01 20.73 6.96' } },
      { tag: 'line', attrs: { x1: '12', y1: '22.08', x2: '12', y2: '12' } },
    ],
  },
  {
    key: 'telegram',
    uciTabId: 'telegram',
    luciTab: 'telegram',
    parentMenu: 'system',
    simpleVisible: true,
    labelRu: 'Telegram-бот',
    labelEn: 'Telegram Bot',
    subtitleRu: 'Удалённое управление маршрутами и уведомления через Telegram',
    subtitleEn: 'Remote route control and notifications via Telegram',
    iconPaths: [
      { tag: 'line', attrs: { x1: '22', y1: '2', x2: '11', y2: '13' } },
      { tag: 'polygon', attrs: { points: '22 2 15 22 11 13 2 9 22 2' } },
    ],
  },
  {
    key: 'settings:ai',
    uciTabId: 'settings_ai',
    luciTab: 'settings',
    settingsSubTab: 'ai',
    parentMenu: 'system',
    simpleVisible: false,
    labelRu: 'ИИ и самоисцеление',
    labelEn: 'AI & Self-Healing',
    subtitleRu: 'Автоматический сторож (Watchdog), восстановление и ИИ-агент',
    subtitleEn: 'Automated Watchdog recovery and AI diagnostics agent',
    iconPaths: [
      {
        tag: 'path',
        attrs: {
          d: 'M12 2v4M12 18v4M4.93 4.93l2.83 2.83M16.24 16.24l2.83 2.83M2 12h4M18 12h4',
        },
      },
    ],
  },
  {
    key: 'settings:updates',
    uciTabId: 'settings_updates',
    luciTab: 'settings',
    settingsSubTab: 'updates',
    parentMenu: 'system',
    simpleVisible: false,
    labelRu: 'Обновления списков',
    labelEn: 'Lists & Presets',
    subtitleRu: 'Расписание обновления гео-баз, правил и компонентов',
    subtitleEn: 'Geo-databases, rulesets and component update schedule',
    iconPaths: [
      { tag: 'polyline', attrs: { points: '23 4 23 10 17 10' } },
      { tag: 'path', attrs: { d: 'M20.49 15a9 9 0 1 1-2.12-9.36L23 10' } },
    ],
  },
  {
    key: 'settings:navigation',
    uciTabId: 'settings',
    luciTab: 'settings',
    settingsSubTab: 'navigation',
    parentMenu: 'system',
    simpleVisible: true,
    labelRu: 'Дашборд и интерфейс',
    labelEn: 'Dashboard & Interface',
    subtitleRu: 'Пресеты дашборда, 2-колоночная раскладка виджетов и меню',
    subtitleEn: 'Dashboard presets, 2-column widget layout and menu order',
    iconPaths: [
      {
        tag: 'rect',
        attrs: { x: '3', y: '3', width: '18', height: '18', rx: '2' },
      },
      { tag: 'line', attrs: { x1: '9', y1: '3', x2: '9', y2: '21' } },
    ],
  },
];

function getUciGetter():
  | ((pkg: string, sec: string, opt: string) => any)
  | null {
  const lexicalUci = typeof uci !== 'undefined' ? (uci as any) : null;
  if (lexicalUci && typeof lexicalUci.get === 'function') {
    return (pkg, sec, opt) => lexicalUci.get(pkg, sec, opt);
  }
  const g = globalThis as any;
  if (g.uci && typeof g.uci.get === 'function') {
    return (pkg, sec, opt) => g.uci.get(pkg, sec, opt);
  }
  if (g.L?.uci && typeof g.L.uci.get === 'function') {
    return (pkg, sec, opt) => g.L.uci.get(pkg, sec, opt);
  }
  return null;
}

function isLuciTabVisibleInUci(
  tabId: string,
  customCheck?: (id: string) => boolean,
): boolean {
  if (tabId === 'settings' || tabId === 'settings:navigation') return true;
  if (typeof customCheck === 'function') {
    try {
      return customCheck(tabId);
    } catch {
      // fall through to direct uci check
    }
  }
  const uciGet = getUciGetter();
  if (!uciGet) return true;
  if (tabId === 'server') {
    const v1 = uciGet('tachyon', 'settings', 'show_tab_servers');
    const v2 = uciGet('tachyon', 'settings', 'show_tab_server');
    if (v1 === undefined && v2 === undefined) return false;
    return v1 === '1' || v1 === true || v2 === '1' || v2 === true;
  }
  if (tabId === 'profile') {
    const v1 = uciGet('tachyon', 'settings', 'show_tab_profiles');
    const v2 = uciGet('tachyon', 'settings', 'show_tab_profile');
    if (v1 === undefined && v2 === undefined) return false;
    return v1 === '1' || v1 === true || v2 === '1' || v2 === true;
  }
  if (tabId === 'schedule') {
    const v1 = uciGet('tachyon', 'settings', 'show_tab_parental');
    const v2 = uciGet('tachyon', 'settings', 'show_tab_schedule');
    if (v1 === undefined && v2 === undefined) return false;
    return v1 === '1' || v1 === true || v2 === '1' || v2 === true;
  }
  if (
    tabId === 'outbounds' ||
    tabId === 'conditions' ||
    tabId === 'balancers'
  ) {
    const secVis = uciGet('tachyon', 'settings', 'show_tab_section');
    if (secVis === '0' || secVis === false) return false;
  }
  const val = uciGet('tachyon', 'settings', `show_tab_${tabId}`);
  return val !== '0' && val !== false;
}

function getLuciTabOrderFromUci(customOrder?: () => string[]): string[] {
  if (typeof customOrder === 'function') {
    try {
      const res = customOrder();
      if (Array.isArray(res) && res.length > 0) return res;
    } catch {
      // fall through
    }
  }
  const uciGet = getUciGetter();
  if (!uciGet) return [];
  const raw = uciGet('tachyon', 'settings', 'tab_order');
  if (Array.isArray(raw)) return raw;
  if (typeof raw === 'string' && raw.trim()) {
    return raw.trim().split(/\s+/);
  }
  return [];
}

function renderNavIcon(
  paths: Array<{ tag: string; attrs: Record<string, string> }>,
  size = 18,
): SVGElement {
  return svgEl(
    'svg',
    {
      viewBox: '0 0 24 24',
      width: String(size),
      height: String(size),
      fill: 'none',
      stroke: 'currentColor',
      'stroke-width': '2',
      'stroke-linecap': 'round',
      'stroke-linejoin': 'round',
      class: 'tachyon-sidebar__icon',
    },
    paths.map((p) => svgEl(p.tag as keyof SVGElementTagNameMap, p.attrs)),
  );
}

export interface MountAppShellOptions {
  mapEl?: HTMLElement;
  capabilities?: UiLanguageCapabilities;
  uiCapabilities?: UiLanguageCapabilities;
  onSelectSectionSubTab?: (subKey: string) => void;
  getActiveSectionSubTab?: () => string;
  onReloadMap?: () => void;
  isTabVisible?: (luciTab: string) => boolean;
  getTabOrder?: () => string[];
}

let modalEnhancementsInstalled = false;

export function installModalHeaderCloseEnhancements(): void {
  if (typeof document === 'undefined' || modalEnhancementsInstalled) return;
  modalEnhancementsInstalled = true;

  const hideActiveModal = () => {
    const g = globalThis as any;
    if (
      typeof ui !== 'undefined' &&
      typeof (ui as any)?.hideModal === 'function'
    ) {
      (ui as any).hideModal();
      return;
    }
    if (g.ui && typeof g.ui.hideModal === 'function') {
      g.ui.hideModal();
      return;
    }
    if (g.L?.hideModal && typeof g.L.hideModal === 'function') {
      g.L.hideModal();
      return;
    }
    document.body?.classList.remove('modal-overlay-active');
  };

  const injectHeaderCloseButton = (modalEl: HTMLElement | null) => {
    if (!modalEl) return;
    if (modalEl.querySelector('.tachyon-modal__header-close')) return;
    const headingEl = modalEl.querySelector<HTMLElement>(
      ':scope > h4, :scope > h3, :scope > .tachyon-wizard > .tachyon-wizard__header',
    );
    if (!headingEl || headingEl.classList.contains('tachyon-wizard__header')) {
      return;
    }
    headingEl.classList.add('tachyon-modal__sticky-header');
    const closeBtn = E(
      'button',
      {
        type: 'button',
        class: 'tachyon-modal__header-close',
        title: `${tr('Закрыть', 'Close')} (Esc)`,
        'aria-label': tr('Закрыть', 'Close'),
        click: (ev: MouseEvent) => {
          ev.preventDefault();
          ev.stopPropagation();
          hideActiveModal();
        },
      } as any,
      '✕',
    );
    headingEl.appendChild(closeBtn);
  };

  const scanOverlay = () => {
    if (typeof document.querySelectorAll !== 'function') return;
    const modals = document.querySelectorAll<HTMLElement>(
      '#modal_overlay > .modal, .cbi-modal, .modal',
    );
    modals.forEach((m) => injectHeaderCloseButton(m));
  };

  scanOverlay();

  if (typeof MutationObserver === 'function' && document.body) {
    const observer = new MutationObserver(() => {
      if (document.body.classList.contains('modal-overlay-active')) {
        scanOverlay();
      }
    });
    observer.observe(document.body, {
      attributes: true,
      attributeFilter: ['class'],
      childList: true,
      subtree: true,
    });
  }

  document.addEventListener('keydown', (ev: KeyboardEvent) => {
    if (
      ev.key === 'Escape' &&
      document.body?.classList.contains('modal-overlay-active')
    ) {
      ev.preventDefault();
      hideActiveModal();
    }
  });
}

const activeShellState: {
  activeNavKey: string;
  initialized?: boolean;
  restoringTab?: boolean;
  options?: MountAppShellOptions;
  renderFn?: () => void;
} = {
  activeNavKey: 'dashboard',
  initialized: false,
  restoringTab: false,
};

export function refreshTachyonAppShell(): void {
  if (typeof activeShellState.renderFn === 'function') {
    activeShellState.renderFn();
  }
}

function switchSettingsInternalSubTab(
  settingsSec: HTMLElement | null,
  subTabKey: string,
): void {
  if (!settingsSec) return;
  const targetLi = settingsSec.querySelector<HTMLElement>(
    `.cbi-tabmenu > li[data-tab="${subTabKey}"]`,
  );
  const targetLink = targetLi?.querySelector<HTMLAnchorElement>('a');
  if (targetLi && targetLink) {
    // Ensure cbi-tab-disabled is present before click so LuCI ui.tabs.switchTab processes it
    targetLi.classList.add('cbi-tab-disabled');
    targetLink.click();
  }

  settingsSec
    .querySelectorAll<HTMLElement>('.cbi-tabmenu > li[data-tab]')
    .forEach((li) => {
      const isMatch = li.getAttribute('data-tab') === subTabKey;
      li.classList.toggle('cbi-tab', isMatch);
      li.classList.toggle('cbi-tab-disabled', !isMatch);
    });

  settingsSec
    .querySelectorAll<HTMLElement>(
      '.cbi-section-node > [data-tab], .cbi-tabcontainer > [data-tab]',
    )
    .forEach((pane) => {
      const isMatch = pane.getAttribute('data-tab') === subTabKey;
      pane.classList.toggle('cbi-tab', isMatch);
      pane.classList.toggle('cbi-tab-disabled', !isMatch);
      pane.setAttribute('data-tab-active', isMatch ? 'true' : 'false');
      pane.style.display = isMatch ? '' : 'none';
    });
}

function formatSidebarEngineLabel(): string {
  const state = store.get();
  const sys = state.diagnosticsSystemInfo;
  const srvVariant = (
    state.servicesInfoWidget?.data?.engineVariant || ''
  ).toLowerCase();
  if (
    state.activeEngine === 'steer' ||
    state.activeEngine === 'steer-extended'
  ) {
    return tr('Ядро: Steer', 'Engine: Steer');
  }
  if (srvVariant === 'lx' || sys?.sing_box_lx) {
    return tr('Ядро: sing-box-lx', 'Engine: sing-box-lx');
  }
  if (
    srvVariant === 'extended' ||
    srvVariant === 'extended-compressed' ||
    sys?.sing_box_extended ||
    sys?.sing_box_compressed
  ) {
    return tr('Ядро: sing-box-extended', 'Engine: sing-box-extended');
  }
  if (srvVariant === 'tiny' || sys?.sing_box_tiny) {
    return tr('Ядро: sing-box-tiny', 'Engine: sing-box-tiny');
  }
  if (srvVariant === 'stable') {
    return tr('Ядро: sing-box', 'Engine: sing-box');
  }
  if (srvVariant === 'tachyon-core' || sys?.sing_box_tachyon_core) {
    return tr('Ядро: Tachyon Core', 'Engine: Tachyon Core');
  }
  const ver = (
    state.servicesInfoWidget?.data?.engineVersion ||
    sys?.sing_box_version ||
    ''
  ).trim();
  if (ver && ver !== 'unknown' && !/^v?0\./i.test(ver)) {
    return tr('Ядро: sing-box', 'Engine: sing-box');
  }
  return tr('Ядро: Tachyon Core', 'Engine: Tachyon Core');
}

export function mountTachyonAppShell(options: MountAppShellOptions = {}): void {
  if (typeof document === 'undefined') return;
  installModalHeaderCloseEnhancements();
  activeShellState.options = options;

  const mapEl =
    options.mapEl ||
    document.querySelector<HTMLElement>('#cbi-tachyon') ||
    document.querySelector<HTMLElement>('.cbi-map');
  if (!mapEl) return;

  let uiMode = getUiMode();
  let sidebarPos = getSidebarPos();
  let sidebarCollapsed = getSidebarCollapsed();
  let topbarCollapsed = getTopbarCollapsed();
  const expandedMenus = getExpandedMenus();

  setUiMode(uiMode);
  mapEl.classList.add('tachyon-app-shell');

  // Check if shell wrapper already exists inside mapEl
  let shellLayout = mapEl.querySelector<HTMLElement>(
    ':scope > .tachyon-shell-layout',
  );
  let sidebarEl: HTMLElement;
  let topbarEl: HTMLElement;
  let workspaceBodyEl: HTMLElement;

  if (!shellLayout) {
    sidebarEl = E('aside', { class: 'tachyon-sidebar' }, []);
    topbarEl = E('div', { class: 'tachyon-topbar', role: 'region' }, []);
    workspaceBodyEl = E('div', { class: 'tachyon-workspace-body' }, []);

    const mainColumn = E(
      'div',
      { class: 'tachyon-main-workspace tachyon-shell-main' },
      [topbarEl, workspaceBodyEl],
    );

    shellLayout = E(
      'div',
      { id: 'tachyon-app-shell', class: 'tachyon-shell-layout' },
      [sidebarEl, mainColumn],
    );

    // Move all existing children of mapEl into workspaceBodyEl so .cbi-tabmenu
    // and .cbi-map-tabbed / .cbi-section[data-tab] share the same parent
    const existingChildren = Array.from(
      mapEl.childNodes || mapEl.children || [],
    );
    for (const child of existingChildren) {
      workspaceBodyEl.appendChild(child);
    }

    mapEl.appendChild(shellLayout);
  } else {
    sidebarEl = shellLayout.querySelector<HTMLElement>('.tachyon-sidebar')!;
    topbarEl = shellLayout.querySelector<HTMLElement>('.tachyon-topbar')!;
    workspaceBodyEl = shellLayout.querySelector<HTMLElement>(
      '.tachyon-workspace-body',
    )!;

    const strayChildren = Array.from(
      mapEl.childNodes || mapEl.children || [],
    ).filter((n) => n !== shellLayout);
    for (const stray of strayChildren) {
      workspaceBodyEl.appendChild(stray);
    }
  }

  const syncShellAttributes = () => {
    const collapsedStr = sidebarCollapsed ? 'true' : 'false';
    const topbarCollapsedStr = topbarCollapsed ? 'true' : 'false';
    mapEl.setAttribute('data-ui-mode', uiMode);
    mapEl.setAttribute('data-sidebar-pos', sidebarPos);
    mapEl.setAttribute('data-sidebar-collapsed', collapsedStr);
    mapEl.setAttribute('data-topbar-collapsed', topbarCollapsedStr);
    shellLayout!.setAttribute('data-ui-mode', uiMode);
    shellLayout!.setAttribute('data-sidebar-pos', sidebarPos);
    shellLayout!.setAttribute('data-sidebar-collapsed', collapsedStr);
    shellLayout!.setAttribute('data-topbar-collapsed', topbarCollapsedStr);
    topbarEl.setAttribute('data-collapsed', topbarCollapsedStr);
    topbarEl.classList.toggle('is-collapsed', topbarCollapsed);
    setUiMode(uiMode);
  };

  syncShellAttributes();

  // Detect active LuCI tab from DOM
  const detectCurrentNavKey = (): string => {
    const activeSection = workspaceBodyEl.querySelector<HTMLElement>(
      '.cbi-map-tabbed > .cbi-section[data-tab-active="true"], ' +
        ':scope > .cbi-section[data-tab-active="true"], ' +
        '.cbi-map-tabbed > .cbi-section.cbi-tab:not(.cbi-tab-disabled), ' +
        ':scope > .cbi-section.cbi-tab:not(.cbi-tab-disabled)',
    );
    const activeTabLi = mapEl.querySelector<HTMLElement>(
      ':scope > .cbi-tabmenu > li.cbi-tab:not(.cbi-tab-disabled), ' +
        '.tachyon-workspace-body > .cbi-tabmenu > li.cbi-tab:not(.cbi-tab-disabled)',
    );
    const rawTab =
      activeSection?.getAttribute('data-tab') ||
      activeSection?.id ||
      activeTabLi?.getAttribute('data-tab') ||
      '';
    const cleanTab = rawTab.replace(/^cbi-tachyon-/, '');
    if (cleanTab === 'section') {
      const sub = options.getActiveSectionSubTab?.() || 'sections';
      return `section:${sub}`;
    }
    if (cleanTab === 'settings') {
      const settingsSec = mapEl.querySelector<HTMLElement>(
        '#cbi-tachyon-settings',
      );
      const activeSubLi = settingsSec?.querySelector<HTMLElement>(
        '.cbi-tabmenu > li.cbi-tab:not(.cbi-tab-disabled)',
      );
      const subKey = activeSubLi?.getAttribute('data-tab') || 'dns';
      const matched = NAV_ITEMS.find(
        (i) => i.luciTab === 'settings' && i.settingsSubTab === subKey,
      );
      return matched ? matched.key : 'settings:dns';
    }
    const found = NAV_ITEMS.find((i) => i.luciTab === cleanTab);
    if (found) {
      return found.key;
    }
    return activeShellState.activeNavKey || 'dashboard';
  };

  const wasInitialized = Boolean(activeShellState.initialized);
  const hasExplicitHash =
    typeof window !== 'undefined' &&
    Boolean(window.location?.hash && window.location.hash !== '#');
  if (!wasInitialized || !activeShellState.activeNavKey) {
    if (!hasExplicitHash) {
      activeShellState.activeNavKey = 'dashboard';
      expandedMenus.clear();
      saveExpandedMenus(expandedMenus);
    } else {
      activeShellState.activeNavKey = detectCurrentNavKey();
    }
    activeShellState.initialized = true;
  }
  const initialItem = NAV_ITEMS.find(
    (i) => i.key === activeShellState.activeNavKey,
  );
  if (initialItem?.parentMenu) {
    expandedMenus.add(initialItem.parentMenu);
  }

  const syncTopLevelTabsDom = (targetLuciTab: string) => {
    const topTabItems = workspaceBodyEl.querySelectorAll<HTMLElement>(
      ':scope > .cbi-tabmenu > li[data-tab], .cbi-map-tabbed > .cbi-tabmenu > li[data-tab]',
    );
    topTabItems.forEach((li) => {
      const rawTab = li.getAttribute('data-tab') || '';
      const isTarget =
        rawTab === targetLuciTab || rawTab === `cbi-tachyon-${targetLuciTab}`;
      li.classList.toggle('cbi-tab', isTarget);
      li.classList.toggle('cbi-tab-disabled', !isTarget);
    });

    const allSections = workspaceBodyEl.querySelectorAll<HTMLElement>(
      '.cbi-map-tabbed > .cbi-section[id^="cbi-tachyon-"], :scope > .cbi-section[id^="cbi-tachyon-"]',
    );
    allSections.forEach((sec) => {
      const isTarget = sec.id === `cbi-tachyon-${targetLuciTab}`;
      sec.classList.toggle('cbi-tab', isTarget);
      sec.classList.toggle('cbi-tab-disabled', !isTarget);
      sec.setAttribute('data-tab-active', isTarget ? 'true' : 'false');
      sec.style.display = isTarget ? '' : 'none';
    });
  };

  const activateNavItem = (item: NavItemDef) => {
    activeShellState.activeNavKey = item.key;
    sidebarEl.classList.remove('is-mobile-open');
    if (item.parentMenu) {
      expandedMenus.add(item.parentMenu);
      saveExpandedMenus(expandedMenus);
    }

    const tabLi = workspaceBodyEl.querySelector<HTMLElement>(
      `:scope > .cbi-tabmenu > li[data-tab="cbi-tachyon-${item.luciTab}"], ` +
        `:scope > .cbi-tabmenu > li[data-tab="${item.luciTab}"], ` +
        `.cbi-map-tabbed > .cbi-tabmenu > li[data-tab="cbi-tachyon-${item.luciTab}"], ` +
        `.cbi-map-tabbed > .cbi-tabmenu > li[data-tab="${item.luciTab}"]`,
    );
    const tabLink = tabLi?.querySelector<HTMLAnchorElement>('a');
    if (tabLi && tabLink) {
      // LuCI ui.tabs.switchTab returns early if li does not have .cbi-tab-disabled
      tabLi.classList.add('cbi-tab-disabled');
      tabLink.click();
    }

    syncTopLevelTabsDom(item.luciTab);

    // Notify Store tabService so controllers (dashboard, monitoring, etc.) mount/unmount
    const currentTabService = store.get().tabService;
    if (currentTabService && currentTabService.current !== item.luciTab) {
      store.set({
        tabService: {
          ...currentTabService,
          current: item.luciTab as any,
        },
      });
    }

    if (item.luciTab === 'section' && item.subTab) {
      options.onSelectSectionSubTab?.(item.subTab);
    }

    if (item.luciTab === 'settings' && item.settingsSubTab) {
      const subTab = item.settingsSubTab;
      const settingsSec = mapEl.querySelector<HTMLElement>(
        '#cbi-tachyon-settings',
      );
      switchSettingsInternalSubTab(settingsSec, subTab);
      if (
        typeof window !== 'undefined' &&
        typeof window.setTimeout === 'function'
      ) {
        window.setTimeout(() => {
          const sec = mapEl.querySelector<HTMLElement>('#cbi-tachyon-settings');
          switchSettingsInternalSubTab(sec, subTab);
        }, 0);
      }
    }

    renderSidebarAndTopbar();
  };

  // Ensure initial active tab visibility is clean (hides any inactive tabs that LuCI left height:0)
  const initialActiveItem =
    NAV_ITEMS.find((i) => i.key === activeShellState.activeNavKey) ||
    NAV_ITEMS[0];
  syncTopLevelTabsDom(initialActiveItem.luciTab);

  // Also listen for LuCI's asynchronous ui.tabs initialization or internal sub-tab clicks
  if (!workspaceBodyEl.dataset.shellTabListenerAttached) {
    workspaceBodyEl.dataset.shellTabListenerAttached = 'true';
    workspaceBodyEl.addEventListener('cbi-tab-active', (ev: Event) => {
      if (activeShellState.restoringTab) {
        return;
      }
      const targetSec = ev.target as HTMLElement | null;
      if (
        targetSec &&
        targetSec.classList.contains('cbi-section') &&
        targetSec.id.startsWith('cbi-tachyon-')
      ) {
        const tabName = targetSec.id.replace(/^cbi-tachyon-/, '');
        syncTopLevelTabsDom(tabName);
        activeShellState.activeNavKey = detectCurrentNavKey();
        renderSidebarAndTopbar();
      } else if (
        targetSec &&
        targetSec.closest('#cbi-tachyon-settings') &&
        targetSec.hasAttribute('data-tab')
      ) {
        const subKey = targetSec.getAttribute('data-tab') || '';
        const matched = NAV_ITEMS.find(
          (i) => i.luciTab === 'settings' && i.settingsSubTab === subKey,
        );
        if (matched && activeShellState.activeNavKey !== matched.key) {
          activeShellState.activeNavKey = matched.key;
          renderSidebarAndTopbar();
        }
      }
    });
  }

  const renderSidebarAndTopbar = () => {
    syncShellAttributes();

    const tabOrder = getLuciTabOrderFromUci(options.getTabOrder);
    const sortByTabOrder = (items: NavItemDef[]): NavItemDef[] => {
      if (!tabOrder.length) return items;
      return items.slice().sort((a, b) => {
        const ka = a.uciTabId || a.luciTab;
        const kb = b.uciTabId || b.luciTab;
        if (ka === kb) return 0;
        let ia = tabOrder.indexOf(ka);
        if (ia === -1) ia = tabOrder.indexOf(a.luciTab);
        let ib = tabOrder.indexOf(kb);
        if (ib === -1) ib = tabOrder.indexOf(b.luciTab);
        if (ia === -1 && ib === -1) return 0;
        if (ia === -1) return 1;
        if (ib === -1) return -1;
        return ia - ib;
      });
    };

    const visibleItems = NAV_ITEMS.filter((item) => {
      const sectionNode = mapEl.querySelector(`#cbi-tachyon-${item.luciTab}`);
      if (!sectionNode) return false;
      if (
        !isLuciTabVisibleInUci(
          item.uciTabId || item.luciTab,
          options.isTabVisible,
        )
      ) {
        return false;
      }
      if (uiMode === 'simple') {
        return item.simpleVisible;
      }
      return true;
    });

    if (!visibleItems.some((i) => i.key === activeShellState.activeNavKey)) {
      const fallback =
        visibleItems.find(
          (i) =>
            i.luciTab === activeShellState.activeNavKey.replace(/:.*$/, ''),
        ) || visibleItems[0];
      if (fallback) {
        activeShellState.activeNavKey = fallback.key;
      }
    }

    // Build Sidebar Navigation with Collapsible Submenus
    const navElements: HTMLElement[] = [];

    // 1. Direct top-level items (Обзор / Dashboard)
    const directItems = sortByTabOrder(
      visibleItems.filter((i) => !i.parentMenu),
    );
    for (const item of directItems) {
      const isActive = item.key === activeShellState.activeNavKey;
      const label = tr(item.labelRu, item.labelEn);
      navElements.push(
        E(
          'button',
          {
            type: 'button',
            class: `tachyon-sidebar__nav-item ${isActive ? 'is-active' : ''}`,
            title: label,
            'data-nav-key': item.key,
            click: (ev: MouseEvent) => {
              ev.preventDefault();
              activateNavItem(item);
            },
          } as any,
          [
            renderNavIcon(item.iconPaths, 18),
            E('span', { class: 'tachyon-sidebar__nav-label' }, label),
          ],
        ),
      );
    }

    // 2. Collapsible Parent Menus with Submenus
    for (const parent of PARENT_MENUS) {
      const children = sortByTabOrder(
        visibleItems.filter((i) => i.parentMenu === parent.id),
      );
      if (children.length === 0) continue;

      const hasActiveChild = children.some(
        (c) => c.key === activeShellState.activeNavKey,
      );
      const isMenuExpanded = expandedMenus.has(parent.id) || hasActiveChild;
      const parentLabel = tr(parent.labelRu, parent.labelEn);

      const chevronSvg = svgEl(
        'svg',
        {
          viewBox: '0 0 24 24',
          width: '15',
          height: '15',
          fill: 'none',
          stroke: 'currentColor',
          'stroke-width': '2',
          'stroke-linecap': 'round',
          'stroke-linejoin': 'round',
          class: `tachyon-sidebar__chevron ${isMenuExpanded ? 'is-open' : ''}`,
        },
        [svgEl('polyline', { points: '6 9 12 15 18 9' })],
      );

      const parentBtn = E(
        'button',
        {
          type: 'button',
          class: [
            'tachyon-sidebar__nav-item',
            'tachyon-sidebar__nav-parent',
            hasActiveChild ? 'has-active-child' : '',
            isMenuExpanded ? 'is-expanded' : '',
          ]
            .filter(Boolean)
            .join(' '),
          title: parentLabel,
          'data-parent-menu': parent.id,
          'aria-expanded': isMenuExpanded ? 'true' : 'false',
          click: (ev: MouseEvent) => {
            ev.preventDefault();
            if (sidebarCollapsed) {
              sidebarCollapsed = false;
              setSidebarCollapsed(false);
              expandedMenus.add(parent.id);
              saveExpandedMenus(expandedMenus);
              if (!hasActiveChild && children[0]) {
                activateNavItem(children[0]);
              } else {
                renderSidebarAndTopbar();
              }
              return;
            }

            if (expandedMenus.has(parent.id)) {
              expandedMenus.delete(parent.id);
              saveExpandedMenus(expandedMenus);
              renderSidebarAndTopbar();
            } else {
              expandedMenus.add(parent.id);
              saveExpandedMenus(expandedMenus);
              if (!hasActiveChild && children[0]) {
                activateNavItem(children[0]);
              } else {
                renderSidebarAndTopbar();
              }
            }
          },
        } as any,
        [
          renderNavIcon(parent.iconPaths, 18),
          E('span', { class: 'tachyon-sidebar__nav-label' }, parentLabel),
          E(
            'span',
            { class: 'tachyon-sidebar__nav-count' },
            String(children.length),
          ),
          chevronSvg,
        ],
      );

      const subMenuEl = E(
        'div',
        {
          class: `tachyon-sidebar__submenu ${isMenuExpanded ? 'is-open' : ''}`,
        },
        children.map((child) => {
          const isChildActive = child.key === activeShellState.activeNavKey;
          const childLabel = tr(child.labelRu, child.labelEn);
          return E(
            'button',
            {
              type: 'button',
              class: `tachyon-sidebar__subitem ${isChildActive ? 'is-active' : ''}`,
              title: childLabel,
              'data-nav-key': child.key,
              click: (ev: MouseEvent) => {
                ev.preventDefault();
                ev.stopPropagation();
                activateNavItem(child);
              },
            } as any,
            [
              E('span', { class: 'tachyon-sidebar__subitem-dot' }),
              E(
                'span',
                { class: 'tachyon-sidebar__subitem-label' },
                childLabel,
              ),
            ],
          );
        }),
      );

      navElements.push(
        E(
          'div',
          {
            class: `tachyon-sidebar__menu-block ${isMenuExpanded ? 'is-open' : ''}`,
          },
          [parentBtn, subMenuEl],
        ),
      );
    }

    // Service live status in Sidebar Footer
    const srvState = store.get().servicesInfoWidget;
    const isRunning = Boolean(
      srvState?.data?.tachyonRunning || srvState?.data?.singbox,
    );
    const isReloading = srvState?.data?.tachyonStatus === 'reloading';
    const isLiteMode = Boolean(srvState?.data?.liteMode);
    const statusText = isReloading
      ? tr('Перезапуск...', 'Reloading...')
      : isRunning
        ? tr('Система работает', 'System running')
        : tr('Остановлена', 'Service stopped');
    const statusDotClass = isReloading
      ? 'tachyon-sidebar__status-dot--warn'
      : isRunning
        ? 'tachyon-sidebar__status-dot--ok'
        : 'tachyon-sidebar__status-dot--err';

    const activeNavItemDef =
      visibleItems.find((i) => i.key === activeShellState.activeNavKey) ||
      visibleItems[0] ||
      NAV_ITEMS[0];
    const activeNavLabel = tr(
      activeNavItemDef.labelRu,
      activeNavItemDef.labelEn,
    );
    const isMobileMenuOpen = sidebarEl.classList.contains('is-mobile-open');

    if (
      typeof document !== 'undefined' &&
      !(sidebarEl as any)._mobileOutsideListener
    ) {
      (sidebarEl as any)._mobileOutsideListener = true;
      document.addEventListener('click', (ev: MouseEvent) => {
        if (!sidebarEl.classList.contains('is-mobile-open')) return;
        const target = ev.target as Node | null;
        if (target && !sidebarEl.contains(target)) {
          sidebarEl.classList.remove('is-mobile-open');
        }
      });
    }

    sidebarEl.replaceChildren(
      E('div', { class: 'tachyon-sidebar__brand' }, [
        E(
          'div',
          {
            class: 'tachyon-sidebar__logo-wrap',
            title: sidebarCollapsed
              ? tr('Развернуть боковое меню', 'Expand sidebar')
              : 'Tachyon',
            click: () => {
              if (sidebarCollapsed) {
                sidebarCollapsed = false;
                setSidebarCollapsed(false);
                renderSidebarAndTopbar();
              } else {
                const dash = NAV_ITEMS.find((i) => i.key === 'dashboard');
                if (dash) activateNavItem(dash);
              }
            },
          },
          [renderTachyonDuckMascotSvg(sidebarCollapsed ? 32 : 40)],
        ),
        E('div', { class: 'tachyon-sidebar__brand-text' }, [
          E('div', { class: 'tachyon-sidebar__brand-title' }, 'Tachyon'),
          E(
            'div',
            { class: 'tachyon-sidebar__brand-sub' },
            uiMode === 'simple'
              ? tr('Обычный режим', 'Simple Mode')
              : tr('Расширенный режим', 'Advanced Mode'),
          ),
        ]),
        E(
          'button',
          {
            type: 'button',
            class: 'tachyon-sidebar__mobile-toggle',
            title: tr('Открыть меню разделов', 'Open navigation menu'),
            click: (ev: MouseEvent) => {
              ev.preventDefault();
              ev.stopPropagation();
              sidebarEl.classList.toggle('is-mobile-open');
            },
          } as any,
          [
            E('span', {
              class: `tachyon-sidebar__status-dot ${statusDotClass}`,
            }),
            E(
              'span',
              { class: 'tachyon-sidebar__mobile-toggle-label' },
              activeNavLabel,
            ),
            E('span', {}, isMobileMenuOpen ? '▴' : '▾'),
          ],
        ),
        E(
          'button',
          {
            type: 'button',
            class: 'tachyon-sidebar__collapse-btn',
            title: sidebarCollapsed
              ? tr('Развернуть меню', 'Expand menu')
              : tr('Свернуть меню в значки', 'Collapse menu to icons'),
            click: (ev: MouseEvent) => {
              ev.preventDefault();
              ev.stopPropagation();
              sidebarCollapsed = !sidebarCollapsed;
              setSidebarCollapsed(sidebarCollapsed);
              renderSidebarAndTopbar();
            },
          } as any,
          sidebarCollapsed
            ? sidebarPos === 'left'
              ? '»'
              : '«'
            : sidebarPos === 'left'
              ? '«'
              : '»',
        ),
      ]),

      E('nav', { class: 'tachyon-sidebar__nav' }, navElements),

      E('div', { class: 'tachyon-sidebar__footer' }, [
        E('div', { class: 'tachyon-sidebar__status-card' }, [
          E('div', { class: 'tachyon-sidebar__status-row' }, [
            E('span', {
              class: `tachyon-sidebar__status-dot ${statusDotClass}`,
            }),
            E('span', { class: 'tachyon-sidebar__status-label' }, statusText),
          ]),
          E(
            'div',
            { class: 'tachyon-sidebar__status-meta' },
            formatSidebarEngineLabel(),
          ),
        ]),
      ]),
    );

    const langSlot = E('div', { class: 'tachyon-topbar__lang-slot' }, []);
    const liteTooltip = tr(
      'Эко-режим (Tachyon Lite) для слабых роутеров: пониженный приоритет прокси (nice 15), ct mark Short-Circuit + connlimit и гибернация фоновых проверок при нагрузке',
      'Tachyon Lite eco mode for low-power routers: lower proxy priority (nice 15), ct mark Short-Circuit + connlimit and background check hibernation under load',
    );

    topbarEl.style.display = '';
    topbarEl.replaceChildren(
      E('div', { class: 'tachyon-topbar__left' }, [
        E(
          'div',
          {
            class: 'tachyon-mode-switcher',
            role: 'group',
            'aria-label': tr('Режим интерфейса', 'Interface Mode'),
          },
          [
            E(
              'button',
              {
                type: 'button',
                class: `tachyon-mode-switcher__btn ${uiMode === 'simple' ? 'is-active' : ''}`,
                title: tr(
                  'Обычный режим: только базовые настройки и быстрый мастер подключений',
                  'Simple mode: basic settings and quick connection wizard',
                ),
                click: () => {
                  if (uiMode === 'simple') return;
                  uiMode = 'simple';
                  renderSidebarAndTopbar();
                },
              },
              tr('Обычный', 'Simple'),
            ),
            E(
              'button',
              {
                type: 'button',
                class: `tachyon-mode-switcher__btn ${uiMode === 'advanced' ? 'is-active' : ''}`,
                title: tr(
                  'Расширенный режим: все разделы, условия, балансировщики и тонкие настройки',
                  'Advanced mode: all tabs, conditions, balancers and expert settings',
                ),
                click: () => {
                  if (uiMode === 'advanced') return;
                  uiMode = 'advanced';
                  renderSidebarAndTopbar();
                },
              },
              tr('Расширенный', 'Advanced'),
            ),
          ],
        ),
        E(
          'button',
          {
            type: 'button',
            class: `tachyon-topbar__eco-btn ${isLiteMode ? 'is-active' : ''}`,
            title: liteTooltip,
            click: async (ev: MouseEvent) => {
              ev.preventDefault();
              const btn = ev.currentTarget as HTMLButtonElement | null;
              const currentSrv = store.get().servicesInfoWidget;
              const curLite = Boolean(currentSrv?.data?.liteMode);
              const nextEnabled = !curLite;
              if (btn) {
                btn.disabled = true;
                btn.replaceChildren(renderZapIcon(14), E('span', {}, ' ...'));
              }
              try {
                const res = await TachyonShellMethods.setLiteMode(nextEnabled);
                if (res.success) {
                  const latestSrv = store.get().servicesInfoWidget;
                  store.set({
                    servicesInfoWidget: {
                      ...latestSrv,
                      data: {
                        ...latestSrv.data,
                        liteMode: nextEnabled ? 1 : 0,
                      },
                    },
                  });
                  showToast(
                    nextEnabled
                      ? tr(
                          'Эко-режим Tachyon Lite включён',
                          'Tachyon Lite eco mode enabled',
                        )
                      : tr(
                          'Эко-режим Tachyon Lite выключен',
                          'Tachyon Lite eco mode disabled',
                        ),
                    'success',
                  );
                } else {
                  showToast(
                    res.error ||
                      tr(
                        'Не удалось переключить Эко-режим',
                        'Failed to toggle Eco Mode',
                      ),
                    'error',
                  );
                }
              } catch (err: any) {
                showToast(
                  err?.message ||
                    tr(
                      'Не удалось переключить Эко-режим',
                      'Failed to toggle Eco Mode',
                    ),
                  'error',
                );
              } finally {
                renderSidebarAndTopbar();
              }
            },
          } as any,
          [
            renderZapIcon(14),
            E(
              'span',
              {},
              isLiteMode
                ? tr('Эко-режим: Вкл', 'Eco Mode: On')
                : tr('Эко-режим', 'Eco Mode'),
            ),
          ],
        ),
      ]),
      E('div', { class: 'tachyon-topbar__right' }, [
        E(
          'button',
          {
            type: 'button',
            class: 'tachyon-topbar__wizard-btn',
            title: tr(
              'Добавить подключение (Мастер настройки)',
              'Add Connection (Setup Wizard)',
            ),
            click: () => {
              openConnectionWizardModal({
                onComplete: ({ direction }) => {
                  if (direction === 'inbound') {
                    const srvItem = NAV_ITEMS.find((i) => i.key === 'server');
                    if (srvItem) activateNavItem(srvItem);
                  } else {
                    const secItem = NAV_ITEMS.find(
                      (i) => i.key === 'section:sections',
                    );
                    if (secItem) activateNavItem(secItem);
                  }
                  options.onReloadMap?.();
                },
              });
            },
          },
          [renderPlusIcon(14), E('span', {}, tr('Подключение', 'Connection'))],
        ),
        E(
          'button',
          {
            type: 'button',
            class: 'tachyon-topbar__icon-btn tachyon-topbar__sidebar-pos-btn',
            title:
              sidebarPos === 'left'
                ? tr(
                    'Переместить боковое меню направо',
                    'Move sidebar to the right',
                  )
                : tr(
                    'Переместить боковое меню налево',
                    'Move sidebar to the left',
                  ),
            click: () => {
              sidebarPos = sidebarPos === 'left' ? 'right' : 'left';
              setSidebarPos(sidebarPos);
              renderSidebarAndTopbar();
            },
          },
          sidebarPos === 'left' ? '◧ ⇄ ◨' : '◨ ⇄ ◧',
        ),
        langSlot,
        E(
          'button',
          {
            type: 'button',
            class: 'tachyon-topbar__icon-btn tachyon-topbar__collapse-btn',
            title: topbarCollapsed
              ? tr('Развернуть панель инструментов', 'Expand top toolbar')
              : tr('Свернуть панель инструментов', 'Collapse top toolbar'),
            click: () => {
              topbarCollapsed = !topbarCollapsed;
              setTopbarCollapsed(topbarCollapsed);
              renderSidebarAndTopbar();
            },
          },
          topbarCollapsed ? '▾' : '▴',
        ),
      ]),
    );

    mountLanguageSelector(
      options.capabilities || options.uiCapabilities,
      langSlot,
    );

    // Sync Settings sub-tabs for Simple / Advanced mode
    const settingsSec = mapEl.querySelector<HTMLElement>(
      '#cbi-tachyon-settings',
    );
    if (settingsSec) {
      const advTabLink = settingsSec.querySelector<HTMLAnchorElement>(
        '.cbi-tabmenu > li[data-tab="advanced"] > a',
      );
      if (advTabLink) {
        if (!advTabLink.dataset.origLabel) {
          advTabLink.dataset.origLabel = advTabLink.textContent || '';
        }
        advTabLink.textContent =
          uiMode === 'simple'
            ? tr('Система и бэкап', 'System & Backup')
            : advTabLink.dataset.origLabel ||
              tr('Расширенные системные', 'Advanced System');
      }
      if (uiMode === 'simple') {
        const activeSubLi = settingsSec.querySelector<HTMLElement>(
          '.cbi-tabmenu > li.cbi-tab:not(.cbi-tab-disabled)',
        );
        const activeSubKey = activeSubLi?.getAttribute('data-tab') || '';
        if (activeSubKey === 'ai') {
          switchSettingsInternalSubTab(settingsSec, 'dns');
        }
      }
    }

    // Mount Quick Action Toolbar banners across workspace panes
    const ensureQuickBar = (
      container: HTMLElement | null,
      barId: string,
      titleRu: string,
      titleEn: string,
      descRu: string,
      descEn: string,
      wizardDir?: 'outbound' | 'inbound',
    ) => {
      if (!container) return;
      let bar = container.querySelector<HTMLElement>(`#${barId}`);
      if (!bar) {
        bar = E('div', { id: barId, class: 'tachyon-pane-quickbar' }, []);
        container.insertBefore(bar, container.firstChild);
      }
      bar.replaceChildren(
        E('div', { class: 'tachyon-pane-quickbar__info' }, [
          E(
            'div',
            { class: 'tachyon-pane-quickbar__title' },
            tr(titleRu, titleEn),
          ),
          E(
            'div',
            { class: 'tachyon-pane-quickbar__desc' },
            tr(descRu, descEn),
          ),
        ]),
        E('div', { class: 'tachyon-pane-quickbar__actions' }, [
          ...(uiMode === 'simple'
            ? [
                E(
                  'button',
                  {
                    type: 'button',
                    class: 'tachyon-pane-quickbar__mode-hint',
                    click: () => {
                      uiMode = 'advanced';
                      renderSidebarAndTopbar();
                    },
                  },
                  tr(
                    'Нужны тонкие параметры? Расширенный режим →',
                    'Need expert knobs? Advanced Mode →',
                  ),
                ),
              ]
            : []),
          ...(wizardDir
            ? [
                E(
                  'button',
                  {
                    type: 'button',
                    class: 'tachyon-pane-quickbar__wizard-btn',
                    click: () => {
                      openConnectionWizardModal({
                        initialDirection: wizardDir,
                        onComplete: ({ direction }) => {
                          if (direction === 'inbound') {
                            const srvItem = NAV_ITEMS.find(
                              (i) => i.key === 'server',
                            );
                            if (srvItem) activateNavItem(srvItem);
                          } else {
                            const secItem = NAV_ITEMS.find(
                              (i) => i.key === 'section:sections',
                            );
                            if (secItem) activateNavItem(secItem);
                          }
                          options.onReloadMap?.();
                        },
                      });
                    },
                  },
                  [
                    renderWandIcon(14),
                    E(
                      'span',
                      {},
                      tr('Быстрый мастер настройки', 'Quick Setup Wizard'),
                    ),
                  ],
                ),
              ]
            : []),
        ]),
      );
    };

    // Studio Deck panes (sections, outbounds, conditions, balancers, server,
    // profile, schedule) render their own compact header toolbar directly in
    // studioDeck.ts — only mount quickbars on non-deck panes below.
    ensureQuickBar(
      mapEl.querySelector<HTMLElement>('#cbi-tachyon-guest_mode'),
      'tachyon-quickbar-guest-mode',
      'Гостевой режим и квоты трафика',
      'Guest Mode & Traffic Quotas',
      'Изоляция гостевых устройств от локальной сети и панели роутера с поддержкой дневных лимитов трафика.',
      'Isolate guest devices from local LAN and router administration with daily traffic quotas.',
    );

    ensureQuickBar(
      mapEl.querySelector<HTMLElement>('#cbi-tachyon-telegram'),
      'tachyon-quickbar-telegram',
      'Telegram-бот управления роутером',
      'Telegram Remote Management Bot',
      'Удалённое переключение маршрутов, проверка пинга и уведомления о событиях через вашего Telegram-бота.',
      'Remote route switching, latency checks, and system alerts via your Telegram bot.',
    );

    if (settingsSec) {
      const activeSettingsNav =
        NAV_ITEMS.find(
          (i) =>
            i.luciTab === 'settings' && i.key === activeShellState.activeNavKey,
        ) ||
        NAV_ITEMS.find((i) => i.key === 'settings:dns') ||
        NAV_ITEMS[0];
      ensureQuickBar(
        settingsSec,
        'tachyon-quickbar-settings',
        activeSettingsNav.labelRu,
        activeSettingsNav.labelEn,
        activeSettingsNav.subtitleRu,
        activeSettingsNav.subtitleEn,
      );
    }
  };

  activeShellState.renderFn = renderSidebarAndTopbar;
  renderSidebarAndTopbar();

  const targetItem =
    NAV_ITEMS.find((i) => i.key === activeShellState.activeNavKey) ||
    NAV_ITEMS[0];
  if (targetItem && (wasInitialized || !hasExplicitHash)) {
    activeShellState.restoringTab = true;
    activateNavItem(targetItem);
    if (
      typeof window !== 'undefined' &&
      typeof window.requestAnimationFrame === 'function'
    ) {
      window.requestAnimationFrame(() => {
        activateNavItem(targetItem);
        activeShellState.restoringTab = false;
      });
    } else {
      activeShellState.restoringTab = false;
    }
  }

  // Keep sidebar footer status and topbar eco button in sync with store updates
  if (!sidebarEl.dataset.storeSubAttached) {
    sidebarEl.dataset.storeSubAttached = 'true';
    store.subscribe((_next, _prev, diff) => {
      if (diff.servicesInfoWidget) {
        const srv = store.get().servicesInfoWidget;
        const dots = sidebarEl.querySelectorAll('.tachyon-sidebar__status-dot');
        const lbl = sidebarEl.querySelector('.tachyon-sidebar__status-label');
        const running = Boolean(srv?.data?.tachyonRunning);
        const reloading = srv?.data?.tachyonStatus === 'reloading';
        const dotClass = `tachyon-sidebar__status-dot ${
          reloading
            ? 'tachyon-sidebar__status-dot--warn'
            : running
              ? 'tachyon-sidebar__status-dot--ok'
              : 'tachyon-sidebar__status-dot--err'
        }`;
        dots.forEach((dot) => {
          dot.className = dotClass;
        });
        if (lbl) {
          lbl.textContent = reloading
            ? tr('Перезапуск...', 'Reloading...')
            : running
              ? tr('Система работает', 'System running')
              : tr('Остановлена', 'Service stopped');
        }
        const ecoBtn = topbarEl.querySelector<HTMLButtonElement>(
          '.tachyon-topbar__eco-btn',
        );
        if (ecoBtn && !ecoBtn.disabled) {
          const isLite = Boolean(srv?.data?.liteMode);
          ecoBtn.replaceChildren(
            renderZapIcon(14),
            E(
              'span',
              {},
              isLite
                ? tr('Эко-режим: Вкл', 'Eco Mode: On')
                : tr('Эко-режим', 'Eco Mode'),
            ),
          );
        }
      }
      if (diff.diagnosticsSystemInfo || diff.servicesInfoWidget) {
        const metaEl = sidebarEl.querySelector('.tachyon-sidebar__status-meta');
        if (metaEl) {
          metaEl.textContent = formatSidebarEngineLabel();
        }
      }
    });
  }
}
