import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest';

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
  mountLanguageSelector,
  TACHYON_LANGUAGES,
} from '../languageSelector';
import { TachyonShellMethods } from '../methods/shell';

interface StubClickEvent {
  preventDefault: () => void;
  stopPropagation: () => void;
}

interface StubClassList {
  add: (...tokens: string[]) => void;
  remove: (...tokens: string[]) => void;
  contains: (token: string) => boolean;
  toggle: (token: string, force?: boolean) => boolean;
}

interface StubElement {
  tagName: string;
  lang: string;
  hidden: boolean;
  disabled: boolean;
  textContent: string;
  className: string;
  classList: StubClassList;
  children: StubElement[];
  setAttribute: (name: string, value: string) => void;
  getAttribute: (name: string) => string | null;
  appendChild: (child: StubElement) => StubElement;
  addEventListener: (
    event: string,
    handler: (ev: StubClickEvent) => void,
  ) => void;
  click: () => void;
  querySelector: (selector: string) => StubElement | null;
  querySelectorAll: (selector: string) => StubElement[];
  outerHTML: string;
  innerHTML: string;
}

function createStubElement(tag: string): StubElement {
  const classes = new Set<string>();
  const attrs = new Map<string, string>();
  const listeners = new Map<string, Array<(ev: StubClickEvent) => void>>();
  const children: StubElement[] = [];
  let textVal = '';
  let hiddenVal = false;
  let innerHtmlVal = '';

  const matchesSimple = (node: StubElement, part: string): boolean => {
    const dataLangMatch = part.match(/^\.([^[]+)\[data-lang="([^"]+)"\]$/);
    if (dataLangMatch) {
      return (
        node.classList.contains(dataLangMatch[1]) &&
        node.getAttribute('data-lang') === dataLangMatch[2]
      );
    }
    const multiClass = part.split('.').filter(Boolean);
    if (part.startsWith('.') && multiClass.length > 0) {
      return multiClass.every((c) => node.classList.contains(c));
    }
    return node.tagName.toLowerCase() === part.toLowerCase();
  };

  const collectAll = (root: StubElement, out: StubElement[]): void => {
    for (const c of root.children) {
      out.push(c);
      collectAll(c, out);
    }
  };

  const el: StubElement = {
    tagName: tag.toUpperCase(),
    lang: '',
    disabled: false,
    children,
    get hidden() {
      return hiddenVal;
    },
    set hidden(v: boolean) {
      hiddenVal = Boolean(v);
    },
    get textContent() {
      if (textVal) return textVal;
      return children.map((c) => c.textContent).join('');
    },
    set textContent(v: string) {
      textVal = String(v);
    },
    get className() {
      return Array.from(classes).join(' ');
    },
    set className(v: string) {
      classes.clear();
      for (const part of String(v).split(/\s+/)) {
        if (part) classes.add(part);
      }
    },
    classList: {
      add(...tokens: string[]) {
        for (const t of tokens) {
          if (t) classes.add(t);
        }
      },
      remove(...tokens: string[]) {
        for (const t of tokens) classes.delete(t);
      },
      contains(token: string) {
        return classes.has(token);
      },
      toggle(token: string, force?: boolean) {
        const next = force === undefined ? !classes.has(token) : force;
        if (next) classes.add(token);
        else classes.delete(token);
        return next;
      },
    },
    setAttribute(name: string, value: string) {
      if (name === 'class') {
        el.className = value;
      } else {
        attrs.set(name, String(value));
      }
    },
    getAttribute(name: string) {
      return attrs.get(name) ?? null;
    },
    appendChild(child: StubElement) {
      children.push(child);
      return child;
    },
    addEventListener(event: string, handler: (ev: StubClickEvent) => void) {
      const list = listeners.get(event) ?? [];
      list.push(handler);
      listeners.set(event, list);
    },
    click() {
      const ev: StubClickEvent = {
        preventDefault: () => {},
        stopPropagation: () => {},
      };
      for (const cb of listeners.get('click') ?? []) {
        cb(ev);
      }
    },
    querySelector(selector: string) {
      const all: StubElement[] = [];
      collectAll(el, all);
      return all.find((n) => matchesSimple(n, selector.trim())) ?? null;
    },
    querySelectorAll(selector: string) {
      const all: StubElement[] = [];
      collectAll(el, all);
      return all.filter((n) => matchesSimple(n, selector.trim()));
    },
    get outerHTML() {
      return `<${tag.toLowerCase()}></${tag.toLowerCase()}>`;
    },
    get innerHTML() {
      return innerHtmlVal;
    },
    set innerHTML(html: string) {
      innerHtmlVal = String(html);
      children.length = 0;
      const btn = createStubElement('button');
      btn.className = 'tachyon-lang-btn';
      const codeMatch = innerHtmlVal.match(
        /<span class="tachyon-lang-code">([^<]*)<\/span>/,
      );
      if (codeMatch) {
        const codeSpan = createStubElement('span');
        codeSpan.className = 'tachyon-lang-code';
        codeSpan.textContent = codeMatch[1];
        btn.appendChild(codeSpan);
      }
      children.push(btn);

      const menu = createStubElement('div');
      menu.className = 'tachyon-lang-menu';
      menu.hidden = /<div class="tachyon-lang-menu"[^>]*\bhidden\b/.test(
        innerHtmlVal,
      );
      const optMatches = innerHtmlVal.matchAll(
        /<button[^>]*class="tachyon-lang-option([^"]*)"[^>]*data-lang="([^"]+)"/g,
      );
      for (const m of optMatches) {
        const opt = createStubElement('button');
        opt.className = `tachyon-lang-option ${m[1] || ''}`;
        opt.setAttribute('data-lang', m[2]);
        menu.appendChild(opt);
      }
      children.push(menu);
    },
  };
  return el;
}

describe('languageSelector', () => {
  const g = globalThis as unknown as {
    _?: (s: string) => string;
    L?: { env?: { lang?: string } };
    document?: {
      documentElement: StubElement;
      createElement: (tag: string) => StubElement;
      createElementNS: (_ns: string, tag: string) => StubElement;
      addEventListener: (
        event: string,
        cb: (ev: StubClickEvent) => void,
      ) => void;
      querySelector: (sel: string) => StubElement | null;
      querySelectorAll: (sel: string) => StubElement[];
    };
    window?: {
      setTimeout: (cb: () => void, ms: number) => ReturnType<typeof setTimeout>;
    };
  };
  const origDocument = g.document;
  const origWindow = g.window;

  beforeEach(() => {
    vi.restoreAllMocks();
    g._ = (s: string) => s;
    delete g.L;
    const docEl = createStubElement('html');
    g.document = {
      documentElement: docEl,
      createElement: (tag: string) => createStubElement(tag),
      createElementNS: (_ns: string, tag: string) => createStubElement(tag),
      addEventListener: () => {},
      querySelector: () => null,
      querySelectorAll: () => [],
    };
    g.window = {
      setTimeout: (cb: () => void, ms: number) => globalThis.setTimeout(cb, ms),
    };
  });

  afterEach(() => {
    delete g.L;
    if (origDocument === undefined) delete g.document;
    else g.document = origDocument;
    if (origWindow === undefined) delete g.window;
    else g.window = origWindow;
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

  it('prefers explicit L.env.lang or document.documentElement.lang over auto', () => {
    (globalThis as unknown as { L?: { env?: { lang?: string } } }).L = {
      env: { lang: 'ru' },
    };
    expect(
      detectActiveLanguageCode({ i18nRuInstalled: true, luciLang: 'auto' }),
    ).toBe('ru');

    (globalThis as unknown as { L?: { env?: { lang?: string } } }).L = {
      env: { lang: 'en' },
    };
    (globalThis as unknown as { _: (s: string) => string })._ = (s: string) =>
      s === 'Settings' ? 'Настройки' : s;
    expect(
      detectActiveLanguageCode({ i18nRuInstalled: true, luciLang: 'auto' }),
    ).toBe('en');

    delete (globalThis as unknown as { L?: unknown }).L;
    document.documentElement.lang = 'ru';
    (globalThis as unknown as { _: (s: string) => string })._ = (s: string) =>
      s;
    expect(
      detectActiveLanguageCode({ i18nRuInstalled: true, luciLang: 'auto' }),
    ).toBe('ru');
  });

  it('keeps an open dropdown intact across remounts and calls set_language on click', async () => {
    const startMock = vi
      .mocked(TachyonShellMethods.componentActionStart)
      .mockResolvedValue({
        success: true,
        data: { job_id: 'job-1' },
      } as Awaited<
        ReturnType<typeof TachyonShellMethods.componentActionStart>
      >);
    const waitMock = vi
      .mocked(TachyonShellMethods.waitComponentActionJob)
      .mockResolvedValue({
        success: true,
        data: { success: true, message: 'ok' },
      } as Awaited<
        ReturnType<typeof TachyonShellMethods.waitComponentActionJob>
      >);

    const slot = document.createElement('div');
    mountLanguageSelector({ luciLang: 'en' }, slot);
    const selector = slot.querySelector(
      '.tachyon-lang-selector',
    ) as HTMLElement;
    const btn = slot.querySelector('.tachyon-lang-btn') as HTMLButtonElement;
    const menu = slot.querySelector('.tachyon-lang-menu') as HTMLElement;

    expect(btn.textContent).toContain('EN');
    btn.click();
    expect(selector.classList.contains('is-open')).toBe(true);
    expect(menu.hidden).toBe(false);

    // Remount while menu is open must preserve the open dropdown DOM
    mountLanguageSelector({ luciLang: 'en', i18nRuInstalled: true }, slot);
    expect(slot.querySelector('.tachyon-lang-selector')).toBe(selector);
    expect(selector.classList.contains('is-open')).toBe(true);
    expect(menu.hidden).toBe(false);

    const ruBtn = slot.querySelector(
      '.tachyon-lang-option[data-lang="ru"]',
    ) as HTMLButtonElement;
    ruBtn.click();
    await Promise.resolve();
    await Promise.resolve();

    expect(startMock).toHaveBeenCalledWith('tachyon', 'set_language', 'ru');
    expect(waitMock).toHaveBeenCalledWith('job-1', 'tachyon', 'set_language');
  });

  it('exposes extensible language registry starting with English and Russian', () => {
    expect(TACHYON_LANGUAGES.map((l) => l.code)).toEqual(['en', 'ru']);
    expect(TACHYON_LANGUAGES[0].requiresPackage).toBe(false);
    expect(TACHYON_LANGUAGES[1].requiresPackage).toBe(true);
    expect(TACHYON_LANGUAGES[0].flagSvg).toContain('<svg');
    expect(TACHYON_LANGUAGES[1].flagSvg).toContain('<svg');
  });
});
