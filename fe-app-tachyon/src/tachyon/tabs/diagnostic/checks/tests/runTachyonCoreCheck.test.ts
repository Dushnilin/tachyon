import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  checkTachyonCore: vi.fn(),
  updateCheckStore: vi.fn(),
}));

vi.mock('../../../../methods', () => ({
  TachyonShellMethods: {
    checkTachyonCore: mocks.checkTachyonCore,
  },
}));

vi.mock('../updateCheckStore', () => ({
  updateCheckStore: mocks.updateCheckStore,
}));

import { runTachyonCoreCheck } from '../runTachyonCoreCheck';

const healthy = {
  tachyon_core_installed: 1,
  tachyon_core_version_ok: 1,
  tachyon_core_version: '0.2.4',
  tachyon_core_bin_path: '/usr/bin/tachyon-core',
  tachyon_core_service_exist: 1,
  tachyon_core_init_path: '/etc/init.d/tachyon-core',
  tachyon_core_autostart_disabled: 1,
  tachyon_core_process_running: 1,
  tachyon_core_ports_listening: 1,
  tachyon_core_listen_ports: '53, 1602, 9090',
};

function keysOf(): string[] {
  const lastCall = mocks.updateCheckStore.mock.calls.slice(-1)[0]?.[0];
  return (lastCall?.items || []).map((i: { key: string }) => i.key);
}

describe('runTachyonCoreCheck', () => {
  beforeEach(() => {
    mocks.checkTachyonCore.mockReset();
    mocks.updateCheckStore.mockReset();
  });

  it('reports Tachyon Core title and all healthy check items', async () => {
    mocks.checkTachyonCore.mockResolvedValue({ success: true, data: healthy });

    await runTachyonCoreCheck();

    expect(keysOf()).toContain('Tachyon Core installed');
    expect(keysOf()).toContain('Tachyon Core listening ports');
    expect(keysOf()).toContain('Tachyon Core process running');
    const lastCall = mocks.updateCheckStore.mock.calls.slice(-1)[0]?.[0];
    expect(lastCall?.title).toBe('Tachyon Core checks');
    expect(lastCall?.state).toBe('success');
  });

  it('throws when Tachyon Core process is not running', async () => {
    mocks.checkTachyonCore.mockResolvedValue({
      success: true,
      data: { ...healthy, tachyon_core_process_running: 0 },
    });

    await expect(runTachyonCoreCheck()).rejects.toThrow(
      'Tachyon Core checks failed',
    );
    expect(mocks.updateCheckStore.mock.calls.slice(-1)[0]?.[0]?.state).toBe(
      'warning',
    );
  });
});
