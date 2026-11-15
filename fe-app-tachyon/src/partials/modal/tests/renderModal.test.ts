/* eslint-disable @typescript-eslint/no-explicit-any */
import { describe, expect, it, vi } from 'vitest';

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
    return {
      tagName: tag.toUpperCase(),
      children: [] as any[],
      style: {} as Record<string, string>,
      textContent: '',
      innerHTML: '',
      setAttribute() {},
      getAttribute() {
        return null;
      },
      addEventListener() {},
      querySelectorAll: function () {
        return [];
      },
      querySelector: function () {
        return null;
      },
      replaceChildren: function (...nodes: any[]) {
        (this as any).children = nodes;
      },
      appendChild: function (node: any) {
        (this as any).children.push(node);
      },
      append: function (...nodes: any[]) {
        nodes.forEach((node) => (this as any).children.push(node));
      },
      unshift: function (...nodes: any[]) {
        (this as any).children.unshift(...nodes);
      },
      classList: {
        add() {},
        remove() {},
      },
    };
  }

  (globalThis as any).document = {
    body: createDummyElement('body') as any,
    createElement: (tag: string) => createDummyElement(tag) as any,
    createElementNS: (_ns: string, tag: string) =>
      createDummyElement(tag) as any,
    createTextNode: (text: string) => ({ textContent: text }),
    getElementById: () => null,
    querySelector: () => null,
    querySelectorAll: () => [],
  };

  (globalThis as any).E = (tag: string, attrs?: any, children?: any) => {
    const el = (globalThis as any).document.createElement(tag);
    if (attrs) {
      const { style, ...rest } = attrs;
      Object.assign(el, rest);
      if (style && typeof style === 'string') {
        style.split(';').forEach((rule: string) => {
          const [k, v] = rule.split(':').map((s: string) => s.trim());
          if (k && v) {
            el.style[k] = v;
          }
        });
      } else if (style && typeof style === 'object') {
        Object.assign(el.style, style);
      }
    }
    if (children) {
      if (Array.isArray(children)) {
        children.forEach((c) => {
          if (c) el.appendChild(c);
        });
      } else {
        el.appendChild(children);
      }
    }
    return el;
  };

  (globalThis as any)._ = (str: string) => str;

  const showModal = vi.fn();
  const hideModal = vi.fn();
  (globalThis as any).ui = {
    showModal,
    hideModal,
  };

  return {
    showModal,
    hideModal,
  };
});

import { renderModal } from '../renderModal';

describe('renderModal', () => {
  it('renders default footer buttons without extraButtons', () => {
    const modal = renderModal('some report', 'test_modal') as any;
    expect(modal).toBeDefined();

    const footer = modal.children[0].children[1];
    expect(footer.children.length).toBe(3); // Download, Copy, Close
  });

  it('renders extraButtons at the beginning of the footer', () => {
    const customButton = (globalThis as any).document.createElement('button');
    customButton.textContent = 'Fix';

    const modal = renderModal('some report', 'doctor_repair', {
      extraButtons: [customButton],
    }) as any;

    const footer = modal.children[0].children[1];
    expect(footer.children.length).toBe(4); // Extra (Fix), Download, Copy, Close
    expect(footer.children[0]).toBe(customButton);
  });
});
