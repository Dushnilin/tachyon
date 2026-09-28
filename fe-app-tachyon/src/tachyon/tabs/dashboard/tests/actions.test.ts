import { describe, it, expect, beforeEach, vi } from 'vitest';
import {
  getExpandedSections,
  saveExpandedSections,
  toggleSectionExpansion,
  DASHBOARD_EXPANDED_SECTIONS_KEY,
} from '../actions';

describe('dashboard actions', () => {
  let mockStorage: Record<string, string>;

  beforeEach(() => {
    mockStorage = {};
    (globalThis as unknown as { localStorage: unknown }).localStorage = {
      getItem: vi.fn((key: string) => mockStorage[key] ?? null),
      setItem: vi.fn((key: string, value: string) => {
        mockStorage[key] = value;
      }),
      removeItem: vi.fn((key: string) => {
        delete mockStorage[key];
      }),
      clear: vi.fn(() => {
        mockStorage = {};
      }),
    };
  });

  it('reads expanded sections from localStorage', () => {
    mockStorage[DASHBOARD_EXPANDED_SECTIONS_KEY] = JSON.stringify([
      'section_vpn',
      'active_clients',
    ]);

    const sections = getExpandedSections();

    expect(sections.has('section_vpn')).toBe(true);
    expect(sections.has('active_clients')).toBe(true);
    expect(sections.has('other')).toBe(false);
  });

  it('handles invalid or empty localStorage safely', () => {
    mockStorage[DASHBOARD_EXPANDED_SECTIONS_KEY] = 'invalid-json{';

    const sections = getExpandedSections();

    expect(sections.size).toBe(0);
  });

  it('toggles section expansion and saves to localStorage', () => {
    const initial = new Set<string>(['section_a']);

    const res1 = toggleSectionExpansion(initial, 'section_b');
    expect(res1.expanded).toBe(true);
    expect(res1.nextSections.has('section_b')).toBe(true);
    expect(mockStorage[DASHBOARD_EXPANDED_SECTIONS_KEY]).toBe(
      JSON.stringify(['section_a', 'section_b']),
    );

    const res2 = toggleSectionExpansion(res1.nextSections, 'section_a');
    expect(res2.expanded).toBe(false);
    expect(res2.nextSections.has('section_a')).toBe(false);
    expect(res2.nextSections.has('section_b')).toBe(true);
  });

  it('saves expanded sections directly to localStorage', () => {
    saveExpandedSections(new Set<string>(['alpha', 'beta']));
    expect(mockStorage[DASHBOARD_EXPANDED_SECTIONS_KEY]).toBe(
      JSON.stringify(['alpha', 'beta']),
    );
  });
});
