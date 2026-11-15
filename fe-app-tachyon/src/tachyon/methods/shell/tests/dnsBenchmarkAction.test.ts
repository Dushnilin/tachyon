import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  executeShellCommand: vi.fn(),
}));

vi.mock('../../../../helpers', () => ({
  executeShellCommand: mocks.executeShellCommand,
}));

import { TachyonShellMethods } from '../index';

describe('TachyonShellMethods DNS Benchmark Actions', () => {
  beforeEach(() => {
    mocks.executeShellCommand.mockReset();
  });

  afterEach(() => {
    vi.clearAllMocks();
  });

  it('starts DNS benchmark asynchronously', async () => {
    mocks.executeShellCommand.mockResolvedValueOnce({
      stdout: JSON.stringify({
        success: true,
        message: 'DNS benchmark started',
        running: true,
      }),
      stderr: '',
      code: 0,
    });

    const res = await TachyonShellMethods.startDnsBenchmark();
    expect(res.success).toBe(true);
    if (res.success) {
      expect(res.data.running).toBe(true);
      expect(res.data.message).toBe('DNS benchmark started');
    }
    expect(mocks.executeShellCommand).toHaveBeenCalledWith(
      expect.objectContaining({
        args: ['dns_benchmark_async'],
      }),
    );
  });

  it('handles start DNS benchmark failure', async () => {
    mocks.executeShellCommand.mockResolvedValueOnce({
      stdout: JSON.stringify({
        success: false,
        error: 'Failed to fork background worker',
      }),
      stderr: '',
      code: 1,
    });

    const res = await TachyonShellMethods.startDnsBenchmark();
    expect(res.success).toBe(false);
    if (!res.success) {
      expect(res.error).toBe('Failed to fork background worker');
    }
  });

  it('retrieves DNS benchmark status and results', async () => {
    const mockState = {
      running: false,
      progress: 100,
      current_server: 'Completed',
      results: [
        {
          id: 'yandex_udp',
          provider: 'Yandex',
          type: 'udp',
          address: '77.88.8.8',
          ip: '77.88.8.8',
          tag: 'Primary',
          latency: 12,
          lossPct: 0,
          status: 'excellent',
          score: 12,
        },
        {
          id: 'cloudflare_doh',
          provider: 'Cloudflare',
          type: 'doh',
          address: 'https://cloudflare-dns.com/dns-query',
          ip: '1.1.1.1',
          tag: 'DoH Encrypted',
          latency: 24,
          lossPct: 0,
          status: 'excellent',
          score: 24,
        },
      ],
      recommendation: {
        dns_type: 'doh',
        dns_server: ['https://cloudflare-dns.com/dns-query'],
        bootstrap_dns_server: ['77.88.8.8'],
        dns_fallback_server: ['1.1.1.1'],
        dns_upstream_mode: 'parallel',
        reason: 'Selected fast encrypted DoH for privacy',
      },
      error: null,
      started_at: 1725280000,
      finished_at: 1725280015,
    };

    mocks.executeShellCommand.mockResolvedValueOnce({
      stdout: JSON.stringify(mockState),
      stderr: '',
      code: 0,
    });

    const res = await TachyonShellMethods.getDnsBenchmarkStatus();
    expect(res.success).toBe(true);
    if (res.success) {
      expect(res.data.progress).toBe(100);
      expect(res.data.results).toHaveLength(2);
      expect(res.data.recommendation?.dns_type).toBe('doh');
    }
    expect(mocks.executeShellCommand).toHaveBeenCalledWith(
      expect.objectContaining({
        args: ['dns_benchmark_status'],
      }),
    );
  });

  it('stops running DNS benchmark', async () => {
    mocks.executeShellCommand.mockResolvedValueOnce({
      stdout: JSON.stringify({ success: true, message: 'Benchmark stopped' }),
      stderr: '',
      code: 0,
    });

    const res = await TachyonShellMethods.stopDnsBenchmark();
    expect(res.success).toBe(true);
    expect(mocks.executeShellCommand).toHaveBeenCalledWith(
      expect.objectContaining({
        args: ['dns_benchmark_stop'],
      }),
    );
  });

  it('applies DNS benchmark recommendation', async () => {
    mocks.executeShellCommand.mockResolvedValueOnce({
      stdout: JSON.stringify({
        success: true,
        message: 'Recommended DNS configuration applied and service restarted',
        recommendation: {
          dns_type: 'doh',
          dns_server: ['https://common.dot.dns.yandex.net/dns-query'],
          bootstrap_dns_server: ['77.88.8.8'],
          dns_fallback_server: ['1.1.1.1'],
          dns_upstream_mode: 'parallel',
        },
      }),
      stderr: '',
      code: 0,
    });

    const res = await TachyonShellMethods.applyDnsBenchmark();
    expect(res.success).toBe(true);
    if (res.success) {
      expect(res.data.recommendation?.dns_server).toContain(
        'https://common.dot.dns.yandex.net/dns-query',
      );
    }
    expect(mocks.executeShellCommand).toHaveBeenCalledWith(
      expect.objectContaining({
        args: ['dns_benchmark_apply'],
      }),
    );
  });
});
