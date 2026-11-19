import { describe, expect, it } from 'vitest';
import { formatServiceStatusMessage } from '../formatServiceStatusMessage';

describe('formatServiceStatusMessage', () => {
  it('formats normal provider status', () => {
    expect(formatServiceStatusMessage('desync provider status is normal')).toBe(
      'Provider status is normal: desync',
    );
  });

  it('formats action not ready with details', () => {
    const msg =
      'action=desync is configured, but the Tachyon-managed tachyon-core runtime is not ready (Desync: invalid option)';
    expect(formatServiceStatusMessage(msg)).toBe(
      'Action is configured, but runtime is not ready (desync -> tachyon-core): Desync: invalid option',
    );
  });

  it('formats missing binary path', () => {
    const msg =
      'action=desync is configured, but tachyon-core provider is not available at /usr/bin/tachyon-core';
    expect(formatServiceStatusMessage(msg)).toBe(
      'Action is configured, but binary is not available (desync -> tachyon-core): /usr/bin/tachyon-core',
    );
  });

  it('formats empty or unknown string', () => {
    expect(formatServiceStatusMessage('')).toBe('');
    expect(formatServiceStatusMessage('Random error')).toBe('Random error');
  });
});
