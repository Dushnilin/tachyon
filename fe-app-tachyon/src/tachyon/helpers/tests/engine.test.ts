import { describe, expect, it } from 'vitest';
import {
  engineLabel,
  engineSupports,
  isWidgetAvailable,
  parkedFeatures,
  switchableEngines,
} from '../engine';

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

describe('isWidgetAvailable', () => {
  it('keeps every widget on sing-box', () => {
    expect(isWidgetAvailable('sing-box', 'clash_connections')).toBe(true);
    expect(isWidgetAvailable(undefined, 'clash_connections')).toBe(true);
  });
});

describe('engineLabel', () => {
  it('names each known engine', () => {
    expect(engineLabel('sing-box')).toBe('sing-box');
    expect(engineLabel('tachyon-core')).toBe('tachyon-core');
  });

  it('defaults to sing-box when the engine is unknown', () => {
    expect(engineLabel(undefined)).toBe('sing-box');
  });
});

describe('switchableEngines', () => {
  it('lists only known engines', () => {
    const engines = switchableEngines({
      active: 'sing-box',
      previous: '',
      capabilities: [],
      engines: [
        { engine: 'sing-box', known: true, installed: true },
        { engine: 'tachyon-core', known: true, installed: true },
        { engine: 'bogus', known: false, installed: false },
      ],
    });
    expect(engines.map((entry) => entry.engine)).toEqual([
      'sing-box',
      'tachyon-core',
    ]);
  });

  it('returns nothing without backend info', () => {
    expect(switchableEngines(null)).toEqual([]);
  });
});

describe('parkedFeatures', () => {
  it('returns the features a switch would park', () => {
    expect(
      parkedFeatures({
        ok: true,
        reason: '',
        from_engine: 'sing-box',
        to_engine: 'tachyon-core',
        plan: { unsupported: ['sections.subscription'] },
      }),
    ).toEqual(['sections.subscription']);
  });

  it('returns nothing when the plan loses no features', () => {
    expect(
      parkedFeatures({
        ok: true,
        reason: '',
        from_engine: 'sing-box',
        to_engine: 'tachyon-core',
        plan: { unsupported: [] },
      }),
    ).toEqual([]);
  });
});
