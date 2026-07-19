/* eslint-disable @typescript-eslint/no-explicit-any */
import {
  getClashWsUrl,
  isCopyableProxyLink,
  onMount,
  preserveScrollForPage,
} from '../../../helpers';
import { copyToClipboard } from '../../../helpers/copyToClipboard';
import { showToast } from '../../../helpers/showToast';
import { prettyBytes } from '../../../helpers/prettyBytes';
import { renderCopyIcon24 } from '../../../icons';
import { CustomTachyonMethods, TachyonShellMethods } from '../../methods';
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
  renderConnections,
  IConnection,
} from './partials';
import { fetchServicesInfo } from '../../fetchers/fetchServicesInfo';
import { fetchHostnames } from '../../fetchers/fetchHostnames';

const DASHBOARD_COLLAPSED_SECTIONS_KEY = 'tachyon_dashboard_collapsed_sections';
const collapsedSections = new Set<string>(
  JSON.parse(localStorage.getItem(DASHBOARD_COLLAPSED_SECTIONS_KEY) || '[]')
);

function toggleSectionCollapsed(sectionCode: string) {
  if (collapsedSections.has(sectionCode)) {
    collapsedSections.delete(sectionCode);
  } else {
    collapsedSections.add(sectionCode);
  }
  localStorage.setItem(DASHBOARD_COLLAPSED_SECTIONS_KEY, JSON.stringify(Array.from(collapsedSections)));
  void renderSectionsWidget();
}
import { getClashApiSecret } from '../../methods/custom/getClashApiSecret';
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

const SECTIONS_REFRESH_INTERVAL_MS = 10000;
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
let connectionsLoading = true;
let connectionsFailed = false;
let pageUnloading = false;
const followedSubscriptionJobs = new Set<string>();
const followedLatencyJobs = new Set<string>();
const handledSubscriptionJobs = new Set<string>();
const handledLatencyJobs = new Set<string>();

const customProxyLatencies = new Map<string, number>();

if (typeof window !== 'undefined') {
  window.addEventListener('pagehide', () => {
    pageUnloading = true;
  });
  window.addEventListener('pageshow', () => {
    pageUnloading = false;
  });
}

// Fetchers

async function fetchDashboardSectionsOnce(mountId: number) {
  if (getDashboardServiceAvailability() === 'stopped') {
    return false;
  }

  const prev = store.get().sectionsWidget;
  const hasRenderedData = prev.data.length > 0;

  store.set({
    sectionsWidget: {
      ...prev,
      failed: false,
      loading: prev.loading && !hasRenderedData,
    },
  });

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
  const failed = !response.success || response.data.success === false;
  const message = response.success
    ? response.data.message || _('Failed to update subscriptions')
    : response.error || _('Failed to update subscriptions');

  if (failed && isTransientRpcError(message)) {
    void refreshRuntimeUiState({ force: true });
    return;
  }

  if (jobId) {
    handledSubscriptionJobs.add(jobId);
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

  socket.subscribe(
    `${getClashWsUrl()}/traffic?token=${clashApiSecret}`,
    (msg) => {
      if (
        dataUpdatesId !== dashboardDataUpdatesId ||
        getDashboardServiceAvailability() === 'stopped'
      ) {
        return;
      }

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

      logger.error(
        '[DASHBOARD]',
        'connectToClashSockets - traffic: failed to connect to',
        getClashWsUrl(),
      );
      store.set({
        bandwidthWidget: {
          loading: false,
          failed: true,
          data: { up: 0, down: 0 },
        },
      });
    },
  );

  socket.subscribe(
    `${getClashWsUrl()}/connections?token=${clashApiSecret}`,
    (msg) => {
      if (
        dataUpdatesId !== dashboardDataUpdatesId ||
        getDashboardServiceAvailability() === 'stopped'
      ) {
        return;
      }

      const parsedMsg = JSON.parse(msg);

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
    },
    (_err) => {
      if (
        dataUpdatesId !== dashboardDataUpdatesId ||
        getDashboardServiceAvailability() === 'stopped'
      ) {
        return;
      }

      logger.error(
        '[DASHBOARD]',
        'connectToClashSockets - connections: failed to connect to',
        getClashWsUrl(),
      );
      store.set({
        trafficTotalWidget: {
          loading: false,
          failed: true,
          data: { downloadTotal: 0, uploadTotal: 0 },
        },
        systemInfoWidget: {
          loading: false,
          failed: true,
          data: {
            connections: 0,
            memory: 0,
          },
        },
      });
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
  socket.resetAll();
}

function startDashboardDataUpdates() {
  if (
    dashboardDataUpdatesStarted ||
    !dashboardMounted ||
    getDashboardServiceAvailability() === 'stopped'
  ) {
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
  }, SECTIONS_REFRESH_INTERVAL_MS);
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
    sectionsWidget.selectorSwitchingSections[sectionName] ||
    section.outbounds.some(
      (outbound) => outbound.code === tag && outbound.selected,
    )
  ) {
    return;
  }

  setSelectorSwitching(sectionName, tag);

  try {
    await TachyonShellMethods.setClashApiGroupProxy(selector, tag);
    await fetchDashboardSections({ force: true });
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

  try {
    if (latencyType === 'proxy') {
      // Test proxy latency immediately
      const parsedTag = tag.startsWith('[') ? JSON.parse(tag)[0] : tag;
      const response = await TachyonShellMethods.getClashApiProxyLatency(parsedTag, timeout);
      if (response.success && response.data) {
        customProxyLatencies.set(tag, response.data.delay || -1);
      } else {
        customProxyLatencies.set(tag, -1);
      }
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

function getUrlTestLatencyClass(latency: number) {
  if (!latency) {
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

function formatUrlTestLatency(latency: number) {
  return latency ? `${latency}ms` : 'N/A';
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
  if (!countryFlag) {
    return renderFlagEmojis(member.displayName);
  }

  return [
    E(
      'span',
      { class: 'tachyon_dashboard-page__urltest-details__country-badge' },
      countryFlag,
    ),
    ...renderFlagEmojis(member.displayName),
  ];
}

function renderUrlTestSelectedValue(info: Tachyon.UrlTestInfo) {
  const selectedMember = info.outbounds.find((member) => member.selected);
  const selectedName =
    selectedMember?.displayName || info.selectedName || info.selectedCode || '';
  const name = formatUrlTestModalValue(selectedName);

  if (name === _('No')) {
    return E('span', {}, name);
  }

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
            E(
              'span',
              {
                class: 'tachyon_dashboard-page__urltest-details__selected-type',
              },
              selectedMember.type,
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
) {
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
          ? info.outbounds.map((member: any) =>
              E(
                'div',
                {
                  class: [
                    'tachyon_dashboard-page__urltest-details__row',
                    member.selected
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
                                E(
                                  'span',
                                  {
                                    class:
                                      'tachyon_dashboard-page__urltest-details__row-type',
                                  },
                                  member.type,
                                ),
                              ]
                            : []),
                        ]
                      : [
                          E('b', {}, renderMemberName(member)),
                          ...(member.type
                            ? [
                                E(
                                  'span',
                                  {
                                    class:
                                      'tachyon_dashboard-page__urltest-details__row-type',
                                  },
                                  member.type,
                                ),
                              ]
                            : []),
                        ],
                  ),
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
                  member.canCopyLink
                    ? renderUrlTestCopyButton(_('Copy proxy link'), (event) => {
                        event.preventDefault();
                        void handleCopyOutbound(member);
                      })
                    : E('span', {
                        class:
                          'tachyon_dashboard-page__urltest-details__copy-placeholder',
                      }),
                ],
              ),
            )
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

function renderUrlTestInfoModal(outbound: Tachyon.Outbound) {
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
  );
}

function handleShowUrlTestInfo(outbound: Tachyon.Outbound) {
  if (!outbound.urlTestInfo) {
    return;
  }

  ui.showModal(
    `${_('URLTest details')}: ${
      outbound.urlTestInfo.displayName || outbound.displayName
    }`,
    renderUrlTestInfoModal(outbound),
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
            E(
              'span',
              {
                class: 'tachyon_dashboard-page__urltest-details__selected-type',
              },
              selectedMember.type,
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
    ],
  );
}

function renderPriorityMemberName(member: Tachyon.PriorityMember) {
  const levelName = member.levelName || _('Level');

  return [
    E(
      'span',
      { class: 'tachyon_dashboard-page__urltest-details__priority-number' },
      `#${member.levelIndex + 1}`,
    ),
    E(
      'span',
      { class: 'tachyon_dashboard-page__urltest-details__priority-level' },
      levelName,
    ),
    E(
      'span',
      { class: 'tachyon_dashboard-page__urltest-details__priority-node' },
      renderDetailsMemberName(member),
    ),
  ];
}

function renderPriorityInfoModal(outbound: Tachyon.Outbound) {
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
  );
}

function handleShowPriorityInfo(outbound: Tachyon.Outbound) {
  if (!outbound.priorityInfo) {
    return;
  }

  ui.showModal(
    `${_('Priority details')}: ${
      outbound.priorityInfo.displayName || outbound.displayName
    }`,
    renderPriorityInfoModal(outbound),
  );
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

    const isConnectionNode = ['vpn', 'awg', 'warp'].includes(
      section.action || '',
    );

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

async function renderSectionsWidget() {
  logger.debug('[DASHBOARD]', 'renderSectionsWidget');
  const sectionsWidget = store.get().sectionsWidget;
  const container = document.getElementById('dashboard-sections-grid');

  if (!container) {
    return;
  }

  const sectionsWithCustomLatencies = sectionsWidget.data.map((section) => ({
    ...section,
    outbounds: section.outbounds.map((outbound) => ({
      ...outbound,
      latency: customProxyLatencies.has(outbound.code)
        ? customProxyLatencies.get(outbound.code)!
        : outbound.latency,
    })),
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
    });
  }

  const renderedWidgets = sectionsWithCustomLatencies.map((section) =>
    renderSections({
      loading: sectionsWidget.loading,
      failed: sectionsWidget.failed,
      section,
      isCollapsed: collapsedSections.has(section.code),
      onToggleCollapse: () => toggleSectionCollapsed(section.code),
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
      onShowUrlTestInfo: (outbound) => {
        handleShowUrlTestInfo(outbound);
      },
      onShowPriorityInfo: (outbound) => {
        handleShowPriorityInfo(outbound);
      },
      onUpdateSubscription: (section) => {
        void handleUpdateSubscription(section);
      },
    }),
  );

  return preserveScrollForPage(() => {
    container.replaceChildren(...renderedWidgets);
  });
}

function renderStoreWidget(
  containerId: string,
  storeKey:
    | 'bandwidthWidget'
    | 'trafficTotalWidget'
    | 'systemInfoWidget'
    | 'servicesInfoWidget',
  title: string,
  getItems: (data: any) => Array<{
    key: string;
    value: string;
    attributes?: Record<string, string>;
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
  try {
    const [res, hostnames] = await Promise.all([
      TachyonShellMethods.getClashApiConnections(),
      fetchHostnames()
    ]);
    if (res.success && res.data && typeof res.data === 'object' && Array.isArray((res.data as any).connections)) {
      const connectionsList = (res.data as any).connections;
      const map = new Map<string, IConnection>();
      for (const conn of connectionsList) {
        const ip = conn.metadata?.sourceIP;
        if (!ip) continue;
        const up = Number(conn.upload) || 0;
        const down = Number(conn.download) || 0;
        if (map.has(ip)) {
          const existing = map.get(ip)!;
          existing.count++;
          existing.upload += up;
          existing.download += down;
        } else {
          const name = hostnames.get(ip);
          map.set(ip, { ip, count: 1, upload: up, download: down, name });
        }
      }
      currentConnections = Array.from(map.values()).sort((a, b) => (b.download + b.upload) - (a.download + a.upload));
      connectionsLoading = false;
      connectionsFailed = false;
    } else {
      connectionsFailed = true;
    }
  } catch(e) {
    connectionsFailed = true;
  }
  renderConnectionsWidget();
}

function renderConnectionsWidget() {
  const container = document.getElementById('dashboard-connections-grid');
  if (!container) return;
  if (connectionsFailed && currentConnections.length === 0) {
    container.innerHTML = '';
    return;
  }
  container.replaceChildren(renderConnections(currentConnections));
}

async function renderBandwidthWidget() {
  renderStoreWidget(
    'dashboard-widget-traffic',
    'bandwidthWidget',
    _('Traffic'),
    (data) => [
      { key: _('Uplink'), value: `${prettyBytes(data.up)}/s` },
      { key: _('Downlink'), value: `${prettyBytes(data.down)}/s` },
    ],
    'renderBandwidthWidget',
  );
}

async function renderTrafficTotalWidget() {
  renderStoreWidget(
    'dashboard-widget-traffic-total',
    'trafficTotalWidget',
    _('Traffic Total'),
    (data) => [
      { key: _('Uplink'), value: String(prettyBytes(data.uploadTotal)) },
      { key: _('Downlink'), value: String(prettyBytes(data.downloadTotal)) },
    ],
    'renderTrafficTotalWidget',
  );
}

async function renderSystemInfoWidget() {
  renderStoreWidget(
    'dashboard-widget-system-info',
    'systemInfoWidget',
    _('System info'),
    (data) => [
      { key: _('Active Connections'), value: String(data.connections) },
      { key: _('Memory Usage'), value: String(prettyBytes(data.memory)) },
    ],
    'renderSystemInfoWidget',
  );
}

async function renderServicesInfoWidget() {
  renderStoreWidget(
    'dashboard-widget-service-info',
    'servicesInfoWidget',
    _('Services info'),
    (data) => [
      {
        key: 'Tachyon',
        value: data.tachyonRunning ? _('✔ Running') : _('✘ Stopped'),
        attributes: {
          class: data.tachyonRunning
            ? 'tachyon_dashboard-page__widgets-section__item__row--success'
            : 'tachyon_dashboard-page__widgets-section__item__row--error',
        },
      },
      {
        key: 'Sing-box',
        value: data.singbox ? _('✔ Running') : _('✘ Stopped'),
        attributes: {
          class: data.singbox
            ? 'tachyon_dashboard-page__widgets-section__item__row--success'
            : 'tachyon_dashboard-page__widgets-section__item__row--error',
        },
      },
    ],
    'renderServicesInfoWidget',
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
      renderSectionsWidget();
    }
  }

  if (diff.bandwidthWidget) {
    renderBandwidthWidget();
  }

  if (diff.trafficTotalWidget) {
    renderTrafficTotalWidget();
  }

  if (diff.systemInfoWidget) {
    renderSystemInfoWidget();
  }

  if (diff.servicesInfoWidget) {
    syncDashboardServiceAvailability();
    renderServicesInfoWidget();
  }
}

async function onPageMount() {
  // Cleanup before mount
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
    }
  }

  // Add new listener
  store.subscribe(onStoreUpdate);
  startActionStateWatcher();
  void renderSectionsWidget();
  void renderConnectionsWidget();
  void renderBandwidthWidget();
  void renderTrafficTotalWidget();
  void renderSystemInfoWidget();
  void renderServicesInfoWidget();
  syncDashboardServiceAvailability();


  if (hasRuntimeSnapshot) {
    void refreshRuntimeUiState({ force: true });
  }
}

function onPageUnmount() {
  dashboardMounted = false;
  dashboardMountId += 1;

  stopDashboardDataUpdates();
  stopActionStateWatcher();
  sectionsRefreshQueued = false;
  sectionsRefreshPromise = null;
  // Remove old listener
  store.unsubscribe(onStoreUpdate);
  // Clear store
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
