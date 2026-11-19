import { describe, expect, it } from 'vitest';
import { formatCoreVersion, isNotInstalled } from '../coreVersion';

describe('isNotInstalled', () => {
  it('treats empty and not-installed strings as missing', () => {
    expect(isNotInstalled(undefined)).toBe(true);
    expect(isNotInstalled('')).toBe(true);
    expect(isNotInstalled('not installed')).toBe(true);
    expect(isNotInstalled('Not installed')).toBe(true);
  });

  it('treats semver strings as installed', () => {
    expect(isNotInstalled('0.3.10')).toBe(false);
    expect(isNotInstalled('v0.3.10-tachyon.1')).toBe(false);
  });
});

describe('formatCoreVersion', () => {
  it('returns Not installed for empty or missing versions', () => {
    expect(formatCoreVersion(undefined)).toBe('Not installed');
    expect(formatCoreVersion('')).toBe('Not installed');
    expect(formatCoreVersion('not installed')).toBe('Not installed');
  });

  it('preserves placeholders and version strings as-is', () => {
    expect(formatCoreVersion('loading')).toBe('loading');
    expect(formatCoreVersion('unknown')).toBe('unknown');
    expect(formatCoreVersion('0.3.10')).toBe('0.3.10');
  });
});
