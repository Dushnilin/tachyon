import { describe, expect, it, vi, beforeEach } from 'vitest';

vi.mock('../methods/shell', () => ({
  TachyonShellMethods: {
    componentActionStart: vi.fn(),
    waitComponentActionJob: vi.fn(),
  },
}));

vi.mock('../../helpers/showToast', () => ({
  showToast: vi.fn(),
}));

import {
  detectActiveLanguageCode,
  TACHYON_LANGUAGES,
} from '../languageSelector';

describe('languageSelector', () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    (globalThis as unknown as { _: (s: string) => string })._ = (s: string) =>
      s;
  });

  it('defaults to English flag when luciLang is auto and translations are English', () => {
    expect(
      detectActiveLanguageCode({ i18nRuInstalled: false, luciLang: 'auto' }),
    ).toBe('en');
    expect(
      detectActiveLanguageCode({ i18nRuInstalled: true, luciLang: 'en' }),
    ).toBe('en');
  });

  it('detects Russian when luciLang is ru and ru package is installed', () => {
    expect(
      detectActiveLanguageCode({ i18nRuInstalled: true, luciLang: 'ru' }),
    ).toBe('ru');
  });

  it('falls back to English when luciLang is ru but ru package is not installed', () => {
    expect(
      detectActiveLanguageCode({ i18nRuInstalled: false, luciLang: 'ru' }),
    ).toBe('en');
  });

  it('detects Russian via gettext probe when luciLang is auto and translation is active', () => {
    (globalThis as unknown as { _: (s: string) => string })._ = (s: string) =>
      s === 'Settings' ? 'Настройки' : s;
    expect(
      detectActiveLanguageCode({ i18nRuInstalled: true, luciLang: 'auto' }),
    ).toBe('ru');
  });

  it('exposes extensible language registry starting with English and Russian', () => {
    expect(TACHYON_LANGUAGES.map((l) => l.code)).toEqual(['en', 'ru']);
    expect(TACHYON_LANGUAGES[0].requiresPackage).toBe(false);
    expect(TACHYON_LANGUAGES[1].requiresPackage).toBe(true);
    expect(TACHYON_LANGUAGES[0].flagSvg).toContain('<svg');
    expect(TACHYON_LANGUAGES[1].flagSvg).toContain('<svg');
  });
});
