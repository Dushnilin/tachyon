import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  executeShellCommand: vi.fn(),
}));

vi.mock('../../../helpers', () => ({
  executeShellCommand: mocks.executeShellCommand,
}));

import { eventClient, EventClient, type TachyonEvent } from '../eventClient';

describe('EventClient', () => {
  let client: EventClient;

  beforeEach(() => {
    vi.clearAllMocks();
    client = new EventClient('/usr/bin/tachyon');
  });

  describe('query', () => {
    it('queries events with json filter', async () => {
      const mockEvents: TachyonEvent[] = [
        {
          id: 'ev-1',
          ts: 1700000000,
          event: 'system_start',
          severity: 'info',
          source: 'core',
        },
      ];

      mocks.executeShellCommand.mockResolvedValueOnce({
        code: 0,
        stdout: JSON.stringify(mockEvents),
        stderr: '',
      });

      const res = await client.query({ severity: 'info', source: 'core' });
      expect(mocks.executeShellCommand).toHaveBeenCalledWith({
        command: '/usr/bin/tachyon',
        args: [
          'event_query',
          JSON.stringify({ severity: 'info', source: 'core' }),
        ],
        timeout: 10000,
      });
      expect(res).toEqual(mockEvents);
    });

    it('returns empty array on error', async () => {
      mocks.executeShellCommand.mockResolvedValueOnce({
        code: 1,
        stdout: '',
        stderr: 'failed to open journal',
      });

      const res = await client.query();
      expect(res).toEqual([]);
    });
  });

  describe('tail', () => {
    it('tails last N entries', async () => {
      const mockEvents: TachyonEvent[] = [
        {
          ts: 1700000010,
          event: 'config_reload',
          severity: 'info',
          source: 'lifecycle',
        },
      ];

      mocks.executeShellCommand.mockResolvedValueOnce({
        code: 0,
        stdout: JSON.stringify(mockEvents),
        stderr: '',
      });

      const res = await client.tail(5);
      expect(mocks.executeShellCommand).toHaveBeenCalledWith({
        command: '/usr/bin/tachyon',
        args: ['event_tail', '5'],
        timeout: 10000,
      });
      expect(res).toEqual(mockEvents);
    });
  });

  describe('stats', () => {
    it('returns event journal storage statistics', async () => {
      mocks.executeShellCommand.mockResolvedValueOnce({
        code: 0,
        stdout: JSON.stringify({ count: 42, bytes: 4096 }),
        stderr: '',
      });

      const res = await client.stats();
      expect(mocks.executeShellCommand).toHaveBeenCalledWith({
        command: '/usr/bin/tachyon',
        args: ['event_stats'],
        timeout: 10000,
      });
      expect(res.count).toBe(42);
      expect(res.bytes).toBe(4096);
    });
  });

  describe('clear', () => {
    it('clears event journal and returns true on exit code 0', async () => {
      mocks.executeShellCommand.mockResolvedValueOnce({
        code: 0,
        stdout: '',
        stderr: '',
      });

      const res = await client.clear();
      expect(mocks.executeShellCommand).toHaveBeenCalledWith({
        command: '/usr/bin/tachyon',
        args: ['event_clear'],
        timeout: 10000,
      });
      expect(res).toBe(true);
    });
  });

  describe('record', () => {
    it('returns null if event name is empty', async () => {
      const res = await client.record('');
      expect(res).toBeNull();
      expect(mocks.executeShellCommand).not.toHaveBeenCalled();
    });

    it('records event to journal', async () => {
      const mockEvent: TachyonEvent = {
        id: 'rec-1',
        ts: 1700000050,
        event: 'dns_switch',
        severity: 'warn',
        source: 'watchdog',
        message: 'DNS failover triggered',
        data: { server: '1.1.1.1' },
      };

      mocks.executeShellCommand.mockResolvedValueOnce({
        code: 0,
        stdout: JSON.stringify(mockEvent),
        stderr: '',
      });

      const res = await client.record(
        'dns_switch',
        { server: '1.1.1.1' },
        {
          severity: 'warn',
          source: 'watchdog',
          message: 'DNS failover triggered',
        },
      );

      expect(mocks.executeShellCommand).toHaveBeenCalledWith({
        command: '/usr/bin/tachyon',
        args: [
          'event_record',
          'dns_switch',
          JSON.stringify({ server: '1.1.1.1' }),
          'warn',
          'watchdog',
          'DNS failover triggered',
        ],
        timeout: 10000,
      });
      expect(res).toEqual(mockEvent);
    });
  });

  describe('poll', () => {
    it('polls events and deduplicates across iterations', async () => {
      const event1: TachyonEvent = {
        id: 'ev-1',
        ts: 100,
        event: 'ping',
        severity: 'info',
        source: 'test',
      };
      const event2: TachyonEvent = {
        id: 'ev-2',
        ts: 105,
        event: 'pong',
        severity: 'info',
        source: 'test',
      };

      mocks.executeShellCommand.mockResolvedValue({
        code: 0,
        stdout: '[]',
        stderr: '',
      });
      mocks.executeShellCommand
        .mockResolvedValueOnce({
          code: 0,
          stdout: JSON.stringify([event1]),
          stderr: '',
        })
        .mockResolvedValueOnce({
          code: 0,
          stdout: JSON.stringify([event1, event2]),
          stderr: '',
        });

      const received: TachyonEvent[] = [];
      const stop = client.poll({
        onEvent: (ev) => received.push(ev),
        intervalMs: 10,
      });

      await new Promise((r) => setTimeout(r, 60));
      stop();

      // event1 should only be received once despite appearing in both poll batches
      expect(received).toHaveLength(2);
      expect(received[0].id).toBe('ev-1');
      expect(received[1].id).toBe('ev-2');
    });
  });

  describe('singleton export', () => {
    it('exports a default eventClient instance', () => {
      expect(eventClient).toBeInstanceOf(EventClient);
    });
  });
});
