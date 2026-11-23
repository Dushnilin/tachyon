/* eslint-disable @typescript-eslint/no-explicit-any */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const mockCallBaseMethod = vi.fn();

vi.mock('./methods/shell/callBaseMethod', () => ({
  callBaseMethod: (...args: any[]) => mockCallBaseMethod(...args),
}));

vi.mock('./helpers/i18n', () => ({
  tr: (_ru: string, en: string) => en,
}));

function makeEl(tag: string, attrs?: any, children?: any) {
  const el: any = {
    tagName: tag.toUpperCase(),
    attributes: {} as Record<string, string>,
    children: [] as any[],
    textContent: '',
    value: '',
    disabled: false,
    isConnected: true,
    className: '',
    listeners: {} as Record<string, (...a: any[]) => any>,
    setAttribute(k: string, v: string) {
      this.attributes[k] = String(v);
    },
    getAttribute(k: string) {
      return this.attributes[k] ?? null;
    },
    removeAttribute(k: string) {
      delete this.attributes[k];
    },
    append(...nodes: any[]) {
      for (const n of nodes) {
        if (n != null) this.children.push(n);
      }
    },
    appendChild(node: any) {
      if (node != null) this.children.push(node);
      return node;
    },
    replaceChildren(...nodes: any[]) {
      this.children = nodes.filter((n) => n != null);
    },
  };

  if (attrs && typeof attrs === 'object') {
    for (const [k, v] of Object.entries(attrs)) {
      if (typeof v === 'function') {
        el.listeners[k] = v as (...a: any[]) => any;
      } else if (k === 'class') {
        el.className = String(v);
      } else if (v !== undefined) {
        el.attributes[k] = String(v);
      }
    }
  }

  const pushChild = (c: any) => {
    if (c == null || c === false) return;
    if (Array.isArray(c)) {
      c.forEach(pushChild);
    } else if (typeof c === 'string' || typeof c === 'number') {
      const s = String(c);
      el.children.push(s);
      el.textContent += s;
    } else {
      el.children.push(c);
    }
  };
  if (children !== undefined) {
    pushChild(children);
  }
  return el;
}

function collectText(node: any): string {
  if (node == null) return '';
  if (typeof node === 'string' || typeof node === 'number') return String(node);
  if (Array.isArray(node)) return node.map(collectText).join('');
  if (Array.isArray(node.children) && node.children.length > 0) {
    return node.children.map(collectText).join('');
  }
  return typeof node.textContent === 'string' ? node.textContent : '';
}

function findAllByTag(root: any, tag: string, acc: any[] = []): any[] {
  if (!root || typeof root !== 'object') return acc;
  if (Array.isArray(root)) {
    root.forEach((n) => findAllByTag(n, tag, acc));
    return acc;
  }
  if (root.tagName === tag.toUpperCase()) acc.push(root);
  if (Array.isArray(root.children)) {
    root.children.forEach((c: any) => findAllByTag(c, tag, acc));
  }
  return acc;
}

function findByPredicate(root: any, pred: (n: any) => boolean): any {
  if (!root || typeof root !== 'object') return null;
  if (Array.isArray(root)) {
    for (const item of root) {
      const hit = findByPredicate(item, pred);
      if (hit) return hit;
    }
    return null;
  }
  if (pred(root)) return root;
  if (Array.isArray(root.children)) {
    return findByPredicate(root.children, pred);
  }
  return null;
}

describe('switchHistory modal', () => {
  const showModal = vi.fn();
  const hideModal = vi.fn();

  beforeEach(() => {
    mockCallBaseMethod.mockReset();
    showModal.mockReset();
    hideModal.mockReset();
    (globalThis as any).E = makeEl;
    (globalThis as any).ui = { showModal, hideModal };
    (globalThis as any).document = {
      createElement: (tag: string) => makeEl(tag),
      createElementNS: (_ns: string, tag: string) => makeEl(tag),
    };
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('handles zero, invalid timestamps and missing delay without undefined ms', async () => {
    mockCallBaseMethod.mockResolvedValue({
      success: true,
      data: {
        events: [
          {
            timestamp: 0,
            group: 'Proxy',
            from: '',
            to: 'NodeA',
            reason: 'initial',
            source: 'core_failover',
            observed: true,
            from_delay_ms: 42,
            to_delay_ms: undefined,
          },
          {
            timestamp: Number.NaN,
            group: 'Proxy',
            from: 'NodeA',
            to: 'NodeB',
            reason: 'failover',
            source: 'core_failover',
            observed: true,
            to_delay_ms: 55,
          },
        ],
      },
    });

    const { openSwitchHistory } = await import('./switchHistory');
    openSwitchHistory();

    await vi.waitFor(() => {
      expect(mockCallBaseMethod).toHaveBeenCalledTimes(1);
    });
    await new Promise((r) => setTimeout(r, 0));

    const modalBody = showModal.mock.calls[0][1];
    const renderedText = collectText(modalBody);
    expect(renderedText).not.toContain('undefined ms');
    expect(renderedText).not.toContain('undefined мс');
    expect(renderedText).not.toContain('Invalid Date');
    expect(renderedText).toContain('— → 55 ms');

    const times = findAllByTag(modalBody, 'time');
    expect(times).toHaveLength(2);
    expect(times[0].getAttribute('dateTime')).toBeNull();
    expect(times[1].getAttribute('dateTime')).toBeNull();
  });

  it('always unlocks refresh button and clears aria-busy on RPC rejection', async () => {
    mockCallBaseMethod.mockRejectedValue(new Error('network boom'));

    const { openSwitchHistory } = await import('./switchHistory');
    openSwitchHistory();

    await vi.waitFor(() => {
      expect(mockCallBaseMethod).toHaveBeenCalledTimes(1);
    });
    await new Promise((r) => setTimeout(r, 0));

    const modalBody = showModal.mock.calls[0][1];
    const refreshBtn = findAllByTag(modalBody, 'button')[0];
    const listEl = findByPredicate(modalBody, (n: any) =>
      String(n.className || '').includes('tachyon-switch-history__list'),
    );
    const statusEl = findByPredicate(
      modalBody,
      (n: any) => n.getAttribute?.('role') === 'status',
    );

    expect(refreshBtn.disabled).toBe(false);
    expect(listEl.getAttribute('aria-busy')).toBeNull();
    expect(statusEl.textContent).toBe('Switch history is unavailable');
  });
});
