/* eslint-disable @typescript-eslint/no-explicit-any */
import { describe, expect, it, vi } from 'vitest';

class MockMutationObserver {
  observe() {}
  disconnect() {}
  takeRecords() {
    return [];
  }
}
globalThis.MutationObserver = MockMutationObserver as any;

function createDummyElement(tag: string) {
  return {
    tagName: tag.toUpperCase(),
    children: [] as any[],
    style: {} as Record<string, string>,
    setAttribute() {},
    getAttribute() {
      return null;
    },
    querySelectorAll: () => [],
    querySelector: () => null,
    replaceChildren: function (...nodes: any[]) {
      (this as any).children = nodes;
    },
    appendChild: function (node: any) {
      (this as any).children.push(node);
    },
    classList: {
      add() {},
      remove() {},
    },
  };
}

globalThis.document = {
  body: {} as any,
  createElement: (tag: string) => createDummyElement(tag) as any,
  createElementNS: (_ns: string, tag: string) => createDummyElement(tag) as any,
  getElementById: () => null,
  querySelector: () => null,
  querySelectorAll: () => [],
} as any;

(globalThis as any).rpc = { declare: vi.fn() };
(globalThis as any).uci = { sections: vi.fn().mockResolvedValue([]) };
(globalThis as any).localStorage = { getItem: vi.fn(), setItem: vi.fn() };

(globalThis as any).E = (tag: string, attrs?: any, children?: any) => {
  const el = (globalThis as any).document.createElement(tag);
  if (attrs) {
    const { style, ...rest } = attrs;
    Object.assign(el, rest);
    if (typeof style === 'string') {
      el.style.cssText = style;
    } else if (style && typeof style === 'object') {
      Object.assign(el.style, style);
    }
  }
  if (children) {
    el.children = Array.isArray(children) ? children : [children];
  }
  return el;
};

const mockUi = {
  showModal: vi.fn(),
  hideModal: vi.fn(),
};
(globalThis as any).ui = mockUi;
(globalThis as any)._ = (str: string) => str;

describe('renderUpdateProgressModal', () => {
  it('renders install button and does not auto-close when onInstall is provided', async () => {
    vi.useFakeTimers();
    mockUi.showModal.mockReset();
    mockUi.hideModal.mockReset();

    const { showUpdateProgressModal } = await import(
      '../partials/renderUpdateProgressModal'
    );

    const onInstall = vi.fn();
    const controller = showUpdateProgressModal({
      component: 'sing_box',
      action: 'check_update',
      componentTitle: 'sing-box',
    });

    controller.completeSuccess('Update is available', {
      autoCloseMs: 0,
      installText: 'Update',
      onInstall,
    });

    // Verify modal element passed to showModal contains Install/Update button
    const modalContent = mockUi.showModal.mock.calls[0]?.[1] as any;
    expect(modalContent).toBeDefined();

    // Advance time to verify auto-close did NOT fire
    vi.advanceTimersByTime(5000);
    expect(mockUi.hideModal).not.toHaveBeenCalled();

    vi.useRealTimers();
  });

  it('auto-closes after completed installation without hanging', async () => {
    vi.useFakeTimers();
    mockUi.showModal.mockReset();
    mockUi.hideModal.mockReset();

    const { showUpdateProgressModal } = await import(
      '../partials/renderUpdateProgressModal'
    );

    const controller = showUpdateProgressModal({
      component: 'sing_box',
      action: 'install',
      componentTitle: 'sing-box',
    });

    controller.completeSuccess('Update completed successfully!');

    // Advance timer past autoCloseMs (1200ms)
    vi.advanceTimersByTime(1500);
    expect(mockUi.hideModal).toHaveBeenCalled();

    vi.useRealTimers();
  });
});
