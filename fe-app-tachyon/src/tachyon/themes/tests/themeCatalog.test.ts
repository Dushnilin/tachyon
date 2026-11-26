/* eslint-disable @typescript-eslint/no-explicit-any */
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import {
  BUILTIN_THEMES,
  BG_ANIMATION_STORAGE_KEY,
  CUSTOM_THEMES_STORAGE_KEY,
  THEME_ID_STORAGE_KEY,
  applyThemeToDocument,
  computeThemeCssVars,
  deleteCustomTheme,
  exportThemeJson,
  getActiveTheme,
  getAllThemes,
  isBgAnimationEnabled,
  parseThemeImportText,
  saveCustomTheme,
  setActiveTheme,
  setBgAnimationEnabled,
} from '../themeCatalog';

describe('themeCatalog', () => {
  const storage = new Map<string, string>();
  const styleProps = new Map<string, string>();
  const attrs: Record<string, string> = {};

  beforeEach(() => {
    storage.clear();
    styleProps.clear();
    for (const k of Object.keys(attrs)) delete attrs[k];

    (globalThis as any).localStorage = {
      getItem: (k: string) => storage.get(k) ?? null,
      setItem: (k: string, v: string) => storage.set(k, String(v)),
      removeItem: (k: string) => storage.delete(k),
    };
    (globalThis as any).document = {
      documentElement: {
        style: {
          setProperty: (k: string, v: string) => styleProps.set(k, v),
        },
        setAttribute: (k: string, v: string) => {
          attrs[k] = String(v);
        },
      },
    };
  });

  afterEach(() => {
    delete (globalThis as any).localStorage;
    delete (globalThis as any).document;
  });

  it('defines the exact 13 built-in themes with complete normalized hex palettes and no banned third-party strings', () => {
    expect(BUILTIN_THEMES.map((t) => t.name)).toEqual([
      'Default Dark',
      'Default Light',
      'Legacy Dark',
      'Catppuccin',
      'Dracula',
      'Everforest',
      'Gruvbox Material',
      'Monokai',
      'Nord',
      'One Dark Pro',
      'Tokyo Night',
      'Solarized Dark',
      'Vesper',
    ]);

    const banned = /antigravity|vscode|vs code|github|openvsx|argon/i;
    for (const t of BUILTIN_THEMES) {
      expect(t.id).not.toMatch(banned);
      expect(t.name).not.toMatch(banned);
      for (const hex of Object.values(t.colors)) {
        expect(hex).toMatch(/^#[0-9a-f]{6}$/);
      }
      const vars = computeThemeCssVars(t);
      expect(vars['--bg']).toBe(t.colors.bg);
      expect(vars['--surface-glass']).toMatch(/^rgba\(\d+, \d+, \d+, 0\.84\)$/);
      expect(vars['--topbar-glass']).toMatch(/^rgba\(\d+, \d+, \d+, 0\.96\)$/);
      expect(vars['--accent-soft']).toMatch(/^rgba\(\d+, \d+, \d+, 0\.16\)$/);
      expect(vars['--accent-ring']).toMatch(/^rgba\(\d+, \d+, \d+, 0\.34\)$/);
    }
  });

  it('switches themes and persists custom themes in unified localStorage keys', () => {
    expect(getActiveTheme().id).toBe('default-dark');
    setActiveTheme('tokyo-night');
    expect(storage.get(THEME_ID_STORAGE_KEY)).toBe('tokyo-night');
    expect(styleProps.get('--bg')).toBe('#1a1b26');
    expect(attrs['data-tachyon-theme']).toBe('tokyo-night');

    const saved = saveCustomTheme({
      name: 'Midnight Amber',
      scheme: 'dark',
      colors: {
        bg: '#121317',
        surface: '#1a1c22',
        accent: '#f59e0b',
      },
    });
    expect(storage.get(CUSTOM_THEMES_STORAGE_KEY)).toContain('Midnight Amber');
    expect(getAllThemes().some((t) => t.id === saved.id)).toBe(true);

    setActiveTheme(saved.id);
    expect(styleProps.get('--accent')).toBe('#f59e0b');
    expect(styleProps.get('--accent-soft')).toBe('rgba(245, 158, 11, 0.16)');

    deleteCustomTheme(saved.id);
    expect(getActiveTheme().id).toBe('default-dark');
  });

  it('parses JSON and JSONC color definitions with comments, URLs, and trailing commas', () => {
    const jsonc = `
    {
      // Comment mentioning https://example.com/theme must keep string intact
      "name": "Clean Slate",
      /* block comment */
      "type": "light",
      "colors": {
        "editor.background": "#f8fafc",
        "sideBar.background": "#ffffff",
        "list.hoverBackground": "#f1f5f9",
        "button.background": "#2563eb",
        "editor.foreground": "#0f172a",
      },
    }`;
    const parsed = parseThemeImportText(jsonc);
    expect(parsed.name).toBe('Clean Slate');
    expect(parsed.scheme).toBe('light');
    expect(parsed.colors.bg).toBe('#f8fafc');
    expect(parsed.colors.accent).toBe('#2563eb');

    const applied = applyThemeToDocument({
      id: 'preview',
      name: parsed.name,
      scheme: parsed.scheme,
      colors: parsed.colors,
    });
    expect(attrs['data-tachyon-theme-scheme']).toBe('light');
    expect(attrs['data-darkmode']).toBe('false');
    expect(exportThemeJson(applied)).toContain('"scheme": "light"');
  });

  it('toggles background animation state and persists to localStorage and document attributes', () => {
    expect(isBgAnimationEnabled()).toBe(true);

    setBgAnimationEnabled(false);
    expect(storage.get(BG_ANIMATION_STORAGE_KEY)).toBe('false');
    expect(attrs['data-tachyon-bg-animation']).toBe('false');
    expect(isBgAnimationEnabled()).toBe(false);

    applyThemeToDocument(getActiveTheme());
    expect(attrs['data-tachyon-bg-animation']).toBe('false');

    setBgAnimationEnabled(true);
    expect(storage.get(BG_ANIMATION_STORAGE_KEY)).toBe('true');
    expect(attrs['data-tachyon-bg-animation']).toBe('true');
    expect(isBgAnimationEnabled()).toBe(true);
  });

  it('applies Default Light compatibility variables and cleans them up when switching back to dark', () => {
    const removedProps: string[] = [];
    (globalThis as any).document.documentElement.style.removeProperty = (
      k: string,
    ) => {
      removedProps.push(k);
      styleProps.delete(k);
    };

    storage.set('tachyon_color_scheme_v1', 'light');
    expect(getActiveTheme().id).toBe('default-light');

    setActiveTheme('default-light');
    expect(attrs['data-tachyon-theme-scheme']).toBe('light');
    expect(attrs['data-darkmode']).toBe('false');
    expect(styleProps.get('--surface')).toBe('#ffffff');
    expect(styleProps.get('--background-color-high')).toBe('#ffffff');
    expect(styleProps.get('--text-color-high')).toBe('#0f172a');

    setActiveTheme('default-dark');
    expect(attrs['data-tachyon-theme-scheme']).toBe('dark');
    expect(attrs['data-darkmode']).toBe('true');
    expect(removedProps).toContain('--background-color-high');
    expect(styleProps.has('--background-color-high')).toBe(false);
  });
});
