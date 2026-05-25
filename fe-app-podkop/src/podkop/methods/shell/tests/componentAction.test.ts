import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  executeShellCommand: vi.fn(),
  fsRead: vi.fn(),
}));

vi.mock('../../../../helpers', () => ({
  executeShellCommand: mocks.executeShellCommand,
}));

import { PodkopShellMethods } from '../index';

describe('PodkopShellMethods.componentAction', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    mocks.executeShellCommand.mockReset();
    mocks.fsRead.mockReset();
    vi.stubGlobal('fs', {
      read: mocks.fsRead,
    });
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it('does not fail Podkop Plus self-update when status polling disappears after package replacement', async () => {
    mocks.fsRead.mockRejectedValue(new Error('Access denied'));
    mocks.executeShellCommand.mockImplementation(({ args }) => {
      if (args[0] === 'component_action_async') {
        return Promise.resolve({
          stdout: JSON.stringify({
            success: true,
            job_id: 'job-1',
            message: 'Component action started',
          }),
          stderr: '',
          code: 0,
        });
      }

      if (args[0] === 'component_action_status') {
        return Promise.resolve({
          stdout: '',
          stderr: 'Unknown command',
          code: 1,
        });
      }

      if (args[0] === 'show_version') {
        return Promise.resolve({
          stdout: '0.7.17.11\n',
          stderr: '',
          code: 0,
        });
      }

      return Promise.resolve({
        stdout: '',
        stderr: 'Unexpected command',
        code: 1,
      });
    });

    const responsePromise = PodkopShellMethods.componentAction(
      'podkop',
      'install',
      '0.7.17.11',
    );

    await vi.advanceTimersByTimeAsync(33000);

    await expect(responsePromise).resolves.toEqual({
      success: true,
      data: {
        success: true,
        component: 'podkop',
        action: 'install',
        message: 'Podkop Plus has been installed',
        current_version: '0.7.17.11',
        latest_version: '0.7.17.11',
        changed: true,
        status: 'latest',
      },
    });
  });
});
