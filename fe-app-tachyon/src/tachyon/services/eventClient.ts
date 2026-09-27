import { executeShellCommand } from '../../helpers';
import { logger } from './logger.service';

export type EventSeverity = 'debug' | 'info' | 'warn' | 'error' | 'fatal';

export interface TachyonEvent {
  id?: string;
  ts: number;
  ms?: number;
  event: string;
  severity: EventSeverity;
  source: string;
  job_id?: string;
  correlation_id?: string;
  message?: string;
  data?: Record<string, unknown>;
}

export interface EventFilter {
  event?: string;
  severity?: EventSeverity | string;
  source?: string;
  job_id?: string;
  since_ts?: number;
  limit?: number;
}

export interface EventJournalStats {
  count: number;
  bytes: number;
  oldest_ts?: number;
  newest_ts?: number;
}

export interface EventRecordMeta {
  severity?: EventSeverity;
  source?: string;
  message?: string;
  job_id?: string;
  correlation_id?: string;
}

export interface PollEventsOptions {
  onEvent: (event: TachyonEvent) => void;
  onError?: (error: unknown) => void;
  filter?: EventFilter;
  intervalMs?: number;
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
    logger.warn('[EVENT_CLIENT] Failed to parse JSON stdout:', err);
    return fallback;
  }
}

export class EventClient {
  private readonly binaryPath: string;

  constructor(binaryPath = '/usr/bin/tachyon') {
    this.binaryPath = binaryPath;
  }

  async query(filter: EventFilter = {}): Promise<TachyonEvent[]> {
    try {
      const filterJson = JSON.stringify(filter);
      const res = await executeShellCommand({
        command: this.binaryPath,
        args: ['event_query', filterJson],
        timeout: 10000,
      });

      if ((res.code ?? 0) !== 0) {
        logger.error(
          '[EVENT_CLIENT] query failed with code',
          res.code,
          res.stderr,
        );
        return [];
      }

      return parseJsonStdout<TachyonEvent[]>(res.stdout, []);
    } catch (err) {
      logger.error('[EVENT_CLIENT] query exception:', err);
      return [];
    }
  }

  async tail(count = 10): Promise<TachyonEvent[]> {
    try {
      const res = await executeShellCommand({
        command: this.binaryPath,
        args: ['event_tail', String(count)],
        timeout: 10000,
      });

      if ((res.code ?? 0) !== 0) {
        logger.error(
          '[EVENT_CLIENT] tail failed with code',
          res.code,
          res.stderr,
        );
        return [];
      }

      return parseJsonStdout<TachyonEvent[]>(res.stdout, []);
    } catch (err) {
      logger.error('[EVENT_CLIENT] tail exception:', err);
      return [];
    }
  }

  async stats(): Promise<EventJournalStats> {
    try {
      const res = await executeShellCommand({
        command: this.binaryPath,
        args: ['event_stats'],
        timeout: 10000,
      });

      if ((res.code ?? 0) !== 0) {
        logger.error(
          '[EVENT_CLIENT] stats failed with code',
          res.code,
          res.stderr,
        );
        return { count: 0, bytes: 0 };
      }

      return parseJsonStdout<EventJournalStats>(res.stdout, {
        count: 0,
        bytes: 0,
      });
    } catch (err) {
      logger.error('[EVENT_CLIENT] stats exception:', err);
      return { count: 0, bytes: 0 };
    }
  }

  async clear(): Promise<boolean> {
    try {
      const res = await executeShellCommand({
        command: this.binaryPath,
        args: ['event_clear'],
        timeout: 10000,
      });

      return (res.code ?? 0) === 0;
    } catch (err) {
      logger.error('[EVENT_CLIENT] clear exception:', err);
      return false;
    }
  }

  async record(
    event: string,
    data: Record<string, unknown> = {},
    meta: EventRecordMeta = {},
  ): Promise<TachyonEvent | null> {
    if (!event) return null;

    const dataJson = JSON.stringify(data);
    const severity = meta.severity || 'info';
    const source = meta.source || 'tachyon';
    const message = meta.message || '';

    try {
      const res = await executeShellCommand({
        command: this.binaryPath,
        args: ['event_record', event, dataJson, severity, source, message],
        timeout: 10000,
      });

      if ((res.code ?? 0) !== 0) {
        logger.error(
          '[EVENT_CLIENT] record failed with code',
          res.code,
          res.stderr,
        );
        return null;
      }

      return parseJsonStdout<TachyonEvent | null>(res.stdout, null);
    } catch (err) {
      logger.error('[EVENT_CLIENT] record exception:', err);
      return null;
    }
  }

  poll(options: PollEventsOptions): () => void {
    const { onEvent, onError, filter = {}, intervalMs = 2000 } = options;

    let stopped = false;
    let timer: ReturnType<typeof setTimeout> | null = null;
    let lastSeenTs = filter.since_ts ?? Math.floor(Date.now() / 1000);
    const seenIds = new Set<string>();

    const pollStep = async () => {
      if (stopped) return;

      try {
        const events = await this.query({
          ...filter,
          since_ts: lastSeenTs,
        });

        if (!stopped && events.length > 0) {
          for (const ev of events) {
            const key = ev.id || `${ev.ts}_${ev.event}_${ev.source}`;
            if (!seenIds.has(key)) {
              seenIds.add(key);
              if (ev.ts > lastSeenTs) {
                lastSeenTs = ev.ts;
              }
              try {
                onEvent(ev);
              } catch (err) {
                logger.warn('[EVENT_CLIENT] onEvent handler error:', err);
              }
            }
          }

          // Bound seenIds memory cache
          if (seenIds.size > 2000) {
            const toRemove = seenIds.size - 1000;
            let count = 0;
            for (const id of seenIds) {
              seenIds.delete(id);
              count++;
              if (count >= toRemove) break;
            }
          }
        }
      } catch (err) {
        if (!stopped && onError) {
          try {
            onError(err);
          } catch (_e) {
            // ignore
          }
        }
      } finally {
        if (!stopped) {
          timer = setTimeout(pollStep, intervalMs);
        }
      }
    };

    timer = setTimeout(pollStep, intervalMs);

    return () => {
      stopped = true;
      if (timer) {
        clearTimeout(timer);
        timer = null;
      }
      seenIds.clear();
    };
  }
}

export const eventClient = new EventClient();
