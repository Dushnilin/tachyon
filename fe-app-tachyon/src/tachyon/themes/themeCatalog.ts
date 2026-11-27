/* eslint-disable @typescript-eslint/no-explicit-any */
export const THEME_ID_STORAGE_KEY = 'tachyon_ui_theme_id';
export const THEME_MODE_STORAGE_KEY = 'tachyon_ui_theme_mode';
export const THEME_LIGHT_ID_STORAGE_KEY = 'tachyon_ui_theme_light_id';
export const THEME_DARK_ID_STORAGE_KEY = 'tachyon_ui_theme_dark_id';
export const THEME_SCHEDULE_START_STORAGE_KEY =
  'tachyon_ui_theme_schedule_start';
export const THEME_SCHEDULE_END_STORAGE_KEY = 'tachyon_ui_theme_schedule_end';
export const CUSTOM_THEMES_STORAGE_KEY = 'tachyon_ui_custom_themes';
export const THEME_CHANGED_EVENT = 'tachyon:theme-changed';
export const BG_ANIMATION_STORAGE_KEY = 'tachyon_ui_bg_animation';
export const BG_ANIMATION_CHANGED_EVENT = 'tachyon:bg-animation-changed';
export const FONT_SANS_STORAGE_KEY = 'tachyon_ui_font_sans';
export const FONT_MONO_STORAGE_KEY = 'tachyon_ui_font_mono';
export const FONT_SIZE_STORAGE_KEY = 'tachyon_ui_font_size';
export const TYPOGRAPHY_CHANGED_EVENT = 'tachyon:typography-changed';

export type ThemeScheme = 'dark' | 'light';
export type ThemeAutoMode = 'manual' | 'system' | 'schedule';
export type FontSansPresetId =
  | 'system'
  | 'geometric'
  | 'humanist'
  | 'mono'
  | 'serif';
export type FontMonoPresetId = 'system' | 'jetbrains' | 'cascadia' | 'plex';
export type FontSizePresetId = 'compact' | 'normal' | 'large';

export interface TypographyConfig {
  sans: FontSansPresetId;
  mono: FontMonoPresetId;
  size: FontSizePresetId;
}

export interface FontPresetDefinition<T extends string = string> {
  id: T;
  labelRu: string;
  labelEn: string;
  value: string;
}

export const FONT_SANS_PRESETS: ReadonlyArray<
  FontPresetDefinition<FontSansPresetId>
> = [
  {
    id: 'system',
    labelRu: 'Системный (Apple / UI)',
    labelEn: 'System (Apple / UI)',
    value:
      '-apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", "Inter", system-ui, sans-serif',
  },
  {
    id: 'geometric',
    labelRu: 'Геометрический (Inter / Segoe)',
    labelEn: 'Geometric (Inter / Segoe)',
    value:
      '"Inter", "Segoe UI Variable", "Segoe UI", "Roboto", "Helvetica Neue", Arial, sans-serif',
  },
  {
    id: 'humanist',
    labelRu: 'Гуманистический (Ubuntu / Noto)',
    labelEn: 'Humanist (Ubuntu / Noto)',
    value:
      '"Ubuntu", "Cantarell", "Noto Sans", "DejaVu Sans", "Segoe UI", Tahoma, sans-serif',
  },
  {
    id: 'mono',
    labelRu: 'Терминальный (Mono)',
    labelEn: 'Terminal (Monospace)',
    value: 'var(--mono)',
  },
  {
    id: 'serif',
    labelRu: 'Книжный (Serif)',
    labelEn: 'Editorial (Serif)',
    value: '"Charter", "Iowan Old Style", Georgia, "Times New Roman", serif',
  },
];

export const FONT_MONO_PRESETS: ReadonlyArray<
  FontPresetDefinition<FontMonoPresetId>
> = [
  {
    id: 'system',
    labelRu: 'Системный Mono',
    labelEn: 'System Mono',
    value:
      '"SF Mono", ui-monospace, "Cascadia Code", "JetBrains Mono", "Fira Code", Consolas, monospace',
  },
  {
    id: 'jetbrains',
    labelRu: 'JetBrains / Fira Code',
    labelEn: 'JetBrains / Fira Code',
    value:
      '"JetBrains Mono", "Fira Code", "Cascadia Code", ui-monospace, Consolas, monospace',
  },
  {
    id: 'cascadia',
    labelRu: 'Cascadia / Consolas',
    labelEn: 'Cascadia / Consolas',
    value:
      '"Cascadia Code", "Cascadia Mono", Consolas, "Courier New", monospace',
  },
  {
    id: 'plex',
    labelRu: 'IBM Plex / Roboto Mono',
    labelEn: 'IBM Plex / Roboto Mono',
    value:
      '"IBM Plex Mono", "Roboto Mono", "DejaVu Sans Mono", ui-monospace, monospace',
  },
];

export const FONT_SIZE_PRESETS: ReadonlyArray<
  FontPresetDefinition<FontSizePresetId>
> = [
  {
    id: 'compact',
    labelRu: 'Компактный (13px)',
    labelEn: 'Compact (13px)',
    value: '13px',
  },
  {
    id: 'normal',
    labelRu: 'Стандартный (14px)',
    labelEn: 'Default (14px)',
    value: '14px',
  },
  {
    id: 'large',
    labelRu: 'Крупный (15px)',
    labelEn: 'Large (15px)',
    value: '15px',
  },
];

export interface ThemeAutoConfig {
  mode: ThemeAutoMode;
  lightThemeId: string;
  darkThemeId: string;
  scheduleStart: string;
  scheduleEnd: string;
}

export const DEFAULT_LIGHT_THEME_ID = 'default-light';
export const DEFAULT_DARK_THEME_ID = 'default-dark';
export const DEFAULT_SCHEDULE_START = '22:00';
export const DEFAULT_SCHEDULE_END = '07:00';

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
    id: 'default-light',
    name: 'Default Light',
    scheme: 'light',
    builtin: true,
    colors: {
      bg: '#f5f7fb',
      surface: '#ffffff',
      hover: '#f1f5f9',
      elevated: '#e2e8f0',
      accent: '#0a84ff',
      accentHover: '#005bb5',
      text: '#0f172a',
      text2: '#334155',
      text3: '#475569',
      success: '#15803d',
      warn: '#b45309',
      danger: '#b91c1c',
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
  {
    id: 'material-dark',
    name: 'Material Dark',
    scheme: 'dark',
    builtin: true,
    colors: {
      bg: '#121316',
      surface: '#1b1d22',
      hover: '#24272e',
      elevated: '#2e323b',
      accent: '#82aaff',
      accentHover: '#a5c2ff',
      text: '#eeffff',
      text2: '#b2ccd6',
      text3: '#697098',
      success: '#c3e88d',
      warn: '#ffcb6b',
      danger: '#f07178',
    },
  },
  {
    id: 'everforest-light',
    name: 'Everforest Light',
    scheme: 'light',
    builtin: true,
    colors: {
      bg: '#edf2ec',
      surface: '#f8fbf7',
      hover: '#e2ebe0',
      elevated: '#d4e2d2',
      accent: '#237a54',
      accentHover: '#1a6142',
      text: '#1f2d27',
      text2: '#465c52',
      text3: '#687e74',
      success: '#2d7a47',
      warn: '#b4690e',
      danger: '#c23b3b',
    },
  },
  {
    id: 'material-light',
    name: 'Material Light',
    scheme: 'light',
    builtin: true,
    colors: {
      bg: '#f1f3f6',
      surface: '#ffffff',
      hover: '#e8edf3',
      elevated: '#dce4ef',
      accent: '#1a73e8',
      accentHover: '#1557b0',
      text: '#1c1f24',
      text2: '#4b5563',
      text3: '#6b7280',
      success: '#188038',
      warn: '#b06000',
      danger: '#d93025',
    },
  },
  {
    id: 'apple-light',
    name: 'Apple Light',
    scheme: 'light',
    builtin: true,
    colors: {
      bg: '#f5f5f7',
      surface: '#ffffff',
      hover: '#ebebf0',
      elevated: '#e2e2e8',
      accent: '#0071e3',
      accentHover: '#005bb5',
      text: '#1d1d1f',
      text2: '#515154',
      text3: '#6e6e73',
      success: '#248a3d',
      warn: '#b25000',
      danger: '#d70015',
    },
  },
  {
    id: 'gruvbox-light',
    name: 'Gruvbox Light',
    scheme: 'light',
    builtin: true,
    colors: {
      bg: '#f2e5bc',
      surface: '#fbf1c7',
      hover: '#ebdbb2',
      elevated: '#dfcfa0',
      accent: '#076678',
      accentHover: '#427b58',
      text: '#282828',
      text2: '#504945',
      text3: '#7c6f64',
      success: '#79740e',
      warn: '#b57614',
      danger: '#9d0006',
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
  const surfaceRgb = hexToRgbTuple(
    c.surface,
    isLight ? '255, 255, 255' : '20, 20, 22',
  );
  const accentRgb = hexToRgbTuple(c.accent, '10, 132, 255');
  const successRgb = hexToRgbTuple(c.success, '48, 209, 88');
  const warnRgb = hexToRgbTuple(c.warn, '255, 159, 10');
  const dangerRgb = hexToRgbTuple(c.danger, '255, 69, 58');

  const border = isLight ? 'rgba(0, 0, 0, 0.10)' : 'rgba(255, 255, 255, 0.08)';
  const borderStrong = isLight
    ? 'rgba(0, 0, 0, 0.18)'
    : 'rgba(255, 255, 255, 0.15)';
  const accentSoft = `rgba(${accentRgb}, ${isLight ? '0.12' : '0.16'})`;
  const accentRing = `rgba(${accentRgb}, ${isLight ? '0.38' : '0.36'})`;
  const accentText = c.accentHover;
  const accentTextHover = isLight ? c.accent : c.accentHover;
  const successSoft = `rgba(${successRgb}, ${isLight ? '0.11' : '0.13'})`;
  const successBorder = `rgba(${successRgb}, ${isLight ? '0.32' : '0.34'})`;
  const warnSoft = `rgba(${warnRgb}, ${isLight ? '0.11' : '0.13'})`;
  const warnBorder = `rgba(${warnRgb}, ${isLight ? '0.34' : '0.35'})`;
  const dangerSoft = `rgba(${dangerRgb}, ${isLight ? '0.10' : '0.13'})`;
  const dangerBorder = `rgba(${dangerRgb}, ${isLight ? '0.32' : '0.36'})`;

  return {
    '--color-scheme': isLight ? 'light' : 'dark',
    '--bg': c.bg,
    '--surface': c.surface,
    '--bg2': c.surface,
    '--surface2': c.hover,
    '--hover': c.hover,
    '--elevated': c.elevated,
    '--accent': c.accent,
    '--accent-hover': c.accentHover,
    '--accent-fg':
      inferSchemeFromBg(c.accent) === 'light' ? '#0b0b0c' : '#ffffff',
    '--tachyon-theme-accent': c.accent,
    '--text': c.text,
    '--text2': c.text2,
    '--text3': c.text3,
    '--muted': c.text2,
    '--success': c.success,
    '--ok': c.success,
    '--warn': c.warn,
    '--warning': c.warn,
    '--danger': c.danger,
    '--border': border,
    '--border-strong': borderStrong,
    '--border-hi': borderStrong,
    '--surface-glass': `rgba(${surfaceRgb}, ${isLight ? '0.92' : '0.86'})`,
    '--topbar-glass': `rgba(${surfaceRgb}, ${isLight ? '0.96' : '0.94'})`,
    '--accent-soft': accentSoft,
    '--accent-ring': accentRing,
    '--accent-text': accentText,
    '--accent-text-hover': accentTextHover,
    '--success-soft': successSoft,
    '--success-border': successBorder,
    '--warn-soft': warnSoft,
    '--warn-border': warnBorder,
    '--danger-soft': dangerSoft,
    '--danger-border': dangerBorder,
    '--row-hover': isLight
      ? 'rgba(0, 0, 0, 0.03)'
      : 'rgba(255, 255, 255, 0.03)',
    '--bg-grid-stroke': isLight
      ? 'rgba(0, 0, 0, 0.05)'
      : 'rgba(255, 255, 255, 0.028)',
    '--modal-backdrop': isLight
      ? 'rgba(15, 23, 42, 0.36)'
      : 'rgba(0, 0, 0, 0.62)',
    '--shadow-card': isLight
      ? '0 2px 10px rgba(15, 23, 42, 0.06), inset 0 1px 0 rgba(255, 255, 255, 0.7)'
      : 'inset 0 1px 0 rgba(255, 255, 255, 0.04)',
    '--shadow-popover': isLight
      ? '0 16px 40px rgba(15, 23, 42, 0.16)'
      : '0 18px 44px rgba(0, 0, 0, 0.62)',
    '--shadow-modal': isLight
      ? '0 24px 48px rgba(15, 23, 42, 0.18)'
      : '0 24px 48px rgba(0, 0, 0, 0.58)',
    '--background-color-high': c.surface,
    '--background-color-medium': c.bg,
    '--background-color-low': c.hover,
    '--border-color-high': borderStrong,
    '--border-color-medium': border,
    '--border-color-low': isLight
      ? 'rgba(0, 0, 0, 0.07)'
      : 'rgba(255, 255, 255, 0.06)',
    '--text-color-high': c.text,
    '--text-color-medium': c.text2,
    '--text-color-low': c.text3,
    '--primary-color-high': c.accent,
    '--primary-color-medium': c.accent,
    '--primary-color-low': accentSoft,
    '--tachyon-text-primary': c.text,
    '--tachyon-bg-input': isLight ? c.hover : c.bg,
    '--tachyon-accent': c.accent,
    '--tachyon-accent-strong': c.accentHover,
    '--tachyon-accent-soft': accentSoft,
    '--tachyon-accent-border': accentRing,
    '--tachyon-accent-text': accentText,
    '--tachyon-accent-text-hover': accentTextHover,
    '--tachyon-success': c.success,
    '--tachyon-success-soft': successSoft,
    '--tachyon-success-border': successBorder,
    '--tachyon-warning': c.warn,
    '--tachyon-warning-soft': warnSoft,
    '--tachyon-warning-border': warnBorder,
    '--tachyon-danger': c.danger,
    '--tachyon-danger-soft': dangerSoft,
    '--tachyon-danger-border': dangerBorder,
  };
}

function findFontPresetValue<T extends string>(
  presets: ReadonlyArray<FontPresetDefinition<T>>,
  id: string,
): string {
  return (presets.find((p) => p.id === id) || presets[0]).value;
}

export function getTypographyConfig(): TypographyConfig {
  const fallback: TypographyConfig = {
    sans: 'system',
    mono: 'system',
    size: 'normal',
  };
  if (typeof localStorage === 'undefined') return fallback;
  try {
    const rawSans = String(
      localStorage.getItem(FONT_SANS_STORAGE_KEY) || '',
    ).trim();
    const rawMono = String(
      localStorage.getItem(FONT_MONO_STORAGE_KEY) || '',
    ).trim();
    const rawSize = String(
      localStorage.getItem(FONT_SIZE_STORAGE_KEY) || '',
    ).trim();
    return {
      sans: FONT_SANS_PRESETS.some((p) => p.id === rawSans)
        ? (rawSans as FontSansPresetId)
        : fallback.sans,
      mono: FONT_MONO_PRESETS.some((p) => p.id === rawMono)
        ? (rawMono as FontMonoPresetId)
        : fallback.mono,
      size: FONT_SIZE_PRESETS.some((p) => p.id === rawSize)
        ? (rawSize as FontSizePresetId)
        : fallback.size,
    };
  } catch {
    return fallback;
  }
}

export function computeTypographyCssVars(
  cfg: TypographyConfig,
): Record<string, string> {
  const sans = findFontPresetValue(FONT_SANS_PRESETS, cfg.sans);
  const mono = findFontPresetValue(FONT_MONO_PRESETS, cfg.mono);
  const size = findFontPresetValue(FONT_SIZE_PRESETS, cfg.size);
  return {
    '--sans': sans,
    '--mono': mono,
    '--tachyon-font-mono': mono,
    '--font-mono': mono,
    '--tachyon-font-size': size,
  };
}

export function applyTypographyToDocument(
  cfg: TypographyConfig = getTypographyConfig(),
): TypographyConfig {
  const vars = computeTypographyCssVars(cfg);
  if (typeof document !== 'undefined' && document.documentElement) {
    const root = document.documentElement;
    for (const [key, val] of Object.entries(vars)) {
      root.style?.setProperty?.(key, val);
    }
    root.setAttribute?.('data-tachyon-font-sans', cfg.sans);
    root.setAttribute?.('data-tachyon-font-mono', cfg.mono);
    root.setAttribute?.('data-tachyon-font-size', cfg.size);
  }
  return cfg;
}

export function setTypographyConfig(
  patch: Partial<TypographyConfig>,
): TypographyConfig {
  const cur = getTypographyConfig();
  const next: TypographyConfig = {
    sans:
      patch.sans && FONT_SANS_PRESETS.some((p) => p.id === patch.sans)
        ? patch.sans
        : cur.sans,
    mono:
      patch.mono && FONT_MONO_PRESETS.some((p) => p.id === patch.mono)
        ? patch.mono
        : cur.mono,
    size:
      patch.size && FONT_SIZE_PRESETS.some((p) => p.id === patch.size)
        ? patch.size
        : cur.size,
  };
  if (typeof localStorage !== 'undefined') {
    try {
      localStorage.setItem(FONT_SANS_STORAGE_KEY, next.sans);
      localStorage.setItem(FONT_MONO_STORAGE_KEY, next.mono);
      localStorage.setItem(FONT_SIZE_STORAGE_KEY, next.size);
    } catch {
      // ignore
    }
  }
  applyTypographyToDocument(next);
  if (
    typeof window !== 'undefined' &&
    typeof window.dispatchEvent === 'function' &&
    typeof CustomEvent === 'function'
  ) {
    try {
      window.dispatchEvent(
        new CustomEvent(TYPOGRAPHY_CHANGED_EVENT, { detail: next }),
      );
    } catch {
      // ignore
    }
  }
  return next;
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
    if (raw) return raw;
    if (localStorage.getItem('tachyon_color_scheme_v1') === 'light') {
      return 'default-light';
    }
    return DEFAULT_THEME_ID;
  } catch {
    return DEFAULT_THEME_ID;
  }
}

export function getThemeById(id?: string | null): TachyonThemeDefinition {
  const target = String(id || '').trim();
  const all = getAllThemes();
  return all.find((t) => t.id === target) || all[0] || BUILTIN_THEMES[0];
}

function hasThemeId(id: string): boolean {
  const target = String(id || '').trim();
  return Boolean(target && getAllThemes().some((t) => t.id === target));
}

export function parseTimeToMinutes(
  hhmm: string,
  fallbackMinutes: number,
): number {
  const match = /^(\d{1,2}):(\d{2})$/.exec(String(hhmm || '').trim());
  if (!match) return fallbackMinutes;
  const h = Number(match[1]);
  const m = Number(match[2]);
  if (
    !Number.isInteger(h) ||
    !Number.isInteger(m) ||
    h < 0 ||
    h > 23 ||
    m < 0 ||
    m > 59
  ) {
    return fallbackMinutes;
  }
  return h * 60 + m;
}

export function normalizeTimeHHMM(raw: string, fallback: string): string {
  const match = /^(\d{1,2}):(\d{2})$/.exec(String(raw || '').trim());
  if (!match) return fallback;
  const h = Number(match[1]);
  const m = Number(match[2]);
  if (
    !Number.isInteger(h) ||
    !Number.isInteger(m) ||
    h < 0 ||
    h > 23 ||
    m < 0 ||
    m > 59
  ) {
    return fallback;
  }
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}`;
}

export function isScheduleNightNow(
  startHHMM: string,
  endHHMM: string,
  now: Date = new Date(),
): boolean {
  const start = parseTimeToMinutes(startHHMM, 22 * 60);
  const end = parseTimeToMinutes(endHHMM, 7 * 60);
  if (start === end) return false;
  const cur = now.getHours() * 60 + now.getMinutes();
  if (start < end) {
    return cur >= start && cur < end;
  }
  return cur >= start || cur < end;
}

export function getSystemPrefersDark(): boolean {
  if (
    typeof window === 'undefined' ||
    typeof window.matchMedia !== 'function'
  ) {
    return true;
  }
  try {
    return Boolean(window.matchMedia('(prefers-color-scheme: dark)')?.matches);
  } catch {
    return true;
  }
}

export function getThemeAutoConfig(): ThemeAutoConfig {
  const fallback: ThemeAutoConfig = {
    mode: 'manual',
    lightThemeId: DEFAULT_LIGHT_THEME_ID,
    darkThemeId: DEFAULT_DARK_THEME_ID,
    scheduleStart: DEFAULT_SCHEDULE_START,
    scheduleEnd: DEFAULT_SCHEDULE_END,
  };
  if (typeof localStorage === 'undefined') return fallback;
  try {
    const rawMode = String(
      localStorage.getItem(THEME_MODE_STORAGE_KEY) || '',
    ).trim();
    const mode: ThemeAutoMode =
      rawMode === 'system' || rawMode === 'schedule' ? rawMode : 'manual';
    const rawLight = String(
      localStorage.getItem(THEME_LIGHT_ID_STORAGE_KEY) || '',
    ).trim();
    const rawDark = String(
      localStorage.getItem(THEME_DARK_ID_STORAGE_KEY) || '',
    ).trim();
    const lightThemeId = hasThemeId(rawLight)
      ? rawLight
      : DEFAULT_LIGHT_THEME_ID;
    const darkThemeId = hasThemeId(rawDark) ? rawDark : DEFAULT_DARK_THEME_ID;
    const scheduleStart = normalizeTimeHHMM(
      String(localStorage.getItem(THEME_SCHEDULE_START_STORAGE_KEY) || ''),
      DEFAULT_SCHEDULE_START,
    );
    const scheduleEnd = normalizeTimeHHMM(
      String(localStorage.getItem(THEME_SCHEDULE_END_STORAGE_KEY) || ''),
      DEFAULT_SCHEDULE_END,
    );
    return { mode, lightThemeId, darkThemeId, scheduleStart, scheduleEnd };
  } catch {
    return fallback;
  }
}

export function resolveEffectiveThemeId(now: Date = new Date()): string {
  const cfg = getThemeAutoConfig();
  if (cfg.mode === 'system') {
    return getSystemPrefersDark() ? cfg.darkThemeId : cfg.lightThemeId;
  }
  if (cfg.mode === 'schedule') {
    return isScheduleNightNow(cfg.scheduleStart, cfg.scheduleEnd, now)
      ? cfg.darkThemeId
      : cfg.lightThemeId;
  }
  return getSavedThemeId();
}

export function getActiveTheme(): TachyonThemeDefinition {
  return getThemeById(resolveEffectiveThemeId());
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
    applyTypographyToDocument();
    if (document.head) {
      let meta = document.head.querySelector(
        'meta[name="color-scheme"]',
      ) as HTMLMetaElement | null;
      if (!meta) {
        meta = document.createElement('meta');
        meta.name = 'color-scheme';
        document.head.insertBefore(meta, document.head.firstChild);
      }
      meta.content = theme.scheme === 'light' ? 'light' : 'dark';
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
      localStorage.setItem(THEME_MODE_STORAGE_KEY, 'manual');
    } catch {
      // ignore
    }
  }
  return applyThemeToDocument(theme, true);
}

export function setThemeAutoConfig(
  patch: Partial<ThemeAutoConfig>,
): TachyonThemeDefinition {
  const cur = getThemeAutoConfig();
  const nextMode: ThemeAutoMode =
    patch.mode === 'system' ||
    patch.mode === 'schedule' ||
    patch.mode === 'manual'
      ? patch.mode
      : cur.mode;
  const nextLight =
    patch.lightThemeId && hasThemeId(patch.lightThemeId)
      ? patch.lightThemeId
      : cur.lightThemeId;
  const nextDark =
    patch.darkThemeId && hasThemeId(patch.darkThemeId)
      ? patch.darkThemeId
      : cur.darkThemeId;
  const nextStart =
    patch.scheduleStart !== undefined
      ? normalizeTimeHHMM(patch.scheduleStart, cur.scheduleStart)
      : cur.scheduleStart;
  const nextEnd =
    patch.scheduleEnd !== undefined
      ? normalizeTimeHHMM(patch.scheduleEnd, cur.scheduleEnd)
      : cur.scheduleEnd;

  if (typeof localStorage !== 'undefined') {
    try {
      localStorage.setItem(THEME_MODE_STORAGE_KEY, nextMode);
      localStorage.setItem(THEME_LIGHT_ID_STORAGE_KEY, nextLight);
      localStorage.setItem(THEME_DARK_ID_STORAGE_KEY, nextDark);
      localStorage.setItem(THEME_SCHEDULE_START_STORAGE_KEY, nextStart);
      localStorage.setItem(THEME_SCHEDULE_END_STORAGE_KEY, nextEnd);
    } catch {
      // ignore
    }
  }
  ensureAutoThemeWatcher();
  return applyThemeToDocument(getActiveTheme(), true);
}

let autoWatcherInstalled = false;

export function ensureAutoThemeWatcher(): void {
  if (autoWatcherInstalled || typeof window === 'undefined') return;
  autoWatcherInstalled = true;

  const syncIfNeeded = () => {
    const cfg = getThemeAutoConfig();
    if (cfg.mode === 'manual') return;
    const target = getThemeById(resolveEffectiveThemeId());
    const currentId =
      typeof document !== 'undefined'
        ? document.documentElement?.getAttribute?.('data-tachyon-theme')
        : null;
    if (target.id !== currentId) {
      applyThemeToDocument(target, true);
    }
  };

  try {
    if (typeof window.matchMedia === 'function') {
      const mql = window.matchMedia('(prefers-color-scheme: dark)');
      if (mql && typeof mql.addEventListener === 'function') {
        mql.addEventListener('change', syncIfNeeded);
      } else if (mql && typeof (mql as any).addListener === 'function') {
        (mql as any).addListener(syncIfNeeded);
      }
    }
  } catch {
    // ignore matchMedia failures
  }

  if (
    typeof document !== 'undefined' &&
    typeof document.addEventListener === 'function'
  ) {
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState !== 'hidden') {
        syncIfNeeded();
      }
    });
  }

  if (typeof window.setInterval === 'function') {
    window.setInterval(syncIfNeeded, 30_000);
  }
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
  if (typeof localStorage !== 'undefined') {
    try {
      if (localStorage.getItem(THEME_LIGHT_ID_STORAGE_KEY) === target) {
        localStorage.setItem(
          THEME_LIGHT_ID_STORAGE_KEY,
          DEFAULT_LIGHT_THEME_ID,
        );
      }
      if (localStorage.getItem(THEME_DARK_ID_STORAGE_KEY) === target) {
        localStorage.setItem(THEME_DARK_ID_STORAGE_KEY, DEFAULT_DARK_THEME_ID);
      }
    } catch {
      // ignore
    }
  }
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
