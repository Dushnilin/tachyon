import { describe, expect, it } from 'vitest';
import { formatServiceStatusMessage } from '../formatServiceStatusMessage';

describe('formatServiceStatusMessage', () => {
  it('formats normal provider status', () => {
    expect(
      formatServiceStatusMessage('zapret2 provider status is normal'),
    ).toBe('Provider status is normal: zapret2');
    expect(formatServiceStatusMessage('byedpi provider status is normal')).toBe(
      'Provider status is normal: byedpi',
    );
  });

  it('formats action not ready with details', () => {
    const msg =
      'action=zapret2 is configured, but the Tachyon-managed nfqws2 runtime is not ready (Zapret2: invalid ctrack-timeouts value)';
    expect(formatServiceStatusMessage(msg)).toBe(
      'Action is configured, but runtime is not ready (zapret2 -> nfqws2): Zapret2: invalid ctrack-timeouts value',
    );
  });

  it('formats missing binary path', () => {
    const msg =
      'action=zapret2 is configured, but zapret2 provider is not available at /opt/zapret2/nfq2/nfqws2';
    expect(formatServiceStatusMessage(msg)).toBe(
      'Action is configured, but binary is not available (zapret2 -> zapret2): /opt/zapret2/nfq2/nfqws2',
    );
  });

  it('formats empty or unknown string', () => {
    expect(formatServiceStatusMessage('')).toBe('');
    expect(formatServiceStatusMessage('Random error')).toBe('Random error');
  });
});
