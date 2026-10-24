import { renderSections, renderWidget } from './partials';

export function render() {
  return E(
    'div',
    {
      id: 'dashboard-status',
      class: 'tachyon_dashboard-page',
    },
    [
      E('div', { class: 'tachyon_dashboard-page__content' }, [
        E('div', { class: 'tachyon_dashboard-page__widgets-section' }, [
          E('div', { id: 'dashboard-widget-system-services' }, [
            renderWidget({
              loading: true,
              failed: false,
              title: '',
              items: [],
            }),
          ]),
          E(
            'div',
            {
              id: 'dashboard-widgets-sections-list',
              style: 'display: contents;',
            },
            [
              renderWidget({
                loading: true,
                failed: false,
                title: '',
                items: [],
              }),
            ],
          ),
          E(
            'div',
            {
              id: 'dashboard-widget-inbounds',
              class: 'tachyon-inbounds-fullwidth-slot',
            },
            [],
          ),
          E(
            'div',
            { id: 'dashboard-widget-tailscale', style: 'display:none' },
            renderWidget({
              loading: true,
              failed: false,
              title: '',
              items: [],
            }),
          ),
        ]),
        E(
          'div',
          {
            class: 'tachyon_dashboard-page__service-stopped',
            role: 'status',
          },
          _(
            'Tachyon service is stopped. Start the service to display the dashboard.',
          ),
        ),
        E('div', { id: 'dashboard-connections-grid' }, []),
        E(
          'div',
          { id: 'dashboard-sections-grid' },
          renderSections({
            loading: true,
            failed: false,
            section: {
              code: '',
              sectionName: '',
              displayName: '',
              outbounds: [],
              withTagSelect: false,
            },
            onTestLatency: () => {},
            onChooseOutbound: () => {},
            onCopyOutbound: () => {},
            onShowUrlTestInfo: () => {},
            onShowPriorityInfo: () => {},
            onUpdateSubscription: () => {},
            latencyFetching: false,
            latencyProgress: undefined,
            subscriptionUpdating: false,
            selectorSwitchingTag: undefined,
          }),
        ),
      ]),
    ],
  );
}
