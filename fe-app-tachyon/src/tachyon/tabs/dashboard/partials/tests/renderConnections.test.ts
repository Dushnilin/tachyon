/* eslint-disable @typescript-eslint/no-explicit-any */
import { describe, it, expect, vi } from 'vitest';

const _mocks = vi.hoisted(() => {
  class MockMutationObserver {
    observe() {}
    disconnect() {}
    takeRecords() {
      return [];
    }
  }
  (globalThis as any).MutationObserver = MockMutationObserver;

  function createDummyElement(tag: string) {
    const children: any[] = [];
    return {
      tagName: tag.toUpperCase(),
      children,
      childNodes: children,
      style: {} as Record<string, string>,
      className: '',
      class: '',
      get classList() {
        const self = this as any;
        return {
          contains(c: string) {
            const list = (self.class || self.className || '').split(/\s+/);
            return list.includes(c);
          },
        };
      },
      get textContent(): string {
        let text = '';
        for (const c of children) {
          if (typeof c === 'string' || typeof c === 'number') {
            text += c;
          } else if (c && typeof c.textContent === 'string') {
            text += c.textContent;
          }
        }
        return text;
      },
      set textContent(val: string) {
        children.length = 0;
        if (val) children.push(val);
      },
      setAttribute(name: string, val: string) {
        (this as any)[name] = val;
        if (name === 'class') {
          this.className = val;
        }
      },
      getAttribute(name: string) {
        return (this as any)[name] ?? null;
      },
      querySelectorAll(selector: string): any[] {
        const results: any[] = [];
        function traverse(node: any) {
          if (!node || typeof node !== 'object') return;
          if (selector.startsWith('.')) {
            const targetClasses = selector.split('.').filter(Boolean);
            const classes = (node.class || node.className || '').split(/\s+/);
            if (targetClasses.every((tc: string) => classes.includes(tc))) {
              results.push(node);
            }
          }
          if (Array.isArray(node.children)) {
            for (const child of node.children) {
              traverse(child);
            }
          }
        }
        traverse(this);
        return results;
      },
      querySelector(selector: string): any {
        return this.querySelectorAll(selector)[0] || null;
      },
      appendChild(node: any) {
        children.push(node);
      },
    };
  }

  (globalThis as any).document = {
    body: createDummyElement('body') as any,
    createElement: (tag: string) => createDummyElement(tag) as any,
    createElementNS: (_ns: string, tag: string) =>
      createDummyElement(tag) as any,
    querySelectorAll: () => [],
    querySelector: () => null,
    getElementById: () => null,
  } as any;

  (globalThis as any).rpc = { declare: vi.fn() };
  (globalThis as any).localStorage = { getItem: vi.fn(), setItem: vi.fn() };

  (globalThis as any).E = (tag: string, attrs?: any, children?: any) => {
    const el = (globalThis as any).document.createElement(tag);
    if (attrs) {
      for (const [k, v] of Object.entries(attrs)) {
        if (k === 'class' || k === 'className') {
          el.className = v;
          el.class = v;
        } else if (k === 'style') {
          el.style = v;
        } else {
          el.setAttribute(k, v);
        }
      }
    }
    if (children) {
      const childArr = Array.isArray(children) ? children : [children];
      for (const c of childArr) {
        if (c != null && c !== '') {
          el.appendChild(c);
        }
      }
    }
    return el;
  };

  (globalThis as any)._ = (k: string) => k;
});

import {
  renderConnections,
  patchConnections,
  patchExistingClientRowsByIp,
  IConnection,
} from '../renderConnections';

describe('renderConnections', () => {
  it('renders badges for host, mac address, and router correctly', () => {
    const connections: IConnection[] = [
      {
        ip: '10.100.100.185',
        name: 'Mac.lan',
        count: 12,
        upload: 232 * 1024 * 1024,
        download: 3030000,
      },
      {
        ip: '10.100.100.153',
        name: '26:70:52:CD:8E:F9',
        count: 101,
        upload: 9 * 1024 * 1024,
        download: 40 * 1024 * 1024,
      },
      {
        ip: '127.0.0.1',
        name: 'Flint-2',
        count: 1,
        upload: 707,
        download: 5200,
      },
      {
        ip: '95.165.105.233',
        name: 'Роутер (WAN)',
        count: 4,
        upload: 0,
        download: 0,
      },
      {
        ip: '10.100.100.99',
        count: 1,
        upload: 10,
        download: 20,
      },
    ];

    const container = renderConnections(connections, false, () => {});

    // Check host badge
    const hostBadge = container.querySelector(
      '.tachyon-client-row__name-badge--host',
    );
    expect(hostBadge).not.toBeNull();
    expect(hostBadge?.textContent).toBe('Mac.lan');

    // Check MAC badge and popover
    const macBadge = container.querySelector(
      '.tachyon-client-row__name-badge--mac',
    );
    expect(macBadge).not.toBeNull();
    expect(macBadge?.classList.contains('tachyon_proto-popover-trigger')).toBe(
      true,
    );
    const popover = macBadge?.querySelector('.tachyon_proto-popover');
    expect(popover).not.toBeNull();
    expect(
      popover?.querySelector('.tachyon_proto-popover__header')?.textContent,
    ).toBe('26:70:52:CD:8E:F9');
    expect(
      popover?.querySelector('.tachyon_proto-popover__desc')?.textContent,
    ).toMatch(/Устройство не передаёт своё имя|Device does not broadcast/);

    // Check router badges
    const routerBadges = container.querySelectorAll(
      '.tachyon-client-row__name-badge--router',
    );
    expect(routerBadges.length).toBe(2);
    expect(routerBadges[0].textContent).toBe('Flint-2');
    expect(routerBadges[1].textContent).toBe('Роутер (WAN)');

    // Check standalone IP for connection without name
    const standaloneIp = container.querySelector(
      '.tachyon-client-row__ip--standalone',
    );
    expect(standaloneIp).not.toBeNull();
    expect(standaloneIp?.textContent).toBe('10.100.100.99');
  });

  it('renders empty state when there are no connections', () => {
    const container = renderConnections([], false, () => {});
    const emptyEl = container.querySelector('.tachyon-clients-empty');
    expect(emptyEl).not.toBeNull();
    expect(emptyEl?.textContent).toMatch(
      /Нет активных клиентов|No active clients/,
    );
  });

  it('patches connections in-place without replacing DOM nodes', () => {
    const initialConnections: IConnection[] = [
      {
        ip: '10.100.100.153',
        name: '26:70:52:CD:8E:F9',
        count: 5,
        upload: 1000,
        download: 2000,
      },
      {
        ip: '127.0.0.1',
        name: 'Flint-2',
        count: 1,
        upload: 50,
        download: 100,
      },
    ];

    const container = renderConnections(initialConnections, false, () => {});
    const initialRows = container.querySelectorAll('.tachyon-client-row');
    expect(initialRows.length).toBe(2);

    const macRow = initialRows[0];
    const macPopover = macRow.querySelector('.tachyon_proto-popover');
    expect(macPopover).not.toBeNull();

    // Verify initial values
    expect(
      macRow.querySelector('.tachyon-client-row__conns')?.textContent,
    ).toMatch(/^5 (соед\.|conns)$/);

    // Update counts and traffic
    const updatedConnections: IConnection[] = [
      {
        ip: '10.100.100.153',
        name: '26:70:52:CD:8E:F9',
        count: 15,
        upload: 5000000,
        download: 10000000,
      },
      {
        ip: '127.0.0.1',
        name: 'Flint-2',
        count: 3,
        upload: 200,
        download: 400,
      },
    ];

    const patched = patchConnections(container, updatedConnections, false);
    expect(patched).toBe(true);

    const currentRows = container.querySelectorAll('.tachyon-client-row');
    expect(currentRows.length).toBe(2);
    // Strict identity check: DOM elements must NOT be replaced!
    expect(currentRows[0]).toBe(macRow);
    expect(currentRows[0].querySelector('.tachyon_proto-popover')).toBe(
      macPopover,
    );

    // Verify values updated in-place
    expect(
      currentRows[0].querySelector('.tachyon-client-row__conns')?.textContent,
    ).toMatch(/^15 (соед\.|conns)$/);
  });

  it('returns false when client structure or IPs change', () => {
    const initialConnections: IConnection[] = [
      {
        ip: '10.100.100.153',
        name: '26:70:52:CD:8E:F9',
        count: 5,
        upload: 1000,
        download: 2000,
      },
    ];
    const container = renderConnections(initialConnections, false, () => {});

    // Mismatched IP
    const mismatchedConnections: IConnection[] = [
      {
        ip: '10.100.100.199',
        name: '26:70:52:CD:8E:F9',
        count: 5,
        upload: 1000,
        download: 2000,
      },
    ];
    expect(patchConnections(container, mismatchedConnections, false)).toBe(
      false,
    );

    // Changed count of clients
    expect(patchConnections(container, [], false)).toBe(false);

    // Changed collapse state
    expect(patchConnections(container, initialConnections, true)).toBe(false);
  });

  it('patchExistingClientRowsByIp updates traffic on matching rows even when list differs', () => {
    const initialConnections: IConnection[] = [
      {
        ip: '10.100.100.153',
        name: '26:70:52:CD:8E:F9',
        count: 5,
        upload: 1000,
        download: 2000,
      },
    ];
    const container = renderConnections(initialConnections, false, () => {});

    patchExistingClientRowsByIp(container, [
      {
        ip: '10.100.100.153',
        count: 99,
        upload: 9999,
        download: 8888,
      },
      {
        ip: '10.100.100.200',
        count: 1,
        upload: 10,
        download: 20,
      },
    ]);

    const row = container.querySelector('.tachyon-client-row');
    expect(
      row?.querySelector('.tachyon-client-row__conns')?.textContent,
    ).toMatch(/^99 (соед\.|conns)$/);
  });
});
