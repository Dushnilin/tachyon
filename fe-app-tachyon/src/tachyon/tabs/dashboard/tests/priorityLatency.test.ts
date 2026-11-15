import { describe, expect, it, vi } from 'vitest';

import {
  collectUnmeasuredTags,
  measurePriorityLatencies,
  parseDelay,
  parseFailureReason,
  PRIORITY_PROBE_CONCURRENCY,
} from '../priorityLatency';

const member = (code: string, latency?: number) => ({ code, latency });

describe('priority modal latency', () => {
  describe('collectUnmeasuredTags', () => {
    it('asks only for members without a latency', () => {
      expect(
        collectUnmeasuredTags([member('a', 45), member('b'), member('c', 0)]),
      ).toEqual(['b', 'c']);
    });

    // A member that did not answer is exactly the one worth asking again: the
    // priority daemon retries dead nodes on its own schedule too. Treating the
    // cached -1 as final pinned the modal on "-1ms" for the rest of the session
    // after one bad round, which is what the screenshot showed.
    it('re-probes a negative latency from the member or from the cache', () => {
      expect(collectUnmeasuredTags([member('dead', -1)])).toEqual(['dead']);

      const existing = new Map([
        ['dead', -1],
        ['ok', 120],
      ]);

      expect(
        collectUnmeasuredTags([member('dead'), member('ok')], existing),
      ).toEqual(['dead']);
    });

    it('skips tags already measured by the caller', () => {
      const existing = new Map([['b', 120]]);
      expect(
        collectUnmeasuredTags([member('a'), member('b')], existing),
      ).toEqual(['a']);
    });

    it('deduplicates and ignores members without a code', () => {
      expect(
        collectUnmeasuredTags([member('a'), member('a'), member('')]),
      ).toEqual(['a']);
    });
  });

  describe('parseDelay', () => {
    it('reads a single delay answer', () => {
      expect(parseDelay({ delay: 72 })).toBe(72);
    });

    it('takes the fastest member when the tag names a group', () => {
      expect(parseDelay({ a: 90, b: 45, c: 0 })).toBe(45);
    });

    it('reports -1 for anything unusable', () => {
      expect(parseDelay(null)).toBe(-1);
      expect(parseDelay({})).toBe(-1);
      expect(parseDelay({ delay: 0 })).toBe(-1);
    });
  });

  describe('measurePriorityLatencies', () => {
    it('probes the missing members and returns their delays', async () => {
      const probe = vi.fn(async (tag: string) => ({
        success: true,
        data: { delay: tag === 'fast' ? 40 : 90 },
      }));

      const measured = await measurePriorityLatencies(
        [member('fast', 45), member('slow')],
        { probe, healthUrl: 'https://health.example/204' },
      );

      // the member that already had a latency is left alone
      expect(probe).toHaveBeenCalledTimes(1);
      expect(probe).toHaveBeenCalledWith(
        'slow',
        '2000',
        'https://health.example/204',
      );
      expect(measured.get('slow')).toBe(90);
      expect(measured.has('fast')).toBe(false);
    });

    // One dead fallback node must not blank the modal for the rest.
    it('records -1 for a node that did not answer', async () => {
      const probe = vi.fn(async (tag: string) =>
        tag === 'dead'
          ? { success: false }
          : { success: true, data: { delay: 55 } },
      );

      const measured = await measurePriorityLatencies(
        [member('dead'), member('live')],
        { probe },
      );

      expect(measured.get('dead')).toBe(-1);
      expect(measured.get('live')).toBe(55);
    });

    it('survives a probe that throws', async () => {
      const probe = vi.fn(async () => {
        throw new Error('rpc down');
      });

      const measured = await measurePriorityLatencies([member('a')], {
        probe,
      });

      expect(measured.get('a')).toBe(-1);
    });

    it('does not call the API when every member already has a latency', async () => {
      const probe = vi.fn();

      const measured = await measurePriorityLatencies(
        [member('a', 10), member('b', 20)],
        { probe },
      );

      expect(probe).not.toHaveBeenCalled();
      expect(measured.size).toBe(0);
    });

    // The whole point of the change. Asking sing-box for every member's delay at
    // once answered 1 of 152 on a real router; the rest were "Timeout", so the
    // modal filled with -1 instead of latencies.
    it('keeps only a bounded number of probes in flight', async () => {
      let inFlight = 0;
      let peak = 0;

      const probe = vi.fn(async () => {
        inFlight++;
        peak = Math.max(peak, inFlight);
        await new Promise((resolve) => setTimeout(resolve, 1));
        inFlight--;
        return { success: true, data: { delay: 40 } };
      });

      const members = Array.from({ length: 60 }, (_, index) =>
        member(`node-${index}`),
      );
      const measured = await measurePriorityLatencies(members, { probe });

      expect(probe).toHaveBeenCalledTimes(60);
      expect(measured.size).toBe(60);
      expect(peak).toBeLessThanOrEqual(PRIORITY_PROBE_CONCURRENCY);
      expect(peak).toBeGreaterThan(1);
    });

    it('still measures everyone when the group is smaller than one batch', async () => {
      const probe = vi.fn(async (tag: string) => ({
        success: true,
        data: { delay: tag.length * 10 },
      }));

      const measured = await measurePriorityLatencies(
        [member('a'), member('bb')],
        { probe },
      );

      expect(measured.get('a')).toBe(10);
      expect(measured.get('bb')).toBe(20);
    });
  });

  // The reason a node did not answer is the difference between "the server is
  // down" and "the tls handshake was cut". Our own core names the cause; a core
  // that does not - sing-box answers with the message alone - has no reason to
  // show, and its generic message is not one: it names no cause.
  describe('parseFailureReason', () => {
    it('takes the reason the core named', () => {
      expect(
        parseFailureReason({
          message: 'An error occurred in the delay test',
          reason: 'tls handshake with example.com failed',
        }),
      ).toBe('tls handshake with example.com failed');
    });

    it('does not pass the generic message off as a reason', () => {
      expect(
        parseFailureReason({
          message: 'An error occurred in the delay test',
        }),
      ).toBe('');
    });

    it('keeps a message that names something', () => {
      expect(parseFailureReason({ message: 'Unauthorized' })).toBe(
        'Unauthorized',
      );
    });

    it('has nothing to say about a missing answer', () => {
      expect(parseFailureReason(undefined)).toBe('');
      expect(parseFailureReason(null)).toBe('');
    });
  });

  it('reports why a node did not answer', async () => {
    const failures: Array<[string, string]> = [];
    const probe = vi.fn(async (tag: string) => ({
      success: false,
      data: {
        message: 'An error occurred in the delay test',
        reason: `${tag} is not reachable`,
      },
    }));

    await measurePriorityLatencies([member('a')], {
      probe,
      onFailure: (tag, reason) => failures.push([tag, reason]),
    });

    expect(failures).toEqual([['a', 'a is not reachable']]);
  });

  it('says nothing about a core that names no cause', async () => {
    const failures: Array<[string, string]> = [];
    const probe = vi.fn(async () => ({
      success: false,
      data: { message: 'An error occurred in the delay test' },
    }));

    await measurePriorityLatencies([member('a')], {
      probe,
      onFailure: (tag, reason) => failures.push([tag, reason]),
    });

    expect(failures).toEqual([]);
  });
});
