/* eslint-disable @typescript-eslint/no-explicit-any */
export const THEME_ID_STORAGE_KEY = 'tachyon_ui_theme_id';
export const CUSTOM_THEMES_STORAGE_KEY = 'tachyon_ui_custom_themes';
export const THEME_CHANGED_EVENT = 'tachyon:theme-changed';
export const BG_ANIMATION_STORAGE_KEY = 'tachyon_ui_bg_animation';
export const BG_ANIMATION_CHANGED_EVENT = 'tachyon:bg-animation-changed';

export type ThemeScheme = 'dark' | 'light';

export interface TachyonThemeColors {
  bg: string;
  surface: string;
  hover: string;
  elevated: string;
  accent: string;
  accentHover: string;
  text: string;
  text2: string;
  text3: string;
  success: string;
  warn: string;
  danger: string;
}

export interface TachyonThemeDefinition {
  id: string;
  name: string;
  scheme: ThemeScheme;
  builtin?: boolean;
  colors: TachyonThemeColors;
}

export const DEFAULT_THEME_ID = 'default-dark';

export const BUILTIN_THEMES: readonly TachyonThemeDefinition[] = [
  {
    id: 'default-dark',
    name: 'Default Dark',
    scheme: 'dark',
    builtin: true,
    colors: {
      bg: '#0b0b0c',
      surface: '#141416',
      hover: '#1c1c1f',
      elevated: '#26262b',
      accent: '#0a84ff',
      accentHover: '#409cff',
      text: '#f5f5f7',
      text2: '#a1a1a6',
      text3: '#6e6e73',
      success: '#30d158',
      warn: '#ff9f0a',
      danger: '#ff453a',
    },
  },
  {
    id: 'legacy-dark',
    name: 'Legacy Dark',
    scheme: 'dark',
    builtin: true,
    colors: {
      bg: '#0d1117',
      surface: '#161b22',
      hover: '#1f2630',
      elevated: '#28313d',
      accent: '#58a6ff',
      accentHover: '#79c0ff',
      text: '#e6edf3',
      text2: '#8b949e',
      text3: '#6e7681',
      success: '#3fb950',
      warn: '#d29922',
      danger: '#f85149',
    },
  },
  {
    id: 'catppuccin',
    name: 'Catppuccin',
    scheme: 'dark',
    builtin: true,
    colors: {
      bg: '#1e1e2e',
      surface: '#242436',
      hover: '#313244',
      elevated: '#3b3d52',
      accent: '#89b4fa',
      accentHover: '#b4befe',
      text: '#cdd6f4',
      text2: '#a6adc8',
      text3: '#7f849c',
      success: '#a6e3a1',
      warn: '#f9e2af',
      danger: '#f38ba8',
    },
  },
  {
    id: 'dracula',
    name: 'Dracula',
    scheme: 'dark',
    builtin: true,
    colors: {
      bg: '#282a36',
      surface: '#2f3241',
      hover: '#383b4d',
      elevated: '#44475a',
      accent: '#bd93f9',
      accentHover: '#d1b3ff',
      text: '#f8f8f2',
      text2: '#b6bbd2',
      text3: '#6272a4',
      success: '#50fa7b',
      warn: '#ffb86c',
      danger: '#ff5555',
    },
  },
  {
    id: 'everforest',
    name: 'Everforest',
    scheme: 'dark',
    builtin: true,
    colors: {
      bg: '#272e33',
      surface: '#2e383c',
      hover: '#374145',
      elevated: '#414b50',
      accent: '#a7c080',
      accentHover: '#b8d194',
      text: '#d3c6aa',
      text2: '#9da9a0',
      text3: '#7a8478',
      success: '#83c092',
      warn: '#dbbc7f',
      danger: '#e67e80',
    },
  },
  {
    id: 'gruvbox-material',
    name: 'Gruvbox Material',
    scheme: 'dark',
    builtin: true,
    colors: {
      bg: '#1d2021',
      surface: '#282828',
      hover: '#32302f',
      elevated: '#3c3836',
      accent: '#d8a657',
      accentHover: '#e78a4e',
      text: '#d4be98',
      text2: '#a89984',
      text3: '#7c6f64',
      success: '#a9b665',
      warn: '#e78a4e',
      danger: '#ea6962',
    },
  },
  {
    id: 'monokai',
    name: 'Monokai',
    scheme: 'dark',
    builtin: true,
    colors: {
      bg: '#272822',
      surface: '#2e2f29',
      hover: '#383a32',
      elevated: '#46483e',
      accent: '#a6e22e',
      accentHover: '#c4f35c',
      text: '#f8f8f2',
      text2: '#c2c2b4',
      text3: '#75715e',
      success: '#a6e22e',
      warn: '#e6db74',
      danger: '#f92672',
    },
  },
  {
    id: 'nord',
    name: 'Nord',
    scheme: 'dark',
    builtin: true,
    colors: {
      bg: '#2e3440',
      surface: '#343b49',
      hover: '#3b4252',
      elevated: '#434c5e',
      accent: '#88c0d0',
      accentHover: '#8fbcbb',
      text: '#eceff4',
      text2: '#d8dee9',
      text3: '#8190a5',
      success: '#a3be8c',
      warn: '#ebcb8b',
      danger: '#bf616a',
    },
  },
  {
    id: 'one-dark-pro',
    name: 'One Dark Pro',
    scheme: 'dark',
    builtin: true,
    colors: {
      bg: '#21252b',
      surface: '#282c34',
      hover: '#323842',
      elevated: '#3e4451',
      accent: '#61afef',
      accentHover: '#82c4ff',
      text: '#abb2bf',
      text2: '#8b93a2',
      text3: '#5c6370',
      success: '#98c379',
      warn: '#e5c07b',
      danger: '#e06c75',
    },
  },
  {
    id: 'tokyo-night',
    name: 'Tokyo Night',
    scheme: 'dark',
    builtin: true,
    colors: {
      bg: '#1a1b26',
      surface: '#202330',
      hover: '#292e42',
      elevated: '#343b58',
      accent: '#7aa2f7',
      accentHover: '#9ab7ff',
      text: '#c0caf5',
      text2: '#9aa5ce',
      text3: '#565f89',
      success: '#9ece6a',
      warn: '#e0af68',
      danger: '#f7768e',
    },
  },
  {
    id: 'solarized-dark',
    name: 'Solarized Dark',
    scheme: 'dark',
    builtin: true,
    colors: {
      bg: '#002b36',
      surface: '#073642',
      hover: '#0d414f',
      elevated: '#144e5e',
      accent: '#268bd2',
      accentHover: '#2aa198',
      text: '#eee8d5',
      text2: '#93a1a1',
      text3: '#657b83',
      success: '#859900',
      warn: '#b58900',
      danger: '#dc322f',
    },
  },
  {
    id: 'vesper',
    name: 'Vesper',
    scheme: 'dark',
    builtin: true,
    colors: {
      bg: '#101010',
      surface: '#161616',
      hover: '#1f1f1f',
      elevated: '#282828',
      accent: '#ffc799',
      accentHover: '#ffd8b8',
      text: '#ffffff',
      text2: '#a0a0a0',
      text3: '#666666',
      success: '#99ffe4',
      warn: '#ffc799',
      danger: '#ff8080',
    },
  },
];

export const THEME_COLOR_FIELDS: ReadonlyArray<{
  key: keyof TachyonThemeColors;
  labelRu: string;
  labelEn: string;
}> = [
  { key: 'bg', labelRu: 'Основной фон (--bg)', labelEn: 'Background (--bg)' },
  {
    key: 'surface',
    labelRu: 'Поверхности и карточки (--surface)',
    labelEn: 'Surface & Cards (--surface)',
  },
  {
    key: 'hover',
    labelRu: 'Наведение (--hover)',
    labelEn: 'Hover State (--hover)',
  },
  {
    key: 'elevated',
    labelRu: 'Активные поля (--elevated)',
    labelEn: 'Elevated (--elevated)',
  },
  {
    key: 'accent',
    labelRu: 'Основной акцент (--accent)',
    labelEn: 'Primary Accent (--accent)',
  },
  {
    key: 'accentHover',
    labelRu: 'Акцент при наведении (--accent-hover)',
    labelEn: 'Accent Hover (--accent-hover)',
  },
  {
    key: 'text',
    labelRu: 'Основной текст (--text)',
    labelEn: 'Primary Text (--text)',
  },
  {
    key: 'text2',
    labelRu: 'Вторичный текст (--text2)',
    labelEn: 'Secondary Text (--text2)',
  },
  {
    key: 'text3',
    labelRu: 'Приглушённый текст (--text3)',
    labelEn: 'Muted Text (--text3)',
  },
  {
    key: 'success',
    labelRu: 'Успех / онлайн (--success)',
    labelEn: 'Success (--success)',
  },
  {
    key: 'warn',
    labelRu: 'Предупреждение (--warn)',
    labelEn: 'Warning (--warn)',
  },
  {
    key: 'danger',
    labelRu: 'Ошибка / опасность (--danger)',
    labelEn: 'Danger (--danger)',
  },
];

const listeners = new Set<(theme: TachyonThemeDefinition) => void>();

export function normalizeHexColor(raw: unknown, fallback: string): string {
  const s = String(raw ?? '')
    .trim()
    .replace(/^#/, '');
  if (/^[0-9a-f]{3}$/i.test(s)) {
    const [r, g, b] = s.split('');
    return `#${r}${r}${g}${g}${b}${b}`.toLowerCase();
  }
  if (/^[0-9a-f]{6}$/i.test(s)) {
    return `#${s}`.toLowerCase();
  }
  if (/^[0-9a-f]{8}$/i.test(s)) {
    return `#${s.slice(0, 6)}`.toLowerCase();
  }
  return fallback.toLowerCase();
}

function hexToRgbTuple(hex: string, fallback = '20, 20, 22'): string {
  const norm = normalizeHexColor(hex, '');
  if (!/^#[0-9a-f]{6}$/i.test(norm)) return fallback;
  const n = parseInt(norm.slice(1), 16);
  return `${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}`;
}

export function inferSchemeFromBg(bgHex: string): ThemeScheme {
  const norm = normalizeHexColor(bgHex, '#0b0b0c');
  const n = parseInt(norm.slice(1), 16);
  const r = ((n >> 16) & 255) / 255;
  const g = ((n >> 8) & 255) / 255;
  const b = (n & 255) / 255;
  const lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
  return lum > 0.56 ? 'light' : 'dark';
}

export function normalizeThemeColors(
  partial: Partial<TachyonThemeColors> | null | undefined,
  base: TachyonThemeColors = BUILTIN_THEMES[0].colors,
): TachyonThemeColors {
  return {
    bg: normalizeHexColor(partial?.bg, base.bg),
    surface: normalizeHexColor(partial?.surface, base.surface),
    hover: normalizeHexColor(partial?.hover, base.hover),
    elevated: normalizeHexColor(partial?.elevated, base.elevated),
    accent: normalizeHexColor(partial?.accent, base.accent),
    accentHover: normalizeHexColor(
      partial?.accentHover,
      partial?.accent
        ? normalizeHexColor(partial.accent, base.accentHover)
        : base.accentHover,
    ),
    text: normalizeHexColor(partial?.text, base.text),
    text2: normalizeHexColor(partial?.text2, base.text2),
    text3: normalizeHexColor(partial?.text3, base.text3),
    success: normalizeHexColor(partial?.success, base.success),
    warn: normalizeHexColor(partial?.warn, base.warn),
    danger: normalizeHexColor(partial?.danger, base.danger),
  };
}

export function computeThemeCssVars(
  theme: TachyonThemeDefinition,
): Record<string, string> {
  const c = normalizeThemeColors(theme.colors);
  const isLight = theme.scheme === 'light';
  return {
    '--color-scheme': isLight ? 'light' : 'dark',
    '--bg': c.bg,
    '--surface': c.surface,
    '--bg2': c.surface,
    '--hover': c.hover,
    '--elevated': c.elevated,
    '--accent': c.accent,
    '--accent-hover': c.accentHover,
    '--tachyon-theme-accent': c.accent,
    '--text': c.text,
    '--text2': c.text2,
    '--text3': c.text3,
    '--success': c.success,
    '--ok': c.success,
    '--warn': c.warn,
    '--danger': c.danger,
    '--border': isLight ? 'rgba(0, 0, 0, 0.10)' : 'rgba(255, 255, 255, 0.08)',
    '--border-strong': isLight
      ? 'rgba(0, 0, 0, 0.18)'
      : 'rgba(255, 255, 255, 0.15)',
    '--border-hi': isLight
      ? 'rgba(0, 0, 0, 0.18)'
      : 'rgba(255, 255, 255, 0.15)',
    '--surface-glass': `rgba(${hexToRgbTuple(c.surface, '20, 20, 22')}, 0.84)`,
    '--topbar-glass': `rgba(${hexToRgbTuple(c.surface, '20, 20, 22')}, 0.96)`,
    '--accent-soft': `rgba(${hexToRgbTuple(c.accent, '10, 132, 255')}, 0.16)`,
    '--accent-ring': `rgba(${hexToRgbTuple(c.accent, '10, 132, 255')}, 0.34)`,
    '--bg-grid-stroke': isLight
      ? 'rgba(0, 0, 0, 0.045)'
      : 'rgba(255, 255, 255, 0.028)',
  };
}

export function getCustomThemes(): TachyonThemeDefinition[] {
  if (typeof localStorage === 'undefined') return [];
  try {
    const raw = localStorage.getItem(CUSTOM_THEMES_STORAGE_KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed
      .filter(
        (item) =>
          item &&
          typeof item.id === 'string' &&
          item.id.trim() &&
          item.colors &&
          typeof item.colors === 'object',
      )
      .map((item) => ({
        id: String(item.id).trim(),
        name: String(item.name || item.id).trim() || 'Custom Theme',
        scheme: item.scheme === 'light' ? 'light' : 'dark',
        builtin: false,
        colors: normalizeThemeColors(item.colors),
      }));
  } catch {
    return [];
  }
}

function persistCustomThemes(list: TachyonThemeDefinition[]): void {
  if (typeof localStorage === 'undefined') return;
  try {
    const clean = list.map((t) => ({
      id: t.id,
      name: t.name,
      scheme: t.scheme,
      colors: normalizeThemeColors(t.colors),
    }));
    localStorage.setItem(CUSTOM_THEMES_STORAGE_KEY, JSON.stringify(clean));
  } catch {
    // ignore storage quota errors
  }
}

export function getAllThemes(): TachyonThemeDefinition[] {
  const custom = getCustomThemes();
  const builtinIds = new Set(BUILTIN_THEMES.map((t) => t.id));
  const filteredCustom = custom.filter((t) => !builtinIds.has(t.id));
  return [...BUILTIN_THEMES, ...filteredCustom];
}

export function getSavedThemeId(): string {
  if (typeof localStorage === 'undefined') return DEFAULT_THEME_ID;
  try {
    const raw = String(localStorage.getItem(THEME_ID_STORAGE_KEY) || '').trim();
    return raw || DEFAULT_THEME_ID;
  } catch {
    return DEFAULT_THEME_ID;
  }
}

export function getThemeById(id?: string | null): TachyonThemeDefinition {
  const target = String(id || '').trim();
  const all = getAllThemes();
  return all.find((t) => t.id === target) || all[0] || BUILTIN_THEMES[0];
}

export function getActiveTheme(): TachyonThemeDefinition {
  return getThemeById(getSavedThemeId());
}

export function isBgAnimationEnabled(): boolean {
  if (typeof localStorage === 'undefined') return true;
  try {
    return localStorage.getItem(BG_ANIMATION_STORAGE_KEY) !== 'false';
  } catch {
    return true;
  }
}

export function setBgAnimationEnabled(enabled: boolean): boolean {
  if (typeof localStorage !== 'undefined') {
    try {
      localStorage.setItem(
        BG_ANIMATION_STORAGE_KEY,
        enabled ? 'true' : 'false',
      );
    } catch {
      // ignore
    }
  }
  if (typeof document !== 'undefined' && document.documentElement) {
    document.documentElement.setAttribute(
      'data-tachyon-bg-animation',
      enabled ? 'true' : 'false',
    );
  }
  if (
    typeof window !== 'undefined' &&
    typeof window.dispatchEvent === 'function' &&
    typeof CustomEvent === 'function'
  ) {
    try {
      window.dispatchEvent(
        new CustomEvent(BG_ANIMATION_CHANGED_EVENT, { detail: { enabled } }),
      );
    } catch {
      // ignore
    }
  }
  return enabled;
}

export function applyThemeToDocument(
  themeOrId?: TachyonThemeDefinition | string | null,
  notify = false,
): TachyonThemeDefinition {
  const theme =
    typeof themeOrId === 'string' || !themeOrId
      ? getThemeById(themeOrId || getSavedThemeId())
      : {
          ...themeOrId,
          colors: normalizeThemeColors(themeOrId.colors),
        };

  if (typeof document !== 'undefined' && document.documentElement) {
    const root = document.documentElement;
    const vars = computeThemeCssVars(theme);
    for (const [key, val] of Object.entries(vars)) {
      root.style?.setProperty?.(key, val);
    }
    root.setAttribute?.('data-tachyon-theme', theme.id);
    root.setAttribute?.('data-tachyon-theme-scheme', theme.scheme);
    root.setAttribute?.(
      'data-darkmode',
      theme.scheme === 'light' ? 'false' : 'true',
    );
    root.setAttribute?.(
      'data-tachyon-bg-animation',
      isBgAnimationEnabled() ? 'true' : 'false',
    );
  }

  if (notify) {
    for (const cb of listeners) {
      try {
        cb(theme);
      } catch {
        // ignore subscriber errors
      }
    }
    if (
      typeof window !== 'undefined' &&
      typeof window.dispatchEvent === 'function' &&
      typeof CustomEvent === 'function'
    ) {
      try {
        window.dispatchEvent(
          new CustomEvent(THEME_CHANGED_EVENT, { detail: theme }),
        );
      } catch {
        // ignore
      }
    }
  }
  return theme;
}

export function setActiveTheme(id: string): TachyonThemeDefinition {
  const theme = getThemeById(id);
  if (typeof localStorage !== 'undefined') {
    try {
      localStorage.setItem(THEME_ID_STORAGE_KEY, theme.id);
    } catch {
      // ignore
    }
  }
  return applyThemeToDocument(theme, true);
}

export function slugifyCustomThemeId(name: string): string {
  const slug = String(name || '')
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
  const base = slug || 'custom-theme';
  const builtinIds = new Set(BUILTIN_THEMES.map((t) => t.id));
  return builtinIds.has(base) || base.startsWith('custom-')
    ? `custom-${base.replace(/^custom-/, '')}`
    : `custom-${base}`;
}

export function saveCustomTheme(input: {
  id?: string;
  name: string;
  scheme?: ThemeScheme;
  colors: Partial<TachyonThemeColors>;
}): TachyonThemeDefinition {
  const name = String(input.name || '').trim() || 'Custom Theme';
  const colors = normalizeThemeColors(input.colors);
  const scheme: ThemeScheme =
    input.scheme === 'light' || input.scheme === 'dark'
      ? input.scheme
      : inferSchemeFromBg(colors.bg);
  const builtinIds = new Set(BUILTIN_THEMES.map((t) => t.id));
  const rawId = String(input.id || '').trim();
  const id =
    rawId && !builtinIds.has(rawId) ? rawId : slugifyCustomThemeId(name);

  const saved: TachyonThemeDefinition = {
    id,
    name,
    scheme,
    builtin: false,
    colors,
  };

  const existing = getCustomThemes();
  const idx = existing.findIndex((t) => t.id === saved.id);
  if (idx >= 0) {
    existing[idx] = saved;
  } else {
    existing.push(saved);
  }
  persistCustomThemes(existing);
  return saved;
}

export function deleteCustomTheme(id: string): void {
  const target = String(id || '').trim();
  if (!target) return;
  const next = getCustomThemes().filter((t) => t.id !== target);
  persistCustomThemes(next);
  if (getSavedThemeId() === target) {
    setActiveTheme(DEFAULT_THEME_ID);
  } else {
    applyThemeToDocument(getActiveTheme(), true);
  }
}

export function subscribeThemeChange(
  cb: (theme: TachyonThemeDefinition) => void,
): () => void {
  listeners.add(cb);
  return () => listeners.delete(cb);
}

/**
 * Strips // and /* *\/ JSONC comments while preserving URLs inside strings,
 * and removes trailing commas before } or ].
 */
export function stripJsoncCommentsAndTrailingCommas(raw: string): string {
  const src = String(raw || '');
  let noComments = '';
  let inString = false;
  let escaped = false;
  let inLineComment = false;
  let inBlockComment = false;

  for (let i = 0; i < src.length; i++) {
    const ch = src[i];
    const next = src[i + 1];

    if (inLineComment) {
      if (ch === '\n' || ch === '\r') {
        inLineComment = false;
        noComments += ch;
      }
      continue;
    }

    if (inBlockComment) {
      if (ch === '*' && next === '/') {
        inBlockComment = false;
        i++;
      }
      continue;
    }

    if (inString) {
      noComments += ch;
      if (escaped) {
        escaped = false;
      } else if (ch === '\\') {
        escaped = true;
      } else if (ch === '"') {
        inString = false;
      }
      continue;
    }

    if (ch === '"') {
      inString = true;
      noComments += ch;
      continue;
    }
    if (ch === '/' && next === '/') {
      inLineComment = true;
      i++;
      continue;
    }
    if (ch === '/' && next === '*') {
      inBlockComment = true;
      i++;
      continue;
    }
    noComments += ch;
  }

  // Strip trailing commas outside strings
  let out = '';
  inString = false;
  escaped = false;
  for (let i = 0; i < noComments.length; i++) {
    const ch = noComments[i];
    if (inString) {
      out += ch;
      if (escaped) {
        escaped = false;
      } else if (ch === '\\') {
        escaped = true;
      } else if (ch === '"') {
        inString = false;
      }
      continue;
    }
    if (ch === '"') {
      inString = true;
      out += ch;
      continue;
    }
    if (ch === ',') {
      let j = i + 1;
      while (j < noComments.length && /\s/.test(noComments[j])) {
        j++;
      }
      if (noComments[j] === '}' || noComments[j] === ']') {
        continue;
      }
    }
    out += ch;
  }

  return out.trim();
}

export function parseThemeImportText(rawText: string): {
  name: string;
  scheme: ThemeScheme;
  colors: TachyonThemeColors;
} {
  const cleaned = stripJsoncCommentsAndTrailingCommas(rawText);
  if (!cleaned) {
    throw new Error('Empty theme JSON');
  }
  const obj = JSON.parse(cleaned) as Record<string, any>;
  if (!obj || typeof obj !== 'object' || Array.isArray(obj)) {
    throw new Error('Theme root must be a JSON object');
  }

  const base = BUILTIN_THEMES[0].colors;
  const rawColors =
    obj.colors && typeof obj.colors === 'object' ? obj.colors : obj;

  const pickHex = (keys: string[], fallback: string): string => {
    for (const k of keys) {
      if (rawColors[k] != null) {
        const norm = normalizeHexColor(rawColors[k], '');
        if (norm) return norm;
      }
    }
    return fallback;
  };

  const bg = pickHex(
    ['bg', 'editor.background', 'panel.background', 'terminal.background'],
    base.bg,
  );
  const surface = pickHex(
    [
      'surface',
      'sideBar.background',
      'titleBar.activeBackground',
      'editorWidget.background',
      'activityBar.background',
    ],
    bg,
  );
  const hover = pickHex(
    [
      'hover',
      'list.hoverBackground',
      'toolbar.hoverBackground',
      'editor.lineHighlightBackground',
    ],
    base.hover,
  );
  const elevated = pickHex(
    [
      'elevated',
      'list.activeSelectionBackground',
      'input.background',
      'dropdown.background',
    ],
    hover || base.elevated,
  );
  const accent = pickHex(
    [
      'accent',
      'button.background',
      'focusBorder',
      'textLink.foreground',
      'progressBar.background',
    ],
    base.accent,
  );
  const accentHover = pickHex(
    ['accentHover', 'button.hoverBackground', 'textLink.activeForeground'],
    accent,
  );
  const text = pickHex(
    ['text', 'editor.foreground', 'foreground', 'sideBar.foreground'],
    base.text,
  );
  const text2 = pickHex(
    [
      'text2',
      'descriptionForeground',
      'sideBarTitle.foreground',
      'statusBar.foreground',
    ],
    base.text2,
  );
  const text3 = pickHex(
    [
      'text3',
      'editorLineNumber.foreground',
      'input.placeholderForeground',
      'disabledForeground',
    ],
    base.text3,
  );
  const success = pickHex(
    [
      'success',
      'testing.iconPassed',
      'gitDecoration.addedResourceForeground',
      'terminal.ansiGreen',
    ],
    base.success,
  );
  const warn = pickHex(
    [
      'warn',
      'editorWarning.foreground',
      'gitDecoration.modifiedResourceForeground',
      'terminal.ansiYellow',
    ],
    base.warn,
  );
  const danger = pickHex(
    ['danger', 'editorError.foreground', 'errorForeground', 'terminal.ansiRed'],
    base.danger,
  );

  const colors: TachyonThemeColors = {
    bg,
    surface,
    hover,
    elevated,
    accent,
    accentHover,
    text,
    text2,
    text3,
    success,
    warn,
    danger,
  };

  const scheme: ThemeScheme =
    obj.scheme === 'light' || obj.type === 'light'
      ? 'light'
      : obj.scheme === 'dark' || obj.type === 'dark'
        ? 'dark'
        : inferSchemeFromBg(bg);

  const name =
    String(obj.name || obj.label || obj.id || '').trim() || 'Imported Theme';

  return { name, scheme, colors };
}

export function exportThemeJson(theme: TachyonThemeDefinition): string {
  return JSON.stringify(
    {
      name: theme.name,
      scheme: theme.scheme,
      colors: normalizeThemeColors(theme.colors),
    },
    null,
    2,
  );
}
