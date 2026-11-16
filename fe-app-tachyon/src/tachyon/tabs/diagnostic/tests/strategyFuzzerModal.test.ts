/* eslint-disable @typescript-eslint/no-explicit-any */
import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => {
  class MockMutationObserver {
    observe() {}
    disconnect() {}
    takeRecords() {
      return [];
    }
  }
  (globalThis as any).MutationObserver = MockMutationObserver;

  const showModal = vi.fn();
  const hideModal = vi.fn();
  const executeShellCommand = vi.fn();

  const parentMap = new WeakMap<any, any>();
  const listenerMap = new WeakMap<
    any,
    Record<string, Array<(e?: any) => void>>
  >();

  function walkTree(root: any, visitor: (el: any) => boolean | void): boolean {
    if (!root || typeof root !== 'object') return false;
    if (visitor(root) === true) return true;
    const kids = Array.isArray(root.children) ? root.children : [];
    for (const child of kids) {
      if (walkTree(child, visitor)) return true;
    }
    return false;
  }

  function createDummyElement(tag: string) {
    const el: any = {
      tagName: tag.toUpperCase(),
      children: [] as any[],
      style: {} as Record<string, string>,
      value: '',
      checked: false,
      disabled: false,
      textContent: '',
      innerText: '',
      className: '',
      setAttribute(name: string, val: string) {
        if (name === 'id') el.id = val;
        if (name === 'type') el.type = val;
      },
      getAttribute(name: string) {
        return name in el ? String(el[name]) : null;
      },
      addEventListener(type: string, cb: (e?: any) => void) {
        let map = listenerMap.get(el);
        if (!map) {
          map = {};
          listenerMap.set(el, map);
        }
        map[type] = map[type] || [];
        map[type].push(cb);
      },
      removeEventListener(type: string, cb: (e?: any) => void) {
        const map = listenerMap.get(el);
        if (!map || !map[type]) return;
        map[type] = map[type].filter((fn) => fn !== cb);
      },
      dispatchEvent(ev: any) {
        const type = typeof ev === 'string' ? ev : ev?.type;
        const map = listenerMap.get(el);
        if (map && map[type]) {
          const eventObj =
            typeof ev === 'object'
              ? { target: el, ...ev }
              : { target: el, type };
          map[type].forEach((cb) => cb(eventObj));
        }
        return true;
      },
      querySelectorAll(selector: string) {
        const out: any[] = [];
        walkTree(el, (node) => {
          if (node === el) return;
          if (selector === 'option' && node.tagName === 'OPTION')
            out.push(node);
          else if (selector.startsWith('#') && node.id === selector.slice(1))
            out.push(node);
          else if (
            selector === 'input[type="checkbox"]' &&
            node.tagName === 'INPUT' &&
            node.type === 'checkbox'
          ) {
            out.push(node);
          } else if (node.tagName === selector.toUpperCase()) {
            out.push(node);
          }
        });
        return out;
      },
      querySelector(selector: string) {
        return el.querySelectorAll(selector)[0] || null;
      },
      replaceChildren: function (...nodes: any[]) {
        el.children = [];
        el.append(...nodes);
      },
      appendChild: function (node: any) {
        if (node == null) return node;
        if (typeof node === 'object') {
          parentMap.set(node, el);
          if (el.tagName === 'SELECT' && node.tagName === 'OPTION') {
            if (node.selected || el.value === '') {
              el.value = node.value ?? '';
            }
          }
        }
        el.children.push(node);
        return node;
      },
      append: function (...nodes: any[]) {
        nodes.forEach((node) =>
          el.appendChild(
            typeof node === 'string' ? { textContent: node } : node,
          ),
        );
      },
      remove: function () {
        const p = parentMap.get(el);
        if (p && Array.isArray(p.children)) {
          p.children = p.children.filter((c: any) => c !== el);
          parentMap.delete(el);
        }
      },
      classList: {
        add() {},
        remove() {},
        toggle() {},
      },
    };
    Object.defineProperty(el, 'options', {
      enumerable: false,
      get() {
        return el.children.filter((c: any) => c && c.tagName === 'OPTION');
      },
    });
    Object.defineProperty(el, 'isConnected', {
      enumerable: false,
      get() {
        let cur: any = el;
        while (cur) {
          if (cur === (globalThis as any).document.body) return true;
          cur = parentMap.get(cur);
        }
        return false;
      },
    });
    return el;
  }

  const bodyEl = createDummyElement('body');

  (globalThis as any).document = {
    body: bodyEl,
    createElement: (tag: string) => createDummyElement(tag) as any,
    createElementNS: (_ns: string, tag: string) =>
      createDummyElement(tag) as any,
    createTextNode: (text: string) => ({ textContent: String(text) }),
    getElementById: (id: string) => {
      let found: any = null;
      walkTree(bodyEl, (node) => {
        if (node.id === id) {
          found = node;
          return true;
        }
      });
      if (!found) {
        const modalRoot = (showModal as any).mock?.calls?.at(-1)?.[1];
        if (modalRoot) {
          walkTree(modalRoot, (node) => {
            if (node.id === id) {
              found = node;
              return true;
            }
          });
        }
      }
      return found;
    },
    addEventListener(type: string, cb: (e?: any) => void) {
      bodyEl.addEventListener(type, cb);
    },
    removeEventListener(type: string, cb: (e?: any) => void) {
      bodyEl.removeEventListener(type, cb);
    },
    querySelector: (sel: string) => bodyEl.querySelector(sel),
    querySelectorAll: (sel: string) => bodyEl.querySelectorAll(sel),
  };

  (globalThis as any).rpc = { declare: vi.fn() };
  (globalThis as any).uci = { sections: vi.fn().mockResolvedValue([]) };
  (globalThis as any).localStorage = { getItem: vi.fn(), setItem: vi.fn() };

  (globalThis as any).E = (tag: string, attrs?: any, children?: any) => {
    const el = (globalThis as any).document.createElement(tag);
    if (attrs) {
      const { style, ...rest } = attrs;
      for (const [k, v] of Object.entries(rest)) {
        if (
          typeof v === 'function' &&
          ['click', 'change', 'input', 'keydown'].includes(k)
        ) {
          el.addEventListener(k, v as (e?: any) => void);
        } else {
          el[k] = v;
        }
      }
      if (typeof style === 'string') {
        el.style.cssText = style;
      } else if (style && typeof style === 'object') {
        Object.assign(el.style, style);
      }
    }
    if (children !== undefined && children !== null) {
      if (Array.isArray(children)) {
        children.forEach((c) => {
          if (c !== null && c !== undefined && c !== false) {
            el.appendChild(
              typeof c === 'string' || typeof c === 'number'
                ? { textContent: String(c) }
                : c,
            );
          }
        });
      } else if (children !== false) {
        el.appendChild(
          typeof children === 'string' || typeof children === 'number'
            ? { textContent: String(children) }
            : children,
        );
      }
    }
    return el;
  };

  (globalThis as any)._ = (s: string) => s;
  (globalThis as any).sprintf = (s: string, ...args: any[]) => {
    let res = s;
    args.forEach((arg) => {
      res = res.replace(/%[sdj]/, String(arg));
    });
    return res;
  };

  (globalThis as any).ui = {
    showModal,
    hideModal,
  };

  return {
    showModal,
    hideModal,
    executeShellCommand,
  };
});

vi.mock('../../../../helpers', async (importOriginal) => ({
  ...((await importOriginal()) as any),
  executeShellCommand: mocks.executeShellCommand,
}));

import { renderStrategyFuzzerModal } from '../partials/renderStrategyFuzzerModal';
import { TachyonShellMethods } from '../../../methods/shell';

describe('renderStrategyFuzzerModal', () => {
  beforeEach(() => {
    mocks.showModal.mockReset();
    mocks.hideModal.mockReset();
    mocks.executeShellCommand.mockReset();
    (globalThis as any).document.body.children = [];
    vi.restoreAllMocks();
    vi.spyOn(TachyonShellMethods, 'getFuzzerStatus').mockResolvedValue({
      success: true,
      data: {
        running: false,
        results: [],
      } as any,
    });
    vi.spyOn(TachyonShellMethods, 'getFuzzerStrategies').mockResolvedValue({
      success: true,
      data: {
        available_engines: {
          desync: true,
        },
        desync: [],
      } as any,
    });
    vi.spyOn(TachyonShellMethods, 'getFuzzerPatterns').mockResolvedValue({
      success: true,
      data: { patterns: { custom_strategies: [] } } as any,
    });
  });

  it('renders and displays the Strategy Fuzzer modal', () => {
    renderStrategyFuzzerModal(['youtube_rule', 'discord_rule']);

    expect(mocks.showModal).toHaveBeenCalledTimes(1);
    expect(mocks.showModal).toHaveBeenCalledWith(
      'Strategy Fuzzer & Auto-Tuner',
      expect.anything(),
    );
  });

  it('handles fuzzer status with successful probe results and best badge', async () => {
    vi.spyOn(TachyonShellMethods, 'getFuzzerStatus').mockResolvedValue({
      success: true,
      data: {
        running: false,
        progress_pct: 100,
        results: [
          {
            id: 'desync_fake_split_midsld',
            name: 'Fake Split (midsld)',
            engine: 'desync',
            args: '--mode=fake_split --split-pos=midsld --repeats=4',
            description: 'Native desync preset',
            success: true,
            http_code: 204,
            handshake_ms: 225,
            ttfb_ms: 271,
            speed_kbps: 2005,
            score: 1029,
            error: '',
            badge: 'Best Match',
          },
        ],
        best_strategy: {
          id: 'desync_fake_split_midsld',
          score: 1029,
        },
      } as any,
    });

    renderStrategyFuzzerModal(['youtube_rule']);

    expect(mocks.showModal).toHaveBeenCalledTimes(1);
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(TachyonShellMethods.getFuzzerStatus).toHaveBeenCalled();
  });

  it('renders rule options with human-readable labels and UCI section IDs', () => {
    renderStrategyFuzzerModal([
      { id: 'direct', label: 'Провайдер Direct' },
      { id: 'jobvpn', label: 'Работа VPN' },
    ]);

    expect(mocks.showModal).toHaveBeenCalledTimes(1);
    expect(mocks.showModal).toHaveBeenCalledWith(
      'Strategy Fuzzer & Auto-Tuner',
      expect.anything(),
    );
  });

  it('excludes global provider fallback and filters rules applicable to the engine', () => {
    renderStrategyFuzzerModal([
      { id: 'youtube_sec', label: 'YouTube Rule', action: 'desync' },
      { id: 'discord_sec', label: 'Discord Rule', action: 'desync' },
      { id: 'other_sec', label: 'Other Rule', action: 'connection' },
    ]);

    expect(mocks.showModal).toHaveBeenCalledTimes(1);
    const modalEl = mocks.showModal.mock.calls[0][1];
    expect(modalEl).toBeDefined();

    // Check that Provider Default is NOT anywhere in the rendered modal
    const renderedText = JSON.stringify(modalEl);
    expect(renderedText).not.toContain('Provider Default (global fallback)');
    expect(renderedText).not.toContain('глобальный фоллбэк');
  });

  it('omits all-engines option and exposes only native desync in the engine selector', () => {
    renderStrategyFuzzerModal([
      { id: 'youtube_sec', label: 'YouTube Rule', action: 'desync' },
    ]);
    const modalEl = mocks.showModal.mock.calls[0][1];
    const selects = modalEl.querySelectorAll('select');
    const engineSelect = selects.find((sel: any) =>
      sel.options.some((opt: any) => opt.value === 'desync'),
    );
    expect(engineSelect).toBeDefined();
    expect(engineSelect.options).toHaveLength(1);
    expect(engineSelect.options[0].value).toBe('desync');
    expect(engineSelect.options.some((opt: any) => opt.value === 'all')).toBe(
      false,
    );
  });

  it('shows native desync across engine selector and patterns tab', async () => {
    renderStrategyFuzzerModal(
      [{ id: 'ds_sec', label: 'Desync Sec', action: 'desync' }],
      {
        availableEngines: {
          desync: true,
        },
      },
    );

    await new Promise((resolve) => setTimeout(resolve, 20));
    const modalEl = mocks.showModal.mock.calls[0][1];
    const selects = modalEl.querySelectorAll('select');
    const engineSelect = selects.find((sel: any) =>
      sel.options.some((opt: any) => opt.value === 'desync'),
    );
    expect(engineSelect).toBeDefined();
    expect(engineSelect.options).toHaveLength(1);
    expect(engineSelect.options[0].value).toBe('desync');
    expect(engineSelect.value).toBe('desync');

    const buttons = modalEl.querySelectorAll('button');
    const patternsTabBtn = buttons.find((b: any) =>
      JSON.stringify(b).includes('Pattern Builder'),
    );
    patternsTabBtn.dispatchEvent({ type: 'click' });
    const customTabBtn = buttons.find((b: any) =>
      JSON.stringify(b).includes('My Strategies'),
    );
    customTabBtn.dispatchEvent({ type: 'click' });

    const serialized = JSON.stringify(modalEl);
    expect(serialized).toContain(
      'Native Desync (tachyon-core) Matrix Patterns',
    );
  });

  it('excludes global sections and plain connection sections without fallback', () => {
    renderStrategyFuzzerModal([
      { id: 'global', label: 'Global', action: 'desync' },
      {
        id: 'global_rule',
        label: 'Global All',
        action: 'desync',
        isGlobal: true,
      } as any,
      { id: 'proxy_conn', label: 'VPN Proxy', action: 'connection' },
      { id: 'empty_act', label: 'Direct', action: '' },
      { id: 'yt_dpi', label: 'YouTube Desync', action: 'desync' },
    ]);

    const modalEl = mocks.showModal.mock.calls[0][1];
    const selects = modalEl.querySelectorAll('select');
    const ruleSelect = selects.find((sel: any) =>
      sel.options.some((opt: any) => opt.value === 'yt_dpi'),
    );
    expect(ruleSelect).toBeDefined();
    const values = ruleSelect.options.map((o: any) => o.value);
    expect(values).toEqual(['yt_dpi']);
  });

  it('unchecks youtube_suite when custom is selected and normalizes bare multi-domain input', async () => {
    const startSpy = vi
      .spyOn(TachyonShellMethods, 'startFuzzer')
      .mockResolvedValue({
        success: true,
        data: { job_id: 'job_custom_1' } as any,
      });

    renderStrategyFuzzerModal([
      { id: 'yt_dpi', label: 'YouTube Desync', action: 'desync' },
    ]);

    const modalEl = mocks.showModal.mock.calls[0][1];
    const checkboxes = modalEl.querySelectorAll('input[type="checkbox"]');
    const ytCb = checkboxes[0];
    const customCb = checkboxes.find(
      (cb: any) =>
        cb !== ytCb &&
        !String(cb.id || '').includes('auto-apply') &&
        cb.checked === false,
    );
    // Custom checkbox is the last target suite checkbox before auto-apply
    expect(ytCb.checked).toBe(true);
    expect(checkboxes.length).toBeGreaterThanOrEqual(12);
    const customSuiteCb = checkboxes[11];
    customSuiteCb.checked = true;
    customSuiteCb.dispatchEvent({ type: 'change' });

    expect(ytCb.checked).toBe(false);
    expect(customCb).toBeDefined();

    const textareas = modalEl.querySelectorAll('textarea');
    expect(textareas.length).toBeGreaterThanOrEqual(1);
    textareas[0].value = 'youtube.com\ndiscord.com, example.org:8443/path';

    const buttons = modalEl.querySelectorAll('button');
    const startBtn = buttons.find((b: any) =>
      JSON.stringify(b).includes('Start Benchmark'),
    );
    startBtn.dispatchEvent({ type: 'click' });
    await new Promise((resolve) => setTimeout(resolve, 20));

    expect(startSpy).toHaveBeenCalledTimes(1);
    expect(startSpy.mock.calls[0][1]).toBe('custom');
    expect(startSpy.mock.calls[0][2]).toBe(
      'https://youtube.com\nhttps://discord.com\nhttps://example.org:8443/path',
    );
  });

  it('supports nestedModal overlay and onApplyStrategy without applyFuzzerStrategy RPC', async () => {
    const applyRpcSpy = vi.spyOn(TachyonShellMethods, 'applyFuzzerStrategy');
    const onApplyStrategy = vi.fn();

    vi.spyOn(TachyonShellMethods, 'getFuzzerStatus').mockResolvedValue({
      success: true,
      data: {
        running: false,
        progress_pct: 100,
        results: [
          {
            id: 'ds_1',
            name: 'Fake Split midsld',
            engine: 'desync',
            args: '--mode=fake_split --split-pos=midsld',
            description: 'Test',
            success: true,
            http_code: 200,
            handshake_ms: 45,
            ttfb_ms: 90,
            speed_kbps: 2048,
            score: 950,
          },
        ],
      } as any,
    });

    renderStrategyFuzzerModal(
      [{ id: 'yt_dpi', label: 'YouTube Desync', action: 'desync' }],
      {
        initialEngine: 'desync',
        initialRuleSection: 'yt_dpi',
        nestedModal: true,
        onApplyStrategy,
      },
    );

    expect(mocks.showModal).not.toHaveBeenCalled();
    expect((globalThis as any).document.body.children.length).toBe(1);

    await new Promise((resolve) => setTimeout(resolve, 20));

    const overlay = (globalThis as any).document.body.children[0];
    const applyBtn = overlay
      .querySelectorAll('button')
      .find((b: any) => JSON.stringify(b).includes('"Apply"') && !b.disabled);
    expect(applyBtn).toBeDefined();
    applyBtn.dispatchEvent({ type: 'click' });
    await new Promise((resolve) => setTimeout(resolve, 20));

    expect(onApplyStrategy).toHaveBeenCalledWith(
      'desync',
      '--mode=fake_split --split-pos=midsld',
      expect.objectContaining({ id: 'ds_1' }),
    );
    expect(applyRpcSpy).not.toHaveBeenCalled();
    expect((globalThis as any).document.body.children.length).toBe(0);
  });
});
