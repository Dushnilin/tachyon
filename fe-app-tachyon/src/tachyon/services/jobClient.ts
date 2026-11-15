import { executeShellCommand } from '../../helpers';
import { logger } from './logger.service';

export type TachyonJobPhase =
  | 'pending'
  | 'queued'
  | 'preflight'
  | 'running'
  | 'verifying'
  | 'rollback'
  | 'success'
  | 'failure'
  | 'cancelled'
  | 'timed_out';

export interface TachyonJob {
  id: string;
  kind?: string;
  action?: string;
  phase: TachyonJobPhase;
  target?: string;
  progress?: number;
  message?: string;
  error?: string;
  created_at?: number;
  started_at?: number;
  finished_at?: number;
  cancel_requested?: boolean;
  cancel_reason?: string | null;
  cancel_requested_at?: number | null;
  cancelled_at?: number | null;
  cancel_forced?: boolean;
  in_critical_section?: boolean;
  critical_section_name?: string | null;
  critical_section_entered_at?: number | null;
  safe_point_reached?: boolean;
  rolled_back?: boolean;
  rollback_error?: string | null;
  result?: Record<string, unknown>;
  metadata?: Record<string, unknown>;
}

export interface JobCancelResult {
  ok: boolean;
  message?: string;
  forced?: boolean;
  deferred?: boolean;
}

export interface JobRequestCancelResult {
  ok: boolean;
  requested?: boolean;
  message?: string;
}

export interface JobGcResult {
  ok: boolean;
  removed?: number;
}

export interface WatchJobOptions {
  pollIntervalMs?: number;
  timeoutMs?: number;
  signal?: AbortSignal;
  onProgress?: (job: TachyonJob) => void;
}

export function isJobActive(job: Pick<TachyonJob, 'phase'>): boolean {
  return [
    'pending',
    'queued',
    'preflight',
    'running',
    'verifying',
    'rollback',
  ].includes(job.phase);
}

export function isJobTerminal(job: Pick<TachyonJob, 'phase'>): boolean {
  return ['success', 'failure', 'cancelled', 'timed_out'].includes(job.phase);
}

export function isJobSuccessful(job: Pick<TachyonJob, 'phase'>): boolean {
  return job.phase === 'success';
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
    logger.warn('[JOB_CLIENT] Failed to parse JSON stdout:', err);
    return fallback;
  }
}

export class JobClient {
  private readonly binaryPath: string;

  constructor(binaryPath = '/usr/bin/tachyon') {
    this.binaryPath = binaryPath;
  }

  async list(options?: { all?: boolean }): Promise<TachyonJob[]> {
    const args = ['job_list', '--json'];
    if (options?.all) {
      args.push('--all');
    }

    try {
      const res = await executeShellCommand({
        command: this.binaryPath,
        args,
        timeout: 10000,
      });

      if ((res.code ?? 0) !== 0) {
        logger.error(
          '[JOB_CLIENT] list failed with code',
          res.code,
          res.stderr,
        );
        return [];
      }

      return parseJsonStdout<TachyonJob[]>(res.stdout, []);
    } catch (err) {
      logger.error('[JOB_CLIENT] list exception:', err);
      return [];
    }
  }

  async query(jobId: string): Promise<TachyonJob | null> {
    if (!jobId) return null;

    try {
      const res = await executeShellCommand({
        command: this.binaryPath,
        args: ['job_query', jobId],
        timeout: 10000,
      });

      if ((res.code ?? 0) !== 0) {
        return null;
      }

      const job = parseJsonStdout<TachyonJob | null>(res.stdout, null);
      return job && job.id ? job : null;
    } catch (err) {
      logger.error('[JOB_CLIENT] query exception:', err);
      return null;
    }
  }

  async cancel(
    jobId: string,
    options?: { force?: boolean; reason?: string },
  ): Promise<JobCancelResult> {
    if (!jobId) {
      return { ok: false, message: 'Missing job ID' };
    }

    const args = ['job_cancel', jobId];
    if (options?.force) {
      args.push('--force');
    }
    if (options?.reason) {
      args.push(options.reason);
    }

    try {
      const res = await executeShellCommand({
        command: this.binaryPath,
        args,
        timeout: 10000,
      });

      const parsed = parseJsonStdout<Record<string, unknown>>(res.stdout, {});
      const ok = (res.code ?? 0) === 0 || parsed.ok === true;

      return {
        ok,
        message:
          typeof parsed.message === 'string'
            ? parsed.message
            : res.stderr || undefined,
        forced: Boolean(parsed.forced ?? options?.force),
        deferred: Boolean(parsed.deferred),
      };
    } catch (err) {
      logger.error('[JOB_CLIENT] cancel exception:', err);
      return {
        ok: false,
        message: err instanceof Error ? err.message : String(err),
      };
    }
  }

  async requestCancel(
    jobId: string,
    reason?: string,
  ): Promise<JobRequestCancelResult> {
    if (!jobId) {
      return { ok: false, requested: false, message: 'Missing job ID' };
    }

    const args = ['job_request_cancel', jobId];
    if (reason) {
      args.push(reason);
    }

    try {
      const res = await executeShellCommand({
        command: this.binaryPath,
        args,
        timeout: 10000,
      });

      const parsed = parseJsonStdout<Record<string, unknown>>(res.stdout, {});
      const ok = (res.code ?? 0) === 0 || parsed.ok === true;

      return {
        ok,
        requested: Boolean(parsed.requested ?? ok),
        message:
          typeof parsed.message === 'string'
            ? parsed.message
            : res.stderr || undefined,
      };
    } catch (err) {
      logger.error('[JOB_CLIENT] requestCancel exception:', err);
      return {
        ok: false,
        requested: false,
        message: err instanceof Error ? err.message : String(err),
      };
    }
  }

  async gc(): Promise<JobGcResult> {
    try {
      const res = await executeShellCommand({
        command: this.binaryPath,
        args: ['job_gc'],
        timeout: 10000,
      });

      const parsed = parseJsonStdout<Record<string, unknown>>(res.stdout, {});
      const ok = (res.code ?? 0) === 0;

      return {
        ok,
        removed:
          typeof parsed.removed === 'number' ? parsed.removed : undefined,
      };
    } catch (err) {
      logger.error('[JOB_CLIENT] gc exception:', err);
      return { ok: false };
    }
  }

  async watch(
    jobId: string,
    options: WatchJobOptions = {},
  ): Promise<TachyonJob> {
    const {
      pollIntervalMs = 500,
      timeoutMs = 60000,
      signal,
      onProgress,
    } = options;

    const startTime = Date.now();

    return new Promise<TachyonJob>((resolve, reject) => {
      let isSettled = false;
      let timer: ReturnType<typeof setTimeout> | null = null;

      const cleanup = () => {
        if (timer) {
          clearTimeout(timer);
          timer = null;
        }
        if (signal) {
          signal.removeEventListener('abort', onAbort);
        }
      };

      const onAbort = () => {
        if (isSettled) return;
        isSettled = true;
        cleanup();
        reject(new Error('Job watch aborted by caller'));
      };

      if (signal) {
        if (signal.aborted) {
          reject(new Error('Job watch aborted by caller'));
          return;
        }
        signal.addEventListener('abort', onAbort);
      }

      const poll = async () => {
        if (isSettled) return;

        if (Date.now() - startTime > timeoutMs) {
          isSettled = true;
          cleanup();
          reject(
            new Error(
              `Job watch timed out after ${timeoutMs}ms for job: ${jobId}`,
            ),
          );
          return;
        }

        try {
          const job = await this.query(jobId);

          if (!job) {
            isSettled = true;
            cleanup();
            reject(new Error(`Job ${jobId} not found`));
            return;
          }

          if (onProgress) {
            try {
              onProgress(job);
            } catch (err) {
              logger.warn('[JOB_CLIENT] onProgress handler threw error:', err);
            }
          }

          if (isJobTerminal(job)) {
            isSettled = true;
            cleanup();
            resolve(job);
            return;
          }

          if (!isSettled) {
            timer = setTimeout(poll, pollIntervalMs);
          }
        } catch (err) {
          isSettled = true;
          cleanup();
          reject(err);
        }
      };

      void poll();
    });
  }
}

export const jobClient = new JobClient();
