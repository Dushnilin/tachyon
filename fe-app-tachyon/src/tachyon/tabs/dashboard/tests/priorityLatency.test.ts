import { describe, expect, it, vi } from 'vitest';

import {
  collectUnmeasuredTags,
  measurePriorityLatencies,
  parseDelay,
} from '../priorityLatency';

const member = (code: string, latency?: number) => ({ code, latency });

describe('priority modal latency', () => {
  describe('collectUnmeasuredTags', () => {
    it('asks only for members without a latency', () => {
      expect(
        collectUnmeasuredTags([member('a', 45), member('b'), member('c', 0)]),
      ).toEqual(['b', 'c']);
    });

    // A fallback level node that did not answer is a measurement, not a gap:
    // re-probing it on every modal open would hammer a dead node. Zero is the
    // dashboard's "unknown" value, so it is still worth asking about.
    it('keeps a negative latency as a measurement but re-probes an unknown zero', () => {
      expect(collectUnmeasuredTags([member('a', -1)])).toEqual([]);
      expect(collectUnmeasuredTags([member('a', 0)])).toEqual(['a']);
    });

    it('skips tags already known to the caller', () => {
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
  });
});
