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
    execCommand: vi.fn().mockReturnValue(true),
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

import { renderSupportModal } from '../partials/renderSupportModal';
import { renderWikiDisclaimer } from '../partials/renderWikiDisclaimer';

describe('renderSupportModal & renderWikiDisclaimer', () => {
  beforeEach(() => {
    mocks.showModal.mockReset();
    mocks.hideModal.mockReset();
  });

  it('renders Support Development button inside renderWikiDisclaimer', () => {
    const disclaimer = renderWikiDisclaimer('default') as any;
    expect(disclaimer).toBeDefined();

    // disclaimer has content, Open Project Page btn, Telegram Channel btn, Support Development btn
    const buttons = disclaimer.children.filter(
      (c: any) =>
        c.tagName === 'BUTTON' ||
        (c.classList && c.classList.toString().includes('btn')),
    );
    expect(buttons.length).toBe(3);
  });

  it('opens support modal with title and content when renderSupportModal is called', () => {
    renderSupportModal();
    expect(mocks.showModal).toHaveBeenCalledTimes(1);

    const title = mocks.showModal.mock.calls[0][0];
    expect(title).toContain('Support Development');

    const modalContent = mocks.showModal.mock.calls[0][1];
    expect(modalContent).toBeDefined();
  });
});
