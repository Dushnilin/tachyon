// A priority group is a plain sing-box selector over the raw server tags, so
// nothing in sing-box measures it: latency exists only for servers that belong to
// a URLTest group. That is why the first level showed numbers and every fallback
// node showed N/A, even though the members were reachable all along.
//
// Tachyon's own priority daemon has no such gap - priority.uc probes each member
// through the Clash API on demand, with the group's health URL and check timeout.
// This module does the same for the details modal, so what the user sees is what
// the daemon acts on.

export const PRIORITY_PROBE_TIMEOUT_MS = '2000';

export interface PriorityLatencyMember {
  code?: string;
  latency?: number;
}

export interface MeasureOptions {
  healthUrl?: string;
  timeout?: string;
  existing?: Map<string, number>;
  probe: (
    tag: string,
    timeout: string,
    healthUrl: string,
  ) => Promise<{ success: boolean; data?: unknown }>;
}

/**
 * Members whose latency is still unknown. Any non-zero number is a measurement -
 * including the negative one the dashboard stores for "did not answer" - so only
 * an absent or zero value is worth re-probing.
 */
export function collectUnmeasuredTags(
  members: PriorityLatencyMember[],
  existing?: Map<string, number>,
): string[] {
  const tags: string[] = [];
  const seen = new Set<string>();

  for (const member of members || []) {
    const tag = String(member?.code || '');
    if (!tag || seen.has(tag)) continue;
    if (typeof member?.latency === 'number' && member.latency !== 0) continue;
    if (existing?.has(tag)) continue;
    seen.add(tag);
    tags.push(tag);
  }

  return tags;
}

/**
 * Pulls a delay out of a Clash API delay answer. The endpoint answers either with
 * a single { delay } object or, for a tag that names a group, with a map of members;
 * the fastest member is what the rest of the dashboard shows.
 */
export function parseDelay(data: unknown): number {
  if (!data || typeof data !== 'object') return -1;

  const single = (data as { delay?: unknown }).delay;
  if (typeof single === 'number' && single > 0) return single;

  const delays = Object.values(data as Record<string, unknown>).filter(
    (value): value is number => typeof value === 'number' && value > 0,
  ) as number[];

  return delays.length > 0 ? Math.min(...delays) : -1;
}

/**
 * Measures every member that has no latency yet. Failures resolve to -1 rather
 * than rejecting: one unreachable node must not blank the whole modal, and -1 is
 * what the dashboard already stores for "did not answer".
 */
export async function measurePriorityLatencies(
  members: PriorityLatencyMember[],
  options: MeasureOptions,
): Promise<Map<string, number>> {
  const measured = new Map<string, number>();
  const tags = collectUnmeasuredTags(members, options.existing);
  if (tags.length === 0) return measured;

  const timeout = options.timeout || PRIORITY_PROBE_TIMEOUT_MS;
  const healthUrl = options.healthUrl || '';

  await Promise.all(
    tags.map(async (tag) => {
      try {
        const response = await options.probe(tag, timeout, healthUrl);
        measured.set(tag, response?.success ? parseDelay(response.data) : -1);
      } catch {
        measured.set(tag, -1);
      }
    }),
  );

  return measured;
}
