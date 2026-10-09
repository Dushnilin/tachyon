import { describe, expect, it } from 'vitest';
import {
  formatSingBoxVersion,
  normalizeSingBoxVariantFields,
  type SingBoxVariantFields,
} from '../singBoxVariant';

describe('normalizeSingBoxVariantFields', () => {
  it('detects tachyon-core from the version suffix', () => {
    const normalized = normalizeSingBoxVariantFields<SingBoxVariantFields>({
      sing_box_version: 'v0.0.1-tachyon.0',
    });

    expect(normalized.sing_box_tachyon_core).toBe(1);
    expect(normalized.sing_box_fptn).toBe(1);
    expect(normalized.sing_box_extended).toBe(0);
    expect(normalized.sing_box_tiny).toBe(0);
    expect(normalized.sing_box_cert_pin).toBe(1);
    expect(normalized.sing_box_tailscale).toBe(1);
  });

  it('lets the tachyon_core flag win over stale fork flags', () => {
    const normalized = normalizeSingBoxVariantFields<SingBoxVariantFields>({
      sing_box_version: 'v0.0.1-tachyon.0',
      sing_box_tiny: 1,
      sing_box_extended: 1,
    });

    expect(normalized.sing_box_tachyon_core).toBe(1);
    expect(normalized.sing_box_tiny).toBe(0);
    expect(normalized.sing_box_extended).toBe(0);
    expect(normalized.sing_box_lx).toBe(0);
  });

  it('keeps a stock build out of the tachyon-core flags', () => {
    const normalized = normalizeSingBoxVariantFields<SingBoxVariantFields>({
      sing_box_version: '1.13.21',
    });

    expect(normalized.sing_box_tachyon_core).toBe(0);
    expect(normalized.sing_box_fptn).toBe(0);
    expect(normalized.sing_box_cert_pin).toBe(0);
  });
});

describe('formatSingBoxVersion', () => {
  it('names the full tachyon-core build without a suffix', () => {
    const formatted = formatSingBoxVersion({
      sing_box_version: 'v0.0.1-tachyon.0',
    });

    expect(formatted).toBe('v0.0.1-tachyon.0');
  });
});
