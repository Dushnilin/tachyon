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

  it('hides Clash and sing-box widgets on steer', () => {
    expect(isWidgetAvailable('steer', 'clash_connections')).toBe(false);
    expect(isWidgetAvailable('steer', 'clash_groups')).toBe(false);
    expect(isWidgetAvailable('steer-extended', 'sing_box_inbounds')).toBe(
      false,
    );
  });

  it('keeps engine-agnostic widgets on steer', () => {
    expect(isWidgetAvailable('steer', 'tachyon_status')).toBe(true);
    expect(isWidgetAvailable('steer', 'dns_status')).toBe(true);
  });
});

describe('engineLabel', () => {
  it('names each known engine', () => {
    expect(engineLabel('sing-box')).toBe('sing-box');
    expect(engineLabel('steer')).toBe('steer');
    expect(engineLabel('steer-extended')).toBe('steer-extended');
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
        { engine: 'steer', known: true, installed: false },
        { engine: 'bogus', known: false, installed: false },
      ],
    });
    expect(engines.map((entry) => entry.engine)).toEqual(['sing-box', 'steer']);
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
        to_engine: 'steer',
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
        to_engine: 'steer',
        plan: { unsupported: [] },
      }),
    ).toEqual([]);
  });
});
