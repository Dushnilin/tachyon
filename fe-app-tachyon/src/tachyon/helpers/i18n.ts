/**
 * Detects whether the current UI language is Russian.
 * Checks DOM html[lang], document.documentElement.lang, LuCI environment,
 * and standard base translations.
 */
export function isRussianLanguage(): boolean {
  if (typeof document !== 'undefined') {
    const docLang = (
      document.documentElement?.lang ||
      document.querySelector('html')?.getAttribute('lang') ||
      ''
    ).toLowerCase();
    if (docLang.startsWith('ru')) return true;
    if (docLang.startsWith('en')) return false;
  }

  const globalObj = (
    typeof globalThis !== 'undefined'
      ? globalThis
      : typeof window !== 'undefined'
        ? window
        : {}
  ) as { L?: { env?: { lang?: string } } };
  const globalL = globalObj.L;

  if (typeof globalL?.env?.lang === 'string') {
    const envLang = globalL.env.lang.trim().toLowerCase();
    if (envLang.startsWith('ru')) return true;
    if (envLang.startsWith('en')) return false;
  }

  try {
    if (typeof _ === 'function') {
      if (
        _('Status') === 'Статус' ||
        _('Settings') === 'Настройки' ||
        _('Overview') === 'Обзор' ||
        _('Save') === 'Сохранить'
      ) {
        return true;
      }
    }
  } catch {
    // Ignore translation resolution errors
  }

  return false;
}

/**
 * Returns Russian text if current UI is RU, otherwise English.
 */
export function tr(ru: string, en: string): string {
  return isRussianLanguage() ? ru : en;
}
