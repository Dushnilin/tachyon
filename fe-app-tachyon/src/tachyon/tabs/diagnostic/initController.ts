import {
  onMount,
  preserveScrollForPage,
  executeShellCommand,
} from '../../../helpers';
import { showToast } from '../../../helpers/showToast';
import { runDnsCheck } from './checks/runDnsCheck';
import { runSingBoxCheck } from './checks/runSingBoxCheck';
import { runInboundsCheck } from './checks/runInboundsCheck';
import { runNftCheck } from './checks/runNftCheck';
import { runFakeIPCheck } from './checks/runFakeIPCheck';
import { runZapretCheck } from './checks/runZapretCheck';
import { runZapret2Check } from './checks/runZapret2Check';
import { runByedpiCheck } from './checks/runByedpiCheck';
import {
  DIAGNOSTICS_CHECKS,
  DIAGNOSTICS_CHECKS_MAP,
} from './checks/contstants';
import {
  DiagnosticsProviderOptions,
  getDiagnosticsChecks,
  getLoadingDiagnosticsChecks,
} from './diagnostic.store';
import {
  logger,
  getCachedRuntimeUiState,
  refreshRuntimeUiState,
  setLocalServiceAction,
  store,
  StoreType,
  subscribeRuntimeUiState,
} from '../../services';
import { ensureSystemInfo } from '../../services/systemInfo.service';
import {
  renderAvailableActions,
  renderCheckSection,
  renderRunAction,
  renderSystemInfo,
  renderServiceCheckModal,
  renderAiChatModal,
} from './partials';
import { TachyonShellMethods } from '../../methods';
import { fetchServicesInfo } from '../../fetchers/fetchServicesInfo';
import { normalizeCompiledVersion } from '../../../helpers/normalizeCompiledVersion';
import { renderModal, renderButton } from '../../../partials';
import { TACHYON_LUCI_APP_VERSION } from '../../../constants';
import { renderWikiDisclaimer } from './partials/renderWikiDisclaimer';
import { runSectionsCheck } from './checks/runSectionsCheck';
import { Tachyon } from '../../types';
import {
  getAvailableActionsDisabledState,
  getServiceTransition,
  hasComponentActionLoading,
  hasLocalMutatingServiceActionLoading,
  isServiceTransitionStatus,
  shouldResetDiagnosticsChecks,
  shouldDisableDiagnosticRunAction,
  shouldSkipServicesInfoAutoRefresh,
  shouldShowRestartAction,
  shouldShowStartAction,
  shouldShowStopAction,
} from './serviceTransition';
import { isActiveLuciTab } from '../../helpers/isActiveLuciTab';
import {
  formatSingBoxVersion,
  normalizeSingBoxVariantFields,
} from '../../helpers/singBoxVariant';
import {
  clearPersistedDiagnosticRun,
  PersistedDiagnosticRun,
  readPersistedDiagnosticRun,
  savePersistedDiagnosticRun,
} from './diagnosticRunPersistence';
import {
  formatMaskedSingBoxConfig,
  maskGlobalCheckText,
  stringifySingBoxConfig,
} from './helpers/maskDiagnostics';

const SERVICE_STATUS_REFRESH_INTERVAL_MS = 2000;
const SERVICE_ACTION_STATUS_TIMEOUT_MS = 45000;

let latestProviderInfoRequestId = 0;
let diagnosticLifecycleRegistered = false;
let diagnosticControllerInitialized = false;
let diagnosticMounted = false;
let diagnosticMountId = 0;
let diagnosticCompletedWhileHidden = false;
let servicesInfoStateUnsubscribe: (() => void) | null = null;
let servicesInfoRefreshPromise: Promise<void> | null = null;
const followedServiceActionJobs = new Set<string>();
const handledServiceActionJobs = new Set<string>();

type ServiceRuntimeAction = 'restart' | 'start' | 'stop';
type DiagnosticRunner = {
  code: DIAGNOSTICS_CHECKS;
  run: () => Promise<void>;
};

function sleep(ms: number) {
  return new Promise<void>((resolve) => setTimeout(resolve, ms));
}

function getDiagnosticsProviderOptions(
  systemInfo: Pick<
    StoreType['diagnosticsSystemInfo'],
    | 'zapret_installed'
    | 'zapret2_installed'
    | 'byedpi_installed'
    | 'server_inbounds_enabled_count'
  > = store.get().diagnosticsSystemInfo,
): DiagnosticsProviderOptions {
  return {
    includeZapret: Boolean(systemInfo.zapret_installed),
    includeZapret2: Boolean(systemInfo.zapret2_installed),
    includeByedpi: Boolean(systemInfo.byedpi_installed),
    includeInbounds: systemInfo.server_inbounds_enabled_count > 0,
  };
}

function getNotRunningDiagnosticsChecks() {
  return getDiagnosticsChecks(
    _('Not running'),
    getDiagnosticsProviderOptions(),
  );
}

function resetDiagnosticsChecks() {
  store.set({
    diagnosticsChecks: getNotRunningDiagnosticsChecks(),
  });
}

function setDiagnosticActionLoading(
  action: keyof StoreType['diagnosticsActions'],
  loading: boolean,
  local = false,
) {
  if (local || !loading) {
    setLocalServiceAction(action, loading && local);
  }

  const diagnosticsActions = store.get().diagnosticsActions;

  store.set({
    diagnosticsActions: {
      ...diagnosticsActions,
      [action]: { loading },
    },
  });
}

function isDiagnosticMountActive(mountId = diagnosticMountId) {
  return diagnosticMounted && diagnosticMountId === mountId;
}

function isLocalMutatingServiceActionLoading() {
  const actions = store.get().diagnosticsActions;

  return hasLocalMutatingServiceActionLoading(actions);
}

function isMutatingServiceActionLoading() {
  return (
    isLocalMutatingServiceActionLoading() ||
    isServiceTransitionStatus(store.get().servicesInfoWidget.data.tachyonStatus)
  );
}

function getTachyonStatusText(running: boolean, enabled: boolean) {
  if (running) {
    return enabled ? 'running & enabled' : 'running but disabled';
  }

  return enabled ? 'stopped but enabled' : 'stopped & disabled';
}

function setDisplayedTachyonRunning(running: boolean) {
  const servicesInfoWidget = store.get().servicesInfoWidget;
  const enabled = Boolean(servicesInfoWidget.data.tachyonEnabled);

  store.set({
    servicesInfoWidget: {
      ...servicesInfoWidget,
      loading: false,
      data: {
        ...servicesInfoWidget.data,
        tachyonRunning: running ? 1 : 0,
        tachyonStatus: getTachyonStatusText(running, enabled),
      },
    },
  });
}

async function refreshDiagnosticServicesInfo({
  force = false,
  mountId = diagnosticMountId,
  allowInactive = false,
}: {
  force?: boolean;
  mountId?: number;
  allowInactive?: boolean;
} = {}) {
  if (!allowInactive && !isDiagnosticMountActive(mountId)) {
    return;
  }

  if (
    shouldSkipServicesInfoAutoRefresh({
      force,
      localMutatingActionLoading: isLocalMutatingServiceActionLoading(),
    })
  ) {
    return;
  }

  if (servicesInfoRefreshPromise) {
    return servicesInfoRefreshPromise;
  }

  const promise = fetchServicesInfo()
    .then((uiState) => {
      followServiceActionsFromUiState(uiState);
    })
    .catch((error) => {
      logger.error(
        '[DIAGNOSTIC]',
        'refreshDiagnosticServicesInfo failed',
        error,
      );
    })
    .finally(() => {
      if (servicesInfoRefreshPromise === promise) {
        servicesInfoRefreshPromise = null;
      }
    });

  servicesInfoRefreshPromise = promise;
  return promise;
}

async function waitForTachyonRunningState(expectedRunning: boolean) {
  const startedAt = Date.now();

  while (Date.now() - startedAt < SERVICE_ACTION_STATUS_TIMEOUT_MS) {
    await refreshDiagnosticServicesInfo({ force: true, allowInactive: true });

    const tachyonRunning = Boolean(
      store.get().servicesInfoWidget.data.tachyonRunning,
    );

    if (tachyonRunning === expectedRunning) {
      return true;
    }

    await sleep(SERVICE_STATUS_REFRESH_INTERVAL_MS);
  }

  return false;
}

function startServiceActionStateWatcher() {
  if (servicesInfoStateUnsubscribe) {
    return;
  }

  servicesInfoStateUnsubscribe = subscribeRuntimeUiState((uiState) => {
    if (diagnosticMounted) {
      followServiceActionsFromUiState(uiState);
    }
  });
}

function stopServiceActionStateWatcher() {
  if (!servicesInfoStateUnsubscribe) {
    return;
  }

  servicesInfoStateUnsubscribe();
  servicesInfoStateUnsubscribe = null;
}

function isVisibleServiceRuntimeAction(
  action: Tachyon.ServiceActionState['action'],
): action is ServiceRuntimeAction {
  return action === 'restart' || action === 'start' || action === 'stop';
}

function setServiceActionStateLoading(
  state: Tachyon.ServiceActionState,
  loading: boolean,
) {
  if (!isVisibleServiceRuntimeAction(state.action)) {
    return;
  }

  setDiagnosticActionLoading(state.action, loading);
}

async function followServiceActionState(state: Tachyon.ServiceActionState) {
  const jobId = state.job_id;

  if (!jobId || followedServiceActionJobs.has(jobId)) {
    return;
  }

  if (!state.running && handledServiceActionJobs.has(jobId)) {
    return;
  }

  followedServiceActionJobs.add(jobId);
  if (state.running) {
    setServiceActionStateLoading(state, true);
  }

  try {
    if (state.running) {
      await TachyonShellMethods.waitServiceActionJob(jobId);
    }
  } catch (error) {
    logger.error('[DIAGNOSTIC]', 'followServiceActionState failed', error);
  } finally {
    handledServiceActionJobs.add(jobId);
    setServiceActionStateLoading(state, false);
    await refreshDiagnosticServicesInfo({ force: true, allowInactive: true });
    void TachyonShellMethods.uiActionAck('service', jobId);
    followedServiceActionJobs.delete(jobId);
    resetDiagnosticsChecks();
  }
}

function followServiceActionsFromUiState(uiState?: Tachyon.UiState) {
  if (!uiState) {
    return;
  }

  for (const action of uiState.actions.service || []) {
    if (action.job_id) {
      void followServiceActionState(action);
    }
  }
}

async function fetchSystemInfo() {
  const systemInfo = await ensureSystemInfo();

  if (store.get().diagnosticsRunAction.loading) {
    return;
  }

  store.set({
    diagnosticsChecks: getDiagnosticsChecks(
      _('Not running'),
      getDiagnosticsProviderOptions(systemInfo),
    ),
  });
}

async function fetchDiagnosticsProviderInfo({
  resetChecks = true,
}: { resetChecks?: boolean } = {}) {
  const requestId = ++latestProviderInfoRequestId;

  try {
    const uiState = await refreshRuntimeUiState({ force: true });

    if (requestId !== latestProviderInfoRequestId) {
      return;
    }

    if (uiState) {
      const currentSystemInfo = store.get().diagnosticsSystemInfo;
      const nextSystemInfo = normalizeSingBoxVariantFields({
        ...currentSystemInfo,
        providerInfoLoaded: true,
        sing_box_extended: uiState.capabilities.sing_box_extended,
        sing_box_tiny: uiState.capabilities.sing_box_tiny,
        sing_box_compressed: uiState.capabilities.sing_box_compressed,
        sing_box_lx: uiState.capabilities.sing_box_lx,
        sing_box_tailscale: uiState.capabilities.sing_box_tailscale,
        zapret_installed: uiState.capabilities.zapret_installed,
        zapret2_installed: uiState.capabilities.zapret2_installed,
        byedpi_installed: uiState.capabilities.byedpi_installed,
        server_inbounds_enabled_count:
          uiState.capabilities.server_inbounds_enabled_count,
      });

      if (!nextSystemInfo.zapret_installed) {
        nextSystemInfo.zapret_version = 'not installed';
      }

      if (!nextSystemInfo.zapret2_installed) {
        nextSystemInfo.zapret2_version = 'not installed';
      }

      if (!nextSystemInfo.byedpi_installed) {
        nextSystemInfo.byedpi_version = 'not installed';
      }

      const nextState: Partial<StoreType> = {
        diagnosticsSystemInfo: nextSystemInfo,
      };

      if (
        shouldResetDiagnosticsChecks({
          resetChecks,
          diagnosticsRunLoading: store.get().diagnosticsRunAction.loading,
        })
      ) {
        nextState.diagnosticsChecks = getDiagnosticsChecks(
          _('Not running'),
          getDiagnosticsProviderOptions(nextSystemInfo),
        );
      }

      store.set(nextState);
      return;
    }

    const [zapretRuntime, zapret2Runtime, byedpiRuntime, inboundsConfig] =
      await Promise.all([
        TachyonShellMethods.checkZapretRuntime(),
        TachyonShellMethods.checkZapret2Runtime(),
        TachyonShellMethods.checkByedpiRuntime(),
        TachyonShellMethods.checkInboundsConfig(),
      ]);

    if (requestId !== latestProviderInfoRequestId) {
      return;
    }

    const currentSystemInfo = store.get().diagnosticsSystemInfo;
    const nextSystemInfo = {
      ...currentSystemInfo,
      providerInfoLoaded: true,
      zapret_installed: zapretRuntime.success
        ? zapretRuntime.data.zapret_installed
        : currentSystemInfo.zapret_installed,
      zapret2_installed: zapret2Runtime.success
        ? zapret2Runtime.data.zapret2_installed
        : currentSystemInfo.zapret2_installed,
      byedpi_installed: byedpiRuntime.success
        ? byedpiRuntime.data.byedpi_installed
        : currentSystemInfo.byedpi_installed,
      server_inbounds_enabled_count: inboundsConfig.success
        ? inboundsConfig.data.enabled_count
        : -1,
    };

    if (!zapretRuntime.success) {
      logger.error('[DIAGNOSTIC]', 'fetchZapretRuntime failed', zapretRuntime);
    }

    if (!zapret2Runtime.success) {
      logger.error(
        '[DIAGNOSTIC]',
        'fetchZapret2Runtime failed',
        zapret2Runtime,
      );
    }

    if (!byedpiRuntime.success) {
      logger.error('[DIAGNOSTIC]', 'fetchByedpiRuntime failed', byedpiRuntime);
    }

    if (!inboundsConfig.success) {
      logger.error(
        '[DIAGNOSTIC]',
        'fetchInboundsConfig failed',
        inboundsConfig,
      );
    }

    if (!nextSystemInfo.zapret_installed) {
      nextSystemInfo.zapret_version = 'not installed';
    }

    if (!nextSystemInfo.zapret2_installed) {
      nextSystemInfo.zapret2_version = 'not installed';
    }

    if (!nextSystemInfo.byedpi_installed) {
      nextSystemInfo.byedpi_version = 'not installed';
    }

    const nextState: Partial<StoreType> = {
      diagnosticsSystemInfo: nextSystemInfo,
    };

    if (
      shouldResetDiagnosticsChecks({
        resetChecks,
        diagnosticsRunLoading: store.get().diagnosticsRunAction.loading,
      })
    ) {
      nextState.diagnosticsChecks = getDiagnosticsChecks(
        _('Not running'),
        getDiagnosticsProviderOptions(nextSystemInfo),
      );
    }

    store.set(nextState);
  } catch (error) {
    logger.error('[DIAGNOSTIC]', 'fetchDiagnosticsProviderInfo failed', error);

    if (requestId === latestProviderInfoRequestId) {
      const currentSystemInfo = store.get().diagnosticsSystemInfo;

      store.set({
        diagnosticsSystemInfo: {
          ...currentSystemInfo,
          providerInfoLoaded: true,
          server_inbounds_enabled_count: -1,
        },
      });
    }
  }
}

function renderDiagnosticsChecks() {
  logger.debug('[DIAGNOSTIC]', 'renderDiagnosticsChecks');
  const diagnosticsChecks = [...store.get().diagnosticsChecks].sort(
    (a, b) => a.order - b.order,
  );
  const container = document.getElementById('tachyon_diagnostic-page-checks');

  const renderedDiagnosticsChecks = diagnosticsChecks.map((check) =>
    renderCheckSection(check),
  );

  return preserveScrollForPage(() => {
    container!.replaceChildren(...renderedDiagnosticsChecks);
  });
}

function renderDiagnosticRunActionWidget() {
  logger.debug('[DIAGNOSTIC]', 'renderDiagnosticRunActionWidget');

  const { loading } = store.get().diagnosticsRunAction;
  const providerInfoLoaded =
    store.get().diagnosticsSystemInfo.providerInfoLoaded;
  const servicesInfoWidget = store.get().servicesInfoWidget;
  const tachyonRunning = Boolean(servicesInfoWidget.data.tachyonRunning);
  const container = document.getElementById(
    'tachyon_diagnostic-page-run-check',
  );

  const renderedAction = renderRunAction({
    loading,
    disabled: shouldDisableDiagnosticRunAction({
      providerInfoLoaded,
      servicesInfoLoading: servicesInfoWidget.loading,
      tachyonRunning,
      mutatingServiceActionLoading: isMutatingServiceActionLoading(),
    }),
    click: () => runChecks(),
  });

  return preserveScrollForPage(() => {
    container!.replaceChildren(renderedAction);
  });
}

async function handleServiceRuntimeAction({
  action,
  expectedRunning,
  optimisticRunning,
}: {
  action: ServiceRuntimeAction;
  expectedRunning: boolean;
  optimisticRunning?: boolean;
}) {
  setDiagnosticActionLoading(action, true, true);
  let jobId = '';
  let ownsJobFollow = false;
  let delegatedToWatcher = false;

  if (optimisticRunning !== undefined) {
    setDisplayedTachyonRunning(optimisticRunning);
  }

  try {
    const startResponse = await TachyonShellMethods.serviceActionStart(action);

    if (!startResponse.success) {
      throw new Error(startResponse.error);
    }

    jobId = startResponse.data.job_id;
    if (followedServiceActionJobs.has(jobId)) {
      delegatedToWatcher = true;
      return;
    }

    followedServiceActionJobs.add(jobId);
    ownsJobFollow = true;
    const result = await TachyonShellMethods.waitServiceActionJob(jobId);

    if (!result.success) {
      throw new Error(result.error);
    }

    if (!result.data.success) {
      throw new Error(result.data.message || _('Service action failed'));
    }

    await waitForTachyonRunningState(expectedRunning);
  } catch (e) {
    logger.error('[DIAGNOSTIC]', `handleServiceRuntimeAction(${action})`, e);
  } finally {
    if (!delegatedToWatcher) {
      if (ownsJobFollow) {
        followedServiceActionJobs.delete(jobId);
      }

      setDiagnosticActionLoading(action, false);
      await refreshDiagnosticServicesInfo({ force: true, allowInactive: true });
      if (jobId) {
        handledServiceActionJobs.add(jobId);
        void TachyonShellMethods.uiActionAck('service', jobId);
      }
      resetDiagnosticsChecks();
    }
  }
}

function handleCheckServicesAction() {
  renderServiceCheckModal();
}

async function handleRestart() {
  await handleServiceRuntimeAction({
    action: 'restart',
    expectedRunning: true,
    optimisticRunning: false,
  });
}

async function handleStart() {
  await handleServiceRuntimeAction({
    action: 'start',
    expectedRunning: true,
  });
}

async function handleStop() {
  await handleServiceRuntimeAction({
    action: 'stop',
    expectedRunning: false,
  });
}

async function handleEnable() {
  setDiagnosticActionLoading('enable', true);

  try {
    await TachyonShellMethods.enable();
  } catch (e) {
    logger.error('[DIAGNOSTIC]', 'handleEnable - e', e);
  } finally {
    await refreshDiagnosticServicesInfo({
      force: true,
      allowInactive: true,
    });
    setDiagnosticActionLoading('enable', false);
  }
}

async function handleDisable() {
  setDiagnosticActionLoading('disable', true);

  try {
    await TachyonShellMethods.disable();
  } catch (e) {
    logger.error('[DIAGNOSTIC]', 'handleDisable - e', e);
  } finally {
    await refreshDiagnosticServicesInfo({
      force: true,
      allowInactive: true,
    });
    setDiagnosticActionLoading('disable', false);
  }
}

async function handleShowGlobalCheck() {
  setDiagnosticActionLoading('globalCheck', true);

  try {
    const globalCheck = await TachyonShellMethods.globalCheck(false);

    if (globalCheck.success) {
      const rawGlobalCheckText = (globalCheck.data as string) ?? '';
      const maskedGlobalCheckText = maskGlobalCheckText(rawGlobalCheckText);

      ui.showModal(
        _('Global check'),
        renderModal(rawGlobalCheckText, 'global_check', {
          maskText: () => maskedGlobalCheckText,
          initialAutoRefresh: false,
          showMaskValuesToggle: true,
        }),
      );
    } else {
      logger.error('[DIAGNOSTIC]', 'handleShowGlobalCheck - e', globalCheck);
    }
  } catch (e) {
    logger.error('[DIAGNOSTIC]', 'handleShowGlobalCheck - e', e);
  } finally {
    setDiagnosticActionLoading('globalCheck', false);
  }
}

async function handleRunDoctor() {
  setDiagnosticActionLoading('doctor', true);

  try {
    const doctorRes = await TachyonShellMethods.doctor();

    if (!doctorRes || typeof doctorRes !== 'object') {
      showToast(_('Doctor failed') + ': ' + _('Unknown error'), 'error');
      return;
    }

    if (doctorRes.success) {
      const rawData = (doctorRes as { data?: unknown }).data;
      const data =
        typeof rawData === 'object' && rawData !== null
          ? (rawData as Record<string, unknown>)
          : null;
      const report = data ? String(data.report ?? '') : String(rawData ?? '');
      const issues = data ? Number(data.issues ?? 0) : 0;
      const fixed = data ? Number(data.fixed ?? 0) : 0;

      const title =
        issues > 0
          ? _('Doctor repair') +
            ' \u2014 ' +
            _('Issues') +
            ': ' +
            issues +
            ', ' +
            _('Fixed') +
            ': ' +
            fixed
          : /safe bypass|аварийного обхода|bypassed|стоковом состоянии|stock (state|internet)/i.test(
                report,
              )
            ? _('Doctor repair') + ' \u2014 Safe Bypass'
            : _('Doctor repair') + ' \u2014 ' + _('No issues found');

      ui.showModal(
        title,
        renderModal(report, 'doctor_repair', {
          initialAutoRefresh: false,
        }),
      );
    } else {
      const errorMsg =
        typeof doctorRes.error === 'string'
          ? doctorRes.error
          : _('Unknown error');
      showToast(_('Doctor failed') + ': ' + errorMsg, 'error');
    }
  } catch (e) {
    logger.error(
      '[DIAGNOSTIC]',
      'handleRunDoctor - e',
      e instanceof Error ? e.message : String(e),
    );
    showToast(_('Doctor failed'), 'error');
  } finally {
    setDiagnosticActionLoading('doctor', false);
    runChecks();
  }
}

interface AiDoctorHistoryEntry {
  timestamp: string;
  report: string;
  quickFixes: string[];
}

function getAiDoctorHistory(): AiDoctorHistoryEntry[] {
  try {
    const raw = localStorage.getItem('tachyon_ai_doctor_history');
    return raw ? (JSON.parse(raw) as AiDoctorHistoryEntry[]) : [];
  } catch (_e) {
    return [];
  }
}

function saveAiDoctorHistory(entry: AiDoctorHistoryEntry) {
  try {
    const current = getAiDoctorHistory();
    const updated = [entry, ...current].slice(0, 5);
    localStorage.setItem('tachyon_ai_doctor_history', JSON.stringify(updated));
  } catch (_e) {
    // Ignore storage errors
  }
}

async function handleViewLogs() {
  setDiagnosticActionLoading('viewLogs', true);

  try {
    const viewLogs = await TachyonShellMethods.checkLogs();

    if (viewLogs.success) {
      const getLatestLogs = async () => {
        const latestLogs = await TachyonShellMethods.checkLogs();

        if (!latestLogs.success) {
          throw latestLogs;
        }

        return (latestLogs.data as string) ?? '';
      };

      ui.showModal(
        _('View logs'),
        renderModal(viewLogs.data as string, 'view_logs', {
          getText: getLatestLogs,
          refreshMs: 250,
          initialAutoRefresh: true,
          showAutoRefreshToggle: true,
          startAtEnd: true,
        }),
      );
    } else {
      logger.error('[DIAGNOSTIC]', 'handleViewLogs - e', viewLogs);
    }
  } catch (e) {
    logger.error('[DIAGNOSTIC]', 'handleViewLogs - e', e);
  } finally {
    setDiagnosticActionLoading('viewLogs', false);
  }
}

async function handleRunAiDoctor() {
  setDiagnosticActionLoading('aiDoctor', true);

  try {
    const aiRes = await TachyonShellMethods.aiDoctor();

    if (!aiRes || typeof aiRes !== 'object') {
      showToast(_('AI Doctor failed') + ': ' + _('Unknown error'), 'error');
      return;
    }

    const rawData = (aiRes as { data?: unknown }).data;
    const data =
      typeof rawData === 'object' && rawData !== null
        ? (rawData as Record<string, unknown>)
        : null;

    if (
      (aiRes as { success?: boolean }).success ||
      (data && data.success !== false)
    ) {
      const report = data
        ? String(data.report ?? data.summary ?? rawData ?? '')
        : String(rawData ?? '');
      const quickFixes: string[] = Array.isArray(data?.quick_fixes)
        ? (data!.quick_fixes as string[])
        : String(data?.quick_fix ?? '')
            .split(',')
            .map((s) => s.trim())
            .filter(Boolean);

      const nowStr = new Date().toLocaleTimeString();
      saveAiDoctorHistory({ timestamp: nowStr, report, quickFixes });
      let historyEntries = getAiDoctorHistory();
      let activeTab: 'diagnosis' | 'devices' | 'history' = 'diagnosis';
      let lanClients: Tachyon.LanClient[] = [];
      let loadingClients = false;

      const loadLanClients = async () => {
        if (loadingClients) return;
        loadingClients = true;
        renderModalLayout();
        try {
          const res = await TachyonShellMethods.getLanClients();
          if (
            res &&
            res.success &&
            res.data &&
            Array.isArray(res.data.clients)
          ) {
            lanClients = res.data.clients;
          }
        } catch (e) {
          logger.error(
            '[DIAGNOSTIC]',
            'getLanClients error',
            e instanceof Error ? e.message : String(e),
          );
        } finally {
          loadingClients = false;
          renderModalLayout();
        }
      };

      const copySupportReport = async () => {
        let currentClients = lanClients;
        if (currentClients.length === 0) {
          try {
            const res = await TachyonShellMethods.getLanClients();
            if (res && res.success && res.data?.clients) {
              lanClients = res.data.clients;
              currentClients = lanClients;
            }
          } catch (_e) {
            // ignore network clients error when copying report
          }
        }

        const nodeSummary = nodes
          .map((n) => `${n.name}: ${n.status}`)
          .join(' | ');
        const fixesSummary =
          quickFixes.length > 0
            ? quickFixes.map((f) => FIX_LABELS[f] || f).join(', ')
            : _('None');
        const clientsSummary =
          currentClients.length > 0
            ? currentClients
                .map(
                  (c) =>
                    `- ${c.hostname} (IP: ${c.ip}, MAC: ${c.mac.slice(0, 8)}**): ${c.mode.toUpperCase()}`,
                )
                .join('\n')
            : _('No DHCP clients detected');

        const text = [
          '# Tachyon AI Doctor Diagnostic Report',
          `Generated: ${new Date().toISOString()}`,
          `Pillars: ${nodeSummary}`,
          `Recommended Fixes: ${fixesSummary}`,
          '',
          '## Diagnosis:',
          report,
          '',
          '## LAN Devices Routing:',
          clientsSummary,
        ].join('\n');

        try {
          if (navigator.clipboard && navigator.clipboard.writeText) {
            await navigator.clipboard.writeText(text);
          } else {
            const ta = document.createElement('textarea');
            ta.value = text;
            document.body.appendChild(ta);
            ta.select();
            document.execCommand('copy');
            document.body.removeChild(ta);
          }
          showToast(
            _('Anonymized support report copied to clipboard'),
            'success',
          );
        } catch {
          showToast(_('Failed to copy report to clipboard'), 'error');
        }
      };

      const getDeviceIcon = (hostname: string): string => {
        const h = hostname.toLowerCase();
        if (
          h.includes('tv') ||
          h.includes('samsung') ||
          h.includes('lg') ||
          h.includes('bravia') ||
          h.includes('roku') ||
          h.includes('appletv')
        )
          return '📺';
        if (
          h.includes('phone') ||
          h.includes('iphone') ||
          h.includes('android') ||
          h.includes('pixel') ||
          h.includes('xiaomi') ||
          h.includes('galaxy')
        )
          return '📱';
        if (
          h.includes('mac') ||
          h.includes('pc') ||
          h.includes('laptop') ||
          h.includes('desktop') ||
          h.includes('thinkpad')
        )
          return '💻';
        if (
          h.includes('playstation') ||
          h.includes('ps4') ||
          h.includes('ps5') ||
          h.includes('xbox') ||
          h.includes('switch') ||
          h.includes('nintendo')
        )
          return '🎮';
        return '📟';
      };

      // Root Cause Analysis from Backend / Report
      const repLower = report.toLowerCase();
      const backendNodes =
        Array.isArray(data?.nodes) && (data!.nodes as unknown[]).length === 4
          ? (data!.nodes as Array<{
              name: string;
              status: 'OK' | 'WARN' | 'FAIL';
            }>)
          : null;

      const nodes = backendNodes ?? [
        {
          name: 'WAN',
          status:
            repLower.includes('wan interface down') ||
            repLower.includes(
              'шлюз по умолчанию или внешний интернет недоступен',
            ) ||
            repLower.includes('wan interface is unreachable')
              ? 'FAIL'
              : 'OK',
        },
        {
          name: 'DNS',
          status:
            repLower.includes('сбой разрешения dns') ||
            repLower.includes('dns resolution failed') ||
            repLower.includes('dns failed') ||
            repLower.includes('dnsmasq failed')
              ? 'FAIL'
              : 'OK',
        },
        {
          name: 'sing-box',
          status:
            (repLower.includes('sing-box') || repLower.includes('proxy')) &&
            (repLower.includes('остановлен') ||
              repLower.includes('stopped') ||
              repLower.includes('не функционирует') ||
              repLower.includes('error') ||
              repLower.includes('crash'))
              ? 'FAIL'
              : 'OK',
        },
        {
          name: 'nftables',
          status:
            (repLower.includes('nftables') ||
              repLower.includes('правила файрвола') ||
              repLower.includes('firewall rules')) &&
            (repLower.includes('нарушены') ||
              repLower.includes('damaged') ||
              repLower.includes('corrupted') ||
              repLower.includes('compromised'))
              ? 'WARN'
              : 'OK',
        },
      ];

      const FIX_LABELS: Record<string, string> = {
        start_singbox: _('Start sing-box'),
        rebuild_rules: _('Rebuild firewall rules'),
        fix_dnsmasq: _('Restart dnsmasq'),
        fix_resolv_symlink: _('Fix resolv.conf'),
        start_watchdog: _('Start watchdog'),
        restart_singbox_dns: _('Restart sing-box DNS'),
        fix_uci_config: _('Restore config backup'),
        fix_wan_interface: _('Reconnect WAN'),
        fix_gateway: _('Resolve gateway'),
        clear_dns_cache: _('Clear DNS cache'),
        update_subscriptions: _('Update subscriptions'),
        reset_firewall: _('Restart firewall'),
        restart_network: _('Restart network'),
        restart_zapret: _('Restart Zapret/ByeDPI'),
        optimize_memory: _('Optimize RAM memory'),
        switch_to_doh: _('Switch DNS to DoH'),
        heal_network_stack: _('Auto-Heal Network Stack'),
        enable_safe_bypass: _('Enable Direct WAN Bypass'),
        restore_native_internet: _('Restore Native Internet (Stop Tachyon)'),
        fix_system_time: _('Sync System Time (NTP)'),
        flush_conntrack: _('Flush Conntrack Table'),
        fix_bootstrap_dns: _('Reset Bootstrap DNS'),
        optimize_mtu: _('Optimize AWG MTU'),
      };

      const renderRootCauseBanner = () => {
        return E(
          'div',
          {
            class: 'cbi-section-node',
            style:
              'display: flex; align-items: center; justify-content: space-around; gap: 8px; flex-wrap: wrap; padding: 8px 12px; margin-bottom: 12px; border-radius: 6px; background: var(--background-color-high, rgba(0,0,0,0.03)); border: 1px solid var(--border-color, rgba(0,0,0,0.1));',
          },
          nodes.map((node) => {
            const labelClass =
              node.status === 'OK'
                ? 'label-success'
                : node.status === 'WARN'
                  ? 'label-warning'
                  : 'label-danger';
            const icon =
              node.status === 'OK' ? '✓' : node.status === 'WARN' ? '⚠' : '✕';
            return E(
              'span',
              {
                class: `label ${labelClass}`,
                style:
                  'font-size: 11px; padding: 4px 10px; border-radius: 4px; display: inline-flex; align-items: center; gap: 4px; font-weight: bold;',
              },
              [
                E('span', {}, node.name),
                E('span', {}, `${icon} ${node.status}`),
              ],
            );
          }),
        );
      };

      const renderDiagnosisTabContent = () => {
        return E('div', { class: 'cbi-section-node' }, [
          renderRootCauseBanner(),
          E(
            'pre',
            {
              class: 'tachyon-partial-modal__content alert-message notice',
              style:
                'white-space: pre-wrap; font-family: inherit; font-size: 12px; line-height: 1.5; max-height: 320px; overflow-y: auto; margin: 0; padding: 12px; border-radius: 6px; border: 1px solid var(--border-color, rgba(0,0,0,0.1));',
            },
            report,
          ),
          quickFixes.length > 0
            ? E(
                'div',
                {
                  class: 'alert-message warning',
                  style:
                    'margin-top: 12px; padding: 10px 12px; border-radius: 6px;',
                },
                [
                  E(
                    'div',
                    {
                      style:
                        'font-weight: bold; margin-bottom: 8px; font-size: 12px;',
                    },
                    '🛠️ ' + _('Recommended Quick Fixes:'),
                  ),
                  E(
                    'div',
                    {
                      style: 'display: flex; gap: 6px; flex-wrap: wrap;',
                    },
                    quickFixes.map((code) => {
                      let applied = false;
                      const friendlyLabel = FIX_LABELS[code] || code;
                      const btn = renderButton({
                        classNames: ['cbi-button-apply'],
                        text: `⚡ ${friendlyLabel}`,
                        onClick: async () => {
                          if (applied) return;
                          btn.textContent =
                            '⏳ ' + _('Applying...') + ' ' + friendlyLabel;
                          showToast(
                            _('Applying fix') + ': ' + friendlyLabel + '...',
                            'success',
                          );
                          const fixRes =
                            await TachyonShellMethods.applyQuickFix(code);
                          if (
                            fixRes &&
                            typeof fixRes === 'object' &&
                            (fixRes as { success?: boolean }).success
                          ) {
                            applied = true;
                            btn.textContent = `✓ ${friendlyLabel} (${_('Fixed')})`;
                            btn.classList.remove('cbi-button-apply');
                            btn.classList.add('cbi-button-neutral');
                            showToast(
                              _('Fix applied') + ': ' + friendlyLabel,
                              'success',
                            );
                          } else {
                            btn.textContent = `⚡ ${friendlyLabel}`;
                            showToast(
                              _('Failed to apply fix') + ': ' + friendlyLabel,
                              'error',
                            );
                          }
                        },
                      });
                      return btn;
                    }),
                  ),
                ],
              )
            : nodes.some((n) => n.status === 'FAIL' || n.status === 'WARN')
              ? E(
                  'div',
                  {
                    class: 'alert-message warning',
                    style:
                      'margin-top: 12px; padding: 8px 12px; font-size: 12px; border-radius: 6px;',
                  },
                  '⚠️ ' + _('Issues detected. Review the diagnosis above.'),
                )
              : E(
                  'div',
                  {
                    class: 'alert-message success',
                    style:
                      'margin-top: 12px; padding: 8px 12px; font-size: 12px; border-radius: 6px;',
                  },
                  '✓ ' + _('No issues detected. System is running normally.'),
                ),
        ]);
      };

      const renderDevicesTabContent = () => {
        if (loadingClients) {
          return E(
            'div',
            {
              class: 'cbi-section-node',
              style: 'padding: 20px; text-align: center; font-size: 13px;',
            },
            '⏳ ' + _('Loading connected LAN devices...'),
          );
        }

        if (lanClients.length === 0) {
          return E('div', { class: 'cbi-section-node' }, [
            E(
              'div',
              {
                class: 'alert-message info',
                style: 'margin: 0 0 10px 0; padding: 12px;',
              },
              _('No active DHCP clients found on local network.'),
            ),
            renderButton({
              classNames: ['cbi-button-action'],
              text: '🔄 ' + _('Refresh Device List'),
              onClick: loadLanClients,
            }),
          ]);
        }

        return E('div', { class: 'cbi-section-node' }, [
          E(
            'div',
            {
              style:
                'display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px;',
            },
            [
              E(
                'span',
                { style: 'font-weight: bold; font-size: 12px;' },
                `📱 ${_('Connected Devices')}: ${lanClients.length}`,
              ),
              renderButton({
                classNames: ['cbi-button-neutral'],
                text: '🔄 ' + _('Refresh'),
                onClick: loadLanClients,
              }),
            ],
          ),
          E(
            'div',
            {
              style:
                'display: flex; flex-direction: column; gap: 8px; max-height: 340px; overflow-y: auto;',
            },
            lanClients.map((client) => {
              const icon = getDeviceIcon(client.hostname);
              const isDirect = client.mode === 'direct';
              return E(
                'div',
                {
                  class: 'cbi-section-node',
                  style:
                    'display: flex; justify-content: space-between; align-items: center; gap: 10px; padding: 8px 12px; border-radius: 6px; border: 1px solid var(--border-color, rgba(0,0,0,0.1)); background: var(--background-color-high, rgba(0,0,0,0.02)); flex-wrap: wrap;',
                },
                [
                  E(
                    'div',
                    {
                      style: 'display: flex; align-items: center; gap: 8px;',
                    },
                    [
                      E('span', { style: 'font-size: 18px;' }, icon),
                      E('div', {}, [
                        E(
                          'div',
                          { style: 'font-weight: bold; font-size: 12px;' },
                          client.hostname,
                        ),
                        E(
                          'div',
                          { style: 'font-size: 11px; opacity: 0.75;' },
                          `${client.ip} (${client.mac})`,
                        ),
                      ]),
                    ],
                  ),
                  E(
                    'div',
                    {
                      style: 'display: flex; align-items: center; gap: 8px;',
                    },
                    [
                      E(
                        'span',
                        {
                          class: `label ${isDirect ? 'label-warning' : 'label-success'}`,
                          style:
                            'font-size: 11px; padding: 3px 8px; border-radius: 4px;',
                        },
                        isDirect
                          ? '🌐 ' + _('Direct WAN')
                          : '🛡️ ' + _('Proxy / DPI'),
                      ),
                      renderButton({
                        classNames: [
                          isDirect ? 'cbi-button-action' : 'cbi-button-apply',
                        ],
                        text: isDirect
                          ? '🛡️ ' + _('Route via Proxy')
                          : '⚡ ' + _('Direct Bypass'),
                        onClick: async () => {
                          showToast(
                            _('Updating device routing mode...'),
                            'success',
                          );
                          const res =
                            await TachyonShellMethods.toggleClientBypass(
                              client.ip,
                            );
                          if (res && res.success && res.data) {
                            client.mode = res.data.mode;
                            showToast(
                              _('Device updated') + ': ' + client.hostname,
                              'success',
                            );
                            renderModalLayout();
                          } else {
                            showToast(_('Failed to update device'), 'error');
                          }
                        },
                      }),
                    ],
                  ),
                ],
              );
            }),
          ),
        ]);
      };

      const renderHistoryTabContent = () => {
        if (historyEntries.length === 0) {
          return E(
            'div',
            { class: 'alert-message info', style: 'margin: 0; padding: 12px;' },
            _('No diagnostic history available yet.'),
          );
        }

        return E(
          'div',
          {
            style:
              'display: flex; flex-direction: column; gap: 8px; max-height: 360px; overflow-y: auto;',
          },
          historyEntries.map((h, i) =>
            E(
              'div',
              {
                class: 'cbi-section-node',
                style:
                  'padding: 10px; border-radius: 6px; border: 1px solid var(--border-color, rgba(0,0,0,0.1)); background: var(--background-color-high, rgba(0,0,0,0.02));',
              },
              [
                E(
                  'div',
                  {
                    style:
                      'display: flex; justify-content: space-between; font-weight: bold; font-size: 11px; margin-bottom: 6px; opacity: 0.8;',
                  },
                  [
                    E('span', {}, `#${historyEntries.length - i}`),
                    E('span', {}, h.timestamp),
                  ],
                ),
                E(
                  'pre',
                  {
                    class: 'tachyon-partial-modal__content',
                    style:
                      'margin: 0; white-space: pre-wrap; font-size: 11px; max-height: 120px; overflow-y: auto; padding: 8px; border-radius: 4px; background: rgba(0,0,0,0.05);',
                  },
                  h.report,
                ),
              ],
            ),
          ),
        );
      };

      const mainContainer = E(
        'div',
        {
          class: 'tachyon-partial-modal__body',
          style: 'width: 100%; max-width: 680px; box-sizing: border-box;',
        },
        [],
      );

      const renderModalLayout = () => {
        mainContainer.replaceChildren(
          E('div', {}, [
            E(
              'div',
              {
                style:
                  'display: flex; gap: 8px; margin-bottom: 12px; border-bottom: 1px solid var(--border-color, rgba(0,0,0,0.1)); padding-bottom: 8px; flex-wrap: wrap;',
              },
              [
                renderButton({
                  classNames: [
                    activeTab === 'diagnosis'
                      ? 'cbi-button-action'
                      : 'cbi-button-neutral',
                  ],
                  text: '🔍 ' + _('Current Diagnosis'),
                  onClick: () => {
                    activeTab = 'diagnosis';
                    renderModalLayout();
                  },
                }),
                renderButton({
                  classNames: [
                    activeTab === 'devices'
                      ? 'cbi-button-action'
                      : 'cbi-button-neutral',
                  ],
                  text: `📱 ${_('LAN Devices')} ${lanClients.length > 0 ? `(${lanClients.length})` : ''}`,
                  onClick: () => {
                    activeTab = 'devices';
                    if (lanClients.length === 0) {
                      loadLanClients();
                    } else {
                      renderModalLayout();
                    }
                  },
                }),
                renderButton({
                  classNames: [
                    activeTab === 'history'
                      ? 'cbi-button-action'
                      : 'cbi-button-neutral',
                  ],
                  text: `🕒 ${_('History')} (${historyEntries.length})`,
                  onClick: () => {
                    historyEntries = getAiDoctorHistory();
                    activeTab = 'history';
                    renderModalLayout();
                  },
                }),
              ],
            ),
            activeTab === 'diagnosis'
              ? renderDiagnosisTabContent()
              : activeTab === 'devices'
                ? renderDevicesTabContent()
                : renderHistoryTabContent(),
            E(
              'div',
              {
                class: 'tachyon-partial-modal__footer',
                style:
                  'margin-top: 15px; display: flex; justify-content: space-between; align-items: center; gap: 8px; flex-wrap: wrap;',
              },
              [
                E(
                  'div',
                  {
                    style:
                      'display: flex; gap: 8px; flex-wrap: wrap; align-items: center;',
                  },
                  [
                    renderButton({
                      classNames: ['cbi-button-action'],
                      text: '📋 ' + _('Copy Support Report'),
                      onClick: copySupportReport,
                    }),
                    renderButton({
                      classNames: ['cbi-button-reset'],
                      text: '🚨 ' + _('Restore Native Internet (Stop Tachyon)'),
                      onClick: async () => {
                        showToast(
                          _(
                            'Restoring native direct internet (stopping Tachyon)...',
                          ),
                          'success',
                        );
                        const fixRes = await TachyonShellMethods.applyQuickFix(
                          'restore_native_internet',
                        );
                        if (
                          fixRes &&
                          typeof fixRes === 'object' &&
                          (fixRes as { success?: boolean }).success
                        ) {
                          showToast(
                            _('Native internet restored. Tachyon stopped.'),
                            'success',
                          );
                          ui.hideModal();
                          await refreshDiagnosticServicesInfo({
                            force: true,
                            allowInactive: true,
                          });
                        } else {
                          showToast(
                            _('Failed to restore native internet'),
                            'error',
                          );
                        }
                      },
                    }),
                  ],
                ),
                renderButton({
                  classNames: ['cbi-button-neutral'],
                  text: _('Close'),
                  onClick: () => ui.hideModal(),
                }),
              ],
            ),
          ]),
        );
      };

      renderModalLayout();
      ui.showModal(_('AI Doctor Diagnosis'), mainContainer);
    } else {
      const errorMsg =
        typeof (aiRes as { error?: string }).error === 'string'
          ? (aiRes as { error?: string }).error
          : _('Unknown error');
      showToast(_('AI Doctor failed') + ': ' + errorMsg, 'error');
    }
  } catch (e) {
    logger.error(
      '[DIAGNOSTIC]',
      'handleRunAiDoctor - e',
      e instanceof Error ? e.message : String(e),
    );
    showToast(_('AI Doctor failed'), 'error');
  } finally {
    setDiagnosticActionLoading('aiDoctor', false);
  }
}

function handleOpenAiChat() {
  renderAiChatModal();
}

function handleRestoreNativeInternet() {
  ui.showModal(
    _('Restore Native Internet'),
    E('div', {}, [
      E(
        'p',
        {},
        _(
          'This action will stop Tachyon, restore standard dnsmasq/DNS, remove all proxy/anti-censorship firewall rules and restore direct Internet connection through your ISP.',
        ),
      ),
      E(
        'div',
        {
          class: 'right',
          style:
            'display: flex; justify-content: flex-end; gap: 8px; margin-top: 15px;',
        },
        [
          renderButton({
            classNames: ['cbi-button-neutral'],
            text: _('Cancel'),
            onClick: () => ui.hideModal(),
          }),
          renderButton({
            classNames: ['cbi-button-reset'],
            text: '🚨 ' + _('Restore Native Internet'),
            onClick: async () => {
              ui.hideModal();
              showToast(
                _('Restoring native direct internet (stopping Tachyon)...'),
                'success',
              );
              const res = await TachyonShellMethods.applyQuickFix(
                'restore_native_internet',
              );
              if (
                res &&
                typeof res === 'object' &&
                (res as { success?: boolean }).success
              ) {
                showToast(
                  _('Native internet restored. Tachyon stopped.'),
                  'success',
                );
                await refreshDiagnosticServicesInfo({
                  force: true,
                  allowInactive: true,
                });
              } else {
                showToast(_('Failed to restore native internet'), 'error');
              }
            },
          }),
        ],
      ),
    ]),
  );
}

async function handleShowSingBoxConfig() {
  setDiagnosticActionLoading('showSingBoxConfig', true);

  try {
    const showSingBoxConfig =
      await TachyonShellMethods.showSingBoxConfig(false);

    if (showSingBoxConfig.success) {
      const rawSingBoxConfigText = stringifySingBoxConfig(
        showSingBoxConfig.data,
      );
      const maskedSingBoxConfigText = formatMaskedSingBoxConfig(
        showSingBoxConfig.data,
      );

      ui.showModal(
        _('Show sing-box config'),
        renderModal(rawSingBoxConfigText, 'show_sing_box_config', {
          maskText: () => maskedSingBoxConfigText,
          initialAutoRefresh: false,
          showMaskValuesToggle: true,
        }),
      );
    } else {
      logger.error(
        '[DIAGNOSTIC]',
        'handleShowSingBoxConfig - e',
        showSingBoxConfig,
      );
    }
  } catch (e) {
    logger.error('[DIAGNOSTIC]', 'handleShowSingBoxConfig - e', e);
  } finally {
    setDiagnosticActionLoading('showSingBoxConfig', false);
  }
}

async function handleGenerateBugReport() {
  setDiagnosticActionLoading('generateBugReport', true);
  try {
    const configResult = await fs.read('/etc/config/tachyon').catch(() => '');
    const logsResult = await executeShellCommand({
      command: '/sbin/logread',
      args: ['-e', 'tachyon', '-l', '1000'],
    });
    const singboxLogsResult = await executeShellCommand({
      command: '/sbin/logread',
      args: ['-e', 'sing-box', '-l', '1000'],
    });

    const rawReport = [
      '--- TACHYON CONFIG ---',
      configResult || 'Failed to fetch config',
      '',
      '--- TACHYON LOGS ---',
      logsResult.code === 0
        ? logsResult.stdout
        : 'Failed to fetch tachyon logs',
      '',
      '--- SING-BOX LOGS ---',
      singboxLogsResult.code === 0
        ? singboxLogsResult.stdout
        : 'Failed to fetch sing-box logs',
    ].join('\n');

    const maskedReport = maskGlobalCheckText(rawReport);

    // Download as a text file instead of using clipboard, because navigator.clipboard
    // is undefined in insecure contexts (HTTP) which is common for router web interfaces.
    const blob = new Blob([maskedReport], { type: 'text/plain;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `tachyon-bugreport-${new Date().toISOString().replace(/[:.]/g, '-')}.txt`;
    a.style.display = 'none';
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);

    showToast(_('Bug report downloaded'), 'success');
  } catch (e) {
    logger.error('[DIAGNOSTIC]', 'handleGenerateBugReport - e', e);
    showToast(_('Failed to generate bug report'), 'error');
  } finally {
    setDiagnosticActionLoading('generateBugReport', false);
  }
}

function renderWikiDisclaimerWidget() {
  const diagnosticsChecks = store.get().diagnosticsChecks;

  function getWikiKind() {
    const allResults = diagnosticsChecks.map((check) => check.state);

    if (allResults.includes('error')) {
      return 'error';
    }

    if (allResults.includes('warning')) {
      return 'warning';
    }

    return 'default';
  }

  const container = document.getElementById('tachyon_diagnostic-page-wiki');

  return preserveScrollForPage(() => {
    container!.replaceChildren(renderWikiDisclaimer(getWikiKind()));
  });
}

function renderDiagnosticAvailableActionsWidget() {
  const diagnosticsActions = store.get().diagnosticsActions;
  const updatesActions = store.get().updatesActions;
  const servicesInfoWidget = store.get().servicesInfoWidget;
  logger.debug('[DIAGNOSTIC]', 'renderDiagnosticAvailableActionsWidget');

  const tachyonEnabled = Boolean(servicesInfoWidget.data.tachyonEnabled);
  const tachyonRunning = Boolean(servicesInfoWidget.data.tachyonRunning);
  const serviceTransition = getServiceTransition(
    servicesInfoWidget.data.tachyonStatus,
  );
  const restartLoading =
    diagnosticsActions.restart.loading || serviceTransition.restarting;
  const startLoading =
    diagnosticsActions.start.loading || serviceTransition.starting;
  const stopLoading =
    diagnosticsActions.stop.loading || serviceTransition.stopping;
  const atLeastOneMutatingActionLoading =
    restartLoading ||
    startLoading ||
    stopLoading ||
    diagnosticsActions.enable.loading ||
    diagnosticsActions.disable.loading;
  const componentActionLoading = hasComponentActionLoading(updatesActions);
  const { serviceControlsDisabled, utilityActionsDisabled, viewLogsDisabled } =
    getAvailableActionsDisabledState({
      servicesInfoLoading: servicesInfoWidget.loading,
      mutatingServiceActionLoading: atLeastOneMutatingActionLoading,
      componentActionLoading,
    });
  const startVisible = shouldShowStartAction({
    tachyonRunning,
    restartLoading,
    startLoading,
    stopLoading,
  });
  const stopVisible = shouldShowStopAction({
    tachyonRunning,
    restartLoading,
    startLoading,
    stopLoading,
  });

  const container = document.getElementById('tachyon_diagnostic-page-actions');

  const renderedActions = renderAvailableActions({
    restart: {
      loading: restartLoading,
      visible: shouldShowRestartAction({
        tachyonRunning,
        restartLoading,
        startLoading,
        stopLoading,
      }),
      onClick: handleRestart,
      disabled: serviceControlsDisabled,
    },
    start: {
      loading: startLoading,
      visible: startVisible,
      onClick: handleStart,
      disabled: serviceControlsDisabled,
    },
    stop: {
      loading: stopLoading,
      visible: stopVisible,
      onClick: handleStop,
      disabled: serviceControlsDisabled,
    },
    enable: {
      loading: diagnosticsActions.enable.loading,
      visible: !tachyonEnabled,
      onClick: handleEnable,
      disabled: serviceControlsDisabled,
    },
    disable: {
      loading: diagnosticsActions.disable.loading,
      visible: tachyonEnabled,
      onClick: handleDisable,
      disabled: serviceControlsDisabled,
    },
    globalCheck: {
      loading: diagnosticsActions.globalCheck.loading,
      visible: true,
      onClick: handleShowGlobalCheck,
      disabled: utilityActionsDisabled,
    },
    doctor: {
      loading: diagnosticsActions.doctor.loading,
      visible: true,
      onClick: handleRunDoctor,
      disabled: utilityActionsDisabled,
    },
    aiDoctor: {
      loading: diagnosticsActions.aiDoctor.loading,
      visible: true,
      onClick: handleRunAiDoctor,
      disabled: diagnosticsActions.aiDoctor.loading,
    },
    restoreNativeInternet: {
      loading: false,
      visible: true,
      onClick: handleRestoreNativeInternet,
      disabled: false,
    },
    aiChat: {
      loading: false,
      visible: true,
      onClick: handleOpenAiChat,
      disabled: false,
    },
    checkServices: {
      visible: true,
      loading: diagnosticsActions.checkServices.loading,
      disabled: utilityActionsDisabled,
      onClick: handleCheckServicesAction,
    },
    viewLogs: {
      loading: diagnosticsActions.viewLogs.loading,
      visible: true,
      onClick: handleViewLogs,
      disabled: viewLogsDisabled,
    },
    showSingBoxConfig: {
      loading: diagnosticsActions.showSingBoxConfig.loading,
      visible: true,
      onClick: handleShowSingBoxConfig,
      disabled: utilityActionsDisabled,
    },
    generateBugReport: {
      loading: diagnosticsActions.generateBugReport.loading,
      visible: true,
      onClick: handleGenerateBugReport,
      disabled: utilityActionsDisabled,
    },
  });

  return preserveScrollForPage(() => {
    container!.replaceChildren(renderedActions);
  });
}

function renderDiagnosticSystemInfoWidget() {
  logger.debug('[DIAGNOSTIC]', 'renderDiagnosticSystemInfoWidget');
  const diagnosticsSystemInfo = store.get().diagnosticsSystemInfo;

  const container = document.getElementById(
    'tachyon_diagnostic-page-system-info',
  );

  const items = [
    {
      key: 'Tachyon',
      value: normalizeCompiledVersion(
        diagnosticsSystemInfo.tachyon_version,
        diagnosticsSystemInfo.tachyon_commit_sha,
      ),
    },
    {
      key: 'Luci App',
      value: normalizeCompiledVersion(TACHYON_LUCI_APP_VERSION),
    },
    {
      key: 'Sing-box',
      value: formatSingBoxVersion(diagnosticsSystemInfo),
    },
  ];

  if (diagnosticsSystemInfo.zapret_installed) {
    items.push({
      key: 'Zapret',
      value: diagnosticsSystemInfo.zapret_version,
    });
  }

  if (diagnosticsSystemInfo.zapret2_installed) {
    items.push({
      key: 'Zapret2',
      value: diagnosticsSystemInfo.zapret2_version,
    });
  }

  if (diagnosticsSystemInfo.byedpi_installed) {
    items.push({
      key: 'ByeDPI',
      value: diagnosticsSystemInfo.byedpi_version,
    });
  }

  items.push(
    {
      key: 'OS',
      value: diagnosticsSystemInfo.openwrt_version,
    },
    {
      key: 'Device',
      value: diagnosticsSystemInfo.device_model,
    },
  );

  const renderedSystemInfo = renderSystemInfo({
    items,
  });

  return preserveScrollForPage(() => {
    container!.replaceChildren(renderedSystemInfo);
  });
}

async function onStoreUpdate(
  _next: StoreType,
  _prev: StoreType,
  diff: Partial<StoreType>,
) {
  if (diff.diagnosticsChecks) {
    renderDiagnosticsChecks();
    renderWikiDisclaimerWidget();
  }

  if (diff.diagnosticsRunAction) {
    renderDiagnosticRunActionWidget();
  }

  if (
    diff.diagnosticsActions ||
    diff.servicesInfoWidget ||
    diff.updatesActions
  ) {
    renderDiagnosticAvailableActionsWidget();
  }

  if (diff.diagnosticsActions || diff.servicesInfoWidget) {
    renderDiagnosticRunActionWidget();
  }

  if (diff.diagnosticsSystemInfo) {
    renderDiagnosticSystemInfoWidget();
    renderDiagnosticRunActionWidget();
  }
}

function persistDiagnosticRunProgress({
  providerOptions,
  nextRunnerIndex,
}: {
  providerOptions: DiagnosticsProviderOptions;
  nextRunnerIndex: number;
}) {
  savePersistedDiagnosticRun({
    providerOptions,
    nextRunnerIndex,
    diagnosticsChecks: store.get().diagnosticsChecks,
  });
}

function setDiagnosticCheckLoading(code: DIAGNOSTICS_CHECKS) {
  const meta = DIAGNOSTICS_CHECKS_MAP[code];
  const diagnosticsChecks = store.get().diagnosticsChecks;
  const other = diagnosticsChecks.filter((item) => item.code !== code);

  store.set({
    diagnosticsChecks: [
      ...other,
      {
        order: meta.order,
        code: meta.code,
        title: meta.title,
        description: _('Checking, please wait'),
        state: 'loading',
        items: [],
      },
    ],
  });
}

function getDiagnosticRunners(
  providerOptions: DiagnosticsProviderOptions,
): DiagnosticRunner[] {
  return [
    { code: DIAGNOSTICS_CHECKS.DNS, run: runDnsCheck },
    { code: DIAGNOSTICS_CHECKS.SINGBOX, run: runSingBoxCheck },
    ...(providerOptions.includeInbounds
      ? [{ code: DIAGNOSTICS_CHECKS.INBOUNDS, run: runInboundsCheck }]
      : []),
    { code: DIAGNOSTICS_CHECKS.NFT, run: runNftCheck },
    ...(providerOptions.includeZapret
      ? [{ code: DIAGNOSTICS_CHECKS.ZAPRET, run: runZapretCheck }]
      : []),
    ...(providerOptions.includeZapret2
      ? [{ code: DIAGNOSTICS_CHECKS.ZAPRET2, run: runZapret2Check }]
      : []),
    ...(providerOptions.includeByedpi
      ? [{ code: DIAGNOSTICS_CHECKS.BYEDPI, run: runByedpiCheck }]
      : []),
    { code: DIAGNOSTICS_CHECKS.OUTBOUNDS, run: runSectionsCheck },
    { code: DIAGNOSTICS_CHECKS.FAKEIP, run: runFakeIPCheck },
  ];
}

async function runChecks({ resume }: { resume?: PersistedDiagnosticRun } = {}) {
  if (store.get().diagnosticsRunAction.loading && !resume) {
    return;
  }

  let providerOptions =
    resume?.providerOptions ?? getDiagnosticsProviderOptions();
  let nextRunnerIndex = resume?.nextRunnerIndex ?? 0;

  store.set({
    diagnosticsRunAction: { loading: true },
    diagnosticsChecks:
      resume?.diagnosticsChecks ??
      getLoadingDiagnosticsChecks(providerOptions).diagnosticsChecks,
  });
  persistDiagnosticRunProgress({
    providerOptions,
    nextRunnerIndex,
  });

  try {
    if (!resume) {
      await fetchDiagnosticsProviderInfo({ resetChecks: false });

      providerOptions = getDiagnosticsProviderOptions();
      nextRunnerIndex = 0;

      store.set({
        diagnosticsChecks:
          getLoadingDiagnosticsChecks(providerOptions).diagnosticsChecks,
      });
      persistDiagnosticRunProgress({
        providerOptions,
        nextRunnerIndex,
      });
    }

    const runners = getDiagnosticRunners(providerOptions);

    for (let index = nextRunnerIndex; index < runners.length; index += 1) {
      const runner = runners[index];

      setDiagnosticCheckLoading(runner.code);
      persistDiagnosticRunProgress({
        providerOptions,
        nextRunnerIndex: index,
      });

      try {
        await runner.run();
      } catch (e) {
        logger.error(
          '[DIAGNOSTIC]',
          `runChecks - ${runner.run.name} failed`,
          e,
        );
      }

      persistDiagnosticRunProgress({
        providerOptions,
        nextRunnerIndex: index + 1,
      });
    }
  } catch (e) {
    logger.error('[DIAGNOSTIC]', 'runChecks - e', e);
  } finally {
    clearPersistedDiagnosticRun();
    store.set({ diagnosticsRunAction: { loading: false } });
    if (!diagnosticMounted) {
      diagnosticCompletedWhileHidden = true;
    }
  }
}

async function loadInitialDiagnosticData() {
  const diagnosticStatus = document.getElementById('diagnostic-status');

  if (diagnosticStatus?.isConnected && diagnosticStatus.offsetParent !== null) {
    if (store.get().diagnosticsRunAction.loading) {
      return;
    }

    await fetchSystemInfo();
    await fetchDiagnosticsProviderInfo();
  }
}

function restorePersistedDiagnosticRun() {
  const persistedRun = readPersistedDiagnosticRun();

  if (!persistedRun) {
    return false;
  }

  store.set({
    diagnosticsRunAction: { loading: true },
    diagnosticsChecks: persistedRun.diagnosticsChecks,
  });
  void runChecks({ resume: persistedRun });
  return true;
}

async function onPageMount() {
  const preserveHiddenResult = diagnosticCompletedWhileHidden;

  onPageUnmount({
    preserveCompletedResult: preserveHiddenResult,
    preservePersistedRun: true,
  });

  diagnosticMounted = true;
  diagnosticMountId += 1;
  const mountId = diagnosticMountId;
  const hasRuntimeSnapshot = Boolean(getCachedRuntimeUiState());

  if (!hasRuntimeSnapshot) {
    const uiState = await refreshRuntimeUiState({ force: true });

    if (!diagnosticMounted || mountId !== diagnosticMountId) {
      return;
    }

    if (!uiState) {
      void refreshDiagnosticServicesInfo({ force: true });
    }
  }

  const restoredPersistedRun =
    !preserveHiddenResult && restorePersistedDiagnosticRun();

  if (preserveHiddenResult) {
    diagnosticCompletedWhileHidden = false;
  } else if (
    !restoredPersistedRun &&
    !store.get().diagnosticsRunAction.loading
  ) {
    store.reset(['diagnosticsRunAction']);
    resetDiagnosticsChecks();
  }

  store.subscribe(onStoreUpdate);
  startServiceActionStateWatcher();

  renderDiagnosticsChecks();
  renderDiagnosticRunActionWidget();
  renderDiagnosticAvailableActionsWidget();
  renderDiagnosticSystemInfoWidget();
  renderWikiDisclaimerWidget();

  if (hasRuntimeSnapshot) {
    void refreshRuntimeUiState({ force: true });
  }
  if (!preserveHiddenResult && !restoredPersistedRun) {
    void loadInitialDiagnosticData();
  }
}

function onPageUnmount({
  preserveCompletedResult = false,
  preservePersistedRun = false,
}: {
  preserveCompletedResult?: boolean;
  preservePersistedRun?: boolean;
} = {}) {
  diagnosticMounted = false;
  diagnosticMountId += 1;
  stopServiceActionStateWatcher();
  servicesInfoRefreshPromise = null;

  store.unsubscribe(onStoreUpdate);

  if (!preserveCompletedResult && !store.get().diagnosticsRunAction.loading) {
    if (!preservePersistedRun) {
      clearPersistedDiagnosticRun();
    }
    store.reset(['diagnosticsRunAction']);
    resetDiagnosticsChecks();
    diagnosticCompletedWhileHidden = false;
  }
}

function registerLifecycleListeners() {
  if (diagnosticLifecycleRegistered) {
    return;
  }

  diagnosticLifecycleRegistered = true;

  store.subscribe((next, prev, diff) => {
    if (
      diff.tabService &&
      next.tabService.current !== prev.tabService.current
    ) {
      logger.debug(
        '[DIAGNOSTIC]',
        'active tab diff event, active tab:',
        diff.tabService.current,
      );
      const isDIAGNOSTICVisible = next.tabService.current === 'diagnostic';

      if (isDIAGNOSTICVisible) {
        logger.debug(
          '[DIAGNOSTIC]',
          'registerLifecycleListeners',
          'onPageMount',
        );
        return onPageMount();
      }

      if (!isDIAGNOSTICVisible) {
        logger.debug(
          '[DIAGNOSTIC]',
          'registerLifecycleListeners',
          'onPageUnmount',
        );
        return onPageUnmount();
      }
    }
  });
}

export async function initController(): Promise<void> {
  if (diagnosticControllerInitialized) {
    return;
  }

  diagnosticControllerInitialized = true;

  onMount('diagnostic-status').then(() => {
    logger.debug('[DIAGNOSTIC]', 'initController', 'onMount');
    registerLifecycleListeners();
    if (
      store.get().tabService.current === 'diagnostic' ||
      isActiveLuciTab('diagnostic')
    ) {
      onPageMount();
    }
  });
}
