import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  executeShellCommand: vi.fn(),
}));

vi.mock('../../../../helpers', () => ({
  executeShellCommand: mocks.executeShellCommand,
  extractLastJsonValue: (raw: string) => {
    try {
      return JSON.parse(raw);
    } catch {
      return null;
    }
  },
}));

import { TachyonShellMethods } from '../index';

describe('TachyonShellMethods ui-state fallback paths', () => {
  beforeEach(() => {
    mocks.executeShellCommand.mockReset();
    mocks.executeShellCommand.mockResolvedValue({
      stdout: '',
      stderr: 'truncated',
      code: 1,
    });
  });

  it('reads clash-proxies.json from /tmp/tachyon-rs/ui-state before /var/run/tachyon/ui-state', async () => {
    const readPaths: string[] = [];
    vi.stubGlobal('fs', {
      read: vi.fn(async (path: string) => {
        readPaths.push(path);
        if (path === '/tmp/tachyon-rs/ui-state/clash-proxies.json') {
          return JSON.stringify({
            proxies: {
              'main-1': {
                type: 'VLESS',
                name: 'Node 1',
                udp: true,
                history: [],
              },
            },
          });
        }
        throw new Error('not found');
      }),
    });

    const res = await TachyonShellMethods.getClashApiProxies();

    expect(res.success).toBe(true);
    expect(readPaths).toEqual(['/tmp/tachyon-rs/ui-state/clash-proxies.json']);
  });

  it('falls back to /var/run/tachyon/ui-state/clash-proxies.json when /tmp/tachyon-rs copy is absent', async () => {
    const readPaths: string[] = [];
    vi.stubGlobal('fs', {
      read: vi.fn(async (path: string) => {
        readPaths.push(path);
        if (path === '/var/run/tachyon/ui-state/clash-proxies.json') {
          return JSON.stringify({
            proxies: {
              'main-2': {
                type: 'VLESS',
                name: 'Node 2',
                udp: true,
                history: [],
              },
            },
          });
        }
        throw new Error('ENOENT');
      }),
    });

    const res = await TachyonShellMethods.getClashApiProxies();

    expect(res.success).toBe(true);
    expect(readPaths).toEqual([
      '/tmp/tachyon-rs/ui-state/clash-proxies.json',
      '/var/run/tachyon/ui-state/clash-proxies.json',
    ]);
  });

  it('reads clash-connections.json from /tmp/tachyon-rs/ui-state before /var/run/tachyon/ui-state', async () => {
    const readPaths: string[] = [];
    vi.stubGlobal('fs', {
      read: vi.fn(async (path: string) => {
        readPaths.push(path);
        if (path === '/tmp/tachyon-rs/ui-state/clash-connections.json') {
          return JSON.stringify({ connections: [{ id: 'c1' }] });
        }
        throw new Error('not found');
      }),
    });

    const res = await TachyonShellMethods.getClashApiConnections();

    expect(res.success).toBe(true);
    expect(readPaths).toEqual([
      '/tmp/tachyon-rs/ui-state/clash-connections.json',
    ]);
  });

  it('falls back to /var/run/tachyon/ui-state/clash-connections.json when /tmp/tachyon-rs copy is absent', async () => {
    const readPaths: string[] = [];
    vi.stubGlobal('fs', {
      read: vi.fn(async (path: string) => {
        readPaths.push(path);
        if (path === '/var/run/tachyon/ui-state/clash-connections.json') {
          return JSON.stringify({ connections: [{ id: 'c2' }] });
        }
        throw new Error('ENOENT');
      }),
    });

    const res = await TachyonShellMethods.getClashApiConnections();

    expect(res.success).toBe(true);
    expect(readPaths).toEqual([
      '/tmp/tachyon-rs/ui-state/clash-connections.json',
      '/var/run/tachyon/ui-state/clash-connections.json',
    ]);
  });
});
