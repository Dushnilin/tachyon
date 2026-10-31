import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  executeShellCommand: vi.fn(),
}));

vi.mock('../../../../helpers', () => ({
  executeShellCommand: mocks.executeShellCommand,
}));

import { Tachyon } from '../../../types';
import { callBaseMethod } from '../callBaseMethod';

describe('callBaseMethod', () => {
  beforeEach(() => {
    mocks.executeShellCommand.mockReset();
  });

  it('fails on non-zero exit code even when stdout is present by default', async () => {
    mocks.executeShellCommand.mockResolvedValue({
      stdout: '{"ok":false}',
      stderr: 'command failed',
      code: 1,
    });

    const response = await callBaseMethod(
      Tachyon.AvailableMethods.CHECK_DNS_AVAILABLE,
    );

    expect(response).toEqual({
      success: false,
      error: 'command failed',
    });
  });

  it('can return stdout for diagnostic commands with non-zero exit code', async () => {
    mocks.executeShellCommand.mockResolvedValue({
      stdout: 'Global check run\n[FAIL] Sing-box process running',
      stderr: '',
      code: 1,
    });

    const response = await callBaseMethod(
      Tachyon.AvailableMethods.GLOBAL_CHECK,
      [],
      { allowNonZeroWithStdout: true },
    );

    expect(response).toEqual({
      success: true,
      data: 'Global check run\n[FAIL] Sing-box process running',
    });
  });

  it('passes a custom timeout to long-running commands', async () => {
    mocks.executeShellCommand.mockResolvedValue({
      stdout: '{"ok":true}',
      stderr: '',
      code: 0,
    });

    await callBaseMethod(Tachyon.AvailableMethods.GLOBAL_CHECK, [], {
      timeout: 60000,
    });

    expect(mocks.executeShellCommand).toHaveBeenCalledWith({
      command: '/usr/bin/tachyon',
      args: ['global_check'],
      timeout: 60000,
    });
  });

  it('accepts empty stdout only when explicitly allowed', async () => {
    mocks.executeShellCommand.mockResolvedValue({
      stdout: '',
      stderr: '',
      code: 0,
    });

    await expect(
      callBaseMethod(Tachyon.AvailableMethods.ENABLE, [], {
        allowEmptyStdout: true,
      }),
    ).resolves.toEqual({ success: true, data: undefined });

    await expect(
      callBaseMethod(Tachyon.AvailableMethods.GET_UI_STATE),
    ).resolves.toEqual({ success: false, error: '' });
  });

  it('does not hide a failed command when empty stdout is allowed', async () => {
    mocks.executeShellCommand.mockResolvedValue({
      stdout: '',
      stderr: 'Read-only file system',
      code: 1,
    });

    await expect(
      callBaseMethod(Tachyon.AvailableMethods.ENABLE, [], {
        allowEmptyStdout: true,
      }),
    ).resolves.toEqual({
      success: false,
      error: 'Read-only file system',
    });
  });
});
