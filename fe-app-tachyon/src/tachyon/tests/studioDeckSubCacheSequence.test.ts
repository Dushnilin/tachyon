/* eslint-disable @typescript-eslint/no-explicit-any */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { mountTachyonStudioDeck } from '../studioDeck';

interface Deferred<T> {
  promise: Promise<T>;
  resolve: (value: T) => void;
  reject: (err: unknown) => void;
}

function createDeferred<T>(): Deferred<T> {
  let resolve!: (value: T) => void;
  let reject!: (err: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

class MockClassList {
  private set = new Set<string>();
  constructor(initial = '') {
    this.setFromString(initial);
  }
  setFromString(raw: string) {
    this.set = new Set(
      String(raw || '')
        .split(/\s+/)
        .filter(Boolean),
    );
  }
  add(...names: string[]) {
    names.forEach((n) => this.set.add(n));
  }
  remove(...names: string[]) {
    names.forEach((n) => this.set.delete(n));
  }
  contains(name: string) {
    return this.set.has(name);
  }
  toString() {
    return Array.from(this.set).join(' ');
  }
}

class MockElement {
  tagName: string;
  attributes: Record<string, string> = {};
  children: MockElement[] = [];
  parentNode: MockElement | null = null;
  style: Record<string, string> = {};
  classList = new MockClassList();
  listeners: Record<string, ((ev: any) => void)[]> = {};
  private _text = '';

  constructor(tagName = 'div') {
    this.tagName = tagName.toLowerCase();
  }

  get className() {
    return this.classList.toString();
  }
  set className(val: string) {
    this.classList.setFromString(val);
  }

  get innerHTML() {
    return this._text;
  }
  set innerHTML(val: string) {
    this._text = val;
    if (val === '') {
      this.children = [];
    }
  }

  get textContent(): string {
    return [this._text, ...this.children.map((c) => c.textContent)].join('');
  }
  set textContent(val: string) {
    this._text = String(val ?? '');
    this.children = [];
  }

  get firstChild(): MockElement | null {
    return this.children[0] || null;
  }

  setAttribute(k: string, v: string) {
    if (k === 'class') {
      this.className = v;
    } else {
      this.attributes[k] = String(v);
    }
  }
  getAttribute(k: string): string | null {
    if (k === 'class') return this.className;
    return Object.prototype.hasOwnProperty.call(this.attributes, k)
      ? this.attributes[k]
      : null;
  }

  appendChild(child: MockElement | string | null | undefined) {
    if (child == null) return child;
    if (typeof child === 'string') {
      this._text += child;
      return child;
    }
    child.parentNode = this;
    this.children.push(child);
    return child;
  }

  prepend(child: MockElement) {
    child.parentNode = this;
    this.children.unshift(child);
    return child;
  }

  replaceChildren(...nodes: (MockElement | string | null | undefined)[]) {
    this.children = [];
    this._text = '';
    for (const node of nodes) {
      this.appendChild(node);
    }
  }

  insertBefore(child: MockElement, ref: MockElement | null) {
    child.parentNode = this;
    const idx = ref ? this.children.indexOf(ref) : -1;
    if (idx >= 0) {
      this.children.splice(idx, 0, child);
    } else {
      this.children.push(child);
    }
    return child;
  }

  remove() {
    if (!this.parentNode) return;
    this.parentNode.children = this.parentNode.children.filter(
      (c) => c !== this,
    );
    this.parentNode = null;
  }

  addEventListener(type: string, fn: (ev: any) => void) {
    if (!this.listeners[type]) this.listeners[type] = [];
    this.listeners[type].push(fn);
  }

  removeEventListener(type: string, fn: (ev: any) => void) {
    if (!this.listeners[type]) return;
    this.listeners[type] = this.listeners[type].filter((f) => f !== fn);
  }

  click() {
    const ev = {
      type: 'click',
      target: this,
      preventDefault: () => {},
      stopPropagation: () => {},
    };
    (this.listeners.click || []).forEach((fn) => fn(ev));
  }

  private matchesSelector(sel: string): boolean {
    const trimmed = sel.trim();
    if (trimmed.startsWith('.')) {
      return this.classList.contains(trimmed.slice(1));
    }
    return this.tagName === trimmed.toLowerCase();
  }

  querySelectorAll(sel: string): MockElement[] {
    const parts = sel.split(',').map((s) => s.trim());
    const out: MockElement[] = [];
    const walk = (node: MockElement) => {
      for (const ch of node.children) {
        if (parts.some((p) => ch.matchesSelector(p))) {
          out.push(ch);
        }
        walk(ch);
      }
    };
    walk(this);
    return out;
  }

  querySelector(sel: string): MockElement | null {
    return this.querySelectorAll(sel)[0] || null;
  }
}

function makeE() {
  return function E(
    tag: string,
    attrs?: Record<string, any> | null,
    children?: any,
  ): MockElement {
    const el = new MockElement(tag);
    if (attrs && typeof attrs === 'object') {
      for (const [k, v] of Object.entries(attrs)) {
        if (v === null || v === undefined || v === false) continue;
        if (k === 'click' && typeof v === 'function') {
          el.addEventListener('click', v);
        } else if (typeof v === 'function') {
          el.addEventListener(k, v);
        } else {
          el.setAttribute(k, String(v));
        }
      }
    }
    const items = Array.isArray(children)
      ? children
      : children !== undefined && children !== null
        ? [children]
        : [];
    for (const item of items) {
      if (item == null || item === false) continue;
      if (item instanceof MockElement) {
        el.appendChild(item);
      } else {
        el.appendChild(String(item));
      }
    }
    return el;
  };
}

async function flushMicrotasks(rounds = 8) {
  for (let i = 0; i < rounds; i += 1) {
    await Promise.resolve();
  }
}

describe('PR #506: studioDeck atomic subCacheLoadSequence', () => {
  const g = globalThis as Record<string, any>;
  const savedGlobals: Record<string, any> = {};
  const keysToRestore = ['E', 'uci', 'fs', 'ui', 'L', 'document', 'window'];

  beforeEach(() => {
    for (const k of keysToRestore) {
      savedGlobals[k] = g[k];
    }
  });

  afterEach(() => {
    for (const k of keysToRestore) {
      if (savedGlobals[k] === undefined) {
        delete g[k];
      } else {
        g[k] = savedGlobals[k];
      }
    }
  });

  it('ignores stale out-of-order subscription cache load and preserves fresh node count', async () => {
    const subRecord = {
      '.name': 'sub1',
      '.type': 'outbound_source',
      enabled: '1',
      source_type: 'subscription',
      name: 'Main Sub',
      url: 'https://example.com/sub.txt',
    };
    const allRecords: Record<string, any> = { sub1: subRecord };

    g.E = makeE();
    g.L = { env: { lang: 'en' } };
    g.ui = { addNotification: vi.fn() };
    g.document = {
      createElementNS: (_ns: string, tag: string) => new MockElement(tag),
      createElement: (tag: string) => new MockElement(tag),
      querySelector: () => null,
      querySelectorAll: () => [],
      getElementById: () => null,
      addEventListener: () => {},
      removeEventListener: () => {},
    };
    g.window = {
      setTimeout: (fn: () => void) => {
        fn();
        return 0;
      },
      clearTimeout: () => {},
      addEventListener: () => {},
      removeEventListener: () => {},
      dispatchEvent: () => true,
    };
    g.uci = {
      sections: (_pkg: string, typeName: string) =>
        Object.values(allRecords).filter((r) => r['.type'] === typeName),
      get: (_pkg: string, sid: string, opt?: string) => {
        const rec = allRecords[sid];
        if (!rec) return null;
        return opt ? (rec[opt] ?? null) : rec;
      },
      set: vi.fn(),
      unset: vi.fn(),
    };

    const staleJsonDeferred = createDeferred<string>();
    let jsonReadCount = 0;

    const makeSubPayload = (count: number) =>
      JSON.stringify({
        outbounds: Array.from({ length: count }, (_v, i) => ({
          type: 'vless',
          tag: `node-${i + 1}`,
          remark: `Node ${i + 1}`,
        })),
      });

    g.fs = {
      list: vi.fn((dir: string) => {
        if (dir === '/etc/tachyon/subscription-cache') {
          return Promise.resolve([
            { name: 'Pool_sub1-subscription-1.url', mtime: 100 },
            { name: 'Pool_sub1-subscription-1.json', mtime: 100 },
          ]);
        }
        return Promise.resolve([]);
      }),
      read: vi.fn((filePath: string) => {
        if (
          filePath ===
          '/etc/tachyon/subscription-cache/Pool_sub1-subscription-1.url'
        ) {
          return Promise.resolve('https://example.com/sub.txt');
        }
        if (
          filePath ===
          '/etc/tachyon/subscription-cache/Pool_sub1-subscription-1.json'
        ) {
          jsonReadCount += 1;
          if (jsonReadCount === 1) {
            return staleJsonDeferred.promise;
          }
          return Promise.resolve(makeSubPayload(6));
        }
        return Promise.resolve('');
      }),
      exec: vi.fn(() =>
        Promise.resolve({ stdout: JSON.stringify({ success: true }) }),
      ),
    };

    const containerEl = new MockElement('div');
    mountTachyonStudioDeck({
      type: 'outbound_source',
      sectionRef: { cfgsections: () => ['sub1'] },
      containerEl: containerEl as unknown as HTMLElement,
    });

    await vi.waitFor(() => {
      expect(jsonReadCount).toBe(1);
    });

    const updateBtn = containerEl
      .querySelectorAll('button')
      .find((b) => b.getAttribute('title') === 'Update this subscription now');
    expect(updateBtn).toBeDefined();

    updateBtn!.click();

    await vi.waitFor(() => {
      expect(jsonReadCount).toBe(2);
      expect(containerEl.textContent).toContain('Nodes: 6');
    });

    staleJsonDeferred.resolve(makeSubPayload(2));
    await flushMicrotasks(30);
    await new Promise((r) => setTimeout(r, 10));

    expect(containerEl.textContent).toContain('Nodes: 6');
    expect(containerEl.textContent).not.toContain('Nodes: 2');
  });
});
