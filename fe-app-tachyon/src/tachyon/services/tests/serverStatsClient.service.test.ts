import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  executeShellCommand: vi.fn(),
}));

vi.mock('../../../helpers', () => ({
  executeShellCommand: mocks.executeShellCommand,
}));

import {
  serverStatsClient,
  ServerStatsClient,
  type ServerMetricEntry,
  type ServerStatsSummary,
} from '../serverStatsClient';

describe('ServerStatsClient', () => {
  let client: ServerStatsClient;

  beforeEach(() => {
    vi.clearAllMocks();
    client = new ServerStatsClient('/usr/bin/tachyon');
  });

  describe('getSummary', () => {
    it('returns parsed summary on success', async () => {
      const mockSummary: ServerStatsSummary = {
        total_servers: 2,
        healthy_count: 1,
        unhealthy_count: 1,
        untested_count: 0,
        avg_latency_ms: 150,
        best_server: {
          tag: 'server-1',
          latency_ms: 150,
          section: 'Main',
          type: 'vless',
        },
        worst_server: {
          tag: 'server-2',
          latency_ms: 500,
          section: 'Main',
          type: 'hysteria2',
        },
        sections: { Main: 2 },
        protocols: { vless: 1, hysteria2: 1 },
        last_updated: 1790500000,
        servers: [
          {
            tag: 'server-1',
            name: 'server-1',
            type: 'vless',
            section: 'Main',
            last_status: 'ok',
            last_latency: 150,
            last_checked: 1790500000,
            last_error: '',
            total_probes: 5,
            successful_probes: 5,
            failed_probes: 0,
            consecutive_failures: 0,
            avg_latency: 150,
            min_latency: 120,
            max_latency: 180,
            jitter: 10,
            success_rate: 100,
          },
        ],
      };

      mocks.executeShellCommand.mockResolvedValueOnce({
        code: 0,
        stdout: JSON.stringify(mockSummary),
        stderr: '',
      });

      const res = await client.getSummary();
      expect(res).toEqual(mockSummary);
      expect(mocks.executeShellCommand).toHaveBeenCalledWith({
        command: '/usr/bin/tachyon',
        args: ['server_stats'],
        timeout: 10000,
      });
    });

    it('returns null on command failure or non-zero exit code', async () => {
      mocks.executeShellCommand.mockResolvedValueOnce({
        code: 1,
        stdout: '',
        stderr: 'failed to read stats',
      });

      const res = await client.getSummary();
      expect(res).toBeNull();
    });

    it('returns null on thrown exception', async () => {
      mocks.executeShellCommand.mockRejectedValueOnce(
        new Error('Process timeout'),
      );

      const res = await client.getSummary();
      expect(res).toBeNull();
    });
  });

  describe('probe', () => {
    it('returns null if tag is empty', async () => {
      const res = await client.probe('');
      expect(res).toBeNull();
      expect(mocks.executeShellCommand).not.toHaveBeenCalled();
    });

    it('executes probe command and returns latency result', async () => {
      const mockResult = {
        tag: 'server-1',
        status: 'ok',
        latency_ms: 120,
        avg_latency_ms: 120,
        success_rate: 100,
        error: '',
      };

      mocks.executeShellCommand.mockResolvedValueOnce({
        code: 0,
        stdout: JSON.stringify(mockResult),
        stderr: '',
      });

      const res = await client.probe('server-1', 2500);
      expect(res).toEqual(mockResult);
      expect(mocks.executeShellCommand).toHaveBeenCalledWith({
        command: '/usr/bin/tachyon',
        args: ['server_probe', 'server-1', '2500'],
        timeout: 4500,
      });
    });
  });

  describe('probeAll', () => {
    it('probes all servers in target section', async () => {
      const mockResult = {
        total_probed: 3,
        successful: 2,
        failed: 1,
        results: [
          {
            tag: 'node-1',
            section: 'Main',
            type: 'vless',
            ok: true,
            latency_ms: 110,
            error: '',
          },
        ],
      };

      mocks.executeShellCommand.mockResolvedValueOnce({
        code: 0,
        stdout: JSON.stringify(mockResult),
        stderr: '',
      });

      const res = await client.probeAll('Main', 3000);
      expect(res).toEqual(mockResult);
      expect(mocks.executeShellCommand).toHaveBeenCalledWith({
        command: '/usr/bin/tachyon',
        args: ['server_probe_all', 'Main', '3000'],
        timeout: 60000,
      });
    });
  });

  describe('getBestCandidates', () => {
    it('fetches top ranked server candidates', async () => {
      const mockCandidates: ServerMetricEntry[] = [
        {
          tag: 'node-fast',
          name: 'Fast Node',
          type: 'vless',
          section: 'Main',
          last_status: 'ok',
          last_latency: 80,
          last_checked: 1790500000,
          last_error: '',
          total_probes: 10,
          successful_probes: 10,
          failed_probes: 0,
          consecutive_failures: 0,
          avg_latency: 80,
          min_latency: 75,
          max_latency: 90,
          jitter: 5,
          success_rate: 100,
        },
      ];

      mocks.executeShellCommand.mockResolvedValueOnce({
        code: 0,
        stdout: JSON.stringify(mockCandidates),
        stderr: '',
      });

      const res = await client.getBestCandidates('Main', 3);
      expect(res).toEqual(mockCandidates);
      expect(mocks.executeShellCommand).toHaveBeenCalledWith({
        command: '/usr/bin/tachyon',
        args: ['server_best', 'Main', '3'],
        timeout: 5000,
      });
    });
  });

  describe('query', () => {
    it('queries servers with filter', async () => {
      const mockServers: ServerMetricEntry[] = [];
      mocks.executeShellCommand.mockResolvedValueOnce({
        code: 0,
        stdout: JSON.stringify(mockServers),
        stderr: '',
      });

      const res = await client.query({ status: 'ok', max_latency: 200 });
      expect(res).toEqual(mockServers);
      expect(mocks.executeShellCommand).toHaveBeenCalledWith({
        command: '/usr/bin/tachyon',
        args: [
          'server_query',
          JSON.stringify({ status: 'ok', max_latency: 200 }),
        ],
        timeout: 5000,
      });
    });
  });

  describe('reset', () => {
    it('resets server statistics successfully', async () => {
      mocks.executeShellCommand.mockResolvedValueOnce({
        code: 0,
        stdout: JSON.stringify({ ok: true }),
        stderr: '',
      });

      const res = await client.reset();
      expect(res).toBe(true);
    });
  });

  describe('singleton export', () => {
    it('exports a ready-to-use serverStatsClient instance', () => {
      expect(serverStatsClient).toBeInstanceOf(ServerStatsClient);
    });
  });
});
