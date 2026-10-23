/* eslint-disable @typescript-eslint/no-explicit-any */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import {
  preserveScrollForPage,
  isUserActivelyScrolling,
  ensureUserScrollTracking,
  _resetUserScrollTrackingForTest,
} from '../preserveScrollForPage';

describe('preserveScrollForPage', () => {
  let originalWindow: any;
  let originalDocument: any;

  beforeEach(() => {
    vi.useFakeTimers();
    originalWindow = (globalThis as any).window;
    originalDocument = (globalThis as any).document;

    const listeners: Record<string, ((e: any) => void)[]> = {};
    (globalThis as any).window = {
      scrollY: 0,
      pageYOffset: 0,
      scrollTo: vi.fn(),
      addEventListener: vi.fn((event: string, cb: any) => {
        listeners[event] = listeners[event] || [];
        listeners[event].push(cb);
      }),
      dispatchEvent: (e: { type: string }) => {
        (listeners[e.type] || []).forEach((cb) => cb(e));
      },
    };

    (globalThis as any).document = {
      documentElement: {
        scrollHeight: 1000,
        scrollTop: 0,
        style: {},
      },
    };

    _resetUserScrollTrackingForTest();
    ensureUserScrollTracking();
  });

  afterEach(() => {
    vi.useRealTimers();
    (globalThis as any).window = originalWindow;
    (globalThis as any).document = originalDocument;
    vi.restoreAllMocks();
  });

  it('executes renderFn immediately', () => {
    const renderFn = vi.fn();
    preserveScrollForPage(renderFn);
    expect(renderFn).toHaveBeenCalledTimes(1);
  });

  it('preserves targetContainer minHeight during render and clears it after animation frame', () => {
    const container: any = {
      offsetHeight: 350,
      style: {},
    };

    let heightDuringRender = '';
    preserveScrollForPage(() => {
      heightDuringRender = container.style.minHeight;
    }, container);

    expect(heightDuringRender).toBe('350px');

    vi.advanceTimersByTime(20);
    expect(container.style.minHeight).toBe('');
  });

  it('handles multiple overlapping calls with ref-counted locks', () => {
    const container: any = {
      offsetHeight: 300,
      style: {},
    };

    // First call locks height at t=0
    preserveScrollForPage(() => {}, container);
    expect(container.style.minHeight).toBe('300px');
    expect((globalThis as any).document.documentElement.style.minHeight).toBe(
      '1000px',
    );

    // Advance 8ms, then call 2 arrives before call 1 finishes
    vi.advanceTimersByTime(8);
    preserveScrollForPage(() => {}, container);

    // Advance 8ms (total 16ms, call 1 frame fires, but call 2 is still active until 24ms)
    vi.advanceTimersByTime(8);
    expect(container.style.minHeight).toBe('300px');
    expect((globalThis as any).document.documentElement.style.minHeight).toBe(
      '1000px',
    );

    // Advance another 8ms (total 24ms, call 2 frame fires)
    vi.advanceTimersByTime(8);
    expect(container.style.minHeight).toBe('');
    expect((globalThis as any).document.documentElement.style.minHeight).toBe(
      '',
    );
  });

  it('does not scroll if user is actively scrolling', () => {
    const scrollToMock = (globalThis as any).window.scrollTo;

    // Simulate user scroll event
    (globalThis as any).window.dispatchEvent({ type: 'wheel' });
    expect(isUserActivelyScrolling()).toBe(true);

    preserveScrollForPage(() => {});

    vi.advanceTimersByTime(20);
    expect(scrollToMock).not.toHaveBeenCalled();
  });

  it('restores scroll position if layout shifted and user was idle', () => {
    const scrollToMock = (globalThis as any).window.scrollTo;
    (globalThis as any).window.scrollY = 400;

    preserveScrollForPage(() => {
      // Simulate layout shift clamping scrollY
      (globalThis as any).window.scrollY = 100;
    });

    // Advance past user scroll threshold and animation frame
    vi.advanceTimersByTime(1000);

    expect(scrollToMock).toHaveBeenCalledWith({ top: 400 });
  });
});
