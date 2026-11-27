/* eslint-disable @typescript-eslint/no-explicit-any */
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import {
  BUILTIN_THEMES,
  BG_ANIMATION_STORAGE_KEY,
  CUSTOM_THEMES_STORAGE_KEY,
  FONT_MONO_PRESETS,
  FONT_MONO_STORAGE_KEY,
  FONT_SANS_PRESETS,
  FONT_SANS_STORAGE_KEY,
  FONT_SIZE_PRESETS,
  FONT_SIZE_STORAGE_KEY,
  THEME_DARK_ID_STORAGE_KEY,
  THEME_ID_STORAGE_KEY,
  THEME_LIGHT_ID_STORAGE_KEY,
  THEME_MODE_STORAGE_KEY,
  THEME_SCHEDULE_END_STORAGE_KEY,
  THEME_SCHEDULE_START_STORAGE_KEY,
  applyThemeToDocument,
  applyTypographyToDocument,
  computeThemeCssVars,
  computeTypographyCssVars,
  deleteCustomTheme,
  exportThemeJson,
  getActiveTheme,
  getAllThemes,
  getThemeAutoConfig,
  getTypographyConfig,
  isBgAnimationEnabled,
  isScheduleNightNow,
  parseThemeImportText,
  resolveEffectiveThemeId,
  saveCustomTheme,
  setActiveTheme,
  setBgAnimationEnabled,
  setThemeAutoConfig,
  setTypographyConfig,
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

  it('defines the exact 18 built-in themes with complete normalized hex palettes and no banned third-party strings', () => {
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
      'Material Dark',
      'Everforest Light',
      'Material Light',
      'Apple Light',
      'Gruvbox Light',
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
      expect(vars['--surface-glass']).toMatch(
        t.scheme === 'light'
          ? /^rgba\(\d+, \d+, \d+, 0\.92\)$/
          : /^rgba\(\d+, \d+, \d+, 0\.86\)$/,
      );
      expect(vars['--topbar-glass']).toMatch(
        t.scheme === 'light'
          ? /^rgba\(\d+, \d+, \d+, 0\.96\)$/
          : /^rgba\(\d+, \d+, \d+, 0\.94\)$/,
      );
      expect(vars['--accent-soft']).toMatch(
        t.scheme === 'light'
          ? /^rgba\(\d+, \d+, \d+, 0\.12\)$/
          : /^rgba\(\d+, \d+, \d+, 0\.16\)$/,
      );
      expect(vars['--accent-ring']).toMatch(
        t.scheme === 'light'
          ? /^rgba\(\d+, \d+, \d+, 0\.38\)$/
          : /^rgba\(\d+, \d+, \d+, 0\.36\)$/,
      );
      expect(vars['--accent-fg']).toMatch(/^#(0b0b0c|ffffff)$/);
      expect(vars['--success-soft']).toMatch(
        /^rgba\(\d+, \d+, \d+, 0\.1[13]\)$/,
      );
      expect(vars['--warn-soft']).toMatch(/^rgba\(\d+, \d+, \d+, 0\.1[13]\)$/);
      expect(vars['--danger-soft']).toMatch(
        /^rgba\(\d+, \d+, \d+, 0\.1[03]\)$/,
      );
      expect(vars['--tachyon-accent-text']).toBe(t.colors.accentHover);
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

  it('applies unified compatibility variables for both light and dark themes', () => {
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
    expect(styleProps.get('--background-color-high')).toBe('#141416');
    expect(styleProps.get('--text-color-high')).toBe('#f5f5f7');

    setActiveTheme('material-dark');
    expect(attrs['data-tachyon-theme']).toBe('material-dark');
    expect(attrs['data-tachyon-theme-scheme']).toBe('dark');
    expect(styleProps.get('--bg')).toBe('#121316');
    expect(styleProps.get('--surface')).toBe('#1b1d22');

    for (const [id, bg, surface] of [
      ['everforest-light', '#edf2ec', '#f8fbf7'],
      ['material-light', '#f1f3f6', '#ffffff'],
      ['apple-light', '#f5f5f7', '#ffffff'],
      ['gruvbox-light', '#f2e5bc', '#fbf1c7'],
    ]) {
      setActiveTheme(id);
      expect(attrs['data-tachyon-theme']).toBe(id);
      expect(attrs['data-tachyon-theme-scheme']).toBe('light');
      expect(attrs['data-darkmode']).toBe('false');
      expect(styleProps.get('--bg')).toBe(bg);
      expect(styleProps.get('--surface')).toBe(surface);
    }
  });

  it('supports browser prefers-color-scheme mode, custom schedule mode, manual override, and custom theme cleanup', () => {
    let prefersDark = false;
    (globalThis as any).window = {
      matchMedia: () => ({ matches: prefersDark }),
    };

    try {
      setThemeAutoConfig({
        mode: 'system',
        lightThemeId: 'apple-light',
        darkThemeId: 'tokyo-night',
      });
      expect(storage.get(THEME_MODE_STORAGE_KEY)).toBe('system');
      expect(storage.get(THEME_LIGHT_ID_STORAGE_KEY)).toBe('apple-light');
      expect(storage.get(THEME_DARK_ID_STORAGE_KEY)).toBe('tokyo-night');
      expect(getActiveTheme().id).toBe('apple-light');

      prefersDark = true;
      expect(getActiveTheme().id).toBe('tokyo-night');

      // Schedule crossing midnight (22:00 .. 07:00)
      setThemeAutoConfig({
        mode: 'schedule',
        scheduleStart: '22:00',
        scheduleEnd: '07:00',
      });
      expect(storage.get(THEME_SCHEDULE_START_STORAGE_KEY)).toBe('22:00');
      expect(storage.get(THEME_SCHEDULE_END_STORAGE_KEY)).toBe('07:00');
      expect(
        isScheduleNightNow('22:00', '07:00', new Date(2026, 0, 1, 22, 0)),
      ).toBe(true);
      expect(
        isScheduleNightNow('22:00', '07:00', new Date(2026, 0, 1, 2, 30)),
      ).toBe(true);
      expect(
        isScheduleNightNow('22:00', '07:00', new Date(2026, 0, 1, 7, 0)),
      ).toBe(false);
      expect(
        isScheduleNightNow('22:00', '07:00', new Date(2026, 0, 1, 14, 0)),
      ).toBe(false);
      expect(resolveEffectiveThemeId(new Date(2026, 0, 1, 23, 15))).toBe(
        'tokyo-night',
      );
      expect(resolveEffectiveThemeId(new Date(2026, 0, 1, 12, 0))).toBe(
        'apple-light',
      );

      // Same-day schedule (09:00 .. 18:00)
      setThemeAutoConfig({
        mode: 'schedule',
        scheduleStart: '09:00',
        scheduleEnd: '18:00',
      });
      expect(resolveEffectiveThemeId(new Date(2026, 0, 1, 9, 0))).toBe(
        'tokyo-night',
      );
      expect(resolveEffectiveThemeId(new Date(2026, 0, 1, 18, 0))).toBe(
        'apple-light',
      );

      // Selecting a custom theme in auto config cleans up back to defaults on delete
      const custom = saveCustomTheme({
        name: 'Night Custom',
        scheme: 'dark',
        colors: { bg: '#111115', accent: '#38bdf8' },
      });
      setThemeAutoConfig({ darkThemeId: custom.id });
      expect(getThemeAutoConfig().darkThemeId).toBe(custom.id);
      deleteCustomTheme(custom.id);
      expect(getThemeAutoConfig().darkThemeId).toBe('default-dark');

      // Manual theme selection switches mode back to manual
      setActiveTheme('nord');
      expect(getThemeAutoConfig().mode).toBe('manual');
      expect(getActiveTheme().id).toBe('nord');
    } finally {
      delete (globalThis as any).window;
    }
  });

  it('persists and applies offline typography font presets and sizes', () => {
    expect(getTypographyConfig()).toEqual({
      sans: 'system',
      mono: 'system',
      size: 'normal',
    });

    const updated = setTypographyConfig({
      sans: 'geometric',
      mono: 'jetbrains',
      size: 'large',
    });
    expect(updated).toEqual({
      sans: 'geometric',
      mono: 'jetbrains',
      size: 'large',
    });
    expect(storage.get(FONT_SANS_STORAGE_KEY)).toBe('geometric');
    expect(storage.get(FONT_MONO_STORAGE_KEY)).toBe('jetbrains');
    expect(storage.get(FONT_SIZE_STORAGE_KEY)).toBe('large');

    const expectedSans = FONT_SANS_PRESETS.find(
      (p) => p.id === 'geometric',
    )?.value;
    const expectedMono = FONT_MONO_PRESETS.find(
      (p) => p.id === 'jetbrains',
    )?.value;
    const expectedSize = FONT_SIZE_PRESETS.find((p) => p.id === 'large')?.value;
    expect(styleProps.get('--sans')).toBe(expectedSans);
    expect(styleProps.get('--mono')).toBe(expectedMono);
    expect(styleProps.get('--tachyon-font-mono')).toBe(expectedMono);
    expect(styleProps.get('--font-mono')).toBe(expectedMono);
    expect(styleProps.get('--tachyon-font-size')).toBe(expectedSize);
    expect(attrs['data-tachyon-font-sans']).toBe('geometric');
    expect(attrs['data-tachyon-font-mono']).toBe('jetbrains');
    expect(attrs['data-tachyon-font-size']).toBe('large');

    const computed = computeTypographyCssVars({
      sans: 'mono',
      mono: 'plex',
      size: 'compact',
    });
    expect(computed['--sans']).toBe('var(--mono)');
    expect(computed['--tachyon-font-size']).toBe('13px');

    storage.set(FONT_SANS_STORAGE_KEY, 'unknown-font');
    const applied = applyTypographyToDocument();
    expect(applied.sans).toBe('system');
  });
});
