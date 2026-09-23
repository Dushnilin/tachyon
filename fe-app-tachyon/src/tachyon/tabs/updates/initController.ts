import { onMount, preserveScrollForPage } from '../../../helpers';
import { copyToClipboard } from '../../../helpers/copyToClipboard';
import { TACHYON_ACTION_PROVIDERS_AVAILABILITY_EVENT } from '../../../constants';
import { normalizeCompiledVersion } from '../../../helpers/normalizeCompiledVersion';
import { capSetSize } from '../../helpers/capCollectionSize';
import { showToast } from '../../../helpers/showToast';
import {
  renderCopyIcon24,
  renderDownloadIcon24,
  renderGlobeIcon24,
  renderRotateCcwIcon24,
  renderSearchIcon24,
  renderXIcon24,
} from '../../../icons';
import { renderButton } from '../../../partials';
import { getComponentActionKey } from '../../helpers/getComponentActionKey';
import type { UpdatesActionKey } from '../../helpers/getComponentActionKey';
import { isTransientRpcError } from '../../helpers/isTransientRpcError';
import { isActiveLuciTab } from '../../helpers/isActiveLuciTab';
import { shouldShowLoadingForRestoredAction } from '../../helpers/restoredActionLoading';
import {
  formatSingBoxVersion,
  normalizeSingBoxVariantFields,
  renderSingBoxVariantBadge,
} from '../../helpers/singBoxVariant';
import { shouldApplyCompletedComponentActionResult } from './componentActionCompletion';
import { engineLabel, parkedFeatures } from '../../helpers/engine';
import {
  shouldPreserveCompletedCheckResultOnNextMount,
  shouldExposeCheckResults,
  shouldRefreshComponentStateBeforeRender,
  shouldResetCheckResultsOnMount,
} from './checkResultLifecycle';
import { describeSameReleaseBuild } from './sameReleaseBuild';
import { TachyonShellMethods } from '../../methods';
import {
  logger,
  markUiActionOwned,
  setLocalComponentAction,
  shouldNotifyOwnedUiAction,
  store,
  StoreType,
} from '../../services';
import { ensureSystemInfo } from '../../services/systemInfo.service';
import {
  getCachedRuntimeUiState,
  refreshRuntimeUiState,
  subscribeRuntimeUiState,
} from '../../services/runtimeUiState.service';
import { Tachyon } from '../../types';
import {
  getActiveProgressModalController,
  setActiveProgressModalJobId,
  showUpdateProgressModal,
} from './partials/renderUpdateProgressModal';
import {
  loadHandledJobsFromSession,
  safeReloadPage,
  saveHandledJobToSession,
} from './sessionJobs';

function getComponentCardTitle(component: Tachyon.ComponentName): string {
  switch (component) {
    case 'tachyon':
      return 'Tachyon';
    case 'sing_box':
      return 'Sing-box';
    case 'zapret':
      return 'Zapret';
    case 'zapret2':
      return 'Zapret2';
    case 'byedpi':
      return 'ByeDPI';
    case 'wdtt':
      return 'WDTT';
    case 'olcrtc':
      return 'OlcRTC';
    case 'fptn':
      return 'FPTN';
    case 'tailscale':
      return 'Tailscale';
    case 'steer':
      return 'Steer';
    case 'steer-extended':
      return 'Steer extended';
    case 'engine':
      return _('Routing Engine');
    default:
      return String(component);
  }
}

function getComponentCurrentVersion(
  component: Tachyon.ComponentName,
): string | undefined {
  const sys = store.get().diagnosticsSystemInfo;
  switch (component) {
    case 'tachyon':
      return sys.tachyon_version;
    case 'sing_box':
      return sys.sing_box_version;
    case 'zapret':
      return sys.zapret_version;
    case 'zapret2':
      return sys.zapret2_version;
    case 'byedpi':
      return sys.byedpi_version;
    case 'wdtt':
      return sys.wdtt_version;
    case 'olcrtc':
      return sys.olcrtc_version;
    case 'fptn':
      return sys.fptn_version;
    case 'tailscale':
      return sys.tailscale_version;
    case 'steer':
    case 'steer-extended':
      return sys.steer_version;
    default:
      return undefined;
  }
}

type UpdateStatus = StoreType['updatesChecks'][Tachyon.ComponentName]['status'];

interface ComponentActionButton {
  key: UpdatesActionKey;
  text: string;
  icon: () => SVGSVGElement;
  component: Tachyon.ComponentName;
  action: Tachyon.ComponentAction;
  targetVersion?: string;
  disabled?: boolean;
}

interface ComponentCard {
  component: Tachyon.ComponentName;
  column: 0 | 1 | 2;
  title: string;
  version: string;
  latestVersion?: string;
  releaseUrl?: string;
  repoUrl?: string;
  actions: ComponentActionButton[];
  badgeNode?: Node | null;
  supportsVersions?: boolean;
  copyValue?: string;
}

let updatesLifecycleRegistered = false;
let updatesControllerInitialized = false;
let updatesMounted = false;
let updatesMountId = 0;
let pageUnloading = false;
let preserveCheckResultsOnNextMount = false;
let componentUpdateCheckCacheResolved = false;
let componentUpdateCheckCacheSnapshot: Tachyon.ComponentUpdateCheckCache | null =
  null;
let componentUpdateCheckCachePromise: Promise<Tachyon.ComponentUpdateCheckCache> | null =
  null;
let componentActionStateUnsubscribe: (() => void) | null = null;
let componentActionStateRefreshPromise: Promise<void> | null = null;
const followedComponentJobs = new Set<string>();
const handledComponentJobs = new Set<string>();

let activeVersionPickerComponent: Tachyon.ComponentName | null = null;
let versionPickerLoading = false;
let versionPickerError: string | null = null;
let versionPickerReleases: Tachyon.ComponentRelease[] = [];
const versionPickerReleasesCache: Partial<
  Record<Tachyon.ComponentName, Tachyon.ComponentRelease[]>
> = {};

for (const savedJob of loadHandledJobsFromSession()) {
  handledComponentJobs.add(savedJob);
  followedComponentJobs.add(savedJob);
}
capSetSize(handledComponentJobs);

if (typeof window !== 'undefined') {
  window.addEventListener('pagehide', () => {
    pageUnloading = true;
  });
  window.addEventListener('pageshow', () => {
    pageUnloading = false;
  });
}

function isNotInstalled(version: string | undefined) {
  return !version || version === 'not installed';
}

function shouldShowInstallAfterCheck(component: Tachyon.ComponentName) {
  const status = getVisibleCheckResult(component)?.status;

  return (
    status === 'outdated' ||
    status === 'dev' ||
    status === 'outdated_same_release'
  );
}

function getVisibleCheckResult(component: Tachyon.ComponentName) {
  if (
    !shouldExposeCheckResults({
      mounted: updatesMounted,
      cacheResolved: componentUpdateCheckCacheResolved,
    })
  ) {
    return null;
  }

  return store.get().updatesChecks[component];
}

function getLatestVersion(component: Tachyon.ComponentName) {
  const checkResult = getVisibleCheckResult(component);

  if (!checkResult || !shouldShowInstallAfterCheck(component)) {
    return undefined;
  }

  return checkResult.latest_version || undefined;
}

function getGitHubReleaseUrl(component: Tachyon.ComponentName) {
  const checkResult = getVisibleCheckResult(component);

  if (
    !checkResult ||
    !shouldShowInstallAfterCheck(component) ||
    !checkResult.release_url
  ) {
    return undefined;
  }

  return checkResult.release_url;
}

function isAnyActionLoading() {
  return Object.values(store.get().updatesActions).some((item) => item.loading);
}

function isSystemInfoLoading() {
  const systemInfo = store.get().diagnosticsSystemInfo;

  return systemInfo.loading || !systemInfo.loaded;
}

function setActionLoading(
  action: UpdatesActionKey,
  loading: boolean,
  local = false,
) {
  if (local || !loading) {
    setLocalComponentAction(action, loading && local);
  }

  const updatesActions = store.get().updatesActions;

  store.set({
    updatesActions: {
      ...updatesActions,
      [action]: { loading },
    },
  });
}

function beginComponentAction(button: ComponentActionButton) {
  if (isAnyActionLoading()) {
    showToast(_('Another component action is already running'), 'error');
    return false;
  }

  setActionLoading(button.key, true, true);
  return true;
}

function setCheckResult(
  component: Tachyon.ComponentName,
  status: UpdateStatus,
  latestVersion: string,
  releaseUrl: string = '',
  currentSha: string = '',
  latestSha: string = '',
) {
  const updatesChecks = store.get().updatesChecks;

  store.set({
    updatesChecks: {
      ...updatesChecks,
      [component]: {
        status,
        latest_version: latestVersion,
        release_url: releaseUrl,
        ...(currentSha ? { current_sha: currentSha } : {}),
        ...(latestSha ? { latest_sha: latestSha } : {}),
      },
    },
  });
}

function resetCheckResult(component: Tachyon.ComponentName) {
  setCheckResult(component, null, '');
}

function applyCachedCheckResults(results: Tachyon.ComponentActionResult[]) {
  results.forEach((result) => {
    const status = result.status || null;

    if (
      status === 'latest' ||
      status === 'outdated' ||
      status === 'dev' ||
      status === 'outdated_same_release'
    ) {
      setCheckResult(
        result.component,
        status,
        result.latest_version || '',
        result.release_url || '',
        result.current_sha || '',
        result.latest_sha || '',
      );
    }
  });
}

function loadComponentUpdateCheckCache({ force = false } = {}) {
  if (!force && componentUpdateCheckCacheSnapshot) {
    return Promise.resolve(componentUpdateCheckCacheSnapshot);
  }

  if (componentUpdateCheckCachePromise) {
    return componentUpdateCheckCachePromise;
  }

  const promise = TachyonShellMethods.componentUpdateCheckCache()
    .then((response) =>
      response.success
        ? response.data
        : ({
            enabled: false,
            results: [],
          } satisfies Tachyon.ComponentUpdateCheckCache),
    )
    .then((cache) => {
      componentUpdateCheckCacheSnapshot = cache;
      return cache;
    })
    .finally(() => {
      if (componentUpdateCheckCachePromise === promise) {
        componentUpdateCheckCachePromise = null;
      }
    });

  componentUpdateCheckCachePromise = promise;
  return promise;
}

function getErrorMessage(error: unknown, fallback: string) {
  return error instanceof Error && error.message ? error.message : fallback;
}

async function ackComponentActionJob(jobId: string) {
  try {
    const response = await TachyonShellMethods.uiActionAck('component', jobId);

    if (!response.success) {
      logger.debug('[UPDATES]', 'component action ack failed', response.error);
    }
  } catch (error) {
    logger.debug('[UPDATES]', 'component action ack failed', error);
  }
}

function getExpectedLatestVersionForAction(button: ComponentActionButton) {
  if (button.targetVersion) {
    return button.targetVersion;
  }
  if (
    button.component !== 'tachyon' ||
    (button.action !== 'install' && button.action !== 'reinstall')
  ) {
    return undefined;
  }

  return (
    store.get().updatesChecks[button.component].latest_version || undefined
  );
}

function getCheckToastMessage(status: UpdateStatus) {
  if (status === 'outdated' || status === 'outdated_same_release') {
    return _('Update is available');
  }

  if (status === 'dev') {
    return _('Installed version is newer than release');
  }

  return _('Latest version is installed');
}

async function refreshSystemInfoAfterMutation() {
  await ensureSystemInfo({ force: true, silent: true });
}

function notifyActionProvidersAvailabilityChanged(
  systemInfo: StoreType['diagnosticsSystemInfo'],
) {
  if (typeof window === 'undefined' || typeof CustomEvent === 'undefined') {
    return;
  }

  window.dispatchEvent(
    new CustomEvent(TACHYON_ACTION_PROVIDERS_AVAILABILITY_EVENT, {
      detail: {
        zapretInstalled: Boolean(systemInfo.zapret_installed),
        zapret2Installed: Boolean(systemInfo.zapret2_installed),
        byedpiInstalled: Boolean(systemInfo.byedpi_installed),
        wdttInstalled: Boolean(systemInfo.wdtt_installed),
        olcrtcInstalled: Boolean(systemInfo.olcrtc_installed),
      },
    }),
  );
}

const RELOAD_POLL_INTERVAL_MS = 1000;
const RELOAD_POLL_MAX_WAIT_MS = 30000;

async function waitForTachyonResponsive() {
  const deadline = Date.now() + RELOAD_POLL_MAX_WAIT_MS;
  while (Date.now() < deadline) {
    try {
      const response = await TachyonShellMethods.getUiState();
      if (response.success) {
        return true;
      }
    } catch {
      // Backend is restarting — keep polling until it answers again.
    }
    await new Promise((resolve) =>
      setTimeout(resolve, RELOAD_POLL_INTERVAL_MS),
    );
  }
  return false;
}

function reloadPageAfterTachyonUpdate(jobId?: string) {
  if (jobId) {
    saveHandledJobToSession(jobId);
  }
  // Reload only after the restarted backend actually answers get_ui_state:
  // a fixed delay either reloaded too early (tab hung on stale component
  // action state) or wasted seconds on fast routers.
  void waitForTachyonResponsive().finally(() => {
    safeReloadPage();
  });
}

function patchSystemInfoAfterMutation(result: Tachyon.ComponentActionResult) {
  const systemInfo = store.get().diagnosticsSystemInfo;
  const nextSystemInfo = { ...systemInfo, loading: false, loaded: true };
  const version =
    result.current_version || result.latest_version || _('unknown');

  if (
    result.component === 'tachyon' &&
    (result.action === 'install' || result.action === 'reinstall')
  ) {
    nextSystemInfo.tachyon_version = version;
  }

  if (result.component === 'sing_box') {
    nextSystemInfo.sing_box_version = version;

    if (result.action === 'install_extended') {
      nextSystemInfo.sing_box_extended = 1;
      nextSystemInfo.sing_box_tiny = 0;
      nextSystemInfo.sing_box_compressed = 0;
      nextSystemInfo.sing_box_lx = 0;
      nextSystemInfo.sing_box_tailscale = 1;
    }

    if (result.action === 'install_extended_compressed') {
      nextSystemInfo.sing_box_extended = 1;
      nextSystemInfo.sing_box_tiny = 0;
      nextSystemInfo.sing_box_compressed = 1;
      nextSystemInfo.sing_box_lx = 0;
      nextSystemInfo.sing_box_tailscale = 1;
    }

    if (result.action === 'install_lx') {
      nextSystemInfo.sing_box_extended = 1;
      nextSystemInfo.sing_box_tiny = 0;
      nextSystemInfo.sing_box_compressed = 0;
      nextSystemInfo.sing_box_lx = 1;
      nextSystemInfo.sing_box_tailscale = 1;
    }

    if (result.action === 'install_stable') {
      nextSystemInfo.sing_box_extended = 0;
      nextSystemInfo.sing_box_tiny = 0;
      nextSystemInfo.sing_box_compressed = 0;
      nextSystemInfo.sing_box_lx = 0;
      nextSystemInfo.sing_box_tailscale = 1;
    }

    if (result.action === 'install_tiny') {
      nextSystemInfo.sing_box_extended = 0;
      nextSystemInfo.sing_box_tiny = 1;
      nextSystemInfo.sing_box_compressed = 0;
      nextSystemInfo.sing_box_lx = 0;
      nextSystemInfo.sing_box_tailscale = 0;
    }
  }

  if (result.component === 'zapret') {
    nextSystemInfo.providerInfoLoaded = true;

    if (result.action === 'remove') {
      nextSystemInfo.zapret_installed = 0;
      nextSystemInfo.zapret_version = 'not installed';
    } else {
      nextSystemInfo.zapret_installed = 1;
      nextSystemInfo.zapret_version = version;
    }
  }

  if (result.component === 'zapret2') {
    nextSystemInfo.providerInfoLoaded = true;

    if (result.action === 'remove') {
      nextSystemInfo.zapret2_installed = 0;
      nextSystemInfo.zapret2_version = 'not installed';
    } else {
      nextSystemInfo.zapret2_installed = 1;
      nextSystemInfo.zapret2_version = version;
    }
  }

  if (result.component === 'byedpi') {
    nextSystemInfo.providerInfoLoaded = true;

    if (result.action === 'remove') {
      nextSystemInfo.byedpi_installed = 0;
      nextSystemInfo.byedpi_version = 'not installed';
    } else {
      nextSystemInfo.byedpi_installed = 1;
      nextSystemInfo.byedpi_version = version;
    }
  }

  if (result.component === 'wdtt') {
    nextSystemInfo.providerInfoLoaded = true;

    if (result.action === 'remove') {
      nextSystemInfo.wdtt_installed = 0;
      nextSystemInfo.wdtt_version = 'not installed';
    } else {
      nextSystemInfo.wdtt_installed = 1;
      nextSystemInfo.wdtt_version = version;
    }
  }

  if (result.component === 'olcrtc') {
    nextSystemInfo.providerInfoLoaded = true;

    if (result.action === 'remove') {
      nextSystemInfo.olcrtc_installed = 0;
      nextSystemInfo.olcrtc_version = 'not installed';
    } else {
      nextSystemInfo.olcrtc_installed = 1;
      nextSystemInfo.olcrtc_version = version;
    }
  }

  if (result.component === 'fptn') {
    nextSystemInfo.providerInfoLoaded = true;

    if (result.action === 'remove') {
      nextSystemInfo.fptn_installed = 0;
      nextSystemInfo.fptn_version = 'not installed';
    } else {
      nextSystemInfo.fptn_installed = 1;
      nextSystemInfo.fptn_version = version;
    }
  }

  if (result.component === 'steer' || result.component === 'steer-extended') {
    if (result.action === 'remove') {
      nextSystemInfo.steer_installed = 0;
      nextSystemInfo.steer_version = 'not installed';
      nextSystemInfo.steer_extended = 0;
    } else {
      nextSystemInfo.steer_installed = 1;
      nextSystemInfo.steer_version = version;
      nextSystemInfo.steer_extended =
        result.component === 'steer-extended' ? 1 : 0;
    }
  }

  if (result.component === 'direct_bypass') {
    nextSystemInfo.direct_bypass_enabled = result.action === 'enable' ? 1 : 0;
  }
  if (result.component === 'torrserver_direct') {
    nextSystemInfo.torrserver_direct_enabled =
      result.action === 'enable' ? 1 : 0;
    nextSystemInfo.torrserver_direct_active =
      result.action === 'enable' ? 1 : 0;
  }

  const normalizedSystemInfo = normalizeSingBoxVariantFields(nextSystemInfo);

  store.set({
    diagnosticsSystemInfo: normalizedSystemInfo,
  });

  if (
    result.component === 'zapret' ||
    result.component === 'zapret2' ||
    result.component === 'byedpi' ||
    result.component === 'wdtt' ||
    result.component === 'olcrtc' ||
    result.component === 'fptn'
  ) {
    notifyActionProvidersAvailabilityChanged(normalizedSystemInfo);
  }
}

async function applyCompletedComponentAction({
  key,
  result,
  notify,
}: {
  key: UpdatesActionKey;
  result: Tachyon.ComponentActionResult;
  notify: boolean;
}) {
  const modalController = getActiveProgressModalController();

  if (result.action === 'check_update') {
    setActionLoading(key, false);

    if (!shouldApplyCompletedComponentActionResult(result, notify)) {
      modalController?.completeSuccess(_('Check completed!'));
      return;
    }

    if (
      shouldPreserveCompletedCheckResultOnNextMount({
        action: result.action,
        mounted: updatesMounted,
      })
    ) {
      preserveCheckResultsOnNextMount = true;
    }

    const status = result.status || null;
    const hasUpdate =
      status === 'outdated' || status === 'outdated_same_release';

    if (
      status === 'latest' ||
      status === 'outdated' ||
      status === 'dev' ||
      status === 'outdated_same_release'
    ) {
      setCheckResult(
        result.component,
        status,
        result.latest_version || '',
        result.release_url || '',
        result.current_sha || '',
        result.latest_sha || '',
      );
      modalController?.updateVersions({
        currentVersion: getComponentCurrentVersion(result.component),
        targetVersion: result.latest_version || '',
        currentSha: result.current_sha || '',
        targetSha: result.latest_sha || '',
      });
    }

    if (notify) {
      showToast(getCheckToastMessage(status), 'success');
    }

    if (hasUpdate) {
      const installButton = getComponentInstallAction(result.component);
      modalController?.completeSuccess(getCheckToastMessage(status), {
        autoCloseMs: 0,
        installText: installButton.text,
        onInstall: () => {
          void handleComponentAction(installButton);
        },
      });
    } else {
      modalController?.completeSuccess(getCheckToastMessage(status));
    }
    return;
  }

  if (
    result.action === 'install' ||
    result.action === 'reinstall' ||
    result.action.startsWith('install_')
  ) {
    setCheckResult(result.component, 'latest', result.latest_version || '');
  } else {
    resetCheckResult(result.component);
  }

  patchSystemInfoAfterMutation(result);
  setActionLoading(key, false);

  if (
    result.component === 'tachyon' &&
    (result.action === 'install' ||
      result.action === 'reinstall' ||
      result.action === 'install_version')
  ) {
    const tachyonSuccessMsg =
      result.action === 'install_version'
        ? _('Tachyon updated to') + ' ' + (result.latest_version || '')
        : _('Tachyon has been installed');

    if (notify) {
      showToast(tachyonSuccessMsg, 'success', 1200);
      if (modalController) {
        modalController.completeSuccess(tachyonSuccessMsg, {
          reloadPage: true,
        });
      } else {
        reloadPageAfterTachyonUpdate(result.job_id);
      }
    } else {
      modalController?.completeSuccess(tachyonSuccessMsg);
    }
    return;
  }

  if (notify && result.message) {
    showToast(result.message, 'success');
  }
  modalController?.completeSuccess(result.message);

  void refreshSystemInfoAfterMutation();
}

async function completeComponentActionJob(
  key: UpdatesActionKey,
  jobId: string,
  response: Tachyon.MethodResponse<Tachyon.ComponentActionResult>,
) {
  if (pageUnloading) {
    setActionLoading(key, false);
    return;
  }

  const alreadyHandled = handledComponentJobs.has(jobId);

  if (alreadyHandled) {
    setActionLoading(key, false);
    return;
  }

  const shouldNotify = shouldNotifyOwnedUiAction('component', jobId);
  const modalController = getActiveProgressModalController();

  if (!response.success || !response.data.success) {
    const message = response.success
      ? response.data.message || _('Failed to execute')
      : response.error || _('Failed to execute');

    if (isTransientRpcError(message)) {
      setActionLoading(key, false);
      void refreshComponentActionState();
      return;
    }

    handledComponentJobs.add(jobId);
    capSetSize(handledComponentJobs);
    saveHandledJobToSession(jobId);
    setActionLoading(key, false);
    if (shouldNotify) {
      showToast(message, 'error');
    }
    modalController?.completeError(message);
    await ackComponentActionJob(jobId);
    return;
  }

  handledComponentJobs.add(jobId);
  capSetSize(handledComponentJobs);
  saveHandledJobToSession(jobId);
  await ackComponentActionJob(jobId);
  await applyCompletedComponentAction({
    key,
    result: response.data,
    notify: shouldNotify,
  });
}

async function followComponentActionState(
  state: Tachyon.ComponentActionResult,
) {
  const jobId = state.job_id;
  const key = getComponentActionKey(state.component, state.action);

  if (
    !jobId ||
    !key ||
    followedComponentJobs.has(jobId) ||
    handledComponentJobs.has(jobId)
  ) {
    return;
  }

  followedComponentJobs.add(jobId);
  if (shouldShowLoadingForRestoredAction(state)) {
    setActionLoading(key, true);
    if (!getActiveProgressModalController()) {
      setActiveProgressModalJobId(jobId);
      showUpdateProgressModal({
        component: state.component,
        action: state.action,
        componentTitle: getComponentCardTitle(state.component),
        currentVersion: state.current_version,
        targetVersion: state.latest_version,
      });
    }
    getActiveProgressModalController()?.startLogTracking(jobId);
  }

  try {
    const response = state.running
      ? await TachyonShellMethods.waitComponentActionJob(
          jobId,
          state.component,
          state.action,
          state.latest_version || undefined,
          (phase: string, message?: string) => {
            getActiveProgressModalController()?.updatePhase(phase, message);
          },
        )
      : ({
          success: true,
          data: state,
        } as Tachyon.MethodSuccessResponse<Tachyon.ComponentActionResult>);

    await completeComponentActionJob(key, jobId, response);
  } catch (error) {
    logger.error('[UPDATES]', 'followComponentActionState failed', error);
    if (!pageUnloading) {
      const message = getErrorMessage(error, _('Failed to execute'));

      setActionLoading(key, false);
      if (!isTransientRpcError(message)) {
        showToast(message, 'error');
        getActiveProgressModalController()?.completeError(message);
      }
    }
  } finally {
    followedComponentJobs.delete(jobId);
  }
}

async function followAlreadyRunningComponentAction(
  button: ComponentActionButton,
) {
  const uiState = await refreshRuntimeUiState({ force: true });

  if (!uiState) {
    return false;
  }

  let state = uiState.actions.component.find(
    (item) =>
      item.running &&
      item.component === button.component &&
      item.action === button.action &&
      (!item.job_id || !handledComponentJobs.has(item.job_id)),
  );

  if (!state) {
    state = uiState.actions.component.find(
      (item) =>
        item.running &&
        item.component === button.component &&
        (!item.job_id || !handledComponentJobs.has(item.job_id)),
    );
  }

  if (!state) {
    return false;
  }

  if (state.job_id) {
    markUiActionOwned('component', state.job_id);
  }
  await followComponentActionState(state);
  return true;
}

function isComponentActionAlreadyRunningError(message: string | undefined) {
  return Boolean(
    message && message.includes('Another component action is already running'),
  );
}

function handleComponentUiState(uiState: Tachyon.UiState) {
  for (const state of uiState.actions.component || []) {
    const jobId = state.job_id;
    if (!jobId) {
      continue;
    }

    if (handledComponentJobs.has(jobId) || followedComponentJobs.has(jobId)) {
      continue;
    }

    if (state.running) {
      void followComponentActionState(state);
    } else {
      handledComponentJobs.add(jobId);
      capSetSize(handledComponentJobs);
      saveHandledJobToSession(jobId);
      void ackComponentActionJob(jobId);
    }
  }
}

async function refreshComponentActionState() {
  if (componentActionStateRefreshPromise) {
    return componentActionStateRefreshPromise;
  }

  componentActionStateRefreshPromise = (async () => {
    if (!updatesMounted) {
      return;
    }

    const state = await refreshRuntimeUiState({ force: true });

    if (!state) {
      return;
    }

    handleComponentUiState(state);
  })().finally(() => {
    componentActionStateRefreshPromise = null;
  });

  return componentActionStateRefreshPromise;
}

function startComponentActionStateWatcher() {
  if (componentActionStateUnsubscribe) {
    return;
  }

  componentActionStateUnsubscribe = subscribeRuntimeUiState((uiState) => {
    if (updatesMounted) {
      handleComponentUiState(uiState);
    }
  });
}

function stopComponentActionStateWatcher() {
  if (!componentActionStateUnsubscribe) {
    return;
  }

  componentActionStateUnsubscribe();
  componentActionStateUnsubscribe = null;
}

async function handleComponentAction(button: ComponentActionButton) {
  if (!beginComponentAction(button)) {
    return;
  }

  const cardTitle = getComponentCardTitle(button.component);
  const currentVersion = getComponentCurrentVersion(button.component);
  const targetVersion = getExpectedLatestVersionForAction(button);
  const checkResult = getVisibleCheckResult(button.component);
  const currentSha = checkResult?.current_sha;
  const targetSha = checkResult?.latest_sha;

  let modalController = getActiveProgressModalController();
  if (!modalController) {
    modalController = showUpdateProgressModal({
      component: button.component,
      action: button.action,
      componentTitle: cardTitle,
      currentVersion,
      targetVersion,
      currentSha,
      targetSha,
    });
  }

  let jobId = '';
  let ownsJobFollow = false;

  try {
    const startResponse = await TachyonShellMethods.componentActionStart(
      button.component,
      button.action,
      button.targetVersion,
    );

    if (!startResponse.success) {
      if (isComponentActionAlreadyRunningError(startResponse.error)) {
        if (await followAlreadyRunningComponentAction(button)) {
          return;
        }
        await new Promise((resolve) => setTimeout(resolve, 800));
        if (await followAlreadyRunningComponentAction(button)) {
          return;
        }
        setActionLoading(button.key, false);
        modalController.completeError(
          _('Another component action is already running'),
        );
        await refreshComponentActionState();
        return;
      }

      if (isTransientRpcError(startResponse.error)) {
        if (await followAlreadyRunningComponentAction(button)) {
          return;
        }
        await new Promise((resolve) => setTimeout(resolve, 800));
        if (await followAlreadyRunningComponentAction(button)) {
          return;
        }
        setActionLoading(button.key, false);
        modalController.completeError(
          startResponse.error || _('Transient connection error'),
        );
        await refreshComponentActionState();
        return;
      }

      throw new Error(startResponse.error);
    }

    jobId = startResponse.data.job_id;
    if (followedComponentJobs.has(jobId) || handledComponentJobs.has(jobId)) {
      return;
    }

    followedComponentJobs.add(jobId);
    ownsJobFollow = true;
    setActiveProgressModalJobId(jobId);
    markUiActionOwned('component', jobId);
    modalController.startLogTracking(jobId);

    const response = await TachyonShellMethods.waitComponentActionJob(
      jobId,
      button.component,
      button.action,
      getExpectedLatestVersionForAction(button),
      (phase: string, message?: string) => {
        modalController.updatePhase(phase, message);
      },
    );

    await completeComponentActionJob(button.key, jobId, response);
  } catch (error) {
    logger.error('[UPDATES]', 'handleComponentAction failed', error);
    if (!pageUnloading) {
      const message = getErrorMessage(error, _('Failed to execute'));

      setActionLoading(button.key, false);
      if (!isTransientRpcError(message)) {
        showToast(message, 'error');
      }
      modalController.completeError(message);
      void refreshComponentActionState();
    }
  } finally {
    if (ownsJobFollow) {
      followedComponentJobs.delete(jobId);
    }
  }
}

function getCheckAction(
  component: Tachyon.ComponentName,
  key: UpdatesActionKey,
): ComponentActionButton {
  return {
    key,
    text: _('Check update'),
    icon: renderSearchIcon24,
    component,
    action: 'check_update',
  };
}

function getInstallAction(
  component: Tachyon.ComponentName,
  key: UpdatesActionKey,
  installed: boolean,
): ComponentActionButton {
  return {
    key,
    text: installed ? _('Update') : _('Install'),
    icon: installed ? renderRotateCcwIcon24 : renderDownloadIcon24,
    component,
    action: 'install',
  };
}

function getComponentInstallKey(
  component: Tachyon.ComponentName,
): UpdatesActionKey {
  switch (component) {
    case 'tachyon':
      return 'tachyonInstall';
    case 'sing_box':
      return 'singBoxInstall';
    case 'zapret':
      return 'zapretInstall';
    case 'zapret2':
      return 'zapret2Install';
    case 'byedpi':
      return 'byedpiInstall';
    case 'wdtt':
      return 'wdttInstall';
    case 'olcrtc':
      return 'olcrtcInstall';
    case 'tailscale':
      return 'tailscaleInstall';
    case 'steer':
    case 'steer-extended':
      return 'steerInstall';
    case 'engine':
      return 'engineSwitch';
    default:
      return 'tachyonInstall';
  }
}

function getComponentInstallAction(
  component: Tachyon.ComponentName,
): ComponentActionButton {
  const isInstalled = !isNotInstalled(getComponentCurrentVersion(component));
  const key = getComponentInstallKey(component);
  return getInstallAction(component, key, isInstalled);
}

function getInstalledUpdateActions(
  component: Tachyon.ComponentName,
  checkKey: UpdatesActionKey,
  installKey: UpdatesActionKey,
  installed = true,
) {
  if (!installed) {
    return [];
  }

  const actions = [getCheckAction(component, checkKey)];
  if (shouldShowInstallAfterCheck(component)) {
    actions.push(getInstallAction(component, installKey, true));
  }
  return actions;
}

function getComponentBackupVersion(component: Tachyon.ComponentName): string {
  const sys = store.get().diagnosticsSystemInfo;
  switch (component) {
    case 'sing_box':
      return sys.sing_box_backup_version || '';
    case 'zapret':
      return sys.zapret_backup_version || '';
    case 'zapret2':
      return sys.zapret2_backup_version || '';
    case 'byedpi':
      return sys.byedpi_backup_version || '';
    case 'wdtt':
      return sys.wdtt_backup_version || '';
    case 'olcrtc':
      return sys.olcrtc_backup_version || '';
    case 'fptn':
      return sys.fptn_backup_version || '';
    case 'tailscale':
      return sys.tailscale_backup_version || '';
    case 'steer':
    case 'steer-extended':
      return sys.steer_backup_version || '';
    default:
      return '';
  }
}

function getRollbackAction(
  component: Tachyon.ComponentName,
  key: UpdatesActionKey,
  backupVersion: string,
): ComponentActionButton {
  return {
    key,
    text: backupVersion ? `${_('Rollback')} (${backupVersion})` : _('Rollback'),
    icon: renderRotateCcwIcon24,
    component,
    action: 'rollback',
  };
}

function getOptionalComponentActions({
  component,
  installed,
  checkKey,
  installKey,
  removeKey,
  rollbackKey,
}: {
  component:
    | 'zapret'
    | 'zapret2'
    | 'byedpi'
    | 'wdtt'
    | 'olcrtc'
    | 'fptn'
    | 'tailscale';
  installed: boolean;
  checkKey: UpdatesActionKey;
  installKey: UpdatesActionKey;
  removeKey: UpdatesActionKey;
  rollbackKey: UpdatesActionKey;
}) {
  if (!installed) {
    return [getInstallAction(component, installKey, false)];
  }

  const actions = [
    ...getInstalledUpdateActions(component, checkKey, installKey),
    {
      key: removeKey,
      text: _('Remove'),
      icon: renderXIcon24,
      component,
      action: 'remove' as const,
    },
  ];

  const backupVersion = getComponentBackupVersion(component);
  if (backupVersion) {
    actions.push(getRollbackAction(component, rollbackKey, backupVersion));
  }

  return actions;
}

const COMPONENT_REPO_URLS: Record<Tachyon.ComponentName, string> = {
  tachyon: 'https://github.com/Dushnilin/tachyon',
  sing_box: 'https://github.com/SagerNet/sing-box',
  zapret: 'https://github.com/remittor/zapret-openwrt',
  zapret2: 'https://github.com/Dushnilin/zapret2-openwrt',
  byedpi: 'https://github.com/DPITrickster/ByeDPI-OpenWrt',
  wdtt: 'https://github.com/Dushnilin/qwdtt-openwrt',
  olcrtc: 'https://github.com/Dushnilin/openwrt-olcrtc',
  fptn: 'https://github.com/Dushnilin/fptn',
  tailscale: 'https://openwrt.org/packages/pkgdata/tailscale',
  steer: 'https://github.com/xyzmean/steer',
  'steer-extended': 'https://github.com/xyzmean/steer',
  direct_bypass: '',
  torrserver_direct: '',
  engine: '',
};

function getComponentCards(): ComponentCard[] {
  const systemInfo = normalizeSingBoxVariantFields(
    store.get().diagnosticsSystemInfo,
  );
  const systemInfoLoading = isSystemInfoLoading();
  const zapretInstalled = Boolean(systemInfo.zapret_installed);
  const zapret2Installed = Boolean(systemInfo.zapret2_installed);
  const byedpiInstalled = Boolean(systemInfo.byedpi_installed);
  const wdttInstalled = Boolean(systemInfo.wdtt_installed);
  const olcrtcInstalled = Boolean(systemInfo.olcrtc_installed);
  const fptnInstalled = Boolean(systemInfo.fptn_installed);
  const tailscaleInstalled = Boolean(systemInfo.tailscale_installed);
  const singBoxInstalled = !isNotInstalled(systemInfo.sing_box_version);
  const singBoxStable =
    singBoxInstalled &&
    !systemInfo.sing_box_extended &&
    !systemInfo.sing_box_tiny;
  const singBoxExtended =
    Boolean(systemInfo.sing_box_extended) &&
    !systemInfo.sing_box_compressed &&
    !systemInfo.sing_box_lx;
  const singBoxExtendedCompressed =
    Boolean(systemInfo.sing_box_extended) &&
    Boolean(systemInfo.sing_box_compressed);
  const singBoxLx =
    Boolean(systemInfo.sing_box_extended) && Boolean(systemInfo.sing_box_lx);
  const singBoxTiny = Boolean(systemInfo.sing_box_tiny);

  const tachyonActions = [
    ...getInstalledUpdateActions('tachyon', 'tachyonCheck', 'tachyonInstall'),
    {
      key: 'tachyonReinstall' as const,
      text: _('Reinstall'),
      icon: renderRotateCcwIcon24,
      component: 'tachyon' as const,
      action: 'reinstall' as const,
    },
  ];
  const singBoxActions = getInstalledUpdateActions(
    'sing_box',
    'singBoxCheck',
    'singBoxInstall',
    singBoxInstalled,
  );

  const singBoxBackup = getComponentBackupVersion('sing_box');
  if (singBoxBackup && singBoxInstalled) {
    singBoxActions.push(
      getRollbackAction('sing_box', 'singBoxRollback', singBoxBackup),
    );
  }

  if (!singBoxStable) {
    singBoxActions.push({
      key: 'singBoxInstallStable',
      text: 'Stable',
      icon: renderDownloadIcon24,
      component: 'sing_box',
      action: 'install_stable',
    });
  }
  if (!singBoxTiny) {
    singBoxActions.push({
      key: 'singBoxInstallTiny',
      text: 'Tiny',
      icon: renderDownloadIcon24,
      component: 'sing_box',
      action: 'install_tiny',
    });
  }
  if (!singBoxExtended) {
    singBoxActions.push({
      key: 'singBoxInstallExtended',
      text: 'Extended',
      icon: renderDownloadIcon24,
      component: 'sing_box',
      action: 'install_extended',
    });
  }
  if (!singBoxExtendedCompressed) {
    singBoxActions.push({
      key: 'singBoxInstallExtendedCompressed',
      text: 'Extended compressed',
      icon: renderDownloadIcon24,
      component: 'sing_box',
      action: 'install_extended_compressed',
    });
  }
  if (!singBoxLx) {
    singBoxActions.push({
      key: 'singBoxInstallLx',
      text: 'Leadaxe (lx)',
      icon: renderDownloadIcon24,
      component: 'sing_box',
      action: 'install_lx',
    });
  }

  const zapretActions = getOptionalComponentActions({
    component: 'zapret',
    installed: zapretInstalled,
    checkKey: 'zapretCheck',
    installKey: 'zapretInstall',
    removeKey: 'zapretRemove',
    rollbackKey: 'zapretRollback',
  });
  const zapret2Actions = getOptionalComponentActions({
    component: 'zapret2',
    installed: zapret2Installed,
    checkKey: 'zapret2Check',
    installKey: 'zapret2Install',
    removeKey: 'zapret2Remove',
    rollbackKey: 'zapret2Rollback',
  });
  const byedpiActions = getOptionalComponentActions({
    component: 'byedpi',
    installed: byedpiInstalled,
    checkKey: 'byedpiCheck',
    installKey: 'byedpiInstall',
    removeKey: 'byedpiRemove',
    rollbackKey: 'byedpiRollback',
  });
  const wdttActions = getOptionalComponentActions({
    component: 'wdtt',
    installed: wdttInstalled,
    checkKey: 'wdttCheck',
    installKey: 'wdttInstall',
    removeKey: 'wdttRemove',
    rollbackKey: 'wdttRollback',
  });
  const olcrtcActions = getOptionalComponentActions({
    component: 'olcrtc',
    installed: olcrtcInstalled,
    checkKey: 'olcrtcCheck',
    installKey: 'olcrtcInstall',
    removeKey: 'olcrtcRemove',
    rollbackKey: 'olcrtcRollback',
  });
  const fptnActions = getOptionalComponentActions({
    component: 'fptn',
    installed: fptnInstalled,
    checkKey: 'fptnCheck',
    installKey: 'fptnInstall',
    removeKey: 'fptnRemove',
    rollbackKey: 'fptnRollback',
  });
  const tailscaleActions = getOptionalComponentActions({
    component: 'tailscale',
    installed: tailscaleInstalled,
    checkKey: 'tailscaleCheck',
    installKey: 'tailscaleInstall',
    removeKey: 'tailscaleRemove',
    rollbackKey: 'tailscaleRollback',
  });

  const directBypassEnabled = Boolean(systemInfo.direct_bypass_enabled);
  const directBypassEndpoint = systemInfo.direct_bypass_address
    ? `${systemInfo.direct_bypass_address}:${systemInfo.direct_bypass_port || '2080'}`
    : '';
  const torrserverRunning = Boolean(systemInfo.torrserver_running);
  const torrserverDirectAvailable = Boolean(
    systemInfo.torrserver_direct_available,
  );
  const torrserverDirectEnabled = Boolean(systemInfo.torrserver_direct_enabled);
  const torrserverDirectActive = Boolean(systemInfo.torrserver_direct_active);

  const directBypassActions: ComponentActionButton[] = [
    directBypassEnabled
      ? {
          key: 'directBypassDisable' as const,
          text: _('Disable'),
          icon: renderXIcon24,
          component: 'direct_bypass' as const,
          action: 'disable' as const,
        }
      : {
          key: 'directBypassEnable' as const,
          text: _('Enable'),
          icon: renderRotateCcwIcon24,
          component: 'direct_bypass' as const,
          action: 'enable' as const,
        },
  ];

  const torrserverDirectActions: ComponentActionButton[] = [
    torrserverDirectEnabled
      ? {
          key: 'torrserverDirectDisable' as const,
          text: _('Disable'),
          icon: renderXIcon24,
          component: 'torrserver_direct' as const,
          action: 'disable' as const,
        }
      : {
          key: 'torrserverDirectEnable' as const,
          text: _('Enable'),
          icon: renderRotateCcwIcon24,
          component: 'torrserver_direct' as const,
          action: 'enable' as const,
          disabled: !torrserverDirectAvailable,
        },
  ];

  return [
    {
      component: 'tachyon',
      column: 0,
      title: 'Tachyon',
      version: systemInfoLoading
        ? _('Loading...')
        : normalizeCompiledVersion(
            systemInfo.tachyon_version,
            systemInfo.tachyon_commit_sha,
          ),
      latestVersion: getLatestVersion('tachyon'),
      releaseUrl: getGitHubReleaseUrl('tachyon'),
      repoUrl: COMPONENT_REPO_URLS.tachyon,
      actions: tachyonActions,
      supportsVersions: true,
    },
    {
      component: 'sing_box',
      column: 0,
      title: 'Sing-box',
      version: systemInfoLoading
        ? _('Loading...')
        : formatSingBoxVersion(systemInfo),
      badgeNode: systemInfoLoading
        ? null
        : renderSingBoxVariantBadge(systemInfo),
      latestVersion: getLatestVersion('sing_box'),
      releaseUrl: getGitHubReleaseUrl('sing_box'),
      repoUrl:
        systemInfo.sing_box_repo_url ||
        (singBoxLx
          ? 'https://github.com/Leadaxe/sing-box-lx'
          : singBoxExtended || singBoxExtendedCompressed
            ? 'https://github.com/shtorm-7/sing-box-extended'
            : COMPONENT_REPO_URLS.sing_box),
      actions: singBoxActions,
      supportsVersions: true,
    },
    {
      component: 'direct_bypass',
      column: 0,
      title: _('Direct Proxy'),
      version: directBypassEnabled
        ? `HTTP/SOCKS5 · ${directBypassEndpoint || _('Enabled')}`
        : _('Disabled'),
      copyValue:
        directBypassEnabled && directBypassEndpoint
          ? directBypassEndpoint
          : undefined,
      actions: directBypassActions,
    },
    {
      component: 'torrserver_direct',
      column: 0,
      title: _('TorrServer Direct'),
      version: !torrserverRunning
        ? _('TorrServer not found')
        : !torrserverDirectAvailable
          ? _('Dedicated cgroup unavailable')
          : torrserverDirectEnabled && torrserverDirectActive
            ? _('Enabled')
            : torrserverDirectEnabled
              ? _('Waiting for TorrServer')
              : _('Disabled'),
      actions: torrserverDirectActions,
    },
    {
      component: 'zapret',
      column: 1,
      title: 'Zapret',
      version: systemInfoLoading
        ? _('Loading...')
        : zapretInstalled
          ? systemInfo.zapret_version
          : _('Not installed'),
      latestVersion: getLatestVersion('zapret'),
      releaseUrl: getGitHubReleaseUrl('zapret'),
      repoUrl: COMPONENT_REPO_URLS.zapret,
      actions: zapretActions,
      supportsVersions: true,
    },
    {
      component: 'zapret2',
      column: 1,
      title: 'Zapret2',
      version: systemInfoLoading
        ? _('Loading...')
        : zapret2Installed
          ? systemInfo.zapret2_version
          : _('Not installed'),
      latestVersion: getLatestVersion('zapret2'),
      releaseUrl: getGitHubReleaseUrl('zapret2'),
      repoUrl: COMPONENT_REPO_URLS.zapret2,
      actions: zapret2Actions,
      supportsVersions: true,
    },
    {
      component: 'byedpi',
      column: 1,
      title: 'ByeDPI',
      version: systemInfoLoading
        ? _('Loading...')
        : byedpiInstalled
          ? systemInfo.byedpi_version
          : _('Not installed'),
      latestVersion: getLatestVersion('byedpi'),
      releaseUrl: getGitHubReleaseUrl('byedpi'),
      repoUrl: COMPONENT_REPO_URLS.byedpi,
      actions: byedpiActions,
    },
    {
      component: 'wdtt',
      column: 2,
      title: 'WDTT',
      version: systemInfoLoading
        ? _('Loading...')
        : wdttInstalled
          ? systemInfo.wdtt_version
          : _('Not installed'),
      latestVersion: getLatestVersion('wdtt'),
      releaseUrl: getGitHubReleaseUrl('wdtt'),
      repoUrl: COMPONENT_REPO_URLS.wdtt,
      actions: wdttActions,
      supportsVersions: true,
    },
    {
      component: 'olcrtc',
      column: 2,
      title: 'OlcRTC',
      version: systemInfoLoading
        ? _('Loading...')
        : olcrtcInstalled
          ? systemInfo.olcrtc_version
          : _('Not installed'),
      latestVersion: getLatestVersion('olcrtc'),
      releaseUrl: getGitHubReleaseUrl('olcrtc'),
      repoUrl: COMPONENT_REPO_URLS.olcrtc,
      actions: olcrtcActions,
      supportsVersions: true,
    },
    {
      component: 'fptn',
      column: 2,
      title: 'FPTN',
      version: systemInfoLoading
        ? _('Loading...')
        : fptnInstalled
          ? systemInfo.fptn_version
          : _('Not installed'),
      latestVersion: getLatestVersion('fptn'),
      releaseUrl: getGitHubReleaseUrl('fptn'),
      repoUrl: COMPONENT_REPO_URLS.fptn,
      actions: fptnActions,
      supportsVersions: true,
    },
    {
      component: 'tailscale',
      column: 2,
      title: 'Tailscale',
      version: systemInfoLoading
        ? _('Loading...')
        : tailscaleInstalled
          ? systemInfo.tailscale_version
          : _('Not installed'),
      latestVersion: getLatestVersion('tailscale'),
      releaseUrl: getGitHubReleaseUrl('tailscale'),
      repoUrl: COMPONENT_REPO_URLS.tailscale,
      actions: tailscaleActions,
    },
  ];
}

async function toggleVersionPicker(component: Tachyon.ComponentName) {
  if (activeVersionPickerComponent === component) {
    activeVersionPickerComponent = null;
    versionPickerLoading = false;
    versionPickerError = null;
    renderUpdatesComponents();
    return;
  }

  activeVersionPickerComponent = component;
  versionPickerError = null;

  if (versionPickerReleasesCache[component]) {
    versionPickerReleases = versionPickerReleasesCache[component]!;
    versionPickerLoading = false;
    renderUpdatesComponents();
    return;
  }

  versionPickerLoading = true;
  versionPickerReleases = [];
  renderUpdatesComponents();

  try {
    const response = await TachyonShellMethods.componentListReleases(
      component,
      5,
    );

    if (activeVersionPickerComponent !== component) {
      return;
    }

    if (!response.success) {
      versionPickerError = response.error || _('No versions found');
      versionPickerReleases = [];
    } else if (!response.data || response.data.length === 0) {
      versionPickerError = _('No versions found');
      versionPickerReleases = [];
    } else {
      versionPickerReleases = response.data;
      versionPickerReleasesCache[component] = response.data;
      versionPickerError = null;
    }
  } catch (_error) {
    if (activeVersionPickerComponent !== component) {
      return;
    }
    versionPickerError = _('Failed to load versions');
    versionPickerReleases = [];
  } finally {
    if (activeVersionPickerComponent === component) {
      versionPickerLoading = false;
      renderUpdatesComponents();
    }
  }
}

async function handleInstallVersion(
  component: Tachyon.ComponentName,
  tag: string,
) {
  activeVersionPickerComponent = null;
  renderUpdatesComponents();

  const key = getComponentInstallKey(component);
  const button: ComponentActionButton = {
    key,
    text: _('Install'),
    icon: renderDownloadIcon24,
    component,
    action: 'install_version',
    targetVersion: tag,
  };
  await handleComponentAction(button);
}

function renderVersionPickerDropdown(
  component: Tachyon.ComponentName,
): HTMLElement {
  const container = E('div', { class: 'tachyon-version-picker' });

  if (versionPickerLoading) {
    container.appendChild(
      E(
        'div',
        { class: 'tachyon-version-picker__loading' },
        _('Loading versions...'),
      ),
    );
    return container;
  }

  if (versionPickerError) {
    container.appendChild(
      E('div', { class: 'tachyon-version-picker__error' }, versionPickerError),
    );
    return container;
  }

  const list = E('div', { class: 'tachyon-version-picker__list' });
  for (const release of versionPickerReleases) {
    const children: Node[] = [
      E('span', { class: 'tachyon-version-picker__tag' }, release.tag),
    ];
    if (release.published) {
      children.push(
        E('span', { class: 'tachyon-version-picker__date' }, release.published),
      );
    }
    if (release.prerelease) {
      children.push(
        E(
          'span',
          { class: 'tachyon-version-picker__prerelease' },
          _('pre-release'),
        ),
      );
    }
    children.push(
      renderButton({
        text: _('Install'),
        loading: false,
        disabled: isAnyActionLoading(),
        onClick: () => void handleInstallVersion(component, release.tag),
      }),
    );
    list.appendChild(
      E('div', { class: 'tachyon-version-picker__item' }, children),
    );
  }

  container.appendChild(list);
  return container;
}

function renderComponentCard(card: ComponentCard) {
  const updatesActions = store.get().updatesActions;
  const anyActionLoading = isAnyActionLoading();
  const systemInfoLoading = isSystemInfoLoading();

  const checkResult = getVisibleCheckResult(card.component);

  const headerChildren: Node[] = [
    E('b', { class: 'tachyon_updates-page__component__title' }, card.title),
  ];
  if (card.badgeNode) {
    headerChildren.push(card.badgeNode);
  }
  headerChildren.push(
    E(
      'span',
      { class: 'tachyon_updates-page__component__header-version' },
      card.version,
    ),
  );
  if (card.repoUrl) {
    headerChildren.push(
      E(
        'a',
        {
          class: 'tachyon_updates-page__component__repo-link',
          href: card.repoUrl,
          target: '_blank',
          rel: 'noopener noreferrer',
          title: card.repoUrl,
        },
        renderGlobeIcon24(),
      ),
    );
  }
  const header = E(
    'div',
    { class: 'tachyon_updates-page__component__header' },
    headerChildren,
  );

  const detailsChildren: Node[] = [];

  if (checkResult && checkResult.status) {
    let labelText = '';
    const latestValueNodes: Node[] = [];

    if (checkResult.status === 'outdated') {
      labelText = _('Update is available:');
      const versionToShow =
        checkResult.latest_version || card.latestVersion || card.version;

      if (checkResult.release_url) {
        latestValueNodes.push(
          E(
            'a',
            {
              class: 'tachyon_updates-page__component__release-version-link',
              href: checkResult.release_url,
              target: '_blank',
              rel: 'noopener noreferrer',
            },
            versionToShow || _('Open'),
          ),
        );
      } else if (versionToShow) {
        latestValueNodes.push(document.createTextNode(versionToShow));
      }
    } else if (checkResult.status === 'outdated_same_release') {
      labelText = _('Update is available for current release');
      // Show short commit SHAs so user understands it's the same version, different build
      const build = describeSameReleaseBuild({
        currentSha: checkResult.current_sha,
        latestSha: checkResult.latest_sha,
      });
      latestValueNodes.push(
        E(
          'span',
          {
            class: 'tachyon_updates-page__component__sha-info',
            title: _('Installed build → Available build'),
          },
          build.kind === 'sha' ? build.text : _('Rebuilt release'),
        ),
      );
    } else if (checkResult.status === 'latest') {
      labelText = _('Latest version is installed');
    } else if (checkResult.status === 'dev') {
      labelText = `${_('Installed version is newer than release')}. ${_('Latest version:')}`;
      const versionToShow = checkResult.latest_version || card.latestVersion;

      if (checkResult.release_url) {
        latestValueNodes.push(
          E(
            'a',
            {
              class: 'tachyon_updates-page__component__release-version-link',
              href: checkResult.release_url,
              target: '_blank',
              rel: 'noopener noreferrer',
            },
            versionToShow || _('Open'),
          ),
        );
      } else if (versionToShow) {
        latestValueNodes.push(document.createTextNode(versionToShow));
      }
    }

    if (labelText) {
      const rowChildren: Node[] = [
        E(
          'span',
          { class: 'tachyon_updates-page__component__info-label' },
          labelText,
        ),
      ];
      if (latestValueNodes.length > 0) {
        rowChildren.push(
          E(
            'span',
            {
              class:
                'tachyon_updates-page__component__info-value tachyon_updates-page__component__info-value--latest',
            },
            latestValueNodes,
          ),
        );
      }

      detailsChildren.push(
        E(
          'div',
          { class: 'tachyon_updates-page__component__info-row' },
          rowChildren,
        ),
      );
    }
  }

  const detailsContainer =
    detailsChildren.length > 0
      ? E(
          'div',
          { class: 'tachyon_updates-page__component__details' },
          detailsChildren,
        )
      : null;

  const primaryActions: ComponentActionButton[] = [];
  const dangerActions: ComponentActionButton[] = [];
  const variantActions: ComponentActionButton[] = [];

  card.actions.forEach((action) => {
    if (action.action === 'remove') {
      dangerActions.push(action);
    } else if (action.action.startsWith('install_')) {
      variantActions.push(action);
    } else {
      primaryActions.push(action);
    }
  });

  const actionElements: Node[] = [];

  const primaryButtons = primaryActions.map((action) => {
    const loading = updatesActions[action.key].loading;
    const isUpdateOrInstall =
      action.action === 'install' || action.action === 'reinstall';

    return renderButton({
      classNames: isUpdateOrInstall ? ['cbi-button-save'] : [],
      text: action.text,
      icon: action.icon,
      loading,
      disabled:
        action.disabled || systemInfoLoading || (anyActionLoading && !loading),
      onClick: () => void handleComponentAction(action),
    });
  });

  const dangerButtons = dangerActions.map((action) => {
    const loading = updatesActions[action.key].loading;

    return renderButton({
      classNames: ['cbi-button-remove'],
      text: action.text,
      icon: action.icon,
      loading,
      disabled:
        action.disabled || systemInfoLoading || (anyActionLoading && !loading),
      onClick: () => void handleComponentAction(action),
    });
  });

  if (primaryButtons.length > 0 || dangerButtons.length > 0) {
    actionElements.push(
      E('div', { class: 'tachyon_updates-page__component__actions-main' }, [
        ...primaryButtons,
        ...dangerButtons,
      ]),
    );
  }

  if (card.copyValue) {
    actionElements.push(
      E('div', { class: 'tachyon_updates-page__component__actions-main' }, [
        renderButton({
          text: _('Copy address'),
          icon: renderCopyIcon24,
          disabled: anyActionLoading,
          onClick: () => copyToClipboard(card.copyValue || ''),
        }),
      ]),
    );
  }

  if (variantActions.length > 0) {
    const variantButtons = variantActions.map((action) => {
      const loading = updatesActions[action.key].loading;
      return renderButton({
        text: action.text,
        icon: action.icon,
        loading,
        disabled: systemInfoLoading || (anyActionLoading && !loading),
        onClick: () => void handleComponentAction(action),
      });
    });

    actionElements.push(
      E('div', { class: 'tachyon_updates-page__component__variants' }, [
        E(
          'div',
          { class: 'tachyon_updates-page__component__variants-title' },
          _('Install another build:'),
        ),
        E(
          'div',
          { class: 'tachyon_updates-page__component__variants-buttons' },
          variantButtons,
        ),
      ]),
    );
  }

  if (card.supportsVersions) {
    const isPickerOpen = activeVersionPickerComponent === card.component;
    const versionsButton = renderButton({
      text: isPickerOpen ? _('Hide versions') : _('Versions'),
      loading: isPickerOpen && versionPickerLoading,
      disabled: systemInfoLoading || anyActionLoading,
      onClick: () => void toggleVersionPicker(card.component),
    });
    actionElements.push(
      E('div', { class: 'tachyon_updates-page__component__versions' }, [
        versionsButton,
      ]),
    );

    if (isPickerOpen) {
      actionElements.push(renderVersionPickerDropdown(card.component));
    }
  }

  const actionsContainer = E(
    'div',
    {
      class: [
        'tachyon_updates-page__component__actions',
        detailsContainer
          ? 'tachyon_updates-page__component__actions--with-details'
          : '',
      ]
        .filter(Boolean)
        .join(' '),
    },
    actionElements,
  );

  const cardChildren: Node[] = [header];
  if (detailsContainer) {
    cardChildren.push(detailsContainer);
  }
  cardChildren.push(actionsContainer);

  return E('div', { class: 'tachyon_updates-page__component' }, cardChildren);
}

function isComponentCardVisible(
  card: ComponentCard,
  systemInfo: Record<string, unknown>,
): boolean {
  const component = card.component;
  if (component === 'tachyon' || component === 'sing_box') {
    return true;
  }
  if (component === 'fptn') {
    const fptnInstalled = Boolean(systemInfo.fptn_installed);
    const fptnSupported =
      systemInfo.fptn_supported === undefined
        ? true
        : Boolean(systemInfo.fptn_supported);
    if (!fptnInstalled && !fptnSupported) {
      return false;
    }
  }

  const optKey = `show_component_${component}`;
  const val = systemInfo[optKey];
  if (val === undefined || val === null || val === '') {
    return true;
  }
  return String(val) === '1' || val === 1;
}

let engineInfoCache: Tachyon.EngineInfo | null = null;

async function refreshEngineInfo(): Promise<void> {
  const response = await TachyonShellMethods.getEngineInfo();
  engineInfoCache = response.success ? response.data : null;
}

let selectedEngineOverride: string | null = null;

// One card for the routing engine: sing-box variants and steer variants in a
// single place, with the active engine marked. Installing a variant also makes
// it active, so choosing an engine is one click.
function renderEngineCard(): Node {
  const info = engineInfoCache;
  const systemInfo = normalizeSingBoxVariantFields(
    store.get().diagnosticsSystemInfo,
  );
  const updatesActions = store.get().updatesActions;
  const anyActionLoading = isAnyActionLoading();
  const active = info?.active || 'sing-box';
  const installing = steerBusy;
  const singBoxLoading = isSystemInfoLoading();

  const base = info?.engines.find((e) => e.engine === 'steer');
  const extended = info?.engines.find((e) => e.engine === 'steer-extended');
  const baseInstalled = Boolean(base?.installed || systemInfo.steer_installed);
  const extendedInstalled = Boolean(
    extended?.installed ||
      (systemInfo.steer_installed && systemInfo.steer_extended),
  );

  // sing-box variant availability
  const singBoxInstalled = !isNotInstalled(systemInfo.sing_box_version);
  const singBoxTiny = Boolean(systemInfo.sing_box_tiny);
  const singBoxExtendedCompressed =
    Boolean(systemInfo.sing_box_extended) &&
    Boolean(systemInfo.sing_box_compressed);
  const singBoxLx = Boolean(systemInfo.sing_box_lx);
  const singBoxExtended =
    Boolean(systemInfo.sing_box_extended) &&
    !singBoxExtendedCompressed &&
    !singBoxLx;
  const singBoxStable =
    singBoxInstalled &&
    !singBoxTiny &&
    !singBoxExtended &&
    !singBoxExtendedCompressed &&
    !singBoxLx;

  const isSingBoxActive = active === 'sing-box';

  const engineVersion = isSingBoxActive
    ? singBoxLoading
      ? _('Loading...')
      : formatSingBoxVersion(systemInfo)
    : systemInfo.steer_version ||
      (baseInstalled || extendedInstalled
        ? _('Installed')
        : _('Not installed'));

  // Badge
  let engineBadgeNode: Node | null = null;
  if (isSingBoxActive) {
    engineBadgeNode = singBoxLoading
      ? null
      : renderSingBoxVariantBadge(systemInfo);
  } else if (extendedInstalled) {
    engineBadgeNode = E(
      'span',
      { class: 'tachyon_updates-page__component__badge' },
      'Extended',
    );
  } else if (baseInstalled) {
    engineBadgeNode = E(
      'span',
      { class: 'tachyon_updates-page__component__badge' },
      'Base',
    );
  }

  // Repo URL
  const engineRepoUrl = isSingBoxActive
    ? systemInfo.sing_box_repo_url ||
      (singBoxLx
        ? 'https://github.com/Leadaxe/sing-box-lx'
        : singBoxExtended || singBoxExtendedCompressed
          ? 'https://github.com/shtorm-7/sing-box-extended'
          : COMPONENT_REPO_URLS.sing_box)
    : systemInfo.steer_repo_url || COMPONENT_REPO_URLS.steer;

  // Header
  const headerChildren: Node[] = [
    E(
      'b',
      { class: 'tachyon_updates-page__component__title' },
      _('Routing Engine'),
    ),
  ];
  if (engineBadgeNode) headerChildren.push(engineBadgeNode);
  headerChildren.push(
    E(
      'span',
      { class: 'tachyon_updates-page__component__header-version' },
      engineVersion,
    ),
  );
  if (engineRepoUrl) {
    headerChildren.push(
      E(
        'a',
        {
          class: 'tachyon_updates-page__component__repo-link',
          href: engineRepoUrl,
          target: '_blank',
          rel: 'noopener noreferrer',
          title: engineRepoUrl,
        },
        renderGlobeIcon24(),
      ),
    );
  }
  const header = E(
    'div',
    { class: 'tachyon_updates-page__component__header' },
    headerChildren,
  );

  // ── Details block: check result (same pattern as renderComponentCard) ──────
  const checkComponent: Tachyon.ComponentName = isSingBoxActive
    ? 'sing_box'
    : active === 'steer-extended'
      ? 'steer-extended'
      : 'steer';
  const checkResult = getVisibleCheckResult(checkComponent);
  const detailsChildren: Node[] = [];

  if (checkResult?.status) {
    let labelText = '';
    const latestValueNodes: Node[] = [];

    if (checkResult.status === 'outdated') {
      labelText = _('Update is available:');
      const v = checkResult.latest_version || engineVersion;
      if (checkResult.release_url) {
        latestValueNodes.push(
          E(
            'a',
            {
              class: 'tachyon_updates-page__component__release-version-link',
              href: checkResult.release_url,
              target: '_blank',
              rel: 'noopener noreferrer',
            },
            v || _('Open'),
          ),
        );
      } else if (v) {
        latestValueNodes.push(document.createTextNode(v));
      }
    } else if (checkResult.status === 'outdated_same_release') {
      labelText = _('Update is available for current release');
      const build = describeSameReleaseBuild({
        currentSha: checkResult.current_sha,
        latestSha: checkResult.latest_sha,
      });
      latestValueNodes.push(
        E(
          'span',
          {
            class: 'tachyon_updates-page__component__sha-info',
            title: _('Installed build → Available build'),
          },
          build.kind === 'sha' ? build.text : _('Rebuilt release'),
        ),
      );
    } else if (checkResult.status === 'latest') {
      labelText = _('Latest version is installed');
    } else if (checkResult.status === 'dev') {
      labelText = `${_('Installed version is newer than release')}. ${_('Latest version:')}`;
      const v = checkResult.latest_version || getLatestVersion(checkComponent);
      if (checkResult.release_url) {
        latestValueNodes.push(
          E(
            'a',
            {
              class: 'tachyon_updates-page__component__release-version-link',
              href: checkResult.release_url,
              target: '_blank',
              rel: 'noopener noreferrer',
            },
            v || _('Open'),
          ),
        );
      } else if (v) {
        latestValueNodes.push(document.createTextNode(v));
      }
    }

    if (labelText) {
      const rowChildren: Node[] = [
        E(
          'span',
          { class: 'tachyon_updates-page__component__info-label' },
          labelText,
        ),
      ];
      if (latestValueNodes.length > 0) {
        rowChildren.push(
          E(
            'span',
            {
              class:
                'tachyon_updates-page__component__info-value tachyon_updates-page__component__info-value--latest',
            },
            latestValueNodes,
          ),
        );
      }
      detailsChildren.push(
        E(
          'div',
          { class: 'tachyon_updates-page__component__info-row' },
          rowChildren,
        ),
      );
    }
  }

  const detailsContainer =
    detailsChildren.length > 0
      ? E(
          'div',
          { class: 'tachyon_updates-page__component__details' },
          detailsChildren,
        )
      : null;

  // ── Variant selector: all sing-box flavours + steer in one dropdown ────────
  interface SelectableVariant {
    id: string;
    label: string;
    group: 'sing-box' | 'steer';
    installed: boolean;
    active: boolean;
  }

  const currentSingBoxVariant = singBoxTiny
    ? 'sing-box-tiny'
    : singBoxExtendedCompressed
      ? 'sing-box-extended-compressed'
      : singBoxLx
        ? 'sing-box-lx'
        : singBoxExtended
          ? 'sing-box-extended'
          : 'sing-box-stable';

  const selectableVariants: SelectableVariant[] = [
    {
      id: 'sing-box-stable',
      label: 'sing-box (Stable)',
      group: 'sing-box',
      installed: singBoxInstalled && singBoxStable,
      active: isSingBoxActive && singBoxStable,
    },
    {
      id: 'sing-box-tiny',
      label: 'sing-box (Tiny)',
      group: 'sing-box',
      installed: singBoxInstalled && singBoxTiny,
      active: isSingBoxActive && singBoxTiny,
    },
    {
      id: 'sing-box-extended',
      label: 'sing-box (Extended)',
      group: 'sing-box',
      installed: singBoxInstalled && singBoxExtended,
      active: isSingBoxActive && singBoxExtended,
    },
    {
      id: 'sing-box-extended-compressed',
      label: 'sing-box (Extended compressed)',
      group: 'sing-box',
      installed: singBoxInstalled && singBoxExtendedCompressed,
      active: isSingBoxActive && singBoxExtendedCompressed,
    },
    {
      id: 'sing-box-lx',
      label: 'sing-box (Leadaxe)',
      group: 'sing-box',
      installed: singBoxInstalled && singBoxLx,
      active: isSingBoxActive && singBoxLx,
    },
    {
      id: 'steer',
      label: 'Steer (Base)',
      group: 'steer',
      installed: baseInstalled && !extendedInstalled,
      active: active === 'steer',
    },
    {
      id: 'steer-extended',
      label: 'Steer extended',
      group: 'steer',
      installed: extendedInstalled,
      active: active === 'steer-extended',
    },
  ];

  const defaultSelectedId =
    selectedEngineOverride ||
    (isSingBoxActive ? currentSingBoxVariant : active);
  const selectedVariant =
    selectableVariants.find((v) => v.id === defaultSelectedId) ??
    selectableVariants[0]!;

  const picker = E('select', {
    class: 'cbi-input-select',
    style: 'min-width: 210px;',
  }) as HTMLSelectElement;
  const sbGroup = E('optgroup', { label: 'sing-box' }) as HTMLOptGroupElement;
  const stGroup = E('optgroup', { label: 'Steer' }) as HTMLOptGroupElement;

  selectableVariants.forEach((entry) => {
    const suffix = entry.active
      ? ' ✓'
      : !entry.installed
        ? ` (${_('not installed')})`
        : '';
    const opt = E(
      'option',
      { value: entry.id },
      `${entry.label}${suffix}`,
    ) as HTMLOptionElement;
    opt.selected = entry.id === selectedVariant.id;
    (entry.group === 'sing-box' ? sbGroup : stGroup).appendChild(opt);
  });
  picker.appendChild(sbGroup);
  picker.appendChild(stGroup);
  picker.addEventListener('change', (e) => {
    selectedEngineOverride = (e.target as HTMLSelectElement).value;
    renderUpdatesComponents();
  });

  const warning = E('div', {
    style:
      'font-size:12px;color:var(--text-color-medium,#b58900);margin-top:6px;display:none;',
  });

  function getVariantEngine(
    id: string,
  ): 'sing-box' | 'steer' | 'steer-extended' {
    if (id === 'steer') return 'steer';
    if (id === 'steer-extended') return 'steer-extended';
    return 'sing-box';
  }
  function getVariantInstallAction(id: string): Tachyon.ComponentAction {
    switch (id) {
      case 'sing-box-tiny':
        return 'install_tiny';
      case 'sing-box-extended':
        return 'install_extended';
      case 'sing-box-extended-compressed':
        return 'install_extended_compressed';
      case 'sing-box-lx':
        return 'install_lx';
      default:
        return 'install_stable';
    }
  }

  const isSelectedSingBox = selectedVariant.group === 'sing-box';
  const isSelectedSteer = selectedVariant.group === 'steer';
  const isSelectedActive = selectedVariant.active;
  const isSelectedInstalled = selectedVariant.installed;

  const applyButton = renderButton({
    text: isSelectedActive
      ? _('Active')
      : isSelectedInstalled
        ? _('Apply')
        : _('Install & Switch'),
    classNames: ['cbi-button-action'],
    disabled:
      installing || singBoxLoading || isSelectedActive || anyActionLoading,
    onClick: () => {
      if (isSelectedActive) return;
      const engineId = getVariantEngine(selectedVariant.id);
      if (isSelectedSingBox) {
        if (!isSelectedInstalled) {
          void runComponentAction(
            'sing_box',
            getVariantInstallAction(selectedVariant.id),
            'singBoxInstall',
          );
        } else if (engineId !== active) {
          void applyEngineSelection(engineId, active, warning as HTMLElement);
        }
      } else {
        if (!isSelectedInstalled) {
          void runSteerAction(engineId, 'install');
        } else {
          void applyEngineSelection(engineId, active, warning as HTMLElement);
        }
      }
    },
  });

  // ── "Check update" button for active engine ────────────────────────────────
  const checkUpdateAction: ComponentActionButton = {
    key: isSingBoxActive ? 'singBoxCheck' : 'steerCheck',
    text: _('Check update'),
    icon: renderSearchIcon24,
    component: checkComponent,
    action: 'check_update',
  };
  const checkUpdateLoading = Boolean(
    updatesActions[checkUpdateAction.key]?.loading,
  );
  const checkUpdateButton = renderButton({
    text: checkUpdateAction.text,
    icon: checkUpdateAction.icon,
    loading: checkUpdateLoading,
    disabled:
      singBoxLoading || installing || (anyActionLoading && !checkUpdateLoading),
    onClick: () => void handleComponentAction(checkUpdateAction),
  });

  // ── "Update" button when update available ────────────────────────────────
  const showUpdateBtn = shouldShowInstallAfterCheck(checkComponent);
  const updateButton = showUpdateBtn
    ? (() => {
        const ua: ComponentActionButton = {
          key: isSingBoxActive ? 'singBoxInstall' : 'steerInstall',
          text: _('Update'),
          icon: renderRotateCcwIcon24,
          component: checkComponent,
          action: 'install',
        };
        const loading = Boolean(updatesActions[ua.key]?.loading);
        return renderButton({
          classNames: ['cbi-button-save'],
          text: ua.text,
          icon: ua.icon,
          loading,
          disabled: singBoxLoading || (anyActionLoading && !loading),
          onClick: () => void handleComponentAction(ua),
        });
      })()
    : null;

  const actionElements: Node[] = [];

  // Row 1: picker + Apply + Check update [+ Update]
  const primaryRow: Node[] = [picker, applyButton, checkUpdateButton];
  if (updateButton) primaryRow.push(updateButton);
  actionElements.push(
    E(
      'div',
      {
        class: 'tachyon_updates-page__component__actions-main',
        style: 'margin-bottom:8px;gap:8px;align-items:center;flex-wrap:wrap;',
      },
      primaryRow,
    ),
    warning,
  );

  // Remove (steer only)
  if (isSelectedSteer && (baseInstalled || extendedInstalled)) {
    const removeLoading = Boolean(updatesActions.steerRemove?.loading);
    actionElements.push(
      E(
        'div',
        {
          class: 'tachyon_updates-page__component__actions-main',
          style: 'margin-top:4px;',
        },
        [
          renderButton({
            text: _('Remove'),
            classNames: ['cbi-button-remove'],
            loading: removeLoading,
            disabled: installing || anyActionLoading,
            onClick: () =>
              void runSteerAction(
                getVariantEngine(selectedVariant.id),
                'remove',
              ),
          }),
        ],
      ),
    );
  }

  // Versions picker
  const isPickerOpen = activeVersionPickerComponent === checkComponent;
  actionElements.push(
    E('div', { class: 'tachyon_updates-page__component__versions' }, [
      renderButton({
        text: isPickerOpen ? _('Hide versions') : _('Versions'),
        loading: isPickerOpen && versionPickerLoading,
        disabled: singBoxLoading || anyActionLoading || steerBusy,
        onClick: () => void toggleVersionPicker(checkComponent),
      }),
    ]),
  );
  if (isPickerOpen) {
    actionElements.push(renderVersionPickerDropdown(checkComponent));
  }

  const actionsContainer = E(
    'div',
    {
      class: [
        'tachyon_updates-page__component__actions',
        detailsContainer
          ? 'tachyon_updates-page__component__actions--with-details'
          : '',
      ]
        .filter(Boolean)
        .join(' '),
    },
    actionElements,
  );

  const cardChildren: Node[] = [header];
  if (detailsContainer) cardChildren.push(detailsContainer);
  cardChildren.push(actionsContainer);

  return E('div', { class: 'tachyon_updates-page__component' }, cardChildren);
}

let steerBusy = false;

interface EngineFlowJob {
  component: Tachyon.ComponentName;
  action: Tachyon.ComponentAction;
  key: UpdatesActionKey;
  /** Extra arg for componentActionStart (target version or engine name). */
  extra?: string;
}

/**
 * Run one or more component-action jobs under a single progress modal with log
 * polling. Used by the engine card: Install & Switch chains install + engine
 * switch, Apply runs only the switch. The modal stays open across jobs and is
 * completed once at the end (or on the first failure).
 */
async function runEngineFlow(
  jobs: EngineFlowJob[],
  modalOptions: Parameters<typeof showUpdateProgressModal>[0],
  successMessage: string,
): Promise<void> {
  if (isAnyActionLoading()) {
    showToast(_('Another component action is already running'), 'error');
    return;
  }

  steerBusy = true;
  for (const job of jobs) {
    setActionLoading(job.key, true, true);
  }
  renderUpdatesComponents();

  let modalController = getActiveProgressModalController();
  if (!modalController) {
    modalController = showUpdateProgressModal(modalOptions);
  }

  const ownedJobIds: string[] = [];
  let delegated = false;

  try {
    for (const job of jobs) {
      const startResponse = await TachyonShellMethods.componentActionStart(
        job.component,
        job.action,
        job.extra,
      );

      if (!startResponse.success) {
        if (
          isComponentActionAlreadyRunningError(startResponse.error) ||
          isTransientRpcError(startResponse.error)
        ) {
          const button: ComponentActionButton = {
            key: job.key,
            text: job.action,
            icon: renderRotateCcwIcon24,
            component: job.component,
            action: job.action,
            targetVersion: job.extra,
          };
          if (await followAlreadyRunningComponentAction(button)) {
            delegated = true;
            return;
          }
        }
        throw new Error(startResponse.error);
      }

      const jobId = startResponse.data.job_id;
      if (followedComponentJobs.has(jobId) || handledComponentJobs.has(jobId)) {
        delegated = true;
        return;
      }

      followedComponentJobs.add(jobId);
      ownedJobIds.push(jobId);
      setActiveProgressModalJobId(jobId);
      markUiActionOwned('component', jobId);
      modalController.startLogTracking(jobId);

      const response = await TachyonShellMethods.waitComponentActionJob(
        jobId,
        job.component,
        job.action,
        job.extra,
        (phase: string, message?: string) => {
          modalController.updatePhase(phase, message);
        },
      );

      const succeeded = response.success && response.data.success;
      if (!succeeded) {
        const message = response.success
          ? response.data.message || _('Failed to execute')
          : response.error || _('Failed to execute');

        if (isTransientRpcError(message)) {
          void refreshComponentActionState();
          return;
        }

        handledComponentJobs.add(jobId);
        capSetSize(handledComponentJobs);
        saveHandledJobToSession(jobId);
        await ackComponentActionJob(jobId);
        showToast(message, 'error');
        modalController.completeError(message);
        return;
      }

      handledComponentJobs.add(jobId);
      capSetSize(handledComponentJobs);
      saveHandledJobToSession(jobId);
      await ackComponentActionJob(jobId);

      if (job.component !== 'engine') {
        patchSystemInfoAfterMutation(response.data);
        if (
          job.action === 'install' ||
          job.action === 'reinstall' ||
          job.action.startsWith('install_')
        ) {
          setCheckResult(
            job.component,
            'latest',
            response.data.latest_version || '',
          );
        } else {
          resetCheckResult(job.component);
        }
      }
    }

    await refreshEngineInfo();
    await refreshSystemInfoAfterMutation();
    showToast(successMessage, 'success');
    modalController.completeSuccess(successMessage);
  } catch (error) {
    logger.error('[UPDATES]', 'runEngineFlow failed', error);
    if (!pageUnloading) {
      const message = getErrorMessage(error, _('Failed to execute'));
      if (!isTransientRpcError(message)) {
        showToast(message, 'error');
      }
      getActiveProgressModalController()?.completeError(message);
      await refreshComponentActionState();
    }
  } finally {
    for (const jobId of ownedJobIds) {
      followedComponentJobs.delete(jobId);
    }
    if (!delegated) {
      for (const job of jobs) {
        setActionLoading(job.key, false);
      }
      steerBusy = false;
      renderUpdatesComponents();
    }
  }
}

// Run a sing-box variant action from the engine card: install the selected
// variant, then make sing-box the active engine so Install & Switch is one click.
async function runComponentAction(
  component: Tachyon.ComponentName,
  action: Tachyon.ComponentAction,
  _key: string,
): Promise<void> {
  const engineTarget = 'sing-box';
  const installKey =
    getComponentActionKey(component, action) ??
    getComponentInstallKey(component);
  await runEngineFlow(
    [
      { component, action, key: installKey },
      {
        component: 'engine',
        action: 'switch',
        key: 'engineSwitch',
        extra: engineTarget,
      },
    ],
    {
      component,
      action,
      componentTitle: getComponentCardTitle(component),
      currentVersion: getComponentCurrentVersion(component),
    },
    `${_('Active engine')}: ${engineLabel(engineTarget)}`,
  );
}

// Install/update a steer variant, then make it the active engine so the
// user's choice takes effect without a second step.
async function runSteerAction(
  component: string,
  action: string,
): Promise<void> {
  const jobs: EngineFlowJob[] = [
    {
      component: component as Tachyon.ComponentName,
      action: action as Tachyon.ComponentAction,
      key: action === 'remove' ? 'steerRemove' : 'steerInstall',
    },
  ];
  if (action === 'install') {
    jobs.push({
      component: 'engine',
      action: 'switch',
      key: 'engineSwitch',
      extra: component,
    });
  }

  await runEngineFlow(
    jobs,
    {
      component: component as Tachyon.ComponentName,
      action: action as Tachyon.ComponentAction,
      componentTitle: getComponentCardTitle(component as Tachyon.ComponentName),
      currentVersion: getComponentCurrentVersion(
        component as Tachyon.ComponentName,
      ),
    },
    action === 'install'
      ? `${_('Active engine')}: ${engineLabel(component)}`
      : `${_('Steer')}: ${action}`,
  );
}

async function applyEngineSelection(
  engine: string,
  current: string,
  warning: HTMLElement,
): Promise<void> {
  if (engine === current) {
    return;
  }

  const planResponse = await TachyonShellMethods.getEnginePlan(engine);
  const parked = planResponse.success ? parkedFeatures(planResponse.data) : [];
  if (parked.length > 0) {
    warning.style.display = 'block';
    warning.textContent = `${_('These features will be parked and restored when you switch back')}: ${parked.join(', ')}`;
  } else {
    warning.style.display = 'none';
  }

  await runEngineFlow(
    [
      {
        component: 'engine',
        action: 'switch',
        key: 'engineSwitch',
        extra: engine,
      },
    ],
    {
      component: 'engine',
      action: 'switch',
      componentTitle: _('Routing Engine'),
      currentVersion: engineLabel(current),
      targetVersion: engineLabel(engine),
    },
    `${_('Active engine')}: ${engineLabel(engine)}`,
  );
}

function renderUpdatesComponents() {
  const container = document.getElementById('tachyon_updates-components');

  if (!container) {
    return;
  }

  const systemInfo = normalizeSingBoxVariantFields(
    store.get().diagnosticsSystemInfo,
  );

  // The sing-box card is folded into the Routing Engine card, so drop it from
  // the grid and insert the single engine card right after Tachyon.
  const visibleCards = getComponentCards()
    .filter((card) => card.component !== 'sing_box')
    .filter((card) => isComponentCardVisible(card, systemInfo));

  const columns: Node[][] = [[], [], []];
  const colCounts = [0, 0, 0];
  visibleCards.forEach((card) => {
    colCounts[card.column] = (colCounts[card.column] || 0) + 1;
  });
  const hasEmptyColumn =
    colCounts.some((c) => c === 0) && visibleCards.length >= 3;

  visibleCards.forEach((card, idx) => {
    const colIdx = hasEmptyColumn ? idx % 3 : card.column;
    columns[colIdx]?.push(renderComponentCard(card));

    if (idx === 0) {
      columns[colIdx]?.push(renderEngineCard());
    }
  });

  return preserveScrollForPage(() => {
    container.replaceChildren(
      ...columns.map((columnNodes) =>
        E(
          'div',
          { class: 'tachyon_updates-page__components-column' },
          columnNodes,
        ),
      ),
    );
  });
}

function onStoreUpdate(
  _next: StoreType,
  _prev: StoreType,
  diff: Partial<StoreType>,
) {
  if (
    diff.diagnosticsSystemInfo ||
    diff.updatesActions ||
    diff.updatesChecks ||
    diff.diagnosticsActions ||
    diff.servicesInfoWidget
  ) {
    renderUpdatesComponents();
  }
}

function applyComponentUpdateCheckCache(
  componentUpdateCheckCache: Tachyon.ComponentUpdateCheckCache,
) {
  componentUpdateCheckCacheResolved = true;

  if (componentUpdateCheckCache.enabled) {
    store.reset(['updatesChecks']);
    applyCachedCheckResults(componentUpdateCheckCache.results);
  }

  if (
    shouldResetCheckResultsOnMount({
      anyActionLoading: isAnyActionLoading(),
      preserveCheckResultsOnNextMount,
      persistentCacheEnabled: componentUpdateCheckCache.enabled,
    })
  ) {
    store.reset(['updatesChecks']);
  }
}

async function onPageMount() {
  onPageUnmount();

  updatesMounted = true;
  updatesMountId += 1;
  const mountId = updatesMountId;
  const cachedRuntimeState = getCachedRuntimeUiState();
  const hasRuntimeSnapshot = Boolean(cachedRuntimeState);
  const needsFreshStateBeforeRender =
    shouldRefreshComponentStateBeforeRender(cachedRuntimeState);
  const runtimeStateRefreshPromise =
    !hasRuntimeSnapshot || needsFreshStateBeforeRender
      ? refreshRuntimeUiState({ force: true })
      : null;
  const prefetchedComponentUpdateCheckCache = componentUpdateCheckCacheSnapshot;

  if (prefetchedComponentUpdateCheckCache) {
    applyComponentUpdateCheckCache(prefetchedComponentUpdateCheckCache);
  }

  renderUpdatesComponents();

  void refreshEngineInfo().then(() => {
    if (updatesMounted && mountId === updatesMountId) {
      renderUpdatesComponents();
    }
  });

  const componentUpdateCheckCache = await loadComponentUpdateCheckCache({
    force: Boolean(prefetchedComponentUpdateCheckCache),
  });

  if (!updatesMounted || mountId !== updatesMountId) {
    return;
  }

  applyComponentUpdateCheckCache(componentUpdateCheckCache);
  preserveCheckResultsOnNextMount = false;
  renderUpdatesComponents();

  if (runtimeStateRefreshPromise) {
    await runtimeStateRefreshPromise;

    if (!updatesMounted || mountId !== updatesMountId) {
      return;
    }
  }

  store.subscribe(onStoreUpdate);
  startComponentActionStateWatcher();
  renderUpdatesComponents();
  void ensureSystemInfo();
  if (hasRuntimeSnapshot) {
    void refreshRuntimeUiState({ force: true });
  }
}

function onPageUnmount() {
  updatesMounted = false;
  updatesMountId += 1;
  activeVersionPickerComponent = null;
  stopComponentActionStateWatcher();
  store.unsubscribe(onStoreUpdate);
}

function registerLifecycleListeners() {
  if (updatesLifecycleRegistered) {
    return;
  }

  updatesLifecycleRegistered = true;

  store.subscribe((next, prev, diff) => {
    if (
      diff.tabService &&
      next.tabService.current !== prev.tabService.current
    ) {
      const isUpdatesVisible = next.tabService.current === 'updates';

      if (isUpdatesVisible) {
        return onPageMount();
      }

      if (updatesMounted) {
        return onPageUnmount();
      }
    }
  });
}

export async function initController(): Promise<void> {
  if (updatesControllerInitialized) {
    return;
  }

  updatesControllerInitialized = true;
  void loadComponentUpdateCheckCache();

  onMount('updates-status').then(() => {
    logger.debug('[UPDATES]', 'initController', 'onMount');
    registerLifecycleListeners();
    if (
      store.get().tabService.current === 'updates' ||
      isActiveLuciTab('updates')
    ) {
      onPageMount();
    }
  });
}
