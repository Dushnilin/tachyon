/// <reference types="vite/client" />
/* eslint-disable @typescript-eslint/no-explicit-any */
import { describe, expect, it } from 'vitest';
import { attachCommunityListPicker } from '../communityListPicker';
import settingsSource from '../../views/settings.ts?raw';

describe('Issue #494: Smart Detect russia_inside recommendation and explanation', () => {
  it('adds (Рекомендуется) / (Recommended) badge for russia_inside and explains russia_inside vs russia_outside in RU & EN', () => {
    const startIdx = settingsSource.indexOf("'smart_detect_exclude_lists'");
    expect(startIdx).toBeGreaterThan(-1);
    const block = settingsSource.slice(startIdx, startIdx + 1600);

    // Recommendation label for russia_inside
    expect(block).toContain("name === 'russia_inside'");
    expect(block).toContain('Рекомендуется');
    expect(block).toContain('Recommended');

    // Clear Russian explanation contrasting Russia (inside) vs Russia (outside)
    expect(block).toContain('Россия (внутри)');
    expect(block).toContain('Россия (снаружи)');
    expect(block).toContain('временных сбоях');
    expect(block).toContain('региональными ограничениями');

    // Clear English explanation contrasting Russia (inside) vs Russia (outside)
    expect(block).toContain('Russia (inside)');
    expect(block).toContain('Russia (outside)');
    expect(block).toContain('temporary outages');
    expect(block).toContain('regional restrictions');
  });

  it('renders a recommended badge on communityListPicker chips when recommendedKeys is passed', async () => {
    class MockHTMLElement {}
    (globalThis as any).HTMLElement = MockHTMLElement;

    const createMockEl = (tag: string): any => {
      const attrs: Record<string, string> = {};
      const el: any = Object.assign(new MockHTMLElement(), {
        tagName: tag.toUpperCase(),
        children: [] as any[],
        parentNode: null as any,
        style: {},
        className: '',
        textContent: '',
        dataset: {},
        classList: {
          add: () => {},
          remove: () => {},
          toggle: () => {},
          contains: () => false,
        },
        setAttribute(k: string, v: string) {
          attrs[k] = String(v);
          if (k === 'class') el.className = String(v);
        },
        getAttribute: (k: string) => attrs[k] ?? null,
        appendChild(c: any) {
          if (c && typeof c === 'object') {
            c.parentNode = el;
            el.children.push(c);
          }
          return c;
        },
        replaceChildren(...nodes: any[]) {
          el.children = nodes.filter(Boolean);
        },
        addEventListener: () => {},
        querySelectorAll(sel: string) {
          const out: any[] = [];
          const walk = (n: any) => {
            for (const ch of n.children || []) {
              if (
                sel === '[data-recommended="true"]' &&
                ch.getAttribute?.('data-recommended') === 'true'
              ) {
                out.push(ch);
              } else if (
                sel === '.tachyon-ruleset-picker__chip[data-key]' &&
                ch.getAttribute?.('data-key')
              ) {
                out.push(ch);
              }
              walk(ch);
            }
          };
          walk(el);
          return out;
        },
        querySelector(sel: string) {
          return el.querySelectorAll(sel)[0] || null;
        },
        insertBefore(n: any) {
          el.children.push(n);
          return n;
        },
      });
      return el;
    };

    (globalThis as any).document = {
      documentElement: { lang: 'ru' },
      body: createMockEl('body'),
      createElementNS: (_ns: string, tag: string) => createMockEl(tag),
    };
    (globalThis as any).E = (tag: string, attrs?: any, children?: any) => {
      const el = createMockEl(tag);
      if (attrs) {
        for (const [k, v] of Object.entries(attrs)) {
          if (v !== undefined && v !== null && typeof v !== 'function') {
            el.setAttribute(k, String(v));
          }
        }
      }
      const add = (c: any) => {
        if (c == null || c === '') return;
        if (Array.isArray(c)) c.forEach(add);
        else if (typeof c === 'object') el.appendChild(c);
        else el.textContent += String(c);
      };
      add(children);
      return el;
    };

    const parent = createMockEl('div');
    const widget = createMockEl('div');
    parent.appendChild(widget);

    const opt: any = {
      renderWidget: () => widget,
      getUIElement: () => ({ getValue: () => [], setValue: () => {} }),
    };

    attachCommunityListPicker(opt, { recommendedKeys: ['russia_inside'] });
    opt.renderWidget('settings', 0, []);

    await new Promise((r) => setTimeout(r, 15));

    const chips = parent.querySelectorAll(
      '.tachyon-ruleset-picker__chip[data-key]',
    );
    const ruChip = chips.find(
      (c: any) => c.getAttribute('data-key') === 'russia_inside',
    );
    const ytChip = chips.find(
      (c: any) => c.getAttribute('data-key') === 'youtube',
    );
    expect(ruChip).toBeTruthy();
    expect(ytChip).toBeTruthy();
    const ruBadge = ruChip.querySelector('[data-recommended="true"]');
    const ytBadge = ytChip.querySelector('[data-recommended="true"]');
    expect(ruBadge).toBeTruthy();
    expect(ruBadge.textContent).toBe('(Рекомендуется)');
    expect(ytBadge).toBeNull();
  });
});
