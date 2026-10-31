import { renderActivityIcon } from '../../../icons';

export function render() {
  return E(
    'div',
    { id: 'diagnostic-status', class: 'tachyon_diagnostic-root' },
    [
      // Top Bento Telemetry Strip
      E('div', {
        id: 'tachyon_diagnostic-page-system-info',
        class: 'tachyon_diagnostic-system-strip',
      }),

      // Main Dual-Column Bento Layout
      E('div', { class: 'tachyon_diagnostic-page' }, [
        E('div', { class: 'tachyon_diagnostic-page__left-bar' }, [
          E('div', { class: 'tachyon_diagnostic-page__left-bar__header' }, [
            E(
              'div',
              { class: 'tachyon_diagnostic-page__left-bar__header-titles' },
              [
                E(
                  'b',
                  {
                    class: 'tachyon_diagnostic-page__left-bar__title',
                    style: 'display:inline-flex;align-items:center;gap:7px;',
                  },
                  [renderActivityIcon(16), _('System Health & Subsystems')],
                ),
                E(
                  'span',
                  { class: 'tachyon_diagnostic-page__left-bar__subtitle' },
                  _(
                    'Automated verification of DNS, routing rules, firewall and DPI bypass engines',
                  ),
                ),
              ],
            ),
            E('div', { id: 'tachyon_diagnostic-page-run-check' }),
          ]),
          E('div', {
            class: 'tachyon_diagnostic-page__checks',
            id: 'tachyon_diagnostic-page-checks',
          }),
        ]),
        E('div', { class: 'tachyon_diagnostic-page__right-bar' }, [
          E('div', { id: 'tachyon_diagnostic-page-actions' }),
          E('div', { id: 'tachyon_diagnostic-page-wiki' }),
        ]),
      ]),
    ],
  );
}
