import { beforeEach, describe, expect, it } from 'vitest';
import {
  reasonLabel,
  renderSwitchEvent,
  type SwitchEvent,
} from '../switchHistory';

type MockChild = MockNode | HTMLElement | string | number | null | undefined;
interface MockNode {
  tagName?: string;
  attrs?: Record<string, unknown>;
  textContent?: string | null;
  children?: ArrayLike<MockChild>;
  append?: (...more: MockChild[]) => void;
}

function collectText(node: MockChild): string {
  if (node == null) return '';
  if (typeof node === 'string' || typeof node === 'number') {
    return String(node);
  }
  const parts: string[] = [];
  if (typeof node.textContent === 'string') parts.push(node.textContent);
  const children = node.children
    ? Array.from(node.children as ArrayLike<MockChild>)
    : [];
  for (const child of children) {
    parts.push(collectText(child));
  }
  return parts.join(' ');
}

describe('switchHistory (#485 reasons & human-readable names)', () => {
  beforeEach(() => {
    const g = globalThis as Record<string, unknown>;
    g.document = { documentElement: { lang: 'ru' } };
    g.E = (
      tag: string,
      attrs?: Record<string, unknown>,
      children?: MockChild | MockChild[],
    ) => {
      const childList = Array.isArray(children)
        ? children
        : children != null
          ? [children]
          : [];
      return {
        tagName: tag.toUpperCase(),
        attrs: attrs || {},
        children: childList,
        append(...more: MockChild[]) {
          this.children.push(...more);
        },
        textContent: childList
          .filter((c) => typeof c === 'string' || typeof c === 'number')
          .join(''),
      };
    };
  });

  it('translates #485 core decision reasons including active_unhealthy alias', () => {
    expect(reasonLabel('active_ineligible')).toBe('Активный узел недоступен');
    expect(reasonLabel('active_unhealthy')).toBe('Активный узел недоступен');
    expect(reasonLabel('higher_priority_eligible')).toBe(
      'Возврат на более приоритетный узел',
    );
    expect(reasonLabel('manual_restore')).toBe(
      'Ручной возврат на основной узел',
    );
  });

  it('renders human-readable group and node labels plus core decided_at while keeping raw tags in title', () => {
    const ev: SwitchEvent = {
      timestamp: 1_795_500_050,
      decided_at: 1_795_500_000,
      group: 'bal-Main-bal_Main_auto',
      group_display_name: 'Main Auto',
      from: 'awgconf-src_rtest-1',
      to: 'rtest',
      reason: 'active_ineligible',
      source: 'core_failover',
      observed: true,
      priority: true,
      from_delay_ms: 132,
      to_delay_ms: 48,
    };

    const el = renderSwitchEvent(ev);
    const fullText = collectText(el);
    expect(fullText).toContain('Main Auto');
    expect(fullText).toContain('rtest #2');
    expect(fullText).toContain('rtest');
    expect(fullText).toContain('Активный узел недоступен');
    expect(fullText).toContain('Время решения ядра');
    expect(fullText).not.toContain('bal-Main-bal_Main_auto');
    expect(fullText).not.toContain('awgconf-src_rtest-1');
  });
});
