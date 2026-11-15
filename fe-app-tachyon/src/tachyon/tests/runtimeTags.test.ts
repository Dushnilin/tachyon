import { describe, expect, it } from 'vitest';

import { cleanBalancerTagId, getOutboundTagBySection } from '../runtimeTags';

describe('runtimeTags', () => {
  it('uses the same direct section collision format as the backend generator', () => {
    expect(getOutboundTagBySection('proxy')).toBe('proxy-out');
    expect(getOutboundTagBySection('direct')).toBe('direct-out-1');
    expect(getOutboundTagBySection('bypass')).toBe('bypass-out-1');
    expect(getOutboundTagBySection('direct-1')).toBe('direct-1-out');
  });

  it('strips redundant bal_ prefix and section name from wizard/UI balancer IDs', () => {
    expect(cleanBalancerTagId('Main', 'bal_auto_Main')).toBe('auto');
    expect(cleanBalancerTagId('Main', 'bal_Main_auto')).toBe('auto');
    expect(cleanBalancerTagId('Main', 'bal_Main_Fast')).toBe('Fast');
    expect(cleanBalancerTagId('Main', 'bal_prio_Main_Prio1')).toBe('Prio1');
    expect(cleanBalancerTagId('main', 'pg_main')).toBe('pg_main');
    expect(cleanBalancerTagId('xhttp', 'ut_xhttp')).toBe('ut_xhttp');
  });
});
