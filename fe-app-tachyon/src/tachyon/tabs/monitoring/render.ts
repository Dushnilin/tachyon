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
              'div',
              {
                id: 'monitoring-device-filter-wrap',
                class: 'tachyon_monitoring-page__multiselect',
              },
              [
                E(
                  'button',
                  {
                    id: 'monitoring-device-filter-trigger',
                    class:
                      'btn cbi-button tachyon_monitoring-page__multiselect-trigger',
                    type: 'button',
                  },
                  [
                    E(
                      'span',
                      {
                        id: 'monitoring-device-filter-label',
                        class: 'tachyon_monitoring-page__multiselect-label',
                      },
                      _('All sources'),
                    ),
                    E(
                      'span',
                      {
                        class: 'tachyon_monitoring-page__multiselect-caret',
                      },
                      '▾',
                    ),
                  ],
                ),
                E(
                  'div',
                  {
                    id: 'monitoring-device-filter-menu',
                    class: 'tachyon_monitoring-page__multiselect-menu',
                    hidden: true,
                  },
                  [],
                ),
              ],
            ),
            E(
              'div',
              {
                id: 'monitoring-route-filter-wrap',
                class: 'tachyon_monitoring-page__multiselect',
              },
              [
                E(
                  'button',
                  {
                    id: 'monitoring-route-filter-trigger',
                    class:
                      'btn cbi-button tachyon_monitoring-page__multiselect-trigger',
                    type: 'button',
                  },
                  [
                    E(
                      'span',
                      {
                        id: 'monitoring-route-filter-label',
                        class: 'tachyon_monitoring-page__multiselect-label',
                      },
                      _('All Routes'),
                    ),
                    E(
                      'span',
                      {
                        class: 'tachyon_monitoring-page__multiselect-caret',
                      },
                      '▾',
                    ),
                  ],
                ),
                E(
                  'div',
                  {
                    id: 'monitoring-route-filter-menu',
                    class: 'tachyon_monitoring-page__multiselect-menu',
                    hidden: true,
                  },
                  [],
                ),
              ],
            ),
            E(
              'div',
              {
                id: 'monitoring-network-filters',
                class: 'tachyon_monitoring-page__proto-group',
                'aria-label': _('Type'),
              },
              ['tcp', 'udp', 'quic'].map((proto) =>
                E(
                  'label',
                  {
                    class: `tachyon_monitoring-page__proto-chip tachyon_monitoring-page__proto-chip--${proto}`,
                  },
                  [
                    E('input', {
                      type: 'checkbox',
                      value: proto,
                      class: 'tachyon_monitoring-page__proto-checkbox',
                    }),
                    E(
                      'span',
                      { class: 'tachyon_monitoring-page__proto-text' },
                      proto.toUpperCase(),
                    ),
                  ],
                ),
              ),
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
            id: 'monitoring-quick-filters',
            class: 'tachyon_monitoring-page__quick-bar',
            hidden: true,
          },
          [],
        ),
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
