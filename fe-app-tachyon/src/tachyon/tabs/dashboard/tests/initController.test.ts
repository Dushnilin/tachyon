/* eslint-disable @typescript-eslint/no-explicit-any */
import { describe, it, expect, vi, beforeEach } from 'vitest';

class MockMutationObserver {
  observe() {}
  disconnect() {}
  takeRecords() {
    return [];
  }
}
globalThis.MutationObserver = MockMutationObserver as any;

globalThis.document = {
  body: {} as any,
  createElement: () => ({}) as any,
  getElementById: () => null,
  querySelector: () => null,
  querySelectorAll: () => [],
} as any;

(globalThis as any).rpc = { declare: vi.fn() };
(globalThis as any).localStorage = { getItem: vi.fn(), setItem: vi.fn() };

// Define mocks before importing
vi.mock('../../../helpers', () => ({
  canUseDirectClashApi: vi.fn().mockReturnValue(true),
  onMount: vi.fn().mockImplementation(() => Promise.resolve()),
  getClashWsUrl: vi.fn(),
  isCopyableProxyLink: vi.fn(),
  preserveScrollForPage: vi.fn((cb) => cb()),
}));

vi.mock('../../../helpers/isActiveLuciTab', () => ({
  isActiveLuciTab: vi.fn().mockReturnValue(true),
}));

vi.mock('../../../services/runtimeUiState.service', () => ({
  getCachedRuntimeUiState: vi.fn().mockReturnValue(null),
  refreshRuntimeUiState: vi.fn().mockResolvedValue(null),
  subscribeRuntimeUiState: vi.fn(),
}));

describe('dashboard initController', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    (globalThis as any).E = vi
      .fn()
      .mockImplementation((tag) => document.createElement(tag));
    (globalThis as any).ui = {
      showModal: vi.fn(),
      hideModal: vi.fn(),
      addNotification: vi.fn(),
    } as any;
    (globalThis as any).uci = {
      sections: vi.fn().mockResolvedValue([]),
    } as any;
  });

  it('should export initController function', async () => {
    const { initController } = await import('../initController');
    expect(typeof initController).toBe('function');
  });

  // -1 is what the dashboard stores for "did not answer". Rendering it as "-1ms"
  // in green is worse than useless: the row looks like a measurement, and a
  // better one than most real ones.
  it('never shows a negative latency as a measurement', async () => {
    const { formatUrlTestLatency, getUrlTestLatencyClass } = await import(
      '../initController'
    );

    expect(formatUrlTestLatency(-1)).toBe('N/A');
    expect(getUrlTestLatencyClass(-1)).toBe(
      'tachyon_dashboard-page__outbound-grid__item__latency--empty',
    );

    expect(formatUrlTestLatency(72)).toBe('72ms');
    expect(getUrlTestLatencyClass(72)).toBe(
      'tachyon_dashboard-page__outbound-grid__item__latency--green',
    );
  });

  it('formats service row values correctly', async () => {
    const { formatServiceRowValue } = await import('../initController');

    // Stopped
    expect(formatServiceRowValue({ running: 0 })).toBe('✗');
    expect(formatServiceRowValue({ running: 0, version: '0.1.3' })).toBe(
      '✗ [v0.1.3]',
    );
    expect(formatServiceRowValue({ running: 0, version: 'v0.1.3' })).toBe(
      '✗ [v0.1.3]',
    );

    // Running with memory, uptime and version
    expect(
      formatServiceRowValue({
        running: 1,
        memoryMb: 16,
        uptimePretty: '1ч 47м',
        version: '0.1.3',
      }),
    ).toBe('✓ (16 MB) • 1ч 47м [v0.1.3]');

    // Running with extra cache suffix
    expect(
      formatServiceRowValue({
        running: 1,
        memoryMb: 2,
        uptimePretty: '3ч 57м',
        extraSuffix: ' [Cache: 1.1 MB]',
      }),
    ).toBe('✓ (2 MB) • 3ч 57м [Cache: 1.1 MB]');

    // Running with no memory but uptime
    expect(
      formatServiceRowValue({
        running: 1,
        uptimePretty: '6ч 29м',
      }),
    ).toBe('✓ • 6ч 29м');
  });

  it('formats service tooltips correctly', async () => {
    const { formatServiceTooltip } = await import('../initController');

    expect(formatServiceTooltip({})).toBeUndefined();
    expect(formatServiceTooltip({ pid: 21427, uptimePretty: '1ч 47м' })).toBe(
      'PID: 21427 • Uptime: 1ч 47м',
    );
    expect(formatServiceTooltip({ pid: 2450 })).toBe('PID: 2450');
  });

  it('renders modern service row items with pills and status dot', async () => {
    const { renderServiceRowItem } = await import('../initController');
    const runningItem = renderServiceRowItem('Tachyon Core', {
      running: 1,
      memoryMb: 22,
      uptimePretty: '2ч 51м',
      tooltip: 'PID: 1234 • Uptime: 2ч 51м',
    });
    expect(runningItem.attributes.class).toContain('row--success');
    expect(runningItem.attributes.title).toBe('PID: 1234 • Uptime: 2ч 51м');

    const stoppedItem = renderServiceRowItem('Zapret2', {
      running: 0,
    });
    expect(stoppedItem.attributes.class).toContain('row--error');
  });

  it('localizes uptime strings based on UI language', async () => {
    const { formatLocalizedUptime } = await import('../initController');

    // In English environment (vitest default):
    expect(formatLocalizedUptime('3ч 12м')).toBe('3h 12m');
    expect(formatLocalizedUptime('2д 5ч')).toBe('2d 5h');
    expect(formatLocalizedUptime('45с')).toBe('45s');
    expect(formatLocalizedUptime('15м')).toBe('15m');
    expect(formatLocalizedUptime(undefined, 3720)).toBe('1h 2m');
    expect(formatLocalizedUptime(undefined, 45)).toBe('45s');
  });

  it('renders system widget when service is stopped', async () => {
    const { renderSystemServicesWidget } = await import('../initController');
    const { store } = await import('../../../services/store.service');

    const container = {
      replaceChildren: vi.fn(),
    };
    (globalThis.document as any).getElementById = vi.fn((id: string) => {
      if (id === 'dashboard-widget-system-services') return container;
      return null;
    });

    store.set({
      servicesInfoWidget: {
        loading: false,
        failed: false,
        data: {
          tachyonRunning: 0,
          singbox: 0,
          dnsmasqRunning: 1,
        } as any,
      },
    });

    await renderSystemServicesWidget();
    expect(container.replaceChildren).toHaveBeenCalled();
  });

  it('extractTestedTags extracts codes from proxy_list, group, and proxy', async () => {
    const { extractTestedTags } = await import('../initController');

    // proxy_list
    expect(
      extractTestedTags('proxy_list', 'sec', JSON.stringify(['us-1', 'us-2'])),
    ).toEqual(['us-1', 'us-2']);

    // proxy
    expect(extractTestedTags('proxy', 'sec', 'de-1')).toEqual(['de-1']);
    expect(extractTestedTags('proxy', 'sec', '["de-2"]')).toEqual(['de-2']);

    // invalid json in proxy_list
    expect(extractTestedTags('proxy_list', 'sec', 'invalid')).toEqual([]);
  });

  it('applyTestedLatenciesResults sets positive delay for responding nodes and -1 for unresponsive nodes', async () => {
    const { applyTestedLatenciesResults, customProxyLatencies } = await import(
      '../initController'
    );
    const { TachyonShellMethods } = await import('../../../methods');

    const now = Date.now();
    vi.spyOn(TachyonShellMethods, 'getClashApiProxies').mockResolvedValue({
      success: true,
      data: {
        proxies: {
          'server-ok': {
            history: [{ time: new Date(now).toISOString(), delay: 145 }],
          },
          'server-timeout': {
            history: [],
          },
          'server-old': {
            history: [
              { time: new Date(now - 60000).toISOString(), delay: 200 },
            ],
          },
        },
      } as any,
    });

    const beforeTimes = new Map<string, string>();
    beforeTimes.set('server-old', new Date(now - 60000).toISOString());

    await applyTestedLatenciesResults(
      ['server-ok', 'server-timeout', 'server-old'],
      now,
      beforeTimes,
    );

    expect(customProxyLatencies.get('server-ok')).toBe(145);
    expect(customProxyLatencies.get('server-timeout')).toBe(-1);
    expect(customProxyLatencies.get('server-old')).toBe(-1);
  });
});
