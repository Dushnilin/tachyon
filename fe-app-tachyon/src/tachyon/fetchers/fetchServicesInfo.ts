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

  const [tachyonResult, singboxResult] = await Promise.allSettled([
    TachyonShellMethods.getStatus(),
    TachyonShellMethods.getSingBoxStatus(),
  ]);

  if (requestId !== latestServicesInfoRequestId) {
    return;
  }

  const tachyon = getSettledMethodResponse('getStatus', tachyonResult);
  const singbox = getSettledMethodResponse('getSingBoxStatus', singboxResult);
  const previousData = store.get().servicesInfoWidget.data;

  store.set({
    servicesInfoWidget: {
      loading: false,
      failed: !tachyon.success || !singbox.success,
      data: {
        singbox: singbox.success ? singbox.data.running : previousData.singbox,
        tachyonRunning: tachyon.success
          ? tachyon.data.running
          : previousData.tachyonRunning,
        tachyonEnabled: tachyon.success
          ? tachyon.data.enabled
          : previousData.tachyonEnabled,
        tachyonStatus: tachyon.success
          ? tachyon.data.status
          : previousData.tachyonStatus,
      },
    },
  });

  return undefined;
}
