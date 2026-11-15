import { describe, expect, it } from 'vitest';
import {
  isDynamicTelemetrySegment,
  serverFilterNameMatches,
  stripDynamicServerTelemetry,
} from '../serverFilterName';

describe('serverFilterName telemetry normalization', () => {
  it('strips dynamic byte, duration, date and quota telemetry while keeping protocol and index tags', () => {
    expect(
      stripDynamicServerTelemetry(
        '\u{1F1EA}\u{1F1FA} [LTE] Europe 1 [154.77 GiB] [VLESS] (#2)',
      ),
    ).toBe('\u{1F1EA}\u{1F1FA} [LTE] Europe 1 [VLESS] (#2)');

    expect(
      stripDynamicServerTelemetry('\u{1F1E9}\u{1F1EA} Germany 1 (154,77 ГБ)'),
    ).toBe('\u{1F1E9}\u{1F1EA} Germany 1');

    expect(
      stripDynamicServerTelemetry('\u{1F1F3}\u{1F1F1} NL 1 [12.4 / 200 GB]'),
    ).toBe('\u{1F1F3}\u{1F1F1} NL 1');

    expect(
      stripDynamicServerTelemetry(
        '\u{1F1EB}\u{1F1EE} Finland [Осталось: 98.5 ГБ]',
      ),
    ).toBe('\u{1F1EB}\u{1F1EE} Finland');

    expect(
      stripDynamicServerTelemetry(
        '\u{1F1FA}\u{1F1F8} US West | 154.77 GiB | 28d',
      ),
    ).toBe('\u{1F1FA}\u{1F1F8} US West');

    expect(
      stripDynamicServerTelemetry(
        '\u{1F1F5}\u{1F1F1} Poland [exp: 2026-12-31]',
      ),
    ).toBe('\u{1F1F5}\u{1F1F1} Poland');

    expect(
      stripDynamicServerTelemetry(
        '\u{1F1F8}\u{1F1EA} Sweden [До 15.12] [Traffic: 45%]',
      ),
    ).toBe('\u{1F1F8}\u{1F1EA} Sweden');

    expect(stripDynamicServerTelemetry('\u{1F1EC}\u{1F1E7} UK [Exp: 2d]')).toBe(
      '\u{1F1EC}\u{1F1E7} UK',
    );
  });

  it('guards against stripping speed metrics, server indices, protocol badges and 2d/3d tokens', () => {
    expect(isDynamicTelemetrySegment('10 Gbps')).toBe(false);
    expect(isDynamicTelemetrySegment('100 Mbit/s')).toBe(false);
    expect(isDynamicTelemetrySegment('100 Мбит/с')).toBe(false);
    expect(isDynamicTelemetrySegment('50 GB/s')).toBe(false);
    expect(isDynamicTelemetrySegment('VLESS')).toBe(false);
    expect(isDynamicTelemetrySegment('LTE')).toBe(false);
    expect(isDynamicTelemetrySegment('#2')).toBe(false);
    expect(isDynamicTelemetrySegment('1')).toBe(false);
    expect(isDynamicTelemetrySegment('2D')).toBe(false);
    expect(isDynamicTelemetrySegment('3d')).toBe(false);
    expect(isDynamicTelemetrySegment('154.77 GiB')).toBe(true);
    expect(isDynamicTelemetrySegment('Осталось: 98,5 ГБ')).toBe(true);

    expect(
      stripDynamicServerTelemetry('\u{1F1E9}\u{1F1EA} Germany 1 [10 Gbps]'),
    ).toBe('\u{1F1E9}\u{1F1EA} Germany 1 [10 Gbps]');
    expect(stripDynamicServerTelemetry('Node [2D] (#2)')).toBe(
      'Node [2D] (#2)',
    );
    expect(stripDynamicServerTelemetry('Server (1)')).toBe('Server (1)');
  });

  it('matches saved filters across subscription quota updates without colliding distinct nodes', () => {
    expect(
      serverFilterNameMatches(
        '\u{1F1EA}\u{1F1FA} [LTE] Europe 1 [154.77 GiB]',
        ['\u{1F1EA}\u{1F1FA} [LTE] Europe 1 [151.02 GiB]'],
      ),
    ).toBe(true);

    expect(
      serverFilterNameMatches(
        '\u{1F1EA}\u{1F1FA} [LTE] Europe 1 [154.77 GiB]',
        ['\u{1F1EA}\u{1F1FA} [LTE] Europe 1.1 [151.02 GiB]'],
      ),
    ).toBe(false);

    expect(
      serverFilterNameMatches('\u{1F1E9}\u{1F1EA} Germany 1 [10 Gbps]', [
        '\u{1F1E9}\u{1F1EA} Germany 1 [1 Gbps]',
      ]),
    ).toBe(false);

    expect(serverFilterNameMatches('Server (1)', ['Server (2)'])).toBe(false);

    expect(
      serverFilterNameMatches(
        '[SubA] \u{1F1E9}\u{1F1EA} Germany 1 | 154.77 GiB | 28d',
        [
          '\u{1F1E9}\u{1F1EA} Germany 1 (98,5 ГБ)',
          '[SubA] \u{1F1E9}\u{1F1EA} Germany 1 | 151.02 GiB | 27d',
        ],
      ),
    ).toBe(true);
  });
});
