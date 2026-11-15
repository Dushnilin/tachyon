import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({ exec: vi.fn() }));

// Keep the real timeout wrapper: mocking executeShellCommand would miss the
// regression where get_ui_state succeeds after the old 3s deadline.
vi.mock('../../../../helpers', async () => {
  const { executeShellCommand } = await import(
    '../../../../helpers/executeShellCommand'
  );
  return { executeShellCommand };
});

import { TachyonShellMethods } from '../index';
import { refreshRuntimeUiState } from '../../../services/runtimeUiState.service';
import { store } from '../../../services/store.service';

describe('autostart and runtime status on slow routers', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.stubGlobal('_', (text: string) => text);
    vi.stubGlobal('fs', { exec: mocks.exec });
    mocks.exec.mockReset();
    store.reset();
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it.each(['enable', 'disable'] as const)(
    'accepts a successful %s command without stdout',
    async (action) => {
      // rpcd omits stdout/stderr entirely for silent commands.
      mocks.exec.mockResolvedValue({ code: 0 });

      await expect(TachyonShellMethods[action]()).resolves.toEqual({
        success: true,
        data: undefined,
      });
      expect(mocks.exec).toHaveBeenCalledWith('/usr/bin/tachyon', [action]);
    },
  );

  it('applies a healthy status response that takes four seconds', async () => {
    const uiState = {
      service: {
        tachyon: { running: 1, enabled: 1, status: 'running & enabled' },
        sing_box: { running: 1, enabled: 0, status: 'running but disabled' },
      },
      capabilities: {},
      actions: { service: [], latency: [], component: [], subscription: [] },
    };
    mocks.exec.mockImplementation(
      () =>
        new Promise((resolve) => {
          setTimeout(
            () => resolve({ code: 0, stdout: JSON.stringify(uiState) }),
            4000,
          );
        }),
    );

    const refresh = refreshRuntimeUiState({ force: true });
    await vi.advanceTimersByTimeAsync(4000);

    await expect(refresh).resolves.toEqual(uiState);
    expect(store.get().servicesInfoWidget.data).toMatchObject({
      tachyonRunning: 1,
      tachyonEnabled: 1,
      tachyonStatus: 'running & enabled',
      singbox: 1,
    });
  });
});
