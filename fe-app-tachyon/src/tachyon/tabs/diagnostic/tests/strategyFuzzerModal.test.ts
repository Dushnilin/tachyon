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
      setAttribute() {},
      getAttribute() {
        return null;
      },
      addEventListener() {},
      querySelectorAll: () => [],
      querySelector: () => null,
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
    body: {} as any,
    createElement: (tag: string) => createDummyElement(tag) as any,
    createElementNS: (_ns: string, tag: string) =>
      createDummyElement(tag) as any,
    getElementById: () => null,
    querySelector: () => null,
    querySelectorAll: () => [],
  };

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
      if (Array.isArray(children)) {
        children.forEach((c) =>
          el.appendChild(typeof c === 'string' ? { textContent: c } : c),
        );
      } else {
        el.appendChild(
          typeof children === 'string' ? { textContent: children } : children,
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

  const showModal = vi.fn();
  const hideModal = vi.fn();
  const executeShellCommand = vi.fn();

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

describe('renderStrategyFuzzerModal', () => {
  beforeEach(() => {
    mocks.showModal.mockReset();
    mocks.executeShellCommand.mockReset();
    mocks.executeShellCommand.mockResolvedValue({
      stdout: JSON.stringify({
        running: false,
        results: [],
      }),
      stderr: '',
      code: 0,
    });
  });

  it('renders and displays the Strategy Fuzzer modal', () => {
    renderStrategyFuzzerModal(['youtube_rule', 'discord_rule']);

    expect(mocks.showModal).toHaveBeenCalledTimes(1);
    expect(mocks.showModal).toHaveBeenCalledWith(
      '⚡ Strategy Fuzzer & Auto-Tuner',
      expect.anything(),
    );
  });
});
