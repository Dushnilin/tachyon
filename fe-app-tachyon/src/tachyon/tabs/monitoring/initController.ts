import { canUseDirectClashApi, getClashWsUrl, onMount } from '../../../helpers';
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
  getRouteDisplayNames,
  getRoute,
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
import { normalizeString } from './formatters';

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
let renderTimer: ReturnType<typeof setInterval> | null = null;
let connectionsPollTimer: ReturnType<typeof setInterval> | null = null;
let connectionsSocketUrl = '';
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
let selectedDeviceFilter = ALL_FILTER_VALUE;
let selectedRouteFilter = ALL_FILTER_VALUE;
let searchQuery = '';
let localDeviceChoices: LocalDeviceChoices = {};
let lastDeviceFilterSignature = '';
let lastRouteFilterSignature = '';
let loading = true;
let failed = false;
let closingAll = false;
let monitoringPaused = false;
let monitoringPausedAt: number | null = null;
let serviceAvailability: ServiceAvailability = 'loading';

const activeConnections = new Map<string, MonitoredConnection>();
const closedConnections = new Map<string, MonitoredConnection>();
const closingConnectionIds = new Set<string>();

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

function getVisibleConnections(): MonitoredConnection[] {
  return filterVisibleConnections({
    deviceFilter: selectedDeviceFilter,
    routeFilter: selectedRouteFilter,
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
    activeConnections.set(id, {
      ...rawConnection,
      id,
      lastSeenAt: now,
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

  return Array.from(ips).sort((a, b) => {
    const byLabel = getLocalDeviceFilterLabel(a).localeCompare(
      getLocalDeviceFilterLabel(b),
    );
    return byLabel || a.localeCompare(b);
  });
}

function renderRouteFilterOptions() {
  const select = document.getElementById(
    'monitoring-route-filter',
  ) as HTMLSelectElement | null;
  if (!select) return;

  const uniqueRoutes = new Set<string>();
  Object.values(getRouteDisplayNames()).forEach((name) => {
    if (name) uniqueRoutes.add(name);
  });

  const routes = Array.from(uniqueRoutes).sort();

  if (
    selectedRouteFilter !== ALL_FILTER_VALUE &&
    !routes.includes(selectedRouteFilter)
  ) {
    selectedRouteFilter = ALL_FILTER_VALUE;
  }

  const signature = [selectedRouteFilter, ...routes].join('|');

  if (signature === lastRouteFilterSignature) {
    select.value = selectedRouteFilter;
    return;
  }

  lastRouteFilterSignature = signature;

  const options = [
    E('option', { value: ALL_FILTER_VALUE }, _('All Routes')),
    ...routes.map((name) => E('option', { value: name }, name)),
  ];

  select.replaceChildren(...options);
  select.value = selectedRouteFilter;
}

function renderDeviceFilterOptions() {
  const select = document.getElementById(
    'monitoring-device-filter',
  ) as HTMLSelectElement | null;

  if (!select) {
    return;
  }

  const sourceIps = getKnownSourceIps();
  if (
    selectedDeviceFilter !== ALL_FILTER_VALUE &&
    !sourceIps.includes(selectedDeviceFilter)
  ) {
    selectedDeviceFilter = ALL_FILTER_VALUE;
  }

  const signature = [
    selectedDeviceFilter,
    ...sourceIps.map((ip) => `${ip}:${getLocalDeviceFilterLabel(ip)}`),
  ].join('|');
  if (signature === lastDeviceFilterSignature) {
    select.value = selectedDeviceFilter;
    return;
  }

  lastDeviceFilterSignature = signature;

  const options = [
    E('option', { value: ALL_FILTER_VALUE }, _('All')),
    ...sourceIps.map((ip) =>
      E('option', { value: ip }, getLocalDeviceFilterLabel(ip)),
    ),
  ];

  select.replaceChildren(...options);
  select.value = selectedDeviceFilter;
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

  const select = document.getElementById(
    'monitoring-device-filter',
  ) as HTMLSelectElement | null;
  const searchInput = document.getElementById(
    'monitoring-search',
  ) as HTMLInputElement | null;

  if (select) {
    select.disabled = serviceAvailability === 'stopped';
  }

  if (searchInput) {
    searchInput.disabled = serviceAvailability === 'stopped';
  }
}

function renderValue(value: string, className = '') {
  const text = value || '-';
  const element = E(
    'span',
    {
      class: ['tachyon_monitoring-page__value', className]
        .filter(Boolean)
        .join(' '),
      title: text,
    },
    text,
  );

  element.setAttribute('data-copy-value', text);

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

  const row = E(
    'tr',
    {
      class: isClosing ? 'tachyon_monitoring-page__row--closing' : '',
    },
    [
      renderTableCell(_('Host'), [renderValue(target.primary)]),
      renderTableCell(_('Type'), [
        renderValue(getNetwork(connection), 'tachyon_monitoring-page__network'),
      ]),
      renderTableCell(_('Route'), [
        renderValue(getRoute(connection), 'tachyon_monitoring-page__route'),
      ]),
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

  const seenIds = new Set<string>();
  for (const connection of visibleConnections) {
    seenIds.add(connection.id);
    const signature = getConnectionRowSignature(connection);
    const existing = existingRows.get(connection.id);

    if (!existing) {
      tbody.appendChild(renderConnectionRow(connection));
      continue;
    }

    if (existing.getAttribute('data-row-signature') !== signature) {
      tbody.replaceChild(renderConnectionRow(connection), existing);
      continue;
    }

    // Patch volatile cells in place: Time, Downloaded, Uploaded.
    patchVolatileCells(existing, connection);
    tbody.appendChild(existing);
  }

  for (const [id, row] of existingRows) {
    if (!seenIds.has(id)) {
      row.remove();
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

  const volatileByIndex: Array<[number, () => HTMLElement]> = [
    [
      3,
      () =>
        renderTableCell(_('Time'), [
          renderValue(formatConnectionDuration(connection)),
        ]),
    ],
    [
      4,
      () =>
        renderTableCell(_('Downloaded'), [
          renderValue(formatBytes(connection.download)),
        ]),
    ],
    [
      5,
      () =>
        renderTableCell(_('Uploaded'), [
          renderValue(formatBytes(connection.upload)),
        ]),
    ],
  ];

  for (const [index, makeCell] of volatileByIndex) {
    const current = cells[index];
    const next = makeCell();
    if (current) {
      row.replaceChild(next, current);
    } else {
      row.appendChild(next);
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

function bindControls() {
  const activeButton = document.getElementById('monitoring-tab-active');
  const closedButton = document.getElementById('monitoring-tab-closed');
  const select = document.getElementById(
    'monitoring-device-filter',
  ) as HTMLSelectElement | null;
  const routeSelect = document.getElementById(
    'monitoring-route-filter',
  ) as HTMLSelectElement | null;
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

  if (select) {
    select.onchange = () => {
      selectedDeviceFilter = select.value || ALL_FILTER_VALUE;
      renderConnections();
    };
  }

  if (routeSelect) {
    routeSelect.onchange = () => {
      selectedRouteFilter = routeSelect.value || ALL_FILTER_VALUE;
      renderConnections();
    };
  }

  if (searchInput) {
    searchInput.oninput = () => {
      searchQuery = searchInput.value;
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

  connectionsSocketUrl = `${getClashWsUrl()}/connections?token=${clashApiSecret}`;

  socket.subscribe(
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
        socket.disconnect(connectionsSocketUrl);
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
    socket.disconnect(connectionsSocketUrl);
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
        running: uiState.service.tachyon.running,
      }),
    );
  });
}

function resetMonitoringState() {
  activeTab = 'active';
  selectedDeviceFilter = ALL_FILTER_VALUE;
  selectedRouteFilter = ALL_FILTER_VALUE;
  searchQuery = '';
  lastDeviceFilterSignature = '';
  lastRouteFilterSignature = '';
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

  if (renderTimer) {
    clearInterval(renderTimer);
    renderTimer = null;
  }

  stopConnectionsUpdates();
  serviceStateUnsubscribe?.();
  serviceStateUnsubscribe = null;

  document.removeEventListener('selectionchange', flushRenderAfterSelection);
  document.removeEventListener('copy', handleMonitoringValueCopy);
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

    if (store.get().tabService.current === 'monitoring') {
      onPageMount();
    }
  });
}

export { buildRouteDisplayNames, getRouteDisplayNameByTag, getRoute };
