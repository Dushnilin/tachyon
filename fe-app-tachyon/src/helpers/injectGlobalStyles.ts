import { GlobalStyles } from '../styles';
import {
  applyThemeToDocument,
  ensureAutoThemeWatcher,
  getActiveTheme,
  isBgAnimationEnabled,
} from '../tachyon/themes/themeCatalog';

const TACHYON_GLOBAL_STYLES_ID = 'tachyon-global-styles';

const TACHYON_BG_SVG = `
  <svg viewBox="0 0 1600 900" preserveAspectRatio="xMidYMid slice" fill="none" xmlns="http://www.w3.org/2000/svg">
    <g stroke="var(--bg-grid-stroke, rgba(255,255,255,0.028))" stroke-width="1">
      <path d="M-100 140 C 420 40, 1080 280, 1700 90"/>
      <path d="M-100 290 C 480 190, 1020 420, 1700 240"/>
      <path d="M-100 450 C 520 370, 1080 550, 1700 420"/>
      <path d="M-100 620 C 460 520, 1120 710, 1700 580"/>
      <path d="M-100 780 C 540 680, 1060 840, 1700 740"/>
      <path d="M 180 -60 C 420 320, 880 580, 1480 960"/>
      <path d="M 640 -60 C 820 300, 1180 560, 1680 880"/>
    </g>
    <g stroke-width="1.5" stroke-linecap="round">
      <path class="tachyon-stream" stroke="var(--accent, #0a84ff)" stroke-opacity="0.55" d="M-100 140 C 420 40, 1080 280, 1700 90"/>
      <path class="tachyon-stream s2" stroke="var(--text, #f5f5f7)" stroke-opacity="0.32" d="M-100 290 C 480 190, 1020 420, 1700 240"/>
      <path class="tachyon-stream s3" stroke="var(--accent, #0a84ff)" stroke-opacity="0.62" d="M-100 450 C 520 370, 1080 550, 1700 420"/>
      <path class="tachyon-stream s4" stroke="var(--accent-hover, #409cff)" stroke-opacity="0.45" d="M-100 620 C 460 520, 1120 710, 1700 580"/>
      <path class="tachyon-stream s5" stroke="var(--text, #f5f5f7)" stroke-opacity="0.28" d="M-100 780 C 540 680, 1060 840, 1700 740"/>
      <path class="tachyon-stream s2" stroke="var(--accent, #0a84ff)" stroke-opacity="0.4" d="M 180 -60 C 420 320, 880 580, 1480 960"/>
      <path class="tachyon-stream s4" stroke="var(--accent, #0a84ff)" stroke-opacity="0.35" d="M 640 -60 C 820 300, 1180 560, 1680 880"/>
    </g>
  </svg>
`;

export function injectGlobalStyles() {
  if (typeof document === 'undefined') {
    return;
  }

  try {
    ensureAutoThemeWatcher();
    const activeTheme = applyThemeToDocument(getActiveTheme(), false);
    if (activeTheme.scheme === 'light') {
      document.documentElement.setAttribute('data-darkmode', 'false');
      document.body?.classList?.remove('dark');
    } else {
      document.documentElement.setAttribute('data-darkmode', 'true');
      document.body?.classList?.add('dark');
    }
    const bgAnim = isBgAnimationEnabled();
    document.documentElement.setAttribute(
      'data-tachyon-bg-animation',
      bgAnim ? 'true' : 'false',
    );
  } catch {
    // ignore DOM attribute errors in headless test runners
  }

  if (!document.getElementById(TACHYON_GLOBAL_STYLES_ID)) {
    document.head.insertAdjacentHTML(
      'beforeend',
      `
        <style id="${TACHYON_GLOBAL_STYLES_ID}">
          ${GlobalStyles}
        </style>
      `,
    );
  }

  try {
    if (document.body && !document.querySelector('.tachyon-bg-layer')) {
      const bgLayer = document.createElement('div');
      bgLayer.className = 'tachyon-bg-layer';
      bgLayer.setAttribute('aria-hidden', 'true');
      bgLayer.innerHTML = TACHYON_BG_SVG;
      document.body.insertBefore(bgLayer, document.body.firstChild);
    }
  } catch {
    // ignore in minimal mock DOM environments
  }
}
