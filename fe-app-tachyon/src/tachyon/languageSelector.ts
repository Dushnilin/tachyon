import { TachyonShellMethods } from './methods/shell';
import { showToast } from '../helpers/showToast';
import { isTransientRpcError } from './helpers/isTransientRpcError';

export interface TachyonLanguageOption {
  code: string;
  label: string;
  nativeLabel: string;
  shortCode: string;
  requiresPackage: boolean;
  flagSvg: string;
}

export const TACHYON_LANGUAGES: TachyonLanguageOption[] = [
  {
    code: 'en',
    label: 'English',
    nativeLabel: 'English',
    shortCode: 'EN',
    requiresPackage: false,
    flagSvg: `<svg viewBox="0 0 60 30" width="20" height="14" aria-hidden="true" style="border-radius:2px;box-shadow:0 0 0 1px rgba(0,0,0,0.18);display:block;flex-shrink:0"><clipPath id="tachyon-uk-clip"><path d="M0,0 v30 h60 v-30 z"/></clipPath><clipPath id="tachyon-uk-diag"><path d="M30,15 h30 v15 z v15 h-30 z h-30 v-15 z v-15 h30 z"/></clipPath><g clip-path="url(#tachyon-uk-clip)"><path d="M0,0 v30 h60 v-30 z" fill="#012169"/><path d="M0,0 L60,30 M60,0 L0,30" stroke="#fff" stroke-width="6"/><path d="M0,0 L60,30 M60,0 L0,30" clip-path="url(#tachyon-uk-diag)" stroke="#C8102E" stroke-width="4"/><path d="M30,0 v30 M0,15 h60" stroke="#fff" stroke-width="10"/><path d="M30,0 v30 M0,15 h60" stroke="#C8102E" stroke-width="6"/></g></svg>`,
  },
  {
    code: 'ru',
    label: 'Russian',
    nativeLabel: 'Русский',
    shortCode: 'RU',
    requiresPackage: true,
    flagSvg: `<svg viewBox="0 0 60 40" width="20" height="14" aria-hidden="true" style="border-radius:2px;box-shadow:0 0 0 1px rgba(0,0,0,0.18);display:block;flex-shrink:0"><rect width="60" height="13.34" y="0" fill="#ffffff"/><rect width="60" height="13.34" y="13.33" fill="#0039a6"/><rect width="60" height="13.34" y="26.66" fill="#d52b1e"/></svg>`,
  },
];

export interface UiLanguageCapabilities {
  i18nRuInstalled?: boolean;
  luciLang?: string;
}

export function detectActiveLanguageCode(
  capabilities?: UiLanguageCapabilities,
): string {
  const globalObj = (
    typeof globalThis !== 'undefined'
      ? globalThis
      : typeof window !== 'undefined'
        ? window
        : {}
  ) as { L?: { env?: { lang?: string } } };
  const globalL = globalObj.L;
  const envLang =
    typeof globalL?.env?.lang === 'string'
      ? globalL.env.lang.trim().toLowerCase()
      : '';
  const luciLang = (capabilities?.luciLang || envLang || '')
    .trim()
    .toLowerCase();
  const ruInstalled = capabilities?.i18nRuInstalled !== false;

  if (luciLang === 'en') {
    return 'en';
  }
  if (luciLang === 'ru' && ruInstalled) {
    return 'ru';
  }

  try {
    const probed = typeof _ === 'function' ? _('Settings') : 'Settings';
    if (probed && probed !== 'Settings') {
      return 'ru';
    }
  } catch {
    // Fallback to English
  }

  return 'en';
}

let outsideClickBound = false;

export function mountLanguageSelector(
  capabilities?: UiLanguageCapabilities,
): void {
  if (typeof document === 'undefined') return;

  const mapHeader =
    document.querySelector<HTMLElement>('#cbi-tachyon > h2') ||
    document.querySelector<HTMLElement>('.cbi-map > h2');
  if (!mapHeader) return;

  mapHeader.classList.add('tachyon-map-header');

  let wrapper = mapHeader.querySelector<HTMLElement>('.tachyon-lang-selector');
  if (!wrapper) {
    wrapper = document.createElement('div');
    wrapper.className = 'tachyon-lang-selector';
    mapHeader.appendChild(wrapper);
  }

  const activeCode = detectActiveLanguageCode(capabilities);
  const activeOption =
    TACHYON_LANGUAGES.find((item) => item.code === activeCode) ||
    TACHYON_LANGUAGES[0];
  const ruInstalled = Boolean(capabilities?.i18nRuInstalled);

  wrapper.innerHTML = `
    <button type="button" class="tachyon-lang-btn" title="${_('Change interface language')}" aria-haspopup="listbox" aria-expanded="false">
      <span class="tachyon-lang-flag">${activeOption.flagSvg}</span>
      <span class="tachyon-lang-code">${activeOption.shortCode}</span>
      <span class="tachyon-lang-caret">▾</span>
    </button>
    <div class="tachyon-lang-menu" role="listbox" hidden>
      <div class="tachyon-lang-menu__header">${_('Interface language')}</div>
      ${TACHYON_LANGUAGES.map((lang) => {
        const isCurrent = lang.code === activeOption.code;
        const needsInstall =
          lang.code === 'ru' && lang.requiresPackage && !ruInstalled;
        const badgeText = isCurrent ? '✓' : needsInstall ? _('Install') : '';
        const badgeClass = isCurrent
          ? 'tachyon-lang-option__badge--active'
          : needsInstall
            ? 'tachyon-lang-option__badge--install'
            : '';
        return `
          <button type="button" class="tachyon-lang-option ${isCurrent ? 'is-active' : ''}" data-lang="${lang.code}" role="option" aria-selected="${isCurrent}">
            <span class="tachyon-lang-flag">${lang.flagSvg}</span>
            <span class="tachyon-lang-option__text">
              <span class="tachyon-lang-option__native">${lang.nativeLabel}</span>
              <span class="tachyon-lang-option__sub">${lang.label}</span>
            </span>
            ${badgeText ? `<span class="tachyon-lang-option__badge ${badgeClass}">${badgeText}</span>` : ''}
          </button>
        `;
      }).join('')}
    </div>
  `;

  const btn = wrapper.querySelector<HTMLButtonElement>('.tachyon-lang-btn');
  const menu = wrapper.querySelector<HTMLElement>('.tachyon-lang-menu');
  if (!btn || !menu) return;

  const closeMenu = () => {
    menu.hidden = true;
    btn.setAttribute('aria-expanded', 'false');
    wrapper?.classList.remove('is-open');
  };

  btn.addEventListener('click', (ev) => {
    ev.stopPropagation();
    const willOpen = menu.hidden;
    menu.hidden = !willOpen;
    btn.setAttribute('aria-expanded', willOpen ? 'true' : 'false');
    wrapper?.classList.toggle('is-open', willOpen);
  });

  menu
    .querySelectorAll<HTMLButtonElement>('.tachyon-lang-option')
    .forEach((optBtn) => {
      optBtn.addEventListener('click', async (ev) => {
        ev.stopPropagation();
        const targetLang = optBtn.getAttribute('data-lang') || 'en';
        const targetOption = TACHYON_LANGUAGES.find(
          (item) => item.code === targetLang,
        );
        closeMenu();

        if (!targetOption) return;
        const needsInstall =
          targetOption.code === 'ru' &&
          targetOption.requiresPackage &&
          !ruInstalled;

        if (targetOption.code === activeOption.code && !needsInstall) {
          return;
        }

        btn.disabled = true;
        btn.classList.add('is-loading');
        const codeSpan = btn.querySelector<HTMLElement>('.tachyon-lang-code');
        if (codeSpan) {
          codeSpan.textContent = '...';
        }

        showToast(
          needsInstall
            ? _('Installing language pack and switching language...')
            : _('Switching interface language...'),
          'success',
        );

        try {
          const started = await TachyonShellMethods.componentActionStart(
            'tachyon',
            'set_language',
            targetOption.code,
          );
          if (!started.success) {
            throw new Error(started.error || _('Failed to change language'));
          }

          const finished = await TachyonShellMethods.waitComponentActionJob(
            started.data.job_id,
            'tachyon',
            'set_language',
          );
          if (!finished.success || !finished.data.success) {
            const errMsg = !finished.success
              ? finished.error
              : finished.data.message;
            if (!isTransientRpcError(errMsg)) {
              throw new Error(errMsg || _('Failed to change language'));
            }
          }

          showToast(_('Language updated. Reloading page...'), 'success');
          window.setTimeout(() => {
            window.location.reload();
          }, 400);
        } catch (err) {
          const msg =
            err instanceof Error ? err.message : _('Failed to change language');
          if (isTransientRpcError(msg)) {
            showToast(_('Language updated. Reloading page...'), 'success');
            window.setTimeout(() => {
              window.location.reload();
            }, 600);
            return;
          }
          btn.disabled = false;
          btn.classList.remove('is-loading');
          if (codeSpan) {
            codeSpan.textContent = activeOption.shortCode;
          }
          showToast(msg, 'error');
        }
      });
    });

  if (!outsideClickBound) {
    outsideClickBound = true;
    document.addEventListener('click', () => {
      document
        .querySelectorAll<HTMLElement>('.tachyon-lang-selector.is-open')
        .forEach((el) => {
          el.classList.remove('is-open');
          const m = el.querySelector<HTMLElement>('.tachyon-lang-menu');
          const b = el.querySelector<HTMLButtonElement>('.tachyon-lang-btn');
          if (m) m.hidden = true;
          if (b) b.setAttribute('aria-expanded', 'false');
        });
    });
  }
}
