import { describe, expect, it } from 'vitest';
import { DIAGNOSTICS_CHECKS } from '../checks/constants';
import { getDiagnosticsChecks } from '../diagnostic.store';

describe('diagnostic store checks', () => {
  it('returns core diagnostic checks without legacy provider checks', () => {
    const checks = getDiagnosticsChecks('Pending', {
      includeInbounds: false,
    });

    expect(checks.map((check) => check.code)).toEqual([
      DIAGNOSTICS_CHECKS.DNS,
      DIAGNOSTICS_CHECKS.TACHYON_CORE,
      DIAGNOSTICS_CHECKS.NFT,
      DIAGNOSTICS_CHECKS.OUTBOUNDS,
      DIAGNOSTICS_CHECKS.FAKEIP,
    ]);
  });

  it('keeps Inbounds hidden until enabled inbounds are confirmed', () => {
    const checks = getDiagnosticsChecks('Pending');

    expect(checks.map((check) => check.code)).not.toContain(
      DIAGNOSTICS_CHECKS.INBOUNDS,
    );
  });

  it('shows Inbounds when enabled inbounds are confirmed', () => {
    const checks = getDiagnosticsChecks('Pending', {
      includeInbounds: true,
    });

    expect(checks.map((check) => check.code)).toContain(
      DIAGNOSTICS_CHECKS.INBOUNDS,
    );
  });
});
