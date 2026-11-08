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

  function createDummyElement(tag: string): any {
    const classSet = new Set<string>();
    const listeners: Record<string, Array<(...args: any[]) => void>> = {};
    const el: any = {
      tagName: tag.toUpperCase(),
      children: [] as any[],
      style: {} as Record<string, string>,
      textContent: '',
      innerHTML: '',
      isConnected: true,
      setAttribute() {},
      getAttribute() {
        return null;
      },
      addEventListener(type: string, cb: (...args: any[]) => void) {
        listeners[type] = listeners[type] || [];
        listeners[type].push(cb);
      },
      click() {
        (listeners.click || []).forEach((fn) =>
          fn({ stopPropagation() {}, preventDefault() {} }),
        );
      },
      querySelectorAll(selector: string): any[] {
        const cls = selector.startsWith('.') ? selector.slice(1) : selector;
        const results: any[] = [];
        const walk = (node: any) => {
          if (!node || typeof node !== 'object') return;
          if (node.classList?.contains?.(cls)) {
            results.push(node);
          }
          (node.children || []).forEach(walk);
        };
        (el.children || []).forEach(walk);
        return results;
      },
      querySelector(selector: string): any {
        return el.querySelectorAll(selector)[0] ?? null;
      },
      replaceChildren(...nodes: any[]) {
        el.children = nodes.filter(Boolean);
      },
      appendChild(node: any) {
        if (node) el.children.push(node);
        return node;
      },
      classList: {
        add(...names: string[]) {
          names.forEach((n) => classSet.add(n));
        },
        remove(...names: string[]) {
          names.forEach((n) => classSet.delete(n));
        },
        contains(name: string) {
          return classSet.has(name);
        },
      },
    };
    return el;
  }

  (globalThis as any).document = {
    body: createDummyElement('body'),
    createElement: (tag: string) => createDummyElement(tag),
    createElementNS: (_ns: string, tag: string) => createDummyElement(tag),
    createTextNode: (text: string) => ({ textContent: text }),
    getElementById: () => null,
    querySelector: () => null,
    querySelectorAll: () => [],
    execCommand: vi.fn().mockReturnValue(true),
  };

  (globalThis as any).E = (tag: string, attrs?: any, children?: any) => {
    const el = (globalThis as any).document.createElement(tag);
    if (attrs) {
      const { style, class: className, click, ...rest } = attrs;
      Object.assign(el, rest);
      if (typeof className === 'string') {
        className
          .split(/\s+/)
          .filter(Boolean)
          .forEach((c) => el.classList.add(c));
      }
      if (typeof click === 'function') {
        el.addEventListener('click', click);
      }
      if (style && typeof style === 'string') {
        el.style.cssText = style;
      }
    }
    if (children !== undefined && children !== null) {
      const appendOne = (c: any) => {
        if (c === undefined || c === null) return;
        if (typeof c === 'string' || typeof c === 'number') {
          el.textContent += String(c);
          el.appendChild({ textContent: String(c) });
        } else {
          el.appendChild(c);
        }
      };
      if (Array.isArray(children)) {
        children.forEach(appendOne);
      } else {
        appendOne(children);
      }
    }
    return el;
  };

  const showModal = vi.fn();
  const hideModal = vi.fn();
  (globalThis as any).ui = { showModal, hideModal };
  (globalThis as any)._ = (s: string) => s;

  return { showModal, hideModal };
});

vi.mock('../../../services/tab.service', () => ({
  TabService: {
    getInstance: () => ({ isActive: () => true }),
  },
}));

import {
  areAllCheckCardsExpanded,
  clearExpandedCheckCards,
  collapseHealthyCheckCards,
  expandAllCheckCards,
  renderCheckSection,
} from '../partials/renderCheckSection';
import {
  renderDiagnosticsModal,
  updateDiagnosticsModalIfOpen,
} from '../partials/renderDiagnosticsModal';
import { store } from '../../../services';

describe('diagnostics auto-expand and modal view', () => {
  beforeEach(() => {
    clearExpandedCheckCards();
    mocks.showModal.mockReset();
    mocks.hideModal.mockReset();
  });

  it('auto-expands only error check cards (keeps warning cards collapsed even if they contain a failed sub-item) and sorts failed items first', () => {
    const warningCard = renderCheckSection({
      code: 'INBOUNDS' as any,
      order: 2,
      title: 'Inbounds checks',
      description: 'Warnings found',
      state: 'warning',
      items: [
        { state: 'warning', key: 'WAN public IP', value: 'Not detected' },
        { state: 'success', key: 'Listening port', value: '0.0.0.0:443' },
      ],
    });
    expect(
      warningCard.classList.contains('tachyon_diagnostic_alert--expanded'),
    ).toBe(false);

    const partialWarningCardWithFailedItem = renderCheckSection({
      code: 'OUTBOUNDS' as any,
      order: 5,
      title: 'Outbounds checks',
      description: 'Issues detected',
      state: 'warning',
      items: [
        { state: 'error', key: 'fptn', value: '[FPTN] Not responding' },
        { state: 'success', key: 'Main', value: '[SoftPortal] 53ms' },
      ],
    });
    expect(
      partialWarningCardWithFailedItem.classList.contains(
        'tachyon_diagnostic_alert--expanded',
      ),
    ).toBe(false);

    const errorCard = renderCheckSection({
      code: 'NFT' as any,
      order: 3,
      title: 'Nftables checks',
      description: 'Some checks failed',
      state: 'error',
      items: [
        { state: 'success', key: 'Table exist', value: 'inet TachyonTable' },
        { state: 'error', key: 'Rules proxy exist', value: 'Missing' },
        { state: 'warning', key: 'Rules mangle counters', value: '0 pkts' },
      ],
    });

    expect(
      errorCard.classList.contains('tachyon_diagnostic_alert--expanded'),
    ).toBe(true);

    const summaryItems = errorCard.querySelectorAll(
      '.tachyon_diagnostic_alert__summary__item',
    );
    expect(summaryItems).toHaveLength(3);
    // Error item sorted first, warning second, success third
    expect(
      summaryItems[0].classList.contains(
        'tachyon_diagnostic_alert__summary__item--error',
      ),
    ).toBe(true);
    expect(
      summaryItems[1].classList.contains(
        'tachyon_diagnostic_alert__summary__item--warning',
      ),
    ).toBe(true);
    expect(
      summaryItems[2].classList.contains(
        'tachyon_diagnostic_alert__summary__item--success',
      ),
    ).toBe(true);
  });

  it('keeps healthy success cards collapsed by default and supports expandAll / collapseHealthy', () => {
    const checks = [
      {
        code: 'DNS' as any,
        order: 1,
        title: 'DNS checks',
        description: 'Checks passed',
        state: 'success' as const,
        items: [
          { state: 'success' as const, key: 'Main DNS', value: '1.1.1.1' },
        ],
      },
      {
        code: 'OUTBOUNDS' as any,
        order: 5,
        title: 'Sections checks',
        description: 'Checks failed',
        state: 'error' as const,
        items: [
          { state: 'error' as const, key: 'YouTube', value: 'Not responding' },
        ],
      },
    ];

    const dnsCard = renderCheckSection(checks[0]);
    const outCard = renderCheckSection(checks[1]);

    expect(
      dnsCard.classList.contains('tachyon_diagnostic_alert--expanded'),
    ).toBe(false);
    expect(
      outCard.classList.contains('tachyon_diagnostic_alert--expanded'),
    ).toBe(true);
    expect(areAllCheckCardsExpanded(checks)).toBe(false);

    expandAllCheckCards(checks.map((c) => c.code));
    expect(areAllCheckCardsExpanded(checks)).toBe(true);

    collapseHealthyCheckCards(checks);
    expect(areAllCheckCardsExpanded(checks)).toBe(false);
  });

  it('opens diagnostics modal and updates live when store changes', () => {
    store.set({
      diagnosticsRunAction: { loading: true },
      diagnosticsChecks: [
        {
          code: 'DNS' as any,
          order: 1,
          title: 'DNS checks',
          description: 'Checking, please wait',
          state: 'loading',
          items: [],
        },
      ],
    });

    const onRunChecks = vi.fn();
    const onRunDoctor = vi.fn();
    renderDiagnosticsModal({ onRunChecks, onRunDoctor });

    expect(mocks.showModal).toHaveBeenCalledTimes(1);
    const modalNodes = mocks.showModal.mock.calls[0][1];
    const modalRoot = Array.isArray(modalNodes) ? modalNodes[0] : modalNodes;

    expect(
      modalRoot.querySelector('.tachyon_diagnostic-summary-banner--loading'),
    ).not.toBeNull();

    // Transition to error state and update live
    store.set({
      diagnosticsRunAction: { loading: false },
      diagnosticsChecks: [
        {
          code: 'DNS' as any,
          order: 1,
          title: 'DNS checks',
          description: 'Checks failed',
          state: 'error',
          items: [
            { state: 'error', key: 'DNS on router', value: 'Not responding' },
          ],
        },
      ],
    });
    updateDiagnosticsModalIfOpen();

    expect(
      modalRoot.querySelector('.tachyon_diagnostic-summary-banner--error'),
    ).not.toBeNull();
    expect(
      modalRoot.querySelector('.tachyon_diagnostic_alert--expanded'),
    ).not.toBeNull();
  });
});
