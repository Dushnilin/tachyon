/* eslint-disable @typescript-eslint/no-explicit-any */
import { beforeEach, describe, expect, it, vi } from 'vitest';

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
  beforeEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

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

  it('polls the operation log while the job runs and stops after completion', async () => {
    vi.useFakeTimers();
    mockUi.showModal.mockReset();
    mockUi.hideModal.mockReset();

    const { TachyonShellMethods } = await import('../../../methods');
    const { showUpdateProgressModal } = await import(
      '../partials/renderUpdateProgressModal'
    );

    let nextOffset = 0;
    const logSpy = vi
      .spyOn(TachyonShellMethods, 'componentActionLog')
      .mockImplementation(async (_jobId: string, offset: number = 0) => {
        nextOffset = offset + 5;
        return {
          success: true,
          data: { success: true, log: 'chunk', offset: nextOffset },
        } as never;
      });

    const controller = showUpdateProgressModal({
      component: 'sing_box',
      action: 'install',
      componentTitle: 'sing-box',
    });

    // The first poll runs immediately, the following ones on the 1500ms timer.
    controller.startLogTracking('job-123');
    await vi.advanceTimersByTimeAsync(1500);
    await vi.advanceTimersByTimeAsync(1500);

    expect(logSpy).toHaveBeenCalledWith('job-123', 0);
    expect(logSpy).toHaveBeenCalledWith('job-123', 5);
    expect(logSpy).toHaveBeenCalledWith('job-123', 10);
    expect(controller.getLogText()).toBe('chunkchunkchunk');

    controller.completeSuccess('done');
    await vi.advanceTimersByTimeAsync(0);

    // A final read drains the remaining log, then polling stops.
    expect(logSpy).toHaveBeenCalledWith('job-123', 15);
    expect(controller.getLogText()).toBe('chunkchunkchunkchunk');

    const callsAfterCompletion = logSpy.mock.calls.length;
    await vi.advanceTimersByTimeAsync(5000);
    expect(logSpy.mock.calls.length).toBe(callsAfterCompletion);

    controller.close();
    vi.useRealTimers();
  });

  it('does not poll the log when no job id was provided', async () => {
    vi.useFakeTimers();
    mockUi.showModal.mockReset();
    mockUi.hideModal.mockReset();

    const { TachyonShellMethods } = await import('../../../methods');
    const { showUpdateProgressModal } = await import(
      '../partials/renderUpdateProgressModal'
    );

    const logSpy = vi
      .spyOn(TachyonShellMethods, 'componentActionLog')
      .mockResolvedValue({
        success: true,
        data: { success: true, log: 'x', offset: 1 },
      } as never);

    const controller = showUpdateProgressModal({
      component: 'sing_box',
      action: 'install',
      componentTitle: 'sing-box',
    });

    controller.startLogTracking('');
    await vi.advanceTimersByTimeAsync(1500);
    expect(logSpy).not.toHaveBeenCalled();
    expect(controller.getLogText()).toBe('');

    controller.close();
    vi.useRealTimers();
  });
});
