export interface TrafficSample {
  up: number;
  down: number;
}

export interface TrafficRatesState {
  lastTrafficPollTime: number;
  lastUploadTotal: number;
  lastDownloadTotal: number;
}

export function createInitialTrafficRatesState(): TrafficRatesState {
  return {
    lastTrafficPollTime: 0,
    lastUploadTotal: 0,
    lastDownloadTotal: 0,
  };
}

export function computeTrafficRates(
  uploadTotal: number,
  downloadTotal: number,
  now: number,
  state: TrafficRatesState,
): { rates: TrafficSample; nextState: TrafficRatesState } {
  if (state.lastTrafficPollTime > 0) {
    const dt = Math.max(0.5, (now - state.lastTrafficPollTime) / 1000);
    const up = Math.max(
      0,
      Math.round((uploadTotal - state.lastUploadTotal) / dt),
    );
    const down = Math.max(
      0,
      Math.round((downloadTotal - state.lastDownloadTotal) / dt),
    );

    return {
      rates: { up, down },
      nextState: {
        lastTrafficPollTime: now,
        lastUploadTotal: uploadTotal,
        lastDownloadTotal: downloadTotal,
      },
    };
  }

  return {
    rates: { up: 0, down: 0 },
    nextState: {
      lastTrafficPollTime: now,
      lastUploadTotal: uploadTotal,
      lastDownloadTotal: downloadTotal,
    },
  };
}
