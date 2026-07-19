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
});
