/* eslint-disable @typescript-eslint/no-explicit-any */
import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  createExitCountryController,
  formatExitCountryTooltip,
  isPrivacyModeEnabled,
  maskPublicIp,
  renderExitCountryIndicator,
  setPrivacyModeEnabled,
} from '../exitCountry';

function createMockEl(tag: string): any {
  const attrs: Record<string, string> = {};
  const listeners: Record<string, Array<(ev: any) => void>> = {};
  const el: any = {
    tagName: tag.toUpperCase(),
    children: [] as any[],
    style: {},
    className: '',
    textContent: '',
    setAttribute(k: string, v: string) {
      attrs[k] = String(v);
      if (k === 'class') el.className = String(v);
    },
    getAttribute: (k: string) => attrs[k] ?? null,
    addEventListener(type: string, cb: (ev: any) => void) {
      if (!listeners[type]) listeners[type] = [];
      listeners[type].push(cb);
    },
    click() {
      const ev = { preventDefault() {}, stopPropagation() {} };
      (listeners.click || []).forEach((fn) => fn(ev));
    },
    appendChild(child: any) {
      if (child != null && child !== '') {
        el.children.push(child);
      }
      return child;
    },
  };
  return el;
}

describe('Issue #499: Dashboard actual exit country indicator', () => {
  beforeEach(() => {
    const store = new Map<string, string>();
    (globalThis as any).localStorage = {
      getItem: (k: string) => (store.has(k) ? store.get(k)! : null),
      setItem: (k: string, v: string) => store.set(k, String(v)),
    };
    const body = createMockEl('body');
    body.dataset = {};
    body.classList = {
      _set: new Set<string>(),
      add(c: string) {
        this._set.add(c);
      },
      remove(c: string) {
        this._set.delete(c);
      },
      toggle(c: string, force?: boolean) {
        const should = force !== undefined ? force : !this._set.has(c);
        if (should) this._set.add(c);
        else this._set.delete(c);
        return should;
      },
      contains(c: string) {
        return this._set.has(c);
      },
    };
    (globalThis as any).document = {
      documentElement: { lang: 'ru' },
      body,
      createElementNS: (_ns: string, tag: string) => createMockEl(tag),
      addEventListener: () => {},
    };
    (globalThis as any).window = {
      dispatchEvent: () => true,
    };
    (globalThis as any).E = (tag: string, attrs?: any, children?: any) => {
      const el = createMockEl(tag);
      if (attrs) {
        for (const [k, v] of Object.entries(attrs)) {
          if (v === undefined || v === null) continue;
          if (k === 'click' && typeof v === 'function') {
            el.addEventListener('click', v as any);
          } else {
            el.setAttribute(k, String(v));
          }
        }
      }
      const add = (c: any) => {
        if (c == null || c === '') return;
        if (Array.isArray(c)) c.forEach(add);
        else if (typeof c === 'object') el.appendChild(c);
        else el.textContent += String(c);
      };
      add(children);
      return el;
    };
    setPrivacyModeEnabled(false);
  });

  it('renders flag + ISO country code, shows IP/source in tooltip, and masks IP under Alt+P privacy mode', () => {
    const onRefresh = vi.fn();
    const state = {
      loading: false,
      activeNode: 'nl-ams-01',
      error: '',
      data: {
        ok: true,
        country_code: 'NL',
        ip: '203.0.113.42',
        active_node: 'nl-ams-01',
        source: 'cloudflare',
        checked_at: 1700000000,
        cached: false,
      },
    };

    const elPublic = renderExitCountryIndicator(state, onRefresh, false);
    expect(elPublic.getAttribute('data-exit-country-indicator')).toBe('1');
    expect(elPublic.getAttribute('data-country-code')).toBe('NL');
    expect(elPublic.children[0].textContent).toContain('NL');
    expect(elPublic.children[0].textContent).toContain('🇳🇱');
    expect(elPublic.getAttribute('title')).toContain('203.0.113.42');
    expect(elPublic.getAttribute('title')).toContain('cloudflare');

    // Click triggers manual refresh callback
    elPublic.click();
    expect(onRefresh).toHaveBeenCalledTimes(1);

    // Privacy mode masks IP while preserving flag + 2-letter code
    setPrivacyModeEnabled(true);
    expect(isPrivacyModeEnabled()).toBe(true);
    const elPrivate = renderExitCountryIndicator(state, onRefresh, true);
    expect(elPrivate.children[0].textContent).toContain('🇳🇱');
    expect(elPrivate.children[0].textContent).toContain('NL');
    expect(elPrivate.getAttribute('title')).not.toContain('203.0.113.42');
    expect(elPrivate.getAttribute('title')).toContain('•••.•••.•••.•••');
    expect(maskPublicIp('2001:db8::1', true)).toBe('••••:••••:••••');
    expect(formatExitCountryTooltip(state, true)).not.toContain('203.0.113.42');
  });

  it('auto-updates on active node switch and ignores stale out-of-order responses', async () => {
    let resolveFirst!: (val: any) => void;
    let resolveSecond!: (val: any) => void;
    const calls: Array<{ refresh?: boolean; node?: string }> = [];

    const fetcher = vi.fn((opts?: { refresh?: boolean; node?: string }) => {
      calls.push({ ...opts });
      return new Promise<any>((resolve) => {
        if (calls.length === 1) resolveFirst = resolve;
        else resolveSecond = resolve;
      });
    });

    const updates: any[] = [];
    const ctrl = createExitCountryController({
      fetcher,
      onUpdate: (st) => updates.push(st),
    });

    // Initial node sync -> fetch #1 (cached allowed)
    ctrl.syncActiveNode('de-fra-01');
    expect(calls[0]).toEqual({ refresh: false, node: 'de-fra-01' });

    // User switches active node BEFORE fetch #1 resolves -> fetch #2 (refresh=true)
    ctrl.syncActiveNode('nl-ams-02');
    expect(calls[1]).toEqual({ refresh: true, node: 'nl-ams-02' });

    // Resolve fetch #2 FIRST (NL)
    resolveSecond({
      success: true,
      data: {
        ok: true,
        country_code: 'NL',
        ip: '198.51.100.22',
        active_node: 'nl-ams-02',
        source: 'cloudflare',
        checked_at: 1700000010,
        cached: false,
      },
    });
    await Promise.resolve();
    expect(ctrl.getState().data?.country_code).toBe('NL');

    // Now stale fetch #1 resolves LATE (DE) — MUST BE IGNORED
    resolveFirst({
      success: true,
      data: {
        ok: true,
        country_code: 'DE',
        ip: '198.51.100.11',
        active_node: 'de-fra-01',
        source: 'ipwhois',
        checked_at: 1700000001,
        cached: false,
      },
    });
    await Promise.resolve();

    expect(ctrl.getState().data?.country_code).toBe('NL');
    expect(ctrl.getState().activeNode).toBe('nl-ams-02');
    expect(updates[updates.length - 1]?.data?.country_code).toBe('NL');
  });
});
