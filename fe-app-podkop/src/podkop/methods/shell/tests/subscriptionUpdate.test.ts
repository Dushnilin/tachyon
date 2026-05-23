import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  executeShellCommand: vi.fn(),
}));

vi.mock('../../../../helpers', () => ({
  executeShellCommand: mocks.executeShellCommand,
}));

import { PodkopShellMethods } from '../index';

describe('PodkopShellMethods.subscriptionUpdate', () => {
  beforeEach(() => {
    mocks.executeShellCommand.mockReset();
  });

  it('succeeds when retry diagnostics are written to stderr but command exits successfully', async () => {
    mocks.executeShellCommand.mockResolvedValue({
      stdout: 'Subscription update completed',
      stderr: 'curl: (28) Operation timed out',
      code: 0,
    });

    const response = await PodkopShellMethods.subscriptionUpdate('main');

    expect(response).toEqual({
      success: true,
      data: 'Subscription update completed',
    });
    expect(mocks.executeShellCommand).toHaveBeenCalledWith({
      command: '/usr/bin/podkop-plus',
      args: ['subscription_update', 'main'],
      timeout: 600000,
    });
  });

  it('fails when the command exits with a non-zero code', async () => {
    mocks.executeShellCommand.mockResolvedValue({
      stdout: '',
      stderr: 'Subscription update failed',
      code: 1,
    });

    const response = await PodkopShellMethods.subscriptionUpdate('main');

    expect(response).toEqual({
      success: false,
      error: 'Subscription update failed',
    });
  });
});
