export function render() {
  return E(
    'div',
    {
      id: 'monitoring-status',
      class: 'tachyon_monitoring-page',
    },
    [
      E('div', { class: 'tachyon_monitoring-page__panel' }, [
        E('div', { class: 'tachyon_monitoring-page__controls' }, [
          E('div', { class: 'tachyon_monitoring-page__tabs' }, [
            E(
              'button',
              {
                id: 'monitoring-tab-active',
                class:
                  'btn cbi-button tachyon_monitoring-page__tab tachyon_monitoring-page__tab--active',
                type: 'button',
              },
              `${_('Active')} 0`,
            ),
            E(
              'button',
              {
                id: 'monitoring-tab-closed',
                class: 'btn cbi-button tachyon_monitoring-page__tab',
                type: 'button',
              },
              `${_('Closed')} 0`,
            ),
          ]),
          E('div', { class: 'tachyon_monitoring-page__filters' }, [
            E(
              'select',
              {
                id: 'monitoring-device-filter',
                class:
                  'cbi-input-select tachyon_monitoring-page__device-filter',
              },
              [E('option', { value: 'all' }, _('All'))],
            ),
            E(
              'select',
              {
                id: 'monitoring-route-filter',
                class:
                  'cbi-input-select tachyon_monitoring-page__device-filter tachyon_monitoring-page__route-filter',
              },
              [E('option', { value: 'all' }, _('All Routes'))],
            ),
            E('label', { class: 'tachyon_monitoring-page__search' }, [
              E('span', { class: 'tachyon_monitoring-page__search-icon' }, []),
              E('input', {
                id: 'monitoring-search',
                class: 'cbi-input-text tachyon_monitoring-page__search-input',
                type: 'search',
                placeholder: _('Search'),
                autocomplete: 'off',
              }),
            ]),
          ]),
          E('div', { class: 'tachyon_monitoring-page__actions' }, [
            E(
              'button',
              {
                id: 'monitoring-close-all',
                class: 'btn cbi-button tachyon_monitoring-page__icon-button',
                title: _('Close all connections'),
                'aria-label': _('Close all connections'),
                type: 'button',
                disabled: true,
              },
              [],
            ),
            E(
              'button',
              {
                id: 'monitoring-pause-toggle',
                class: 'btn cbi-button tachyon_monitoring-page__icon-button',
                title: _('Pause updates'),
                'aria-label': _('Pause updates'),
                type: 'button',
              },
              [],
            ),
          ]),
        ]),
        E(
          'div',
          {
            id: 'monitoring-connections',
            class: 'tachyon_monitoring-page__body',
          },
          [
            E(
              'div',
              {
                class:
                  'tachyon_monitoring-page__state tachyon_monitoring-page__state--loading',
              },
              _('Loading connections'),
            ),
          ],
        ),
      ]),
    ],
  );
}
