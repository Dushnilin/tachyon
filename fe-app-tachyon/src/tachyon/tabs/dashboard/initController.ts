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
import { renderCopyIcon24, renderLoaderCircleIcon24 } from '../../../icons';
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
  getLatencyTestLabel,
  renderFlagEmojis,
  renderSections,
  renderWidget,
  renderDualWidget,
  renderConnections,
  patchConnections,
  patchExistingClientRowsByIp,
  IConnection,
} from './partials';
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
  getConfiguredServerInbounds,
  renderInboundServersDashboardWidget,
  switchToServersTab,
} from './inboundServers';

let expandedSections = getExpandedSections();

function toggleSectionExpanded(sectionCode: string) {
  const result = toggleSectionExpansion(expandedSections, sectionCode);
  expandedSections = result.nextSections;
  if (result.expanded && sectionCode === 'active_clients') {
    void fetchConnections();
  }
  void renderSectionsWidget();
  void renderConnectionsWidget();
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
const singleTestingOutboundCodes: Record<string, boolean> = {};
let isTestingAllSections = false;

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

  const activeEngine = store.get().activeEngine;
  const isSteer = activeEngine === 'steer' || activeEngine === 'steer-extended';

  if (isSteer || !canUseDirectClashApi()) {
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

function getInitialLatencyProgress(
  latencyType: Tachyon.LatencyActionState['latency_type'],
  tag: string,
): Tachyon.LatencyActionProgress | undefined {
  if (latencyType !== 'proxy_list') {
    return undefined;
  }

  try {
    const tags = JSON.parse(tag);
    if (!Array.isArray(tags)) {
      return undefined;
    }

    const total = tags.filter(
      (item) => typeof item === 'string' && item.length > 0,
    ).length;

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
    try {
      const parsed = JSON.parse(tag);
      if (Array.isArray(parsed)) {
        return parsed.filter(
          (item): item is string => typeof item === 'string' && item.length > 0,
        );
      }
    } catch {
      return [];
    }
  }

  if (latencyType === 'group') {
    const section = store
      .get()
      .sectionsWidget.data.find((s) => s.sectionName === sectionName);
    if (section?.outbounds) {
      return section.outbounds
        .filter(
          (o) => !['SING_BOX', 'ZAPRET', 'ZAPRET2', 'BYEDPI'].includes(o.type),
        )
        .map((o) => o.code);
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
        (prevTime != null ? currentTime !== prevTime : isFreshTimestamp);

      if (isNewMeasurement && delay > 0) {
        customProxyLatencies.set(tag, delay);
      } else {
        // Tag was tested, but either timed out (no history / old history) or errored
        customProxyLatencies.set(tag, -1);
      }
    }

    capMapSize(customProxyLatencies);
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
    getInitialLatencyProgress(latencyType, tag),
  );
  let jobId = '';
  let ownsJobFollow = false;
  let completed = false;
  const testedTags = extractTestedTags(latencyType, sectionName, tag);
  const testStartedAt = Date.now();
  const beforeTimes = new Map<string, string>();

  if (testedTags.length > 0 && latencyType !== 'proxy') {
    try {
      const beforeProxiesRes = await TachyonShellMethods.getClashApiProxies();
      if (beforeProxiesRes.success && beforeProxiesRes.data) {
        const proxies = (beforeProxiesRes.data as any)?.proxies || {};
        for (const t of testedTags) {
          const time = (proxies[t] || proxies[t.trim()])?.history?.[0]?.time;
          if (typeof time === 'string') {
            beforeTimes.set(t, time);
          }
        }
      }
    } catch (e) {
      logger.debug('[DASHBOARD]', 'snapshot proxies before test failed', e);
    }
  }

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
      await TachyonShellMethods.waitLatencyTestJob(jobId);
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
    const SERVICE_TYPES = new Set(['SING_BOX', 'ZAPRET', 'ZAPRET2', 'BYEDPI']);
    for (const section of sectionsWidget.data) {
      if (!section.outbounds || section.outbounds.length === 0) {
        continue;
      }
      if (sectionsWidget.latencyFetchingSections[section.sectionName]) {
        continue;
      }
      const testable = section.outbounds.filter(
        (o) => !SERVICE_TYPES.has(o.type),
      );
      if (testable.length === 0) {
        continue;
      }

      if (section.withTagSelect) {
        const tag = section.latencyTestCodes?.length
          ? section.latencyTestCodes
          : section.latencyTestCode || section.code;
        if (Array.isArray(tag)) {
          await handleTestLatency(
            'proxy_list',
            section.sectionName,
            JSON.stringify(tag),
            section.latencyTestTimeout,
          );
        } else {
          await handleTestLatency(
            'group',
            section.sectionName,
            tag,
            section.latencyTestTimeout,
          );
        }
      } else {
        await handleTestLatency(
          'proxy',
          section.sectionName,
          testable[0].code,
          section.latencyTestTimeout,
        );
      }
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
          ]
        : []),
      modeBadge,
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
        { class: 'tachyon_dashboard-page__urltest-details__outbounds-title' },
        _('Nodes'),
      ),
      E(
        'div',
        { class: 'tachyon_dashboard-page__urltest-details__table' },
        info.outbounds.length
          ? info.outbounds.map((member: any) => {
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
                      class:
                        'tachyon_dashboard-page__urltest-details__row-name',
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
                      class:
                        'tachyon_dashboard-page__urltest-details__row-actions',
                    },
                    [
                      E(
                        'div',
                        {
                          class:
                            'tachyon_dashboard-page__urltest-details__row-meta',
                        },
                        [
                          E(
                            'span',
                            { class: getUrlTestLatencyClass(member.latency) },
                            formatUrlTestLatency(member.latency),
                          ),
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
                              section.outbounds.some(
                                (o) => o.code === member.code,
                              )
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
                                            s.sectionName ===
                                            section.sectionName,
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
                      member.canCopyLink
                        ? renderUrlTestCopyButton(
                            _('Copy proxy link'),
                            (event) => {
                              event.preventDefault();
                              void handleCopyOutbound(member);
                            },
                          )
                        : E('span', {
                            class:
                              'tachyon_dashboard-page__urltest-details__copy-placeholder',
                          }),
                    ],
                  ),
                ],
              );
            })
          : [
              E(
                'div',
                { class: 'tachyon_dashboard-page__urltest-details__empty' },
                _('Node list is empty'),
              ),
            ],
      ),
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
            ui.hideModal();
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

  const fields: Array<{
    label: string;
    value?: unknown;
    children?: Array<HTMLElement | string>;
  }> = [
    {
      label: _('Selected'),
      children: [renderUrlTestSelectedValue(info)],
    },
    { label: _('Testing URL'), children: [renderDetailsUrl(info.url)] },
    { label: _('Interval'), value: info.interval },
    { label: _('Tolerance'), value: info.tolerance },
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

function handleShowUrlTestInfo(
  section: Tachyon.OutboundGroup,
  outbound: Tachyon.Outbound,
) {
  if (!outbound.urlTestInfo) {
    return;
  }

  ui.showModal(
    `${_('URLTest details')}: ${
      outbound.urlTestInfo.displayName || outbound.displayName
    }`,
    renderUrlTestInfoModal(outbound, section),
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
          ]
        : []),
      modeBadge,
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

  const fields: Array<{
    label: string;
    value?: unknown;
    children?: Array<HTMLElement | string>;
  }> = [
    {
      label: _('Selected'),
      children: [renderPrioritySelectedValue(info)],
    },
    { label: _('Check URL'), children: [renderDetailsUrl(info.healthUrl)] },
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

    const withLatencies: Tachyon.PriorityInfo = {
      ...info,
      outbounds: (info.outbounds || []).map((member) => {
        const delay = measured.get(String(member.code || ''));
        return delay === undefined ? member : { ...member, latency: delay };
      }),
    };

    body.replaceChildren(
      renderPriorityInfoModal(
        { ...outbound, priorityInfo: withLatencies },
        section,
      ),
    );
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
  return Array.from(
    container.querySelectorAll<HTMLButtonElement>(
      `.${LATENCY_TEST_BUTTON_CLASS}`,
    ),
  ).find((button) => button.dataset.latencySection === sectionName);
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
  const schedule =
    typeof requestAnimationFrame !== 'undefined'
      ? requestAnimationFrame
      : (cb: () => void) => setTimeout(cb, 16);
  sectionsRenderFrame = schedule(() => {
    sectionsRenderFrame = null;
    void renderSectionsWidget();
  }) as unknown as number;
}

async function renderSectionsWidget() {
  logger.debug('[DASHBOARD]', 'renderSectionsWidget');
  const sectionsWidget = store.get().sectionsWidget;
  const container = document.getElementById('dashboard-sections-grid');

  if (!container) {
    return;
  }

  if (isUserActivelyScrolling()) {
    scheduleSectionsWidgetRender();
    return;
  }

  const SERVICE_TYPES = new Set(['SING_BOX', 'ZAPRET', 'ZAPRET2', 'BYEDPI']);

  const sectionsWithCustomLatencies = sectionsWidget.data.map((section) => ({
    ...section,
    outbounds: section.outbounds.map((outbound) => {
      const customLatency = customProxyLatencies.get(outbound.code);
      const latency =
        SERVICE_TYPES.has(outbound.type) || customLatency == null
          ? outbound.latency
          : customLatency;

      const urlTestInfo = outbound.urlTestInfo
        ? {
            ...outbound.urlTestInfo,
            outbounds: outbound.urlTestInfo.outbounds.map((member) => ({
              ...member,
              latency: customProxyLatencies.has(member.code)
                ? customProxyLatencies.get(member.code)!
                : member.latency,
            })),
          }
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
    }),
  }));

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

  const hasTestableSections = sectionsWithCustomLatencies.some(
    (s) =>
      s.outbounds &&
      s.outbounds.length > 0 &&
      !SERVICE_TYPES.has(s.outbounds[0]?.type),
  );

  const testAllHeader = hasTestableSections
    ? E(
        'div',
        {
          class: 'tachyon_dashboard-page__sections-header',
        },
        [
          E(
            'div',
            {
              class: 'tachyon_dashboard-page__sections-header__title',
            },
            [
              svgEl(
                'svg',
                {
                  width: '16',
                  height: '16',
                  viewBox: '0 0 24 24',
                  fill: 'none',
                  stroke: 'currentColor',
                  'stroke-width': '2',
                  'stroke-linecap': 'round',
                  'stroke-linejoin': 'round',
                },
                [
                  svgEl('circle', { cx: '6', cy: '19', r: '3' }),
                  svgEl('path', {
                    d: 'M9 19h8.5a3.5 3.5 0 0 0 0-7h-11a3.5 3.5 0 0 1 0-7H15',
                  }),
                  svgEl('circle', { cx: '18', cy: '5', r: '3' }),
                ],
              ),
              E('span', {}, _('Routing sections')),
            ],
          ),
          E(
            'div',
            {
              class: 'tachyon_dashboard-page__sections-header__actions',
            },
            [
              E(
                'button',
                {
                  type: 'button',
                  id: 'dashboard-test-all-sections-button',
                  class: 'btn',
                  disabled: isTestingAllSections ? true : undefined,
                  click: () => {
                    void handleTestAllSections();
                  },
                },
                isTestingAllSections
                  ? [
                      renderLoaderCircleIcon24(),
                      E('span', {}, _('Testing all sections...')),
                    ]
                  : E('span', {}, _('Test all sections')),
              ),
            ],
          ),
        ],
      )
    : null;

  const renderedWidgets: HTMLElement[] = [];
  let pendingServiceCards: HTMLElement[] = [];

  const flushServiceCards = () => {
    if (pendingServiceCards.length === 0) return;
    if (pendingServiceCards.length === 1) {
      renderedWidgets.push(pendingServiceCards[0]);
    } else {
      renderedWidgets.push(
        E(
          'div',
          { class: 'tachyon_dashboard-page__service-sections-row' },
          pendingServiceCards,
        ),
      );
    }
    pendingServiceCards = [];
  };

  for (const section of sectionsWithCustomLatencies) {
    const widget = renderSections({
      loading: sectionsWidget.loading,
      failed: sectionsWidget.failed,
      section,
      isCollapsed: !expandedSections.has(section.code),
      onToggleCollapse: () => toggleSectionExpanded(section.code),
      collapsedSourceGroups: expandedSections,
      onToggleSourceGroupCollapse: (groupKey: string) =>
        toggleSectionExpanded(groupKey),
      activeCountryFilter: activeCountryFilters.get(section.sectionName),
      onFilterCountry: (sectionName: string, countryCode?: string) => {
        if (countryCode) {
          activeCountryFilters.set(sectionName, countryCode);
        } else {
          activeCountryFilters.delete(sectionName);
        }
        void renderSectionsWidget();
      },
      activeRegionFilter: activeRegionFilters.get(section.sectionName) || 'all',
      onFilterRegion: (sectionName: string, region: string) => {
        activeRegionFilters.set(sectionName, region);
        activeCountryFilters.delete(sectionName);
        void renderSectionsWidget();
      },
      latencyFetching: Boolean(
        sectionsWidget.latencyFetchingSections[section.sectionName],
      ),
      latencyProgress:
        sectionsWidget.latencyProgressSections[section.sectionName],
      subscriptionUpdating: Boolean(
        sectionsWidget.subscriptionUpdatingSections[section.sectionName],
      ),
      selectorSwitchingTag:
        sectionsWidget.selectorSwitchingSections[section.sectionName],
      onTestSingleOutbound: (sectionName, outboundCode) => {
        void handleTestSingleOutbound(sectionName, outboundCode);
      },
      testingOutboundCodes: singleTestingOutboundCodes,
      onTestLatency: (tag) => {
        if (section.withTagSelect) {
          if (Array.isArray(tag)) {
            return handleTestLatency(
              'proxy_list',
              section.sectionName,
              JSON.stringify(tag),
            );
          }

          return handleTestLatency('group', section.sectionName, tag);
        }

        return handleTestLatency(
          'proxy',
          section.sectionName,
          Array.isArray(tag) ? JSON.stringify(tag) : tag,
          section.latencyTestTimeout,
        );
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
    });

    if (isServiceGroup(section)) {
      pendingServiceCards.push(widget);
    } else {
      flushServiceCards();
      renderedWidgets.push(widget);
    }
  }
  flushServiceCards();

  return preserveScrollForPage(() => {
    container.replaceChildren(
      ...(testAllHeader ? [testAllHeader] : []),
      ...renderedWidgets,
    );
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
  const activeEngine = store.get().activeEngine;
  const isSteer = activeEngine === 'steer' || activeEngine === 'steer-extended';
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
    directSocketsFailed || !canUseDirectClashApi() || isSteer || isLiteMode;
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
  const schedule =
    typeof requestAnimationFrame !== 'undefined'
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

  const isCollapsed = !expandedSections.has('active_clients');

  // Fast-path in-place DOM update without replacing children
  if (
    patchConnections(
      container,
      currentConnections,
      isCollapsed,
      currentTopDomains,
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
  if (totalProxySections <= 1) {
    return {
      conns: rawConns.length,
      upload: totals.uploadTotal || 0,
      download: totals.downloadTotal || 0,
      downSpeed: totals.downSpeed || 0,
      upSpeed: totals.upSpeed || 0,
    };
  }

  const target = (sectionName || '').toLowerCase();
  let conns = 0;
  let upload = 0;
  let download = 0;
  let downSpeed = 0;
  let upSpeed = 0;

  for (const c of rawConns) {
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

export async function renderSectionDashboardWidgets() {
  const container = document.getElementById('dashboard-widgets-sections-list');
  if (!container) return;

  const sectionsWidget = store.get().sectionsWidget;
  const sectionsWithCustomLatencies = sectionsWidget.data.map((section) => ({
    ...section,
    outbounds: section.outbounds.map((outbound) => {
      const customLatency = customProxyLatencies.get(outbound.code);
      return {
        ...outbound,
        latency: customLatency ?? outbound.latency,
        urlTestInfo: outbound.urlTestInfo
          ? {
              ...outbound.urlTestInfo,
              outbounds: outbound.urlTestInfo.outbounds.map((member) => ({
                ...member,
                latency:
                  customProxyLatencies.get(member.code) ?? member.latency,
              })),
            }
          : undefined,
        priorityInfo: outbound.priorityInfo
          ? {
              ...outbound.priorityInfo,
              outbounds: outbound.priorityInfo.outbounds.map((member) => ({
                ...member,
                latency:
                  customProxyLatencies.get(member.code) ?? member.latency,
              })),
            }
          : undefined,
      };
    }),
  }));

  const activeRoutes = getAllActiveRoutes(sectionsWithCustomLatencies);
  const isCheckingLatency =
    Object.keys(sectionsWidget.latencyFetchingSections || {}).length > 0 ||
    Object.keys(singleTestingOutboundCodes).length > 0;

  const bandwidth = store.get().bandwidthWidget.data;
  const total = store.get().trafficTotalWidget.data;
  const loading = sectionsWidget.loading;
  const failed = sectionsWidget.failed;

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
  const enabledInboundsCount = isTachyonRunning
    ? getConfiguredServerInbounds().filter((s) => s.enabled).length
    : 0;
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
          ? tr('⚡ Включён (MIPS Eco)', '⚡ Enabled (MIPS Eco)')
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

  if (enabledInboundsCount > 0) {
    routingItems.push({
      key: tr('Входящие серверы', 'Inbound Servers'),
      value: E(
        'span',
        {
          class: 'tachyon-stat-pill tachyon-stat-pill--conns',
          style: 'cursor: pointer;',
        },
        `${enabledInboundsCount} ${tr('активных', 'active')}`,
      ),
      onClick: () => switchToServersTab(),
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
          if (
            store.get().activeEngine === 'steer' ||
            store.get().activeEngine === 'steer-extended'
          ) {
            return 'Steer';
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
  const schedule =
    typeof requestAnimationFrame !== 'undefined'
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
  const schedule =
    typeof requestAnimationFrame !== 'undefined'
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
    value: online
      ? tr('✔ В сети', '✔ Online')
      : tr('✘ Не в сети', '✘ Offline'),
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

  dashboardMounted = true;
  dashboardMountId += 1;
  const mountId = dashboardMountId;
  const hasRuntimeSnapshot = Boolean(getCachedRuntimeUiState());

  if (!hasRuntimeSnapshot) {
    const uiState = await refreshRuntimeUiState({ force: true });

    if (!dashboardMounted || mountId !== dashboardMountId) {
      return;
    }

    if (!uiState) {
      void fetchServicesInfo();
      void fetchTailscalePeers();
    }
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

  if (hasRuntimeSnapshot) {
    void refreshRuntimeUiState({ force: true });
  }
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

  stopDashboardDataUpdates();
  stopActionStateWatcher();
  sectionsRefreshQueued = false;
  sectionsRefreshPromise = null;
  store.unsubscribe(onStoreUpdate);
  store.reset(['bandwidthWidget', 'trafficTotalWidget', 'systemInfoWidget']);
}

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
