import { describe, expect, it } from 'vitest';
import {
  formatDuration,
  formatEndpoint,
  normalizeString,
  parseStartedAt,
} from '../formatters';

describe('monitoring formatters', () => {
  describe('normalizeString', () => {
    it('handles null and undefined', () => {
      expect(normalizeString(null)).toBe('');
      expect(normalizeString(undefined)).toBe('');
    });

    it('trims string values', () => {
      expect(normalizeString('  test  ')).toBe('test');
    });

    it('converts numbers to strings', () => {
      expect(normalizeString(123)).toBe('123');
    });
  });

  describe('formatEndpoint', () => {
    it('returns "-" for empty address', () => {
      expect(formatEndpoint('')).toBe('-');
      expect(formatEndpoint(undefined)).toBe('-');
    });

    it('returns address only when port is missing or 443', () => {
      expect(formatEndpoint('example.com')).toBe('example.com');
      expect(formatEndpoint('example.com', 443)).toBe('example.com');
      expect(formatEndpoint('example.com', '443')).toBe('example.com');
    });

    it('formats IPv4 and hostname with port', () => {
      expect(formatEndpoint('1.2.3.4', 80)).toBe('1.2.3.4:80');
      expect(formatEndpoint('example.com', '8080')).toBe('example.com:8080');
    });

    it('formats IPv6 with brackets when port is present', () => {
      expect(formatEndpoint('2001:db8::1', 80)).toBe('[2001:db8::1]:80');
      expect(formatEndpoint('[2001:db8::1]', 80)).toBe('[2001:db8::1]:80');
    });
  });

  describe('formatDuration', () => {
    it('formats seconds and minutes', () => {
      expect(formatDuration(0)).toBe('0:00');
      expect(formatDuration(5000)).toBe('0:05');
      expect(formatDuration(65000)).toBe('1:05');
      expect(formatDuration(599000)).toBe('9:59');
    });

    it('formats hours', () => {
      expect(formatDuration(3600000)).toBe('1:00:00');
      expect(formatDuration(3665000)).toBe('1:01:05');
    });
  });

  describe('parseStartedAt', () => {
    it('parses valid ISO start timestamps', () => {
      const now = new Date('2026-09-28T00:00:00Z').getTime();
      expect(
        parseStartedAt({
          start: '2026-09-28T00:00:00Z',
          lastSeenAt: 123456,
        }),
      ).toBe(now);
    });

    it('falls back to lastSeenAt when start is invalid or missing', () => {
      expect(parseStartedAt({ start: '', lastSeenAt: 99999 })).toBe(99999);
      expect(parseStartedAt({ start: 'invalid', lastSeenAt: 88888 })).toBe(
        88888,
      );
    });
  });
});
