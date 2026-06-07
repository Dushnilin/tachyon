import { PodkopShellMethods } from '../methods';
import { logger } from '../services/logger.service';
import { store } from '../services/store.service';
import { refreshRuntimeUiState } from '../services/runtimeUiState.service';
import { Podkop } from '../types';

let latestServicesInfoRequestId = 0;

function getSettledMethodResponse<T>(
  scope: string,
  result: PromiseSettledResult<Podkop.MethodResponse<T>>,
): Podkop.MethodResponse<T> {
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

  const [podkopResult, singboxResult] = await Promise.allSettled([
    PodkopShellMethods.getStatus(),
    PodkopShellMethods.getSingBoxStatus(),
  ]);

  if (requestId !== latestServicesInfoRequestId) {
    return;
  }

  const podkop = getSettledMethodResponse('getStatus', podkopResult);
  const singbox = getSettledMethodResponse('getSingBoxStatus', singboxResult);
  const previousData = store.get().servicesInfoWidget.data;

  store.set({
    servicesInfoWidget: {
      loading: false,
      failed: !podkop.success || !singbox.success,
      data: {
        singbox: singbox.success ? singbox.data.running : previousData.singbox,
        podkopRunning: podkop.success
          ? podkop.data.running
          : previousData.podkopRunning,
        podkopEnabled: podkop.success
          ? podkop.data.enabled
          : previousData.podkopEnabled,
        podkopStatus: podkop.success
          ? podkop.data.status
          : previousData.podkopStatus,
      },
    },
  });

  return undefined;
}
