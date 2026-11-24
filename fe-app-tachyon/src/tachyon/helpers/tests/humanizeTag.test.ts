import { beforeEach, describe, expect, it } from 'vitest';
import {
  buildRuntimeTagDisplayContextFromUci,
  humanizeRuntimeTag,
} from '../humanizeTag';

describe('humanizeRuntimeTag', () => {
  beforeEach(() => {
    const g = globalThis as Record<string, unknown>;
    g.document = { documentElement: { lang: 'ru' } };
    g.uci = {
      sections: (_pkg: string, type: string) => {
        if (type === 'section') {
          return [{ '.name': 'Main', label: 'Основной маршрут' }];
        }
        if (type === 'balancer') {
          return [{ '.name': 'bal_Main_auto', name: 'Main Auto' }];
        }
        if (type === 'outbound_source') {
          return [
            {
              '.name': 'src_rtest',
              source_type: 'amnezia_config',
              name: 'rtest',
            },
          ];
        }
        if (type === 'server') {
          return [{ '.name': 'in_VLESS', label: 'VLESS Home' }];
        }
        return [];
      },
    };
  });

  it('resolves sections, balancers, indexed awgconf tags and inbound server tags from UCI', () => {
    const context = buildRuntimeTagDisplayContextFromUci();
    expect(humanizeRuntimeTag('sel-Main', undefined, { context })).toBe(
      'Основной маршрут',
    );
    expect(
      humanizeRuntimeTag('bal-Main-bal_Main_auto', undefined, { context }),
    ).toBe('Main Auto');
    expect(
      humanizeRuntimeTag('awgconf-src_rtest-1', undefined, { context }),
    ).toBe('rtest #2');
    expect(humanizeRuntimeTag('srv-in_VLESS', undefined, { context })).toBe(
      'VLESS Home',
    );
    expect(humanizeRuntimeTag('direct', undefined, { context })).toBe(
      'Напрямую',
    );
  });

  it('falls back cleanly when UCI has no matching entry', () => {
    delete (globalThis as Record<string, unknown>).uci;
    expect(humanizeRuntimeTag('bal-Main-bal_Main_auto')).toBe('auto');
    expect(humanizeRuntimeTag('awgconf-src_rtest-1')).toBe('rtest #2');
    expect(humanizeRuntimeTag('awgconf-src_rtest')).toBe('rtest');
    expect(humanizeRuntimeTag('srv-in_VLESS')).toBe('in_VLESS');
    expect(humanizeRuntimeTag('sel-Main')).toBe('Main');
  });
});
