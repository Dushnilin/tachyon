/* eslint-disable @typescript-eslint/no-explicit-any */
import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => {
  const byId = new Map<string, any>();

  function createEl(tag: string) {
    const listeners: Record<string, Array<(ev?: any) => void>> = {};
    const el: any = {
      tagName: tag.toUpperCase(),
      children: [] as any[],
      style: {} as Record<string, string>,
      textContent: '',
      value: '',
      disabled: false,
      class: '',
      id: '',
      get childNodes() {
        return this.children;
      },
      set innerHTML(val: string) {
        if (val === '') {
          this.children = [];
          this.textContent = '';
        }
      },
      get innerHTML() {
        return this.textContent;
      },
      setAttribute(k: string, v: string) {
        this[k] = v;
        if (k === 'id') byId.set(v, this);
      },
      getAttribute(k: string) {
        return this[k] ?? null;
      },
      addEventListener(type: string, fn: (ev?: any) => void) {
        listeners[type] = listeners[type] || [];
        listeners[type].push(fn);
      },
      click() {
        if (typeof this.onclick === 'function') {
          this.onclick({});
        }
        (listeners.click || []).forEach((fn) => fn({}));
      },
      appendChild(node: any) {
        if (node && typeof node === 'object') {
          this.children.push(node);
          if (node.id) byId.set(node.id, node);
        } else if (node != null) {
          this.textContent += String(node);
        }
        return node;
      },
      append(...nodes: any[]) {
        nodes.forEach((n) => this.appendChild(n));
      },
      replaceChildren(...nodes: any[]) {
        this.children = [];
        nodes.forEach((n) => this.appendChild(n));
      },
      querySelector: () => null,
      querySelectorAll: () => [],
      classList: { add() {}, remove() {} },
    };
    return el;
  }

  (globalThis as any).document = {
    body: createEl('body'),
    createElement: (tag: string) => createEl(tag),
    createElementNS: (_ns: string, tag: string) => createEl(tag),
    createTextNode: (txt: string) => ({
      nodeType: 3,
      textContent: String(txt),
    }),
    getElementById: (id: string) => byId.get(id) ?? null,
    querySelector: () => null,
    querySelectorAll: () => [],
  };

  (globalThis as any).E = (tag: string, attrs?: any, children?: any) => {
    const el = (globalThis as any).document.createElement(tag);
    if (attrs) {
      const { style, click, ...rest } = attrs;
      Object.assign(el, rest);
      if (el.id) byId.set(el.id, el);
      if (typeof click === 'function') {
        el.addEventListener('click', click);
      }
      if (style && typeof style === 'string') {
        style.split(';').forEach((rule: string) => {
          const [k, v] = rule.split(':').map((s: string) => s.trim());
          if (k && v) el.style[k] = v;
        });
      } else if (style && typeof style === 'object') {
        Object.assign(el.style, style);
      }
    }
    if (children !== undefined && children !== null) {
      if (Array.isArray(children)) {
        children.forEach((c) => {
          if (c != null) el.appendChild(c);
        });
      } else {
        el.appendChild(children);
      }
    }
    return el;
  };

  (globalThis as any)._ = (str: string) => str;
  (globalThis as any).rpc = { declare: vi.fn() };
  (globalThis as any).uci = { sections: vi.fn().mockResolvedValue([]) };
  (globalThis as any).localStorage = { getItem: vi.fn(), setItem: vi.fn() };

  const showModal = vi.fn();
  const hideModal = vi.fn();
  (globalThis as any).ui = { showModal, hideModal, addNotification: vi.fn() };

  const callBaseMethod = vi.fn();
  return { byId, showModal, hideModal, callBaseMethod };
});

vi.mock('../../../methods/shell/callBaseMethod', () => ({
  callBaseMethod: (...args: any[]) => mocks.callBaseMethod(...args),
}));

import { renderServiceCheckModal } from '../partials/renderServiceCheckModal';

function collectNodes(root: any, pred: (n: any) => boolean): any[] {
  const found: any[] = [];
  const walk = (n: any) => {
    if (!n || typeof n !== 'object') return;
    if (pred(n)) found.push(n);
    if (Array.isArray(n.children)) {
      n.children.forEach(walk);
    }
  };
  walk(root);
  return found;
}

describe('renderServiceCheckModal', () => {
  beforeEach(() => {
    mocks.byId.clear();
    mocks.showModal.mockReset();
    mocks.hideModal.mockReset();
    mocks.callBaseMethod.mockReset();
  });

  it('loads active targets, renders fixed-layout table, and auto-runs domain probes', async () => {
    vi.useFakeTimers();
    mocks.callBaseMethod.mockImplementation(
      async (_method: string, args?: string[]) => {
        if (args?.[0] === 'get-targets') {
          return {
            success: true,
            data: [
              {
                section: 'YouTube',
                route_type: 'desync',
                domain: 'www.youtube.com',
              },
              {
                section: 'GitHub',
                route_type: 'proxy',
                domain: 'github.com',
              },
            ],
          };
        }
        if (args?.[0] === 'check-domain') {
          const target = JSON.parse(args[1] || '{}');
          return {
            success: true,
            data: [
              {
                ...target,
                ip: '142.250.74.14',
                dns_ms: 12,
                tcp_ms: 28,
                tls_ms: 54,
                http_ms: 118,
                status_class: 'OK',
                success: true,
              },
            ],
          };
        }
        return { success: false };
      },
    );

    renderServiceCheckModal();
    expect(mocks.showModal).toHaveBeenCalledTimes(1);

    await vi.runAllTimersAsync();

    expect(mocks.callBaseMethod).toHaveBeenCalledWith('service_health_check', [
      'get-targets',
    ]);
    const domainCalls = mocks.callBaseMethod.mock.calls.filter(
      (c) => c[1]?.[0] === 'check-domain',
    );
    expect(domainCalls).toHaveLength(2);

    const modalRoot = mocks.showModal.mock.calls[0][1];
    const tables = collectNodes(modalRoot, (n) => n.tagName === 'TABLE');
    expect(tables.length).toBeGreaterThan(0);
    expect(tables[0].style['table-layout']).toBe('fixed');

    vi.useRealTimers();
  });

  it('handles failed get-targets response cleanly without crashing', async () => {
    mocks.callBaseMethod.mockResolvedValue({ success: false });

    renderServiceCheckModal();
    await Promise.resolve();
    await Promise.resolve();

    expect(mocks.showModal).toHaveBeenCalledTimes(1);
    const modalRoot = mocks.showModal.mock.calls[0][1];
    const paragraphs = collectNodes(
      modalRoot,
      (n) =>
        n.tagName === 'P' &&
        String(n.textContent).includes('Failed to start service check.'),
    );
    expect(paragraphs.length).toBe(1);
  });
});
