import { executeShellCommand } from '../../helpers';
import { logger } from './logger.service';

export interface ServerMetricEntry {
  tag: string;
  name: string;
  type: string;
  section: string;
  last_status: 'ok' | 'error' | 'untested';
  last_latency: number;
  last_checked: number;
  last_error: string;
  total_probes: number;
  successful_probes: number;
  failed_probes: number;
  consecutive_failures: number;
  avg_latency: number;
  min_latency: number | null;
  max_latency: number | null;
  jitter: number;
  success_rate: number;
}

export interface ServerStatsSummary {
  total_servers: number;
  healthy_count: number;
  unhealthy_count: number;
  untested_count: number;
  avg_latency_ms: number;
  best_server: {
    tag: string;
    latency_ms: number;
    section: string;
    type: string;
  } | null;
  worst_server: {
    tag: string;
    latency_ms: number;
    section: string;
    type: string;
  } | null;
  sections: Record<string, number>;
  protocols: Record<string, number>;
  last_updated: number;
  servers: ServerMetricEntry[];
}

export interface ServerProbeResult {
  tag: string;
  status: 'ok' | 'error' | 'untested';
  latency_ms: number;
  avg_latency_ms: number;
  success_rate: number;
  error: string;
}

export interface ServerProbeAllSummary {
  total_probed: number;
  successful: number;
  failed: number;
  results: Array<{
    tag: string;
    section: string;
    type: string;
    ok: boolean;
    latency_ms: number;
    error: string;
  }>;
}

export interface ServerStatsFilter {
  section?: string;
  status?: 'ok' | 'error' | 'untested' | string;
  type?: string;
  max_latency?: number;
}

function parseJsonStdout<T>(stdout: string, fallback: T): T {
  if (!stdout) return fallback;
  try {
    let text = stdout.trim();
    const match = text.match(/(\{[\s\S]*\}|\[[\s\S]*\])/);
    if (match) {
      text = match[0];
    }
    return JSON.parse(text) as T;
  } catch (err) {
    logger.warn('[SERVER_STATS_CLIENT] Failed to parse JSON stdout:', err);
    return fallback;
  }
}

export class ServerStatsClient {
  private readonly binaryPath: string;

  constructor(binaryPath = '/usr/bin/tachyon') {
    this.binaryPath = binaryPath;
  }

  async getSummary(): Promise<ServerStatsSummary | null> {
    try {
      const res = await executeShellCommand({
        command: this.binaryPath,
        args: ['server_stats'],
        timeout: 10000,
      });

      if (res.code === 0 && res.stdout) {
        return parseJsonStdout<ServerStatsSummary | null>(res.stdout, null);
      }
      return null;
    } catch (err) {
      logger.error('[SERVER_STATS_CLIENT] getSummary error:', err);
      return null;
    }
  }

  async probe(
    tag: string,
    timeoutMs = 3000,
  ): Promise<ServerProbeResult | null> {
    if (!tag) return null;
    try {
      const res = await executeShellCommand({
        command: this.binaryPath,
        args: ['server_probe', tag, String(timeoutMs)],
        timeout: timeoutMs + 2000,
      });

      if (res.code === 0 && res.stdout) {
        return parseJsonStdout<ServerProbeResult | null>(res.stdout, null);
      }
      return null;
    } catch (err) {
      logger.error('[SERVER_STATS_CLIENT] probe error:', err);
      return null;
    }
  }

  async probeAll(
    section = 'all',
    timeoutMs = 3000,
  ): Promise<ServerProbeAllSummary | null> {
    try {
      const res = await executeShellCommand({
        command: this.binaryPath,
        args: ['server_probe_all', section, String(timeoutMs)],
        timeout: 60000,
      });

      if (res.code === 0 && res.stdout) {
        return parseJsonStdout<ServerProbeAllSummary | null>(res.stdout, null);
      }
      return null;
    } catch (err) {
      logger.error('[SERVER_STATS_CLIENT] probeAll error:', err);
      return null;
    }
  }

  async getBestCandidates(
    section = 'all',
    limit = 5,
  ): Promise<ServerMetricEntry[]> {
    try {
      const res = await executeShellCommand({
        command: this.binaryPath,
        args: ['server_best', section, String(limit)],
        timeout: 5000,
      });

      if (res.code === 0 && res.stdout) {
        return parseJsonStdout<ServerMetricEntry[]>(res.stdout, []);
      }
      return [];
    } catch (err) {
      logger.error('[SERVER_STATS_CLIENT] getBestCandidates error:', err);
      return [];
    }
  }

  async query(filter?: ServerStatsFilter): Promise<ServerMetricEntry[]> {
    try {
      const filterArg = filter ? JSON.stringify(filter) : '{}';
      const res = await executeShellCommand({
        command: this.binaryPath,
        args: ['server_query', filterArg],
        timeout: 5000,
      });

      if (res.code === 0 && res.stdout) {
        return parseJsonStdout<ServerMetricEntry[]>(res.stdout, []);
      }
      return [];
    } catch (err) {
      logger.error('[SERVER_STATS_CLIENT] query error:', err);
      return [];
    }
  }

  async reset(): Promise<boolean> {
    try {
      const res = await executeShellCommand({
        command: this.binaryPath,
        args: ['server_stats_reset'],
        timeout: 5000,
      });
      return res.code === 0;
    } catch (err) {
      logger.error('[SERVER_STATS_CLIENT] reset error:', err);
      return false;
    }
  }
}

export const serverStatsClient = new ServerStatsClient();
