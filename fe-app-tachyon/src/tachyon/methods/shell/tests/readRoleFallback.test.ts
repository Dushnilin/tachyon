/// <reference types="vite/client" />
import { beforeEach, describe, expect, it, vi } from 'vitest';

import { Tachyon } from '../../../types';

/**
 * The read role is not a degraded version of the write role, it is a different
 * execution path. rpcd grants it exec on /usr/bin/tachyon-read and withholds
 * /usr/bin/tachyon outright, so a read-only LuCI account calling the main binary
 * is denied by policy before any subcommand runs.
 *
 * Nothing in the session tells the frontend which role it holds and the ACL is
 * per-file, so the denial is the only signal there is. Without a fallback the
 * whole Tachyon page renders empty for exactly the accounts that are supposed to
 * see it read-only.
 *
 * The fallback is sticky because the denial recurs on every call otherwise, and
 * write accounts must never enter that path: their first call succeeds.
 */

interface RpcResponse {
  stdout: string;
  stderr: string;
  code?: number;
}

const exec = vi.fn<(params: { command: string }) => Promise<RpcResponse>>();

/** rpcd's answer when the ACL withholds the file. */
const DENIED: RpcResponse = {
  stdout: '',
  stderr: 'Access denied',
  code: 1,
};

function ok(payload: unknown): RpcResponse {
  return { stdout: JSON.stringify(payload), stderr: '', code: 0 };
}

/** callBaseMethod keeps the chosen binary in module state; reset it per test. */
async function withFreshModule() {
  vi.resetModules();
  vi.doMock('../../../../helpers', () => ({ executeShellCommand: exec }));
  return import('../callBaseMethod');
}

describe('read-only fallback', () => {
  beforeEach(() => {
    exec.mockReset();
  });

  it('falls back to tachyon-read when rpcd denies the main binary', async () => {
    exec
      .mockResolvedValueOnce(DENIED)
      .mockResolvedValueOnce(ok({ version: '1.4.5' }));
    const { callBaseMethod: fresh } = await withFreshModule();

    const result = await fresh(Tachyon.AvailableMethods.SHOW_VERSION);

    expect(result).toEqual({ success: true, data: { version: '1.4.5' } });
    expect(exec.mock.calls[0]?.[0].command).toBe('/usr/bin/tachyon');
    expect(exec.mock.calls[1]?.[0].command).toBe('/usr/bin/tachyon-read');
  });

  it('stops calling the denied binary once the role is known', async () => {
    exec
      .mockResolvedValueOnce(DENIED)
      .mockResolvedValueOnce(ok({ first: true }))
      .mockResolvedValueOnce(ok({ second: true }));
    const { callBaseMethod: fresh } = await withFreshModule();

    await fresh(Tachyon.AvailableMethods.SHOW_VERSION);
    await fresh(Tachyon.AvailableMethods.CHECK_NFT);

    expect(exec).toHaveBeenCalledTimes(3);
    expect(exec.mock.calls[2]?.[0].command).toBe('/usr/bin/tachyon-read');
  });

  it('never falls back for a write account, whose first call is allowed', async () => {
    exec.mockResolvedValue(ok({ engine: 'sing-box' }));
    const { callBaseMethod: fresh } = await withFreshModule();

    await fresh(Tachyon.AvailableMethods.SERVICE_ACTION_ASYNC);
    await fresh(Tachyon.AvailableMethods.SHOW_VERSION);

    expect(exec).toHaveBeenCalledTimes(2);
    expect(
      exec.mock.calls.every(
        ([params]) => params.command === '/usr/bin/tachyon',
      ),
    ).toBe(true);
  });

  it('does not switch when the call failed for an unrelated reason', async () => {
    exec.mockResolvedValue({
      stdout: '',
      stderr: 'sing-box: config parse error',
      code: 1,
    });
    const { callBaseMethod: fresh } = await withFreshModule();

    const result = await fresh(Tachyon.AvailableMethods.SHOW_CONFIG);

    expect(result.success).toBe(false);
    expect(exec).toHaveBeenCalledTimes(1);
  });
});
