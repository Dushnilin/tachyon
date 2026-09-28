import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  executeShellCommand: vi.fn(),
}));

vi.mock('../../../helpers', () => ({
  executeShellCommand: mocks.executeShellCommand,
}));

import {
  stabilityClient,
  StabilityClient,
  type StabilityReport,
  type StabilityStatus,
} from '../stabilityClient';

describe('StabilityClient', () => {
  let client: StabilityClient;

  beforeEach(() => {
    vi.clearAllMocks();
    client = new StabilityClient('/usr/bin/tachyon');
  });

  describe('getReport', () => {
    it('returns parsed stability report on success', async () => {
      const mockReport: StabilityReport = {
        timestamp: 1790500000,
        health: {
          score: 100,
          grade: 'optimal',
          penalties: [],
        },
        uptimes: {
          system: { seconds: 3600, pretty: '1h' },
          daemons: {
            'sing-box': {
              running: true,
              pid: 1234,
              uptime_seconds: 3600,
              pretty: '1h',
            },
          },
        },
        restarts_and_flaps: {
          wan_flaps: 0,
          watchdog_restarts: 0,
          engine_crashes: 0,
          dnsmasq_restarts: 0,
          dns_failovers: 0,
          config_rollbacks: 0,
        },
        resources: {
          memory: {
            total_kb: 512000,
            free_kb: 256000,
            available_kb: 300000,
            used_kb: 212000,
            used_pct: 41,
            pressure_level: 'normal',
            swap_total_kb: 0,
            swap_free_kb: 0,
            swap_used_kb: 0,
            daemons_rss_kb: { 'sing-box': 50000 },
          },
          file_descriptors: {
            system_allocated: 500,
            system_max: 50000,
            system_used_pct: 1,
            daemons: { 'sing-box': 50 },
          },
          orphans: { count: 0, orphans: [] },
        },
        jobs: {
          total_jobs: 0,
          running_jobs: 0,
          failed_jobs: 0,
          cancelled_jobs: 0,
          last_failed_job: null,
        },
        server_fleet: {
          total_servers: 10,
          healthy_count: 8,
          unhealthy_count: 2,
          untested_count: 0,
          avg_latency_ms: 120,
          best_server: {
            tag: 'node-1',
            latency_ms: 80,
            section: 'Main',
            type: 'vless',
          },
          sections: { Main: 10 },
        },
        recent_incidents: [],
      };

      mocks.executeShellCommand.mockResolvedValueOnce({
        code: 0,
        stdout: JSON.stringify(mockReport),
        stderr: '',
      });

      const res = await client.getReport();
      expect(res).toEqual(mockReport);
      expect(mocks.executeShellCommand).toHaveBeenCalledWith({
        command: '/usr/bin/tachyon',
        args: ['stability_report'],
        timeout: 10000,
      });
    });

    it('returns null on failure or non-zero exit code', async () => {
      mocks.executeShellCommand.mockResolvedValueOnce({
        code: 1,
        stdout: '',
        stderr: 'error generating report',
      });

      const res = await client.getReport();
      expect(res).toBeNull();
    });

    it('returns null on thrown exception', async () => {
      mocks.executeShellCommand.mockRejectedValueOnce(
        new Error('Command timeout'),
      );

      const res = await client.getReport();
      expect(res).toBeNull();
    });
  });

  describe('getStatus', () => {
    it('returns parsed stability status on success', async () => {
      const mockStatus: StabilityStatus = {
        timestamp: 1790500000,
        score: 95,
        grade: 'optimal',
        system_uptime: '2d 5h',
        wan_flaps: 0,
        watchdog_restarts: 0,
        memory_used_pct: 35,
        memory_pressure: 'normal',
        healthy_servers: 15,
        total_servers: 20,
        avg_latency_ms: 130,
      };

      mocks.executeShellCommand.mockResolvedValueOnce({
        code: 0,
        stdout: JSON.stringify(mockStatus),
        stderr: '',
      });

      const res = await client.getStatus();
      expect(res).toEqual(mockStatus);
      expect(mocks.executeShellCommand).toHaveBeenCalledWith({
        command: '/usr/bin/tachyon',
        args: ['stability_status'],
        timeout: 5000,
      });
    });

    it('returns null on failure', async () => {
      mocks.executeShellCommand.mockResolvedValueOnce({
        code: 1,
        stdout: '',
        stderr: 'failed to read status',
      });

      const res = await client.getStatus();
      expect(res).toBeNull();
    });
  });

  describe('singleton export', () => {
    it('exports a ready-to-use stabilityClient instance', () => {
      expect(stabilityClient).toBeInstanceOf(StabilityClient);
    });
  });
});
