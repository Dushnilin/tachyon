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

vi.mock('../../../helpers', () => ({
  canUseDirectClashApi: vi.fn().mockReturnValue(true),
  getClashWsUrl: vi.fn().mockReturnValue('ws://127.0.0.1:9090'),
  onMount: vi.fn().mockImplementation(() => Promise.resolve()),
  prettyBytes: vi.fn().mockReturnValue('0 B'),
  showToast: vi.fn(),
}));

vi.mock('../../../services/runtimeUiState.service', () => ({
  getCachedRuntimeUiState: vi.fn().mockReturnValue(null),
  refreshRuntimeUiState: vi.fn().mockResolvedValue(null),
  subscribeRuntimeUiState: vi.fn(),
}));

describe('monitoring initController', () => {
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

  it('should resolve route display names correctly for built-in and section tags', async () => {
    const { buildRouteDisplayNames, getRouteDisplayNameByTag, getRoute } =
      await import('../initController');

    buildRouteDisplayNames([
      {
        '.name': 'vpn',
        '.type': 'section',
        label: 'My VPN',
        enabled: '1',
      } as any,
      {
        '.name': 'zapret',
        '.type': 'section',
        label: 'Zapret YouTube',
        enabled: '1',
      } as any,
    ]);

    // Built-in tags
    expect(getRouteDisplayNameByTag('bypass-out')).toBe('Bypass');
    expect(getRouteDisplayNameByTag('direct-out')).toBe('direct');
    expect(getRouteDisplayNameByTag('tachyon-failover')).toBe('Failover');

    // Section root tags
    expect(getRouteDisplayNameByTag('vpn-out')).toBe('My VPN');
    expect(getRouteDisplayNameByTag('zapret-out')).toBe('Zapret YouTube');

    // Section sub-outbounds (numeric, named, priority, json)
    expect(getRouteDisplayNameByTag('vpn-1-out')).toBe('My VPN');
    expect(getRouteDisplayNameByTag('vpn-priority-1-out')).toBe('My VPN');
    expect(getRouteDisplayNameByTag('vpn-json-1-out')).toBe('My VPN');
    expect(getRouteDisplayNameByTag('vpn-interface-1-out')).toBe('My VPN');
    expect(getRouteDisplayNameByTag('zapret-1-out')).toBe('Zapret YouTube');

    // Direct section name matching
    expect(getRouteDisplayNameByTag('vpn')).toBe('My VPN');
    expect(getRouteDisplayNameByTag('zapret')).toBe('Zapret YouTube');

    // Unknown tag returns empty string
    expect(getRouteDisplayNameByTag('unknown-out')).toBe('');

    // getRoute helper with chains and fallback rule
    expect(
      getRoute({
        id: '1',
        metadata: {},
        chains: ['tproxy-in', 'vpn-priority-1-out'],
        lastSeenAt: Date.now(),
      } as any),
    ).toBe('My VPN');

    expect(
      getRoute({
        id: '2',
        metadata: {},
        chains: ['tproxy-in', 'zapret-out'],
        lastSeenAt: Date.now(),
      } as any),
    ).toBe('Zapret YouTube');

    expect(
      getRoute({
        id: '3',
        metadata: {},
        chains: [],
        rule: 'rule-1 => route("zapret-out")',
        lastSeenAt: Date.now(),
      } as any),
    ).toBe('Zapret YouTube');

    expect(
      getRoute({
        id: '4',
        metadata: {},
        chains: ['tachyon-failover'],
        lastSeenAt: Date.now(),
      } as any),
    ).toBe('Failover');
  });
});
