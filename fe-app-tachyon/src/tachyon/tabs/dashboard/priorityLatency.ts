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

// Measured on a router with a 152-node subscription: asking sing-box for every
// member's delay at once answered 1 of 152 - the rest came back "Timeout", because
// each request is a real probe through that outbound and they pile up on each
// other. Sequential probing answered 78 of 152, and 4, 8 and 16 at a time all came
// out within noise of sequential (29-33 of the 40 healthiest tags against 32
// sequential), so the cliff is only at "everything at once". Eight keeps the
// modal responsive without paying for that.
export const PRIORITY_PROBE_CONCURRENCY = 8;

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
 * Members whose latency is still unknown. A measurement is a positive number:
 * zero is the dashboard's "unknown", and a negative one is "did not answer", so
 * neither is worth keeping. Skipping the negative is what pinned the modal on
 * -1 for the rest of the session after the first bad round.
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
    if (typeof member?.latency === 'number' && member.latency > 0) continue;
    const cached = existing?.get(tag);
    if (typeof cached === 'number' && cached > 0) continue;
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

  let next = 0;
  const worker = async () => {
    while (next < tags.length) {
      const tag = tags[next++];
      try {
        const response = await options.probe(tag, timeout, healthUrl);
        measured.set(tag, response?.success ? parseDelay(response.data) : -1);
      } catch {
        measured.set(tag, -1);
      }
    }
  };

  const workers = Math.min(PRIORITY_PROBE_CONCURRENCY, tags.length);
  await Promise.all(Array.from({ length: workers }, worker));

  return measured;
}
