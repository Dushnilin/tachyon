import {
  computeAutoFullWidgetIds,
  DashboardWidgetId,
  getDashboardLayoutConfig,
} from './dashboardLayout';
import { renderSections, renderWidget } from './partials';

export function render() {
  const layoutCfg = getDashboardLayoutConfig();
  const autoFullIds = computeAutoFullWidgetIds(layoutCfg.widgets);
  const getSlotProps = (
    widgetId: DashboardWidgetId,
    baseId: string,
    baseClass: string,
  ) => {
    const placement = layoutCfg.widgets.find((w) => w.id === widgetId);
    const width = placement?.width === 'half' ? 'half' : 'full';
    const isAutoFull = autoFullIds.has(widgetId);
    const enabled = placement ? placement.enabled : true;
    const view = placement?.view || 'default';
    const idx = layoutCfg.widgets.findIndex((w) => w.id === widgetId);
    const order = idx >= 0 ? idx + 1 : 99;
    return {
      id: baseId,
      class: [
        baseClass,
        'tachyon-dashboard-widget-slot',
        width === 'half' && !isAutoFull
          ? 'tachyon-dashboard-widget-slot--half'
          : 'tachyon-dashboard-widget-slot--full',
        isAutoFull ? 'tachyon-dashboard-widget-slot--auto-full' : '',
        !enabled ? 'tachyon-dashboard-widget-slot--hidden' : '',
      ]
        .filter(Boolean)
        .join(' '),
      'data-widget-id': widgetId,
      'data-widget-view': view,
      'data-widget-width': width,
      style: `order: ${order};${!enabled ? ' display: none;' : ''}`,
    };
  };

  return E(
    'div',
    {
      id: 'dashboard-status',
      class: 'tachyon_dashboard-page',
    },
    [
      E(
        'div',
        {
          class: 'tachyon_dashboard-page__content',
          'data-dashboard-preset': layoutCfg.preset,
        },
        [
          E(
            'div',
            {
              class: 'tachyon_dashboard-page__service-stopped',
              role: 'status',
              style: 'order: 0; grid-column: 1 / -1;',
            },
            _(
              'Tachyon service is stopped. Start the service to display the dashboard.',
            ),
          ),

          // Widget 1: KPI Stat Cards / Strip / Stat Pills / Telemetry / Counters
          E(
            'div',
            getSlotProps('kpi', 'dashboard-kpi-row', 'tachyon-kpi-grid'),
            [],
          ),

          // Widget 2: Live Traffic Chart (Area / Bars / Gauges / Dual Telemetry)
          E(
            'div',
            getSlotProps(
              'traffic_chart',
              'dashboard-traffic-chart-card',
              'tachyon-traffic-chart-slot',
            ),
            [],
          ),

          // Widget 3: Routing & System Status (Card / 2x2 Tiles / Banner / Cockpit HUD)
          E(
            'div',
            getSlotProps(
              'system_status',
              'dashboard-widget-system-services',
              'tachyon-system-status-slot',
            ),
            [
              renderWidget({
                loading: true,
                failed: false,
                title: '',
                items: [],
              }),
            ],
          ),

          // Widget 4: Router Services (Strip / Cards / Minimal LEDs / Resource Bars)
          E(
            'div',
            getSlotProps(
              'router_services',
              'dashboard-router-services-strip',
              'tachyon-router-services-slot',
            ),
            [],
          ),

          // Widget 5: Inbound Servers (Collapsible / Expanded Cards / Compact Chips / Port Matrix)
          E(
            'div',
            getSlotProps(
              'inbounds',
              'dashboard-widget-inbounds',
              'tachyon-inbounds-fullwidth-slot',
            ),
            [],
          ),

          // Widget 6: Active Clients & Top Domains (Collapsible / Expanded / Domains Focus / Client Cards)
          E(
            'div',
            getSlotProps(
              'active_clients',
              'dashboard-connections-grid',
              'tachyon-connections-slot',
            ),
            [],
          ),

          // Widget 7: Routing Sections (Rows / Bento Cards / Compact Tiles / Protocol Matrix)
          E(
            'div',
            getSlotProps(
              'routing_sections',
              'dashboard-sections-grid',
              'tachyon-sections-slot',
            ),
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

          // Optional Tailscale status slot
          E(
            'div',
            {
              id: 'dashboard-widget-tailscale',
              class:
                'tachyon-dashboard-widget-slot tachyon-dashboard-widget-slot--full',
              style: 'display:none; order: 90;',
            },
            renderWidget({
              loading: true,
              failed: false,
              title: '',
              items: [],
            }),
          ),

          // Hidden legacy slot kept for unit-test compatibility
          E(
            'div',
            {
              id: 'dashboard-widgets-sections-list',
              style: 'display: none;',
            },
            [],
          ),
        ],
      ),
    ],
  );
}
