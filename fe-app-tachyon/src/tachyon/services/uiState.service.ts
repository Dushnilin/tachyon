import { getComponentActionKey } from '../helpers/getComponentActionKey';
import {
  getSubscriptionJobTargetSelector,
  getSubscriptionUpdateTargetKey,
} from '../helpers/subscriptionUpdating';
import type { Tachyon } from '../types';
import { getLocalActionOverlay } from './localActionOverlay.service';
import { store } from './store.service';
import type { StoreType } from './store.service';

type UiActionMap = Partial<Tachyon.UiState['actions']>;

function isRunningAction(state: { running?: boolean }) {
  return state.running === true;
}

function getEmptyUpdatesActions(): StoreType['updatesActions'] {
  return {
    tachyonCheck: { loading: false },
    tachyonInstall: { loading: false },
    tachyonReinstall: { loading: false },
    tachyonRollback: { loading: false },
    tachyonCoreCheck: { loading: false },
    tachyonCoreInstall: { loading: false },
    tachyonCoreRollback: { loading: false },
    directBypassEnable: { loading: false },
    directBypassDisable: { loading: false },
    torrserverDirectCheck: { loading: false },
    torrserverDirectInstall: { loading: false },
    torrserverDirectRemove: { loading: false },
    torrserverDirectEnable: { loading: false },
    torrserverDirectDisable: { loading: false },
  };
}

function getEmptyDiagnosticsActions(): StoreType['diagnosticsActions'] {
  return {
    ...store.get().diagnosticsActions,
    restart: { loading: false },
    start: { loading: false },
    stop: { loading: false },
  };
}

function normalizeLatencyProgress(
  progress?: Tachyon.LatencyActionProgress,
): Tachyon.LatencyActionProgress | undefined {
  const total = Math.trunc(Number(progress?.total ?? 0));

  if (!Number.isFinite(total) || total <= 0) {
    return undefined;
  }

  const completedValue = Number(progress?.completed ?? 0);
  const failedValue = Number(progress?.failed ?? 0);
  const completed = Number.isFinite(completedValue)
    ? Math.trunc(completedValue)
    : 0;
  const failed = Number.isFinite(failedValue) ? Math.trunc(failedValue) : 0;

  return {
    completed: Math.min(Math.max(0, completed), total),
    total,
    failed: Math.max(0, failed),
  };
}

function applyServiceState(uiState: Tachyon.UiState) {
  const currentSystemInfo = store.get().diagnosticsSystemInfo;
  const nextSystemInfo = {
    ...currentSystemInfo,
    providerInfoLoaded: true,
    server_inbounds_enabled_count:
      uiState.capabilities.server_inbounds_enabled_count,
  };

  nextSystemInfo.tachyon_core_fptn = uiState.capabilities.tachyon_core_fptn;
  nextSystemInfo.tachyon_core_tailscale =
    uiState.capabilities.tachyon_core_tailscale;
  nextSystemInfo.tachyon_core_cert_pin =
    uiState.capabilities.tachyon_core_cert_pin ?? 0;

  store.set({
    servicesInfoWidget: {
      loading: false,
      failed: false,
      data: {
        tachyonCore: uiState.service.tachyon_core.running,
        tachyonCoreMemoryMb: uiState.service.tachyon_core.memory_rss_mb,
        tachyonCorePid: uiState.service.tachyon_core.pid,
        tachyonCoreUptimeSeconds: uiState.service.tachyon_core.uptime_seconds,
        tachyonCoreUptimePretty: uiState.service.tachyon_core.uptime_pretty,
        engineVersion: uiState.service.tachyon_core.engine_version,
        tachyonRunning: uiState.service.tachyon.running,
        tachyonEnabled: uiState.service.tachyon.enabled,
        tachyonStatus: uiState.service.tachyon.status,
        liteMode: uiState.service.tachyon.lite_mode,
        tachyonMemoryMb: uiState.service.tachyon.memory_rss_mb,
        tachyonPid: uiState.service.tachyon.pid,
        tachyonUptimeSeconds: uiState.service.tachyon.uptime_seconds,
        tachyonUptimePretty: uiState.service.tachyon.uptime_pretty,
        cpuLoadPercent: uiState.service.tachyon.cpu_load_percent,
        cpuTempC: uiState.service.tachyon.cpu_temp_c,
        watchdogRunning:
          uiState.service.watchdog?.running ??
          store.get().servicesInfoWidget.data.watchdogRunning,
        dnsmasqRunning: uiState.service.dnsmasq
          ? uiState.service.dnsmasq.running
          : undefined,
        dnsmasqMemoryMb: uiState.service.dnsmasq
          ? uiState.service.dnsmasq.memory_rss_mb
          : undefined,
        dnsmasqLocalCacheEnabled: uiState.service.dnsmasq
          ? uiState.service.dnsmasq.local_cache_enabled
          : undefined,
        dnsmasqCacheSize: uiState.service.dnsmasq
          ? uiState.service.dnsmasq.cache_size
          : undefined,
        dnsmasqPid: uiState.service.dnsmasq?.pid,
        dnsmasqUptimeSeconds: uiState.service.dnsmasq?.uptime_seconds,
        dnsmasqUptimePretty: uiState.service.dnsmasq?.uptime_pretty,
      },
    },
    diagnosticsSystemInfo: nextSystemInfo,
    activeEngine: uiState.active_engine || 'tachyon-core',
  });
}

function applyActionState(actions: UiActionMap = {}) {
  const current = store.get();
  const localOverlay = getLocalActionOverlay();
  const currentLatencyProgressSections =
    current.sectionsWidget.latencyProgressSections;
  const subscriptionUpdatingSections: Record<string, boolean> = {};
  const subscriptionUpdatingTargets: Record<string, boolean> = {};
  const latencyFetchingSections: Record<string, boolean> = {};
  const latencyProgressSections: Record<string, Tachyon.LatencyActionProgress> =
    {};
  const updatesActions = getEmptyUpdatesActions();
  const diagnosticsActions = getEmptyDiagnosticsActions();

  for (const state of actions.subscription || []) {
    if (isRunningAction(state) && state.section) {
      const selector = getSubscriptionJobTargetSelector(state);
      if (selector) {
        const key = getSubscriptionUpdateTargetKey(state.section, selector);
        if (key) {
          subscriptionUpdatingTargets[key] = true;
        }
        const resolvedTarget = String(state.resolved_target || '').trim();
        if (
          resolvedTarget &&
          resolvedTarget !== selector &&
          resolvedTarget.toLowerCase() !== state.section.toLowerCase()
        ) {
          const resolvedKey = getSubscriptionUpdateTargetKey(
            state.section,
            resolvedTarget,
          );
          if (resolvedKey) {
            subscriptionUpdatingTargets[resolvedKey] = true;
          }
        }
      } else {
        subscriptionUpdatingSections[state.section] = true;
      }
    }
  }

  for (const state of actions.latency || []) {
    if (isRunningAction(state) && state.section) {
      latencyFetchingSections[state.section] = true;
      const progress = normalizeLatencyProgress(state.progress);
      if (progress) {
        latencyProgressSections[state.section] = progress;
      } else if (currentLatencyProgressSections[state.section]) {
        latencyProgressSections[state.section] =
          currentLatencyProgressSections[state.section];
      }
    }
  }

  for (const state of actions.component || []) {
    if (!isRunningAction(state)) {
      continue;
    }

    const key = getComponentActionKey(state.component, state.action);
    if (key) {
      updatesActions[key] = { loading: true };
    }
  }

  for (const state of actions.service || []) {
    if (!isRunningAction(state)) {
      continue;
    }

    if (state.action === 'start') {
      diagnosticsActions.start = { loading: true };
    } else if (state.action === 'stop') {
      diagnosticsActions.stop = { loading: true };
    } else if (state.action === 'restart' || state.action === 'reload') {
      diagnosticsActions.restart = { loading: true };
    }
  }

  for (const section of localOverlay.subscriptionSections) {
    subscriptionUpdatingSections[section] = true;
  }

  for (const targetKey of localOverlay.subscriptionTargets) {
    subscriptionUpdatingTargets[targetKey] = true;
  }

  for (const section of localOverlay.latencySections) {
    latencyFetchingSections[section] = true;
    if (
      !latencyProgressSections[section] &&
      currentLatencyProgressSections[section]
    ) {
      latencyProgressSections[section] =
        currentLatencyProgressSections[section];
    }
  }

  for (const key of localOverlay.componentActions) {
    updatesActions[key] = { loading: true };
  }

  for (const action of localOverlay.serviceActions) {
    diagnosticsActions[action] = { loading: true };
  }

  const prevSw = current.sectionsWidget;
  const sectionsWidgetChanged =
    JSON.stringify(prevSw.subscriptionUpdatingSections) !==
      JSON.stringify(subscriptionUpdatingSections) ||
    JSON.stringify(prevSw.subscriptionUpdatingTargets) !==
      JSON.stringify(subscriptionUpdatingTargets) ||
    JSON.stringify(prevSw.latencyFetchingSections) !==
      JSON.stringify(latencyFetchingSections) ||
    JSON.stringify(prevSw.latencyProgressSections) !==
      JSON.stringify(latencyProgressSections);

  store.set({
    sectionsWidget: sectionsWidgetChanged
      ? {
          ...prevSw,
          subscriptionUpdatingSections,
          subscriptionUpdatingTargets,
          latencyFetchingSections,
          latencyProgressSections,
        }
      : prevSw,
    updatesActions,
    diagnosticsActions,
  });
}

export function applyUiStateToStore(uiState: Tachyon.UiState) {
  applyServiceState(uiState);
  applyActionState(uiState.actions);
}
