/* eslint-disable @typescript-eslint/no-explicit-any */
import {
  canUseDirectClashApi,
  getClashWsUrl,
  isCopyableProxyLink,
  isUserActivelyScrolling,
  onMount,
  openPrefixColorPickerModal,
  preserveScrollForPage,
  renderOutboundTypeWithPopover,
  resolvePrefixBadgeStyle,
  svgEl,
} from '../../../helpers';
import { copyToClipboard } from '../../../helpers/copyToClipboard';
import { showToast } from '../../../helpers/showToast';
import { prettyBytes } from '../../../helpers/prettyBytes';
import {
  renderAlertTriangleIcon,
  renderArrowUpRightIcon,
  renderCheckIcon,
  renderCopyIcon24,
  renderLayoutGridIcon,
  renderListIcon,
  renderLoaderCircleIcon24,
  renderRefreshCwIcon,
  renderSettingsIcon,
  renderXIcon,
  renderZapIcon,
} from '../../../icons';
import { CustomTachyonMethods, TachyonShellMethods } from '../../methods';
import { tr, isRussianLanguage } from '../../helpers/i18n';
import {
  logger,
  markUiActionOwned,
  setLocalLatencyAction,
  setLocalSubscriptionAction,
  shouldNotifyOwnedUiAction,
  socket,
  store,
  StoreType,
} from '../../services';
import {
  clearDashboardGridHoverFreeze,
  getLatencyTestLabel,
  renderFlagEmojis,
  renderSections,
  renderWidget,
  renderDualWidget,
  renderConnections,
  patchConnections,
  patchExistingClientRowsByIp,
  IConnection,
  renderKpiRow,
  renderTrafficChartCard,
  renderDashboardSectionsAndNodes,
  renderSectionConditionsAndBalancersView,
} from './partials';
import {
  sortOutboundsForDashboard,
  sortUrlTestMembers,
} from '../../methods/custom/getDashboardSections';
import { fetchServicesInfo } from '../../fetchers/fetchServicesInfo';
import { fetchHostnames } from '../../fetchers/fetchHostnames';
import { getExpandedSections, toggleSectionExpansion } from './actions';
import {
  aggregateClientConnections,
  aggregateTopDomains,
  ITopDomain,
} from './connections';
import {
  getAllActiveRoutes,
  isServiceGroup,
  isNonTestableOutboundType,
  ActiveRouteInfo,
} from './activeRoute';
import { ensureOutboundDisplayFlag } from '../../helpers/country';
import {
  computeConnectionRates,
  computeTrafficRates,
  ConnectionTrafficSample,
  createInitialConnectionRatesState,
  createInitialTrafficRatesState,
  TrafficSample,
  TrafficRatesState,
} from './metrics';
import {
  applyDashboardLayoutToDom,
  getWidgetViewMode,
  subscribeDashboardLayoutChanges,
} from './dashboardLayout';
import {
  getConfiguredServerInbounds,
  renderInboundServersDashboardWidget,
} from './inboundServers';

let expandedSections = getExpandedSections();
const expandedRoutingSections = new Set<string>();
const sectionAccordionTabs = new Map<string, 'nodes' | 'conditions'>();
const DASHBOARD_NODES_VIEW_MODE_KEY = 'tachyon_dashboard_nodes_view_mode';

function getDashboardNodesViewMode(): 'table' | 'tiles' {
  try {
    if (typeof localStorage !== 'undefined') {
      const saved = localStorage.getItem(DASHBOARD_NODES_VIEW_MODE_KEY);
      if (saved === 'tiles' || saved === 'table') {
        return saved;
      }
    }
  } catch {
    // ignore storage errors
  }
  return 'table';
}

function setDashboardNodesViewMode(mode: 'table' | 'tiles') {
  try {
    if (typeof localStorage !== 'undefined') {
      localStorage.setItem(DASHBOARD_NODES_VIEW_MODE_KEY, mode);
    }
  } catch {
    // ignore storage errors
  }
}

function toggleSectionExpanded(sectionCode: string) {
  const result = toggleSectionExpansion(expandedSections, sectionCode);
  expandedSections = result.nextSections;
  if (result.expanded && sectionCode === 'active_clients') {
    void fetchConnections();
  }
  void renderSectionsWidget();
  void renderConnectionsWidget();
}

function findDashboardSectionRowEl(codeOrName: string): HTMLElement | null {
  if (typeof document === 'undefined' || !codeOrName) return null;
  const allSections = getSectionsWithCustomLatencies();
  const sec = allSections.find(
    (s) => s.code === codeOrName || s.sectionName === codeOrName,
  );
  const metricKey = sec?.sectionName || codeOrName;
  return document.querySelector<HTMLElement>(
    `[data-section-row-metrics="${metricKey}"]`,
  );
}

function toggleRoutingSectionExpanded(sectionCode: string) {
  const prevRow = findDashboardSectionRowEl(sectionCode);
  const prevTop = prevRow ? prevRow.getBoundingClientRect().top : null;

  if (expandedRoutingSections.has(sectionCode)) {
    expandedRoutingSections.delete(sectionCode);
  } else {
    expandedRoutingSections.add(sectionCode);
  }

  const restoreRowAnchor = () => {
    const nextRow = findDashboardSectionRowEl(sectionCode);
    if (!nextRow || typeof window === 'undefined') return;
    const nextTop = nextRow.getBoundingClientRect().top;
    const targetTop = prevTop !== null && prevTop >= 12 ? prevTop : 16;
    const delta = nextTop - targetTop;
    if (Math.abs(delta) > 4) {
      const mainContent = document.getElementById('maincontent');
      if (mainContent && mainContent.scrollTop > 0) {
        mainContent.scrollTop += delta;
      } else {
        window.scrollBy(0, delta);
      }
    }
  };

  void renderSectionsWidget(true).then(() => {
    restoreRowAnchor();
    if (typeof requestAnimationFrame === 'function') {
      requestAnimationFrame(restoreRowAnchor);
    }
  });
}
import { getClashApiSecret } from '../../methods/custom/getClashApiSecret';
import { measurePriorityLatencies } from './priorityLatency';
import { Tachyon } from '../../types';
import {
  getCachedRuntimeUiState,
  refreshRuntimeUiState,
  subscribeRuntimeUiState,
} from '../../services/runtimeUiState.service';
import { isActiveLuciTab } from '../../helpers/isActiveLuciTab';
import { isTransientRpcError } from '../../helpers/isTransientRpcError';
import { shouldShowLoadingForRestoredAction } from '../../helpers/restoredActionLoading';
import { getServiceAvailability } from '../../helpers/serviceAvailability';
import { capSetSize, capMapSize } from '../../helpers/capCollectionSize';

const SECTIONS_REFRESH_INTERVAL_MS = 15000;
const CONNECTIONS_POLL_INTERVAL_MS = 3000;
const LATENCY_TEST_BUTTON_CLASS = 'dashboard-sections-grid-item-test-latency';
const LATENCY_TEST_BUTTON_LABEL_CLASS =
  'dashboard-sections-grid-item-test-latency__label';
let sectionsRefreshTimer: ReturnType<typeof setInterval> | null = null;
let sectionsRefreshPromise: Promise<boolean> | null = null;
let sectionsRefreshQueued = false;
let actionStateUnsubscribe: (() => void) | null = null;
let dashboardMounted = false;
let dashboardMountId = 0;
let dashboardDataUpdatesStarted = false;
let dashboardDataUpdatesId = 0;
let connectionsRefreshTimer: ReturnType<typeof setInterval> | null = null;
let currentConnections: IConnection[] = [];
let currentTopDomains: ITopDomain[] = [];
let lastRawConnections: any[] = [];
let cachedHostnames = new Map<string, string>();
let directSocketsFailed = false;
let trafficRatesState: TrafficRatesState = createInitialTrafficRatesState();
let connectionRatesState = createInitialConnectionRatesState();
let connectionRates = new Map<string, TrafficSample>();

function updateRawConnections(connections: ConnectionTrafficSample[]) {
  const sample = computeConnectionRates(
    connections,
    Date.now(),
    connectionRatesState,
  );
  connectionRatesState = sample.nextState;
  connectionRates = sample.rates;
  lastRawConnections = connections;
  // A final idle snapshot may leave global totals unchanged, but section
  // speeds still need to return to zero.
  scheduleSectionDashboardWidgetsRender();
}
let pageUnloading = false;
const followedSubscriptionJobs = new Set<string>();
const followedLatencyJobs = new Set<string>();
const handledSubscriptionJobs = new Set<string>();
const handledLatencyJobs = new Set<string>();

// Teardown has to name the exact callbacks it registered. `/connections` is
// shared with the monitoring tab, so both a whole-manager reset and a
// whole-URL disconnect took the other tab's live listener down with them, and
// neither tab ever re-subscribed. Track what this tab handed to
// socket.subscribe() and unsubscribe exactly that: the manager drops the last
// listener for a URL on its own, so the shared socket stays up for whoever is
// still listening.
let clashSocketSubscriptions: Array<{
  url: string;
  listener: Parameters<typeof socket.subscribe>[1];
  onError: Parameters<typeof socket.subscribe>[2];
}> = [];

function trackClashSocketSubscription(
  url: string,
  listener: Parameters<typeof socket.subscribe>[1],
  onError: Parameters<typeof socket.subscribe>[2],
) {
  socket.subscribe(url, listener, onError);
  clashSocketSubscriptions.push({ url, listener, onError });
}

function unsubscribeClashSockets() {
  for (const { url, listener, onError } of clashSocketSubscriptions) {
    socket.unsubscribe(url, listener, onError);
  }
  clashSocketSubscriptions = [];
}

export const customProxyLatencies = new Map<string, number>();
const activeCountryFilters = new Map<string, string>();
const activeRegionFilters = new Map<string, string>();
const collapsedSourceGroups = new Set<string>();
const singleTestingOutboundCodes: Record<string, boolean> = {};
let isTestingAllSections = false;
let selectedDashboardSectionCode = '';
let activeSectionModalTab: 'nodes' | 'conditions' = 'nodes';

let dashboardVisibilityPaused = false;

if (typeof window !== 'undefined') {
  window.addEventListener('pagehide', () => {
    pageUnloading = true;
  });
  window.addEventListener('pageshow', () => {
    pageUnloading = false;
  });
}

if (
  typeof document !== 'undefined' &&
  typeof document.addEventListener === 'function'
) {
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) {
      if (dashboardDataUpdatesStarted) {
        stopDashboardDataUpdates();
        dashboardVisibilityPaused = true;
      }
    } else if (dashboardVisibilityPaused) {
      dashboardVisibilityPaused = false;
      if (dashboardMounted && getDashboardServiceAvailability() !== 'stopped') {
        startDashboardDataUpdates();
      }
    }
  });
}

const probedPriorityMemberTags = new Set<string>();
let warmingPriorityLatencies = false;

function warmPrioritySectionLatencies(
  sections: Tachyon.OutboundGroup[],
  mountId: number,
) {
  if (warmingPriorityLatencies || !dashboardMounted) {
    return;
  }

  const pendingGroups: Array<{
    healthUrl?: string;
    members: Tachyon.PriorityMember[];
  }> = [];

  for (const section of sections) {
    if (isServiceGroup(section)) continue;
    for (const outbound of section.outbounds || []) {
      const info = outbound.priorityInfo;
      if (!info?.outbounds?.length) continue;
      const missingMembers = info.outbounds.filter((member) => {
        const code = String(member.code || '').trim();
        if (!code || code === 'direct-out') return false;
        if (probedPriorityMemberTags.has(code)) return false;
        if (customProxyLatencies.has(code)) return false;
        return !member.latency || member.latency === 0;
      });
      if (missingMembers.length > 0) {
        for (const m of missingMembers) {
          probedPriorityMemberTags.add(String(m.code || '').trim());
        }
        capSetSize(probedPriorityMemberTags);
        pendingGroups.push({
          healthUrl: info.healthUrl,
          members: missingMembers,
        });
      }
    }
  }

  if (pendingGroups.length === 0) {
    return;
  }

  warmingPriorityLatencies = true;
  void (async () => {
    try {
      let anyMeasured = false;
      for (const group of pendingGroups) {
        if (
          !dashboardMounted ||
          mountId !== dashboardMountId ||
          getDashboardServiceAvailability() === 'stopped'
        ) {
          return;
        }
        const measured = await measurePriorityLatencies(group.members, {
          healthUrl: group.healthUrl,
          existing: customProxyLatencies,
          probe: (tag, timeout) =>
            TachyonShellMethods.getClashApiProxyLatency(tag, timeout),
        });
        if (measured.size > 0) {
          anyMeasured = true;
          measured.forEach((delay, tag) => {
            customProxyLatencies.set(tag, delay);
          });
          capMapSize(customProxyLatencies);
        }
      }
      if (
        anyMeasured &&
        dashboardMounted &&
        mountId === dashboardMountId &&
        getDashboardServiceAvailability() !== 'stopped'
      ) {
        void renderSectionsWidget();
        void fetchDashboardSections({ force: true });
      }
    } finally {
      warmingPriorityLatencies = false;
    }
  })();
}

// Fetchers

async function fetchDashboardSectionsOnce(mountId: number) {
  if (getDashboardServiceAvailability() === 'stopped') {
    return false;
  }

  const prev = store.get().sectionsWidget;
  const hasRenderedData = prev.data.length > 0;
  const nextLoading = prev.loading && !hasRenderedData;

  if (prev.failed !== false || prev.loading !== nextLoading) {
    store.set({
      sectionsWidget: {
        ...prev,
        failed: false,
        loading: nextLoading,
      },
    });
  }

  try {
    const { data, success } = await CustomTachyonMethods.getDashboardSections();

    if (
      !dashboardMounted ||
      mountId !== dashboardMountId ||
      getDashboardServiceAvailability() === 'stopped'
    ) {
      return false;
    }

    if (!success) {
      throw new Error('failed to fetch dashboard sections');
    }

    const current = store.get().sectionsWidget;

    store.set({
      sectionsWidget: {
        ...current,
        loading: false,
        failed: false,
        data,
      },
    });

    warmPrioritySectionLatencies(data, mountId);

    return true;
  } catch (error) {
    logger.error('[DASHBOARD]', 'fetchDashboardSections: failed', error);

    if (
      !dashboardMounted ||
      mountId !== dashboardMountId ||
      getDashboardServiceAvailability() === 'stopped'
    ) {
      return false;
    }

    const current = store.get().sectionsWidget;

    store.set({
      sectionsWidget: {
        ...current,
        loading: false,
        failed: current.data.length === 0,
        data: current.data,
      },
    });

    return false;
  }
}

async function fetchDashboardSections(options: { force?: boolean } = {}) {
  if (sectionsRefreshPromise) {
    if (options.force) {
      sectionsRefreshQueued = true;
    }

    return sectionsRefreshPromise;
  }

  const mountId = dashboardMountId;
  const promise = (async () => {
    let success = false;

    do {
      sectionsRefreshQueued = false;
      success = await fetchDashboardSectionsOnce(mountId);
    } while (
      sectionsRefreshQueued &&
      dashboardMounted &&
      mountId === dashboardMountId
    );

    return success;
  })();

  sectionsRefreshPromise = promise;

  try {
    return await promise;
  } finally {
    if (sectionsRefreshPromise === promise) {
      sectionsRefreshPromise = null;
    }
  }
}

function setSubscriptionUpdating(
  sectionName: string,
  updating: boolean,
  local = false,
) {
  if (local || !updating) {
    setLocalSubscriptionAction(sectionName, updating && local);
  }

  const sectionsWidget = store.get().sectionsWidget;
  const subscriptionUpdatingSections = {
    ...sectionsWidget.subscriptionUpdatingSections,
  };

  if (updating) {
    subscriptionUpdatingSections[sectionName] = true;
  } else {
    delete subscriptionUpdatingSections[sectionName];
  }

  store.set({
    sectionsWidget: {
      ...sectionsWidget,
      subscriptionUpdatingSections,
    },
  });
}

function setSelectorSwitching(sectionName: string, tag?: string) {
  const sectionsWidget = store.get().sectionsWidget;
  const selectorSwitchingSections = {
    ...sectionsWidget.selectorSwitchingSections,
  };

  if (tag) {
    selectorSwitchingSections[sectionName] = tag;
  } else {
    delete selectorSwitchingSections[sectionName];
  }

  store.set({
    sectionsWidget: {
      ...sectionsWidget,
      selectorSwitchingSections,
    },
  });
}

function setLatencyFetching(
  sectionName: string,
  fetching: boolean,
  local = false,
  progress?: Tachyon.LatencyActionProgress,
) {
  if (local || !fetching) {
    setLocalLatencyAction(sectionName, fetching && local);
  }

  const sectionsWidget = store.get().sectionsWidget;
  const latencyFetchingSections = {
    ...sectionsWidget.latencyFetchingSections,
  };
  const latencyProgressSections = {
    ...sectionsWidget.latencyProgressSections,
  };

  if (fetching) {
    latencyFetchingSections[sectionName] = true;
    if (progress) {
      latencyProgressSections[sectionName] = progress;
    }
  } else {
    delete latencyFetchingSections[sectionName];
    delete latencyProgressSections[sectionName];
  }

  store.set({
    sectionsWidget: {
      ...sectionsWidget,
      latencyFetchingSections,
      latencyProgressSections,
    },
  });
}

async function completeSubscriptionUpdateJob(
  jobId: string,
  sectionName: string,
  response: Tachyon.MethodResponse<Tachyon.SubscriptionUpdateJobState>,
) {
  if (pageUnloading) {
    setSubscriptionUpdating(sectionName, false);
    return;
  }

  if (jobId && handledSubscriptionJobs.has(jobId)) {
    setSubscriptionUpdating(sectionName, false);
    return;
  }

  const shouldNotify = jobId
    ? shouldNotifyOwnedUiAction('subscription', jobId)
    : false;
  const failed = !response.success || !response.data.success;
  const message = response.success
    ? response.data.message || _('Failed to update subscriptions')
    : response.error || _('Failed to update subscriptions');

  if (failed && isTransientRpcError(message)) {
    void refreshRuntimeUiState({ force: true });
    return;
  }

  if (jobId) {
    handledSubscriptionJobs.add(jobId);
    capSetSize(handledSubscriptionJobs);
  }

  setSubscriptionUpdating(sectionName, false);

  if (jobId && response.success) {
    void TachyonShellMethods.uiActionAck('subscription', jobId);
  }

  if (failed) {
    if (shouldNotify) {
      showToast(_('Failed to update subscriptions'), 'error');
    }
    return;
  }

  if (shouldNotify) {
    showToast(_('Subscriptions updated'), 'success');
  }
  void fetchDashboardSections({ force: true });
  void fetchServicesInfo();
  void fetchTailscalePeers();
}

async function followSubscriptionUpdateState(
  state: Tachyon.SubscriptionUpdateJobState,
) {
  const jobId = state.job_id;
  const sectionName = state.section || '';

  if (!jobId || !sectionName || followedSubscriptionJobs.has(jobId)) {
    return;
  }

  if (!state.running && handledSubscriptionJobs.has(jobId)) {
    return;
  }

  followedSubscriptionJobs.add(jobId);
  if (shouldShowLoadingForRestoredAction(state)) {
    setSubscriptionUpdating(sectionName, true);
  }

  try {
    const response = state.running
      ? await TachyonShellMethods.waitSubscriptionUpdateJob(jobId)
      : ({
          success: true,
          data: state,
        } as Tachyon.MethodSuccessResponse<Tachyon.SubscriptionUpdateJobState>);

    await completeSubscriptionUpdateJob(jobId, sectionName, response);
  } catch (error) {
    logger.error('[DASHBOARD]', 'followSubscriptionUpdateState failed', error);
    if (!pageUnloading) {
      const message =
        error instanceof Error
          ? error.message
          : _('Failed to update subscriptions');

      setSubscriptionUpdating(sectionName, false);
      if (!isTransientRpcError(message)) {
        showToast(_('Failed to update subscriptions'), 'error');
      }
    }
  } finally {
    followedSubscriptionJobs.delete(jobId);
  }
}

async function completeLatencyTestJob(jobId: string, sectionName: string) {
  setLatencyFetching(sectionName, false);

  if (pageUnloading) {
    return;
  }

  if (jobId && handledLatencyJobs.has(jobId)) {
    return;
  }

  if (jobId) {
    handledLatencyJobs.add(jobId);
    capSetSize(handledLatencyJobs);
  }

  if (jobId) {
    void TachyonShellMethods.uiActionAck('latency', jobId);
  }

  void fetchDashboardSections({ force: true });
}

async function followLatencyTestState(state: Tachyon.LatencyActionState) {
  const jobId = state.job_id;
  const sectionName = state.section || '';

  if (!jobId || !sectionName || followedLatencyJobs.has(jobId)) {
    return;
  }

  if (!state.running && handledLatencyJobs.has(jobId)) {
    return;
  }

  followedLatencyJobs.add(jobId);
  if (shouldShowLoadingForRestoredAction(state)) {
    setLatencyFetching(sectionName, true);
  }

  try {
    if (state.running) {
      await TachyonShellMethods.waitLatencyTestJob(jobId);
    }

    const testedTags = extractTestedTags(
      state.latency_type,
      sectionName,
      state.tag,
    );
    if (testedTags.length > 0) {
      const startedAtMs =
        typeof state.started_at === 'number'
          ? state.started_at > 1e11
            ? state.started_at
            : state.started_at * 1000
          : 0;
      await applyTestedLatenciesResults(testedTags, startedAtMs);
    }

    await completeLatencyTestJob(jobId, sectionName);
  } catch (error) {
    logger.error('[DASHBOARD]', 'followLatencyTestState failed', error);
    if (!pageUnloading) {
      setLatencyFetching(sectionName, false);
    }
  } finally {
    followedLatencyJobs.delete(jobId);
  }
}

function followDashboardActionsFromUiState(uiState: Tachyon.UiState) {
  for (const state of uiState.actions.subscription || []) {
    if (state.running || (state.job_id && state.section)) {
      void followSubscriptionUpdateState(state);
    } else if (state.job_id && !handledSubscriptionJobs.has(state.job_id)) {
      handledSubscriptionJobs.add(state.job_id);
      void TachyonShellMethods.uiActionAck('subscription', state.job_id);
    }
  }

  for (const state of uiState.actions.latency || []) {
    if (state.running || (state.job_id && state.section)) {
      void followLatencyTestState(state);
    } else if (state.job_id && !handledLatencyJobs.has(state.job_id)) {
      handledLatencyJobs.add(state.job_id);
      void TachyonShellMethods.uiActionAck('latency', state.job_id);
    }
  }
}

function startActionStateWatcher() {
  if (actionStateUnsubscribe) {
    return;
  }

  actionStateUnsubscribe = subscribeRuntimeUiState((uiState) => {
    if (dashboardMounted) {
      followDashboardActionsFromUiState(uiState);
    }
  });
}

function stopActionStateWatcher() {
  if (!actionStateUnsubscribe) {
    return;
  }

  actionStateUnsubscribe();
  actionStateUnsubscribe = null;
}

async function connectToClashSockets(dataUpdatesId: number) {
  const mountId = dashboardMountId;
  const clashApiSecret = await getClashApiSecret();

  if (
    !dashboardMounted ||
    mountId !== dashboardMountId ||
    dataUpdatesId !== dashboardDataUpdatesId ||
    getDashboardServiceAvailability() === 'stopped'
  ) {
    return;
  }

  if (!canUseDirectClashApi()) {
    directSocketsFailed = true;
    logger.info(
      '[DASHBOARD]',
      'direct Clash API websocket unavailable, relying on polling fallback',
    );
    return;
  }

  unsubscribeClashSockets();

  trackClashSocketSubscription(
    `${getClashWsUrl()}/traffic?token=${clashApiSecret}`,
    (msg) => {
      if (
        dataUpdatesId !== dashboardDataUpdatesId ||
        getDashboardServiceAvailability() === 'stopped'
      ) {
        return;
      }

      directSocketsFailed = false;
      const parsedMsg = JSON.parse(msg);

      store.set({
        bandwidthWidget: {
          loading: false,
          failed: false,
          data: { up: parsedMsg.up, down: parsedMsg.down },
        },
      });
    },
    (_err) => {
      if (
        dataUpdatesId !== dashboardDataUpdatesId ||
        getDashboardServiceAvailability() === 'stopped'
      ) {
        return;
      }

      directSocketsFailed = true;
      logger.warn(
        '[DASHBOARD]',
        'connectToClashSockets - traffic: socket failed, using polling fallback',
        getClashWsUrl(),
      );
    },
  );

  const isLiteMode = Boolean(store.get().servicesInfoWidget.data?.liteMode);
  if (isLiteMode && !expandedSections.has('active_clients')) {
    logger.info(
      '[DASHBOARD]',
      'Tachyon Lite active: skipping /connections WebSocket stream while client list is collapsed',
    );
    return;
  }

  trackClashSocketSubscription(
    `${getClashWsUrl()}/connections?token=${clashApiSecret}`,
    (msg) => {
      if (
        dataUpdatesId !== dashboardDataUpdatesId ||
        getDashboardServiceAvailability() === 'stopped'
      ) {
        return;
      }

      directSocketsFailed = false;
      const parsedMsg = JSON.parse(msg);

      if (Array.isArray(parsedMsg.connections)) {
        updateRawConnections(parsedMsg.connections);
        currentConnections = aggregateClientConnections(
          parsedMsg.connections,
          cachedHostnames,
        );
        currentTopDomains = aggregateTopDomains(parsedMsg.connections);
      }

      store.set({
        trafficTotalWidget: {
          loading: false,
          failed: false,
          data: {
            downloadTotal: parsedMsg.downloadTotal,
            uploadTotal: parsedMsg.uploadTotal,
          },
        },
        systemInfoWidget: {
          loading: false,
          failed: false,
          data: {
            connections: parsedMsg.connections?.length,
            memory: parsedMsg.memory,
          },
        },
      });

      if (
        Array.isArray(parsedMsg.connections) &&
        expandedSections.has('active_clients')
      ) {
        renderConnectionsWidget();
      }
      renderInboundServersDashboardWidget({
        rawConnections: lastRawConnections,
        hostnames: cachedHostnames,
      });
    },
    (_err) => {
      if (
        dataUpdatesId !== dashboardDataUpdatesId ||
        getDashboardServiceAvailability() === 'stopped'
      ) {
        return;
      }

      directSocketsFailed = true;
      logger.warn(
        '[DASHBOARD]',
        'connectToClashSockets - connections: socket failed, using polling fallback',
        getClashWsUrl(),
      );
    },
  );
}

function getDashboardServiceAvailability() {
  const service = store.get().servicesInfoWidget;

  return getServiceAvailability({
    loading: service.loading,
    failed: service.failed,
    running: service.data.tachyonRunning,
  });
}

function stopDashboardDataUpdates() {
  dashboardDataUpdatesStarted = false;
  dashboardDataUpdatesId += 1;

  if (sectionsRefreshTimer) {
    clearInterval(sectionsRefreshTimer);
    sectionsRefreshTimer = null;
  }
  if (connectionsRefreshTimer) {
    clearInterval(connectionsRefreshTimer);
    connectionsRefreshTimer = null;
  }

  sectionsRefreshQueued = false;
  // Only this tab's listeners, not socket.resetAll(): the monitoring tab holds
  // its own subscription to the same /connections URL and would go silent.
  unsubscribeClashSockets();
  currentConnections = [];
  connectionRatesState = createInitialConnectionRatesState();
  connectionRates.clear();
}

function startDashboardDataUpdates() {
  if (
    dashboardDataUpdatesStarted ||
    !dashboardMounted ||
    getDashboardServiceAvailability() === 'stopped'
  ) {
    return;
  }

  if (typeof document !== 'undefined' && document.hidden) {
    dashboardVisibilityPaused = true;
    return;
  }

  dashboardDataUpdatesStarted = true;
  const dataUpdatesId = ++dashboardDataUpdatesId;
  void fetchDashboardSections({ force: true });
  void connectToClashSockets(dataUpdatesId);
  sectionsRefreshTimer = setInterval(() => {
    void fetchDashboardSections();
  }, SECTIONS_REFRESH_INTERVAL_MS);

  void fetchConnections();
  connectionsRefreshTimer = setInterval(() => {
    void fetchConnections();
  }, CONNECTIONS_POLL_INTERVAL_MS);
}

function syncDashboardServiceAvailability() {
  const availability = getDashboardServiceAvailability();
  const stopped = availability === 'stopped';
  const container = document.getElementById('dashboard-status');

  container?.classList.toggle(
    'tachyon_dashboard-page--service-stopped',
    stopped,
  );

  if (stopped || availability === 'loading') {
    stopDashboardDataUpdates();
    void renderSystemServicesWidget();
    return;
  }

  startDashboardDataUpdates();
}

// Handlers

async function handleChooseOutbound(
  sectionName: string,
  selector: string,
  tag: string,
) {
  const sectionsWidget = store.get().sectionsWidget;
  const section = sectionsWidget.data.find(
    (item) => item.sectionName === sectionName,
  );

  if (
    !section?.withTagSelect ||
    sectionsWidget.selectorSwitchingSections[sectionName]
  ) {
    return;
  }

  setSelectorSwitching(sectionName, tag);

  try {
    const res = await TachyonShellMethods.setClashApiGroupProxy(selector, tag);
    if (res && !(res as any).success && (res as any).error) {
      showToast(
        (res as any).message ||
          (res as any).error ||
          _('Failed to switch proxy'),
        'error',
      );
    }
    await fetchDashboardSections({ force: true });
  } catch (error: any) {
    showToast(error?.message || _('Failed to switch proxy'), 'error');
  } finally {
    setSelectorSwitching(sectionName);
  }
}

type DashboardSectionItem = StoreType['sectionsWidget']['data'][number];

function serializeSectionLatencyTag(
  section: DashboardSectionItem,
  tag: string[],
): string {
  const hasGroupChildren = Boolean(
    section.sectionName &&
      section.outbounds?.some(
        (o) =>
          Boolean(o.urlTestInfo?.outbounds?.length) ||
          Boolean(o.priorityInfo?.outbounds?.length),
      ),
  );
  if ((tag.length > 40 || hasGroupChildren) && section.sectionName) {
    return `@section:${section.sectionName}`;
  }
  return JSON.stringify(tag);
}

function expandSectionTestableTags(
  section: DashboardSectionItem | undefined,
  baseTags: string[],
): string[] {
  if (!section?.outbounds?.length) {
    return baseTags;
  }
  const seen = new Set<string>(baseTags);
  const result = [...baseTags];
  for (const outbound of section.outbounds) {
    if (baseTags.length > 0 && !seen.has(outbound.code)) {
      continue;
    }
    for (const member of outbound.urlTestInfo?.outbounds || []) {
      if (member?.code && !seen.has(member.code)) {
        seen.add(member.code);
        result.push(member.code);
      }
    }
    for (const member of outbound.priorityInfo?.outbounds || []) {
      if (member?.code && !seen.has(member.code)) {
        seen.add(member.code);
        result.push(member.code);
      }
    }
  }
  return result;
}

function getInitialLatencyProgress(
  latencyType: Tachyon.LatencyActionState['latency_type'],
  tag: string,
  sectionName?: string,
): Tachyon.LatencyActionProgress | undefined {
  if (latencyType !== 'proxy_list') {
    return undefined;
  }

  if (tag.startsWith('@section:')) {
    const secName = sectionName || tag.slice(9);
    const section = store
      .get()
      .sectionsWidget.data.find((s) => s.sectionName === secName);
    const baseTags = section?.latencyTestCodes?.length
      ? section.latencyTestCodes
      : (section?.outbounds || [])
          .filter((o) => !isNonTestableOutboundType(o.type))
          .map((o) => o.code);
    const total = expandSectionTestableTags(section, baseTags).length;
    return total > 0 ? { completed: 0, total, failed: 0 } : undefined;
  }

  try {
    const tags = JSON.parse(tag);
    if (!Array.isArray(tags)) {
      return undefined;
    }

    const validTags = tags.filter(
      (item): item is string => typeof item === 'string' && item.length > 0,
    );
    const section = sectionName
      ? store
          .get()
          .sectionsWidget.data.find((s) => s.sectionName === sectionName)
      : undefined;
    const total = expandSectionTestableTags(section, validTags).length;

    return total > 0 ? { completed: 0, total, failed: 0 } : undefined;
  } catch {
    return undefined;
  }
}

export function extractTestedTags(
  latencyType: Tachyon.LatencyActionState['latency_type'],
  sectionName: string,
  tag: string,
): string[] {
  if (latencyType === 'proxy_list') {
    if (tag.startsWith('@section:')) {
      const secName = sectionName || tag.slice(9);
      const section = store
        .get()
        .sectionsWidget.data.find((s) => s.sectionName === secName);
      if (section && isServiceGroup(section)) {
        return [];
      }
      if (section?.latencyTestCodes?.length) {
        return expandSectionTestableTags(section, [
          ...section.latencyTestCodes,
        ]);
      }
      if (section?.outbounds) {
        const base = section.outbounds
          .filter((o) => !isNonTestableOutboundType(o.type))
          .map((o) => o.code);
        return expandSectionTestableTags(section, base);
      }
      return [];
    }
    try {
      const parsed = JSON.parse(tag);
      if (Array.isArray(parsed)) {
        const validTags = parsed.filter(
          (item): item is string => typeof item === 'string' && item.length > 0,
        );
        const section = sectionName
          ? store
              .get()
              .sectionsWidget.data.find((s) => s.sectionName === sectionName)
          : undefined;
        return expandSectionTestableTags(section, validTags);
      }
    } catch {
      return [];
    }
  }

  if (latencyType === 'group') {
    const section = store
      .get()
      .sectionsWidget.data.find((s) => s.sectionName === sectionName);
    if (section && isServiceGroup(section)) {
      return [];
    }
    if (section?.outbounds) {
      const base = section.outbounds
        .filter((o) => !isNonTestableOutboundType(o.type))
        .map((o) => o.code);
      return expandSectionTestableTags(section, base);
    }
    return [];
  }

  if (latencyType === 'proxy') {
    const parsedTag = tag.startsWith('[')
      ? (JSON.parse(tag)[0] as string)
      : tag;
    return parsedTag ? [parsedTag] : [];
  }

  return [];
}

export async function applyTestedLatenciesResults(
  testedTags: string[],
  testStartedAt: number,
  beforeTimes?: Map<string, string>,
) {
  if (!testedTags || testedTags.length === 0) {
    return;
  }

  try {
    const proxiesRes = await TachyonShellMethods.getClashApiProxies();
    if (!proxiesRes.success || !proxiesRes.data) {
      return;
    }

    const proxies = (proxiesRes.data as any)?.proxies || {};
    const telemetry = (proxiesRes.data as any)?.telemetry || {};
    const getTelemetryDelay = (t: string): number => {
      const entry = telemetry[t] || telemetry[t.trim()];
      const rtt = entry?.rtt_ms ?? entry?.ewma_rtt_ms;
      return typeof rtt === 'number' && Number.isFinite(rtt) && rtt > 0
        ? Math.round(rtt)
        : 0;
    };
    for (const tag of testedTags) {
      const proxy = proxies[tag] || proxies[tag.trim()];
      const latest = proxy?.history?.[0];
      const delay = typeof latest?.delay === 'number' ? latest.delay : 0;
      const currentTime = typeof latest?.time === 'string' ? latest.time : '';
      const prevTime = beforeTimes?.get(tag);

      const historyTimestamp = currentTime ? Date.parse(currentTime) : 0;
      const isFreshTimestamp =
        testStartedAt > 0 &&
        Number.isFinite(historyTimestamp) &&
        historyTimestamp >= testStartedAt - 15000;

      const isNewMeasurement =
        Boolean(currentTime) &&
        (isFreshTimestamp ||
          prevTime == null ||
          (prevTime != null && currentTime !== prevTime));

      const childTags: string[] = [];
      if (typeof proxy?.now === 'string' && proxy.now.trim()) {
        childTags.push(proxy.now.trim());
      }
      if (Array.isArray(proxy?.all)) {
        for (const c of proxy.all) {
          if (typeof c === 'string' && c.trim()) childTags.push(c.trim());
        }
      }
      for (const cTag of childTags) {
        const cLatest = proxies[cTag]?.history?.[0];
        const cDelay = typeof cLatest?.delay === 'number' ? cLatest.delay : 0;
        const cTime = typeof cLatest?.time === 'string' ? cLatest.time : '';
        const cPrevTime = beforeTimes?.get(cTag);
        const cTs = cTime ? Date.parse(cTime) : 0;
        const cFresh =
          testStartedAt > 0 &&
          Number.isFinite(cTs) &&
          cTs >= testStartedAt - 15000;
        const cIsNew =
          Boolean(cTime) &&
          (cFresh ||
            cPrevTime == null ||
            (cPrevTime != null && cTime !== cPrevTime));
        if (cIsNew && cDelay > 0) {
          customProxyLatencies.set(cTag, cDelay);
        }
      }

      if (isNewMeasurement && delay > 0) {
        customProxyLatencies.set(tag, delay);
      } else {
        let derivedDelay = 0;
        for (const cTag of childTags) {
          const cCustom = customProxyLatencies.get(cTag);
          if (typeof cCustom === 'number' && cCustom > 0) {
            derivedDelay =
              derivedDelay > 0 ? Math.min(derivedDelay, cCustom) : cCustom;
            if (cTag === proxy?.now) {
              derivedDelay = cCustom;
              break;
            }
          }
          const cLatest = proxies[cTag]?.history?.[0];
          const cDelay =
            typeof cLatest?.delay === 'number' && cLatest.delay > 0
              ? cLatest.delay
              : getTelemetryDelay(cTag);
          if (cDelay > 0) {
            derivedDelay =
              derivedDelay > 0 ? Math.min(derivedDelay, cDelay) : cDelay;
            if (cTag === proxy?.now) {
              derivedDelay = cDelay;
              break;
            }
          }
        }
        if (derivedDelay <= 0) {
          derivedDelay = getTelemetryDelay(tag);
        }
        customProxyLatencies.set(tag, derivedDelay > 0 ? derivedDelay : -1);
      }
    }

    capMapSize(customProxyLatencies);
    clearDashboardGridHoverFreeze();
    void renderSectionsWidget();
  } catch (error) {
    logger.warn(
      '[DASHBOARD]',
      'Failed to apply tested latencies results',
      error,
    );
  }
}

async function handleTestLatency(
  latencyType: Tachyon.LatencyActionState['latency_type'],
  sectionName: string,
  tag: string,
  timeout?: string,
) {
  if (store.get().sectionsWidget.latencyFetchingSections[sectionName]) {
    return;
  }

  setLatencyFetching(
    sectionName,
    true,
    true,
    getInitialLatencyProgress(latencyType, tag, sectionName),
  );
  let jobId = '';
  let ownsJobFollow = false;
  let completed = false;
  const testedTags = extractTestedTags(latencyType, sectionName, tag);
  const testStartedAt = Date.now();
  const beforeTimes = new Map<string, string>();
  const snapshotBeforePromise =
    testedTags.length > 0 && latencyType !== 'proxy'
      ? TachyonShellMethods.getClashApiProxies()
          .then((beforeProxiesRes) => {
            if (beforeProxiesRes.success && beforeProxiesRes.data) {
              const proxies = (beforeProxiesRes.data as any)?.proxies || {};
              for (const t of testedTags) {
                const time = (proxies[t] || proxies[t.trim()])?.history?.[0]
                  ?.time;
                if (typeof time === 'string') {
                  beforeTimes.set(t, time);
                }
              }
            }
          })
          .catch((e) => {
            logger.debug(
              '[DASHBOARD]',
              'snapshot proxies before test failed',
              e,
            );
          })
      : Promise.resolve();

  try {
    if (latencyType === 'proxy') {
      const parsedTag = tag.startsWith('[') ? JSON.parse(tag)[0] : tag;
      const response = await TachyonShellMethods.getClashApiProxyLatency(
        parsedTag,
        timeout,
      );
      if (response.success && response.data) {
        const delay = (response.data as any)?.delay;
        if (typeof delay === 'number' && delay > 0) {
          customProxyLatencies.set(tag, delay);
        } else {
          const groupDelays = Object.values(response.data || {}).filter(
            (v): v is number => typeof v === 'number' && v > 0,
          );
          customProxyLatencies.set(
            tag,
            groupDelays.length > 0 ? Math.min(...groupDelays) : -1,
          );
        }
      } else {
        customProxyLatencies.set(tag, -1);
      }
      capMapSize(customProxyLatencies);
      setLatencyFetching(sectionName, false);
      completed = true;
      void fetchDashboardSections({ force: true });
    } else {
      await snapshotBeforePromise;
      const startResponse = await TachyonShellMethods.latencyTestStart(
        latencyType,
        sectionName,
        tag,
        timeout,
      );

      if (!startResponse.success) {
        setLatencyFetching(sectionName, false);
        return;
      }

      jobId = startResponse.data.job_id;
      if (!jobId) {
        setLatencyFetching(sectionName, false);
        return;
      }

      followedLatencyJobs.add(jobId);
      ownsJobFollow = true;
      await TachyonShellMethods.waitLatencyTestJob(
        jobId,
        Date.now(),
        (state) => {
          if (state.running && state.progress) {
            setLatencyFetching(sectionName, true, true, state.progress);
          }
        },
      );
      await applyTestedLatenciesResults(testedTags, testStartedAt, beforeTimes);
      await completeLatencyTestJob(jobId, sectionName);
      completed = true;
    }
  } catch (error) {
    logger.error('[DASHBOARD]', 'handleTestLatency: failed', error);
  } finally {
    if (ownsJobFollow) {
      followedLatencyJobs.delete(jobId);
    }

    if (!completed) {
      setLatencyFetching(sectionName, false);
    }
  }
}

async function handleTestSingleOutbound(
  _sectionName: string,
  outboundCode: string,
) {
  if (singleTestingOutboundCodes[outboundCode]) {
    return;
  }
  singleTestingOutboundCodes[outboundCode] = true;
  void renderSectionsWidget();

  try {
    const response = await TachyonShellMethods.getClashApiProxyLatency(
      outboundCode,
      '2000',
    );
    if (response.success && response.data) {
      const delay = (response.data as any)?.delay;
      if (typeof delay === 'number' && delay > 0) {
        customProxyLatencies.set(outboundCode, delay);
      } else {
        const groupDelays = Object.values(response.data || {}).filter(
          (v): v is number => typeof v === 'number' && v > 0,
        );
        customProxyLatencies.set(
          outboundCode,
          groupDelays.length > 0 ? Math.min(...groupDelays) : -1,
        );
      }
    } else {
      customProxyLatencies.set(outboundCode, -1);
    }
    capMapSize(customProxyLatencies);
  } catch (error) {
    logger.warn('[DASHBOARD]', 'Failed single proxy latency test', error);
    customProxyLatencies.set(outboundCode, -1);
  } finally {
    delete singleTestingOutboundCodes[outboundCode];
    void renderSectionsWidget();
    void renderTrafficTotalWidget();
  }
}

async function handleTestAllSections() {
  if (isTestingAllSections) {
    return;
  }
  isTestingAllSections = true;
  void renderSectionsWidget();

  try {
    const sectionsWidget = store.get().sectionsWidget;
    const taskFns: Array<() => Promise<void>> = [];
    for (const section of sectionsWidget.data) {
      if (!section.outbounds || section.outbounds.length === 0) {
        continue;
      }
      if (isServiceGroup(section)) {
        continue;
      }
      if (sectionsWidget.latencyFetchingSections[section.sectionName]) {
        continue;
      }
      const testable = section.outbounds.filter(
        (o) => !isNonTestableOutboundType(o.type),
      );
      if (testable.length === 0) {
        continue;
      }

      if (section.withTagSelect) {
        const tag = section.latencyTestCodes?.length
          ? section.latencyTestCodes
          : section.latencyTestCode || section.code;
        if (Array.isArray(tag)) {
          const serializedTag = serializeSectionLatencyTag(section, tag);
          taskFns.push(() =>
            handleTestLatency(
              'proxy_list',
              section.sectionName,
              serializedTag,
              section.latencyTestTimeout,
            ),
          );
        } else {
          taskFns.push(() =>
            handleTestLatency(
              'group',
              section.sectionName,
              tag,
              section.latencyTestTimeout,
            ),
          );
        }
      } else {
        taskFns.push(() =>
          handleTestLatency(
            'proxy',
            section.sectionName,
            testable[0].code,
            section.latencyTestTimeout,
          ),
        );
      }
    }
    if (taskFns.length > 0) {
      const maxConcurrency = 2;
      let cursor = 0;
      const runWorker = async () => {
        while (cursor < taskFns.length) {
          const idx = cursor++;
          await taskFns[idx]();
        }
      };
      await Promise.all(
        Array.from({ length: Math.min(maxConcurrency, taskFns.length) }, () =>
          runWorker(),
        ),
      );
    }
  } finally {
    isTestingAllSections = false;
    void renderSectionsWidget();
  }
}

function handleCopyOutbound(outbound: Tachyon.Outbound) {
  const link = outbound.link;

  if (link && isCopyableProxyLink(link)) {
    copyToClipboard(link);
    return;
  }
  showToast(_('Proxy link is unavailable'), 'error');
}

function formatUrlTestModalValue(value: unknown) {
  if (typeof value === 'boolean') {
    return value ? _('Yes') : _('No');
  }

  const text = `${value ?? ''}`.trim();
  return text || _('No');
}

export function getUrlTestLatencyClass(latency: number) {
  // -1 is what the dashboard stores for "did not answer". It used to fall through
  // to the < 800 branch and paint a dead node green.
  if (!latency || latency < 0) {
    return 'tachyon_dashboard-page__outbound-grid__item__latency--empty';
  }

  if (latency < 800) {
    return 'tachyon_dashboard-page__outbound-grid__item__latency--green';
  }

  if (latency < 1500) {
    return 'tachyon_dashboard-page__outbound-grid__item__latency--yellow';
  }

  return 'tachyon_dashboard-page__outbound-grid__item__latency--red';
}

export function formatUrlTestLatency(latency: number) {
  return latency && latency > 0 ? `${latency}ms` : 'N/A';
}

function renderDetailsUrl(value: unknown) {
  const url = `${value ?? ''}`.trim();

  if (!/^https?:\/\//i.test(url)) {
    return E('span', {}, formatUrlTestModalValue(value));
  }

  return E(
    'a',
    {
      class: 'tachyon_dashboard-page__urltest-details__url',
      href: url,
      target: '_blank',
      rel: 'noopener noreferrer',
    },
    url,
  );
}

function normalizeDetailsUrlList(primaryUrl?: string, urls?: string[]) {
  const seen = new Set<string>();
  const result: string[] = [];
  for (const item of [...(urls || []), primaryUrl || '']) {
    const trimmed = `${item || ''}`.trim();
    if (trimmed && !seen.has(trimmed)) {
      seen.add(trimmed);
      result.push(trimmed);
    }
  }
  return result;
}

function renderDetailsUrls(primaryUrl?: string, urls?: string[]) {
  const list = normalizeDetailsUrlList(primaryUrl, urls);
  if (list.length <= 1) {
    return renderDetailsUrl(list[0] ?? primaryUrl);
  }

  return E(
    'div',
    { class: 'tachyon_dashboard-page__urltest-details__url-list' },
    list.map((url, idx) =>
      E('div', { class: 'tachyon_dashboard-page__urltest-details__url-item' }, [
        E(
          'span',
          { class: 'tachyon_dashboard-page__urltest-details__url-index' },
          `#${idx + 1}`,
        ),
        renderDetailsUrl(url),
      ]),
    ),
  );
}

function formatMultiUrlStrategyLabel(strategy?: string) {
  const key = `${strategy || 'worst_case'}`.trim().toLowerCase();
  if (key === 'best_case') {
    return _('At least one URL (best latency)');
  }
  if (key === 'best_case_target') {
    return _('Target URL #1 priority');
  }
  if (key === 'average') {
    return _('Average latency across URLs');
  }
  return _('All URLs must respond (worst latency)');
}

function formatBalancerModeLabel(mode?: string) {
  const key = `${mode || 'least_test'}`.trim().toLowerCase();
  switch (key) {
    case 'stability':
      return _('Stability (EWMA + RFC 3550 Jitter + Loss Penalty)');
    case 'sticky':
      return _('Sticky Flow (Rendezvous HRW by Client / Domain)');
    case 'least_load':
      return _('Least Load (Active Connections × RTT)');
    case 'weighted':
      return _('Weighted (Smooth WRR by 1/RTT²)');
    case 'passive':
      return _('Passive Circuit Breaker (Early-Abort Quarantine)');
    case 'hedged':
      return _('Hedged (Happy Eyeballs Parallel Backup)');
    case 'throughput':
      return _('Throughput (Active Bandwidth Decay)');
    case 'quota':
      return _('Quota (Traffic Quota Balancer)');
    case 'round_robin':
      return _('Round-Robin Pool');
    case 'failover':
      return _('Failover (Pin Current Until Failure)');
    case 'priority':
      return _('Priority (Ordered Failover Tiers)');
    default:
      return _('Fastest (Lowest RTT)');
  }
}

function shortenUrlForPopover(rawUrl: string, idx: number) {
  const trimmed = `${rawUrl || ''}`.trim();
  const stripped = trimmed.replace(/^https?:\/\//i, '').replace(/\/$/, '');
  const shortText =
    stripped.length > 32 ? `${stripped.slice(0, 29)}...` : stripped;
  return `#${idx + 1} ${shortText || trimmed}`;
}

function renderMemberUrlDelaysPopover(
  member: Tachyon.UrlTestMember,
  urls?: string[],
) {
  const memberDelays = member.urlDelays || {};
  const effectiveUrls = normalizeDetailsUrlList(undefined, [
    ...(urls || []),
    ...Object.keys(memberDelays),
  ]);

  if (effectiveUrls.length <= 1 && Object.keys(memberDelays).length === 0) {
    return null;
  }

  return E(
    'span',
    {
      class:
        'tachyon_dashboard-page__urltest-details__url-delays-trigger tachyon_proto-popover-trigger',
      tabIndex: 0,
      title: _('Latency by URL'),
    },
    [
      'i',
      E('div', { class: 'tachyon_proto-popover' }, [
        E('div', { class: 'tachyon_proto-popover__header' }, [
          E(
            'span',
            { class: 'tachyon_proto-popover__title' },
            _('Latency by URL'),
          ),
        ]),
        E(
          'div',
          { class: 'tachyon_proto-popover__rows' },
          effectiveUrls.map((url, idx) => {
            const rawDelayVal = memberDelays[url];
            const delayVal =
              rawDelayVal === undefined &&
              idx === 0 &&
              typeof member.latency === 'number' &&
              member.latency !== 0
                ? member.latency
                : rawDelayVal;
            const hasDelay = typeof delayVal === 'number' && delayVal > 0;
            const isFailed = typeof delayVal === 'number' && delayVal <= 0;
            return E('div', { class: 'tachyon_proto-popover__row' }, [
              E(
                'span',
                {
                  class: 'tachyon_proto-popover__key',
                  title: url,
                },
                shortenUrlForPopover(url, idx),
              ),
              E(
                'span',
                {
                  class: `tachyon_proto-popover__val ${getUrlTestLatencyClass(
                    hasDelay ? delayVal : -1,
                  )}`,
                },
                hasDelay ? `${delayVal}ms` : isFailed ? _('timeout') : 'N/A',
              ),
            ]);
          }),
        ),
      ]),
    ],
  );
}

function parseIntervalToSeconds(raw?: string, fallbackSec = 180) {
  const s = `${raw || ''}`.trim().toLowerCase();
  if (!s) return fallbackSec;
  if (/^\d+$/.test(s)) {
    const val = Number(s);
    return val > 0 ? val : fallbackSec;
  }
  let total = 0;
  let matched = false;
  const regex = /(\d+)\s*(h|m|s)/g;
  let m: RegExpExecArray | null;
  while ((m = regex.exec(s)) !== null) {
    matched = true;
    const n = Number(m[1]);
    const unit = m[2];
    if (unit === 'h') total += n * 3600;
    else if (unit === 'm') total += n * 60;
    else total += n;
  }
  return matched && total > 0 ? total : fallbackSec;
}

function formatCountdownSeconds(sec: number) {
  const clamped = Math.max(0, Math.floor(sec));
  if (clamped >= 60) {
    const mins = Math.floor(clamped / 60);
    const rem = clamped % 60;
    return `↻ ${mins}m ${rem}s`;
  }
  return `↻ ${clamped}s`;
}

function renderLiveCheckField(intervalRaw?: string, updatedAtSec?: number) {
  const labelText = `${intervalRaw || '3m'}`.trim() || '3m';
  const intervalSec = parseIntervalToSeconds(labelText, 180);
  const nowSec = Math.floor(Date.now() / 1000);
  const elapsed =
    updatedAtSec && updatedAtSec > 0 && nowSec >= updatedAtSec
      ? (nowSec - updatedAtSec) % intervalSec
      : 0;
  const remaining = Math.max(1, intervalSec - elapsed);

  return E(
    'div',
    { class: 'tachyon_dashboard-page__urltest-details__live-check' },
    [
      E('span', {}, `${_('Every')} ${labelText}`),
      E(
        'span',
        {
          class: 'tachyon_dashboard-page__urltest-details__live-timer',
        },
        formatCountdownSeconds(remaining),
      ),
    ],
  );
}

function getDetectedCountryFlag(country?: string) {
  const code = `${country || ''}`.trim().toUpperCase();

  if (!/^[A-Z]{2}$/.test(code)) {
    return '';
  }

  return String.fromCodePoint(
    ...code.split('').map((char) => 0x1f1e6 + char.charCodeAt(0) - 65),
  );
}

function renderDetailsMemberName(member: Tachyon.UrlTestMember) {
  const countryFlag = getDetectedCountryFlag(member.country);
  const displayTitle = countryFlag
    ? member.displayName
    : ensureOutboundDisplayFlag(member);
  const elements = countryFlag
    ? [
        E(
          'span',
          { class: 'tachyon_dashboard-page__urltest-details__country-badge' },
          countryFlag,
        ),
        ...renderFlagEmojis(displayTitle),
      ]
    : renderFlagEmojis(displayTitle);

  if (member.prefix) {
    const pStyle = resolvePrefixBadgeStyle(member.prefix);
    return [
      ...elements,
      E(
        'span',
        {
          class: 'tachyon_dashboard-page__outbound-grid__item__prefix-badge',
          style: `margin-left: 6px; background: ${pStyle.bg}; color: ${pStyle.color}; border: 1px solid ${pStyle.border}; font-weight: 600; cursor: pointer;`,
          title: _('Click to customize prefix colors'),
          click: (event: MouseEvent) =>
            openPrefixColorPickerModal(member.prefix!, event),
        },
        renderFlagEmojis(member.prefix),
      ),
    ];
  }

  return elements;
}

function renderUrlTestSelectedValue(info: Tachyon.UrlTestInfo) {
  const selectedMember = info.outbounds.find((member) => member.selected);
  const selectedName =
    selectedMember?.displayName || info.selectedName || info.selectedCode || '';
  const name = formatUrlTestModalValue(selectedName);

  if (name === _('No')) {
    return E('span', {}, name);
  }

  const modeBadge = info.isManualSelection
    ? E(
        'span',
        {
          class: 'badge badge-warning',
          style:
            'margin-left: 8px; padding: 2px 6px; font-size: 11px; background: rgba(255, 152, 0, 0.2); color: #ff9800; border-radius: 3px;',
        },
        _('Manual'),
      )
    : E(
        'span',
        {
          class: 'badge badge-info',
          style:
            'margin-left: 8px; padding: 2px 6px; font-size: 11px; background: rgba(33, 150, 243, 0.2); color: #2196f3; border-radius: 3px;',
        },
        _('Auto'),
      );

  return E(
    'span',
    { class: 'tachyon_dashboard-page__urltest-details__selected-value' },
    [
      E(
        'span',
        { class: 'tachyon_dashboard-page__urltest-details__selected-name' },
        selectedMember ? renderDetailsMemberName(selectedMember) : name,
      ),
      ...(selectedMember?.type
        ? [
            renderOutboundTypeWithPopover(
              selectedMember.type,
              selectedMember.transport,
              selectedMember.details,
              'tachyon_dashboard-page__urltest-details__selected-type',
            ),
          ]
        : []),
      ...(selectedMember
        ? [
            E(
              'span',
              { class: getUrlTestLatencyClass(selectedMember.latency) },
              formatUrlTestLatency(selectedMember.latency),
            ),
            ...(renderMemberUrlDelaysPopover(selectedMember, info.urls)
              ? [renderMemberUrlDelaysPopover(selectedMember, info.urls)!]
              : []),
          ]
        : []),
      modeBadge,
      ...(info.fallbackActive
        ? [
            E(
              'span',
              {
                class: 'badge badge-warning',
                title: _(
                  'No server reached all health check URLs; fallback mode is active (best partial match selected).',
                ),
                style:
                  'margin-left: 6px; padding: 2px 6px; font-size: 11px; background: rgba(245, 158, 11, 0.22); color: #f59e0b; border: 1px solid rgba(245, 158, 11, 0.45); border-radius: 3px; display: inline-flex; align-items: center; gap: 3px;',
              },
              [
                renderAlertTriangleIcon(11),
                E(
                  'span',
                  {},
                  `Fallback (${info.passedUrls ?? 1}/${info.totalUrls ?? 2} URL)`,
                ),
              ],
            ),
          ]
        : []),
    ],
  );
}

function renderUrlTestCopyButton(
  title: string,
  onClick: (event: MouseEvent) => void,
) {
  return E(
    'button',
    {
      type: 'button',
      class: 'btn tachyon_dashboard-page__urltest-details__copy-button',
      title,
      'aria-label': title,
      click: onClick,
    },
    renderCopyIcon24(),
  );
}

const modalNodesSortState = new Map<
  string,
  { col: 'name' | 'type' | 'latency'; dir: 'asc' | 'desc' }
>();

function renderCommonDetailsModal(
  info: any,
  fields: Array<{
    label: string;
    value?: unknown;
    children?: Array<HTMLElement | string>;
  }>,
  renderMemberName: (member: any) => any,
  isPriority: boolean,
  section?: Tachyon.OutboundGroup,
  outbound?: Tachyon.Outbound,
) {
  const isManual = Boolean(info.isManualSelection);
  const sortKey = `${section?.code || ''}:${outbound?.code || info.code || ''}`;
  const isRu =
    typeof document !== 'undefined' &&
    (document.documentElement?.lang || '').toLowerCase().startsWith('ru');
  const tableEl = E('div', {
    class: 'tachyon_dashboard-page__urltest-details__table',
  });
  const colInds = new Map<'name' | 'type' | 'latency', HTMLElement>();
  const colBtns = new Map<'name' | 'type' | 'latency', HTMLElement>();

  const populateModalRows = () => {
    const sortState = modalNodesSortState.get(sortKey);
    colInds.forEach((ind, col) => {
      const isActive = Boolean(sortState && sortState.col === col);
      ind.textContent = isActive
        ? sortState!.dir === 'asc'
          ? ' ▲'
          : ' ▼'
        : '';
      colBtns.get(col)?.classList.toggle('is-active', isActive);
    });

    const rawMembers: any[] = Array.isArray(info.outbounds)
      ? [...info.outbounds]
      : [];
    const sortedMembers = sortState
      ? rawMembers.sort((a, b) => {
          let cmp = 0;
          if (sortState.col === 'name') {
            cmp = String(a.displayName || a.code || '').localeCompare(
              String(b.displayName || b.code || ''),
              'ru',
            );
          } else if (sortState.col === 'type') {
            const ta = `${a.type || ''} ${a.transport || ''}`.trim();
            const tb = `${b.type || ''} ${b.transport || ''}`.trim();
            cmp = ta.localeCompare(tb, 'ru');
          } else if (sortState.col === 'latency') {
            const la =
              typeof a.latency === 'number' && a.latency > 0
                ? a.latency
                : a.latency < 0
                  ? 999998
                  : 999999;
            const lb =
              typeof b.latency === 'number' && b.latency > 0
                ? b.latency
                : b.latency < 0
                  ? 999998
                  : 999999;
            cmp = la - lb;
          }
          return sortState.dir === 'asc' ? cmp : -cmp;
        })
      : rawMembers;

    if (!sortedMembers.length) {
      tableEl.replaceChildren(
        E(
          'div',
          { class: 'tachyon_dashboard-page__urltest-details__empty' },
          _('Node list is empty'),
        ),
      );
      return;
    }

    tableEl.replaceChildren(
      ...sortedMembers.map((member: any) => {
        const isMemberActive =
          member.selected || member.code === info.selectedCode;

        return E(
          'div',
          {
            class: [
              'tachyon_dashboard-page__urltest-details__row',
              isMemberActive
                ? 'tachyon_dashboard-page__urltest-details__row--active'
                : '',
            ]
              .filter(Boolean)
              .join(' '),
          },
          [
            E(
              'div',
              {
                class: 'tachyon_dashboard-page__urltest-details__row-name',
              },
              isPriority
                ? [
                    E(
                      'b',
                      {
                        class:
                          'tachyon_dashboard-page__urltest-details__priority-name',
                      },
                      renderMemberName(member),
                    ),
                    ...(member.type
                      ? [
                          renderOutboundTypeWithPopover(
                            member.type,
                            member.transport,
                            member.details,
                            'tachyon_dashboard-page__urltest-details__row-type',
                          ),
                        ]
                      : []),
                  ]
                : [
                    E('b', {}, renderMemberName(member)),
                    ...(member.type
                      ? [
                          renderOutboundTypeWithPopover(
                            member.type,
                            member.transport,
                            member.details,
                            'tachyon_dashboard-page__urltest-details__row-type',
                          ),
                        ]
                      : []),
                  ],
            ),
            E(
              'div',
              {
                class: 'tachyon_dashboard-page__urltest-details__row-actions',
              },
              [
                E(
                  'div',
                  {
                    class: 'tachyon_dashboard-page__urltest-details__row-meta',
                  },
                  [
                    E(
                      'span',
                      {
                        class: getUrlTestLatencyClass(member.latency),
                        style: 'cursor: pointer; user-select: none;',
                        title: _('Click to test latency'),
                        click: async (ev: MouseEvent) => {
                          ev.preventDefault();
                          ev.stopPropagation();
                          const badgeEl =
                            ev.currentTarget as HTMLElement | null;
                          if (badgeEl) {
                            badgeEl.textContent = '…';
                          }
                          const urls = normalizeDetailsUrlList(
                            info.url || info.healthUrl,
                            info.urls || info.healthUrls,
                          );
                          const probeUrls =
                            urls.length > 0
                              ? urls
                              : ['https://www.gstatic.com/generate_204'];
                          const perUrlMap = await probeModalMultiUrlLatencies(
                            [member],
                            probeUrls,
                          );
                          const mDelays = perUrlMap.get(member.code);
                          if (mDelays) {
                            const positive = Object.values(mDelays).filter(
                              (d) => d > 0,
                            );
                            const nextLatency =
                              positive.length > 0 ? Math.max(...positive) : -1;
                            member.latency = nextLatency;
                            member.urlDelays = {
                              ...(member.urlDelays || {}),
                              ...mDelays,
                            };
                            customProxyLatencies.set(member.code, nextLatency);
                            capMapSize(customProxyLatencies);
                          }
                          populateModalRows();
                        },
                      },
                      formatUrlTestLatency(member.latency),
                    ),
                    ...(member.telemetry
                      ? (() => {
                          const t = member.telemetry!;
                          const tipParts: string[] = [];
                          if (t.ewma_rtt_ms)
                            tipParts.push(`EWMA: ${t.ewma_rtt_ms} ${_('ms')}`);
                          if (t.jitter_ms)
                            tipParts.push(
                              `${_('Jitter')}: ±${t.jitter_ms} ${_('ms')}`,
                            );
                          if (t.loss_penalty_ms)
                            tipParts.push(
                              `${_('Penalty')}: +${t.loss_penalty_ms} ${_('ms')}`,
                            );
                          if (t.active_conns)
                            tipParts.push(
                              `${_('Connections')}: ${t.active_conns}`,
                            );
                          if (t.throughput_kib_s)
                            tipParts.push(
                              `${_('Throughput')}: ${t.throughput_kib_s} ${_('KiB/s')}`,
                            );
                          if (t.transferred_kib)
                            tipParts.push(
                              `${_('Traffic')}: ${(t.transferred_kib / 1024).toFixed(1)} ${_('MiB')}`,
                            );
                          if (t.quarantined) {
                            return [
                              E(
                                'span',
                                {
                                  class: 'badge badge-warning',
                                  title: tipParts.join(' · '),
                                  style:
                                    'margin-left: 6px; padding: 1px 5px; font-size: 10px; font-variant-numeric: tabular-nums;',
                                },
                                `${_('Quarantine')} ${t.quarantine_rem_s || 0}${_('s')}`,
                              ),
                            ];
                          }
                          if (
                            tipParts.length > 0 &&
                            (t.jitter_ms ||
                              t.loss_penalty_ms ||
                              t.active_conns ||
                              t.throughput_kib_s)
                          ) {
                            const metricLabels: string[] = [];
                            if (t.jitter_ms) {
                              metricLabels.push(`±${t.jitter_ms} ${_('ms')}`);
                            }
                            if (t.loss_penalty_ms) {
                              metricLabels.push(
                                `+${t.loss_penalty_ms} ${_('ms')}`,
                              );
                            }
                            if (metricLabels.length === 0 && t.active_conns) {
                              metricLabels.push(
                                `${t.active_conns} ${_('conn.')}`,
                              );
                            }
                            if (
                              metricLabels.length === 0 &&
                              t.throughput_kib_s
                            ) {
                              metricLabels.push(
                                `${t.throughput_kib_s} ${_('KiB/s')}`,
                              );
                            }
                            return [
                              E(
                                'span',
                                {
                                  title: tipParts.join(' · '),
                                  style:
                                    'margin-left: 6px; font-size: 11px; opacity: 0.72; font-variant-numeric: tabular-nums;',
                                },
                                metricLabels.join(' · '),
                              ),
                            ];
                          }
                          return [];
                        })()
                      : []),
                    ...(renderMemberUrlDelaysPopover(
                      member,
                      info.urls || info.healthUrls,
                    )
                      ? [
                          renderMemberUrlDelaysPopover(
                            member,
                            info.urls || info.healthUrls,
                          )!,
                        ]
                      : []),
                  ],
                ),
                ...(section && section.withTagSelect
                  ? isMemberActive
                    ? [
                        E(
                          'span',
                          {
                            class:
                              'badge badge-success tachyon_dashboard-page__urltest-details__active-badge',
                          },
                          [
                            svgEl(
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
                              },
                              [
                                svgEl('polyline', {
                                  points: '20 6 9 17 4 12',
                                }),
                              ],
                            ),
                            _('Active'),
                          ],
                        ),
                      ]
                    : isPriority ||
                        section.outbounds.some((o) => o.code === member.code)
                      ? [
                          E(
                            'button',
                            {
                              type: 'button',
                              class:
                                'btn cbi-button cbi-button-action tachyon_dashboard-page__urltest-details__select-btn',
                              click: async (event: MouseEvent) => {
                                event.preventDefault();
                                const btn =
                                  event.currentTarget as HTMLButtonElement | null;
                                if (btn) {
                                  btn.disabled = true;
                                }
                                const targetSelector = isPriority
                                  ? outbound?.code || section.code
                                  : section.code;
                                await handleChooseOutbound(
                                  section.sectionName,
                                  targetSelector,
                                  member.code,
                                );
                                const updatedSection = store
                                  .get()
                                  .sectionsWidget.data.find(
                                    (s) =>
                                      s.sectionName === section.sectionName,
                                  );
                                const updatedOutbound =
                                  updatedSection?.outbounds.find(
                                    (o) => o.code === outbound?.code,
                                  );
                                if (updatedSection && updatedOutbound) {
                                  if (isPriority) {
                                    handleShowPriorityInfo(
                                      updatedSection,
                                      updatedOutbound,
                                    );
                                  } else {
                                    handleShowUrlTestInfo(
                                      updatedSection,
                                      updatedOutbound,
                                    );
                                  }
                                } else {
                                  ui.hideModal();
                                }
                              },
                            },
                            _('Select'),
                          ),
                        ]
                      : []
                  : []),
                (() => {
                  const matchedOutbound = section?.outbounds?.find(
                    (o) =>
                      o.code === member.code ||
                      (member.displayName &&
                        o.displayName === member.displayName),
                  );
                  const effectiveLink = member.link || matchedOutbound?.link;
                  const canCopyMemberLink = Boolean(
                    member.canCopyLink ||
                      matchedOutbound?.canCopyLink ||
                      isCopyableProxyLink(effectiveLink),
                  );
                  return canCopyMemberLink
                    ? renderUrlTestCopyButton(_('Copy proxy link'), (event) => {
                        event.preventDefault();
                        void handleCopyOutbound({
                          ...matchedOutbound,
                          ...member,
                          link: effectiveLink,
                          canCopyLink: true,
                        });
                      })
                    : E('span', {
                        class:
                          'tachyon_dashboard-page__urltest-details__copy-placeholder',
                      });
                })(),
              ],
            ),
          ],
        );
      }),
    );
  };

  const makeSortPill = (col: 'name' | 'type' | 'latency', label: string) => {
    const ind = E('span', { style: 'font-size: 10px; opacity: 0.8;' });
    colInds.set(col, ind);
    const btn = E(
      'button',
      {
        type: 'button',
        class:
          'btn cbi-button tachyon_dashboard-page__urltest-details__sort-pill',
        click: (e: MouseEvent) => {
          e.preventDefault();
          const cur = modalNodesSortState.get(sortKey);
          if (cur && cur.col === col) {
            modalNodesSortState.set(sortKey, {
              col,
              dir: cur.dir === 'asc' ? 'desc' : 'asc',
            });
          } else {
            modalNodesSortState.set(sortKey, { col, dir: 'asc' });
          }
          populateModalRows();
        },
      },
      [E('span', {}, label), ind],
    );
    colBtns.set(col, btn);
    return btn;
  };

  populateModalRows();

  return E('div', { class: 'tachyon_dashboard-page__urltest-details' }, [
    E(
      'dl',
      { class: 'tachyon_dashboard-page__urltest-details__params' },
      fields.map(({ label, value, children }) =>
        E('div', { class: 'tachyon_dashboard-page__urltest-details__param' }, [
          E('dt', {}, label),
          E(
            'dd',
            {},
            children || [E('span', {}, formatUrlTestModalValue(value))],
          ),
        ]),
      ),
    ),
    E('div', { class: 'tachyon_dashboard-page__urltest-details__outbounds' }, [
      E(
        'div',
        {
          class: 'tachyon_dashboard-page__urltest-details__outbounds-title',
          style:
            'display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap; gap: 8px;',
        },
        [
          E('span', {}, _('Nodes')),
          E(
            'div',
            {
              style:
                'display: inline-flex; align-items: center; gap: 6px; flex-wrap: wrap;',
            },
            [
              makeSortPill('name', isRu ? 'Сервер' : _('Server')),
              makeSortPill('type', isRu ? 'Протокол' : _('Protocol')),
              makeSortPill('latency', isRu ? 'Задержка' : _('Latency')),
            ],
          ),
        ],
      ),
      tableEl,
    ]),
    E('div', { class: 'tachyon_dashboard-page__urltest-details__footer' }, [
      ...(section && outbound && isManual
        ? [
            E(
              'button',
              {
                type: 'button',
                class: 'btn cbi-button cbi-button-apply',
                click: async (event: MouseEvent) => {
                  event.preventDefault();
                  const btn = event.currentTarget as HTMLButtonElement | null;
                  if (btn) {
                    btn.disabled = true;
                  }
                  await handleChooseOutbound(
                    section.sectionName,
                    section.code,
                    outbound.code,
                  );
                  const updatedSection = store
                    .get()
                    .sectionsWidget.data.find(
                      (s) => s.sectionName === section.sectionName,
                    );
                  const updatedOutbound = updatedSection?.outbounds.find(
                    (o) => o.code === outbound.code,
                  );
                  if (updatedSection && updatedOutbound) {
                    if (isPriority) {
                      handleShowPriorityInfo(updatedSection, updatedOutbound);
                    } else {
                      handleShowUrlTestInfo(updatedSection, updatedOutbound);
                    }
                  } else {
                    ui.hideModal();
                  }
                },
              },
              _('Switch to auto-selection'),
            ),
          ]
        : []),
      E(
        'button',
        {
          type: 'button',
          class: 'btn cbi-button cbi-button-neutral',
          click: () => {
            if (selectedDashboardSectionCode) {
              openSectionInspectorModal(selectedDashboardSectionCode);
            } else {
              ui.hideModal();
            }
          },
        },
        _('Close'),
      ),
    ]),
  ]);
}

function renderUrlTestInfoModal(
  outbound: Tachyon.Outbound,
  section?: Tachyon.OutboundGroup,
) {
  const info = outbound.urlTestInfo;

  if (!info) {
    return E('div', {}, _('URLTest details are unavailable'));
  }

  const effectiveUrls = normalizeDetailsUrlList(info.url, info.urls);
  const fields: Array<{
    label: string;
    value?: unknown;
    children?: Array<HTMLElement | string>;
  }> = [
    {
      label: _('Selected'),
      children: [renderUrlTestSelectedValue(info)],
    },
    ...(info.mode && info.mode !== 'least_test'
      ? [{ label: _('Algorithm'), value: formatBalancerModeLabel(info.mode) }]
      : []),
    {
      label: effectiveUrls.length > 1 ? _('Testing URLs') : _('Testing URL'),
      children: [renderDetailsUrls(info.url, info.urls)],
    },
    ...(effectiveUrls.length > 1 || info.multiUrlStrategy
      ? [
          {
            label: _('Multi-URL strategy'),
            value: formatMultiUrlStrategyLabel(info.multiUrlStrategy),
          },
        ]
      : []),
    {
      label: _('Live check'),
      children: [
        renderLiveCheckField(
          info.activeCheckInterval || info.interval,
          info.updatedAt,
        ),
      ],
    },
    { label: _('Interval'), value: info.interval },
    {
      label: _('Tolerance'),
      value:
        info.tolerance != null && /^\d+$/.test(String(info.tolerance).trim())
          ? `${String(info.tolerance).trim()} ms`
          : info.tolerance,
    },
    { label: _('Idle timeout'), value: info.idleTimeout },
    {
      label: _('Interrupt connections'),
      value: info.interruptExistConnections,
    },
  ];

  return renderCommonDetailsModal(
    info,
    fields,
    (member) => renderDetailsMemberName(member),
    false,
    section,
    outbound,
  );
}

function applyPriorityDaemonStatusToInfo(
  info: Tachyon.UrlTestInfo | Tachyon.PriorityInfo,
  st: Record<string, any>,
) {
  let changed = false;
  if (st.fallback_active !== undefined) {
    info.fallbackActive = Boolean(st.fallback_active);
    info.passedUrls = Number(st.passed_urls || 0);
    info.totalUrls = Number(st.total_urls || 0);
    changed = true;
  }
  if (typeof st.updated_at === 'number' && st.updated_at > 0) {
    info.updatedAt = st.updated_at;
    changed = true;
  }
  if (
    typeof st.active_check_interval === 'string' &&
    st.active_check_interval
  ) {
    info.activeCheckInterval = st.active_check_interval;
    changed = true;
  }
  if (Array.isArray(st.urls) && st.urls.length > 0) {
    if ('urls' in info || !('healthUrls' in info)) {
      (info as Tachyon.UrlTestInfo).urls = st.urls.filter(Boolean);
    } else {
      (info as Tachyon.PriorityInfo).healthUrls = st.urls.filter(Boolean);
    }
    changed = true;
  }
  if (st.url_delays && typeof st.url_delays === 'object') {
    const delaysMap = st.url_delays as Record<string, Record<string, number>>;
    info.outbounds = (info.outbounds || []).map((member) => {
      const mDelays = delaysMap[member.code];
      if (mDelays && typeof mDelays === 'object') {
        changed = true;
        const positive = Object.values(mDelays).filter(
          (d): d is number => typeof d === 'number' && d > 0,
        );
        const derivedLatency =
          (!member.latency || member.latency === 0) && positive.length > 0
            ? Math.max(...positive)
            : member.latency;
        if (derivedLatency && derivedLatency > 0) {
          customProxyLatencies.set(member.code, derivedLatency);
        }
        return {
          ...member,
          latency: derivedLatency,
          urlDelays: { ...(member.urlDelays || {}), ...mDelays },
        };
      }
      return member;
    });
  }
  return changed;
}

async function probeModalMultiUrlLatencies(
  members: Tachyon.UrlTestMember[],
  urls: string[],
  groupTag?: string,
  onProgress?: (partial: Map<string, Record<string, number>>) => void,
): Promise<Map<string, Record<string, number>>> {
  const result = new Map<string, Record<string, number>>();
  const cleanUrls = urls.map((u) => `${u || ''}`.trim()).filter(Boolean);
  if (cleanUrls.length === 0 || !members.length) {
    return result;
  }

  const memberTags = members
    .map((m) => `${m.code || ''}`.trim())
    .filter(Boolean);
  const cleanGroupTag = `${groupTag || ''}`.trim();

  if (cleanGroupTag && memberTags.length > 1) {
    const fallbackTasks: Array<{ tag: string; url: string }> = [];
    for (const url of cleanUrls) {
      let batchMap: Record<string, number> | null = null;
      try {
        const batchRes = await TachyonShellMethods.getClashApiGroupLatency(
          cleanGroupTag,
          '3500',
          url,
        );
        if (
          batchRes.success &&
          batchRes.data &&
          typeof batchRes.data === 'object'
        ) {
          const rawData = batchRes.data as any;
          const delaysObj =
            rawData.delays && typeof rawData.delays === 'object'
              ? rawData.delays
              : rawData;
          if (delaysObj && typeof delaysObj === 'object') {
            batchMap = {};
            for (const [k, v] of Object.entries(delaysObj)) {
              if (k === 'success' || k === 'error') continue;
              const num = Number(v);
              if (Number.isFinite(num) && num > 0) {
                batchMap[k] = num;
              }
            }
          }
        }
      } catch {
        batchMap = null;
      }

      if (batchMap && Object.keys(batchMap).length > 0) {
        for (const tag of memberTags) {
          const d = batchMap[tag];
          if (typeof d === 'number' && d > 0) {
            const mapForTag = result.get(tag) || {};
            mapForTag[url] = d;
            result.set(tag, mapForTag);
          } else {
            fallbackTasks.push({ tag, url });
          }
        }
        onProgress?.(result);
      } else {
        for (const tag of memberTags) {
          fallbackTasks.push({ tag, url });
        }
      }
    }

    if (fallbackTasks.length > 0) {
      let fIdx = 0;
      const fConc = Math.min(6, fallbackTasks.length);
      const fWorker = async () => {
        while (fIdx < fallbackTasks.length) {
          const current = fallbackTasks[fIdx++];
          try {
            const res = await TachyonShellMethods.getClashApiProxyLatency(
              current.tag,
              '2500',
              current.url,
            );
            const delayVal =
              res.success &&
              res.data &&
              typeof (res.data as any).delay === 'number' &&
              (res.data as any).delay > 0
                ? Number((res.data as any).delay)
                : -1;
            const mapForTag = result.get(current.tag) || {};
            mapForTag[current.url] = delayVal;
            result.set(current.tag, mapForTag);
          } catch {
            const mapForTag = result.get(current.tag) || {};
            mapForTag[current.url] = -1;
            result.set(current.tag, mapForTag);
          }
        }
      };
      await Promise.all(Array.from({ length: fConc }, fWorker));
      onProgress?.(result);
    }
    return result;
  }

  const tasks: Array<{ tag: string; url: string }> = [];
  for (const tag of memberTags) {
    for (const url of cleanUrls) {
      tasks.push({ tag, url });
    }
  }

  let idx = 0;
  const concurrency = Math.min(6, tasks.length);
  const worker = async () => {
    while (idx < tasks.length) {
      const current = tasks[idx++];
      try {
        const res = await TachyonShellMethods.getClashApiProxyLatency(
          current.tag,
          '2500',
          current.url,
        );
        const delayVal =
          res.success &&
          res.data &&
          typeof (res.data as any).delay === 'number' &&
          (res.data as any).delay > 0
            ? Number((res.data as any).delay)
            : -1;
        const mapForTag = result.get(current.tag) || {};
        mapForTag[current.url] = delayVal;
        result.set(current.tag, mapForTag);
      } catch {
        const mapForTag = result.get(current.tag) || {};
        mapForTag[current.url] = -1;
        result.set(current.tag, mapForTag);
      }
    }
  };

  await Promise.all(Array.from({ length: concurrency }, worker));
  onProgress?.(result);
  return result;
}

function attachModalLiveCheckTimer(
  body: HTMLElement,
  intervalRaw: string | undefined,
  onCycleTriggered: () => Promise<void>,
) {
  if (typeof window === 'undefined') return;
  const intervalSec = parseIntervalToSeconds(intervalRaw, 180);
  let remaining = intervalSec;
  let probing = false;

  const timerId = window.setInterval(() => {
    if (!body.isConnected) {
      window.clearInterval(timerId);
      return;
    }
    const badge = body.querySelector<HTMLElement>(
      '.tachyon_dashboard-page__urltest-details__live-timer',
    );
    if (probing) {
      if (badge) badge.textContent = `↻ ${_('checking...')}`;
      return;
    }
    remaining -= 1;
    if (remaining <= 0) {
      remaining = intervalSec;
      probing = true;
      if (badge) badge.textContent = `↻ ${_('checking...')}`;
      void onCycleTriggered().finally(() => {
        probing = false;
        remaining = intervalSec;
      });
      return;
    }
    if (badge) {
      badge.textContent = formatCountdownSeconds(remaining);
    }
  }, 1000);
}

function syncUrlTestMembersWithLatencies(
  info: Tachyon.UrlTestInfo,
  section?: Tachyon.OutboundGroup,
  outbound?: Tachyon.Outbound,
) {
  const secOutboundByCode = new Map<string, Tachyon.Outbound>();
  (section?.outbounds || []).forEach((ob) => {
    secOutboundByCode.set(ob.code, ob);
  });

  info.outbounds = (info.outbounds || []).map((member) => {
    const customLat = customProxyLatencies.get(member.code);
    const secLat = secOutboundByCode.get(member.code)?.latency;
    const isSelected = member.selected || member.code === info.selectedCode;
    let nextLatency =
      customLat !== undefined
        ? customLat
        : typeof member.latency === 'number' && member.latency !== 0
          ? member.latency
          : typeof secLat === 'number' && secLat !== 0
            ? secLat
            : 0;
    if (
      nextLatency === 0 &&
      isSelected &&
      outbound &&
      typeof outbound.latency === 'number' &&
      outbound.latency > 0
    ) {
      nextLatency = outbound.latency;
    }
    return nextLatency !== member.latency
      ? { ...member, latency: nextLatency }
      : member;
  });
}

function handleShowUrlTestInfo(
  section: Tachyon.OutboundGroup,
  outbound: Tachyon.Outbound,
) {
  if (!outbound.urlTestInfo) {
    return;
  }

  const info = outbound.urlTestInfo;
  syncUrlTestMembersWithLatencies(info, section, outbound);
  const body = E('div', {}, [renderUrlTestInfoModal(outbound, section)]);

  ui.showModal(
    `${_('URLTest details')}: ${
      outbound.urlTestInfo.displayName || outbound.displayName
    }`,
    body,
  );

  const repaintModal = () => {
    if (!body.isConnected) return;
    if (body.querySelector('.tachyon_proto-popover-trigger:hover')) return;
    syncUrlTestMembersWithLatencies(info, section, outbound);
    body.replaceChildren(
      renderUrlTestInfoModal(
        { ...outbound, urlTestInfo: { ...info } },
        section,
      ),
    );
  };

  const applyPerUrlMapToInfo = (
    perUrlMap: Map<string, Record<string, number>>,
  ) => {
    if (!body.isConnected || perUrlMap.size === 0) return;
    info.updatedAt = Math.floor(Date.now() / 1000);
    info.outbounds = (info.outbounds || []).map((member) => {
      const mDelays = perUrlMap.get(member.code);
      if (!mDelays) return member;
      const mergedUrlDelays = { ...(member.urlDelays || {}), ...mDelays };
      const positive = Object.values(mergedUrlDelays).filter((d) => d > 0);
      const nextLatency =
        positive.length > 0
          ? Math.max(...positive)
          : member.latency > 0
            ? member.latency
            : -1;
      if (nextLatency !== 0) {
        customProxyLatencies.set(member.code, nextLatency);
      }
      return {
        ...member,
        latency: nextLatency,
        urlDelays: mergedUrlDelays,
      };
    });
    capMapSize(customProxyLatencies);
    repaintModal();
  };

  const runLiveMultiUrlProbe = async () => {
    const urls = normalizeDetailsUrlList(info.url, info.urls);
    const probeUrls =
      urls.length > 0 ? urls : ['https://www.gstatic.com/generate_204'];
    if (!body.isConnected) return;
    const perUrlMap = await probeModalMultiUrlLatencies(
      info.outbounds || [],
      probeUrls,
      info.code,
      (partial) => applyPerUrlMapToInfo(partial),
    );
    applyPerUrlMapToInfo(perUrlMap);
  };

  if (typeof fs !== 'undefined' && typeof fs.read === 'function' && info.code) {
    const encCode = encodeURIComponent(info.code);
    fs.read(`/var/run/tachyon/priority/${encCode}.json`)
      .catch(() => fs.read(`/tmp/run/tachyon/priority/${encCode}.json`))
      .then((raw) => {
        if (!raw || !body.isConnected) return;
        const st = JSON.parse(raw);
        if (
          st &&
          typeof st === 'object' &&
          applyPriorityDaemonStatusToInfo(info, st)
        ) {
          repaintModal();
        }
      })
      .catch(() => {})
      .finally(() => {
        const urls = normalizeDetailsUrlList(info.url, info.urls);
        const hasMissingUrlDelays =
          urls.length > 1 &&
          urls.some((u) =>
            (info.outbounds || []).some(
              (m) => !m.urlDelays || m.urlDelays[u] === undefined,
            ),
          );
        const hasMissingLatencies = (info.outbounds || []).some(
          (m) => !m.latency || m.latency === 0,
        );
        if (hasMissingUrlDelays || hasMissingLatencies) {
          void runLiveMultiUrlProbe();
        }
      });
  } else {
    const urls = normalizeDetailsUrlList(info.url, info.urls);
    const hasMissingLatencies = (info.outbounds || []).some(
      (m) => !m.latency || m.latency === 0,
    );
    if (urls.length > 1 || hasMissingLatencies) {
      void runLiveMultiUrlProbe();
    }
  }

  attachModalLiveCheckTimer(
    body,
    info.activeCheckInterval || info.interval,
    runLiveMultiUrlProbe,
  );
}

function renderPrioritySelectedValue(info: Tachyon.PriorityInfo) {
  const selectedMember = info.outbounds.find((member) => member.selected);
  const selectedName =
    selectedMember?.displayName || info.selectedName || info.selectedCode || '';
  const name = formatUrlTestModalValue(selectedName);

  if (name === _('No')) {
    return E('span', {}, name);
  }

  const modeBadge = info.isManualSelection
    ? E(
        'span',
        {
          class: 'badge badge-warning',
          style:
            'margin-left: 8px; padding: 2px 6px; font-size: 11px; background: rgba(255, 152, 0, 0.2); color: #ff9800; border-radius: 3px;',
        },
        _('Manual'),
      )
    : E(
        'span',
        {
          class: 'badge badge-info',
          style:
            'margin-left: 8px; padding: 2px 6px; font-size: 11px; background: rgba(33, 150, 243, 0.2); color: #2196f3; border-radius: 3px;',
        },
        _('Auto'),
      );

  return E(
    'span',
    { class: 'tachyon_dashboard-page__urltest-details__selected-value' },
    [
      E(
        'span',
        {
          class: [
            'tachyon_dashboard-page__urltest-details__selected-name',
            selectedMember
              ? 'tachyon_dashboard-page__urltest-details__priority-name'
              : '',
          ]
            .filter(Boolean)
            .join(' '),
        },
        selectedMember ? renderPriorityMemberName(selectedMember) : name,
      ),
      ...(selectedMember?.type
        ? [
            renderOutboundTypeWithPopover(
              selectedMember.type,
              selectedMember.transport,
              selectedMember.details,
              'tachyon_dashboard-page__urltest-details__selected-type',
            ),
          ]
        : []),
      ...(selectedMember
        ? [
            E(
              'span',
              { class: getUrlTestLatencyClass(selectedMember.latency) },
              formatUrlTestLatency(selectedMember.latency),
            ),
            ...(renderMemberUrlDelaysPopover(selectedMember, info.healthUrls)
              ? [renderMemberUrlDelaysPopover(selectedMember, info.healthUrls)!]
              : []),
          ]
        : []),
      modeBadge,
      ...(info.fallbackActive
        ? [
            E(
              'span',
              {
                class: 'badge badge-warning',
                title: _(
                  'No server reached all health check URLs; fallback mode is active (best partial match selected).',
                ),
                style:
                  'margin-left: 6px; padding: 2px 6px; font-size: 11px; background: rgba(245, 158, 11, 0.22); color: #f59e0b; border: 1px solid rgba(245, 158, 11, 0.45); border-radius: 3px; display: inline-flex; align-items: center; gap: 3px;',
              },
              [
                renderAlertTriangleIcon(11),
                E(
                  'span',
                  {},
                  `Fallback (${info.passedUrls ?? 1}/${info.totalUrls ?? 2} URL)`,
                ),
              ],
            ),
          ]
        : []),
    ],
  );
}

function renderPriorityMemberName(member: Tachyon.PriorityMember) {
  const countryFlag = getDetectedCountryFlag(member.country);
  const displayTitle = countryFlag
    ? member.displayName
    : ensureOutboundDisplayFlag(member);
  const flagElements = countryFlag
    ? [
        E(
          'span',
          { class: 'tachyon_dashboard-page__urltest-details__country-badge' },
          countryFlag,
        ),
      ]
    : [];

  const elements = [
    ...flagElements,
    E(
      'span',
      { class: 'tachyon_dashboard-page__urltest-details__priority-level' },
      `[${member.levelName}]`,
    ),
    ...renderFlagEmojis(displayTitle),
  ];

  if (member.prefix) {
    const pStyle = resolvePrefixBadgeStyle(member.prefix);
    return [
      ...elements,
      E(
        'span',
        {
          class: 'tachyon_dashboard-page__outbound-grid__item__prefix-badge',
          style: `margin-left: 6px; background: ${pStyle.bg}; color: ${pStyle.color}; border: 1px solid ${pStyle.border}; font-weight: 600; cursor: pointer;`,
          title: _('Click to customize prefix colors'),
          click: (event: MouseEvent) =>
            openPrefixColorPickerModal(member.prefix!, event),
        },
        renderFlagEmojis(member.prefix),
      ),
    ];
  }

  return elements;
}

function renderPriorityInfoModal(
  outbound: Tachyon.Outbound,
  section?: Tachyon.OutboundGroup,
) {
  const info = outbound.priorityInfo;

  if (!info) {
    return E('div', {}, _('Priority details are unavailable'));
  }

  const effectiveUrls = normalizeDetailsUrlList(
    info.healthUrl,
    info.healthUrls,
  );
  const fields: Array<{
    label: string;
    value?: unknown;
    children?: Array<HTMLElement | string>;
  }> = [
    {
      label: _('Selected'),
      children: [renderPrioritySelectedValue(info)],
    },
    {
      label: effectiveUrls.length > 1 ? _('Check URLs') : _('Check URL'),
      children: [renderDetailsUrls(info.healthUrl, info.healthUrls)],
    },
    ...(effectiveUrls.length > 1 || info.multiUrlStrategy
      ? [
          {
            label: _('Multi-URL strategy'),
            value: formatMultiUrlStrategyLabel(info.multiUrlStrategy),
          },
        ]
      : []),
    {
      label: _('Live check'),
      children: [
        renderLiveCheckField(info.activeCheckInterval, info.updatedAt),
      ],
    },
    {
      label: _('Check interval'),
      value: info.activeCheckInterval,
    },
    { label: _('Unavailability timeout'), value: info.checkTimeout },
    {
      label: _('Higher-level check interval'),
      value: info.recoveryCheckInterval,
    },
    {
      label: _('Select the fastest node'),
      value: info.pickFastest,
    },
    {
      label: _('Automatically select the fastest node in the current level'),
      value: info.switchToFasterSamePriority,
    },
    ...(info.switchToFasterSamePriority
      ? [
          {
            label: _('Faster server search interval'),
            value: info.fastestCheckInterval,
          },
        ]
      : []),
    {
      label: _('Interrupt connections'),
      value: info.interruptExistConnections,
    },
  ];

  return renderCommonDetailsModal(
    info,
    fields,
    (member) => renderPriorityMemberName(member),
    true,
    section,
    outbound,
  );
}

function handleShowPriorityInfo(
  section: Tachyon.OutboundGroup,
  outbound: Tachyon.Outbound,
) {
  if (!outbound.priorityInfo) {
    return;
  }

  const info = outbound.priorityInfo;
  const body = E('div', {}, [renderPriorityInfoModal(outbound, section)]);

  ui.showModal(
    `${_('Priority details')}: ${
      outbound.priorityInfo.displayName || outbound.displayName
    }`,
    body,
  );

  const repaintModal = () => {
    if (!body.isConnected) return;
    if (body.querySelector('.tachyon_proto-popover-trigger:hover')) return;
    body.replaceChildren(
      renderPriorityInfoModal(
        { ...outbound, priorityInfo: { ...info } },
        section,
      ),
    );
  };

  if (typeof fs !== 'undefined' && typeof fs.read === 'function' && info.code) {
    const encCode = encodeURIComponent(info.code);
    fs.read(`/var/run/tachyon/priority/${encCode}.json`)
      .catch(() => fs.read(`/tmp/run/tachyon/priority/${encCode}.json`))
      .then((raw) => {
        if (!raw || !body.isConnected) return;
        const st = JSON.parse(raw);
        if (
          st &&
          typeof st === 'object' &&
          applyPriorityDaemonStatusToInfo(info, st)
        ) {
          repaintModal();
        }
      })
      .catch(() => {});
  }

  // A priority group is a plain selector over raw server tags, so sing-box never
  // measures it and every fallback-level node reads N/A - even though the members
  // are reachable and the priority daemon probes them on its own schedule. Ask the
  // same Clash API the daemon asks, then repaint the modal with the numbers.
  void measurePriorityLatencies(info.outbounds || [], {
    healthUrl: info.healthUrl,
    existing: customProxyLatencies,
    probe: (tag, timeout) =>
      TachyonShellMethods.getClashApiProxyLatency(tag, timeout),
    // The core says what failed: the dial, the tls handshake, the status the
    // server answered with. "An error occurred in the delay test" on its own
    // leaves the user with nothing to act on.
    onFailure: (tag, reason) => {
      showToast(`${tag}: ${reason}`, 'error');
    },
  }).then((measured) => {
    if (measured.size === 0 || !body.isConnected) {
      return;
    }

    measured.forEach((delay, tag) => {
      customProxyLatencies.set(tag, delay);
    });
    capMapSize(customProxyLatencies);

    info.outbounds = (info.outbounds || []).map((member) => {
      const delay = measured.get(String(member.code || ''));
      return delay === undefined ? member : { ...member, latency: delay };
    });

    repaintModal();
  });

  attachModalLiveCheckTimer(body, info.activeCheckInterval, async () => {
    const urls = normalizeDetailsUrlList(info.healthUrl, info.healthUrls);
    if (urls.length === 0 || !body.isConnected) return;
    const perUrlMap = await probeModalMultiUrlLatencies(
      info.outbounds || [],
      urls,
    );
    if (!body.isConnected || perUrlMap.size === 0) return;
    info.updatedAt = Math.floor(Date.now() / 1000);
    info.outbounds = (info.outbounds || []).map((member) => {
      const mDelays = perUrlMap.get(member.code);
      if (!mDelays) return member;
      const positive = Object.values(mDelays).filter((d) => d > 0);
      const nextLatency =
        positive.length > 0 ? Math.max(...positive) : member.latency;
      return {
        ...member,
        latency: nextLatency,
        urlDelays: { ...(member.urlDelays || {}), ...mDelays },
      };
    });
    repaintModal();
  });
}

async function handleUpdateSubscription(section: Tachyon.OutboundGroup) {
  if (
    store.get().sectionsWidget.subscriptionUpdatingSections[section.sectionName]
  ) {
    return;
  }

  setSubscriptionUpdating(section.sectionName, true, true);
  let jobId = '';
  let ownsJobFollow = false;

  try {
    const startResponse = await TachyonShellMethods.subscriptionUpdateStart(
      section.sectionName,
    );

    if (!startResponse.success) {
      throw new Error(startResponse.error);
    }

    jobId = startResponse.data.job_id;
    markUiActionOwned('subscription', jobId);
    if (followedSubscriptionJobs.has(jobId)) {
      return;
    }

    followedSubscriptionJobs.add(jobId);
    ownsJobFollow = true;
    const response = await TachyonShellMethods.waitSubscriptionUpdateJob(jobId);
    await completeSubscriptionUpdateJob(jobId, section.sectionName, response);
  } catch (error) {
    logger.error('[DASHBOARD]', 'handleUpdateSubscription: failed', error);
    if (!pageUnloading) {
      const message =
        error instanceof Error
          ? error.message
          : _('Failed to update subscriptions');

      setSubscriptionUpdating(section.sectionName, false);
      if (!isTransientRpcError(message)) {
        showToast(_('Failed to update subscriptions'), 'error');
      }
    }
  } finally {
    if (ownsJobFollow) {
      followedSubscriptionJobs.delete(jobId);
    }
  }
}

function shallowRecordEqual<T>(
  left: Record<string, T>,
  right: Record<string, T>,
) {
  const leftKeys = Object.keys(left);
  const rightKeys = Object.keys(right);

  if (leftKeys.length !== rightKeys.length) {
    return false;
  }

  return leftKeys.every((key) => left[key] === right[key]);
}

function canUpdateLatencyProgressInline(
  prev: StoreType['sectionsWidget'],
  next: StoreType['sectionsWidget'],
) {
  return (
    prev.loading === next.loading &&
    prev.failed === next.failed &&
    prev.data === next.data &&
    shallowRecordEqual(
      prev.latencyFetchingSections,
      next.latencyFetchingSections,
    ) &&
    shallowRecordEqual(
      prev.subscriptionUpdatingSections,
      next.subscriptionUpdatingSections,
    ) &&
    shallowRecordEqual(
      prev.selectorSwitchingSections,
      next.selectorSwitchingSections,
    )
  );
}

function findLatencyTestButton(container: HTMLElement, sectionName: string) {
  const modalRoot = document.getElementById('tachyon-section-inspector-modal');
  const roots = modalRoot ? [modalRoot, container] : [container];
  for (const root of roots) {
    const found = Array.from(
      root.querySelectorAll<HTMLButtonElement>(`.${LATENCY_TEST_BUTTON_CLASS}`),
    ).find((button) => button.dataset.latencySection === sectionName);
    if (found) return found;
  }
  return undefined;
}

function updateLatencyProgressInline(
  sectionsWidget: StoreType['sectionsWidget'],
) {
  const container = document.getElementById('dashboard-sections-grid');

  if (!container) {
    return false;
  }

  for (const section of sectionsWidget.data) {
    if (!sectionsWidget.latencyFetchingSections[section.sectionName]) {
      continue;
    }

    const button = findLatencyTestButton(container, section.sectionName);
    const label = button?.querySelector<HTMLElement>(
      `.${LATENCY_TEST_BUTTON_LABEL_CLASS}`,
    );

    if (!label) {
      return false;
    }

    const isConnectionNode =
      !section.withTagSelect &&
      [
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
      ].includes(section.action || '');

    const text = isConnectionNode
      ? _('Checking Connection...')
      : getLatencyTestLabel(
          sectionsWidget.latencyProgressSections[section.sectionName],
        );

    if (label.textContent !== text) {
      label.textContent = text;
    }
  }

  return true;
}

// Renderer

let sectionsRenderFrame: number | null = null;
function scheduleSectionsWidgetRender() {
  if (sectionsRenderFrame !== null) return;
  const schedule = isUserActivelyScrolling()
    ? (cb: () => void) => setTimeout(cb, 250)
    : typeof requestAnimationFrame !== 'undefined'
      ? requestAnimationFrame
      : (cb: () => void) => setTimeout(cb, 16);
  sectionsRenderFrame = schedule(() => {
    sectionsRenderFrame = null;
    void renderSectionsWidget();
  }) as unknown as number;
}

function getSectionsWithCustomLatencies(): Tachyon.OutboundGroup[] {
  const sectionsWidget = store.get().sectionsWidget;

  return sectionsWidget.data.map((section) => {
    const skipSectionLatency = isServiceGroup(section);
    const sortMode = section.dashboardSettings?.sortMode || 'latency';
    const mappedOutbounds = section.outbounds.map((outbound) => {
      if (skipSectionLatency || isNonTestableOutboundType(outbound.type)) {
        return {
          ...outbound,
          latency: 0,
        };
      }
      const customLatency = customProxyLatencies.get(outbound.code);
      let latency = customLatency == null ? outbound.latency : customLatency;

      const urlTestInfo = outbound.urlTestInfo
        ? (() => {
            const membersWithLatency = outbound.urlTestInfo.outbounds.map(
              (member) => ({
                ...member,
                latency: customProxyLatencies.has(member.code)
                  ? customProxyLatencies.get(member.code)!
                  : member.latency,
              }),
            );
            const sortedMembers = sortUrlTestMembers(membersWithLatency);
            let selectedCode = outbound.urlTestInfo.selectedCode;
            let selectedName = outbound.urlTestInfo.selectedName;
            const currentSelectedMember = sortedMembers.find(
              (m) => m.code === selectedCode,
            );
            const bestAliveMember = sortedMembers.find((m) => m.latency > 0);
            if (
              bestAliveMember &&
              (!currentSelectedMember || currentSelectedMember.latency <= 0)
            ) {
              selectedCode = bestAliveMember.code;
              selectedName = bestAliveMember.displayName;
            }
            const activeMember = sortedMembers.find(
              (m) => m.code === selectedCode,
            );
            if (activeMember && activeMember.latency !== 0) {
              latency = activeMember.latency;
            }
            return {
              ...outbound.urlTestInfo,
              selectedCode,
              selectedName,
              outbounds: sortedMembers.map((m) => ({
                ...m,
                selected: m.code === selectedCode,
              })),
            };
          })()
        : undefined;

      const priorityInfo = outbound.priorityInfo
        ? {
            ...outbound.priorityInfo,
            outbounds: outbound.priorityInfo.outbounds.map((member) => ({
              ...member,
              latency: customProxyLatencies.has(member.code)
                ? customProxyLatencies.get(member.code)!
                : member.latency,
            })),
          }
        : undefined;

      return {
        ...outbound,
        latency,
        urlTestInfo,
        priorityInfo,
      };
    });

    return {
      ...section,
      outbounds: skipSectionLatency
        ? mappedOutbounds
        : sortOutboundsForDashboard(mappedOutbounds, {
            sortByLatency: sortMode !== 'default',
            sortMode,
          }),
    };
  });
}

function renderSectionInspectorModalContent(
  section: Tachyon.OutboundGroup,
  allSections: Tachyon.OutboundGroup[],
  proxySectionCount: number,
): HTMLElement {
  const sectionsWidget = store.get().sectionsWidget;
  const bwData = store.get().bandwidthWidget.data;
  const totData = store.get().trafficTotalWidget.data;

  const sectionSwitcher =
    allSections.length > 1
      ? E(
          'div',
          { class: 'tachyon-sec-modal__switcher' },
          allSections.map((sec) => {
            const isSelected = sec.code === section.code;
            return E(
              'button',
              {
                type: 'button',
                class: `tachyon-sec-modal__switch-pill ${
                  isSelected ? 'is-active' : ''
                }`,
                click: (e: MouseEvent) => {
                  e.preventDefault();
                  selectedDashboardSectionCode = sec.code;
                  openSectionInspectorModal(sec.code);
                  void renderSectionsWidget();
                },
              },
              renderFlagEmojis(sec.displayName || sec.sectionName || sec.code),
            );
          }),
        )
      : null;

  const tabsBar = E('div', { class: 'tachyon-sec-accordion__tabs' }, [
    E(
      'button',
      {
        type: 'button',
        class: `btn cbi-button tachyon-sec-accordion__tab-btn ${
          activeSectionModalTab === 'nodes' ? 'is-active' : ''
        }`,
        click: (e: MouseEvent) => {
          e.preventDefault();
          activeSectionModalTab = 'nodes';
          openSectionInspectorModal(section.code);
        },
      },
      [E('span', {}, tr('Узлы и балансировщики', 'Nodes & Balancers'))],
    ),
    E(
      'button',
      {
        type: 'button',
        class: `btn cbi-button tachyon-sec-accordion__tab-btn ${
          activeSectionModalTab === 'conditions' ? 'is-active' : ''
        }`,
        click: (e: MouseEvent) => {
          e.preventDefault();
          activeSectionModalTab = 'conditions';
          openSectionInspectorModal(section.code);
        },
      },
      [E('span', {}, tr('Условия и правила', 'Conditions & Rules'))],
    ),
  ]);

  const currentNodesViewMode = getDashboardNodesViewMode();
  const hasServerNodes =
    !isServiceGroup(section) &&
    Boolean(
      (section.outbounds || []).some((o) => !o.urlTestInfo && !o.priorityInfo),
    );
  const isSubUpdating = Boolean(
    sectionsWidget.subscriptionUpdatingSections[section.sectionName],
  );
  const isLatFetching = Boolean(
    sectionsWidget.latencyFetchingSections[section.sectionName],
  );
  const latProgress =
    sectionsWidget.latencyProgressSections[section.sectionName];

  const renderNodesHeaderControls = (inModal: boolean): HTMLElement[] => {
    const controls: HTMLElement[] = [];
    if (hasServerNodes) {
      controls.push(
        E('div', { class: 'tachyon-nodes-view-switch' }, [
          E(
            'button',
            {
              type: 'button',
              class: `btn cbi-button tachyon-nodes-view-switch__btn ${
                currentNodesViewMode === 'table' ? 'is-active' : ''
              }`,
              click: (e: MouseEvent) => {
                e.preventDefault();
                setDashboardNodesViewMode('table');
                if (inModal) {
                  openSectionInspectorModal(section.code);
                } else {
                  void renderSectionsWidget(true);
                }
              },
            },
            [renderListIcon(12), E('span', {}, tr('Таблица', 'Table'))],
          ),
          E(
            'button',
            {
              type: 'button',
              class: `btn cbi-button tachyon-nodes-view-switch__btn ${
                currentNodesViewMode === 'tiles' ? 'is-active' : ''
              }`,
              click: (e: MouseEvent) => {
                e.preventDefault();
                setDashboardNodesViewMode('tiles');
                if (inModal) {
                  openSectionInspectorModal(section.code);
                } else {
                  void renderSectionsWidget(true);
                }
              },
            },
            [renderLayoutGridIcon(12), E('span', {}, tr('Плитки', 'Tiles'))],
          ),
        ]),
      );
    }
    if ((section.subscriptionSourceCount || 0) > 0) {
      controls.push(
        E(
          'button',
          {
            type: 'button',
            class: 'btn cbi-button tachyon-sec-accordion__action-btn',
            disabled: isSubUpdating ? true : undefined,
            click: (e: MouseEvent) => {
              e.preventDefault();
              if (!isSubUpdating) {
                void handleUpdateSubscription(section);
              }
            },
          },
          isSubUpdating
            ? [renderLoaderCircleIcon24(), E('span', {}, _('Updating...'))]
            : [
                renderRefreshCwIcon(13),
                E('span', {}, _('Update subscriptions')),
              ],
        ),
      );
    }
    if (
      !isServiceGroup(section) &&
      (section.withTagSelect ||
        (section.outbounds && section.outbounds.length > 0))
    ) {
      controls.push(
        E(
          'button',
          {
            type: 'button',
            class: 'btn cbi-button tachyon-sec-accordion__action-btn',
            disabled: isLatFetching ? true : undefined,
            click: (e: MouseEvent) => {
              e.preventDefault();
              if (isLatFetching) return;
              if (section.withTagSelect) {
                const tag = section.latencyTestCodes?.length
                  ? section.latencyTestCodes
                  : section.latencyTestCode || section.code;
                if (Array.isArray(tag)) {
                  const serializedTag = serializeSectionLatencyTag(
                    section,
                    tag,
                  );
                  void handleTestLatency(
                    'proxy_list',
                    section.sectionName,
                    serializedTag,
                    section.latencyTestTimeout,
                  );
                } else {
                  void handleTestLatency(
                    'group',
                    section.sectionName,
                    tag,
                    section.latencyTestTimeout,
                  );
                }
              } else {
                const testable = (section.outbounds || []).filter(
                  (o) => !isNonTestableOutboundType(o.type),
                );
                if (testable.length) {
                  void handleTestLatency(
                    'proxy',
                    section.sectionName,
                    testable[0].code,
                    section.latencyTestTimeout,
                  );
                }
              }
            },
          },
          isLatFetching
            ? [
                renderLoaderCircleIcon24(),
                E('span', {}, getLatencyTestLabel(latProgress)),
              ]
            : [renderZapIcon(12), E('span', {}, _('Test latency'))],
        ),
      );
    }
    return controls;
  };

  const modalHeaderControls =
    activeSectionModalTab === 'nodes' ? renderNodesHeaderControls(true) : [];
  const modalHeaderBar = E('div', { class: 'tachyon-sec-accordion__header' }, [
    tabsBar,
    ...(modalHeaderControls.length > 0
      ? [
          E(
            'div',
            { class: 'tachyon-sec-accordion__actions' },
            modalHeaderControls,
          ),
        ]
      : []),
  ]);

  const tabBody =
    activeSectionModalTab === 'nodes'
      ? E('div', { class: 'tachyon-sec-modal__nodes-pane' }, [
          renderSections({
            loading: false,
            failed: false,
            section,
            hideSectionHeader: true,
            nodesViewMode: currentNodesViewMode,
            onChangeNodesViewMode: (mode) => {
              setDashboardNodesViewMode(mode);
              openSectionInspectorModal(section.code);
            },
            isCollapsed: false,
            onToggleCollapse: () => {
              toggleRoutingSectionExpanded(section.code);
            },
            collapsedSourceGroups,
            onToggleSourceGroupCollapse: (groupKey: string) => {
              if (collapsedSourceGroups.has(groupKey)) {
                collapsedSourceGroups.delete(groupKey);
              } else {
                collapsedSourceGroups.add(groupKey);
              }
              void renderSectionsWidget(true);
            },
            activeCountryFilter: activeCountryFilters.get(section.sectionName),
            onFilterCountry: (sectionName: string, countryCode?: string) => {
              if (countryCode) {
                activeCountryFilters.set(sectionName, countryCode);
              } else {
                activeCountryFilters.delete(sectionName);
              }
              void renderSectionsWidget(true);
            },
            activeRegionFilter: activeRegionFilters.get(section.sectionName),
            onFilterRegion: (sectionName: string, regionCode?: string) => {
              if (regionCode && regionCode !== 'all') {
                activeRegionFilters.set(sectionName, regionCode);
              } else {
                activeRegionFilters.delete(sectionName);
              }
              void renderSectionsWidget(true);
            },
            onTestLatency: (tag: string | string[]) => {
              if (Array.isArray(tag)) {
                const serializedTag = serializeSectionLatencyTag(section, tag);
                void handleTestLatency(
                  'proxy_list',
                  section.sectionName,
                  serializedTag,
                  section.latencyTestTimeout,
                );
                return;
              }
              if (section.withTagSelect) {
                void handleTestLatency(
                  'group',
                  section.sectionName,
                  tag,
                  section.latencyTestTimeout,
                );
                return;
              }
              void handleTestLatency(
                'proxy',
                section.sectionName,
                tag,
                section.latencyTestTimeout,
              );
            },
            onChooseOutbound: (sectionName, selector, tag) => {
              void handleChooseOutbound(sectionName, selector, tag);
            },
            onCopyOutbound: (_sec, outbound) => {
              void handleCopyOutbound(outbound);
            },
            onShowUrlTestInfo: (sec, outbound) => {
              handleShowUrlTestInfo(sec, outbound);
            },
            onShowPriorityInfo: (sec, outbound) => {
              handleShowPriorityInfo(sec, outbound);
            },
            onUpdateSubscription: (sec) => {
              void handleUpdateSubscription(sec);
            },
            latencyFetching: isLatFetching,
            latencyProgress: latProgress,
            subscriptionUpdating: isSubUpdating,
            selectorSwitchingTag:
              sectionsWidget.selectorSwitchingSections[section.sectionName],
            onTestSingleOutbound: (sectionName, outboundCode) => {
              void handleTestSingleOutbound(sectionName, outboundCode);
            },
            testingOutboundCodes: singleTestingOutboundCodes,
            sectionStats: getSectionConnectionStats(
              section.sectionName || 'main',
              proxySectionCount || 1,
              lastRawConnections,
              {
                downloadTotal: totData?.downloadTotal,
                uploadTotal: totData?.uploadTotal,
                downSpeed: bwData?.down,
                upSpeed: bwData?.up,
              },
              connectionRates,
            ),
          }),
        ])
      : E('div', { class: 'tachyon-sec-modal__conditions-pane' }, [
          renderSectionConditionsAndBalancersView(section, {
            onShowUrlTestInfo: (sec, outbound) => {
              handleShowUrlTestInfo(sec, outbound);
            },
            onShowPriorityInfo: (sec, outbound) => {
              handleShowPriorityInfo(sec, outbound);
            },
            onChooseOutbound: (sectionName, selector, tag) => {
              void handleChooseOutbound(sectionName, selector, tag);
            },
          }),
        ]);

  return E(
    'div',
    {
      id: 'tachyon-section-inspector-modal',
      class: 'tachyon-section-inspector-modal',
    },
    [
      ...(sectionSwitcher ? [sectionSwitcher] : []),
      modalHeaderBar,
      tabBody,
      E('div', { class: 'tachyon-sec-modal__footer' }, [
        E(
          'button',
          {
            type: 'button',
            class:
              'btn cbi-button tachyon-sec-accordion__action-btn tachyon-sec-accordion__action-btn--primary',
            click: (e: MouseEvent) => {
              e.preventDefault();
              const targetSecId = section.sectionName || section.code;
              selectedDashboardSectionCode = '';
              ui.hideModal();
              const openEntity = (globalThis as any).__tachyonOpenEntityModal;
              if (typeof openEntity === 'function' && targetSecId) {
                openEntity('section', targetSecId, 'sections');
                return;
              }
              const navSub = document.querySelector<HTMLElement>(
                '.tachyon-sidebar__subitem[data-nav-key="section:sections"]',
              );
              if (navSub) {
                navSub.click();
              } else {
                const topTab = document.querySelector<HTMLElement>(
                  '.cbi-tabmenu > li[data-tab="cbi-tachyon-section"] a',
                );
                topTab?.click();
              }
            },
          },
          [
            renderSettingsIcon(13),
            E(
              'span',
              {},
              tr('Настроить секцию и правила →', 'Configure section & rules →'),
            ),
          ],
        ),
        E(
          'button',
          {
            type: 'button',
            class:
              'btn cbi-button cbi-button-neutral tachyon-sec-accordion__action-btn',
            click: (e: MouseEvent) => {
              e.preventDefault();
              selectedDashboardSectionCode = '';
              ui.hideModal();
              void renderSectionsWidget(true);
            },
          },
          _('Close'),
        ),
      ]),
    ],
  );
}

function renderSectionAccordionBody(
  section: Tachyon.OutboundGroup,
  proxySectionCount: number,
): HTMLElement {
  const sectionsWidget = store.get().sectionsWidget;
  const bwData = store.get().bandwidthWidget.data;
  const totData = store.get().trafficTotalWidget.data;
  const secKey = section.sectionName || section.code;
  const defaultTab = isServiceGroup(section) ? 'conditions' : 'nodes';
  const currentTab = sectionAccordionTabs.get(secKey) || defaultTab;
  const currentNodesViewMode = getDashboardNodesViewMode();
  const hasServerNodes =
    !isServiceGroup(section) &&
    Boolean(
      (section.outbounds || []).some((o) => !o.urlTestInfo && !o.priorityInfo),
    );
  const isSubUpdating = Boolean(
    sectionsWidget.subscriptionUpdatingSections[section.sectionName],
  );
  const isLatFetching = Boolean(
    sectionsWidget.latencyFetchingSections[section.sectionName],
  );
  const latProgress =
    sectionsWidget.latencyProgressSections[section.sectionName];

  const headerActions: HTMLElement[] = [
    ...(currentTab === 'nodes' && hasServerNodes
      ? [
          E('div', { class: 'tachyon-nodes-view-switch' }, [
            E(
              'button',
              {
                type: 'button',
                class: `btn cbi-button tachyon-nodes-view-switch__btn ${
                  currentNodesViewMode === 'table' ? 'is-active' : ''
                }`,
                click: (e: MouseEvent) => {
                  e.preventDefault();
                  setDashboardNodesViewMode('table');
                  void renderSectionsWidget(true);
                },
              },
              [renderListIcon(12), E('span', {}, tr('Таблица', 'Table'))],
            ),
            E(
              'button',
              {
                type: 'button',
                class: `btn cbi-button tachyon-nodes-view-switch__btn ${
                  currentNodesViewMode === 'tiles' ? 'is-active' : ''
                }`,
                click: (e: MouseEvent) => {
                  e.preventDefault();
                  setDashboardNodesViewMode('tiles');
                  void renderSectionsWidget(true);
                },
              },
              [renderLayoutGridIcon(12), E('span', {}, tr('Плитки', 'Tiles'))],
            ),
          ]),
        ]
      : []),
    ...(currentTab === 'nodes' && (section.subscriptionSourceCount || 0) > 0
      ? [
          E(
            'button',
            {
              type: 'button',
              class: 'btn cbi-button tachyon-sec-accordion__action-btn',
              disabled: isSubUpdating ? true : undefined,
              click: (e: MouseEvent) => {
                e.preventDefault();
                if (!isSubUpdating) {
                  void handleUpdateSubscription(section);
                }
              },
            },
            isSubUpdating
              ? [renderLoaderCircleIcon24(), E('span', {}, _('Updating...'))]
              : [
                  renderRefreshCwIcon(13),
                  E('span', {}, _('Update subscriptions')),
                ],
          ),
        ]
      : []),
    ...(currentTab === 'nodes' &&
    !isServiceGroup(section) &&
    (section.withTagSelect ||
      (section.outbounds && section.outbounds.length > 0))
      ? [
          E(
            'button',
            {
              type: 'button',
              class: 'btn cbi-button tachyon-sec-accordion__action-btn',
              disabled: isLatFetching ? true : undefined,
              click: (e: MouseEvent) => {
                e.preventDefault();
                if (isLatFetching) return;
                if (section.withTagSelect) {
                  const tag = section.latencyTestCodes?.length
                    ? section.latencyTestCodes
                    : section.latencyTestCode || section.code;
                  if (Array.isArray(tag)) {
                    const serializedTag = serializeSectionLatencyTag(
                      section,
                      tag,
                    );
                    void handleTestLatency(
                      'proxy_list',
                      section.sectionName,
                      serializedTag,
                      section.latencyTestTimeout,
                    );
                  } else {
                    void handleTestLatency(
                      'group',
                      section.sectionName,
                      tag,
                      section.latencyTestTimeout,
                    );
                  }
                } else {
                  const testable = (section.outbounds || []).filter(
                    (o) => !isNonTestableOutboundType(o.type),
                  );
                  if (testable.length) {
                    void handleTestLatency(
                      'proxy',
                      section.sectionName,
                      testable[0].code,
                      section.latencyTestTimeout,
                    );
                  }
                }
              },
            },
            isLatFetching
              ? [
                  renderLoaderCircleIcon24(),
                  E('span', {}, getLatencyTestLabel(latProgress)),
                ]
              : [renderZapIcon(12), E('span', {}, _('Test latency'))],
          ),
        ]
      : []),
    E(
      'button',
      {
        type: 'button',
        class:
          'btn cbi-button tachyon-sec-accordion__action-btn tachyon-sec-accordion__action-btn--sm',
        title: tr('Открыть в модальном окне', 'Open in modal'),
        click: (e: MouseEvent) => {
          e.preventDefault();
          activeSectionModalTab = currentTab;
          openSectionInspectorModal(section.code);
        },
      },
      [renderArrowUpRightIcon(12)],
    ),
    E(
      'button',
      {
        type: 'button',
        class:
          'btn cbi-button tachyon-sec-accordion__action-btn tachyon-sec-accordion__action-btn--sm',
        title: tr('Настроить секцию и правила', 'Configure section & rules'),
        click: (e: MouseEvent) => {
          e.preventDefault();
          const targetSecId = section.sectionName || section.code;
          const openEntity = (globalThis as any).__tachyonOpenEntityModal;
          if (typeof openEntity === 'function' && targetSecId) {
            openEntity('section', targetSecId, 'sections');
            return;
          }
          const navSub = document.querySelector<HTMLElement>(
            '.tachyon-sidebar__subitem[data-nav-key="section:sections"]',
          );
          if (navSub) {
            navSub.click();
          } else {
            const topTab = document.querySelector<HTMLElement>(
              '.cbi-tabmenu > li[data-tab="cbi-tachyon-section"] a',
            );
            topTab?.click();
          }
        },
      },
      [renderSettingsIcon(12)],
    ),
  ];

  const tabsBar = E('div', { class: 'tachyon-sec-accordion__header' }, [
    E('div', { class: 'tachyon-sec-accordion__tabs' }, [
      E(
        'button',
        {
          type: 'button',
          class: `btn cbi-button tachyon-sec-accordion__tab-btn ${
            currentTab === 'nodes' ? 'is-active' : ''
          }`,
          click: (e: MouseEvent) => {
            e.preventDefault();
            sectionAccordionTabs.set(secKey, 'nodes');
            void renderSectionsWidget(true);
          },
        },
        [E('span', {}, tr('Узлы и балансировщики', 'Nodes & Balancers'))],
      ),
      E(
        'button',
        {
          type: 'button',
          class: `btn cbi-button tachyon-sec-accordion__tab-btn ${
            currentTab === 'conditions' ? 'is-active' : ''
          }`,
          click: (e: MouseEvent) => {
            e.preventDefault();
            sectionAccordionTabs.set(secKey, 'conditions');
            void renderSectionsWidget(true);
          },
        },
        [E('span', {}, tr('Условия и правила', 'Conditions & Rules'))],
      ),
    ]),
    ...(headerActions.length > 0
      ? [E('div', { class: 'tachyon-sec-accordion__actions' }, headerActions)]
      : []),
  ]);

  const footerBar = E('div', { class: 'tachyon-sec-accordion__footer' }, [
    E(
      'button',
      {
        type: 'button',
        class: 'btn cbi-button tachyon-sec-accordion__action-btn',
        click: (e: MouseEvent) => {
          e.preventDefault();
          activeSectionModalTab = currentTab;
          openSectionInspectorModal(section.code);
        },
      },
      [
        renderArrowUpRightIcon(13),
        E('span', {}, tr('Открыть в модальном окне', 'Open in modal')),
      ],
    ),
    E(
      'button',
      {
        type: 'button',
        class:
          'btn cbi-button tachyon-sec-accordion__action-btn tachyon-sec-accordion__action-btn--primary',
        click: (e: MouseEvent) => {
          e.preventDefault();
          const targetSecId = section.sectionName || section.code;
          const openEntity = (globalThis as any).__tachyonOpenEntityModal;
          if (typeof openEntity === 'function' && targetSecId) {
            openEntity('section', targetSecId, 'sections');
            return;
          }
          const navSub = document.querySelector<HTMLElement>(
            '.tachyon-sidebar__subitem[data-nav-key="section:sections"]',
          );
          if (navSub) {
            navSub.click();
          } else {
            const topTab = document.querySelector<HTMLElement>(
              '.cbi-tabmenu > li[data-tab="cbi-tachyon-section"] a',
            );
            topTab?.click();
          }
        },
      },
      [
        renderSettingsIcon(13),
        E(
          'span',
          {},
          tr('Настроить секцию и правила →', 'Configure section & rules →'),
        ),
      ],
    ),
  ]);

  const tabBody =
    currentTab === 'nodes'
      ? E('div', { class: 'tachyon-sec-modal__nodes-pane' }, [
          renderSections({
            loading: false,
            failed: false,
            section,
            hideSectionHeader: true,
            nodesViewMode: currentNodesViewMode,
            onChangeNodesViewMode: (mode) => {
              setDashboardNodesViewMode(mode);
              void renderSectionsWidget(true);
            },
            isCollapsed: false,
            onToggleCollapse: () => {
              toggleRoutingSectionExpanded(section.code);
            },
            collapsedSourceGroups,
            onToggleSourceGroupCollapse: (groupKey: string) => {
              if (collapsedSourceGroups.has(groupKey)) {
                collapsedSourceGroups.delete(groupKey);
              } else {
                collapsedSourceGroups.add(groupKey);
              }
              void renderSectionsWidget(true);
            },
            activeCountryFilter: activeCountryFilters.get(section.sectionName),
            onFilterCountry: (sectionName: string, countryCode?: string) => {
              if (countryCode) {
                activeCountryFilters.set(sectionName, countryCode);
              } else {
                activeCountryFilters.delete(sectionName);
              }
              void renderSectionsWidget(true);
            },
            activeRegionFilter: activeRegionFilters.get(section.sectionName),
            onFilterRegion: (sectionName: string, regionCode?: string) => {
              if (regionCode && regionCode !== 'all') {
                activeRegionFilters.set(sectionName, regionCode);
              } else {
                activeRegionFilters.delete(sectionName);
              }
              void renderSectionsWidget(true);
            },
            onTestLatency: (tag: string | string[]) => {
              if (Array.isArray(tag)) {
                const serializedTag = serializeSectionLatencyTag(section, tag);
                void handleTestLatency(
                  'proxy_list',
                  section.sectionName,
                  serializedTag,
                  section.latencyTestTimeout,
                );
                return;
              }
              if (section.withTagSelect) {
                void handleTestLatency(
                  'group',
                  section.sectionName,
                  tag,
                  section.latencyTestTimeout,
                );
                return;
              }
              void handleTestLatency(
                'proxy',
                section.sectionName,
                tag,
                section.latencyTestTimeout,
              );
            },
            onChooseOutbound: (sectionName, selector, tag) => {
              void handleChooseOutbound(sectionName, selector, tag);
            },
            onCopyOutbound: (_sec, outbound) => {
              void handleCopyOutbound(outbound);
            },
            onShowUrlTestInfo: (sec, outbound) => {
              handleShowUrlTestInfo(sec, outbound);
            },
            onShowPriorityInfo: (sec, outbound) => {
              handleShowPriorityInfo(sec, outbound);
            },
            onUpdateSubscription: (sec) => {
              void handleUpdateSubscription(sec);
            },
            latencyFetching: isLatFetching,
            latencyProgress: latProgress,
            subscriptionUpdating: isSubUpdating,
            selectorSwitchingTag:
              sectionsWidget.selectorSwitchingSections[section.sectionName],
            onTestSingleOutbound: (sectionName, outboundCode) => {
              void handleTestSingleOutbound(sectionName, outboundCode);
            },
            testingOutboundCodes: singleTestingOutboundCodes,
            sectionStats: getSectionConnectionStats(
              section.sectionName || 'main',
              proxySectionCount || 1,
              lastRawConnections,
              {
                downloadTotal: totData?.downloadTotal,
                uploadTotal: totData?.uploadTotal,
                downSpeed: bwData?.down,
                upSpeed: bwData?.up,
              },
              connectionRates,
            ),
          }),
        ])
      : E('div', { class: 'tachyon-sec-modal__conditions-pane' }, [
          renderSectionConditionsAndBalancersView(section, {
            onShowUrlTestInfo: (sec, outbound) => {
              handleShowUrlTestInfo(sec, outbound);
            },
            onShowPriorityInfo: (sec, outbound) => {
              handleShowPriorityInfo(sec, outbound);
            },
            onChooseOutbound: (sectionName, selector, tag) => {
              void handleChooseOutbound(sectionName, selector, tag);
            },
          }),
        ]);

  return E('div', { class: 'tachyon-sec-accordion__inner' }, [
    tabsBar,
    tabBody,
    footerBar,
  ]);
}

function openSectionInspectorModal(sectionCode: string) {
  const allSections = getSectionsWithCustomLatencies();
  const section =
    allSections.find((s) => s.code === sectionCode) || allSections[0];
  if (!section) return;
  selectedDashboardSectionCode = section.code;
  const totalSectionCount = Math.max(1, allSections.length);

  const titleText = `${tr('Секция', 'Section')}: ${
    section.displayName || section.sectionName || section.code
  }`;
  const content = renderSectionInspectorModalContent(
    section,
    allSections,
    totalSectionCount,
  );
  ui.showModal(titleText, [content]);
}

async function renderSectionsWidget(forceImmediate = false) {
  logger.debug('[DASHBOARD]', 'renderSectionsWidget');
  const sectionsWidget = store.get().sectionsWidget;
  const container = document.getElementById('dashboard-sections-grid');

  if (!container) {
    return;
  }

  if (!forceImmediate && isUserActivelyScrolling()) {
    scheduleSectionsWidgetRender();
    return;
  }

  const sectionsWithCustomLatencies = getSectionsWithCustomLatencies();

  if (sectionsWidget.loading || sectionsWidget.failed) {
    const renderedWidget = renderSections({
      loading: sectionsWidget.loading,
      failed: sectionsWidget.failed,
      section: {
        code: '',
        sectionName: '',
        displayName: '',
        outbounds: [],
        withTagSelect: false,
      },
      isCollapsed: false,
      onToggleCollapse: () => {},
      onTestLatency: () => {},
      onChooseOutbound: () => {},
      onCopyOutbound: () => {},
      onShowUrlTestInfo: () => {},
      onShowPriorityInfo: () => {},
      onUpdateSubscription: () => {},
      latencyFetching: false,
      latencyProgress: undefined,
      subscriptionUpdating: false,
      selectorSwitchingTag: undefined,
    });

    return preserveScrollForPage(() => {
      container.replaceChildren(renderedWidget);
    }, container);
  }

  const totalSectionCount = Math.max(1, sectionsWithCustomLatencies.length);
  const bwData = store.get().bandwidthWidget.data;
  const totData = store.get().trafficTotalWidget.data;

  const existingModal = document.getElementById(
    'tachyon-section-inspector-modal',
  );
  if (!existingModal && selectedDashboardSectionCode) {
    // Keep selection only while a modal is active
    const anyModalOpen = document.body.classList.contains(
      'modal-overlay-active',
    );
    if (!anyModalOpen) {
      selectedDashboardSectionCode = '';
    }
  }

  const dashboardBlocks = renderDashboardSectionsAndNodes({
    sections: sectionsWithCustomLatencies,
    selectedSectionCode: selectedDashboardSectionCode,
    expandedSections: expandedRoutingSections,
    onToggleExpandSection: (sectionCode: string) => {
      toggleRoutingSectionExpanded(sectionCode);
    },
    onOpenSectionModal: (sectionCode: string) => {
      selectedDashboardSectionCode = sectionCode;
      openSectionInspectorModal(sectionCode);
      void renderSectionsWidget();
    },
    renderSectionAccordionContent: (sec) =>
      renderSectionAccordionBody(sec, totalSectionCount),
    onSelectSection: (sectionCode: string) => {
      toggleRoutingSectionExpanded(sectionCode);
    },
    getSectionStats: (sec) =>
      getSectionConnectionStats(
        sec.sectionName || 'main',
        totalSectionCount,
        lastRawConnections,
        {
          downloadTotal: totData?.downloadTotal,
          uploadTotal: totData?.uploadTotal,
          downSpeed: bwData?.down,
          upSpeed: bwData?.up,
        },
        connectionRates,
      ),
    isTestingAllSections,
    onTestAllSections: () => {
      void handleTestAllSections();
    },
    latencyFetchingSections: sectionsWidget.latencyFetchingSections,
    latencyProgressSections: sectionsWidget.latencyProgressSections,
    subscriptionUpdatingSections: sectionsWidget.subscriptionUpdatingSections,
    selectorSwitchingSections: sectionsWidget.selectorSwitchingSections,
    testingOutboundCodes: singleTestingOutboundCodes,
    activeCountryFilters,
    onFilterCountry: (sectionName: string, countryCode?: string) => {
      if (countryCode) {
        activeCountryFilters.set(sectionName, countryCode);
      } else {
        activeCountryFilters.delete(sectionName);
      }
      void renderSectionsWidget();
    },
    onTestSectionLatency: (section) => {
      if (isServiceGroup(section)) {
        return;
      }
      if (section.withTagSelect) {
        const tag = section.latencyTestCodes?.length
          ? section.latencyTestCodes
          : section.latencyTestCode || section.code;
        if (Array.isArray(tag)) {
          const serializedTag = serializeSectionLatencyTag(section, tag);
          void handleTestLatency(
            'proxy_list',
            section.sectionName,
            serializedTag,
            section.latencyTestTimeout,
          );
          return;
        }
        void handleTestLatency(
          'group',
          section.sectionName,
          tag,
          section.latencyTestTimeout,
        );
        return;
      }
      const testable = section.outbounds.filter(
        (o) => !isNonTestableOutboundType(o.type),
      );
      if (testable.length) {
        void handleTestLatency(
          'proxy',
          section.sectionName,
          testable[0].code,
          section.latencyTestTimeout,
        );
      }
    },
    onTestSingleOutbound: (sectionName, outboundCode) => {
      void handleTestSingleOutbound(sectionName, outboundCode);
    },
    onChooseOutbound: (sectionName, selector, tag) => {
      void handleChooseOutbound(sectionName, selector, tag);
    },
    onCopyOutbound: (_section, outbound) => {
      handleCopyOutbound(outbound);
    },
    onShowUrlTestInfo: (section, outbound) => {
      handleShowUrlTestInfo(section, outbound);
    },
    onShowPriorityInfo: (section, outbound) => {
      handleShowPriorityInfo(section, outbound);
    },
    onUpdateSubscription: (section) => {
      void handleUpdateSubscription(section);
    },
    onSectionTypesChanged: () => {
      void renderSectionsWidget();
    },
  });

  if (existingModal && selectedDashboardSectionCode) {
    const activeSec = sectionsWithCustomLatencies.find(
      (s) => s.code === selectedDashboardSectionCode,
    );
    if (activeSec) {
      const updatedModalContent = renderSectionInspectorModalContent(
        activeSec,
        sectionsWithCustomLatencies,
        totalSectionCount,
      );
      preserveScrollForPage(() => {
        existingModal.replaceWith(updatedModalContent);
      }, existingModal);
    }
  }

  return preserveScrollForPage(() => {
    container.replaceChildren(...dashboardBlocks);
  }, container);
}

function renderStoreWidget(
  containerId: string,
  storeKey:
    | 'bandwidthWidget'
    | 'trafficTotalWidget'
    | 'systemInfoWidget'
    | 'servicesInfoWidget'
    | 'tailscaleWidget',
  title: string,
  getItems: (data: any) => Array<{
    key?: string | HTMLElement;
    value: string | HTMLElement | (string | HTMLElement)[];
    attributes?: {
      class?: string;
      title?: string;
      [key: string]: string | undefined;
    };
  }>,
  debugName: string,
) {
  logger.debug('[DASHBOARD]', debugName);
  const widgetState = store.get()[storeKey];
  const container = document.getElementById(containerId);
  if (!container) return;

  if (widgetState.loading || widgetState.failed) {
    const renderedWidget = renderWidget({
      loading: widgetState.loading,
      failed: widgetState.failed,
      title: '',
      items: [],
    });
    return container.replaceChildren(renderedWidget);
  }

  const renderedWidget = renderWidget({
    loading: widgetState.loading,
    failed: widgetState.failed,
    title: title,
    items: getItems(widgetState.data),
  });
  container.replaceChildren(renderedWidget);
}

async function fetchConnections() {
  const isLiteMode = Boolean(store.get().servicesInfoWidget.data?.liteMode);

  if (isLiteMode && !expandedSections.has('active_clients')) {
    const bw = store.get().bandwidthWidget.data;
    const totalSpeed = (bw?.down || 0) + (bw?.up || 0);
    if (totalSpeed > 512 * 1024) {
      return;
    }
  }

  const hasEnabledInbounds = getConfiguredServerInbounds().some(
    (s) => s.enabled,
  );
  const shouldFetchHostnames =
    expandedSections.has('active_clients') || hasEnabledInbounds;
  const needsFallbackPolling =
    directSocketsFailed || !canUseDirectClashApi() || isLiteMode;
  if (!needsFallbackPolling && !shouldFetchHostnames) {
    return;
  }
  try {
    if (!needsFallbackPolling && lastRawConnections.length > 0) {
      const hostnames = await fetchHostnames();
      if (hostnames.size > 0) {
        cachedHostnames = hostnames;
      }
      currentConnections = aggregateClientConnections(
        lastRawConnections,
        cachedHostnames,
      );
      void renderSystemInfoWidget();
      renderConnectionsWidget();
      renderInboundServersDashboardWidget({
        rawConnections: lastRawConnections,
        hostnames: cachedHostnames,
      });
      return;
    }

    const [res, hostnames] = await Promise.all([
      TachyonShellMethods.getClashApiConnections(),
      shouldFetchHostnames
        ? fetchHostnames()
        : Promise.resolve(cachedHostnames),
    ]);
    if (shouldFetchHostnames && hostnames.size > 0) {
      cachedHostnames = hostnames;
    }
    if (res.success && res.data && typeof res.data === 'object') {
      const payload = res.data as any;

      if (Array.isArray(payload.connections)) {
        updateRawConnections(payload.connections);
        currentConnections = aggregateClientConnections(
          payload.connections,
          cachedHostnames,
        );
        currentTopDomains = aggregateTopDomains(payload.connections);
      }
      renderInboundServersDashboardWidget({
        rawConnections: lastRawConnections,
        hostnames: cachedHostnames,
      });

      if (needsFallbackPolling) {
        const downloadTotal = Number(payload.downloadTotal) || 0;
        const uploadTotal = Number(payload.uploadTotal) || 0;
        const memory = Number(payload.memory) || 0;
        const connCount = Array.isArray(payload.connections)
          ? payload.connections.length
          : 0;

        const now = Date.now();
        const { rates, nextState } = computeTrafficRates(
          uploadTotal,
          downloadTotal,
          now,
          trafficRatesState,
        );
        trafficRatesState = nextState;

        store.set({
          bandwidthWidget: {
            loading: false,
            failed: false,
            data: rates,
          },
          trafficTotalWidget: {
            loading: false,
            failed: false,
            data: { downloadTotal, uploadTotal },
          },
          systemInfoWidget: {
            loading: false,
            failed: false,
            data: { connections: connCount, memory },
          },
        });
      } else if (shouldFetchHostnames) {
        void renderSystemInfoWidget();
      }
    }
  } catch (_e) {
    // Ignore connections fetch errors
  }
  scheduleConnectionsWidgetRender();
}

let connectionsRenderFrame: number | null = null;
let connectionsWidgetHovered = false;
let connectionsHoverDeferredTimer: ReturnType<typeof setTimeout> | null = null;
let connectionsWidgetListenersAttached = false;

function isConnectionsHoverActive(container: HTMLElement): boolean {
  if (connectionsWidgetHovered) {
    try {
      const el = container.querySelector(
        '.tachyon-client-row:hover, .tachyon_proto-popover-trigger:hover, .tachyon_proto-popover:hover, .tachyon-clients-container:hover',
      );
      if (el) return true;
    } catch {
      return true;
    }
  }
  try {
    return Boolean(
      container.querySelector(
        '.tachyon-client-row:hover, .tachyon_proto-popover-trigger:hover, .tachyon_proto-popover:hover, .tachyon-clients-container:hover',
      ),
    );
  } catch {
    return false;
  }
}

function attachConnectionsWidgetHoverListeners(container: HTMLElement) {
  if (connectionsWidgetListenersAttached) return;
  container.addEventListener('mouseenter', () => {
    connectionsWidgetHovered = true;
  });
  container.addEventListener('mouseleave', () => {
    connectionsWidgetHovered = false;
    if (connectionsHoverDeferredTimer !== null) {
      clearTimeout(connectionsHoverDeferredTimer);
      connectionsHoverDeferredTimer = null;
    }
    scheduleConnectionsWidgetRender();
  });
  connectionsWidgetListenersAttached = true;
}

function scheduleConnectionsWidgetRender() {
  if (connectionsRenderFrame !== null) return;
  const schedule = isUserActivelyScrolling()
    ? (cb: () => void) => setTimeout(cb, 250)
    : typeof requestAnimationFrame !== 'undefined'
      ? requestAnimationFrame
      : (cb: () => void) => setTimeout(cb, 16);
  connectionsRenderFrame = schedule(() => {
    connectionsRenderFrame = null;
    renderConnectionsWidget();
  }) as unknown as number;
}

function renderConnectionsWidget() {
  const container = document.getElementById('dashboard-connections-grid');
  if (!container) return;

  attachConnectionsWidgetHoverListeners(container);

  if (isUserActivelyScrolling()) {
    scheduleConnectionsWidgetRender();
    return;
  }

  const clientsViewMode = getWidgetViewMode('active_clients') || 'collapsible';
  const isCollapsed =
    clientsViewMode === 'expanded' || clientsViewMode === 'domains_focus'
      ? false
      : !expandedSections.has('active_clients');

  // Fast-path in-place DOM update without replacing children
  if (
    patchConnections(
      container,
      currentConnections,
      isCollapsed,
      currentTopDomains,
      clientsViewMode,
    )
  ) {
    return;
  }

  const clientsContainer = container.querySelector(
    '.tachyon-clients-container',
  );
  const wasCollapsed = !clientsContainer;
  const isCollapseToggled = isCollapsed !== wasCollapsed;

  // If order changed or clients connected/disconnected while user is hovering over
  // rows or popovers, do not recreate DOM underneath their cursor.
  // Patch existing row values in-place and defer full re-render until hover ends.
  if (!isCollapseToggled && isConnectionsHoverActive(container)) {
    patchExistingClientRowsByIp(container, currentConnections);

    if (connectionsHoverDeferredTimer === null) {
      connectionsHoverDeferredTimer = setTimeout(() => {
        connectionsHoverDeferredTimer = null;
        scheduleConnectionsWidgetRender();
      }, 1000);
    }
    return;
  }

  if (connectionsHoverDeferredTimer !== null) {
    clearTimeout(connectionsHoverDeferredTimer);
    connectionsHoverDeferredTimer = null;
  }

  preserveScrollForPage(() => {
    container.replaceChildren(
      renderConnections(
        currentConnections,
        isCollapsed,
        () => toggleSectionExpanded('active_clients'),
        currentTopDomains,
        clientsViewMode,
      ),
    );
  }, container);
}

export function getSectionConnectionStats(
  sectionName: string,
  totalProxySections: number,
  rawConns: ConnectionTrafficSample[],
  totals: {
    downloadTotal?: number;
    uploadTotal?: number;
    downSpeed?: number;
    upSpeed?: number;
  },
  rates: ReadonlyMap<string, TrafficSample> = new Map(),
) {
  const target = (sectionName || '').toLowerCase();
  const matchesTarget = (c: ConnectionTrafficSample): boolean => {
    const rawChains = Array.isArray(c.chains)
      ? c.chains
      : Array.isArray((c as any).metadata?.chains)
        ? (c as any).metadata.chains
        : [];
    const chains = rawChains.map((ch: any) => String(ch).toLowerCase());
    if (
      chains.some(
        (ch: string) =>
          ch === target ||
          ch === `${target}-out` ||
          ch.startsWith(`${target}-urltest-`) ||
          ch.startsWith(`${target}-priority-`),
      )
    ) {
      return true;
    }
    const ruleStr = String(
      (c as any).rule || (c as any).rulePayload || '',
    ).toLowerCase();
    if (
      ruleStr &&
      (ruleStr.includes(`route(${target}-out)`) ||
        ruleStr.includes(`route(${target})`) ||
        ruleStr.includes(`rule_set=${target}-`) ||
        ruleStr.includes(`[${target}-`) ||
        ruleStr.includes(` ${target}-`))
    ) {
      return true;
    }
    return false;
  };

  if (
    totalProxySections <= 1 &&
    (rawConns.length === 0 || rawConns.every(matchesTarget))
  ) {
    return {
      conns: rawConns.length,
      upload: totals.uploadTotal || 0,
      download: totals.downloadTotal || 0,
      downSpeed: totals.downSpeed || 0,
      upSpeed: totals.upSpeed || 0,
    };
  }

  let conns = 0;
  let upload = 0;
  let download = 0;
  let downSpeed = 0;
  let upSpeed = 0;

  for (const c of rawConns) {
    if (matchesTarget(c)) {
      conns++;
      upload += Number(c.upload) || 0;
      download += Number(c.download) || 0;
      const rate = c.id ? rates.get(c.id) : undefined;
      downSpeed += rate?.down || 0;
      upSpeed += rate?.up || 0;
    }
  }

  return {
    conns,
    upload,
    download,
    downSpeed,
    upSpeed,
  };
}

const kpiClientsHistory: number[] = [];
const kpiSectionsHistory: number[] = [];
const kpiTrafficHistory: number[] = [];
const kpiLatencyHistory: number[] = [];
const trafficChartHistory: Array<{ ts: number; down: number; up: number }> = [];

function pushBoundedSample(arr: number[], value: number, maxLen = 28) {
  arr.push(Number.isFinite(value) && value >= 0 ? value : 0);
  if (arr.length > maxLen) {
    arr.shift();
  }
}

export async function renderSectionDashboardWidgets() {
  const container = document.getElementById('dashboard-widgets-sections-list');
  const kpiContainer = document.getElementById('dashboard-kpi-row');
  const chartContainer = document.getElementById(
    'dashboard-traffic-chart-card',
  );
  if (!container && !kpiContainer && !chartContainer) return;

  const sectionsWidget = store.get().sectionsWidget;
  const sectionsWithCustomLatencies = getSectionsWithCustomLatencies();

  const activeRoutes = getAllActiveRoutes(sectionsWithCustomLatencies);
  const isCheckingLatency =
    Object.keys(sectionsWidget.latencyFetchingSections || {}).length > 0 ||
    Object.keys(singleTestingOutboundCodes).length > 0;

  const bandwidth = store.get().bandwidthWidget.data;
  const total = store.get().trafficTotalWidget.data;
  const loading = sectionsWidget.loading;
  const failed = sectionsWidget.failed;

  const downSpeed = Number(bandwidth?.down) || 0;
  const upSpeed = Number(bandwidth?.up) || 0;
  const downloadTotal = Number(total?.downloadTotal) || 0;
  const uploadTotal = Number(total?.uploadTotal) || 0;
  const validLatencies = activeRoutes
    .map((r) => r.latency)
    .filter((lat) => typeof lat === 'number' && lat > 0);
  const avgLatencyMs =
    validLatencies.length > 0
      ? Math.round(
          validLatencies.reduce((acc, v) => acc + v, 0) / validLatencies.length,
        )
      : 0;

  pushBoundedSample(kpiClientsHistory, currentConnections.length, 20);
  pushBoundedSample(kpiSectionsHistory, activeRoutes.length, 20);
  pushBoundedSample(kpiTrafficHistory, downSpeed + upSpeed, 20);
  if (avgLatencyMs > 0) {
    pushBoundedSample(kpiLatencyHistory, avgLatencyMs, 20);
  }
  trafficChartHistory.push({ ts: Date.now(), down: downSpeed, up: upSpeed });
  if (trafficChartHistory.length > 30) {
    trafficChartHistory.shift();
  }

  if (kpiContainer) {
    const isLiteMode = Boolean(store.get().servicesInfoWidget.data?.liteMode);
    preserveScrollForPage(() => {
      kpiContainer.replaceChildren(
        ...renderKpiRow({
          activeClients: currentConnections.length,
          activeConnections:
            store.get().systemInfoWidget.data?.connections ||
            lastRawConnections.length ||
            0,
          activeSections: activeRoutes.length,
          downloadTotal,
          uploadTotal,
          downSpeed,
          upSpeed,
          avgLatencyMs,
          isLiteMode,
          clientsHistory: kpiClientsHistory,
          sectionsHistory: kpiSectionsHistory,
          trafficHistory: kpiTrafficHistory,
          latencyHistory: kpiLatencyHistory,
        }),
      );
    }, kpiContainer);
  }

  if (chartContainer) {
    preserveScrollForPage(() => {
      chartContainer.replaceChildren(
        renderTrafficChartCard(trafficChartHistory, downSpeed, upSpeed),
      );
    }, chartContainer);
  }

  // Patch compact section row metrics in-place inside #dashboard-sections-grid
  const sectionsGridEl = document.getElementById('dashboard-sections-grid');
  if (sectionsGridEl) {
    const totalSectionCount = Math.max(
      1,
      sectionsWithCustomLatencies.length,
      activeRoutes.length,
    );
    const rowMetricsNodes = Array.from(
      sectionsGridEl.querySelectorAll<HTMLElement>(
        '[data-section-row-metrics]',
      ),
    );
    for (const rowNode of rowMetricsNodes) {
      const secName =
        rowNode.getAttribute('data-section-row-metrics') || 'main';
      const stats = getSectionConnectionStats(
        secName,
        totalSectionCount,
        lastRawConnections,
        {
          downloadTotal,
          uploadTotal,
          downSpeed,
          upSpeed,
        },
        connectionRates,
      );
      const totalEl = rowNode.querySelector<HTMLElement>(
        '[data-row-metric="session-total"]',
      );
      if (totalEl) {
        const nextTotal = prettyBytes(
          (stats.download || 0) + (stats.upload || 0),
        );
        if (totalEl.textContent !== nextTotal) totalEl.textContent = nextTotal;
      }
      const downEl = rowNode.querySelector<HTMLElement>(
        '[data-row-metric="session-down"]',
      );
      if (downEl) {
        const nextDown = `↓ ${prettyBytes(stats.download || 0)}`;
        if (downEl.textContent !== nextDown) downEl.textContent = nextDown;
      }
      const upEl = rowNode.querySelector<HTMLElement>(
        '[data-row-metric="session-up"]',
      );
      if (upEl) {
        const nextUp = `↑ ${prettyBytes(stats.upload || 0)}`;
        if (upEl.textContent !== nextUp) upEl.textContent = nextUp;
      }
      const connsEl = rowNode.querySelector<HTMLElement>(
        '[data-row-metric="conns"]',
      );
      if (connsEl) {
        const nextConns = String(stats.conns);
        if (connsEl.textContent !== nextConns) connsEl.textContent = nextConns;
      }
    }
  }

  if (!container) return;

  const routesToRender: ActiveRouteInfo[] =
    activeRoutes.length > 0
      ? activeRoutes
      : [
          {
            sectionName: 'main',
            sectionDisplayName: 'Main',
            name: tr('Ожидание / Напрямую', 'Standby / Direct'),
            selector: '—',
            latency: -1,
            type: 'Proxy',
          },
        ];

  const totalProxySections = routesToRender.length;

  // Check if we can update existing cards in-place without touching DOM tree
  const existingCards = Array.from(
    container.querySelectorAll<HTMLElement>('[data-section-card]'),
  );
  const existingNames = existingCards.map((c) =>
    c.getAttribute('data-section-card'),
  );
  const newNames = routesToRender.map((r) => r.sectionName || 'main');

  const canUpdateInPlace =
    existingCards.length > 0 &&
    existingCards.length === routesToRender.length &&
    existingNames.every((name, i) => name === newNames[i]) &&
    !loading &&
    !failed;

  if (canUpdateInPlace) {
    routesToRender.forEach((route, idx) => {
      const card = existingCards[idx];
      const sectionName = route.sectionName || 'main';
      const stats = getSectionConnectionStats(
        sectionName,
        totalProxySections,
        lastRawConnections,
        {
          downloadTotal: total.downloadTotal,
          uploadTotal: total.uploadTotal,
          downSpeed: bandwidth.down,
          upSpeed: bandwidth.up,
        },
        connectionRates,
      );

      const downPill = card.querySelector<HTMLElement>(
        '[data-metric="down-speed"]',
      );
      if (downPill) {
        const nextText = `↓ ${prettyBytes(stats.downSpeed)}/s`;
        if (downPill.textContent !== nextText) downPill.textContent = nextText;
      }

      const upPill = card.querySelector<HTMLElement>(
        '[data-metric="up-speed"]',
      );
      if (upPill) {
        const nextText = `↑ ${prettyBytes(stats.upSpeed)}/s`;
        if (upPill.textContent !== nextText) upPill.textContent = nextText;
      }

      const sDownPill = card.querySelector<HTMLElement>(
        '[data-metric="session-down"]',
      );
      const sUpPill = card.querySelector<HTMLElement>(
        '[data-metric="session-up"]',
      );
      if (sDownPill && sUpPill) {
        const nextDown = `↓ ${prettyBytes(stats.download || 0)}`;
        const nextUp = `↑ ${prettyBytes(stats.upload || 0)}`;
        if (sDownPill.textContent !== nextDown)
          sDownPill.textContent = nextDown;
        if (sUpPill.textContent !== nextUp) sUpPill.textContent = nextUp;
      } else {
        const sTraffic = card.querySelector<HTMLElement>(
          '[data-metric="session-traffic"]',
        );
        if (sTraffic) {
          const nextText = `▼ ${prettyBytes(stats.download || 0)} • ▲ ${prettyBytes(stats.upload || 0)}`;
          if (sTraffic.textContent !== nextText)
            sTraffic.textContent = nextText;
        }
      }

      const connsPill = card.querySelector<HTMLElement>(
        '[data-metric="conns"]',
      );
      if (connsPill) {
        const nextText = String(stats.conns);
        if (connsPill.textContent !== nextText)
          connsPill.textContent = nextText;
      }

      const latencyPill = card.querySelector<HTMLElement>(
        '[data-metric="latency"]',
      );
      if (latencyPill) {
        const hasPillClass = latencyPill.className.includes(
          'tachyon-latency-pill',
        );
        if (hasPillClass) {
          const latencyClass =
            route.latency > 0
              ? route.latency <= 150
                ? 'tachyon-latency-pill tachyon-latency-pill--fast'
                : route.latency <= 300
                  ? 'tachyon-latency-pill tachyon-latency-pill--medium'
                  : 'tachyon-latency-pill tachyon-latency-pill--slow'
              : 'tachyon-latency-pill tachyon-latency-pill--neutral';
          if (latencyPill.className !== latencyClass)
            latencyPill.className = latencyClass;
        } else {
          const latencyClass = route.latency > 0 ? 'tachyon-stat--down' : '';
          if (latencyPill.className !== latencyClass)
            latencyPill.className = latencyClass;
        }
        const latencyText =
          route.latency > 0
            ? `${route.latency}ms`
            : isCheckingLatency
              ? tr('Проверка...', 'Checking...')
              : '—';
        if (latencyPill.textContent !== latencyText)
          latencyPill.textContent = latencyText;
      }

      const serverEl = card.querySelector<HTMLElement>(
        '[data-metric="server"]',
      );
      if (serverEl) {
        if (serverEl.getAttribute('data-server-name') !== route.name) {
          serverEl.setAttribute('data-server-name', route.name);
          const flagNodes = renderFlagEmojis(
            ensureOutboundDisplayFlag({ displayName: route.name }),
          );
          serverEl.replaceChildren(
            ...(Array.isArray(flagNodes) ? flagNodes : [flagNodes]),
          );
        }
      }

      const selectorEl = card.querySelector<HTMLElement>(
        '[data-metric="selector"]',
      );
      if (selectorEl && selectorEl.textContent !== route.selector) {
        selectorEl.textContent = route.selector;
      }

      const protoEl = card.querySelector<HTMLElement>(
        '[data-metric="protocol"]',
      );
      if (protoEl) {
        const protoText = route.type || '—';
        if (protoEl.textContent !== protoText) protoEl.textContent = protoText;
      }
    });
    return;
  }

  // If full DOM re-creation is required, defer while user is actively scrolling
  if (isUserActivelyScrolling()) {
    scheduleSectionDashboardWidgetsRender();
    return;
  }

  const widgets = routesToRender.map((route) => {
    const sectionName = route.sectionName || 'main';
    const sectionDisplayName = route.sectionDisplayName || sectionName;
    const stats = getSectionConnectionStats(
      sectionName,
      totalProxySections,
      lastRawConnections,
      {
        downloadTotal: total.downloadTotal,
        uploadTotal: total.uploadTotal,
        downSpeed: bandwidth.down,
        upSpeed: bandwidth.up,
      },
      connectionRates,
    );

    const latencyClass =
      route.latency > 0
        ? route.latency <= 150
          ? 'tachyon-latency-pill tachyon-latency-pill--fast'
          : route.latency <= 300
            ? 'tachyon-latency-pill tachyon-latency-pill--medium'
            : 'tachyon-latency-pill tachyon-latency-pill--slow'
        : 'tachyon-latency-pill tachyon-latency-pill--neutral';

    const latencyValue =
      route.latency > 0
        ? E('span', { class: latencyClass }, `${route.latency}ms`)
        : isCheckingLatency
          ? E('span', { class: latencyClass }, tr('Проверка...', 'Checking...'))
          : E('span', { class: latencyClass }, '—');

    const routeItems = [
      {
        key: tr('Сервер', 'Server'),
        value: E(
          'span',
          {
            class: 'tachyon-route-pill tachyon-route-pill--server',
            'data-metric': 'server',
            'data-server-name': route.name,
          } as any,
          renderFlagEmojis(
            ensureOutboundDisplayFlag({ displayName: route.name }),
          ),
        ),
      },
      {
        key: tr('Селектор', 'Selector'),
        value: E(
          'span',
          {
            class: 'tachyon-route-pill tachyon-route-pill--selector',
            'data-metric': 'selector',
          } as any,
          route.selector,
        ),
      },
      {
        key: tr('Задержка', 'Latency'),
        value: latencyValue,
      },
      {
        key: tr('Протокол', 'Protocol'),
        value:
          route.type && route.type !== '-'
            ? E(
                'span',
                {
                  'data-metric': 'protocol',
                  class: 'tachyon-protocol-pill',
                } as any,
                route.type,
              )
            : '-',
      },
    ];

    const trafficItems = [
      {
        key: tr('Входящий', 'Downlink'),
        value: E(
          'span',
          {
            class: 'tachyon-stat-pill tachyon-stat-pill--down',
            'data-metric': 'down-speed',
          } as any,
          `↓ ${prettyBytes(stats.downSpeed)}/s`,
        ),
      },
      {
        key: tr('Исходящий', 'Uplink'),
        value: E(
          'span',
          {
            class: 'tachyon-stat-pill tachyon-stat-pill--up',
            'data-metric': 'up-speed',
          } as any,
          `↑ ${prettyBytes(stats.upSpeed)}/s`,
        ),
      },
      {
        key:
          totalProxySections <= 1
            ? tr('За сессию', 'Session total')
            : tr('Трафик секции', 'Section traffic'),
        value: E('span', { class: 'tachyon-stat--session' } as any, [
          E(
            'span',
            {
              class: 'tachyon-traffic-pill tachyon-traffic-pill--down',
              'data-metric': 'session-down',
            } as any,
            `↓ ${prettyBytes(stats.download || 0)}`,
          ),
          E(
            'span',
            {
              class: 'tachyon-traffic-pill tachyon-traffic-pill--up',
              'data-metric': 'session-up',
            } as any,
            `↑ ${prettyBytes(stats.upload || 0)}`,
          ),
        ]),
      },
      {
        key: tr('Соединения', 'Connections'),
        value: E(
          'span',
          {
            class: 'tachyon-stat-pill tachyon-stat-pill--conns',
            'data-metric': 'conns',
          } as any,
          String(stats.conns),
        ),
      },
    ];

    return renderDualWidget({
      loading,
      failed,
      title: `${tr('Секция', 'Section')}: ${sectionDisplayName}`,
      badge: tr('Активна', 'Active'),
      attributes: {
        'data-section-card': sectionName,
      },
      columns: [
        {
          title: tr('Активный маршрут', 'Active Route'),
          items: routeItems,
        },
        {
          title: tr('Трафик и скорость', 'Traffic & Speed'),
          items: trafficItems,
        },
      ],
    });
  });

  preserveScrollForPage(() => {
    container.replaceChildren(...widgets);
  }, container);
}

export async function renderSystemServicesWidget() {
  const container = document.getElementById('dashboard-widget-system-services');
  if (!container) return;

  if (isUserActivelyScrolling()) {
    scheduleSystemServicesWidgetRender();
    return;
  }

  const sysState = store.get().systemInfoWidget;
  const srvState = store.get().servicesInfoWidget;
  const sections = store.get().sectionsWidget.data || [];
  const proxySections = sections.filter(
    (g) => !isServiceGroup(g) && g.outbounds && g.outbounds.length > 0,
  );

  const loading = sysState.loading && srvState.loading;
  const failed = sysState.failed && srvState.failed;
  const srvData = srvState.data;
  const isTachyonRunning = Boolean(srvData?.tachyonRunning);
  const connectionsCount = isTachyonRunning
    ? sysState.data?.connections || 0
    : 0;
  const activeSectionsCount = isTachyonRunning ? proxySections.length : 0;
  const activeClientsCount = isTachyonRunning ? currentConnections.length : 0;
  const isLiteMode = Boolean(srvData?.liteMode);

  const liteTooltip = tr(
    'Комплексный эко-режим для слабых MIPS/MIPSEL роутеров (QCA9531 / MT7628): пониженный приоритет прокси (nice 15), ускорение nftables через ct mark Short-Circuit + connlimit, сжатые лимиты conntrack (600с / 256КБ) и гибернация фоновых проверок при нагрузке',
    'Comprehensive eco mode for low-power MIPS/MIPSEL routers (QCA9531 / MT7628): lower proxy priority (nice 15), nftables ct mark Short-Circuit + connlimit, tighter conntrack limits (600s / 256KB), and Control Plane hibernation under heavy load',
  );

  const routingItems: Array<{
    key?: string | HTMLElement;
    value: string | HTMLElement | (string | HTMLElement)[];
    attributes?: Record<string, string>;
    onClick?: (e: MouseEvent) => void;
  }> = [
    {
      key: tr('Режим работы', 'Mode'),
      value: E(
        'span',
        { class: 'tachyon-mode-pill tachyon-mode-pill--active' },
        'TProxy + Fake-IP',
      ),
    },
    {
      key: tr('Эко-режим (Lite)', 'Tachyon Lite'),
      value: E(
        'button',
        {
          type: 'button',
          class: isLiteMode
            ? 'tachyon-mode-pill tachyon-mode-pill--active'
            : 'tachyon-stat-pill tachyon-stat-pill--conns',
          style: isLiteMode
            ? 'cursor: pointer; border: 1px solid rgba(16, 185, 129, 0.45); background: rgba(16, 185, 129, 0.16); color: #10b981; font-weight: 600;'
            : 'cursor: pointer; opacity: 0.85;',
          title: liteTooltip,
          click: async (event: MouseEvent) => {
            event.preventDefault();
            event.stopPropagation();
            const btn = event.currentTarget as HTMLButtonElement | null;
            if (btn) {
              btn.disabled = true;
              btn.textContent = tr('Применение...', 'Applying...');
            }
            const nextEnabled = !isLiteMode;
            try {
              const res = await TachyonShellMethods.setLiteMode(nextEnabled);
              if (res.success) {
                const currentSrv = store.get().servicesInfoWidget;
                store.set({
                  servicesInfoWidget: {
                    ...currentSrv,
                    data: {
                      ...currentSrv.data,
                      liteMode: nextEnabled ? 1 : 0,
                    },
                  },
                });
                showToast(
                  nextEnabled
                    ? tr(
                        'Эко-режим Tachyon Lite включён (nice 15 + ct mark Short-Circuit)',
                        'Tachyon Lite eco mode enabled (nice 15 + ct mark Short-Circuit)',
                      )
                    : tr(
                        'Эко-режим Tachyon Lite выключен',
                        'Tachyon Lite eco mode disabled',
                      ),
                  'success',
                );
                if (dashboardDataUpdatesStarted) {
                  stopDashboardDataUpdates();
                  startDashboardDataUpdates();
                }
                void refreshRuntimeUiState({ force: true });
              } else {
                showToast(
                  res.error ||
                    tr(
                      'Не удалось переключить Tachyon Lite',
                      'Failed to toggle Tachyon Lite',
                    ),
                  'error',
                );
                void renderSystemServicesWidget();
              }
            } catch (err: any) {
              showToast(
                err?.message ||
                  tr(
                    'Не удалось переключить Tachyon Lite',
                    'Failed to toggle Tachyon Lite',
                  ),
                'error',
              );
              void renderSystemServicesWidget();
            }
          },
        } as any,
        isLiteMode
          ? tr('Включён (MIPS Eco)', 'Enabled (MIPS Eco)')
          : tr('Выключен', 'Off'),
      ),
      attributes: {
        title: liteTooltip,
      },
    },
    {
      key: tr('Всего соединений', 'Active Connections'),
      value: E(
        'span',
        { class: 'tachyon-stat-pill tachyon-stat-pill--conns' },
        String(connectionsCount),
      ),
    },
    {
      key: tr('Секции правил', 'Routing Sections'),
      value: E(
        'span',
        { class: 'tachyon-stat-pill tachyon-stat-pill--conns' },
        String(activeSectionsCount),
      ),
    },
    {
      key: tr('Активные клиенты', 'Active Clients'),
      value: E(
        'span',
        { class: 'tachyon-stat-pill tachyon-stat-pill--conns' },
        String(activeClientsCount),
      ),
    },
  ];

  const cpuLoadPct =
    typeof srvData?.cpuLoadPercent === 'number' &&
    Number.isFinite(srvData.cpuLoadPercent)
      ? Math.max(0, Math.min(100, Math.round(srvData.cpuLoadPercent)))
      : null;
  const cpuTempC =
    typeof srvData?.cpuTempC === 'number' && Number.isFinite(srvData.cpuTempC)
      ? Math.round(srvData.cpuTempC)
      : null;

  if (cpuLoadPct !== null || cpuTempC !== null) {
    const cpuParts: string[] = [];
    if (cpuLoadPct !== null) {
      cpuParts.push(`${cpuLoadPct}%`);
    }
    if (cpuTempC !== null) {
      cpuParts.push(`${cpuTempC} °C`);
    }
    const isHot =
      (cpuTempC !== null && cpuTempC >= 80) ||
      (cpuLoadPct !== null && cpuLoadPct >= 90);
    const isWarm =
      !isHot &&
      ((cpuTempC !== null && cpuTempC >= 70) ||
        (cpuLoadPct !== null && cpuLoadPct >= 75));
    const pillStyle = isHot
      ? 'font-variant-numeric: tabular-nums; border-color: rgba(239, 68, 68, 0.45); background: rgba(239, 68, 68, 0.12); color: #ef4444;'
      : isWarm
        ? 'font-variant-numeric: tabular-nums; border-color: rgba(245, 158, 11, 0.45); background: rgba(245, 158, 11, 0.12); color: #f59e0b;'
        : 'font-variant-numeric: tabular-nums;';
    const cpuTitleParts: string[] = [];
    if (cpuLoadPct !== null) {
      cpuTitleParts.push(`${tr('Нагрузка CPU', 'CPU Load')}: ${cpuLoadPct}%`);
    }
    if (cpuTempC !== null) {
      cpuTitleParts.push(
        `${tr('Температура SoC/CPU', 'SoC/CPU Temp')}: ${cpuTempC} °C`,
      );
    }
    routingItems.push({
      key: tr('Процессор (CPU)', 'CPU Load & Temp'),
      value: E(
        'span',
        {
          class: 'tachyon-stat-pill tachyon-stat-pill--conns',
          style: pillStyle,
          'data-cpu-telemetry': '1',
        } as any,
        cpuParts.join(' • '),
      ),
      attributes: {
        title: cpuTitleParts.join(' | '),
      },
    });
  }

  const srvItems: Array<{
    key?: string | HTMLElement;
    value: string | HTMLElement | (string | HTMLElement)[];
    attributes?: Record<string, string>;
  }> = [];

  if (srvData) {
    const tachyonUptime = formatLocalizedUptime(
      srvData.tachyonUptimePretty,
      srvData.tachyonUptimeSeconds,
    );
    const tachyonTooltip = formatServiceTooltip({
      pid: srvData.tachyonPid,
      uptimePretty: tachyonUptime,
    });

    const singboxUptime = formatLocalizedUptime(
      srvData.singboxUptimePretty,
      srvData.singboxUptimeSeconds,
    );
    const singboxTooltip = formatServiceTooltip({
      pid: srvData.singboxPid,
      uptimePretty: singboxUptime,
    });

    srvItems.push(
      renderServiceRowItem('Tachyon', {
        running: srvData.tachyonRunning,
        memoryMb: srvData.tachyonMemoryMb,
        uptimePretty: tachyonUptime,
        tooltip: tachyonTooltip,
      }),
      renderServiceRowItem(
        (() => {
          if (srvData.engineVariant) {
            return srvData.engineVariant;
          }
          const systemInfo = store.get().diagnosticsSystemInfo;
          if (systemInfo?.sing_box_tachyon_core) {
            return 'Tachyon Core';
          }
          if (systemInfo?.sing_box_lx) {
            return 'Sing-box LX';
          }
          if (systemInfo?.sing_box_extended) {
            return 'Sing-box Ext';
          }
          return 'Sing-box';
        })(),
        {
          running: srvData.singbox,
          memoryMb: srvData.singboxMemoryMb,
          uptimePretty: singboxUptime,
          tooltip: singboxTooltip,
        },
      ),
    );

    if (srvData.dnsmasqRunning != null) {
      const dnsmasqUptime = formatLocalizedUptime(
        srvData.dnsmasqUptimePretty,
        srvData.dnsmasqUptimeSeconds,
      );
      const dnsmasqTooltip = formatServiceTooltip({
        pid: srvData.dnsmasqPid,
        uptimePretty: dnsmasqUptime,
      });

      srvItems.push(
        renderServiceRowItem('Dnsmasq (DNS)', {
          running: srvData.dnsmasqRunning,
          memoryMb: srvData.dnsmasqMemoryMb,
          uptimePretty: dnsmasqUptime,
          tooltip: dnsmasqTooltip,
        }),
      );
    }

    if (srvData.zapret2Running) {
      const zapret2Uptime = formatLocalizedUptime(
        srvData.zapret2UptimePretty,
        srvData.zapret2UptimeSeconds,
      );
      const zapret2Tooltip = formatServiceTooltip({
        pid: srvData.zapret2Pid,
        uptimePretty: zapret2Uptime,
      });

      srvItems.push(
        renderServiceRowItem('Zapret2', {
          running: srvData.zapret2Running,
          memoryMb: srvData.zapret2MemoryMb,
          uptimePretty: zapret2Uptime,
          tooltip: zapret2Tooltip,
        }),
      );
    }

    if (cpuLoadPct !== null || cpuTempC !== null) {
      const cpuPills: HTMLElement[] = [];
      if (cpuLoadPct !== null) {
        cpuPills.push(
          E(
            'span',
            { class: 'tachyon-service-pill tachyon-service-pill--ram' },
            `${cpuLoadPct}%`,
          ),
        );
      }
      if (cpuTempC !== null) {
        cpuPills.push(
          E(
            'span',
            { class: 'tachyon-service-pill tachyon-service-pill--uptime' },
            `${cpuTempC} °C`,
          ),
        );
      }
      const cpuTitleParts: string[] = [];
      if (cpuLoadPct !== null) {
        cpuTitleParts.push(`${tr('Нагрузка CPU', 'CPU Load')}: ${cpuLoadPct}%`);
      }
      if (cpuTempC !== null) {
        cpuTitleParts.push(
          `${tr('Температура SoC/CPU', 'SoC/CPU Temp')}: ${cpuTempC} °C`,
        );
      }
      srvItems.push({
        key: E('span', { class: 'tachyon-service-key' }, [
          E('span', {
            class: 'tachyon-service-dot tachyon-service-dot--online',
          }),
          E('span', { class: 'tachyon-service-name' }, 'CPU'),
        ]),
        value: E('span', { class: 'tachyon-service-value' }, cpuPills),
        attributes: {
          title: cpuTitleParts.join(' • '),
          class: 'tachyon-service-row--running',
        },
      });
    }
  }

  const stripContainer = document.getElementById(
    'dashboard-router-services-strip',
  );
  const sysViewMode = getWidgetViewMode('system_status') || 'card';
  const srvViewMode = getWidgetViewMode('router_services') || 'strip';

  if (stripContainer) {
    let routingWidget: HTMLElement;
    if (sysViewMode === 'tiles' && !loading && !failed) {
      routingWidget = E(
        'div',
        {
          class:
            'tachyon_dashboard-page__widgets-section__item tachyon-dual-card tachyon-system-tiles-card',
          'data-system-view': 'tiles',
        },
        [
          E('div', { class: 'tachyon-dual-card__header' }, [
            E(
              'span',
              { class: 'tachyon-dual-card__title-text' },
              tr('Маршрутизация и система', 'Routing & System'),
            ),
            E('span', {
              class: `tachyon-routing-row__status-dot ${
                isTachyonRunning ? 'is-online' : 'is-offline'
              }`,
              title: isTachyonRunning
                ? tr('Работает', 'Running')
                : tr('Остановлен', 'Stopped'),
            }),
          ]),
          E(
            'div',
            { class: 'tachyon-system-tiles-grid' },
            routingItems.map((item) =>
              E(
                'div',
                {
                  class: 'tachyon-system-tile',
                  ...(item.attributes || {}),
                },
                [
                  E(
                    'span',
                    { class: 'tachyon-system-tile__label' },
                    item.key || '',
                  ),
                  E('div', { class: 'tachyon-system-tile__val' }, item.value),
                ],
              ),
            ),
          ),
        ],
      );
    } else if (sysViewMode === 'cockpit_hud' && !loading && !failed) {
      routingWidget = E(
        'div',
        {
          class:
            'tachyon_dashboard-page__widgets-section__item tachyon-dual-card tachyon-system-hud-card',
          'data-system-view': 'cockpit_hud',
        },
        [
          E('div', { class: 'tachyon-system-hud-card__head' }, [
            E('div', { class: 'tachyon-system-hud-card__title-wrap' }, [
              E('span', {
                class: `tachyon-routing-row__status-dot ${
                  isTachyonRunning ? 'is-online' : 'is-offline'
                }`,
              }),
              E(
                'span',
                { class: 'tachyon-dual-card__title-text' },
                tr('Приборная панель ядра (HUD)', 'Core Telemetry HUD'),
              ),
            ]),
            E(
              'span',
              {
                class: `tachyon-system-hud-card__status-pill ${
                  isTachyonRunning ? 'is-online' : 'is-offline'
                }`,
              },
              isTachyonRunning
                ? tr('ЯДРО АКТИВНО', 'CORE ONLINE')
                : tr('ОСТАНОВЛЕНО', 'STOPPED'),
            ),
          ]),
          E(
            'div',
            { class: 'tachyon-system-hud-grid' },
            routingItems.map((item, idx) =>
              E(
                'div',
                {
                  class: `tachyon-system-hud-cell is-accent-${(idx % 4) + 1}`,
                  ...(item.attributes || {}),
                },
                [
                  E(
                    'span',
                    { class: 'tachyon-system-hud-cell__label' },
                    item.key || '',
                  ),
                  E(
                    'div',
                    { class: 'tachyon-system-hud-cell__val' },
                    item.value,
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    } else if (sysViewMode === 'banner' && !loading && !failed) {
      routingWidget = E(
        'div',
        {
          class:
            'tachyon_dashboard-page__widgets-section__item tachyon-dual-card tachyon-system-banner-card',
          'data-system-view': 'banner',
        },
        [
          E('div', { class: 'tachyon-system-banner-card__left' }, [
            E('span', {
              class: `tachyon-routing-row__status-dot ${
                isTachyonRunning ? 'is-online' : 'is-offline'
              }`,
              title: isTachyonRunning
                ? tr('Работает', 'Running')
                : tr('Остановлен', 'Stopped'),
            }),
            E(
              'strong',
              { class: 'tachyon-system-banner-card__title' },
              tr('Маршрутизация', 'Routing'),
            ),
          ]),
          E(
            'div',
            { class: 'tachyon-system-banner-card__items' },
            routingItems.map((item) =>
              E(
                'div',
                {
                  class: 'tachyon-system-banner-card__item',
                  ...(item.attributes || {}),
                },
                [
                  E(
                    'span',
                    { class: 'tachyon-system-banner-card__key' },
                    `${item.key || ''}:`,
                  ),
                  E(
                    'span',
                    { class: 'tachyon-system-banner-card__val' },
                    item.value,
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    } else {
      routingWidget = renderDualWidget({
        loading,
        failed,
        title: tr('Маршрутизация и правила', 'Routing & Rules'),
        badge: isTachyonRunning
          ? tr('Активна', 'Active')
          : tr('Остановлена', 'Stopped'),
        attributes: {
          class:
            'tachyon-dual-card--system-pinned tachyon-dual-card--single-col',
          'data-system-view': 'card',
        },
        columns: [
          {
            items: routingItems,
          },
        ],
      });
    }

    const nextRoutingSig = `${sysViewMode}|${loading}|${failed}|${isTachyonRunning}|${isLiteMode}|${connectionsCount}|${activeSectionsCount}|${activeClientsCount}|${cpuLoadPct ?? ''}|${cpuTempC ?? ''}`;
    if (
      container.childElementCount === 0 ||
      container.getAttribute('data-routing-sig') !== nextRoutingSig
    ) {
      container.setAttribute('data-routing-sig', nextRoutingSig);
      preserveScrollForPage(() => {
        container.replaceChildren(routingWidget);
      }, container);
    }

    if (loading || failed || srvItems.length === 0) {
      if (stripContainer.childElementCount > 0) {
        stripContainer.removeAttribute('data-strip-sig');
        stripContainer.replaceChildren();
      }
    } else if (srvViewMode === 'cards') {
      const servicesCards = E(
        'div',
        {
          class:
            'tachyon_dashboard-page__widgets-section__item tachyon-router-services-cards-wrap',
          'data-services-view': 'cards',
        },
        [
          E('div', { class: 'tachyon-router-services-cards-head' }, [
            E(
              'span',
              { class: 'tachyon-router-services-bar__title' },
              tr('Службы роутера', 'Router Services'),
            ),
          ]),
          E(
            'div',
            { class: 'tachyon-router-services-cards-grid' },
            srvItems.map((item) => {
              const rowAttrs: Record<string, unknown> = {
                class:
                  `tachyon-router-service-card ${item?.attributes?.class || ''}`.trim(),
              };
              if (item?.attributes?.title) {
                rowAttrs.title = item.attributes.title;
              }
              return E('div', rowAttrs, [
                E(
                  'div',
                  { class: 'tachyon-router-service-card__top' },
                  item.key || '',
                ),
                E(
                  'div',
                  { class: 'tachyon-router-service-card__bottom' },
                  item.value,
                ),
              ]);
            }),
          ),
        ],
      );
      const nextStripSig = `cards|${servicesCards.innerHTML}`;
      if (
        stripContainer.childElementCount === 0 ||
        stripContainer.getAttribute('data-strip-sig') !== nextStripSig
      ) {
        stripContainer.setAttribute('data-strip-sig', nextStripSig);
        preserveScrollForPage(() => {
          stripContainer.replaceChildren(servicesCards);
        }, stripContainer);
      }
    } else if (srvViewMode === 'resource_bars') {
      const servicesBars = E(
        'div',
        {
          class:
            'tachyon_dashboard-page__widgets-section__item tachyon-router-services-cards-wrap tachyon-router-services-resource-wrap',
          'data-services-view': 'resource_bars',
        },
        [
          E('div', { class: 'tachyon-router-services-cards-head' }, [
            E(
              'span',
              { class: 'tachyon-router-services-bar__title' },
              tr(
                'Ресурсы служб роутера (RAM)',
                'Router Services Resources (RAM)',
              ),
            ),
          ]),
          E(
            'div',
            { class: 'tachyon-router-services-resource-grid' },
            srvItems.map((item, idx) => {
              const titleStr = String(item?.attributes?.title || '');
              const mbMatch = titleStr.match(/(\d+(?:\.\d+)?)\s*(?:MB|МБ)/i);
              const mbVal = mbMatch ? parseFloat(mbMatch[1]) : 12 + idx * 8;
              const pct = Math.min(
                100,
                Math.max(8, Math.round((mbVal / 128) * 100)),
              );
              const rowAttrs: Record<string, unknown> = {
                class:
                  `tachyon-router-service-res-card ${item?.attributes?.class || ''}`.trim(),
              };
              if (item?.attributes?.title) {
                rowAttrs.title = item.attributes.title;
              }
              return E('div', rowAttrs, [
                E('div', { class: 'tachyon-router-service-res-card__top' }, [
                  E(
                    'div',
                    { class: 'tachyon-router-service-card__top' },
                    item.key || '',
                  ),
                  E(
                    'div',
                    { class: 'tachyon-router-service-card__bottom' },
                    item.value,
                  ),
                ]),
                E('div', { class: 'tachyon-router-service-res-card__bar' }, [
                  E('div', {
                    class: 'tachyon-router-service-res-card__bar-fill',
                    style: `width: ${pct}%;`,
                  }),
                ]),
              ]);
            }),
          ),
        ],
      );
      const nextStripSig = `resource_bars|${servicesBars.innerHTML}`;
      if (
        stripContainer.childElementCount === 0 ||
        stripContainer.getAttribute('data-strip-sig') !== nextStripSig
      ) {
        stripContainer.setAttribute('data-strip-sig', nextStripSig);
        preserveScrollForPage(() => {
          stripContainer.replaceChildren(servicesBars);
        }, stripContainer);
      }
    } else if (srvViewMode === 'minimal') {
      const servicesMinimal = E(
        'div',
        {
          class:
            'tachyon_dashboard-page__widgets-section__item tachyon-router-services-bar tachyon-router-services-bar--minimal',
          'data-services-view': 'minimal',
        },
        [
          E(
            'span',
            { class: 'tachyon-router-services-bar__title' },
            tr('Службы', 'Services'),
          ),
          E(
            'div',
            { class: 'tachyon-router-services-bar__list' },
            srvItems.map((item) => {
              const rowAttrs: Record<string, unknown> = {
                class:
                  `tachyon-router-services-bar__item tachyon-router-services-bar__item--minimal ${item?.attributes?.class || ''}`.trim(),
              };
              if (item?.attributes?.title) {
                rowAttrs.title = item.attributes.title;
              }
              return E('div', rowAttrs, [
                E(
                  'span',
                  { class: 'tachyon-router-services-bar__item-key' },
                  item.key || '',
                ),
              ]);
            }),
          ),
        ],
      );
      const nextStripSig = `minimal|${servicesMinimal.innerHTML}`;
      if (
        stripContainer.childElementCount === 0 ||
        stripContainer.getAttribute('data-strip-sig') !== nextStripSig
      ) {
        stripContainer.setAttribute('data-strip-sig', nextStripSig);
        preserveScrollForPage(() => {
          stripContainer.replaceChildren(servicesMinimal);
        }, stripContainer);
      }
    } else {
      const servicesBar = E(
        'div',
        {
          class:
            'tachyon_dashboard-page__widgets-section__item tachyon-router-services-bar',
          'data-services-view': 'strip',
        },
        [
          E(
            'span',
            { class: 'tachyon-router-services-bar__title' },
            tr('Службы роутера', 'Router Services'),
          ),
          E(
            'div',
            { class: 'tachyon-router-services-bar__list' },
            srvItems.map((item) => {
              const rowAttrs: Record<string, unknown> = {
                class:
                  `tachyon-router-services-bar__item ${item?.attributes?.class || ''}`.trim(),
              };
              if (item?.attributes?.title) {
                rowAttrs.title = item.attributes.title;
              }
              return E('div', rowAttrs, [
                E(
                  'span',
                  { class: 'tachyon-router-services-bar__item-key' },
                  item.key || '',
                ),
                E(
                  'span',
                  { class: 'tachyon-router-services-bar__item-val' },
                  item.value,
                ),
              ]);
            }),
          ),
        ],
      );

      const nextStripSig = `strip|${servicesBar.innerHTML}`;
      if (
        stripContainer.childElementCount === 0 ||
        stripContainer.getAttribute('data-strip-sig') !== nextStripSig
      ) {
        stripContainer.setAttribute('data-strip-sig', nextStripSig);
        preserveScrollForPage(() => {
          stripContainer.replaceChildren(servicesBar);
        }, stripContainer);
      }
    }
    return;
  }

  const widget = renderDualWidget({
    loading,
    failed,
    title: tr('Система и сервисы', 'System & Services'),
    badge: tr('Активна', 'Active'),
    attributes: {
      class: 'tachyon-dual-card--system-pinned',
    },
    columns: [
      {
        title: tr('Маршрутизация и правила', 'Routing & Rules'),
        items: routingItems,
      },
      {
        title: tr('Службы роутера', 'Router Services'),
        items: srvItems,
      },
    ],
  });

  preserveScrollForPage(() => {
    container.replaceChildren(widget);
  }, container);
}

let sectionWidgetsRenderFrame: number | null = null;
function scheduleSectionDashboardWidgetsRender() {
  if (sectionWidgetsRenderFrame !== null) return;
  const schedule = isUserActivelyScrolling()
    ? (cb: () => void) => setTimeout(cb, 250)
    : typeof requestAnimationFrame !== 'undefined'
      ? requestAnimationFrame
      : (cb: () => void) => setTimeout(cb, 16);
  sectionWidgetsRenderFrame = schedule(() => {
    sectionWidgetsRenderFrame = null;
    void renderSectionDashboardWidgets();
    renderInboundServersDashboardWidget({
      rawConnections: lastRawConnections,
      hostnames: cachedHostnames,
    });
  }) as unknown as number;
}

let systemServicesRenderFrame: number | null = null;
function scheduleSystemServicesWidgetRender() {
  if (systemServicesRenderFrame !== null) return;
  const schedule = isUserActivelyScrolling()
    ? (cb: () => void) => setTimeout(cb, 250)
    : typeof requestAnimationFrame !== 'undefined'
      ? requestAnimationFrame
      : (cb: () => void) => setTimeout(cb, 16);
  systemServicesRenderFrame = schedule(() => {
    systemServicesRenderFrame = null;
    void renderSystemServicesWidget();
  }) as unknown as number;
}

async function renderBandwidthWidget() {
  scheduleSectionDashboardWidgetsRender();
}

async function renderTrafficTotalWidget() {
  scheduleSectionDashboardWidgetsRender();
}

async function renderSystemInfoWidget() {
  scheduleSystemServicesWidgetRender();
}

async function renderServicesInfoWidget() {
  scheduleSystemServicesWidgetRender();
}

export function formatServiceRowValue(options: {
  running: boolean | number;
  memoryMb?: number;
  uptimePretty?: string;
  version?: string;
  extraSuffix?: string;
}): string {
  if (!options.running) {
    const versionPart = options.version
      ? ` [v${options.version.replace(/^v/, '')}]`
      : '';
    return `\u2717${versionPart}`;
  }

  const parts: string[] = ['\u2713'];
  if (options.memoryMb) {
    parts[0] += ` (${options.memoryMb} MB)`;
  }
  if (options.uptimePretty) {
    parts.push(options.uptimePretty);
  }
  let res = parts.join(' \u2022 ');
  if (options.version) {
    res += ` [v${options.version.replace(/^v/, '')}]`;
  }
  if (options.extraSuffix) {
    res += options.extraSuffix;
  }
  return res;
}

export function formatLocalizedUptime(
  uptimePretty?: string,
  uptimeSeconds?: number,
): string | undefined {
  if (uptimeSeconds != null && uptimeSeconds >= 0) {
    if (isRussianLanguage()) {
      if (uptimeSeconds < 60) return `${uptimeSeconds}с`;
      const min = Math.floor(uptimeSeconds / 60);
      if (min < 60) return `${min}м`;
      const hours = Math.floor(min / 60);
      const remMin = min % 60;
      if (hours < 24) return `${hours}ч ${remMin}м`;
      const days = Math.floor(hours / 24);
      const remHours = hours % 24;
      return `${days}д ${remHours}ч`;
    } else {
      if (uptimeSeconds < 60) return `${uptimeSeconds}s`;
      const min = Math.floor(uptimeSeconds / 60);
      if (min < 60) return `${min}m`;
      const hours = Math.floor(min / 60);
      const remMin = min % 60;
      if (hours < 24) return `${hours}h ${remMin}m`;
      const days = Math.floor(hours / 24);
      const remHours = hours % 24;
      return `${days}d ${remHours}h`;
    }
  }

  if (!uptimePretty) return undefined;

  if (!isRussianLanguage()) {
    return uptimePretty
      .replace(/(\d+)\s*д/g, '$1d ')
      .replace(/(\d+)\s*ч/g, '$1h ')
      .replace(/(\d+)\s*м/g, '$1m ')
      .replace(/(\d+)\s*с/g, '$1s ')
      .replace(/\s+/g, ' ')
      .trim();
  }

  return uptimePretty;
}

export function formatServiceTooltip(options: {
  pid?: number;
  uptimePretty?: string;
}): string | undefined {
  const parts: string[] = [];
  if (options.pid) {
    parts.push(`PID: ${options.pid}`);
  }
  if (options.uptimePretty) {
    parts.push(`${tr('Время работы', 'Uptime')}: ${options.uptimePretty}`);
  }
  return parts.length > 0 ? parts.join(' \u2022 ') : undefined;
}

export function renderServiceRowItem(
  name: string,
  options: {
    running: boolean | number;
    memoryMb?: number;
    uptimePretty?: string;
    version?: string;
    extraSuffix?: string;
    tooltip?: string;
  },
) {
  const isRunning = Boolean(options.running);
  const keyEl = E('span', { class: 'tachyon-service-key' }, [
    E('span', {
      class: `tachyon-service-dot ${isRunning ? 'tachyon-service-dot--online' : 'tachyon-service-dot--offline'}`,
    }),
    E('span', { class: 'tachyon-service-name' }, name),
  ]);

  const valueChildren: HTMLElement[] = [];
  if (isRunning) {
    const hasMemory = options.memoryMb != null && options.memoryMb > 0;
    const hasUptime = Boolean(options.uptimePretty);

    if (hasMemory) {
      valueChildren.push(
        E(
          'span',
          { class: 'tachyon-service-pill tachyon-service-pill--ram' },
          `${options.memoryMb} MB`,
        ),
      );
    } else if (hasUptime) {
      valueChildren.push(
        E(
          'span',
          {
            class:
              'tachyon-service-pill tachyon-service-pill--ram tachyon-service-pill--empty',
          },
          '—',
        ),
      );
    }

    if (hasUptime) {
      valueChildren.push(
        E(
          'span',
          { class: 'tachyon-service-pill tachyon-service-pill--uptime' },
          options.uptimePretty,
        ),
      );
    } else if (hasMemory) {
      valueChildren.push(
        E(
          'span',
          {
            class:
              'tachyon-service-pill tachyon-service-pill--uptime tachyon-service-pill--empty',
          },
          '—',
        ),
      );
    }

    if (options.version) {
      valueChildren.push(
        E(
          'span',
          { class: 'tachyon-service-pill tachyon-service-pill--version' },
          `v${options.version.replace(/^v/, '')}`,
        ),
      );
    }
    if (options.extraSuffix) {
      valueChildren.push(
        E(
          'span',
          { style: 'font-size: 11px; opacity: 0.8;' },
          options.extraSuffix,
        ),
      );
    }
    if (valueChildren.length === 0) {
      valueChildren.push(
        E(
          'span',
          { class: 'tachyon-service-pill tachyon-service-pill--active' },
          tr('Работает', 'Active'),
        ),
      );
    }
  } else {
    valueChildren.push(
      E(
        'span',
        { class: 'tachyon-service-pill tachyon-service-pill--stopped' },
        tr('Остановлен', 'Stopped'),
      ),
    );
    if (options.version) {
      valueChildren.push(
        E(
          'span',
          { class: 'tachyon-service-pill tachyon-service-pill--version' },
          `v${options.version.replace(/^v/, '')}`,
        ),
      );
    }
  }

  const valueEl = E('span', { class: 'tachyon-service-value' }, valueChildren);

  return {
    key: keyEl,
    value: valueEl,
    attributes: {
      class: isRunning
        ? 'tachyon_dashboard-page__widgets-section__item__row--success'
        : 'tachyon_dashboard-page__widgets-section__item__row--error',
      ...(options.tooltip ? { title: options.tooltip } : {}),
    },
  };
}

let latestTailscalePeersRequestId = 0;

async function fetchTailscalePeers() {
  const requestId = ++latestTailscalePeersRequestId;
  try {
    const response = await TachyonShellMethods.getTailscalePeers();
    if (requestId !== latestTailscalePeersRequestId) return;
    store.set({
      tailscaleWidget: {
        loading: false,
        failed: !response.success,
        data: response.success ? response.data : null,
      },
    });
  } catch {
    if (requestId !== latestTailscalePeersRequestId) return;
    store.set({
      tailscaleWidget: {
        loading: false,
        failed: true,
        data: store.get().tailscaleWidget.data,
      },
    });
  }
}

function peerRow(name: string, online: boolean) {
  return {
    key: name,
    value: E(
      'span',
      {
        style: 'display: inline-flex; align-items: center; gap: 4px;',
      },
      [
        online ? renderCheckIcon(10) : renderXIcon(10),
        online ? tr('В сети', 'Online') : tr('Не в сети', 'Offline'),
      ],
    ),
    attributes: {
      class: online
        ? 'tachyon_dashboard-page__widgets-section__item__row--success'
        : 'tachyon_dashboard-page__widgets-section__item__row--error',
    },
  };
}

async function renderTailscaleWidget() {
  const widgetState = store.get().tailscaleWidget;
  const container = document.getElementById('dashboard-widget-tailscale');
  if (!container) return;

  if (
    !widgetState.loading &&
    !widgetState.failed &&
    (!widgetState.data || !widgetState.data.configured)
  ) {
    container.style.display = 'none';
    container.replaceChildren();
    return;
  }
  container.style.display = '';

  renderStoreWidget(
    'dashboard-widget-tailscale',
    'tailscaleWidget',
    'Tailscale',
    (data) => {
      type WidgetItem = {
        key: string | HTMLElement;
        value: string | HTMLElement | (string | HTMLElement)[];
        attributes?: Record<string, string>;
      };
      if (!data || !data.configured) return [] as WidgetItem[];
      const items: WidgetItem[] = [
        {
          key: tr('Состояние', 'State'),
          value:
            data.backend_state === 'Running'
              ? tr('Работает', 'Running')
              : data.backend_state || '—',
          attributes: {
            class:
              data.backend_state === 'Running'
                ? 'tachyon_dashboard-page__widgets-section__item__row--success'
                : 'tachyon_dashboard-page__widgets-section__item__row--error',
          },
        },
      ];
      if (data.self && data.self.ips.length) {
        items.push({
          key: tr('Этот роутер', 'This router'),
          value: data.self.ips[0],
        });
      }
      for (const peer of data.peers.slice(0, 5)) {
        if (!peer.online && !peer.name) continue;
        items.push(
          peerRow(peer.name || peer.dns_name || peer.ips[0], peer.online),
        );
      }
      if (data.peers.length > 5) {
        items.push({
          key: tr('Другие пиры', 'Other peers'),
          value: `+${data.peers.length - 5}`,
        });
      }
      return items;
    },
    'renderTailscaleWidget',
  );
}

async function onStoreUpdate(
  next: StoreType,
  prev: StoreType,
  diff: Partial<StoreType>,
) {
  if (diff.sectionsWidget) {
    const inlineUpdated =
      canUpdateLatencyProgressInline(
        prev.sectionsWidget,
        next.sectionsWidget,
      ) && updateLatencyProgressInline(next.sectionsWidget);

    if (!inlineUpdated) {
      const dataChanged =
        prev.sectionsWidget.loading !== next.sectionsWidget.loading ||
        prev.sectionsWidget.failed !== next.sectionsWidget.failed ||
        JSON.stringify(prev.sectionsWidget.data) !==
          JSON.stringify(next.sectionsWidget.data);

      if (dataChanged) {
        scheduleSectionsWidgetRender();
        renderTrafficTotalWidget();
      }
    }
  }

  if (diff.bandwidthWidget || diff.trafficTotalWidget) {
    scheduleSectionDashboardWidgetsRender();
  }

  if (diff.systemInfoWidget || diff.servicesInfoWidget) {
    if (diff.servicesInfoWidget) {
      syncDashboardServiceAvailability();
    }
    scheduleSystemServicesWidgetRender();
  }

  if (diff.tailscaleWidget) {
    renderTailscaleWidget();
  }
}

async function onPageMount() {
  onPageUnmount();
  expandedRoutingSections.clear();

  dashboardMounted = true;
  dashboardMountId += 1;
  const mountId = dashboardMountId;
  const hasRuntimeSnapshot = Boolean(getCachedRuntimeUiState());

  applyDashboardLayoutToDom();
  if (!layoutChangesUnsubscribe) {
    layoutChangesUnsubscribe = subscribeDashboardLayoutChanges(() => {
      if (!dashboardMounted) return;
      applyDashboardLayoutToDom();
      void renderSectionsWidget();
      void renderSectionDashboardWidgets();
      void renderSystemServicesWidget();
      renderConnectionsWidget();
      renderInboundServersDashboardWidget({
        rawConnections: lastRawConnections,
        hostnames: cachedHostnames,
      });
    });
  }
  store.subscribe(onStoreUpdate);
  startActionStateWatcher();
  void renderSectionsWidget();
  void renderConnectionsWidget();
  void renderBandwidthWidget();
  void renderTrafficTotalWidget();
  void renderSystemInfoWidget();
  void renderServicesInfoWidget();
  void renderTailscaleWidget();
  renderInboundServersDashboardWidget({
    rawConnections: lastRawConnections,
    hostnames: cachedHostnames,
  });
  syncDashboardServiceAvailability();
  void fetchTailscalePeers();

  void refreshRuntimeUiState({ force: true }).then((uiState) => {
    if (!dashboardMounted || mountId !== dashboardMountId) {
      return;
    }
    if (!uiState && !hasRuntimeSnapshot) {
      void fetchServicesInfo();
      void fetchTailscalePeers();
    }
  });
}

function onPageUnmount() {
  dashboardMounted = false;
  dashboardMountId += 1;
  dashboardVisibilityPaused = false;

  directSocketsFailed = false;
  trafficRatesState = createInitialTrafficRatesState();

  if (sectionWidgetsRenderFrame !== null) {
    if (typeof cancelAnimationFrame !== 'undefined') {
      cancelAnimationFrame(sectionWidgetsRenderFrame);
    } else {
      clearTimeout(sectionWidgetsRenderFrame);
    }
    sectionWidgetsRenderFrame = null;
  }
  if (systemServicesRenderFrame !== null) {
    if (typeof cancelAnimationFrame !== 'undefined') {
      cancelAnimationFrame(systemServicesRenderFrame);
    } else {
      clearTimeout(systemServicesRenderFrame);
    }
    systemServicesRenderFrame = null;
  }
  if (connectionsRenderFrame !== null) {
    if (typeof cancelAnimationFrame !== 'undefined') {
      cancelAnimationFrame(connectionsRenderFrame);
    } else {
      clearTimeout(connectionsRenderFrame);
    }
    connectionsRenderFrame = null;
  }
  if (connectionsHoverDeferredTimer !== null) {
    clearTimeout(connectionsHoverDeferredTimer);
    connectionsHoverDeferredTimer = null;
  }
  connectionsWidgetHovered = false;
  connectionsWidgetListenersAttached = false;
  if (sectionsRenderFrame !== null) {
    if (typeof cancelAnimationFrame !== 'undefined') {
      cancelAnimationFrame(sectionsRenderFrame);
    } else {
      clearTimeout(sectionsRenderFrame);
    }
    sectionsRenderFrame = null;
  }

  if (layoutChangesUnsubscribe) {
    layoutChangesUnsubscribe();
    layoutChangesUnsubscribe = null;
  }
  stopDashboardDataUpdates();
  stopActionStateWatcher();
  sectionsRefreshQueued = false;
  sectionsRefreshPromise = null;
  probedPriorityMemberTags.clear();
  warmingPriorityLatencies = false;
  store.unsubscribe(onStoreUpdate);
  store.reset(['bandwidthWidget', 'trafficTotalWidget', 'systemInfoWidget']);
}

let layoutChangesUnsubscribe: (() => void) | null = null;
let dashboardLifecycleRegistered = false;
let dashboardControllerInitialized = false;

function registerLifecycleListeners() {
  if (dashboardLifecycleRegistered) {
    return;
  }

  dashboardLifecycleRegistered = true;

  store.subscribe((next, prev, diff) => {
    if (
      diff.tabService &&
      next.tabService.current !== prev.tabService.current
    ) {
      logger.debug(
        '[DASHBOARD]',
        'active tab diff event, active tab:',
        diff.tabService.current,
      );
      const isDashboardVisible = next.tabService.current === 'dashboard';

      if (isDashboardVisible) {
        logger.debug(
          '[DASHBOARD]',
          'registerLifecycleListeners',
          'onPageMount',
        );
        return onPageMount();
      }

      if (!isDashboardVisible) {
        logger.debug(
          '[DASHBOARD]',
          'registerLifecycleListeners',
          'onPageUnmount',
        );
        return onPageUnmount();
      }
    }
  });
}

export async function initController(): Promise<void> {
  if (dashboardControllerInitialized) {
    return;
  }

  dashboardControllerInitialized = true;

  onMount('dashboard-status').then(() => {
    logger.debug('[DASHBOARD]', 'initController', 'onMount');
    registerLifecycleListeners();
    if (
      store.get().tabService.current === 'dashboard' ||
      isActiveLuciTab('dashboard')
    ) {
      onPageMount();
    }
  });
}
