import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  executeShellCommand: vi.fn(),
}));

vi.mock('../../../../helpers', () => ({
  executeShellCommand: mocks.executeShellCommand,
}));

import { TachyonShellMethods } from '../index';

describe('TachyonShellMethods.doctor', () => {
  beforeEach(() => {
    mocks.executeShellCommand.mockReset();
  });

  it('calls doctor without --fix by default (dry-run mode)', async () => {
    mocks.executeShellCommand.mockResolvedValue({
      stdout: JSON.stringify({
        success: true,
        issues: 1,
        fixed: 0,
        report: 'Doctor report: 1 issue found',
      }),
      stderr: '',
      code: 0,
    });

    const res = await TachyonShellMethods.doctor();

    expect(mocks.executeShellCommand).toHaveBeenCalledWith(
      expect.objectContaining({
        args: ['doctor'],
      }),
    );
    expect(res).toEqual({
      success: true,
      data: {
        success: true,
        issues: 1,
        fixed: 0,
        report: 'Doctor report: 1 issue found',
      },
    });
  });

  it('calls doctor with --fix when fix is true', async () => {
    mocks.executeShellCommand.mockResolvedValue({
      stdout: JSON.stringify({
        success: true,
        issues: 1,
        fixed: 1,
        report: 'Doctor report: 1 issue fixed',
      }),
      stderr: '',
      code: 0,
    });

    const res = await TachyonShellMethods.doctor(true);

    expect(mocks.executeShellCommand).toHaveBeenCalledWith(
      expect.objectContaining({
        args: ['doctor', '--fix'],
      }),
    );
    expect(res).toEqual({
      success: true,
      data: {
        success: true,
        issues: 1,
        fixed: 1,
        report: 'Doctor report: 1 issue fixed',
      },
    });
  });
});
