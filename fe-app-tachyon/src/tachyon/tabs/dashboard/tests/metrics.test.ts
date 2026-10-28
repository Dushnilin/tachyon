import { describe, it, expect } from 'vitest';
import {
  computeConnectionRates,
  computeTrafficRates,
  createInitialConnectionRatesState,
  createInitialTrafficRatesState,
} from '../metrics';

describe('dashboard metrics', () => {
  it('initializes with zero rates on first poll', () => {
    const state = createInitialTrafficRatesState();
    const result = computeTrafficRates(1000, 2000, 10000, state);

    expect(result.rates).toEqual({ up: 0, down: 0 });
    expect(result.nextState.lastTrafficPollTime).toBe(10000);
    expect(result.nextState.lastUploadTotal).toBe(1000);
    expect(result.nextState.lastDownloadTotal).toBe(2000);
  });

  it('computes correct transfer rates on subsequent poll', () => {
    const state = {
      lastTrafficPollTime: 10000,
      lastUploadTotal: 1000,
      lastDownloadTotal: 2000,
    };
    // 2 seconds later, 2000 bytes up added (1000 B/s), 4000 bytes down added (2000 B/s)
    const result = computeTrafficRates(3000, 6000, 12000, state);

    expect(result.rates.up).toBe(1000);
    expect(result.rates.down).toBe(2000);
    expect(result.nextState.lastTrafficPollTime).toBe(12000);
  });

  it('never outputs negative rates if counters reset or overflow', () => {
    const state = {
      lastTrafficPollTime: 10000,
      lastUploadTotal: 5000,
      lastDownloadTotal: 5000,
    };
    const result = computeTrafficRates(1000, 2000, 12000, state);

    expect(result.rates.up).toBe(0);
    expect(result.rates.down).toBe(0);
  });
});

describe('connection transfer rates', () => {
  it('uses the first snapshot as a baseline, not as a burst of old traffic', () => {
    const sample = computeConnectionRates(
      [{ id: 'old', upload: 1000000, download: 2000000 }],
      10000,
      createInitialConnectionRatesState(),
    );
    expect(sample.rates.get('old')).toEqual({ up: 0, down: 0 });
  });

  it('uses actual elapsed seconds and each connection counter', () => {
    const first = computeConnectionRates(
      [{ id: 'a', upload: 100, download: 1000 }],
      10000,
      createInitialConnectionRatesState(),
    );
    const next = computeConnectionRates(
      [{ id: 'a', upload: '700', download: '4000' }],
      13000,
      first.nextState,
    );
    expect(next.rates.get('a')).toEqual({ up: 200, down: 1000 });
  });

  it('keeps surviving traffic when a much larger connection closes', () => {
    const first = computeConnectionRates(
      [
        { id: 'closed', download: 9000000 },
        { id: 'live', download: 1000 },
      ],
      10000,
      createInitialConnectionRatesState(),
    );
    const next = computeConnectionRates(
      [{ id: 'live', download: 5000 }],
      12000,
      first.nextState,
    );
    expect(next.rates.get('live')).toEqual({ up: 0, down: 2000 });
    expect([...next.nextState.counters.keys()]).toEqual(['live']);
  });

  it('counts a new connection first seen between snapshots', () => {
    const first = computeConnectionRates(
      [],
      10000,
      createInitialConnectionRatesState(),
    );
    const next = computeConnectionRates(
      [{ id: 'new', upload: 100, download: 8000 }],
      12000,
      first.nextState,
    );
    expect(next.rates.get('new')).toEqual({ up: 50, down: 4000 });
  });

  it('does not produce negative rates after counters reset', () => {
    const first = computeConnectionRates(
      [{ id: 'a', upload: 1000, download: 9000 }],
      10000,
      createInitialConnectionRatesState(),
    );
    const reset = computeConnectionRates(
      [{ id: 'a', upload: 10, download: 100 }],
      11000,
      first.nextState,
    );
    expect(reset.rates.get('a')).toEqual({ up: 0, down: 0 });
    const resumed = computeConnectionRates(
      [{ id: 'a', upload: 110, download: 1100 }],
      12000,
      reset.nextState,
    );
    expect(resumed.rates.get('a')).toEqual({ up: 100, down: 1000 });
  });

  it('returns zero for idle and empty snapshots', () => {
    const first = computeConnectionRates(
      [{ id: 'a', download: 1000 }],
      10000,
      createInitialConnectionRatesState(),
    );
    const idle = computeConnectionRates(
      [{ id: 'a', download: 1000 }],
      11000,
      first.nextState,
    );
    expect(idle.rates.get('a')).toEqual({ up: 0, down: 0 });
    expect(computeConnectionRates([], 12000, idle.nextState).rates.size).toBe(
      0,
    );
  });

  it('ignores invalid counters and avoids division by zero', () => {
    const first = computeConnectionRates(
      [{ id: 'a', upload: 'invalid', download: Infinity }, { download: 1000 }],
      10000,
      createInitialConnectionRatesState(),
    );
    expect(first.nextState.counters.size).toBe(1);
    expect(first.nextState.counters.get('a')).toEqual({ up: 0, down: 0 });
    const sameTime = computeConnectionRates(
      [{ id: 'a', upload: -100, download: 1000 }],
      10000,
      first.nextState,
    );
    expect(sameTime.rates.get('a')).toEqual({ up: 0, down: 0 });
  });
});
