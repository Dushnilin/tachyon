/* eslint-disable @typescript-eslint/no-explicit-any */
import { TACHYON_UCI_PACKAGE } from '../constants';
import {
  humanizeRuntimeTag,
  buildRuntimeTagDisplayContextFromUci,
} from './helpers/humanizeTag';
import { tr } from './helpers/i18n';
import { store } from './services/store.service';
import { activateAppShellNavKey } from './services/tab.service';
import {
  getActiveTheme,
  getAllThemes,
  setActiveTheme,
} from './themes/themeCatalog';
import { openCustomThemeModal } from './themes/themeControls';

export interface CommandPaletteNavEntry {
  key: string;
  labelRu: string;
  labelEn: string;
  subtitleRu?: string;
  subtitleEn?: string;
}

export interface CommandPaletteDeps {
  getNavItems?: () => CommandPaletteNavEntry[];
  activateNav?: (key: string) => void;
  openWizard?: () => void;
  openHistory?: () => void;
  getUiMode?: () => 'simple' | 'advanced';
  setUiMode?: (mode: 'simple' | 'advanced') => void;
  getLayoutWidth?: () => 'compact' | 'full';
  setLayoutWidth?: (w: 'compact' | 'full') => void;
  getLiteMode?: () => boolean;
  toggleLiteMode?: () => void;
  restartService?: () => void;
  refreshShell?: () => void;
}

export interface CommandPaletteItem {
  id: string;
  group: string;
  title: string;
  subtitle: string;
  badge: string;
  keywords?: string;
  run: () => void;
}

let activeDeps: CommandPaletteDeps = {};
let isOpen = false;
let currentQuery = '';
let selectedIdx = 0;
let currentItems: CommandPaletteItem[] = [];
let overlayEl: HTMLElement | null = null;
let keydownBound = false;

export function _resetCommandPaletteForTests(): void {
  isOpen = false;
  currentQuery = '';
  selectedIdx = 0;
  currentItems = [];
  overlayEl?.remove?.();
  overlayEl = null;
  activeDeps = {};
  keydownBound = false;
}

function createEl(
  tag: string,
  attrs: Record<string, any> = {},
  children: Array<HTMLElement | Text | string | null | undefined> = [],
): HTMLElement {
  const node = document.createElement(tag) as any;
  for (const [k, v] of Object.entries(attrs)) {
    if (v == null || v === false) continue;
    if (k === 'class') {
      node.className = String(v);
    } else if (k === 'style') {
      node.setAttribute?.('style', String(v));
      if (typeof node.style === 'object') {
        node.style.cssText = String(v);
      }
    } else if (k === 'value') {
      node.value = String(v);
      node.setAttribute?.('value', String(v));
    } else if (
      ['click', 'input', 'keydown'].includes(k) &&
      typeof v === 'function'
    ) {
      node.addEventListener?.(k, v);
    } else {
      node.setAttribute?.(k, v === true ? '' : String(v));
    }
  }
  for (const child of children) {
    if (child == null) continue;
    if (typeof child === 'string') {
      node.appendChild(document.createTextNode(child));
    } else {
      node.appendChild(child);
    }
  }
  return node;
}

function safeUciSections(secType: string): any[] {
  try {
    const g = globalThis as any;
    const uciApi = typeof uci !== 'undefined' ? (uci as any) : g.uci;
    if (uciApi && typeof uciApi.sections === 'function') {
      const list = uciApi.sections(TACHYON_UCI_PACKAGE, secType);
      return Array.isArray(list) ? list : [];
    }
  } catch {
    // ignore in tests
  }
  return [];
}

function navigateTo(key: string, deps: CommandPaletteDeps): void {
  if (typeof deps.activateNav === 'function') {
    deps.activateNav(key);
  } else {
    activateAppShellNavKey(key);
  }
}

export function buildCommandPaletteItems(
  query: string,
  deps: CommandPaletteDeps = activeDeps,
): CommandPaletteItem[] {
  const q = String(query || '')
    .trim()
    .toLowerCase();
  const items: CommandPaletteItem[] = [];
  const ctx = buildRuntimeTagDisplayContextFromUci();

  const quickGroup = tr('Быстрые действия', 'Quick Actions');
  const uiMode = deps.getUiMode?.() || 'simple';
  const layoutWidth = deps.getLayoutWidth?.() || 'compact';
  const liteOn = Boolean(
    deps.getLiteMode?.() ?? store.get().servicesInfoWidget?.data?.liteMode,
  );

  if (deps.openWizard) {
    items.push({
      id: 'act:wizard',
      group: quickGroup,
      title: tr('Мастер настройки подключения', 'Connection Setup Wizard'),
      subtitle: tr(
        'Добавить подписку, прокси-ссылку, туннель или сервер по шагам',
        'Add subscription, proxy link, tunnel or server step by step',
      ),
      badge: tr('Мастер', 'Wizard'),
      keywords: 'wizard setup connection vless awg',
      run: () => deps.openWizard?.(),
    });
  }

  if (deps.openHistory) {
    items.push({
      id: 'act:history',
      group: quickGroup,
      title: tr(
        'История конфигураций и откат',
        'Configuration History & Rollback',
      ),
      subtitle: tr(
        'Просмотр несохранённых изменений и точек восстановления',
        'Review unsaved changes and restore points',
      ),
      badge: tr('История', 'History'),
      keywords: 'history rollback lkg snapshot',
      run: () => deps.openHistory?.(),
    });
  }

  if (deps.setUiMode) {
    const nextMode = uiMode === 'simple' ? 'advanced' : 'simple';
    items.push({
      id: 'act:ui-mode',
      group: quickGroup,
      title:
        nextMode === 'advanced'
          ? tr('Включить расширенный режим', 'Switch to Advanced Mode')
          : tr('Включить обычный режим', 'Switch to Simple Mode'),
      subtitle: tr(
        'Переключение детализации параметров в формах и настройках',
        'Toggle detailed form parameters',
      ),
      badge: nextMode === 'advanced' ? 'Advanced' : 'Simple',
      keywords: 'mode simple advanced режим yacd',
      run: () => {
        deps.setUiMode?.(nextMode);
        deps.refreshShell?.();
      },
    });
  }

  if (deps.setLayoutWidth) {
    const nextW = layoutWidth === 'compact' ? 'full' : 'compact';
    items.push({
      id: 'act:layout-width',
      group: quickGroup,
      title:
        nextW === 'compact'
          ? tr(
              'Включить компактную ширину (1360px)',
              'Use Compact Layout (1360px)',
            )
          : tr('Растянуть интерфейс на всю ширину', 'Use Full Width Layout'),
      subtitle: tr(
        'Центрированный компактный макет или полноэкранная ширина',
        'Centered compact container or full-bleed viewport width',
      ),
      badge: nextW === 'compact' ? '1360px' : '100%',
      keywords: 'width compact full layout ширина компакт',
      run: () => {
        deps.setLayoutWidth?.(nextW);
        deps.refreshShell?.();
      },
    });
  }

  if (deps.toggleLiteMode) {
    items.push({
      id: 'act:eco',
      group: quickGroup,
      title: liteOn
        ? tr('Выключить Эко-режим (Tachyon Lite)', 'Disable Eco Mode')
        : tr('Включить Эко-режим (Tachyon Lite)', 'Enable Eco Mode'),
      subtitle: tr(
        'Режим экономии ресурсов для маршрутизаторов с небольшим объёмом ОЗУ',
        'Resource-saving mode for constrained routers',
      ),
      badge: liteOn ? 'Lite: On' : 'Lite: Off',
      keywords: 'eco lite память cpu',
      run: () => deps.toggleLiteMode?.(),
    });
  }

  items.push({
    id: 'act:custom-theme',
    group: quickGroup,
    title: tr(
      'Создать свою цветовую тему / импорт JSON',
      'Create Custom Theme / Import JSON',
    ),
    subtitle: tr(
      'Палитра 12 токенов с предпросмотром в реальном времени',
      '12-color palette editor with live preview',
    ),
    badge: tr('Тема', 'Theme'),
    keywords: 'theme palette color json тема цвет',
    run: () => openCustomThemeModal(),
  });

  items.push({
    id: 'act:panel-auth',
    group: quickGroup,
    title: tr(
      'Логин и пароль входа в панель',
      'Panel Login & Password Settings',
    ),
    subtitle: tr(
      'Настроить вход по данным роутера (LuCI) или отдельный пароль панели',
      'Configure router (LuCI) login or separate panel credentials',
    ),
    badge: tr('Вход', 'Auth'),
    keywords: 'login password auth вход пароль авторизация luci',
    run: () => navigateTo('settings:navigation', deps),
  });

  if (deps.restartService) {
    items.push({
      id: 'act:restart',
      group: quickGroup,
      title: tr('Перезапустить службу Tachyon', 'Restart Tachyon Service'),
      subtitle: tr(
        'Перезапуск основного сервиса маршрутизации',
        'Restart the core routing service',
      ),
      badge: tr('Служба', 'Service'),
      keywords: 'restart reload reboot перезапуск',
      run: () => deps.restartService?.(),
    });
  }

  // Navigation & Settings Tabs
  const navGroup = tr('Разделы и настройки', 'Sections & Settings');
  const navEntries = deps.getNavItems?.() || [];
  for (const nav of navEntries) {
    items.push({
      id: `nav:${nav.key}`,
      group: navGroup,
      title: tr(nav.labelRu, nav.labelEn),
      subtitle: tr(nav.subtitleRu || nav.key, nav.subtitleEn || nav.key),
      badge: tr('Раздел', 'Tab'),
      keywords: `${nav.key} ${nav.labelRu} ${nav.labelEn}`,
      run: () => navigateTo(nav.key, deps),
    });
  }

  // Live Outbound Groups & Nodes from store
  const nodeGroupLabel = tr(
    'Секции, группы и узлы (Runtime)',
    'Routing Sections & Live Nodes',
  );
  const seenIds = new Set<string>();
  const runtimeGroups = store.get().sectionsWidget?.data || [];
  for (const grp of runtimeGroups) {
    const grpTitle = humanizeRuntimeTag(
      grp.code,
      grp.displayName || grp.sectionName,
      { context: ctx },
    );
    const grpId = `rt-grp:${grp.code || grp.sectionName}`;
    if (!seenIds.has(grpId)) {
      seenIds.add(grpId);
      items.push({
        id: grpId,
        group: nodeGroupLabel,
        title: grpTitle,
        subtitle: tr('Секция маршрутизации', 'Routing section'),
        badge: grp.action || 'route',
        keywords: `${grp.code || ''} ${grp.sectionName || ''} ${grpTitle}`,
        run: () => navigateTo('dashboard', deps),
      });
    }
    for (const ob of grp.outbounds || []) {
      const obTitle = humanizeRuntimeTag(
        ob.code,
        ob.displayName || ob.sourceName,
        { context: ctx },
      );
      const obId = `rt-ob:${ob.code}:${grp.code}`;
      if (seenIds.has(obId)) continue;
      seenIds.add(obId);
      const latText =
        typeof ob.latency === 'number' && ob.latency > 0
          ? `${ob.latency} ms`
          : '';
      items.push({
        id: obId,
        group: nodeGroupLabel,
        title: obTitle,
        subtitle: [
          grpTitle,
          ob.sourceName
            ? humanizeRuntimeTag(ob.sourceName, ob.sourceName, { context: ctx })
            : '',
          ob.selected ? tr('выбран сейчас', 'selected') : '',
        ]
          .filter(Boolean)
          .join(' · '),
        badge: latText || ob.type || 'node',
        keywords: `${ob.code} ${obTitle} ${ob.sourceName || ''} ${ob.type}`,
        run: () => navigateTo('dashboard', deps),
      });
    }
  }

  // UCI Sections, Outbound Sources, Balancers, Inbound Servers, Conditions, Profiles, Schedules
  const uciConfigGroup = tr(
    'Конфигурация узлов и правил',
    'Configured Objects',
  );
  const uciSpecs: Array<{
    type: string;
    navKey: string;
    badgeRu: string;
    badgeEn: string;
    fallbackName: (rec: any) => string;
  }> = [
    {
      type: 'section',
      navKey: 'section:sections',
      badgeRu: 'Секция',
      badgeEn: 'Section',
      fallbackName: (r) => r.label || r.name || r['.name'],
    },
    {
      type: 'outbound_source',
      navKey: 'section:outbounds',
      badgeRu: 'Подключение',
      badgeEn: 'Source',
      fallbackName: (r) => r.name || r.label || r['.name'],
    },
    {
      type: 'balancer',
      navKey: 'section:balancers',
      badgeRu: 'Балансировщик',
      badgeEn: 'Balancer',
      fallbackName: (r) => r.name || r.label || r['.name'],
    },
    {
      type: 'server',
      navKey: 'server',
      badgeRu: 'Сервер',
      badgeEn: 'Server',
      fallbackName: (r) => r.label || r.name || r['.name'],
    },
    {
      type: 'condition',
      navKey: 'section:conditions',
      badgeRu: 'Условие',
      badgeEn: 'Condition',
      fallbackName: (r) => r.label || r.name || r['.name'],
    },
    {
      type: 'profile',
      navKey: 'profile',
      badgeRu: 'Профиль',
      badgeEn: 'Profile',
      fallbackName: (r) => r.name || r.label || r['.name'],
    },
    {
      type: 'schedule',
      navKey: 'schedule',
      badgeRu: 'Расписание',
      badgeEn: 'Schedule',
      fallbackName: (r) => r.name || r.label || r['.name'],
    },
  ];

  for (const spec of uciSpecs) {
    for (const rec of safeUciSections(spec.type)) {
      const id = String(rec?.['.name'] || '').trim();
      if (!id) continue;
      const rawName = String(spec.fallbackName(rec) || id).trim();
      const title = humanizeRuntimeTag(id, rawName, { context: ctx });
      const uciItemKey = `uci:${spec.type}:${id}`;
      if (seenIds.has(uciItemKey)) continue;
      seenIds.add(uciItemKey);
      items.push({
        id: uciItemKey,
        group: uciConfigGroup,
        title,
        subtitle: tr(`${spec.badgeRu}: ${title}`, `${spec.badgeEn}: ${title}`),
        badge: tr(spec.badgeRu, spec.badgeEn),
        keywords: `${id} ${rawName} ${title} ${spec.type}`,
        run: () => navigateTo(spec.navKey, deps),
      });
    }
  }

  // Color Themes (12 built-ins + custom themes)
  const themeGroup = tr('Цветовые темы оформления', 'Color Themes');
  const activeTheme = getActiveTheme();
  for (const th of getAllThemes()) {
    items.push({
      id: `theme:${th.id}`,
      group: themeGroup,
      title: `${tr('Тема:', 'Theme:')} ${th.name}`,
      subtitle: th.builtin
        ? tr('Встроенная тема интерфейса', 'Built-in interface theme')
        : tr('Пользовательская тема', 'Custom interface theme'),
      badge:
        th.id === activeTheme.id
          ? tr('Активна', 'Active')
          : tr('Применить', 'Apply'),
      keywords: `theme color ${th.name} ${th.id} тема`,
      run: () => setActiveTheme(th.id),
    });
  }

  if (!q) {
    return items.slice(0, 32);
  }
  return items
    .filter((it) =>
      `${it.title} ${it.subtitle} ${it.badge} ${it.group} ${it.keywords || ''}`
        .toLowerCase()
        .includes(q),
    )
    .slice(0, 40);
}

function renderPaletteList(): void {
  if (!overlayEl) return;
  const listEl = overlayEl.querySelector(
    '#tachyon-cmdk-list',
  ) as HTMLElement | null;
  if (!listEl) return;

  currentItems = buildCommandPaletteItems(currentQuery, activeDeps);
  if (selectedIdx >= currentItems.length) {
    selectedIdx = Math.max(0, currentItems.length - 1);
  }

  if (currentItems.length === 0) {
    listEl.replaceChildren(
      createEl('div', { class: 'tachyon-cmdk-empty' }, [
        tr('По запросу ничего не найдено', 'No matching items found'),
      ]),
    );
    return;
  }

  const children: HTMLElement[] = [];
  let lastGroup = '';
  currentItems.forEach((item, idx) => {
    if (item.group !== lastGroup) {
      lastGroup = item.group;
      children.push(
        createEl('div', { class: 'tachyon-cmdk-group' }, [item.group]),
      );
    }
    const isSel = idx === selectedIdx;
    children.push(
      createEl(
        'button',
        {
          type: 'button',
          class: `tachyon-cmdk-item${isSel ? ' is-selected' : ''}`,
          'data-cmdk-idx': String(idx),
          click: (ev: MouseEvent) => {
            ev.preventDefault();
            closeCommandPalette();
            item.run();
          },
        },
        [
          createEl('div', { class: 'tachyon-cmdk-item__main' }, [
            createEl('div', { class: 'tachyon-cmdk-item__title' }, [
              item.title,
            ]),
            createEl('div', { class: 'tachyon-cmdk-item__sub' }, [
              item.subtitle,
            ]),
          ]),
          createEl('span', { class: 'tachyon-cmdk-item__badge' }, [item.badge]),
        ],
      ),
    );
  });

  listEl.replaceChildren(...children);
}

export function closeCommandPalette(): void {
  isOpen = false;
  overlayEl?.remove?.();
  overlayEl = null;
}

export function openCommandPalette(deps?: CommandPaletteDeps): void {
  if (deps) activeDeps = deps;
  if (typeof document === 'undefined' || !document.body) return;

  isOpen = true;
  currentQuery = '';
  selectedIdx = 0;
  overlayEl?.remove?.();

  const input = createEl('input', {
    id: 'tachyon-cmdk-input',
    type: 'text',
    class: 'tachyon-cmdk-input',
    placeholder: tr(
      'Поиск разделов, узлов, настроек, тем или команд...',
      'Search tabs, nodes, settings, themes or actions...',
    ),
    input: () => {
      currentQuery = (input as HTMLInputElement).value || '';
      selectedIdx = 0;
      renderPaletteList();
    },
    keydown: (ev: KeyboardEvent) => {
      if (ev.key === 'ArrowDown') {
        ev.preventDefault();
        if (currentItems.length > 0) {
          selectedIdx = (selectedIdx + 1) % currentItems.length;
          renderPaletteList();
        }
      } else if (ev.key === 'ArrowUp') {
        ev.preventDefault();
        if (currentItems.length > 0) {
          selectedIdx =
            (selectedIdx - 1 + currentItems.length) % currentItems.length;
          renderPaletteList();
        }
      } else if (ev.key === 'Enter') {
        ev.preventDefault();
        const picked = currentItems[selectedIdx];
        if (picked) {
          closeCommandPalette();
          picked.run();
        }
      } else if (ev.key === 'Escape') {
        ev.preventDefault();
        closeCommandPalette();
      }
    },
  });

  const box = createEl('div', { class: 'tachyon-cmdk-box' }, [
    createEl('div', { class: 'tachyon-cmdk-input-wrap' }, [
      input,
      createEl('kbd', { class: 'tachyon-cmdk-kbd' }, ['Esc']),
    ]),
    createEl('div', { id: 'tachyon-cmdk-list', class: 'tachyon-cmdk-list' }),
    createEl('div', { class: 'tachyon-cmdk-ftr' }, [
      createEl('span', {}, [
        tr(
          'Стрелки — выбор · Enter — открыть · Esc — закрыть',
          'Arrows navigate · Enter execute · Esc close',
        ),
      ]),
      createEl('span', {}, ['Tachyon Command Palette']),
    ]),
  ]);

  overlayEl = createEl(
    'div',
    {
      id: 'tachyon-cmdk-overlay',
      class: 'tachyon-cmdk-overlay',
      click: (ev: MouseEvent) => {
        if (ev.target === overlayEl) {
          closeCommandPalette();
        }
      },
    },
    [box],
  );

  document.body.appendChild(overlayEl);
  renderPaletteList();
  setTimeout(() => {
    (input as HTMLInputElement).focus?.();
  }, 15);
}

export function initCommandPalette(deps: CommandPaletteDeps): void {
  activeDeps = deps;
  if (keydownBound || typeof document === 'undefined') return;
  if (typeof document.addEventListener !== 'function') return;
  keydownBound = true;

  document.addEventListener('keydown', (ev: KeyboardEvent) => {
    if (
      (ev.ctrlKey || ev.metaKey) &&
      (ev.key === 'k' || ev.key === 'K' || ev.code === 'KeyK')
    ) {
      ev.preventDefault();
      if (isOpen) {
        closeCommandPalette();
      } else {
        openCommandPalette(activeDeps);
      }
      return;
    }
    if (ev.key === 'Escape' && isOpen) {
      ev.preventDefault();
      closeCommandPalette();
    }
  });
}
