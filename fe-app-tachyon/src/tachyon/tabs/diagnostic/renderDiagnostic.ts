import { renderActivityIcon } from '../../../icons';
import { tr } from '../../helpers/i18n';

export function render() {
  return E(
    'div',
    { id: 'diagnostic-status', class: 'tachyon_diagnostic-root' },
    [
      // 1. GPUI-Kit System Node Telemetry Strip (100% Width)
      E('div', {
        id: 'tachyon_diagnostic-page-system-info',
        class: 'tachyon_diagnostic-system-strip',
      }),

      // 2. Live Tachyon-Core 3-Pane Deep Telemetry Workbench
      E('div', {
        id: 'tachyon_diagnostic-page-core-telemetry',
        class: 'tachyon_diagnostic-core-telemetry-mount',
      }),

      // 3. Dual-Pane GPUI-Kit Inspector & Operations Dock
      E('div', { class: 'tachyon_diagnostic-page' }, [
        E('section', { class: 'tachyon_diagnostic-page__left-bar' }, [
          E('header', { class: 'tachyon_diagnostic-page__left-bar__header' }, [
            E(
              'div',
              { class: 'tachyon_diagnostic-page__left-bar__header-titles' },
              [
                E(
                  'b',
                  {
                    class: 'tachyon_diagnostic-page__left-bar__title',
                  },
                  [renderActivityIcon(14), _('System Health & Subsystems')],
                ),
                E(
                  'span',
                  {
                    id: 'tachyon_diagnostic-page-subtitle',
                    class: 'tachyon_diagnostic-page__left-bar__subtitle',
                  },
                  tr(
                    'DNS · TPROXY · Nftables · FakeIP · Маршруты',
                    'DNS · TPROXY · Nftables · FakeIP · Outbounds',
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
        E('section', { class: 'tachyon_diagnostic-page__right-bar' }, [
          E('div', { id: 'tachyon_diagnostic-page-actions' }),
          E('div', { id: 'tachyon_diagnostic-page-wiki' }),
        ]),
      ]),
    ],
  );
}
