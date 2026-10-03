import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  checkSingBox: vi.fn(),
  updateCheckStore: vi.fn(),
}));

vi.mock('../../../../methods', () => ({
  TachyonShellMethods: {
    checkSingBox: mocks.checkSingBox,
  },
}));

vi.mock('../updateCheckStore', () => ({
  updateCheckStore: mocks.updateCheckStore,
}));

// getMeta reads the diagnostics card state through the store, which pulls in
// TabService and its MutationObserver.
vi.mock('../../../../services/tab.service', () => ({
  TabService: {
    getInstance: () => ({ isActive: () => true }),
  },
}));

import { runSingBoxCheck } from '../runSingBoxCheck';

const healthy = {
  sing_box_installed: 1,
  sing_box_version_ok: 1,
  sing_box_service_exist: 1,
  sing_box_autostart_disabled: 1,
  sing_box_process_running: 1,
  sing_box_ports_listening: 1,
  sing_box_extended: 0,
  sing_box_cert_pin: 0,
};

const lastItems = () =>
  mocks.updateCheckStore.mock.calls.slice(-1)[0]?.[0]?.items;
const keysOf = () =>
  (lastItems() ?? []).map((item: { key: string }) => item.key);
const certPinKey = 'TLS certificate pinning (sing-box 1.15+)';

describe('sing-box diagnostics: certificate pinning line', () => {
  beforeEach(() => {
    mocks.checkSingBox.mockReset();
    mocks.updateCheckStore.mockReset();
  });

  it('keeps the line on a stock build, where the warning is actionable', async () => {
    mocks.checkSingBox.mockResolvedValue({
      success: true,
      data: { ...healthy },
    });

    await runSingBoxCheck();

    expect(keysOf()).toContain(certPinKey);
    const certPin = lastItems().find(
      (item: { key: string }) => item.key === certPinKey,
    );
    expect(certPin.state).toBe('warning');
    expect(certPin.value).toBe('Ignored (Upgrade to Extended)');
  });

  // An extended build reports 1.14.x, so the version-gated capability check can
  // never pass on it, and the hint told the user to upgrade to Extended while
  // they were already there. The backend sets sing_box_extended for lx too.
  it.each([
    ['extended', 1],
    ['lx', 1],
  ])('drops the line on an %s build', async (_variant, extended) => {
    mocks.checkSingBox.mockResolvedValue({
      success: true,
      data: { ...healthy, sing_box_extended: extended, sing_box_cert_pin: 0 },
    });

    await runSingBoxCheck();

    expect(keysOf()).not.toContain(certPinKey);
    expect(keysOf()).toContain('Sing-box listening ports');
  });

  it('still reports the line as supported on a stock build that has the field', async () => {
    mocks.checkSingBox.mockResolvedValue({
      success: true,
      data: { ...healthy, sing_box_extended: 0, sing_box_cert_pin: 1 },
    });

    await runSingBoxCheck();

    const certPin = lastItems().find(
      (item: { key: string }) => item.key === certPinKey,
    );
    expect(certPin.state).toBe('success');
    expect(certPin.value).toBe('Supported');
  });

  it('treats a missing extended flag as stock, so the line is not silently dropped', async () => {
    const { sing_box_extended: _omitted, ...withoutFlag } = healthy;
    mocks.checkSingBox.mockResolvedValue({ success: true, data: withoutFlag });

    await runSingBoxCheck();

    expect(keysOf()).toContain(certPinKey);
  });
});
