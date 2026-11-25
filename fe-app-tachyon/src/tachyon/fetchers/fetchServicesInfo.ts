import { TachyonShellMethods } from '../methods';
import { logger } from '../services/logger.service';
import { store } from '../services/store.service';
import { refreshRuntimeUiState } from '../services/runtimeUiState.service';
import { Tachyon } from '../types';

let latestServicesInfoRequestId = 0;

function getSettledMethodResponse<T>(
  scope: string,
  result: PromiseSettledResult<Tachyon.MethodResponse<T>>,
): Tachyon.MethodResponse<T> {
  if (result.status === 'fulfilled') {
    return result.value;
  }

  logger.error('[SERVICES_INFO]', `${scope} failed`, result.reason);

  return {
    success: false,
    error: result.reason instanceof Error ? result.reason.message : '',
  };
}

export async function fetchServicesInfo() {
  const requestId = ++latestServicesInfoRequestId;
  const uiState = await refreshRuntimeUiState({ force: true });

  if (requestId !== latestServicesInfoRequestId) {
    return;
  }

  if (uiState) {
    return uiState;
  }

  const [tachyonResult, coreResult, watchdogResult] = await Promise.allSettled([
    TachyonShellMethods.getStatus(),
    TachyonShellMethods.getTachyonCoreStatus(),
    TachyonShellMethods.getWatchdogStatus(),
  ]);

  if (requestId !== latestServicesInfoRequestId) {
    return;
  }

  const tachyon = getSettledMethodResponse('getStatus', tachyonResult);
  const core = getSettledMethodResponse('getTachyonCoreStatus', coreResult);
  const watchdog = getSettledMethodResponse(
    'getWatchdogStatus',
    watchdogResult,
  );

  const coreFailed = !core.success;

  const previousData = store.get().servicesInfoWidget.data;

  store.set({
    servicesInfoWidget: {
      loading: false,
      failed: !tachyon.success || coreFailed,
      data: {
        tachyonCore: core.success
          ? core.data.running
          : previousData.tachyonCore,
        tachyonCoreMemoryMb: core.success
          ? core.data.memory_rss_mb
          : previousData.tachyonCoreMemoryMb,
        tachyonCorePid: core.success
          ? core.data.pid
          : previousData.tachyonCorePid,
        tachyonCoreUptimeSeconds: core.success
          ? core.data.uptime_seconds
          : previousData.tachyonCoreUptimeSeconds,
        tachyonCoreUptimePretty: core.success
          ? core.data.uptime_pretty
          : previousData.tachyonCoreUptimePretty,
        engineVersion: core.success
          ? core.data.engine_version
          : previousData.engineVersion,
        tachyonRunning: tachyon.success
          ? tachyon.data.running
          : previousData.tachyonRunning,
        tachyonEnabled: tachyon.success
          ? tachyon.data.enabled
          : previousData.tachyonEnabled,
        tachyonStatus: tachyon.success
          ? tachyon.data.status
          : previousData.tachyonStatus,
        liteMode:
          tachyon.success && tachyon.data.lite_mode != null
            ? tachyon.data.lite_mode
            : previousData.liteMode,
        tachyonMemoryMb: tachyon.success
          ? tachyon.data.memory_rss_mb
          : previousData.tachyonMemoryMb,
        tachyonPid: tachyon.success
          ? tachyon.data.pid
          : previousData.tachyonPid,
        tachyonUptimeSeconds: tachyon.success
          ? tachyon.data.uptime_seconds
          : previousData.tachyonUptimeSeconds,
        tachyonUptimePretty: tachyon.success
          ? tachyon.data.uptime_pretty
          : previousData.tachyonUptimePretty,
        watchdogRunning: watchdog.success
          ? Number((watchdog.data as { running: boolean }).running)
          : previousData.watchdogRunning,
        dnsmasqRunning: previousData.dnsmasqRunning,
        dnsmasqMemoryMb: previousData.dnsmasqMemoryMb,
        dnsmasqLocalCacheEnabled: previousData.dnsmasqLocalCacheEnabled,
        dnsmasqCacheSize: previousData.dnsmasqCacheSize,
        dnsmasqPid: previousData.dnsmasqPid,
        dnsmasqUptimeSeconds: previousData.dnsmasqUptimeSeconds,
        dnsmasqUptimePretty: previousData.dnsmasqUptimePretty,
        platformInfo:
          (tachyon.success && tachyon.data.platform_info) ||
          previousData.platformInfo,
      },
    },
  });

  return undefined;
}
