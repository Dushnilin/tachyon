import { onMount, preserveScrollForPage } from '../../../helpers';
import { copyToClipboard } from '../../../helpers/copyToClipboard';
import { normalizeCompiledVersion } from '../../../helpers/normalizeCompiledVersion';
import { capSetSize } from '../../helpers/capCollectionSize';
import { showToast } from '../../../helpers/showToast';
import {
  renderCopyIcon24,
  renderDownloadIcon24,
  renderFileTextIcon14,
  renderGlobeIcon24,
  renderRotateCcwIcon24,
  renderXIcon24,
} from '../../../icons';
import { renderButton } from '../../../partials';
import { getComponentActionKey } from '../../helpers/getComponentActionKey';
import type { UpdatesActionKey } from '../../helpers/getComponentActionKey';
import { isTransientRpcError } from '../../helpers/isTransientRpcError';
import { isActiveLuciTab } from '../../helpers/isActiveLuciTab';
import { shouldShowLoadingForRestoredAction } from '../../helpers/restoredActionLoading';
import { formatCoreVersion } from '../../helpers/coreVersion';
import { shouldApplyCompletedComponentActionResult } from './componentActionCompletion';
import {
  shouldPreserveCompletedCheckResultOnNextMount,
  shouldExposeCheckResults,
  shouldRefreshComponentStateBeforeRender,
  shouldResetCheckResultsOnMount,
} from './checkResultLifecycle';
import { getReleaseForNotes } from './releaseNotes';
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
import {
  getCheckToastMessage,
  getErrorMessage,
  getExpectedLatestVersionForAction as getExpectedLatestVersionHelper,
  isComponentActionAlreadyRunningError,
  type UpdateStatus,
} from './notifications';
import { computeSystemInfoMutation } from './mutations';
import {
  COMPONENT_REPO_URLS,
  getCheckAction,
  getComponentBackupVersion as getComponentBackupVersionHelper,
  getComponentCardTitle,
  getComponentCurrentVersion as getComponentCurrentVersionHelper,
  getComponentInstallKey,
  getInstallAction,
  getRollbackAction,
  type ComponentActionButton,
  type ComponentCard,
} from './cardDefinitions';

function getComponentCurrentVersion(
  component: Tachyon.ComponentName,
): string | undefined {
  const fromSys = getComponentCurrentVersionHelper(
    component,
    store.get().diagnosticsSystemInfo,
  );
  if (fromSys && fromSys !== 'not installed') {
    return fromSys;
  }
  const cachedCurr = store.get().updatesChecks[component]?.current_version;
  if (cachedCurr && cachedCurr !== 'not installed') {
    return cachedCurr;
  }
  return fromSys;
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
let versionPickerPage = 1;
let versionPickerLoading = false;
let versionPickerError: string | null = null;
let versionPickerReleases: Tachyon.ComponentRelease[] = [];
const versionPickerReleasesCache: Partial<
  Record<string, Tachyon.ComponentRelease[]>
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

  return status === 'outdated' || status === 'outdated_same_release';
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
  return store.get().diagnosticsSystemInfo.loading;
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
  releaseNotes: string = '',
  currentVersion: string = '',
) {
  const updatesChecks = store.get().updatesChecks;
  const existingCurrent = updatesChecks[component]?.current_version || '';

  store.set({
    updatesChecks: {
      ...updatesChecks,
      [component]: {
        status,
        latest_version: latestVersion,
        ...(currentVersion || existingCurrent
          ? { current_version: currentVersion || existingCurrent }
          : {}),
        release_url: releaseUrl,
        ...(releaseNotes ? { release_notes: releaseNotes } : {}),
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
        result.release_notes || '',
        result.current_version || '',
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
  return getExpectedLatestVersionHelper(button, store.get().updatesChecks);
}

async function refreshSystemInfoAfterMutation() {
  await ensureSystemInfo({ force: true, silent: true });
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
    void safeReloadPage();
  });
}

function patchSystemInfoAfterMutation(result: Tachyon.ComponentActionResult) {
  const { nextSystemInfo } = computeSystemInfoMutation(
    store.get().diagnosticsSystemInfo,
    result,
  );

  store.set({
    diagnosticsSystemInfo: nextSystemInfo,
  });
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
        result.release_notes || '',
        result.current_version || '',
      );
      modalController?.updateVersions({
        currentVersion:
          result.current_version ||
          getComponentCurrentVersion(result.component),
        targetVersion: result.latest_version || '',
        currentSha: result.current_sha || '',
        targetSha: result.latest_sha || '',
      });
    }

    const currVerForToast =
      result.current_version || getComponentCurrentVersion(result.component);
    const toastMsg = getCheckToastMessage(
      status,
      currVerForToast,
      result.latest_version || '',
    );

    if (notify) {
      showToast(toastMsg, 'success');
    }

    if (hasUpdate) {
      const installButton = getComponentInstallAction(result.component);
      modalController?.completeSuccess(toastMsg, {
        autoCloseMs: 0,
        installText: installButton.text,
        onInstall: () => {
          void handleComponentAction(installButton);
        },
      });
    } else {
      modalController?.completeSuccess(toastMsg);
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
          setActionLoading(button.key, false);
          return;
        }
        await new Promise((resolve) => setTimeout(resolve, 800));
        if (await followAlreadyRunningComponentAction(button)) {
          setActionLoading(button.key, false);
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
          setActionLoading(button.key, false);
          return;
        }
        await new Promise((resolve) => setTimeout(resolve, 800));
        if (await followAlreadyRunningComponentAction(button)) {
          setActionLoading(button.key, false);
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
      setActionLoading(button.key, false);
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

function getComponentInstallAction(
  component: Tachyon.ComponentName,
): ComponentActionButton {
  const currVer = getComponentCurrentVersion(component);
  const isInstalled = !isNotInstalled(currVer);
  const key = getComponentInstallKey(component);
  const latestVer = getLatestVersion(component);
  return getInstallAction(component, key, isInstalled, currVer, latestVer);
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
    const currVer = getComponentCurrentVersion(component);
    const latestVer = getLatestVersion(component);
    actions.push(
      getInstallAction(component, installKey, true, currVer, latestVer),
    );
  }
  return actions;
}

function getComponentBackupVersion(component: Tachyon.ComponentName): string {
  return getComponentBackupVersionHelper(
    component,
    store.get().diagnosticsSystemInfo,
  );
}

function getComponentCards(): ComponentCard[] {
  const systemInfo = store.get().diagnosticsSystemInfo;
  const systemInfoLoading = isSystemInfoLoading();
  const tachyonCoreInstalled = !isNotInstalled(systemInfo.tachyon_core_version);

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
  const normVer = (raw: string | undefined): string =>
    `${raw || ''}`.trim().replace(/^v/i, '');
  const tachyonBackup = getComponentBackupVersion('tachyon');
  if (
    tachyonBackup &&
    normVer(tachyonBackup) !== normVer(systemInfo.tachyon_version)
  ) {
    tachyonActions.push(
      getRollbackAction('tachyon', 'tachyonRollback', tachyonBackup),
    );
  }
  const tachyonCoreActions = getInstalledUpdateActions(
    'tachyon-core',
    'tachyonCoreCheck',
    'tachyonCoreInstall',
    tachyonCoreInstalled,
  );

  const tachyonCoreBackup = getComponentBackupVersion('tachyon-core');
  if (
    tachyonCoreBackup &&
    tachyonCoreInstalled &&
    normVer(tachyonCoreBackup) !== normVer(systemInfo.tachyon_core_version)
  ) {
    tachyonCoreActions.push(
      getRollbackAction(
        'tachyon-core',
        'tachyonCoreRollback',
        tachyonCoreBackup,
      ),
    );
  }

  const cachedVersionOrLoading = (component: Tachyon.ComponentName) => {
    const check = getVisibleCheckResult(component);
    if (check?.current_version && check.current_version !== 'not installed') {
      return check.current_version;
    }
    return _('Loading...');
  };

  const cards: ComponentCard[] = [
    {
      component: 'tachyon',
      column: 0,
      title: 'Tachyon',
      version: systemInfoLoading
        ? cachedVersionOrLoading('tachyon')
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
      component: 'tachyon-core',
      column: 0,
      title: 'Tachyon Core',
      version: systemInfoLoading
        ? cachedVersionOrLoading('tachyon-core')
        : formatCoreVersion(systemInfo.tachyon_core_version),
      latestVersion: getLatestVersion('tachyon-core'),
      releaseUrl: getGitHubReleaseUrl('tachyon-core'),
      repoUrl:
        systemInfo.tachyon_core_repo_url || COMPONENT_REPO_URLS['tachyon-core'],
      actions: tachyonCoreActions,
      supportsVersions: true,
    },
  ];

  return cards;
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
  versionPickerPage = 1;
  await loadVersionPickerReleases(component, 1);
}

async function loadVersionPickerReleases(
  component: Tachyon.ComponentName,
  page: number,
) {
  const cacheKey = `${component}:${page}`;
  versionPickerError = null;
  versionPickerPage = page;

  if (versionPickerReleasesCache[cacheKey]) {
    versionPickerReleases = versionPickerReleasesCache[cacheKey]!;
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
      page,
    );

    if (
      activeVersionPickerComponent !== component ||
      versionPickerPage !== page
    ) {
      return;
    }

    if (!response.success) {
      versionPickerError = response.error || _('No versions found');
      versionPickerReleases = [];
    } else if (!response.data || response.data.length === 0) {
      versionPickerError =
        page > 1 ? _('No more versions found') : _('No versions found');
      versionPickerReleases = [];
    } else {
      versionPickerReleases = response.data;
      versionPickerReleasesCache[cacheKey] = response.data;
      versionPickerError = null;
    }
  } catch (_error) {
    if (
      activeVersionPickerComponent !== component ||
      versionPickerPage !== page
    ) {
      return;
    }
    versionPickerError = _('Failed to load versions');
    versionPickerReleases = [];
  } finally {
    if (
      activeVersionPickerComponent === component &&
      versionPickerPage === page
    ) {
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

function renderInlineReleaseMarkdown(text: string): Node[] {
  const nodes: Node[] = [];
  const tokenRegex =
    /(\*\*([^*]+)\*\*|`([^`]+)`|\[([^\]]+)\]\((https?:\/\/[^\s)]+)\))/g;
  let lastIndex = 0;
  let match: RegExpExecArray | null;

  while ((match = tokenRegex.exec(text)) !== null) {
    if (match.index > lastIndex) {
      nodes.push(document.createTextNode(text.slice(lastIndex, match.index)));
    }
    if (match[2] !== undefined) {
      nodes.push(E('strong', {}, match[2]));
    } else if (match[3] !== undefined) {
      nodes.push(
        E(
          'code',
          {
            style:
              'padding: 1px 5px; border-radius: 4px; background: rgba(128,128,128,0.16); font-family: monospace; font-size: 0.92em;',
          },
          match[3],
        ),
      );
    } else if (match[4] !== undefined && match[5] !== undefined) {
      nodes.push(
        E(
          'a',
          {
            href: match[5],
            target: '_blank',
            rel: 'noopener noreferrer',
          },
          match[4],
        ),
      );
    }
    lastIndex = tokenRegex.lastIndex;
  }

  if (lastIndex < text.length) {
    nodes.push(document.createTextNode(text.slice(lastIndex)));
  }

  return nodes.length > 0 ? nodes : [document.createTextNode(text)];
}

function renderFormattedReleaseNotes(container: HTMLElement, rawText: string) {
  container.innerHTML = '';
  const normalized = String(rawText || '')
    .replace(/\r\n/g, '\n')
    .trim();
  if (!normalized) {
    container.appendChild(
      E(
        'div',
        { style: 'opacity: 0.75;' },
        _('No release description available.'),
      ),
    );
    return;
  }

  const lines = normalized.split('\n');
  let listItems: HTMLElement[] = [];
  let inCodeBlock = false;
  let codeLines: string[] = [];

  const flushList = () => {
    if (listItems.length > 0) {
      container.appendChild(
        E(
          'ul',
          {
            style:
              'margin: 4px 0 10px 18px; padding: 0; display: flex; flex-direction: column; gap: 4px;',
          },
          listItems,
        ),
      );
      listItems = [];
    }
  };

  const flushCodeBlock = () => {
    if (codeLines.length > 0) {
      container.appendChild(
        E(
          'pre',
          {
            style:
              'margin: 6px 0 10px; padding: 8px 10px; border-radius: 6px; background: rgba(0,0,0,0.2); overflow-x: auto; font-family: monospace; font-size: 12px; white-space: pre-wrap; word-break: break-word;',
          },
          codeLines.join('\n'),
        ),
      );
      codeLines = [];
    }
  };

  for (const rawLine of lines) {
    const trimmed = rawLine.trim();

    if (trimmed.startsWith('```')) {
      flushList();
      if (inCodeBlock) {
        flushCodeBlock();
        inCodeBlock = false;
      } else {
        inCodeBlock = true;
      }
      continue;
    }

    if (inCodeBlock) {
      codeLines.push(rawLine);
      continue;
    }

    if (!trimmed) {
      flushList();
      continue;
    }

    if (/^(-{3,}|\*{3,})$/.test(trimmed)) {
      flushList();
      container.appendChild(
        E('hr', {
          style:
            'border: none; border-top: 1px solid rgba(128,128,128,0.25); margin: 8px 0;',
        }),
      );
      continue;
    }

    const headingMatch = trimmed.match(/^(#{1,4})\s+(.+)$/);
    if (headingMatch) {
      flushList();
      const level = headingMatch[1]!.length;
      const fontSize = level === 1 ? '15px' : level === 2 ? '14px' : '13px';
      container.appendChild(
        E(
          'div',
          {
            style: `font-weight: 600; font-size: ${fontSize}; margin: 10px 0 4px;`,
          },
          renderInlineReleaseMarkdown(headingMatch[2]!),
        ),
      );
      continue;
    }

    const bulletMatch = trimmed.match(/^(?:[-*•]|\d+\.)\s+(.+)$/);
    if (bulletMatch) {
      listItems.push(
        E(
          'li',
          { style: 'line-height: 1.45;' },
          renderInlineReleaseMarkdown(bulletMatch[1]!),
        ) as HTMLElement,
      );
      continue;
    }

    flushList();
    container.appendChild(
      E(
        'div',
        { style: 'margin: 4px 0; line-height: 1.45;' },
        renderInlineReleaseMarkdown(trimmed),
      ),
    );
  }

  flushList();
  flushCodeBlock();
}

async function openReleaseNotesModal(opts: {
  component: Tachyon.ComponentName;
  title: string;
  version?: string;
  notes?: string;
  releaseUrl?: string;
}) {
  let currentNotes = (opts.notes || '').trim();
  const isTruncatedNotes = currentNotes.endsWith('\n...');
  let currentVersion = (opts.version || '').trim();

  const versionBadgeEl = E(
    'span',
    { class: 'tachyon-update-modal__version-badge' },
    currentVersion || _('Latest release'),
  );

  const headerEl = E('div', { class: 'tachyon-update-modal__header' }, [
    E('div', { class: 'tachyon-update-modal__header-info' }, [
      E('b', { class: 'tachyon-update-modal__component-name' }, opts.title),
      versionBadgeEl,
    ]),
  ]);

  const notesContainerEl = E(
    'div',
    {
      class: 'tachyon-update-modal__log',
      style:
        'white-space: normal; word-break: break-word; font-family: inherit; font-size: 13px; line-height: 1.45; max-height: 60vh; overflow-y: auto; padding: 12px 14px;',
    },
    [],
  ) as HTMLElement;

  if (currentNotes && !isTruncatedNotes) {
    renderFormattedReleaseNotes(notesContainerEl, currentNotes);
  } else {
    notesContainerEl.textContent = _('Loading release description...');
  }

  const logPanelEl = E('div', { class: 'tachyon-update-modal__log-panel' }, [
    E('div', { class: 'tachyon-update-modal__log-header' }, [
      E('b', {}, _("What's new?")),
      renderButton({
        classNames: ['cbi-button-action', 'tachyon-update-modal__log-copy'],
        text: _('Copy'),
        onClick: () =>
          copyToClipboard(currentNotes || notesContainerEl.textContent || ''),
      }),
    ]),
    notesContainerEl,
  ]);

  const actionsContainer = E(
    'div',
    {
      class: 'tachyon-update-modal__actions',
      style:
        'display: flex; gap: 8px; justify-content: flex-end; flex-wrap: wrap;',
    },
    [
      renderButton({
        classNames: ['cbi-button-neutral'],
        text: _('Close'),
        icon: renderXIcon24,
        onClick: () => ui.hideModal(),
      }),
    ],
  ) as HTMLElement;

  const modalBodyEl = E('div', { class: 'tachyon-update-modal__body' }, [
    headerEl,
    logPanelEl,
    actionsContainer,
  ]) as HTMLElement;

  ui.showModal(`${_("What's new?")}: ${opts.title}`, modalBodyEl);

  if (!currentNotes || isTruncatedNotes) {
    try {
      const matched = await getReleaseForNotes(opts.component, currentVersion);
      currentNotes = matched?.body?.trim() || currentNotes;
      if (!currentVersion && matched?.tag) {
        currentVersion = matched.tag;
        versionBadgeEl.textContent = currentVersion;
      }
      if (currentNotes) {
        renderFormattedReleaseNotes(notesContainerEl, currentNotes);
      } else {
        notesContainerEl.textContent = _('Failed to load release description.');
      }
    } catch {
      if (currentNotes) {
        renderFormattedReleaseNotes(notesContainerEl, currentNotes);
      } else {
        notesContainerEl.textContent = _('Failed to load release description.');
      }
    }
  }
}

function renderWhatsNewIconButton(opts: {
  component: Tachyon.ComponentName;
  title: string;
  version?: string;
  notes?: string;
  releaseUrl?: string;
}): HTMLElement {
  return E(
    'button',
    {
      type: 'button',
      class: 'tachyon_updates-page__component__repo-link',
      title: _("What's new?"),
      'aria-label': _("What's new?"),
      click: (e: Event) => {
        e.preventDefault();
        void openReleaseNotesModal(opts);
      },
    },
    renderFileTextIcon14(),
  ) as HTMLElement;
}

function formatReleasePublishedDate(published?: string): string {
  const raw = String(published || '').trim();
  if (!raw) return '';
  const match = raw.match(/^(\d{4}-\d{2}-\d{2})/);
  return match ? match[1]! : raw;
}

const customVersionInputValues: Partial<Record<Tachyon.ComponentName, string>> =
  {};

function renderVersionPickerDropdown(
  component: Tachyon.ComponentName,
): HTMLElement {
  const container = E('div', { class: 'tachyon-version-picker' });

  // Custom version manual tag input row
  const customInput = E('input', {
    type: 'text',
    class: 'cbi-input-text tachyon-version-picker__custom-input',
    placeholder: _('Custom tag (e.g. v1.2.3)'),
    id: `tachyon-version-picker-custom-${component}`,
    value: customVersionInputValues[component] || '',
  }) as HTMLInputElement;
  customInput.value = customVersionInputValues[component] || '';
  customInput.addEventListener('input', () => {
    customVersionInputValues[component] = customInput.value;
  });

  const customInstallBtn = renderButton({
    text: _('Install'),
    loading: false,
    disabled: isAnyActionLoading(),
    onClick: () => {
      const tag = customInput.value?.trim();
      if (tag) {
        void handleInstallVersion(component, tag);
      }
    },
  });

  customInput.addEventListener('keydown', (e: KeyboardEvent) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      const tag = customInput.value?.trim();
      if (tag) {
        void handleInstallVersion(component, tag);
      }
    }
  });

  const customRow = E('div', { class: 'tachyon-version-picker__custom' }, [
    customInput,
    customInstallBtn,
  ]);
  container.appendChild(customRow);

  if (versionPickerLoading) {
    container.appendChild(
      E(
        'div',
        { class: 'tachyon-version-picker__loading' },
        _('Loading versions...'),
      ),
    );
  } else if (versionPickerError) {
    container.appendChild(
      E('div', { class: 'tachyon-version-picker__error' }, versionPickerError),
    );
  } else if (versionPickerReleases.length === 0) {
    container.appendChild(
      E(
        'div',
        { class: 'tachyon-version-picker__empty' },
        _('No versions found'),
      ),
    );
  } else {
    const list = E('div', { class: 'tachyon-version-picker__list' });
    for (const release of versionPickerReleases) {
      const children: Node[] = [
        E('span', { class: 'tachyon-version-picker__tag' }, release.tag),
      ];
      if (release.published) {
        children.push(
          E(
            'span',
            {
              class: 'tachyon-version-picker__date',
              title: release.published,
            },
            formatReleasePublishedDate(release.published),
          ),
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
        E('span', { class: 'tachyon-version-picker__actions' }, [
          renderWhatsNewIconButton({
            component,
            title: getComponentCardTitle(component),
            version: release.tag,
            notes: release.body,
            releaseUrl: release.release_url,
          }),
          renderButton({
            text: _('Install'),
            loading: false,
            disabled: isAnyActionLoading(),
            onClick: () => void handleInstallVersion(component, release.tag),
          }),
        ]),
      );
      list.appendChild(
        E('div', { class: 'tachyon-version-picker__item' }, children),
      );
    }
    container.appendChild(list);
  }

  // Pagination bar
  const hasReleasesOrNext = versionPickerReleases.length >= 5;
  const paginationRow = E(
    'div',
    { class: 'tachyon-version-picker__pagination' },
    [
      renderButton({
        text: '← ' + _('Previous'),
        loading: false,
        disabled: versionPickerLoading || versionPickerPage <= 1,
        onClick: () => {
          if (versionPickerPage > 1) {
            void loadVersionPickerReleases(component, versionPickerPage - 1);
          }
        },
      }),
      E(
        'span',
        { class: 'tachyon-version-picker__page-num' },
        `${_('Page')} ${versionPickerPage}`,
      ),
      renderButton({
        text: _('Next') + ' →',
        loading: false,
        disabled: versionPickerLoading || !hasReleasesOrNext,
        onClick: () => {
          void loadVersionPickerReleases(component, versionPickerPage + 1);
        },
      }),
    ],
  );
  container.appendChild(paginationRow);

  return container;
}

function renderComponentCard(card: ComponentCard) {
  const updatesActions = store.get().updatesActions;
  const anyActionLoading = isAnyActionLoading();
  const systemInfoLoading = isSystemInfoLoading();

  const checkResult = getVisibleCheckResult(card.component);
  const canShowWhatsNew = Boolean(card.supportsVersions || card.repoUrl);

  const headerMainChildren: Node[] = [
    E('b', { class: 'tachyon_updates-page__component__title' }, card.title),
  ];
  if (card.badgeNode) {
    headerMainChildren.push(card.badgeNode);
  }
  headerMainChildren.push(
    E(
      'span',
      {
        class: 'tachyon_updates-page__component__header-version',
        title: card.version,
      },
      card.version,
    ),
  );

  const headerToolsChildren: Node[] = [];
  if (card.repoUrl) {
    headerToolsChildren.push(
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
  if (canShowWhatsNew) {
    headerToolsChildren.push(
      renderWhatsNewIconButton({
        component: card.component,
        title: card.title,
        version:
          checkResult?.latest_version || card.latestVersion || card.version,
        notes: checkResult?.release_notes,
        releaseUrl: checkResult?.release_url,
      }),
    );
  }

  const headerChildren: Node[] = [
    E(
      'div',
      { class: 'tachyon_updates-page__component__header-main' },
      headerMainChildren,
    ),
  ];
  if (headerToolsChildren.length > 0) {
    headerChildren.push(
      E(
        'div',
        { class: 'tachyon_updates-page__component__header-tools' },
        headerToolsChildren,
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
      const rawCurrent =
        checkResult.current_version ||
        getComponentCurrentVersion(card.component) ||
        card.version;
      const cleanCurrent =
        rawCurrent &&
        rawCurrent !== 'not installed' &&
        rawCurrent !== _('Not installed') &&
        rawCurrent !== _('Loading...')
          ? rawCurrent
          : '';
      const transitionLabel =
        cleanCurrent && versionToShow && cleanCurrent !== versionToShow
          ? `${cleanCurrent} → ${versionToShow}`
          : versionToShow || _("What's new?");

      if (versionToShow || checkResult.release_url) {
        latestValueNodes.push(
          E(
            'a',
            {
              class: 'tachyon_updates-page__component__release-version-link',
              href: '#',
              click: (e: Event) => {
                e.preventDefault();
                void openReleaseNotesModal({
                  component: card.component,
                  title: card.title,
                  version: versionToShow,
                  notes: checkResult.release_notes,
                  releaseUrl: checkResult.release_url,
                });
              },
            },
            transitionLabel,
          ),
        );
      }
    } else if (checkResult.status === 'outdated_same_release') {
      labelText = _('Update is available for current release');
      // Show short commit SHAs so user understands it's the same version, different build
      const build = describeSameReleaseBuild({
        currentSha: checkResult.current_sha,
        latestSha: checkResult.latest_sha,
      });
      const sameVer =
        checkResult.latest_version ||
        checkResult.current_version ||
        getComponentCurrentVersion(card.component) ||
        '';
      const buildLabel =
        build.kind === 'sha' ? build.text : _('Rebuilt release');
      latestValueNodes.push(
        E(
          'span',
          {
            class: 'tachyon_updates-page__component__sha-info',
            title: _('Installed build → Available build'),
          },
          sameVer ? `${sameVer} (${buildLabel})` : buildLabel,
        ),
      );
    } else if (checkResult.status === 'latest') {
      labelText = _('Latest version is installed');
    } else if (checkResult.status === 'dev') {
      labelText = _('Installed version is newer than release');
      const versionToShow = checkResult.latest_version || card.latestVersion;

      if (versionToShow || checkResult.release_url) {
        latestValueNodes.push(
          E(
            'a',
            {
              class: 'tachyon_updates-page__component__release-version-link',
              href: '#',
              click: (e: Event) => {
                e.preventDefault();
                void openReleaseNotesModal({
                  component: card.component,
                  title: card.title,
                  version: versionToShow,
                  notes: checkResult.release_notes,
                  releaseUrl: checkResult.release_url,
                });
              },
            },
            versionToShow || _("What's new?"),
          ),
        );
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
              style:
                'display: inline-flex; align-items: center; gap: 8px; flex-wrap: wrap;',
            },
            latestValueNodes,
          ),
        );
      }

      const rowStatusMod =
        checkResult.status === 'outdated' ||
        checkResult.status === 'outdated_same_release'
          ? ' tachyon_updates-page__component__info-row--outdated'
          : checkResult.status === 'latest'
            ? ' tachyon_updates-page__component__info-row--latest'
            : '';

      detailsChildren.push(
        E(
          'div',
          {
            class: `tachyon_updates-page__component__info-row${rowStatusMod}`,
          },
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

  const mainRowButtons: Node[] = [...primaryButtons, ...dangerButtons];

  if (card.copyValue) {
    mainRowButtons.push(
      renderButton({
        text: _('Copy address'),
        icon: renderCopyIcon24,
        disabled: anyActionLoading,
        onClick: () => copyToClipboard(card.copyValue || ''),
      }),
    );
  }

  const isPickerOpen =
    card.supportsVersions && activeVersionPickerComponent === card.component;
  if (card.supportsVersions) {
    mainRowButtons.push(
      renderButton({
        text: isPickerOpen ? _('Hide versions') : _('Versions'),
        loading: isPickerOpen && versionPickerLoading,
        disabled: systemInfoLoading || anyActionLoading,
        onClick: () => void toggleVersionPicker(card.component),
      }),
    );
  }

  if (mainRowButtons.length > 0) {
    actionElements.push(
      E(
        'div',
        { class: 'tachyon_updates-page__component__actions-main' },
        mainRowButtons,
      ),
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

  if (isPickerOpen) {
    actionElements.push(renderVersionPickerDropdown(card.component));
  }

  const actionsContainer = E(
    'div',
    {
      class: 'tachyon_updates-page__component__actions',
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
  if (component === 'tachyon' || component === 'tachyon-core') {
    return true;
  }

  const optKey = `show_component_${component}`;
  const val = systemInfo[optKey];
  if (val === undefined || val === null || val === '') {
    return true;
  }
  return String(val) === '1' || val === 1;
}

function renderUpdatesComponents() {
  const container = document.getElementById('tachyon_updates-components');

  if (!container) {
    return;
  }

  const systemInfo = store.get().diagnosticsSystemInfo;

  const visibleCards = getComponentCards().filter((card) =>
    isComponentCardVisible(card, systemInfo),
  );

  const allCards = visibleCards.map((card) => renderComponentCard(card));

  return preserveScrollForPage(() => {
    const activeEl =
      typeof document !== 'undefined' &&
      document.activeElement instanceof HTMLElement &&
      container.contains(document.activeElement)
        ? document.activeElement
        : null;
    const activeId = activeEl?.id || '';
    const selectionStart =
      activeEl instanceof HTMLInputElement ? activeEl.selectionStart : null;
    const selectionEnd =
      activeEl instanceof HTMLInputElement ? activeEl.selectionEnd : null;

    container.replaceChildren(...allCards);

    if (activeId) {
      const nextFocusEl = document.getElementById(activeId);
      if (nextFocusEl instanceof HTMLElement) {
        nextFocusEl.focus({ preventScroll: true });
        if (
          nextFocusEl instanceof HTMLInputElement &&
          selectionStart !== null &&
          selectionEnd !== null
        ) {
          try {
            nextFocusEl.setSelectionRange(selectionStart, selectionEnd);
          } catch {
            // ignore unsupported input types
          }
        }
      }
    }
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

  store.subscribe(onStoreUpdate);
  startComponentActionStateWatcher();
  void ensureSystemInfo();
  renderUpdatesComponents();

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

  renderUpdatesComponents();
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
