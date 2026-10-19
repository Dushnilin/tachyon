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

  const [tachyonResult, singboxResult, watchdogResult, engineResult] =
    await Promise.allSettled([
      TachyonShellMethods.getStatus(),
      TachyonShellMethods.getSingBoxStatus(),
      TachyonShellMethods.getWatchdogStatus(),
      TachyonShellMethods.getEngineStatus(),
    ]);

  if (requestId !== latestServicesInfoRequestId) {
    return;
  }

  const tachyon = getSettledMethodResponse('getStatus', tachyonResult);
  const singbox = getSettledMethodResponse('getSingBoxStatus', singboxResult);
  const watchdog = getSettledMethodResponse(
    'getWatchdogStatus',
    watchdogResult,
  );
  const engineStatus = getSettledMethodResponse(
    'getEngineStatus',
    engineResult,
  );

  // On steer the sing-box service is intentionally stopped. Don't mark the
  // dashboard as failed just because S99sing-box is absent, and report the
  // active engine's own liveness in the singbox slot so the widget shows the
  // routing engine that actually runs.
  const activeEngine =
    engineStatus.success &&
    (engineStatus.data as Tachyon.GetEngineStatus).engine
      ? (engineStatus.data as Tachyon.GetEngineStatus).engine
      : 'sing-box';
  const isSteer = activeEngine === 'steer' || activeEngine === 'steer-extended';
  const singboxFailed = !singbox.success && !isSteer;

  const previousData = store.get().servicesInfoWidget.data;

  store.set({
    servicesInfoWidget: {
      loading: false,
      failed: !tachyon.success || singboxFailed,
      data: {
        singbox: singbox.success
          ? singbox.data.running
          : isSteer && engineStatus.success
            ? 1
            : previousData.singbox,
        singboxMemoryMb: singbox.success
          ? singbox.data.memory_rss_mb
          : previousData.singboxMemoryMb,
        singboxPid: singbox.success
          ? singbox.data.pid
          : previousData.singboxPid,
        singboxUptimeSeconds: singbox.success
          ? singbox.data.uptime_seconds
          : previousData.singboxUptimeSeconds,
        singboxUptimePretty: singbox.success
          ? singbox.data.uptime_pretty
          : previousData.singboxUptimePretty,
        engineVariant: singbox.success
          ? singbox.data.engine_variant
          : previousData.engineVariant,
        engineVersion: singbox.success
          ? singbox.data.engine_version
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
        zapret2Running: previousData.zapret2Running,
        zapret2MemoryMb: previousData.zapret2MemoryMb,
        zapret2Pid: previousData.zapret2Pid,
        zapret2UptimeSeconds: previousData.zapret2UptimeSeconds,
        zapret2UptimePretty: previousData.zapret2UptimePretty,
        dnsmasqRunning: previousData.dnsmasqRunning,
        dnsmasqMemoryMb: previousData.dnsmasqMemoryMb,
        dnsmasqLocalCacheEnabled: previousData.dnsmasqLocalCacheEnabled,
        dnsmasqCacheSize: previousData.dnsmasqCacheSize,
        dnsmasqPid: previousData.dnsmasqPid,
        dnsmasqUptimeSeconds: previousData.dnsmasqUptimeSeconds,
        dnsmasqUptimePretty: previousData.dnsmasqUptimePretty,
      },
    },
    activeEngine,
  });

  return undefined;
}
