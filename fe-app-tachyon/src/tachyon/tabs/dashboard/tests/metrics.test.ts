import { describe, it, expect } from 'vitest';
import {
  computeTrafficRates,
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
