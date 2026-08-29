import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  executeShellCommand: vi.fn(),
  fsRead: vi.fn(),
}));

vi.mock('../../../../helpers', () => ({
  executeShellCommand: mocks.executeShellCommand,
}));

import { TachyonShellMethods } from '../index';

describe('TachyonShellMethods.componentAction', () => {
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

  it('does not fail Tachyon self-update when status polling disappears after package replacement', async () => {
    mocks.fsRead.mockRejectedValue(new Error('Access denied'));
    mocks.executeShellCommand.mockImplementation(({ args }) => {
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

    const responsePromise = TachyonShellMethods.waitComponentActionJob(
      'job-1',
      'tachyon',
      'install',
      '0.7.17.11',
    );

    await vi.advanceTimersByTimeAsync(45000);

    await expect(responsePromise).resolves.toEqual({
      success: true,
      data: {
        success: true,
        component: 'tachyon',
        action: 'install',
        message: 'Tachyon has been installed',
        current_version: '0.7.17.11',
        latest_version: '0.7.17.11',
        changed: true,
        status: 'latest',
      },
    });
  });

  it('returns the backend component action start error message', async () => {
    mocks.executeShellCommand.mockResolvedValue({
      stdout: JSON.stringify({
        success: false,
        message: 'Another component action is already running',
      }),
      stderr: '',
      code: 1,
    });

    await expect(
      TachyonShellMethods.componentActionStart('zapret', 'install'),
    ).resolves.toEqual({
      success: false,
      error: 'Another component action is already running',
    });
  });

  it('keeps following a component job after the former browser-side wait timeout while the backend reports it running', async () => {
    let stateReads = 0;

    mocks.fsRead.mockImplementation(() =>
      Promise.resolve(
        JSON.stringify(
          stateReads++ < 401
            ? {
                success: true,
                running: true,
                component: 'sing_box',
                action: 'check_update',
                message: 'Component action is running',
                job_id: 'job-1',
              }
            : {
                success: true,
                running: false,
                component: 'sing_box',
                action: 'check_update',
                message: 'sing-box is up to date',
                current_version: '1.13.12-extended-2.3.2',
                latest_version: '1.13.12-extended-2.3.2',
                changed: false,
                status: 'latest',
              },
        ),
      ),
    );

    mocks.executeShellCommand.mockImplementation(({ args }) => {
      if (args[0] === 'component_action_status') {
        return Promise.resolve({
          stdout: JSON.stringify({
            success: true,
            running: true,
            component: 'sing_box',
            action: 'check_update',
            message: 'Component action is running',
            job_id: 'job-1',
          }),
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

    const responsePromise = TachyonShellMethods.waitComponentActionJob(
      'job-1',
      'sing_box',
      'check_update',
    );

    await vi.advanceTimersByTimeAsync(10 * 60 * 1000 + 3000);

    await expect(responsePromise).resolves.toEqual({
      success: true,
      data: {
        success: true,
        running: false,
        component: 'sing_box',
        action: 'check_update',
        message: 'sing-box is up to date',
        current_version: '1.13.12-extended-2.3.2',
        latest_version: '1.13.12-extended-2.3.2',
        changed: false,
        status: 'latest',
      },
    });
  });

  it('keeps waiting when status polling briefly fails but UI state still reports the job running', async () => {
    mocks.fsRead
      .mockRejectedValueOnce(new Error('State is temporarily unavailable'))
      .mockResolvedValueOnce(
        JSON.stringify({
          success: true,
          running: false,
          component: 'sing_box',
          action: 'install_extended',
          message: 'sing-box-extended has been installed',
          current_version: '1.13.12-extended-2.3.2',
          latest_version: '1.13.12-extended-2.3.2',
          changed: true,
          status: 'latest',
        }),
      );

    mocks.executeShellCommand.mockImplementation(({ args }) => {
      if (args[0] === 'component_action_status') {
        return Promise.resolve({
          stdout: '',
          stderr: 'Component action job was not found',
          code: 1,
        });
      }

      if (args[0] === 'get_ui_state') {
        return Promise.resolve({
          stdout: JSON.stringify({
            service: {
              tachyon: {
                running: 0,
                enabled: 1,
                status: 'stopped but enabled',
                dns_configured: 0,
              },
              sing_box: {
                running: 0,
                enabled: 1,
                status: 'stopped but enabled',
              },
            },
            capabilities: {
              sing_box_extended: 0,
              sing_box_tiny: 1,
              sing_box_compressed: 0,
              sing_box_tailscale: 0,
              zapret_installed: 1,
              zapret2_installed: 1,
              byedpi_installed: 0,
              server_inbounds_enabled_count: 0,
            },
            actions: {
              service: [],
              latency: [],
              component: [
                {
                  success: true,
                  running: true,
                  component: 'sing_box',
                  action: 'install_extended',
                  message: 'Component action is running',
                  job_id: 'job-1',
                },
              ],
              subscription: [],
            },
          }),
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

    const responsePromise = TachyonShellMethods.waitComponentActionJob(
      'job-1',
      'sing_box',
      'install_extended',
    );

    await vi.advanceTimersByTimeAsync(3000);

    await expect(responsePromise).resolves.toEqual({
      success: true,
      data: {
        success: true,
        running: false,
        component: 'sing_box',
        action: 'install_extended',
        message: 'sing-box-extended has been installed',
        current_version: '1.13.12-extended-2.3.2',
        latest_version: '1.13.12-extended-2.3.2',
        changed: true,
        status: 'latest',
      },
    });
    expect(mocks.executeShellCommand).toHaveBeenCalledWith({
      command: '/usr/bin/tachyon',
      args: ['get_ui_state'],
      timeout: 3000,
    });
  });

  it('keeps waiting through a transient RPC reply loss until the action state settles', async () => {
    mocks.fsRead
      .mockRejectedValueOnce(new Error('State is temporarily unavailable'))
      .mockResolvedValueOnce(
        JSON.stringify({
          success: true,
          running: false,
          component: 'zapret',
          action: 'check_update',
          message: 'zapret is up to date',
          current_version: '70.2',
          latest_version: '70.2',
          changed: false,
          status: 'latest',
        }),
      );

    mocks.executeShellCommand.mockImplementation(({ args }) => {
      if (args[0] === 'component_action_status') {
        return Promise.resolve({
          stdout: '',
          stderr: 'No related RPC reply',
          code: 1,
        });
      }

      if (args[0] === 'get_ui_state') {
        return Promise.resolve({
          stdout: '',
          stderr: 'No related RPC reply',
          code: 1,
        });
      }

      return Promise.resolve({
        stdout: '',
        stderr: 'Unexpected command',
        code: 1,
      });
    });

    const responsePromise = TachyonShellMethods.waitComponentActionJob(
      'job-1',
      'zapret',
      'check_update',
    );

    await vi.advanceTimersByTimeAsync(3000);

    await expect(responsePromise).resolves.toEqual({
      success: true,
      data: {
        success: true,
        running: false,
        component: 'zapret',
        action: 'check_update',
        message: 'zapret is up to date',
        current_version: '70.2',
        latest_version: '70.2',
        changed: false,
        status: 'latest',
      },
    });
  });

  it('completes a Tachyon self-update when the backend is stuck reporting the job running (worker pid recycled, RPC eventually fails)', async () => {
    let rpcCalls = 0;

    mocks.fsRead.mockResolvedValue(
      JSON.stringify({
        success: true,
        running: true,
        component: 'tachyon',
        action: 'reinstall',
        message: 'Component action is running',
        job_id: 'job-1',
      }),
    );

    mocks.executeShellCommand.mockImplementation(({ args }) => {
      if (args[0] === 'component_action_status') {
        rpcCalls++;
        if (rpcCalls <= 4) {
          return Promise.resolve({
            stdout: JSON.stringify({
              success: true,
              running: true,
              component: 'tachyon',
              action: 'reinstall',
              message: 'Component action is running',
              job_id: 'job-1',
            }),
            stderr: '',
            code: 0,
          });
        }
        return Promise.resolve({
          stdout: '',
          stderr: 'Connection refused',
          code: 1,
        });
      }

      if (args[0] === 'show_version') {
        return Promise.resolve({
          stdout: '1.2.78\n',
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

    const responsePromise = TachyonShellMethods.waitComponentActionJob(
      'job-1',
      'tachyon',
      'reinstall',
      '1.2.78',
    );

    await vi.advanceTimersByTimeAsync(45000);

    await expect(responsePromise).resolves.toEqual({
      success: true,
      data: {
        success: true,
        component: 'tachyon',
        action: 'reinstall',
        message: 'Tachyon has been installed',
        current_version: '1.2.78',
        latest_version: '1.2.78',
        changed: true,
        status: 'latest',
      },
    });
  });

  it('treats a stale job state as success for a Tachyon self-update when the installed version matches', async () => {
    let stateReads = 0;

    const stateFactory = () =>
      stateReads++ < 4
        ? {
            success: true,
            running: true,
            component: 'tachyon',
            action: 'reinstall',
            message: 'Component action is running',
            job_id: 'job-1',
          }
        : {
            success: false,
            running: false,
            component: 'tachyon',
            action: 'reinstall',
            message:
              'Component action job is stale or the worker process exited unexpectedly',
            job_id: 'job-1',
          };

    mocks.fsRead.mockImplementation(() =>
      Promise.resolve(JSON.stringify(stateFactory())),
    );

    mocks.executeShellCommand.mockImplementation(({ args }) => {
      if (args[0] === 'component_action_status') {
        return Promise.resolve({
          stdout: JSON.stringify(stateFactory()),
          stderr: '',
          code: 0,
        });
      }

      if (args[0] === 'show_version') {
        return Promise.resolve({
          stdout: '1.2.78\n',
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

    const responsePromise = TachyonShellMethods.waitComponentActionJob(
      'job-1',
      'tachyon',
      'reinstall',
      '1.2.78',
    );

    await vi.advanceTimersByTimeAsync(10000);

    await expect(responsePromise).resolves.toEqual({
      success: true,
      data: {
        success: true,
        component: 'tachyon',
        action: 'reinstall',
        message: 'Tachyon has been installed',
        current_version: '1.2.78',
        latest_version: '1.2.78',
        changed: true,
        status: 'latest',
      },
    });
  });

  it('keeps reporting the stale error when the installed version did not change', async () => {
    mocks.fsRead.mockResolvedValue(
      JSON.stringify({
        success: false,
        running: false,
        component: 'tachyon',
        action: 'reinstall',
        message:
          'Component action job is stale or the worker process exited unexpectedly',
        job_id: 'job-1',
      }),
    );

    mocks.executeShellCommand.mockImplementation(({ args }) => {
      if (args[0] === 'component_action_status') {
        return Promise.resolve({
          stdout: JSON.stringify({
            success: false,
            running: false,
            component: 'tachyon',
            action: 'reinstall',
            message:
              'Component action job is stale or the worker process exited unexpectedly',
            job_id: 'job-1',
          }),
          stderr: '',
          code: 0,
        });
      }

      if (args[0] === 'show_version') {
        return Promise.resolve({
          stdout: '1.2.77\n',
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

    const responsePromise = TachyonShellMethods.waitComponentActionJob(
      'job-1',
      'tachyon',
      'reinstall',
      '1.2.78',
    );

    await vi.advanceTimersByTimeAsync(5000);

    await expect(responsePromise).resolves.toEqual({
      success: true,
      data: {
        success: false,
        running: false,
        component: 'tachyon',
        action: 'reinstall',
        message:
          'Component action job is stale or the worker process exited unexpectedly',
        job_id: 'job-1',
      },
    });
  });

  it('completes a same-version Tachyon reinstall as success when the target version is unknown and the job is stale', async () => {
    mocks.fsRead.mockResolvedValue(
      JSON.stringify({
        success: false,
        running: false,
        component: 'tachyon',
        action: 'reinstall',
        message:
          'Component action job is stale or the worker process exited unexpectedly',
        job_id: 'job-1',
      }),
    );

    mocks.executeShellCommand.mockImplementation(({ args }) => {
      if (args[0] === 'component_action_status') {
        return Promise.resolve({
          stdout: '',
          stderr: 'Unknown command',
          code: 1,
        });
      }

      if (args[0] === 'show_version') {
        return Promise.resolve({
          stdout: '1.2.77\n',
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

    const responsePromise = TachyonShellMethods.waitComponentActionJob(
      'job-1',
      'tachyon',
      'reinstall',
    );

    await vi.advanceTimersByTimeAsync(5000);

    await expect(responsePromise).resolves.toEqual({
      success: true,
      data: {
        success: true,
        component: 'tachyon',
        action: 'reinstall',
        message: 'Tachyon has been installed',
        current_version: '1.2.77',
        latest_version: undefined,
        changed: true,
        status: 'latest',
      },
    });
  });

  it('closes the modal with success when a self-update never confirms and the hard timeout is reached', async () => {
    mocks.fsRead.mockRejectedValue(new Error('Access denied'));
    mocks.executeShellCommand.mockImplementation(({ args }) => {
      if (args[0] === 'component_action_status') {
        return Promise.resolve({
          stdout: '',
          stderr: 'Unknown command',
          code: 1,
        });
      }

      if (args[0] === 'show_version') {
        return Promise.resolve({
          stdout: '1.2.77\n',
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

    const responsePromise = TachyonShellMethods.waitComponentActionJob(
      'job-1',
      'tachyon',
      'install',
    );

    await vi.advanceTimersByTimeAsync(121000);

    await expect(responsePromise).resolves.toEqual({
      success: true,
      data: {
        success: true,
        component: 'tachyon',
        action: 'install',
        message: 'Tachyon has been installed',
        current_version: '1.2.77',
        latest_version: undefined,
        changed: true,
        status: 'latest',
      },
    });
  });

  it('fails a self-update on the hard timeout when the target version is known but never reached', async () => {
    mocks.fsRead.mockResolvedValue(
      JSON.stringify({
        success: true,
        running: true,
        component: 'tachyon',
        action: 'reinstall',
        message: 'Component action is running',
        job_id: 'job-1',
      }),
    );

    mocks.executeShellCommand.mockImplementation(({ args }) => {
      if (args[0] === 'component_action_status') {
        return Promise.resolve({
          stdout: JSON.stringify({
            success: true,
            running: true,
            component: 'tachyon',
            action: 'reinstall',
            message: 'Component action is running',
            job_id: 'job-1',
          }),
          stderr: '',
          code: 0,
        });
      }

      if (args[0] === 'show_version') {
        return Promise.resolve({
          stdout: '1.2.77\n',
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

    const responsePromise = TachyonShellMethods.waitComponentActionJob(
      'job-1',
      'tachyon',
      'reinstall',
      '1.2.78',
    );

    await vi.advanceTimersByTimeAsync(121000);

    await expect(responsePromise).resolves.toEqual({
      success: false,
      error: 'Tachyon update did not complete within the timeout',
    });
  });

  it('does not prematurely confirm same-release Tachyon update while the background job is still running', async () => {
    let jobFinished = false;

    mocks.fsRead.mockImplementation(() =>
      Promise.resolve(
        JSON.stringify({
          success: true,
          running: !jobFinished,
          component: 'tachyon',
          action: 'install',
          message: jobFinished ? 'Tachyon has been installed' : 'Component action is running',
          current_version: '1.3.4',
          latest_version: '1.3.4',
          job_id: 'job-1',
        }),
      ),
    );

    mocks.executeShellCommand.mockImplementation(({ args }) => {
      if (args[0] === 'component_action_status') {
        return Promise.resolve({
          stdout: JSON.stringify({
            success: true,
            running: !jobFinished,
            component: 'tachyon',
            action: 'install',
            message: jobFinished ? 'Tachyon has been installed' : 'Component action is running',
            current_version: '1.3.4',
            latest_version: '1.3.4',
            job_id: 'job-1',
          }),
          stderr: '',
          code: 0,
        });
      }

      if (args[0] === 'show_version') {
        return Promise.resolve({
          stdout: '1.3.4\n',
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

    const responsePromise = TachyonShellMethods.waitComponentActionJob(
      'job-1',
      'tachyon',
      'install',
      '1.3.4',
    );

    // After 5 seconds, job is still running: must not resolve yet
    await vi.advanceTimersByTimeAsync(5000);
    let resolved = false;
    responsePromise.then(() => {
      resolved = true;
    });
    await Promise.resolve();
    expect(resolved).toBe(false);

    // Now job finishes in backend
    jobFinished = true;
    await vi.advanceTimersByTimeAsync(3000);

    await expect(responsePromise).resolves.toEqual({
      success: true,
      data: {
        success: true,
        running: false,
        component: 'tachyon',
        action: 'install',
        message: 'Tachyon has been installed',
        current_version: '1.3.4',
        latest_version: '1.3.4',
        job_id: 'job-1',
      },
    });
  });
});
