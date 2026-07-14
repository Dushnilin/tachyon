import { GlobalStyles } from '../styles';

const TACHYON_GLOBAL_STYLES_ID = 'tachyon-global-styles';

export function injectGlobalStyles() {
  if (document.getElementById(TACHYON_GLOBAL_STYLES_ID)) {
    return;
  }

  document.head.insertAdjacentHTML(
    'beforeend',
    `
        <style id="${TACHYON_GLOBAL_STYLES_ID}">
          ${GlobalStyles}
        </style>
    `,
  );
}
