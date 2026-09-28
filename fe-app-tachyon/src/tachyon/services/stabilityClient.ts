import { executeShellCommand } from '../../helpers';
import { logger } from './logger.service';

export interface StabilityScore {
  score: number;
  grade: 'optimal' | 'healthy' | 'degraded' | 'critical' | string;
  penalties: string[];
}

export interface DaemonUptimeInfo {
  running: boolean;
  pid: number | null;
  uptime_seconds: number;
  pretty: string;
}

export interface UptimesReport {
  system: {
    seconds: number;
    pretty: string;
  };
  daemons: Record<string, DaemonUptimeInfo>;
}

export interface RestartsAndFlapsReport {
  wan_flaps: number;
  watchdog_restarts: number;
  engine_crashes: number;
  dnsmasq_restarts: number;
  dns_failovers: number;
  config_rollbacks: number;
}

export interface MemoryPressureReport {
  total_kb: number;
  free_kb: number;
  available_kb: number;
  used_kb: number;
  used_pct: number;
  pressure_level: 'normal' | 'warning' | 'critical' | string;
  swap_total_kb: number;
  swap_free_kb: number;
  swap_used_kb: number;
  daemons_rss_kb: Record<string, number>;
}

export interface FileDescriptorsReport {
  system_allocated: number;
  system_max: number;
  system_used_pct: number;
  daemons: Record<string, number>;
}

export interface OrphansReport {
  count: number;
  orphans: Array<{ pid: number; comm: string; ppid: number }>;
}

export interface StabilityIncident {
  time: number;
  source: string;
  severity: string;
  title: string;
  message: string;
}

export interface ServerFleetStability {
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
  sections: Record<string, number>;
}

export interface JobsStabilityReport {
  total_jobs: number;
  running_jobs: number;
  failed_jobs: number;
  cancelled_jobs: number;
  last_failed_job: unknown;
}

export interface StabilityReport {
  timestamp: number;
  health: StabilityScore;
  uptimes: UptimesReport;
  restarts_and_flaps: RestartsAndFlapsReport;
  resources: {
    memory: MemoryPressureReport;
    file_descriptors: FileDescriptorsReport;
    orphans: OrphansReport;
  };
  jobs: JobsStabilityReport;
  server_fleet: ServerFleetStability;
  recent_incidents: StabilityIncident[];
}

export interface StabilityStatus {
  timestamp: number;
  score: number;
  grade: 'optimal' | 'healthy' | 'degraded' | 'critical' | string;
  system_uptime: string;
  wan_flaps: number;
  watchdog_restarts: number;
  memory_used_pct: number;
  memory_pressure: string;
  healthy_servers: number;
  total_servers: number;
  avg_latency_ms: number;
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
    logger.warn('[STABILITY_CLIENT] Failed to parse JSON stdout:', err);
    return fallback;
  }
}

export class StabilityClient {
  private readonly binaryPath: string;

  constructor(binaryPath = '/usr/bin/tachyon') {
    this.binaryPath = binaryPath;
  }

  async getReport(): Promise<StabilityReport | null> {
    try {
      const res = await executeShellCommand({
        command: this.binaryPath,
        args: ['stability_report'],
        timeout: 10000,
      });

      if (res.code === 0 && res.stdout) {
        return parseJsonStdout<StabilityReport | null>(res.stdout, null);
      }
      return null;
    } catch (err) {
      logger.error('[STABILITY_CLIENT] getReport error:', err);
      return null;
    }
  }

  async getStatus(): Promise<StabilityStatus | null> {
    try {
      const res = await executeShellCommand({
        command: this.binaryPath,
        args: ['stability_status'],
        timeout: 5000,
      });

      if (res.code === 0 && res.stdout) {
        return parseJsonStdout<StabilityStatus | null>(res.stdout, null);
      }
      return null;
    } catch (err) {
      logger.error('[STABILITY_CLIENT] getStatus error:', err);
      return null;
    }
  }
}

export const stabilityClient = new StabilityClient();
