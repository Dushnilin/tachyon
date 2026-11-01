import { canUseDirectClashApi, getClashWsUrl, onMount } from '../../../helpers';
import { isActiveLuciTab } from '../../helpers/isActiveLuciTab';
import { showToast } from '../../../helpers/showToast';
import {
  renderPauseIcon24,
  renderPlayIcon24,
  renderSearchIcon24,
  renderXIcon24,
} from '../../../icons';
import { CustomTachyonMethods, TachyonShellMethods } from '../../methods';
import { getClashApiSecret } from '../../methods/custom/getClashApiSecret';
import { logger, socket, store, StoreType } from '../../services';
import {
  getCachedRuntimeUiState,
  refreshRuntimeUiState,
  subscribeRuntimeUiState,
} from '../../services/runtimeUiState.service';
import {
  getServiceAvailability,
  type ServiceAvailability,
} from '../../helpers/serviceAvailability';
import {
  type MonitoringTabId,
  type LocalDeviceChoices,
  type ClashConnectionsPayload,
  type MonitoredConnection,
  normalizeConnectionsPayload,
  buildRouteDisplayNames,
  getRouteDisplayNameByTag,
  getRouteSections,
  getRoute,
  getRouteTooltip,
  formatMatchedRuleSummary,
  getNetwork,
  getTargetCellParts,
  getSourceCellParts,
  getDeviceFilterLabel,
  getConnectionSourceIp,
  sortConnections,
  filterVisibleConnections,
  formatConnectionDuration,
  formatBytes,
} from './filters';
import { handleMonitoringValueCopy } from './clipboard';
import { normalizeString, parseStartedAt } from './formatters';
import { subscribeDashboardLayoutChanges } from '../dashboard/dashboardLayout';

interface MonitoringControllerDependencies {
  loadLocalDeviceChoices?: () => Promise<LocalDeviceChoices>;
}

const RENDER_INTERVAL_MS = 500;
const CONNECTIONS_RPC_POLL_INTERVAL_MS = 3000;
const CLOSED_CONNECTION_LIMIT = 300;
const ALL_FILTER_VALUE = 'all';

let dependencies: MonitoringControllerDependencies = {};
let monitoringMounted = false;
let monitoringMountId = 0;
let monitoringLifecycleRegistered = false;
let monitoringControllerInitialized = false;
let serviceStateUnsubscribe: (() => void) | null = null;
let layoutChangeUnsubscribe: (() => void) | null = null;
let renderTimer: ReturnType<typeof setInterval> | null = null;
let connectionsPollTimer: ReturnType<typeof setInterval> | null = null;
let connectionsSocketUrl = '';
// Unsubscribe by callback identity, never by URL: monitoring and dashboard
// both listen on the same /connections URL, and socket.disconnect(url) wiped
// the whole listener set for it - taking the dashboard's subscription with it.
// Holding the exact refs handed to socket.subscribe() lets the stop and error
// paths drop only this tab's handler; the manager closes the socket itself once
// the last listener for the URL is gone.
let connectionsSocketSubscription: {
  listener: Parameters<typeof socket.subscribe>[1];
  onError: Parameters<typeof socket.subscribe>[2];
} | null = null;

function unsubscribeConnectionsSocket() {
  if (connectionsSocketSubscription && connectionsSocketUrl) {
    socket.unsubscribe(
      connectionsSocketUrl,
      connectionsSocketSubscription.listener,
      connectionsSocketSubscription.onError,
    );
  }
  connectionsSocketSubscription = null;
}

// Same signature as socket.subscribe(), so the call site stays unchanged apart
// from the name: what matters is that the callbacks are remembered here.
function trackConnectionsSocketSubscription(
  url: string,
  listener: Parameters<typeof socket.subscribe>[1],
  onError: Parameters<typeof socket.subscribe>[2],
) {
  connectionsSocketSubscription = { listener, onError };
  socket.subscribe(url, listener, onError);
}
let directConnectionsSocketFailedAt = 0;
const DIRECT_SOCKET_COOLDOWN_MS = 60_000;

function canUseConnectionsSocket(): boolean {
  if (
    Date.now() - directConnectionsSocketFailedAt <
    DIRECT_SOCKET_COOLDOWN_MS
  ) {
    return false;
  }
  const activeEngine = store.get().activeEngine;
  if (activeEngine === 'steer' || activeEngine === 'steer-extended') {
    return false;
  }
  return canUseDirectClashApi();
}
let connectionsUpdatesId = 0;
let renderSkippedForSelection = false;
let pendingConnectionsPayload: ClashConnectionsPayload | null = null;
let pollingConnections = false;

let activeTab: MonitoringTabId = 'active';
const selectedDeviceFilters = new Set<string>();
const selectedRouteFilters = new Set<string>();
const selectedNetworkFilters = new Set<string>();
let openDropdownId: 'device' | 'route' | null = null;
let searchQuery = '';
let localDeviceChoices: LocalDeviceChoices = {};
let lastDeviceFilterSignature = '';
let lastRouteFilterSignature = '';
let lastQuickFilterSignature = '';
let loading = true;
let failed = false;
let closingAll = false;
let monitoringPaused = false;
let monitoringPausedAt: number | null = null;
let serviceAvailability: ServiceAvailability = 'loading';

const activeConnections = new Map<string, MonitoredConnection>();
const closedConnections = new Map<string, MonitoredConnection>();
const closingConnectionIds = new Set<string>();

function getRouteBadgeModifier(route: string): string {
  const routeLower = (route || '').toLowerCase();
  if (
    routeLower.includes('block') ||
    routeLower.includes('drop') ||
    routeLower.includes('reject')
  ) {
    return 'tachyon_monitoring-page__route--block';
  }
  if (
    routeLower.includes('dpi') ||
    routeLower.includes('zapret') ||
    routeLower.includes('byedpi') ||
    routeLower.includes('desync') ||
    routeLower.includes('wdtt') ||
    routeLower.includes('olcrtc')
  ) {
    return 'tachyon_monitoring-page__route--dpi';
  }
  if (
    routeLower.includes('direct') ||
    routeLower.includes('wan') ||
    routeLower.includes('bypass')
  ) {
    return 'tachyon_monitoring-page__route--direct';
  }
  if (
    routeLower.includes('proxy') ||
    routeLower.includes('vpn') ||
    routeLower.includes('vless') ||
    routeLower.includes('hysteria') ||
    routeLower.includes('tuic') ||
    routeLower.includes('shadowsocks') ||
    routeLower.includes('trojan') ||
    routeLower.includes('wireguard') ||
    routeLower.includes('warp')
  ) {
    return 'tachyon_monitoring-page__route--proxy';
  }
  return '';
}

function getLocalDeviceFilterLabel(ip: string): string {
  const allConnections = [
    ...Array.from(activeConnections.values()),
    ...Array.from(closedConnections.values()),
  ];
  return getDeviceFilterLabel(ip, allConnections, localDeviceChoices);
}

function getLocalSourceCellParts(connection: MonitoredConnection) {
  return getSourceCellParts(connection, [], localDeviceChoices);
}

function getCurrentTabConnections(): MonitoredConnection[] {
  return Array.from(
    (activeTab === 'active' ? activeConnections : closedConnections).values(),
  );
}

function getVisibleConnections(): MonitoredConnection[] {
  return filterVisibleConnections({
    deviceFilters: selectedDeviceFilters,
    routeFilters: selectedRouteFilters,
    networkFilters: selectedNetworkFilters,
    searchQuery,
    tab: activeTab,
    activeConnections: Array.from(activeConnections.values()),
    closedConnections: Array.from(closedConnections.values()),
    localDeviceChoices,
    allFilterValue: ALL_FILTER_VALUE,
    pausedAt: monitoringPausedAt,
  });
}

function moveConnectionToClosed(connection: MonitoredConnection, now: number) {
  closedConnections.set(connection.id, {
    ...connection,
    closedAt: now,
    lastSeenAt: now,
  });
}

function trimClosedConnections() {
  const sorted = sortConnections(
    Array.from(closedConnections.values()),
    'closed',
  );

  sorted.slice(CLOSED_CONNECTION_LIMIT).forEach((connection) => {
    closedConnections.delete(connection.id);
  });
}

function applyConnectionsPayload(payload: ClashConnectionsPayload) {
  if (monitoringPaused) {
    pendingConnectionsPayload = payload;
    return;
  }

  const mountId = monitoringMountId;
  const now = Date.now();
  const incomingIds = new Set<string>();
  const rawConnections = Array.isArray(payload.connections)
    ? payload.connections
    : [];

  rawConnections.forEach((rawConnection) => {
    const id = normalizeString(rawConnection.id);
    if (!id) {
      return;
    }

    incomingIds.add(id);
    closedConnections.delete(id);
    const prev = activeConnections.get(id);
    const startedAtMs =
      prev && prev.start === rawConnection.start && prev.startedAtMs != null
        ? prev.startedAtMs
        : parseStartedAt({ start: rawConnection.start, lastSeenAt: now });
    activeConnections.set(id, {
      ...rawConnection,
      id,
      lastSeenAt: now,
      startedAtMs,
    });
  });

  Array.from(activeConnections.entries()).forEach(([id, connection]) => {
    if (!incomingIds.has(id)) {
      activeConnections.delete(id);
      moveConnectionToClosed(connection, now);
    }
  });

  trimClosedConnections();
  loading = false;
  failed = false;

  if (monitoringMounted && mountId === monitoringMountId) {
    renderControls();
    renderConnections();
  }
}

function setTab(tab: MonitoringTabId) {
  if (activeTab === tab) {
    return;
  }

  activeTab = tab;
  renderControls();
  renderConnections();
}

function getKnownSourceIps(): string[] {
  const ips = new Set<string>();

  activeConnections.forEach((connection) => {
    const ip = getConnectionSourceIp(connection);
    if (ip) {
      ips.add(ip);
    }
  });

  closedConnections.forEach((connection) => {
    const ip = getConnectionSourceIp(connection);
    if (ip) {
      ips.add(ip);
    }
  });

  const labelsByIp = new Map<string, string>();
  ips.forEach((ip) => {
    labelsByIp.set(ip, getLocalDeviceFilterLabel(ip));
  });

  return Array.from(ips).sort((a, b) => {
    const byLabel = (labelsByIp.get(a) || a).localeCompare(
      labelsByIp.get(b) || b,
    );
    return byLabel || a.localeCompare(b);
  });
}

function getAvailableRoutes(): string[] {
  const uniqueRoutes = new Set<string>();

  getRouteSections().forEach(({ displayName }) => {
    if (displayName) uniqueRoutes.add(displayName);
  });

  activeConnections.forEach((connection) => {
    const route = getRoute(connection);
    if (route && route !== '-') uniqueRoutes.add(route);
  });

  closedConnections.forEach((connection) => {
    const route = getRoute(connection);
    if (route && route !== '-') uniqueRoutes.add(route);
  });

  return Array.from(uniqueRoutes)
    .filter((name) => {
      const lower = name.toLowerCase().trim();
      return lower !== '' && lower !== '-' && !lower.includes('failover');
    })
    .sort((a, b) => a.localeCompare(b));
}

function getRouteConnectionCounts(): Map<string, number> {
  const counts = new Map<string, number>();
  getCurrentTabConnections().forEach((connection) => {
    const route = getRoute(connection);
    if (route && route !== '-') {
      counts.set(route, (counts.get(route) || 0) + 1);
    }
  });
  return counts;
}

function getDeviceConnectionCounts(): Map<string, number> {
  const counts = new Map<string, number>();
  getCurrentTabConnections().forEach((connection) => {
    const ip = getConnectionSourceIp(connection);
    if (ip) {
      counts.set(ip, (counts.get(ip) || 0) + 1);
    }
  });
  return counts;
}

function getNetworkConnectionCounts(): Map<string, number> {
  const counts = new Map<string, number>();
  getCurrentTabConnections().forEach((connection) => {
    const net = (getNetwork(connection) || '').toLowerCase();
    if (net) {
      counts.set(net, (counts.get(net) || 0) + 1);
    }
  });
  return counts;
}

function setDropdownOpen(target: 'device' | 'route' | null) {
  openDropdownId = target;

  const deviceWrap = document.getElementById('monitoring-device-filter-wrap');
  const deviceTrigger = document.getElementById(
    'monitoring-device-filter-trigger',
  );
  const deviceMenu = document.getElementById('monitoring-device-filter-menu');

  const routeWrap = document.getElementById('monitoring-route-filter-wrap');
  const routeTrigger = document.getElementById(
    'monitoring-route-filter-trigger',
  );
  const routeMenu = document.getElementById('monitoring-route-filter-menu');

  const isDeviceOpen = target === 'device';
  const isRouteOpen = target === 'route';

  if (deviceWrap) {
    deviceWrap.classList.toggle(
      'tachyon_monitoring-page__multiselect--open',
      isDeviceOpen,
    );
  }
  if (deviceTrigger) {
    deviceTrigger.setAttribute('aria-expanded', String(isDeviceOpen));
  }
  if (deviceMenu) {
    deviceMenu.hidden = !isDeviceOpen;
  }

  if (routeWrap) {
    routeWrap.classList.toggle(
      'tachyon_monitoring-page__multiselect--open',
      isRouteOpen,
    );
  }
  if (routeTrigger) {
    routeTrigger.setAttribute('aria-expanded', String(isRouteOpen));
  }
  if (routeMenu) {
    routeMenu.hidden = !isRouteOpen;
  }
}

function updateFilterCountsInContainer(
  container: HTMLElement,
  counts: Map<string, number>,
) {
  container
    .querySelectorAll<HTMLElement>('[data-filter-count]')
    .forEach((badge) => {
      const key = badge.getAttribute('data-filter-count') || '';
      const count = counts.get(key) || 0;
      const nextText = String(count);
      if (badge.textContent !== nextText) {
        badge.textContent = nextText;
      }
    });
}

function renderRouteFilterOptions() {
  const menu = document.getElementById('monitoring-route-filter-menu');
  const labelEl = document.getElementById('monitoring-route-filter-label');
  const trigger = document.getElementById(
    'monitoring-route-filter-trigger',
  ) as HTMLButtonElement | null;
  if (!menu || !labelEl) return;

  const routes = getAvailableRoutes();
  const routeCounts = getRouteConnectionCounts();

  Array.from(selectedRouteFilters).forEach((selected) => {
    if (!routes.includes(selected)) {
      selectedRouteFilters.delete(selected);
    }
  });

  if (selectedRouteFilters.size === 0) {
    labelEl.textContent = _('All Routes');
  } else if (selectedRouteFilters.size === 1) {
    labelEl.textContent = Array.from(selectedRouteFilters)[0];
  } else {
    labelEl.textContent = `${_('Routes')}: ${selectedRouteFilters.size}`;
  }

  if (trigger) {
    trigger.classList.toggle(
      'tachyon_monitoring-page__multiselect-trigger--active',
      selectedRouteFilters.size > 0,
    );
    trigger.disabled = serviceAvailability === 'stopped';
  }

  const signature = [
    Array.from(selectedRouteFilters).sort().join(','),
    ...routes,
  ].join('|');

  if (signature === lastRouteFilterSignature) {
    updateFilterCountsInContainer(menu, routeCounts);
    return;
  }

  lastRouteFilterSignature = signature;

  const allChecked = selectedRouteFilters.size === 0;
  const header = E('div', { class: 'tachyon_monitoring-page__menu-header' }, [
    E('label', { class: 'tachyon_monitoring-page__check-all' }, [
      E('input', {
        type: 'checkbox',
        class: 'tachyon_monitoring-page__checkbox',
        ...(allChecked ? { checked: true } : {}),
        onchange: () => {
          selectedRouteFilters.clear();
          lastRouteFilterSignature = '';
          lastQuickFilterSignature = '';
          renderControls();
          renderConnections();
        },
      }),
      E('span', {}, _('All Routes')),
    ]),
    ...(selectedRouteFilters.size > 0
      ? [
          E(
            'button',
            {
              type: 'button',
              class: 'tachyon_monitoring-page__menu-reset',
              onclick: (e: MouseEvent) => {
                e.stopPropagation();
                selectedRouteFilters.clear();
                lastRouteFilterSignature = '';
                lastQuickFilterSignature = '';
                renderControls();
                renderConnections();
              },
            },
            _('Reset'),
          ),
        ]
      : []),
  ]);

  const items =
    routes.length > 0
      ? routes.map((routeName) => {
          const isChecked = selectedRouteFilters.has(routeName);
          const count = routeCounts.get(routeName) || 0;
          const badgeModifier = getRouteBadgeModifier(routeName);
          const badgeClass = ['tachyon_monitoring-page__route', badgeModifier]
            .filter(Boolean)
            .join(' ');
          const countBadge = E(
            'span',
            { class: 'tachyon_monitoring-page__check-count' },
            String(count),
          );
          countBadge.setAttribute('data-filter-count', routeName);

          return E(
            'label',
            {
              class: `tachyon_monitoring-page__check-item${
                isChecked ? ' tachyon_monitoring-page__check-item--checked' : ''
              }`,
            },
            [
              E('input', {
                type: 'checkbox',
                class: 'tachyon_monitoring-page__checkbox',
                value: routeName,
                ...(isChecked ? { checked: true } : {}),
                onchange: (e: Event) => {
                  const target = e.target as HTMLInputElement;
                  if (target.checked) {
                    selectedRouteFilters.add(routeName);
                  } else {
                    selectedRouteFilters.delete(routeName);
                  }
                  lastRouteFilterSignature = '';
                  lastQuickFilterSignature = '';
                  renderControls();
                  renderConnections();
                },
              }),
              E(
                'span',
                { class: 'tachyon_monitoring-page__check-label' },
                E('span', { class: badgeClass }, routeName),
              ),
              countBadge,
            ],
          );
        })
      : [
          E(
            'div',
            { class: 'tachyon_monitoring-page__menu-empty' },
            _('No routes'),
          ),
        ];

  menu.replaceChildren(
    header,
    E('div', { class: 'tachyon_monitoring-page__menu-list' }, items),
  );
}

function renderDeviceFilterOptions() {
  const menu = document.getElementById('monitoring-device-filter-menu');
  const labelEl = document.getElementById('monitoring-device-filter-label');
  const trigger = document.getElementById(
    'monitoring-device-filter-trigger',
  ) as HTMLButtonElement | null;

  if (!menu || !labelEl) {
    return;
  }

  const sourceIps = getKnownSourceIps();
  const deviceCounts = getDeviceConnectionCounts();

  Array.from(selectedDeviceFilters).forEach((selected) => {
    if (!sourceIps.includes(selected)) {
      selectedDeviceFilters.delete(selected);
    }
  });

  if (selectedDeviceFilters.size === 0) {
    labelEl.textContent = _('All sources');
  } else if (selectedDeviceFilters.size === 1) {
    const onlyIp = Array.from(selectedDeviceFilters)[0];
    labelEl.textContent = getLocalDeviceFilterLabel(onlyIp);
  } else {
    labelEl.textContent = `${_('Source')}: ${selectedDeviceFilters.size}`;
  }

  if (trigger) {
    trigger.classList.toggle(
      'tachyon_monitoring-page__multiselect-trigger--active',
      selectedDeviceFilters.size > 0,
    );
    trigger.disabled = serviceAvailability === 'stopped';
  }

  const signature = [
    Array.from(selectedDeviceFilters).sort().join(','),
    ...sourceIps.map((ip) => `${ip}:${getLocalDeviceFilterLabel(ip)}`),
  ].join('|');

  if (signature === lastDeviceFilterSignature) {
    updateFilterCountsInContainer(menu, deviceCounts);
    return;
  }

  lastDeviceFilterSignature = signature;

  const allChecked = selectedDeviceFilters.size === 0;
  const header = E('div', { class: 'tachyon_monitoring-page__menu-header' }, [
    E('label', { class: 'tachyon_monitoring-page__check-all' }, [
      E('input', {
        type: 'checkbox',
        class: 'tachyon_monitoring-page__checkbox',
        ...(allChecked ? { checked: true } : {}),
        onchange: () => {
          selectedDeviceFilters.clear();
          lastDeviceFilterSignature = '';
          lastQuickFilterSignature = '';
          renderControls();
          renderConnections();
        },
      }),
      E('span', {}, _('All sources')),
    ]),
    ...(selectedDeviceFilters.size > 0
      ? [
          E(
            'button',
            {
              type: 'button',
              class: 'tachyon_monitoring-page__menu-reset',
              onclick: (e: MouseEvent) => {
                e.stopPropagation();
                selectedDeviceFilters.clear();
                lastDeviceFilterSignature = '';
                lastQuickFilterSignature = '';
                renderControls();
                renderConnections();
              },
            },
            _('Reset'),
          ),
        ]
      : []),
  ]);

  const items =
    sourceIps.length > 0
      ? sourceIps.map((ip) => {
          const isChecked = selectedDeviceFilters.has(ip);
          const count = deviceCounts.get(ip) || 0;
          const label = getLocalDeviceFilterLabel(ip);
          const countBadge = E(
            'span',
            { class: 'tachyon_monitoring-page__check-count' },
            String(count),
          );
          countBadge.setAttribute('data-filter-count', ip);

          return E(
            'label',
            {
              class: `tachyon_monitoring-page__check-item${
                isChecked ? ' tachyon_monitoring-page__check-item--checked' : ''
              }`,
            },
            [
              E('input', {
                type: 'checkbox',
                class: 'tachyon_monitoring-page__checkbox',
                value: ip,
                ...(isChecked ? { checked: true } : {}),
                onchange: (e: Event) => {
                  const target = e.target as HTMLInputElement;
                  if (target.checked) {
                    selectedDeviceFilters.add(ip);
                  } else {
                    selectedDeviceFilters.delete(ip);
                  }
                  lastDeviceFilterSignature = '';
                  lastQuickFilterSignature = '';
                  renderControls();
                  renderConnections();
                },
              }),
              E(
                'span',
                {
                  class: 'tachyon_monitoring-page__check-label',
                  title: label,
                },
                label,
              ),
              countBadge,
            ],
          );
        })
      : [
          E(
            'div',
            { class: 'tachyon_monitoring-page__menu-empty' },
            _('No active connections'),
          ),
        ];

  menu.replaceChildren(
    header,
    E('div', { class: 'tachyon_monitoring-page__menu-list' }, items),
  );
}

function renderNetworkFilterControls() {
  const group = document.getElementById('monitoring-network-filters');
  if (!group) return;

  const netCounts = getNetworkConnectionCounts();
  const isStopped = serviceAvailability === 'stopped';

  group
    .querySelectorAll<HTMLLabelElement>('.tachyon_monitoring-page__proto-chip')
    .forEach((chip) => {
      const input = chip.querySelector<HTMLInputElement>(
        'input[type="checkbox"]',
      );
      const proto = (input?.value || '').toLowerCase();
      const isChecked = selectedNetworkFilters.has(proto);
      chip.classList.toggle(
        'tachyon_monitoring-page__proto-chip--checked',
        isChecked,
      );
      if (input) {
        input.checked = isChecked;
        input.disabled = isStopped;
      }
      const count = netCounts.get(proto) || 0;
      let countEl = chip.querySelector<HTMLElement>(
        '.tachyon_monitoring-page__proto-count',
      );
      if (!countEl) {
        countEl = E(
          'span',
          { class: 'tachyon_monitoring-page__proto-count' },
          String(count),
        );
        chip.appendChild(countEl);
      } else if (countEl.textContent !== String(count)) {
        countEl.textContent = String(count);
      }
    });
}

function hasAnyActiveFilter(): boolean {
  return (
    selectedDeviceFilters.size > 0 ||
    selectedRouteFilters.size > 0 ||
    selectedNetworkFilters.size > 0 ||
    searchQuery.trim().length > 0
  );
}

function clearAllFilters() {
  selectedDeviceFilters.clear();
  selectedRouteFilters.clear();
  selectedNetworkFilters.clear();
  searchQuery = '';
  lastDeviceFilterSignature = '';
  lastRouteFilterSignature = '';
  lastQuickFilterSignature = '';

  const searchInput = document.getElementById(
    'monitoring-search',
  ) as HTMLInputElement | null;
  if (searchInput) {
    searchInput.value = '';
  }

  renderControls();
  renderConnections();
}

function renderQuickFiltersBar() {
  const bar = document.getElementById('monitoring-quick-filters');
  if (!bar) return;

  if (serviceAvailability === 'stopped') {
    bar.hidden = true;
    return;
  }

  const routes = getAvailableRoutes();
  const routeCounts = getRouteConnectionCounts();
  const anyActive = hasAnyActiveFilter();

  if (routes.length === 0 && !anyActive) {
    bar.hidden = true;
    return;
  }

  bar.hidden = false;

  const signature = [
    Array.from(selectedRouteFilters).sort().join(','),
    Array.from(selectedDeviceFilters).sort().join(','),
    Array.from(selectedNetworkFilters).sort().join(','),
    searchQuery.trim() ? 'search:1' : 'search:0',
    ...routes,
  ].join('|');

  if (signature === lastQuickFilterSignature) {
    updateFilterCountsInContainer(bar, routeCounts);
    return;
  }

  lastQuickFilterSignature = signature;

  const routeChips = routes.map((routeName) => {
    const isChecked = selectedRouteFilters.has(routeName);
    const count = routeCounts.get(routeName) || 0;
    const badgeModifier = getRouteBadgeModifier(routeName);
    const chipClasses = [
      'tachyon_monitoring-page__quick-chip',
      badgeModifier,
      isChecked ? 'tachyon_monitoring-page__quick-chip--checked' : '',
    ]
      .filter(Boolean)
      .join(' ');

    const countBadge = E(
      'span',
      { class: 'tachyon_monitoring-page__quick-chip-count' },
      String(count),
    );
    countBadge.setAttribute('data-filter-count', routeName);

    return E('label', { class: chipClasses, title: routeName }, [
      E('input', {
        type: 'checkbox',
        class: 'tachyon_monitoring-page__quick-chip-input',
        value: routeName,
        ...(isChecked ? { checked: true } : {}),
        onchange: (e: Event) => {
          const target = e.target as HTMLInputElement;
          if (target.checked) {
            selectedRouteFilters.add(routeName);
          } else {
            selectedRouteFilters.delete(routeName);
          }
          lastRouteFilterSignature = '';
          lastQuickFilterSignature = '';
          renderControls();
          renderConnections();
        },
      }),
      E(
        'span',
        { class: 'tachyon_monitoring-page__quick-chip-box' },
        isChecked ? '✓' : '',
      ),
      E(
        'span',
        { class: 'tachyon_monitoring-page__quick-chip-label' },
        routeName,
      ),
      countBadge,
    ]);
  });

  const devicePills = Array.from(selectedDeviceFilters).map((ip) => {
    const label = getLocalDeviceFilterLabel(ip);
    return E(
      'button',
      {
        type: 'button',
        class:
          'tachyon_monitoring-page__active-tag tachyon_monitoring-page__active-tag--device',
        title: label,
        onclick: () => {
          selectedDeviceFilters.delete(ip);
          lastDeviceFilterSignature = '';
          lastQuickFilterSignature = '';
          renderControls();
          renderConnections();
        },
      },
      [
        E('span', {}, label),
        E(
          'span',
          { class: 'tachyon_monitoring-page__active-tag-close' },
          '\u00d7',
        ),
      ],
    );
  });

  const children: HTMLElement[] = [];

  if (routeChips.length > 0) {
    children.push(
      E('div', { class: 'tachyon_monitoring-page__quick-group' }, [
        E(
          'span',
          { class: 'tachyon_monitoring-page__quick-title' },
          `${_('Route')}:`,
        ),
        ...routeChips,
      ]),
    );
  }

  if (devicePills.length > 0) {
    children.push(
      E('div', { class: 'tachyon_monitoring-page__quick-group' }, [
        E(
          'span',
          { class: 'tachyon_monitoring-page__quick-title' },
          `${_('Source')}:`,
        ),
        ...devicePills,
      ]),
    );
  }

  if (anyActive) {
    children.push(
      E(
        'button',
        {
          id: 'monitoring-reset-filters',
          type: 'button',
          class: 'btn cbi-button tachyon_monitoring-page__reset-btn',
          onclick: () => clearAllFilters(),
        },
        `✕ ${_('Reset filters')}`,
      ),
    );
  }

  bar.replaceChildren(...children);
}

function setButtonActive(button: HTMLElement | null, active: boolean) {
  if (!button) {
    return;
  }

  button.classList.toggle('tachyon_monitoring-page__tab--active', active);
}

function renderTabButtonContent(label: string, count: number) {
  return [
    E('span', { class: 'tachyon_monitoring-page__tab-label' }, label),
    E('span', { class: 'tachyon_monitoring-page__tab-badge' }, String(count)),
  ];
}

function renderControls() {
  const activeButton = document.getElementById(
    'monitoring-tab-active',
  ) as HTMLButtonElement | null;
  const closedButton = document.getElementById(
    'monitoring-tab-closed',
  ) as HTMLButtonElement | null;
  const closeAllButton = document.getElementById(
    'monitoring-close-all',
  ) as HTMLButtonElement | null;
  const pauseToggleButton = document.getElementById(
    'monitoring-pause-toggle',
  ) as HTMLButtonElement | null;

  if (activeButton) {
    activeButton.replaceChildren(
      ...renderTabButtonContent(_('Active'), activeConnections.size),
    );
    activeButton.disabled = serviceAvailability === 'stopped';
  }

  if (closedButton) {
    closedButton.replaceChildren(
      ...renderTabButtonContent(_('Closed'), closedConnections.size),
    );
    closedButton.disabled = serviceAvailability === 'stopped';
  }

  setButtonActive(activeButton, activeTab === 'active');
  setButtonActive(closedButton, activeTab === 'closed');

  if (closeAllButton) {
    closeAllButton.replaceChildren(renderXIcon24());
    closeAllButton.disabled =
      serviceAvailability === 'stopped' ||
      activeConnections.size === 0 ||
      closingAll;
  }

  if (pauseToggleButton) {
    const title = monitoringPaused ? _('Resume updates') : _('Pause updates');
    pauseToggleButton.replaceChildren(
      monitoringPaused ? renderPlayIcon24() : renderPauseIcon24(),
    );
    pauseToggleButton.title = title;
    pauseToggleButton.setAttribute('aria-label', title);
    pauseToggleButton.disabled = serviceAvailability === 'stopped';
    pauseToggleButton.classList.toggle(
      'tachyon_monitoring-page__icon-button--active',
      monitoringPaused,
    );
  }

  const searchIcon = document.querySelector(
    '.tachyon_monitoring-page__search-icon',
  );
  if (searchIcon && searchIcon.childNodes.length === 0) {
    searchIcon.replaceChildren(renderSearchIcon24());
  }

  renderDeviceFilterOptions();
  renderRouteFilterOptions();
  renderNetworkFilterControls();
  renderQuickFiltersBar();

  const searchInput = document.getElementById(
    'monitoring-search',
  ) as HTMLInputElement | null;

  if (searchInput) {
    searchInput.disabled = serviceAvailability === 'stopped';
  }
}

function renderValue(value: string, className = '', customTitle?: string) {
  const text = value || '-';
  const tooltipText = customTitle || text;
  const element = E(
    'span',
    {
      class: ['tachyon_monitoring-page__value', className]
        .filter(Boolean)
        .join(' '),
      title: tooltipText,
    },
    text,
  );

  element.setAttribute('data-copy-value', text);
  if (customTitle && customTitle !== text) {
    element.setAttribute('data-rule-tooltip', customTitle);
  }

  return element;
}

function renderSourceValue(source: ReturnType<typeof getSourceCellParts>) {
  const fullText = source.copyValue || source.primary || '-';

  if (!source.ip) {
    const element = E(
      'span',
      {
        class:
          'tachyon_monitoring-page__value tachyon_monitoring-page__source-value tachyon_monitoring-page__source-value--ip-only',
        title: fullText,
      },
      source.primary || '-',
    );

    element.setAttribute('data-copy-value', fullText);

    return element;
  }

  const element = E(
    'span',
    {
      class:
        'tachyon_monitoring-page__value tachyon_monitoring-page__source-value',
      title: fullText,
    },
    [
      E(
        'span',
        { class: 'tachyon_monitoring-page__source-name' },
        source.primary,
      ),
      E('span', { class: 'tachyon_monitoring-page__source-ip' }, source.ip),
    ],
  );

  element.setAttribute('data-copy-value', fullText);

  return element;
}

function renderTableCell(label: string, children: (Node | string)[]) {
  const cell = E('td', {}, children);
  cell.setAttribute('data-label', label);
  return cell;
}

function renderConnectionRow(connection: MonitoredConnection) {
  const target = getTargetCellParts(connection);
  const source = getLocalSourceCellParts(connection);
  const isClosing = closingConnectionIds.has(connection.id);
  const closeButton =
    activeTab === 'active'
      ? E(
          'button',
          {
            class: 'btn cbi-button tachyon_monitoring-page__row-action',
            title: _('Close connection'),
            'aria-label': _('Close connection'),
            type: 'button',
            value: connection.id,
            ...(isClosing ? { disabled: true } : {}),
          },
          [renderXIcon24()],
        )
      : E('span', {}, '-');

  const network = getNetwork(connection);
  const networkLower = (network || '').toLowerCase();
  const networkClass =
    networkLower === 'tcp'
      ? 'tachyon_monitoring-page__network tachyon_monitoring-page__network--tcp'
      : networkLower === 'quic'
        ? 'tachyon_monitoring-page__network tachyon_monitoring-page__network--quic'
        : networkLower === 'udp'
          ? 'tachyon_monitoring-page__network tachyon_monitoring-page__network--udp'
          : 'tachyon_monitoring-page__network';

  const route = getRoute(connection);
  const routeModifier = getRouteBadgeModifier(route);
  const routeClass = ['tachyon_monitoring-page__route', routeModifier]
    .filter(Boolean)
    .join(' ');
  const routeTooltip = getRouteTooltip(connection, route);

  const networkBadge = renderValue(network, networkClass);
  if (networkLower) {
    networkBadge.setAttribute('data-filter-network', networkLower);
  }
  const routeBadge = renderValue(route, routeClass, routeTooltip);
  if (route && route !== '-') {
    routeBadge.setAttribute('data-filter-route', route);
  }

  const row = E(
    'tr',
    {
      class: isClosing ? 'tachyon_monitoring-page__row--closing' : '',
    },
    [
      renderTableCell(_('Host'), [renderValue(target.primary)]),
      renderTableCell(_('Type'), [networkBadge]),
      renderTableCell(_('Route'), [routeBadge]),
      renderTableCell(_('Time'), [
        renderValue(formatConnectionDuration(connection)),
      ]),
      renderTableCell(_('Downloaded'), [
        renderValue(formatBytes(connection.download)),
      ]),
      renderTableCell(_('Uploaded'), [
        renderValue(formatBytes(connection.upload)),
      ]),
      renderTableCell(_('Source'), [renderSourceValue(source)]),
      renderTableCell(_('Close'), [closeButton]),
    ],
  );

  row.setAttribute('data-connection-id', connection.id);
  row.setAttribute('data-row-signature', getConnectionRowSignature(connection));

  return row;
}

function renderStateRow(text: string, className = '') {
  return E('tr', { class: 'tachyon_monitoring-page__state-row' }, [
    E(
      'td',
      {
        class: 'tachyon_monitoring-page__state-cell',
        colSpan: 8,
      },
      [
        E(
          'div',
          {
            class: ['tachyon_monitoring-page__state', className]
              .filter(Boolean)
              .join(' '),
          },
          text,
        ),
      ],
    ),
  ]);
}

function renderConnectionsTable(
  connections: MonitoredConnection[],
  state?: { text: string; className?: string },
) {
  const rows = state
    ? [renderStateRow(state.text, state.className)]
    : connections.map(renderConnectionRow);

  return E('div', { class: 'tachyon_monitoring-page__table-wrap' }, [
    E(
      'table',
      { class: 'table cbi-section-table tachyon_monitoring-page__table' },
      [
        E('thead', {}, [
          E('tr', {}, [
            E('th', {}, _('Host')),
            E('th', {}, _('Type')),
            E('th', {}, _('Route')),
            E('th', {}, _('Time')),
            E('th', {}, `\u2193 ${_('Downloaded')}`),
            E('th', {}, `\u2191 ${_('Uploaded')}`),
            E('th', {}, _('Source')),
            E('th', {}, _('Close')),
          ]),
        ]),
        E('tbody', {}, rows),
      ],
    ),
  ]);
}

function isNodeInsideMonitoring(node: Node | null): boolean {
  const root = document.getElementById('monitoring-status');
  return Boolean(root && node && root.contains(node));
}

function isTextSelectionInsideMonitoring(): boolean {
  const selection = window.getSelection?.();
  if (!selection || selection.isCollapsed) {
    return false;
  }

  return (
    isNodeInsideMonitoring(selection.anchorNode) ||
    isNodeInsideMonitoring(selection.focusNode)
  );
}

function renderConnections(options: { force?: boolean } = {}) {
  const container = document.getElementById('monitoring-connections');
  if (!container) {
    return;
  }

  if (!options.force && isTextSelectionInsideMonitoring()) {
    renderSkippedForSelection = true;
    return;
  }

  renderSkippedForSelection = false;
  const previousScrollLeft = container.scrollLeft;

  if (serviceAvailability === 'stopped') {
    container.replaceChildren(
      renderConnectionsTable([], {
        text: _(
          'Tachyon service is stopped. Start the service to display connections.',
        ),
      }),
    );
    return;
  }

  if (loading) {
    container.replaceChildren(
      renderConnectionsTable([], {
        text: _('Loading connections'),
        className: 'tachyon_monitoring-page__state--loading',
      }),
    );
    return;
  }

  if (failed) {
    container.replaceChildren(
      renderConnectionsTable([], {
        text: _('Connections are unavailable'),
        className: 'tachyon_monitoring-page__state--error',
      }),
    );
    return;
  }

  const visibleConnections = getVisibleConnections();

  if (visibleConnections.length === 0) {
    container.replaceChildren(
      renderConnectionsTable([], {
        text:
          activeTab === 'active'
            ? _('No active connections')
            : _('No closed connections'),
      }),
    );
    return;
  }

  patchConnectionRows(visibleConnections);
  container.scrollLeft = previousScrollLeft;
}

// Structural parts of a row: when only duration/bytes change the row is
// patched in place instead of being rebuilt, which keeps text selection and
// avoids re-creating hundreds of nodes on every render tick.
function getConnectionRowSignature(connection: MonitoredConnection): string {
  const target = getTargetCellParts(connection);
  const source = getLocalSourceCellParts(connection);

  return [
    target.primary,
    getNetwork(connection),
    getRoute(connection),
    formatMatchedRuleSummary(connection),
    source.primary,
    source.ip,
    closingConnectionIds.has(connection.id) ? 'closing' : 'open',
  ].join('|');
}

function patchConnectionRows(visibleConnections: MonitoredConnection[]) {
  const currentTbody = container_queryConnectionsTbody();
  // A tbody showing a state message ("loading", "stopped", ...) contains no
  // keyed rows - replace the whole table shell instead of patching into it.
  const hasKeyedRows =
    currentTbody &&
    currentTbody.querySelector('tr[data-connection-id]') != null;

  if (!currentTbody || !hasKeyedRows) {
    document
      .getElementById('monitoring-connections')
      ?.replaceChildren(renderConnectionsTable(visibleConnections));
    return;
  }

  const tbody: HTMLElement = currentTbody;

  const existingRows = new Map<string, HTMLTableRowElement>();
  for (const row of Array.from(tbody.children) as HTMLTableRowElement[]) {
    const id = row.getAttribute('data-connection-id');
    if (id) {
      existingRows.set(id, row);
    }
  }

  const visibleIds = new Set<string>(visibleConnections.map((c) => c.id));
  for (const [id, row] of existingRows) {
    if (!visibleIds.has(id)) {
      row.remove();
      existingRows.delete(id);
    }
  }

  for (let i = 0; i < visibleConnections.length; i++) {
    const connection = visibleConnections[i];
    const signature = getConnectionRowSignature(connection);
    const existing = existingRows.get(connection.id);

    if (!existing) {
      const newRow = renderConnectionRow(connection);
      const refNode = tbody.children[i] || null;
      tbody.insertBefore(newRow, refNode);
      continue;
    }

    if (existing.getAttribute('data-row-signature') !== signature) {
      const replacement = renderConnectionRow(connection);
      tbody.replaceChild(replacement, existing);
      if (tbody.children[i] !== replacement) {
        tbody.insertBefore(replacement, tbody.children[i] || null);
      }
      continue;
    }

    // Patch volatile cells in place: Time, Downloaded, Uploaded.
    if (activeTab === 'active') {
      patchVolatileCells(existing, connection);
    }
    if (tbody.children[i] !== existing) {
      tbody.insertBefore(existing, tbody.children[i] || null);
    }
  }
}

function container_queryConnectionsTbody(): HTMLElement | null {
  return (
    document.getElementById('monitoring-connections')?.querySelector('tbody') ??
    null
  );
}

function patchVolatileCells(
  row: HTMLTableRowElement,
  connection: MonitoredConnection,
) {
  const cells = row.children;
  if (cells.length < 7) {
    return;
  }

  const volatileValues: Array<[number, string, string]> = [
    [3, _('Time'), formatConnectionDuration(connection)],
    [4, _('Downloaded'), formatBytes(connection.download)],
    [5, _('Uploaded'), formatBytes(connection.upload)],
  ];

  for (const [index, label, rawValue] of volatileValues) {
    const current = cells[index];
    const text = rawValue || '-';
    const span = current?.firstElementChild as HTMLElement | null;
    if (span && span.classList.contains('tachyon_monitoring-page__value')) {
      if (span.textContent !== text) {
        span.textContent = text;
        span.title = text;
        span.setAttribute('data-copy-value', text);
      }
    } else if (current) {
      row.replaceChild(renderTableCell(label, [renderValue(text)]), current);
    } else {
      row.appendChild(renderTableCell(label, [renderValue(text)]));
    }
  }
}

function flushRenderAfterSelection() {
  if (!renderSkippedForSelection || isTextSelectionInsideMonitoring()) {
    return;
  }

  renderConnections({ force: true });
}

function setMonitoringPaused(paused: boolean) {
  if (monitoringPaused === paused) {
    return;
  }

  monitoringPaused = paused;
  monitoringPausedAt = paused ? Date.now() : null;
  renderSkippedForSelection = false;
  renderControls();

  if (!paused) {
    const payload = pendingConnectionsPayload;
    pendingConnectionsPayload = null;

    if (payload) {
      applyConnectionsPayload(payload);
      return;
    }

    if (connectionsPollTimer) {
      void pollConnectionsSnapshot();
      return;
    }
  }

  renderConnections();
}

async function closeConnection(connectionId: string) {
  if (!connectionId || closingConnectionIds.has(connectionId)) {
    return;
  }

  closingConnectionIds.add(connectionId);
  renderConnections();

  try {
    const response =
      await TachyonShellMethods.closeClashApiConnection(connectionId);

    if (!response.success) {
      showToast(_('Failed to close connection'), 'error');
      return;
    }

    const now = Date.now();
    const connection = activeConnections.get(connectionId);
    if (connection) {
      activeConnections.delete(connectionId);
      moveConnectionToClosed(connection, now);
      trimClosedConnections();
      pendingConnectionsPayload = null;
      renderControls();
    }
  } catch (error) {
    logger.error('[MONITORING]', 'closeConnection: failed', error);
    showToast(_('Failed to close connection'), 'error');
  } finally {
    closingConnectionIds.delete(connectionId);
    renderConnections();
  }
}

async function closeAllConnections() {
  if (activeConnections.size === 0 || closingAll) {
    return;
  }

  closingAll = true;
  renderControls();

  try {
    const response = await TachyonShellMethods.closeAllClashApiConnections();

    if (!response.success) {
      showToast(_('Failed to close connections'), 'error');
      return;
    }

    const now = Date.now();
    activeConnections.forEach((connection) => {
      moveConnectionToClosed(connection, now);
    });
    activeConnections.clear();
    pendingConnectionsPayload = null;
    trimClosedConnections();
  } catch (error) {
    logger.error('[MONITORING]', 'closeAllConnections: failed', error);
    showToast(_('Failed to close connections'), 'error');
  } finally {
    closingAll = false;
    renderControls();
    renderConnections();
  }
}

function handleDocumentPointerDown(event: MouseEvent) {
  if (!openDropdownId) return;
  const target = event.target as Node | null;
  const deviceWrap = document.getElementById('monitoring-device-filter-wrap');
  const routeWrap = document.getElementById('monitoring-route-filter-wrap');

  if (
    openDropdownId === 'device' &&
    deviceWrap &&
    target &&
    deviceWrap.contains(target)
  ) {
    return;
  }
  if (
    openDropdownId === 'route' &&
    routeWrap &&
    target &&
    routeWrap.contains(target)
  ) {
    return;
  }

  setDropdownOpen(null);
}

function handleDocumentKeyDown(event: KeyboardEvent) {
  if (event.key === 'Escape' && openDropdownId) {
    setDropdownOpen(null);
  }
}

function bindControls() {
  const activeButton = document.getElementById('monitoring-tab-active');
  const closedButton = document.getElementById('monitoring-tab-closed');
  const deviceTrigger = document.getElementById(
    'monitoring-device-filter-trigger',
  );
  const routeTrigger = document.getElementById(
    'monitoring-route-filter-trigger',
  );
  const networkGroup = document.getElementById('monitoring-network-filters');
  const searchInput = document.getElementById(
    'monitoring-search',
  ) as HTMLInputElement | null;
  const closeAllButton = document.getElementById('monitoring-close-all');
  const pauseToggleButton = document.getElementById('monitoring-pause-toggle');
  const connectionsContainer = document.getElementById(
    'monitoring-connections',
  );

  if (activeButton) {
    activeButton.onclick = () => setTab('active');
  }

  if (closedButton) {
    closedButton.onclick = () => setTab('closed');
  }

  if (closeAllButton) {
    closeAllButton.onclick = () => {
      void closeAllConnections();
    };
  }

  if (pauseToggleButton) {
    pauseToggleButton.onclick = () => {
      setMonitoringPaused(!monitoringPaused);
      pauseToggleButton.blur();
    };
  }

  if (deviceTrigger) {
    deviceTrigger.onclick = (event) => {
      event.stopPropagation();
      setDropdownOpen(openDropdownId === 'device' ? null : 'device');
    };
  }

  if (routeTrigger) {
    routeTrigger.onclick = (event) => {
      event.stopPropagation();
      setDropdownOpen(openDropdownId === 'route' ? null : 'route');
    };
  }

  if (networkGroup) {
    networkGroup.onchange = (event) => {
      const target = event.target as HTMLInputElement | null;
      if (!target || target.type !== 'checkbox') return;
      const proto = (target.value || '').toLowerCase();
      if (!proto) return;
      if (target.checked) {
        selectedNetworkFilters.add(proto);
      } else {
        selectedNetworkFilters.delete(proto);
      }
      lastQuickFilterSignature = '';
      renderControls();
      renderConnections();
    };
  }

  if (searchInput) {
    searchInput.oninput = () => {
      searchQuery = searchInput.value;
      lastQuickFilterSignature = '';
      renderControls();
      renderConnections();
    };
  }

  if (connectionsContainer) {
    connectionsContainer.onclick = (event) => {
      const target = event.target as HTMLElement | null;
      const button = target?.closest(
        '.tachyon_monitoring-page__row-action',
      ) as HTMLButtonElement | null;

      if (button?.value) {
        void closeConnection(button.value);
        return;
      }

      if (isTextSelectionInsideMonitoring()) {
        return;
      }

      const routeBadge = target?.closest<HTMLElement>('[data-filter-route]');
      if (routeBadge) {
        const routeValue = routeBadge.getAttribute('data-filter-route') || '';
        if (routeValue) {
          if (selectedRouteFilters.has(routeValue)) {
            selectedRouteFilters.delete(routeValue);
          } else {
            selectedRouteFilters.add(routeValue);
          }
          lastRouteFilterSignature = '';
          lastQuickFilterSignature = '';
          renderControls();
          renderConnections();
          return;
        }
      }

      const netBadge = target?.closest<HTMLElement>('[data-filter-network]');
      if (netBadge) {
        const netValue = (
          netBadge.getAttribute('data-filter-network') || ''
        ).toLowerCase();
        if (netValue) {
          if (selectedNetworkFilters.has(netValue)) {
            selectedNetworkFilters.delete(netValue);
          } else {
            selectedNetworkFilters.add(netValue);
          }
          lastQuickFilterSignature = '';
          renderControls();
          renderConnections();
        }
      }
    };
  }
}

async function loadLocalDevices() {
  try {
    localDeviceChoices = (await dependencies.loadLocalDeviceChoices?.()) || {};
  } catch (error) {
    logger.warn('[MONITORING]', 'loadLocalDevices: failed', error);
    localDeviceChoices = {};
  } finally {
    renderControls();
    renderConnections();
  }
}

async function loadRouteDisplayNames() {
  try {
    buildRouteDisplayNames(await CustomTachyonMethods.getConfigSections());
  } catch (error) {
    logger.warn('[MONITORING]', 'loadRouteDisplayNames: failed', error);
    buildRouteDisplayNames([]);
  } finally {
    renderControls();
    renderConnections();
  }
}

async function pollConnectionsSnapshot() {
  if (
    pollingConnections ||
    !monitoringMounted ||
    monitoringPaused ||
    serviceAvailability !== 'running'
  ) {
    return;
  }

  const mountId = monitoringMountId;
  pollingConnections = true;

  try {
    const response = await TachyonShellMethods.getClashApiConnections();

    if (
      !monitoringMounted ||
      mountId !== monitoringMountId ||
      serviceAvailability !== 'running'
    ) {
      return;
    }

    if (!response.success) {
      failed = true;
      loading = false;
      renderConnections();
      return;
    }

    applyConnectionsPayload(normalizeConnectionsPayload(response.data));
  } catch (error) {
    if (
      !monitoringMounted ||
      mountId !== monitoringMountId ||
      serviceAvailability !== 'running'
    ) {
      return;
    }

    logger.error('[MONITORING]', 'connections polling failed', error);
    failed = true;
    loading = false;
    renderConnections();
  } finally {
    pollingConnections = false;
  }
}

function startConnectionsPolling() {
  if (connectionsPollTimer) {
    return;
  }

  void pollConnectionsSnapshot();
  connectionsPollTimer = setInterval(() => {
    void pollConnectionsSnapshot();
  }, CONNECTIONS_RPC_POLL_INTERVAL_MS);
}

async function connectToConnectionsSocket(updatesId: number) {
  const mountId = monitoringMountId;
  const clashApiSecret = await getClashApiSecret();

  if (
    !monitoringMounted ||
    mountId !== monitoringMountId ||
    updatesId !== connectionsUpdatesId ||
    serviceAvailability !== 'running'
  ) {
    return;
  }

  unsubscribeConnectionsSocket();
  connectionsSocketUrl = `${getClashWsUrl()}/connections?token=${clashApiSecret}`;

  trackConnectionsSocketSubscription(
    connectionsSocketUrl,
    (msg) => {
      if (
        updatesId !== connectionsUpdatesId ||
        serviceAvailability !== 'running'
      ) {
        return;
      }

      directConnectionsSocketFailedAt = 0;

      try {
        applyConnectionsPayload(JSON.parse(msg) as ClashConnectionsPayload);
      } catch (error) {
        logger.error('[MONITORING]', 'connections socket parse failed', error);
      }
    },
    (_err) => {
      if (
        !monitoringMounted ||
        mountId !== monitoringMountId ||
        updatesId !== connectionsUpdatesId ||
        serviceAvailability !== 'running'
      ) {
        return;
      }

      directConnectionsSocketFailedAt = Date.now();
      logger.warn(
        '[MONITORING]',
        'direct connections socket failed, falling back to polling',
        _err,
      );

      if (connectionsSocketUrl) {
        unsubscribeConnectionsSocket();
        connectionsSocketUrl = '';
      }

      startConnectionsPolling();
    },
  );
}

function startConnectionsUpdates() {
  if (serviceAvailability !== 'running') {
    return;
  }

  if (canUseConnectionsSocket()) {
    const updatesId = ++connectionsUpdatesId;
    void connectToConnectionsSocket(updatesId);
    return;
  }

  startConnectionsPolling();
}

function stopConnectionsUpdates() {
  connectionsUpdatesId += 1;

  if (connectionsPollTimer) {
    clearInterval(connectionsPollTimer);
    connectionsPollTimer = null;
  }

  if (connectionsSocketUrl) {
    unsubscribeConnectionsSocket();
    connectionsSocketUrl = '';
  }
}

function setServiceAvailability(next: ServiceAvailability) {
  if (serviceAvailability === next) {
    return;
  }

  serviceAvailability = next;

  if (next === 'running') {
    loading = true;
    failed = false;
    startConnectionsUpdates();
  } else {
    stopConnectionsUpdates();
    pendingConnectionsPayload = null;

    if (next === 'stopped') {
      loading = false;
      failed = false;
      activeConnections.clear();
      closedConnections.clear();
      closingConnectionIds.clear();
    } else if (next === 'unavailable') {
      loading = false;
      failed = true;
    }
  }

  renderControls();
  renderConnections();
}

function watchServiceState() {
  serviceStateUnsubscribe?.();
  serviceStateUnsubscribe = subscribeRuntimeUiState((uiState) => {
    if (!monitoringMounted) {
      return;
    }

    setServiceAvailability(
      getServiceAvailability({
        loading: false,
        failed: false,
        running: Boolean(
          uiState.service.tachyon.running || uiState.service.sing_box?.running,
        ),
      }),
    );
  });
}

function resetMonitoringState() {
  activeTab = 'active';
  selectedDeviceFilters.clear();
  selectedRouteFilters.clear();
  selectedNetworkFilters.clear();
  setDropdownOpen(null);
  searchQuery = '';
  lastDeviceFilterSignature = '';
  lastRouteFilterSignature = '';
  lastQuickFilterSignature = '';
  loading = true;
  failed = false;
  closingAll = false;
  monitoringPaused = false;
  monitoringPausedAt = null;
  serviceAvailability = 'loading';
  pendingConnectionsPayload = null;
  activeConnections.clear();
  closedConnections.clear();
  closingConnectionIds.clear();

  const searchInput = document.getElementById(
    'monitoring-search',
  ) as HTMLInputElement | null;
  if (searchInput) {
    searchInput.value = '';
  }
}

async function onPageMount() {
  onPageUnmount();

  monitoringMounted = true;
  monitoringMountId += 1;
  const mountId = monitoringMountId;

  resetMonitoringState();
  bindControls();
  renderControls();
  renderConnections();
  watchServiceState();

  void loadLocalDevices();
  void loadRouteDisplayNames();

  layoutChangeUnsubscribe?.();
  layoutChangeUnsubscribe = subscribeDashboardLayoutChanges(() => {
    void loadRouteDisplayNames();
  });

  if (getCachedRuntimeUiState()) {
    void refreshRuntimeUiState({ force: true });
  } else {
    const uiState = await refreshRuntimeUiState({ force: true });

    if (!monitoringMounted || mountId !== monitoringMountId) {
      return;
    }

    if (!uiState && serviceAvailability === 'loading') {
      setServiceAvailability('unavailable');
    }
  }

  document.addEventListener('selectionchange', flushRenderAfterSelection);
  document.addEventListener('copy', handleMonitoringValueCopy);
  document.addEventListener('mousedown', handleDocumentPointerDown);
  document.addEventListener('keydown', handleDocumentKeyDown);

  renderTimer = setInterval(() => {
    if (monitoringPaused) {
      return;
    }

    renderConnections();
  }, RENDER_INTERVAL_MS);
}

let monitoringVisibilityPaused = false;

function pauseMonitoringUpdates() {
  if (!monitoringMounted || monitoringVisibilityPaused) return;
  monitoringVisibilityPaused = true;
  if (renderTimer) {
    clearInterval(renderTimer);
    renderTimer = null;
  }
  stopConnectionsUpdates();
}

function resumeMonitoringUpdates() {
  if (!monitoringMounted || !monitoringVisibilityPaused) return;
  monitoringVisibilityPaused = false;
  if (serviceAvailability === 'running') {
    startConnectionsUpdates();
  }
  if (!renderTimer) {
    renderTimer = setInterval(() => {
      if (monitoringPaused) {
        return;
      }
      renderConnections();
    }, RENDER_INTERVAL_MS);
  }
}

if (
  typeof document !== 'undefined' &&
  typeof document.addEventListener === 'function'
) {
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) {
      pauseMonitoringUpdates();
    } else {
      resumeMonitoringUpdates();
    }
  });
}

function onPageUnmount() {
  monitoringMounted = false;
  monitoringMountId += 1;
  monitoringVisibilityPaused = false;
  setDropdownOpen(null);

  if (renderTimer) {
    clearInterval(renderTimer);
    renderTimer = null;
  }

  stopConnectionsUpdates();
  serviceStateUnsubscribe?.();
  serviceStateUnsubscribe = null;
  layoutChangeUnsubscribe?.();
  layoutChangeUnsubscribe = null;

  document.removeEventListener('selectionchange', flushRenderAfterSelection);
  document.removeEventListener('copy', handleMonitoringValueCopy);
  document.removeEventListener('mousedown', handleDocumentPointerDown);
  document.removeEventListener('keydown', handleDocumentKeyDown);
}

function registerLifecycleListeners() {
  if (monitoringLifecycleRegistered) {
    return;
  }

  monitoringLifecycleRegistered = true;

  store.subscribe(
    (next: StoreType, prev: StoreType, diff: Partial<StoreType>) => {
      if (
        diff.tabService &&
        next.tabService.current !== prev.tabService.current
      ) {
        const isMonitoringVisible = next.tabService.current === 'monitoring';

        if (isMonitoringVisible) {
          return onPageMount();
        }

        if (!isMonitoringVisible) {
          return onPageUnmount();
        }
      }
    },
  );
}

export async function initController(
  controllerDependencies: MonitoringControllerDependencies = {},
): Promise<void> {
  dependencies = {
    ...dependencies,
    ...controllerDependencies,
  };

  if (monitoringControllerInitialized) {
    return;
  }

  monitoringControllerInitialized = true;

  onMount('monitoring-status').then(() => {
    registerLifecycleListeners();

    if (
      store.get().tabService.current === 'monitoring' ||
      isActiveLuciTab('monitoring')
    ) {
      onPageMount();
    }
  });
}

export { buildRouteDisplayNames, getRouteDisplayNameByTag, getRoute };
