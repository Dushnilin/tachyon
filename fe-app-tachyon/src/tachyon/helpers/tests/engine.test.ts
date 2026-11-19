import { describe, expect, it } from 'vitest';
import { engineLabel, engineSupports } from '../engine';

describe('engineSupports', () => {
  it('reports a capability the engine declares', () => {
    expect(
      engineSupports(
        ['routing.domain_lists', 'list_memory_fit'],
        'list_memory_fit',
      ),
    ).toBe(true);
  });

  it('reports a capability the engine does not declare', () => {
    expect(
      engineSupports(['routing.domain_lists'], 'outbound.vless_reality'),
    ).toBe(false);
  });

  it('treats a missing capability list as unsupported', () => {
    expect(engineSupports(undefined, 'routing.domain_lists')).toBe(false);
  });
});

describe('engineLabel', () => {
  it('always resolves to tachyon-core', () => {
    expect(engineLabel('tachyon-core')).toBe('tachyon-core');
    expect(engineLabel(undefined)).toBe('tachyon-core');
  });
});
