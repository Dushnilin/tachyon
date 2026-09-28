/* eslint-disable @typescript-eslint/no-explicit-any */
import { describe, it, expect, vi } from 'vitest';
import {
  isElementOverflowing,
  compactMonitoringText,
  getElementCopyText,
  isCompactTextSubsequence,
  getMonitoringValueOverflowElements,
  getMonitoringValueTextElements,
  shouldCopyFullMonitoringValue,
  getSelectionValueElements,
  handleMonitoringValueCopy,
} from '../clipboard';

if (typeof HTMLElement === 'undefined') {
  class MockHTMLElement {
    scrollWidth = 0;
    clientWidth = 0;
    children: any[] = [];
    querySelectorAll() {
      return [];
    }
    getAttribute() {
      return null;
    }
    getAttributeNames() {
      return [];
    }
  }
  (globalThis as any).HTMLElement = MockHTMLElement;
}

if (typeof window === 'undefined') {
  (globalThis as any).window = globalThis;
}

describe('monitoring clipboard utilities', () => {
  it('detects overflowing elements', () => {
    const normalEl = { scrollWidth: 100, clientWidth: 100 } as HTMLElement;
    const overflowEl = { scrollWidth: 150, clientWidth: 100 } as HTMLElement;
    const borderEl = { scrollWidth: 101, clientWidth: 100 } as HTMLElement;

    expect(isElementOverflowing(normalEl)).toBe(false);
    expect(isElementOverflowing(borderEl)).toBe(false);
    expect(isElementOverflowing(overflowEl)).toBe(true);
  });

  it('compacts text removing ellipses and whitespace', () => {
    expect(compactMonitoringText(' hello … world ')).toBe('helloworld');
    expect(compactMonitoringText('\u2026foo   bar\u2026')).toBe('foobar');
    expect(compactMonitoringText('')).toBe('');
  });

  it('gets element copy text from attribute, textContent, or fallback', () => {
    const elWithAttr = {
      getAttribute: (name: string) =>
        name === 'data-copy-value' ? 'custom-copy' : null,
      textContent: 'visible text',
    } as any;
    expect(getElementCopyText(elWithAttr, 'fallback')).toBe('custom-copy');

    const elWithText = {
      getAttribute: () => null,
      textContent: 'visible text',
    } as any;
    expect(getElementCopyText(elWithText, 'fallback')).toBe('visible text');

    const elEmpty = {
      getAttribute: () => null,
      textContent: '',
    } as any;
    expect(getElementCopyText(elEmpty, 'fallback')).toBe('fallback');
  });

  it('checks if text is a compact subsequence', () => {
    expect(isCompactTextSubsequence('abc', 'axbycz')).toBe(true);
    expect(isCompactTextSubsequence('abc', 'acb')).toBe(false);
    expect(isCompactTextSubsequence('hello', 'hello world')).toBe(true);
    expect(isCompactTextSubsequence('world', 'hello')).toBe(false);
  });

  it('finds overflow elements in subtree', () => {
    const child = {
      scrollWidth: 120,
      clientWidth: 80,
      querySelectorAll: () => [],
    } as any;
    const parent = {
      scrollWidth: 100,
      clientWidth: 100,
      querySelectorAll: () => [child],
    } as any;

    const overflows = getMonitoringValueOverflowElements(parent);
    expect(overflows).toEqual([child]);
  });

  it('collects text elements from leaf and composite nodes', () => {
    const leaf = Object.assign(new (globalThis as any).HTMLElement(), {
      children: [],
      getAttribute: () => null,
      textContent: 'item',
    });

    const parent = Object.assign(new (globalThis as any).HTMLElement(), {
      children: [leaf],
      getAttribute: () => null,
      textContent: 'item',
    });

    const elements = getMonitoringValueTextElements(parent as any);
    expect(elements.length).toBe(1);
    expect(elements[0]).toBe(leaf);
  });

  it('evaluates shouldCopyFullMonitoringValue accurately', () => {
    const el = Object.assign(new (globalThis as any).HTMLElement(), {
      scrollWidth: 200,
      clientWidth: 60,
      children: [],
      querySelectorAll: () => [],
      getAttribute: () => 'very-long-domain-name.example.com',
      textContent: 'very-long-dom…',
    });

    // Empty texts
    expect(shouldCopyFullMonitoringValue(el, '', 'full')).toBe(false);
    expect(shouldCopyFullMonitoringValue(el, 'sel', '')).toBe(false);

    // Exact match
    expect(shouldCopyFullMonitoringValue(el, 'exact', 'exact')).toBe(true);

    // Non-overflowing element with partial text
    const noOverflowEl = Object.assign(new (globalThis as any).HTMLElement(), {
      scrollWidth: 100,
      clientWidth: 100,
      children: [],
      querySelectorAll: () => [],
      getAttribute: () => 'full text',
      textContent: 'full text',
    });
    expect(
      shouldCopyFullMonitoringValue(noOverflowEl, 'full', 'full text'),
    ).toBe(false);

    // Overflowing element with prefix selection
    expect(
      shouldCopyFullMonitoringValue(
        el,
        'very-long-dom…',
        'very-long-domain-name.example.com',
      ),
    ).toBe(true);
  });

  it('filters intersecting elements for selection', () => {
    const el1 = { getAttribute: () => 'v1' } as any;
    const el2 = { getAttribute: () => 'v2' } as any;
    const root = {
      querySelectorAll: () => [el1, el2],
    } as any;

    const range = {
      intersectsNode: (node: any) => node === el1,
    };
    const selection = {
      rangeCount: 1,
      getRangeAt: () => range,
    } as any;

    const results = getSelectionValueElements(selection, root);
    expect(results).toEqual([el1]);
  });

  it('handles copy events and sets full clipboard text when appropriate', () => {
    const el = Object.assign(new (globalThis as any).HTMLElement(), {
      scrollWidth: 200,
      clientWidth: 60,
      children: [],
      querySelectorAll: () => [],
      getAttribute: (k: string) =>
        k === 'data-copy-value' ? 'full-secret-token-value-123456789' : null,
      textContent: 'full-secret-tok…',
    });

    const root = {
      querySelectorAll: () => [el],
    } as any;

    const range = {
      intersectsNode: () => true,
    };

    const setData = vi.fn();
    const preventDefault = vi.fn();
    const event = {
      clipboardData: { setData },
      preventDefault,
    } as any;

    (globalThis as any).window.getSelection = vi.fn().mockReturnValue({
      isCollapsed: false,
      rangeCount: 1,
      getRangeAt: () => range,
      toString: () => 'full-secret-tok…',
    }) as any;

    handleMonitoringValueCopy(event, root);
    expect(setData).toHaveBeenCalledWith(
      'text/plain',
      'full-secret-token-value-123456789',
    );
    expect(preventDefault).toHaveBeenCalled();
  });
});
