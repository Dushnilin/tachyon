export interface TrafficSample {
  up: number;
  down: number;
}

export interface ConnectionTrafficSample {
  id?: string;
  chains?: string[];
  metadata?: { chains?: string[] };
  upload?: number | string;
  download?: number | string;
}

export interface ConnectionRatesState {
  sampledAt: number;
  counters: Map<string, TrafficSample>;
}

export function createInitialConnectionRatesState(): ConnectionRatesState {
  return { sampledAt: 0, counters: new Map() };
}

/** Sample once per /connections message, never while rendering a card. */
export function computeConnectionRates(
  connections: ConnectionTrafficSample[],
  now: number,
  state: ConnectionRatesState,
): {
  rates: Map<string, TrafficSample>;
  nextState: ConnectionRatesState;
} {
  const counters = new Map<string, TrafficSample>();
  const rates = new Map<string, TrafficSample>();
  const dt = (now - state.sampledAt) / 1000;
  const canMeasure = state.sampledAt > 0 && dt > 0;
  const bytes = (value: unknown) => {
    const n = Number(value);
    return Number.isFinite(n) ? Math.max(0, n) : 0;
  };

  for (const connection of connections) {
    if (!connection.id) continue;
    const current = {
      up: bytes(connection.upload),
      down: bytes(connection.download),
    };
    const previous = state.counters.get(connection.id);
    counters.set(connection.id, current);
    rates.set(connection.id, {
      up: canMeasure
        ? Math.round(Math.max(0, current.up - (previous?.up || 0)) / dt)
        : 0,
      down: canMeasure
        ? Math.round(Math.max(0, current.down - (previous?.down || 0)) / dt)
        : 0,
    });
  }

  // Retain only active IDs: closed flows cannot subtract from surviving flows
  // or accumulate indefinitely in the browser's memory.
  return { rates, nextState: { sampledAt: now, counters } };
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
