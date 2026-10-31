/* eslint-disable @typescript-eslint/no-explicit-any */
import { svgEl } from '../../../../helpers';
import { prettyBytes } from '../../../../helpers/prettyBytes';
import {
  renderCheckIcon,
  renderCloudIcon,
  renderCompassIcon,
  renderInfoIcon24,
  renderLoaderCircleIcon24,
  renderLockIcon,
  renderSettingsIcon,
  renderShieldIcon,
  renderSparklesIcon,
  renderZapIcon,
} from '../../../../icons';
import { tr } from '../../../helpers/i18n';
import { Tachyon } from '../../../types';
import { getProxyUrlTransport } from '../../../../helpers/getProxyUrlTransport';
import { ensureOutboundDisplayFlag } from '../../../helpers/country';
import { formatServiceStatusMessage } from '../../../helpers/formatServiceStatusMessage';
import { getWidgetViewMode } from '../dashboardLayout';
import { renderFlagEmojis } from './renderFlagEmojis';

export interface KpiRowMetrics {
  activeClients: number;
  activeConnections: number;
  activeSections: number;
  downloadTotal: number;
  uploadTotal: number;
  downSpeed: number;
  upSpeed: number;
  avgLatencyMs: number;
  isLiteMode: boolean;
  clientsHistory: number[];
  sectionsHistory: number[];
  trafficHistory: number[];
  latencyHistory: number[];
}

export interface TrafficHistoryPoint {
  ts: number;
  down: number;
  up: number;
}

function buildMiniSparklineSvg(
  values: number[],
  strokeVar: string,
  uid: string,
): SVGElement {
  const pts =
    values.length >= 2
      ? values.slice(-20)
      : [0, values[0] || 1, values[0] || 1];
  const maxVal = Math.max(...pts, 1);
  const minVal = Math.min(...pts, 0);
  const span = Math.max(maxVal - minVal, 1);
  const w = 54;
  const h = 22;

  const coords = pts.map((v, i) => {
    const x = (i / Math.max(pts.length - 1, 1)) * w;
    const y = h - 3 - ((v - minVal) / span) * (h - 6);
    return `${x.toFixed(1)},${y.toFixed(1)}`;
  });

  const linePath = `M ${coords.join(' L ')}`;
  const areaPath = `${linePath} L ${w},${h} L 0,${h} Z`;

  return svgEl(
    'svg',
    {
      viewBox: `0 0 ${w} ${h}`,
      width: String(w),
      height: String(h),
      class: 'tachyon-kpi-card__spark',
      'aria-hidden': 'true',
    },
    [
      svgEl('defs', {}, [
        svgEl(
          'linearGradient',
          { id: `kpi-grad-${uid}`, x1: '0%', y1: '0%', x2: '0%', y2: '100%' },
          [
            svgEl('stop', {
              offset: '0%',
              'stop-color': strokeVar,
              'stop-opacity': '0.32',
            }),
            svgEl('stop', {
              offset: '100%',
              'stop-color': strokeVar,
              'stop-opacity': '0.0',
            }),
          ],
        ),
      ]),
      svgEl('path', {
        d: areaPath,
        fill: `url(#kpi-grad-${uid})`,
      }),
      svgEl('path', {
        d: linePath,
        fill: 'none',
        stroke: strokeVar,
        'stroke-width': '2',
        'stroke-linecap': 'round',
        'stroke-linejoin': 'round',
      }),
    ],
  );
}

export function renderKpiRow(
  metrics: KpiRowMetrics,
  viewOverride?: string,
): HTMLElement[] {
  const viewMode = viewOverride || getWidgetViewMode('kpi') || 'cards';
  const totalTraffic =
    (metrics.downloadTotal || 0) + (metrics.uploadTotal || 0);
  const totalSpeed = (metrics.downSpeed || 0) + (metrics.upSpeed || 0);

  const cards = [
    {
      id: 'clients',
      title: tr('Клиенты', 'Clients'),
      value: String(metrics.activeClients),
      sub: `${metrics.activeConnections} ${tr('соединений', 'connections')}`,
      color: '#9482e0',
      history: metrics.clientsHistory,
      icon: [
        svgEl('path', { d: 'M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2' }),
        svgEl('circle', { cx: '9', cy: '7', r: '4' }),
        svgEl('path', { d: 'M22 21v-2a4 4 0 0 0-3-3.87' }),
        svgEl('path', { d: 'M16 3.13a4 4 0 0 1 0 7.75' }),
      ],
    },
    {
      id: 'routes',
      title: tr('Маршруты', 'Routes'),
      value: String(metrics.activeSections),
      sub: metrics.isLiteMode
        ? tr('Эко-режим Lite', 'Lite Eco Mode')
        : tr('— стабильно (TProxy)', '— stable (TProxy)'),
      color: '#9482e0',
      history: metrics.sectionsHistory,
      icon: [
        svgEl('circle', { cx: '6', cy: '19', r: '3' }),
        svgEl('path', {
          d: 'M9 19h8.5a3.5 3.5 0 0 0 0-7h-11a3.5 3.5 0 0 1 0-7H15',
        }),
        svgEl('circle', { cx: '18', cy: '5', r: '3' }),
      ],
    },
    {
      id: 'traffic',
      title: tr('Трафик сессии', 'Session Traffic'),
      value: prettyBytes(totalTraffic),
      sub:
        totalSpeed > 0
          ? `↓ ${prettyBytes(metrics.downSpeed)}/s • ↑ ${prettyBytes(metrics.upSpeed)}/s`
          : `↓ ${prettyBytes(metrics.downloadTotal || 0)} • ↑ ${prettyBytes(metrics.uploadTotal || 0)}`,
      color: '#9482e0',
      history: metrics.trafficHistory,
      icon: [
        svgEl('rect', { x: '2', y: '3', width: '20', height: '7', rx: '2' }),
        svgEl('rect', { x: '2', y: '14', width: '20', height: '7', rx: '2' }),
        svgEl('line', { x1: '6', y1: '6.5', x2: '6.01', y2: '6.5' }),
        svgEl('line', { x1: '6', y1: '17.5', x2: '6.01', y2: '17.5' }),
      ],
    },
    {
      id: 'latency',
      title: tr('Задержка', 'Latency'),
      value: metrics.avgLatencyMs > 0 ? `${metrics.avgLatencyMs} ms` : '—',
      sub:
        metrics.avgLatencyMs > 0
          ? metrics.avgLatencyMs <= 120
            ? tr('● Отличный отклик', '● Excellent response')
            : metrics.avgLatencyMs <= 250
              ? tr('● Нормальный отклик', '● Good response')
              : tr('● Высокий пинг', '● High latency')
          : tr('Ожидание замера', 'Awaiting measurement'),
      color:
        metrics.avgLatencyMs > 0 && metrics.avgLatencyMs > 250
          ? '#d97706'
          : '#9482e0',
      history: metrics.latencyHistory,
      icon: [
        svgEl('circle', { cx: '12', cy: '12', r: '10' }),
        svgEl('polyline', { points: '12 6 12 12 16 14' }),
      ],
    },
  ];

  if (viewMode === 'compact_strip') {
    const stripEl = E(
      'div',
      {
        class: 'tachyon-kpi-strip',
        'data-kpi-view': 'compact_strip',
      } as Record<string, unknown>,
      cards.map((c) =>
        E('div', { class: 'tachyon-kpi-strip__item', 'data-kpi': c.id }, [
          E('div', { class: 'tachyon-kpi-strip__icon' }, [
            svgEl(
              'svg',
              {
                viewBox: '0 0 24 24',
                width: '15',
                height: '15',
                fill: 'none',
                stroke: c.color,
                'stroke-width': '2',
                'stroke-linecap': 'round',
                'stroke-linejoin': 'round',
              },
              c.icon,
            ),
          ]),
          E('div', { class: 'tachyon-kpi-strip__content' }, [
            E('div', { class: 'tachyon-kpi-strip__head' }, [
              E('span', { class: 'tachyon-kpi-strip__label' }, c.title),
              E('strong', { class: 'tachyon-kpi-strip__val' }, c.value),
            ]),
            E('div', { class: 'tachyon-kpi-strip__sub' }, c.sub),
          ]),
        ]),
      ),
    );
    return [stripEl];
  }

  if (viewMode === 'glass_telemetry') {
    const ratios: Record<string, number> = {
      clients: Math.min(100, Math.max(8, metrics.activeClients * 12)),
      routes: Math.min(100, Math.max(15, metrics.activeSections * 18)),
      traffic: Math.min(
        100,
        Math.max(
          10,
          Math.round(
            (((metrics.downSpeed || 0) + (metrics.upSpeed || 0)) /
              (1024 * 1024 * 10)) *
              100,
          ),
        ),
      ),
      latency:
        metrics.avgLatencyMs <= 0
          ? 20
          : Math.min(
              100,
              Math.max(12, 100 - Math.round(metrics.avgLatencyMs / 5)),
            ),
    };
    return cards.map((c) => {
      const pct = ratios[c.id] ?? 50;
      return E(
        'div',
        {
          class: 'tachyon-kpi-card tachyon-kpi-card--telemetry',
          'data-kpi': c.id,
          'data-kpi-view': 'glass_telemetry',
        } as Record<string, unknown>,
        [
          E('div', { class: 'tachyon-kpi-telemetry__top' }, [
            E('span', { class: 'tachyon-kpi-telemetry__label' }, c.title),
            E('span', {
              class: 'tachyon-kpi-telemetry__pulse',
              style: `background: ${c.color}; box-shadow: 0 0 8px ${c.color};`,
            }),
          ]),
          E('div', { class: 'tachyon-kpi-telemetry__val' }, c.value),
          E('div', { class: 'tachyon-kpi-telemetry__bar' }, [
            E('div', {
              class: 'tachyon-kpi-telemetry__bar-fill',
              style: `width: ${pct}%; background: ${c.color};`,
            }),
          ]),
          E('div', { class: 'tachyon-kpi-telemetry__sub' }, c.sub),
        ],
      );
    });
  }

  if (viewMode === 'minimal_counters') {
    const stripEl = E(
      'div',
      {
        class: 'tachyon-kpi-minimal-counters',
        'data-kpi-view': 'minimal_counters',
      } as Record<string, unknown>,
      cards.map((c) =>
        E(
          'div',
          { class: 'tachyon-kpi-minimal-counters__item', 'data-kpi': c.id },
          [
            E(
              'span',
              { class: 'tachyon-kpi-minimal-counters__label' },
              c.title,
            ),
            E(
              'strong',
              {
                class: 'tachyon-kpi-minimal-counters__val',
                style: `color: ${c.color};`,
              },
              c.value,
            ),
            E('span', { class: 'tachyon-kpi-minimal-counters__sub' }, c.sub),
          ],
        ),
      ),
    );
    return [stripEl];
  }

  if (viewMode === 'stat_pills') {
    return cards.map((c) =>
      E(
        'div',
        {
          class: 'tachyon-kpi-card tachyon-kpi-card--stat-pill',
          'data-kpi': c.id,
          'data-kpi-view': 'stat_pills',
        } as Record<string, unknown>,
        [
          E('div', {
            class: 'tachyon-kpi-stat-pill__accent',
            style: `background: ${c.color};`,
          }),
          E('div', { class: 'tachyon-kpi-stat-pill__body' }, [
            E('div', { class: 'tachyon-kpi-stat-pill__head' }, [
              E('span', { class: 'tachyon-kpi-card__title' }, c.title),
              svgEl(
                'svg',
                {
                  viewBox: '0 0 24 24',
                  width: '16',
                  height: '16',
                  fill: 'none',
                  stroke: c.color,
                  'stroke-width': '2',
                  'stroke-linecap': 'round',
                  'stroke-linejoin': 'round',
                },
                c.icon,
              ),
            ]),
            E('div', { class: 'tachyon-kpi-stat-pill__value' }, c.value),
            E('div', { class: 'tachyon-kpi-card__sub' }, c.sub),
          ]),
        ],
      ),
    );
  }

  return cards.map((c) =>
    E(
      'div',
      { class: 'tachyon-kpi-card', 'data-kpi': c.id } as Record<
        string,
        unknown
      >,
      [
        E('div', { class: 'tachyon-kpi-card__top' }, [
          E('div', { class: 'tachyon-kpi-card__icon-ring' }, [
            svgEl(
              'svg',
              {
                viewBox: '0 0 24 24',
                width: '15',
                height: '15',
                fill: 'none',
                stroke: c.color,
                'stroke-width': '2',
                'stroke-linecap': 'round',
                'stroke-linejoin': 'round',
              },
              c.icon,
            ),
          ]),
          E(
            'div',
            { class: 'tachyon-kpi-card__title', title: c.title },
            c.title,
          ),
        ]),
        E('div', { class: 'tachyon-kpi-card__mid' }, [
          E('div', { class: 'tachyon-kpi-card__value' }, c.value),
          buildMiniSparklineSvg(c.history, c.color, c.id),
        ]),
        E('div', { class: 'tachyon-kpi-card__sub', title: c.sub }, c.sub),
      ],
    ),
  );
}

export function renderTrafficChartCard(
  history: TrafficHistoryPoint[],
  currentDown: number,
  currentUp: number,
  viewOverride?: string,
): HTMLElement {
  const viewMode = viewOverride || getWidgetViewMode('traffic_chart') || 'area';
  const pts =
    history.length >= 2
      ? history.slice(-30)
      : [
          { ts: Date.now() - 3000, down: 0, up: 0 },
          { ts: Date.now(), down: currentDown, up: currentUp },
        ];

  const peakDown = Math.max(...pts.map((p) => p.down), currentDown, 0);
  const peakUp = Math.max(...pts.map((p) => p.up), currentUp, 0);
  const maxSpeed = Math.max(peakDown, peakUp, 1024 * 64);

  const headerLegend = E(
    'div',
    { class: 'tachyon-traffic-chart-card__header' },
    [
      E(
        'span',
        { class: 'tachyon-dual-card__title-text' },
        tr('График трафика', 'Traffic Graph'),
      ),
      E('div', { class: 'tachyon-traffic-chart-card__legend' }, [
        E('span', { class: 'tachyon-traffic-chart-card__legend-item' }, [
          E('span', {
            class: 'tachyon-traffic-chart-card__dot',
            style: 'background: #9482e0;',
          }),
          E(
            'span',
            {},
            `${tr('Входящий', 'Downlink')}: ${prettyBytes(currentDown)}/s`,
          ),
        ]),
        E('span', { class: 'tachyon-traffic-chart-card__legend-item' }, [
          E('span', {
            class: 'tachyon-traffic-chart-card__dot',
            style: 'background: #64748b;',
          }),
          E(
            'span',
            {},
            `${tr('Исходящий', 'Uplink')}: ${prettyBytes(currentUp)}/s`,
          ),
        ]),
      ]),
    ],
  );

  if (viewMode === 'dual_telemetry') {
    const dlSpark = buildMiniSparklineSvg(
      pts.map((p) => p.down),
      '#9482e0',
      'dl_tele',
    );
    const ulSpark = buildMiniSparklineSvg(
      pts.map((p) => p.up),
      '#64748b',
      'ul_tele',
    );
    return E(
      'div',
      {
        class:
          'tachyon_dashboard-page__widgets-section__item tachyon-traffic-chart-card tachyon-traffic-chart-card--dual-telemetry',
        'data-chart-view': 'dual_telemetry',
      },
      [
        headerLegend,
        E('div', { class: 'tachyon-traffic-dual-grid' }, [
          E('div', { class: 'tachyon-traffic-dual-box is-down' }, [
            E('div', { class: 'tachyon-traffic-dual-box__head' }, [
              E(
                'span',
                { class: 'tachyon-traffic-dual-box__tag is-down' },
                `↓ ${tr('ПРИЁМ (RX)', 'DOWNLINK (RX)')}`,
              ),
              dlSpark,
            ]),
            E(
              'div',
              { class: 'tachyon-traffic-dual-box__value is-down' },
              `${prettyBytes(currentDown)}/s`,
            ),
            E(
              'div',
              { class: 'tachyon-traffic-dual-box__sub' },
              `${tr('Пик сессии', 'Session peak')}: ${prettyBytes(peakDown)}/s`,
            ),
          ]),
          E('div', { class: 'tachyon-traffic-dual-box is-up' }, [
            E('div', { class: 'tachyon-traffic-dual-box__head' }, [
              E(
                'span',
                { class: 'tachyon-traffic-dual-box__tag is-up' },
                `↑ ${tr('ОТДАЧА (TX)', 'UPLINK (TX)')}`,
              ),
              ulSpark,
            ]),
            E(
              'div',
              { class: 'tachyon-traffic-dual-box__value is-up' },
              `${prettyBytes(currentUp)}/s`,
            ),
            E(
              'div',
              { class: 'tachyon-traffic-dual-box__sub' },
              `${tr('Пик сессии', 'Session peak')}: ${prettyBytes(peakUp)}/s`,
            ),
          ]),
        ]),
      ],
    );
  }

  if (viewMode === 'gauges') {
    const dlRatio = Math.min(100, Math.round((currentDown / maxSpeed) * 100));
    const ulRatio = Math.min(100, Math.round((currentUp / maxSpeed) * 100));

    return E(
      'div',
      {
        class:
          'tachyon_dashboard-page__widgets-section__item tachyon-traffic-chart-card tachyon-traffic-chart-card--gauges',
        'data-chart-view': 'gauges',
      },
      [
        headerLegend,
        E('div', { class: 'tachyon-traffic-gauges' }, [
          E('div', { class: 'tachyon-traffic-gauge-box' }, [
            E('div', { class: 'tachyon-traffic-gauge-box__top' }, [
              E(
                'span',
                { class: 'tachyon-traffic-gauge-box__label' },
                `↓ ${tr('Входящий поток (Downlink)', 'Downlink Stream')}`,
              ),
              E(
                'strong',
                { class: 'tachyon-traffic-gauge-box__val is-down' },
                `${prettyBytes(currentDown)}/s`,
              ),
            ]),
            E('div', { class: 'tachyon-traffic-gauge-bar' }, [
              E('div', {
                class: 'tachyon-traffic-gauge-bar__fill is-down',
                style: `width: ${Math.max(dlRatio, currentDown > 0 ? 4 : 0)}%;`,
              }),
            ]),
            E(
              'div',
              { class: 'tachyon-traffic-gauge-box__foot' },
              `${tr('Пик за сессию', 'Session peak')}: ${prettyBytes(peakDown)}/s`,
            ),
          ]),
          E('div', { class: 'tachyon-traffic-gauge-box' }, [
            E('div', { class: 'tachyon-traffic-gauge-box__top' }, [
              E(
                'span',
                { class: 'tachyon-traffic-gauge-box__label' },
                `↑ ${tr('Исходящий поток (Uplink)', 'Uplink Stream')}`,
              ),
              E(
                'strong',
                { class: 'tachyon-traffic-gauge-box__val is-up' },
                `${prettyBytes(currentUp)}/s`,
              ),
            ]),
            E('div', { class: 'tachyon-traffic-gauge-bar' }, [
              E('div', {
                class: 'tachyon-traffic-gauge-bar__fill is-up',
                style: `width: ${Math.max(ulRatio, currentUp > 0 ? 4 : 0)}%;`,
              }),
            ]),
            E(
              'div',
              { class: 'tachyon-traffic-gauge-box__foot' },
              `${tr('Пик за сессию', 'Session peak')}: ${prettyBytes(peakUp)}/s`,
            ),
          ]),
        ]),
      ],
    );
  }

  const w = 600;
  const h = 150;
  const padLeft = 8;
  const padRight = 8;
  const padTop = 12;
  const padBottom = 18;
  const plotW = w - padLeft - padRight;
  const plotH = h - padTop - padBottom;

  if (viewMode === 'bars') {
    const barSamples = pts.slice(-24);
    const slotW = plotW / Math.max(barSamples.length, 1);
    const barW = Math.max(4, Math.min(12, slotW * 0.38));

    const barNodes: SVGElement[] = [];
    barSamples.forEach((p, idx) => {
      const baseX = padLeft + idx * slotW + (slotW - barW * 2 - 2) / 2;
      const dlH = Math.max(2, Math.min(plotH, (p.down / maxSpeed) * plotH));
      const ulH = Math.max(2, Math.min(plotH, (p.up / maxSpeed) * plotH));

      barNodes.push(
        svgEl('rect', {
          x: baseX.toFixed(1),
          y: (padTop + plotH - dlH).toFixed(1),
          width: barW.toFixed(1),
          height: dlH.toFixed(1),
          rx: '2',
          fill: '#9482e0',
          opacity: '0.88',
        }),
        svgEl('rect', {
          x: (baseX + barW + 2).toFixed(1),
          y: (padTop + plotH - ulH).toFixed(1),
          width: barW.toFixed(1),
          height: ulH.toFixed(1),
          rx: '2',
          fill: '#64748b',
          opacity: '0.85',
        }),
      );
    });

    return E(
      'div',
      {
        class:
          'tachyon_dashboard-page__widgets-section__item tachyon-traffic-chart-card tachyon-traffic-chart-card--bars',
        'data-chart-view': 'bars',
      },
      [
        headerLegend,
        E('div', { class: 'tachyon-traffic-chart-card__body' }, [
          svgEl(
            'svg',
            {
              viewBox: `0 0 ${w} ${h}`,
              class: 'tachyon-traffic-chart-svg',
              preserveAspectRatio: 'none',
            },
            [
              ...[0.25, 0.5, 0.75, 1].map((frac) =>
                svgEl('line', {
                  x1: String(padLeft),
                  y1: String(padTop + plotH * frac),
                  x2: String(padLeft + plotW),
                  y2: String(padTop + plotH * frac),
                  stroke: 'var(--border-color-low, rgba(128,128,128,0.16))',
                  'stroke-width': '1',
                  'stroke-dasharray': '3,3',
                }),
              ),
              ...barNodes,
            ],
          ),
        ]),
      ],
    );
  }

  const toCoords = (selector: (p: TrafficHistoryPoint) => number) =>
    pts.map((p, idx) => {
      const x = padLeft + (idx / Math.max(pts.length - 1, 1)) * plotW;
      const ratio = Math.min(1, Math.max(0, selector(p) / maxSpeed));
      const y = padTop + plotH - ratio * plotH;
      return `${x.toFixed(1)},${y.toFixed(1)}`;
    });

  const downCoords = toCoords((p) => p.down);
  const upCoords = toCoords((p) => p.up);

  const downLine = `M ${downCoords.join(' L ')}`;
  const downArea = `${downLine} L ${padLeft + plotW},${padTop + plotH} L ${padLeft},${padTop + plotH} Z`;

  const upLine = `M ${upCoords.join(' L ')}`;
  const upArea = `${upLine} L ${padLeft + plotW},${padTop + plotH} L ${padLeft},${padTop + plotH} Z`;

  return E(
    'div',
    {
      class:
        'tachyon_dashboard-page__widgets-section__item tachyon-traffic-chart-card',
      'data-chart-view': 'area',
    },
    [
      headerLegend,
      E('div', { class: 'tachyon-traffic-chart-card__body' }, [
        svgEl(
          'svg',
          {
            viewBox: `0 0 ${w} ${h}`,
            class: 'tachyon-traffic-chart-svg',
            preserveAspectRatio: 'none',
          },
          [
            svgEl('defs', {}, [
              svgEl(
                'linearGradient',
                {
                  id: 'tachyon-dl-grad',
                  x1: '0%',
                  y1: '0%',
                  x2: '0%',
                  y2: '100%',
                },
                [
                  svgEl('stop', {
                    offset: '0%',
                    'stop-color': '#9482e0',
                    'stop-opacity': '0.28',
                  }),
                  svgEl('stop', {
                    offset: '100%',
                    'stop-color': '#9482e0',
                    'stop-opacity': '0.02',
                  }),
                ],
              ),
              svgEl(
                'linearGradient',
                {
                  id: 'tachyon-ul-grad',
                  x1: '0%',
                  y1: '0%',
                  x2: '0%',
                  y2: '100%',
                },
                [
                  svgEl('stop', {
                    offset: '0%',
                    'stop-color': '#64748b',
                    'stop-opacity': '0.22',
                  }),
                  svgEl('stop', {
                    offset: '100%',
                    'stop-color': '#64748b',
                    'stop-opacity': '0.01',
                  }),
                ],
              ),
            ]),
            ...[0.25, 0.5, 0.75, 1].map((frac) =>
              svgEl('line', {
                x1: String(padLeft),
                y1: String(padTop + plotH * frac),
                x2: String(padLeft + plotW),
                y2: String(padTop + plotH * frac),
                stroke: 'var(--border-color-low, rgba(128,128,128,0.16))',
                'stroke-width': '1',
                'stroke-dasharray': '3,3',
              }),
            ),
            svgEl('path', { d: downArea, fill: 'url(#tachyon-dl-grad)' }),
            svgEl('path', {
              d: downLine,
              fill: 'none',
              stroke: '#9482e0',
              'stroke-width': '2.4',
              'stroke-linecap': 'round',
              'stroke-linejoin': 'round',
            }),
            svgEl('path', { d: upArea, fill: 'url(#tachyon-ul-grad)' }),
            svgEl('path', {
              d: upLine,
              fill: 'none',
              stroke: '#64748b',
              'stroke-width': '2.2',
              'stroke-linecap': 'round',
              'stroke-linejoin': 'round',
            }),
          ],
        ),
      ]),
    ],
  );
}

/* ==========================================================================
   Two-Block Dashboard Redesign:
   Block 1: Секции маршрутизации (Routing Sections Row List)
   Block 2: Узлы (Nodes Grid + Auto-Selection Modes + Filters + Subscription Info)
   ========================================================================== */

export interface SectionTrafficSummary {
  conns: number;
  download: number;
  upload: number;
  downSpeed: number;
  upSpeed: number;
}

export interface RenderDashboardSectionsAndNodesProps {
  sections: Tachyon.OutboundGroup[];
  selectedSectionCode: string;
  onSelectSection: (sectionCode: string) => void;
  getSectionStats: (section: Tachyon.OutboundGroup) => SectionTrafficSummary;
  isTestingAllSections: boolean;
  onTestAllSections: () => void;
  latencyFetchingSections: Record<string, boolean>;
  latencyProgressSections: Record<string, Tachyon.LatencyActionProgress>;
  subscriptionUpdatingSections: Record<string, boolean>;
  selectorSwitchingSections: Record<string, string>;
  testingOutboundCodes: Record<string, boolean>;
  activeCountryFilters: Map<string, string>;
  onFilterCountry: (sectionName: string, countryCode?: string) => void;
  onTestSectionLatency: (section: Tachyon.OutboundGroup) => void;
  onTestSingleOutbound: (sectionName: string, outboundCode: string) => void;
  onChooseOutbound: (
    sectionName: string,
    selector: string,
    tag: string,
  ) => void;
  onCopyOutbound: (
    section: Tachyon.OutboundGroup,
    outbound: Tachyon.Outbound,
  ) => void;
  onShowUrlTestInfo: (
    section: Tachyon.OutboundGroup,
    outbound: Tachyon.Outbound,
  ) => void;
  onShowPriorityInfo: (
    section: Tachyon.OutboundGroup,
    outbound: Tachyon.Outbound,
  ) => void;
  onUpdateSubscription: (section: Tachyon.OutboundGroup) => void;
}

export interface SectionEngineMeta {
  isDpiOnly: boolean;
  primaryEngine: string;
  engineBadges: Array<{
    label: string;
    kind: 'dpi' | 'proxy' | 'transport';
    title?: string;
    icon?: () => SVGElement;
  }>;
  dpiServerLabel?: string;
  dpiSelectorLabel?: string;
  dpiSubtitlePrefix?: string;
  col2Label?: string;
  col3Label?: string;
}

export function normalizeTransportBadgeLabel(raw?: string): string {
  const clean = String(raw || '')
    .trim()
    .toLowerCase();
  if (!clean) return '';
  switch (clean) {
    case 'xhttp':
    case 'splithttp':
    case 'xhttp-reality':
      return 'XHTTP';
    case 'grpc':
    case 'gun':
      return 'GRPC';
    case 'ws':
    case 'websocket':
      return 'WS';
    case 'httpupgrade':
      return 'HTTPUPGRADE';
    case 'h2':
    case 'http':
    case 'http2':
      return 'H2';
    case 'quic':
      return 'QUIC';
    case 'kcp':
    case 'mkcp':
      return 'KCP';
    case 'tcp':
    case 'raw':
      return 'TCP';
    default:
      return clean.toUpperCase();
  }
}

function extractNodeTransportLabel(node: any): string {
  if (!node || typeof node !== 'object') return '';
  if (typeof node.transport === 'string' && node.transport.trim()) {
    return normalizeTransportBadgeLabel(node.transport);
  }
  if (
    typeof node.details?.transport?.type === 'string' &&
    node.details.transport.type.trim()
  ) {
    return normalizeTransportBadgeLabel(node.details.transport.type);
  }
  if (
    typeof node.details?.transport === 'string' &&
    node.details.transport.trim()
  ) {
    return normalizeTransportBadgeLabel(node.details.transport);
  }
  if (typeof node.link === 'string' && node.link.trim()) {
    const parsed = getProxyUrlTransport(node.link);
    if (parsed) return normalizeTransportBadgeLabel(parsed);
  }
  return '';
}

const SECTION_ICON_PRESETS: Array<{
  label: string;
  domain: string;
  keywords: string[];
}> = [
  {
    label: 'YouTube',
    domain: 'youtube.com',
    keywords: ['youtube', 'ютуб', 'googlevideo'],
  },
  {
    label: 'Discord',
    domain: 'discord.com',
    keywords: ['discord', 'дискорд'],
  },
  {
    label: 'Telegram',
    domain: 'telegram.org',
    keywords: ['telegram', 'телеграм'],
  },
  {
    label: 'ChatGPT / OpenAI',
    domain: 'chatgpt.com',
    keywords: ['openai', 'chatgpt', 'gpt'],
  },
  {
    label: 'Claude',
    domain: 'claude.ai',
    keywords: ['claude', 'anthropic'],
  },
  {
    label: 'Gemini / Google AI',
    domain: 'gemini.google.com',
    keywords: ['google_ai', 'gemini'],
  },
  {
    label: 'Instagram / Meta',
    domain: 'instagram.com',
    keywords: ['instagram', 'инста', 'meta', 'facebook'],
  },
  {
    label: 'X / Twitter',
    domain: 'x.com',
    keywords: ['twitter', 'твиттер', 'x.com'],
  },
  {
    label: 'TikTok',
    domain: 'tiktok.com',
    keywords: ['tiktok', 'тикток'],
  },
  {
    label: 'Twitch',
    domain: 'twitch.tv',
    keywords: ['twitch', 'твич'],
  },
  {
    label: 'Steam',
    domain: 'store.steampowered.com',
    keywords: ['steam', 'стим'],
  },
  {
    label: 'Roblox',
    domain: 'roblox.com',
    keywords: ['roblox', 'роблокс'],
  },
  {
    label: 'Spotify',
    domain: 'spotify.com',
    keywords: ['spotify', 'спотифай'],
  },
  {
    label: 'Netflix',
    domain: 'netflix.com',
    keywords: ['netflix', 'нетфликс'],
  },
  {
    label: 'GitHub',
    domain: 'github.com',
    keywords: ['github', 'гитхаб'],
  },
  {
    label: 'RuTracker',
    domain: 'rutracker.org',
    keywords: ['rutracker', 'рутрекер'],
  },
  {
    label: 'HDRezka',
    domain: 'hdrezka.ag',
    keywords: ['hdrezka', 'резка'],
  },
  {
    label: 'Cloudflare',
    domain: 'cloudflare.com',
    keywords: ['cloudflare', 'warp'],
  },
  {
    label: 'Google',
    domain: 'google.com',
    keywords: ['google', 'гугл'],
  },
  {
    label: 'WhatsApp',
    domain: 'whatsapp.com',
    keywords: ['whatsapp', 'ватсап'],
  },
];

function getGlobalUci(): any {
  if (typeof uci !== 'undefined' && uci) return uci;
  const g = globalThis as any;
  return g.uci || g.L?.uci;
}

function getGlobalUi(): any {
  if (typeof ui !== 'undefined' && ui) return ui;
  const g = globalThis as any;
  return g.ui || g.L?.ui;
}

function toStringArray(val: unknown): string[] {
  if (!val) return [];
  const rawList = Array.isArray(val) ? val : [val];
  const out: string[] = [];
  for (const item of rawList) {
    const lines = String(item || '').split(/\r?\n/);
    for (const rawLine of lines) {
      const cleaned = rawLine.replace(/(?:^|\s)(?:\/\/|#).*$/, '').trim();
      if (!cleaned) continue;
      for (const tok of cleaned.split(/[\s,]+/)) {
        const t = tok.trim();
        if (t && !t.startsWith('//') && !t.startsWith('#')) {
          out.push(t);
        }
      }
    }
  }
  return out;
}

function normalizeFaviconDomainInput(raw: string): string {
  const trimmed = String(raw || '').trim();
  if (!trimmed) return '';
  if (trimmed.toLowerCase() === 'svg' || trimmed.toLowerCase() === 'none') {
    return 'svg';
  }
  if (/^https?:\/\/.+\.(ico|png|svg|jpg|jpeg|webp)(\?.*)?$/i.test(trimmed)) {
    return trimmed;
  }
  const host = trimmed
    .replace(/^https?:\/\//i, '')
    .split(/[/?#]/)[0]
    .trim()
    .toLowerCase();
  return host;
}

function buildFaviconCandidateUrls(domainOrUrl: string): string[] {
  const norm = normalizeFaviconDomainInput(domainOrUrl);
  if (!norm || norm === 'svg') return [];
  if (/^https?:\/\//i.test(norm)) {
    return [norm];
  }
  if (!norm.includes('.')) return [];
  return [
    `https://www.google.com/s2/favicons?domain=${encodeURIComponent(norm)}&sz=64`,
    `https://icons.duckduckgo.com/ip3/${encodeURIComponent(norm)}.ico`,
    `https://${norm}/favicon.ico`,
  ];
}

export function resolveSectionFaviconDomain(
  section: Tachyon.OutboundGroup,
): string | null {
  const secName = section.sectionName || section.code || '';
  const uciObj = getGlobalUci();

  let custom = '';
  try {
    if (typeof localStorage !== 'undefined' && secName) {
      custom = localStorage.getItem(`tachyon_sec_icon_${secName}`) || '';
    }
  } catch {
    // ignore storage access errors
  }
  if (!custom && uciObj && typeof uciObj.get === 'function' && secName) {
    try {
      custom = String(
        uciObj.get('tachyon', secName, 'icon_domain') || '',
      ).trim();
    } catch {
      // ignore uci read errors
    }
  }

  if (custom) {
    const norm = normalizeFaviconDomainInput(custom);
    if (norm === 'svg') return null;
    if (norm) return norm;
  }

  const nameTokens = `${secName} ${section.displayName || ''}`
    .toLowerCase()
    .trim();
  for (const preset of SECTION_ICON_PRESETS) {
    if (preset.keywords.some((kw) => nameTokens.includes(kw))) {
      return preset.domain;
    }
  }

  // Inspect section's community_lists and linked conditions if not a generic Main section
  const isMainLike =
    nameTokens === 'main' ||
    nameTokens.includes('основн') ||
    secName.toLowerCase() === 'main';
  if (!isMainLike && uciObj && typeof uciObj.get === 'function' && secName) {
    try {
      const condRefs = toStringArray(
        uciObj.get('tachyon', secName, 'condition_refs'),
      ).map((r) => r.replace(/^!\s*/, '').trim());
      const allLists: string[] = [];
      const condDomains: string[] = [];

      if (condRefs.length > 0) {
        for (const cid of condRefs) {
          allLists.push(
            ...toStringArray(uciObj.get('tachyon', cid, 'community_lists')),
            ...toStringArray(uciObj.get('tachyon', cid, 'domain_lists')),
          );
          condDomains.push(
            ...toStringArray(uciObj.get('tachyon', cid, 'user_domains')),
            ...toStringArray(uciObj.get('tachyon', cid, 'domain_suffix')),
            ...toStringArray(uciObj.get('tachyon', cid, 'domains')),
          );
        }
      } else {
        allLists.push(
          ...toStringArray(uciObj.get('tachyon', secName, 'community_lists')),
        );
      }

      const listBlob = allLists.join(' ').toLowerCase();
      for (const preset of SECTION_ICON_PRESETS) {
        if (preset.keywords.some((kw) => listBlob.includes(kw))) {
          return preset.domain;
        }
      }

      for (const d of condDomains) {
        const cleanDom = normalizeFaviconDomainInput(d.replace(/^\*\./, ''));
        if (
          cleanDom &&
          cleanDom !== 'svg' &&
          /^[a-z0-9.-]+\.[a-z]{2,}$/i.test(cleanDom)
        ) {
          return cleanDom;
        }
      }
    } catch {
      // ignore uci lookup error
    }
  }

  return null;
}

function createSectionIconContent(
  section: Tachyon.OutboundGroup,
  visual: { iconNodes: SVGElement[] },
  overrideDomain?: string | null,
): HTMLElement {
  const domain =
    overrideDomain !== undefined
      ? overrideDomain
      : resolveSectionFaviconDomain(section);
  const urls = domain ? buildFaviconCandidateUrls(domain) : [];

  const svgFallback = svgEl(
    'svg',
    {
      class: 'tachyon-routing-row__svg-icon',
      viewBox: '0 0 24 24',
      width: '18',
      height: '18',
      fill: 'none',
      stroke: 'currentColor',
      'stroke-width': '2',
      'stroke-linecap': 'round',
      'stroke-linejoin': 'round',
      style: urls.length > 0 ? 'display: none;' : '',
    },
    visual.iconNodes.map((n) => n.cloneNode(true) as SVGElement),
  );

  if (urls.length === 0) {
    return E('span', { class: 'tachyon-routing-row__icon-inner' }, [
      svgFallback,
    ]);
  }

  let urlIndex = 0;
  const imgEl = E('img', {
    class: 'tachyon-routing-row__favicon',
    src: urls[0],
    alt: domain || '',
    loading: 'lazy',
    referrerPolicy: 'no-referrer',
  } as any) as HTMLImageElement;

  imgEl.addEventListener('error', () => {
    urlIndex += 1;
    if (urlIndex < urls.length) {
      imgEl.src = urls[urlIndex];
    } else {
      imgEl.style.display = 'none';
      svgFallback.style.display = '';
    }
  });

  return E('span', { class: 'tachyon-routing-row__icon-inner' }, [
    imgEl,
    svgFallback,
  ]);
}

export function openSectionIconPickerModal(
  section: Tachyon.OutboundGroup,
  onSaved?: (newDomain: string) => void,
): void {
  const uiObj = getGlobalUi();
  const uciObj = getGlobalUci();
  if (!uiObj || typeof uiObj.showModal !== 'function') return;

  const secName = section.sectionName || section.code || '';
  const visual = getSectionVisualMeta(section);
  let explicitSaved = '';
  try {
    if (typeof localStorage !== 'undefined' && secName) {
      explicitSaved = localStorage.getItem(`tachyon_sec_icon_${secName}`) || '';
    }
  } catch {
    // ignore
  }
  if (!explicitSaved && uciObj && typeof uciObj.get === 'function' && secName) {
    try {
      explicitSaved = String(
        uciObj.get('tachyon', secName, 'icon_domain') || '',
      ).trim();
    } catch {
      // ignore
    }
  }
  let currentDomain =
    explicitSaved === 'svg'
      ? 'svg'
      : explicitSaved || resolveSectionFaviconDomain(section) || '';

  const previewBox = E(
    'div',
    {
      class: 'tachyon-routing-row__icon tachyon-icon-picker__preview-icon',
      style: `background: ${visual.bg}; color: ${visual.color}; width: 42px; height: 42px; border-radius: 10px;`,
    },
    [
      createSectionIconContent(
        section,
        visual,
        currentDomain === 'svg' || !currentDomain ? null : currentDomain,
      ),
    ],
  );

  const previewDomainLabel = E(
    'div',
    { class: 'tachyon-icon-picker__preview-domain' },
    currentDomain && currentDomain !== 'svg'
      ? `${tr('Источник иконки:', 'Icon source:')} ${currentDomain}`
      : tr('Стандартная векторная иконка (SVG)', 'Default vector icon (SVG)'),
  );

  const updatePreview = (val: string) => {
    currentDomain = val.trim();
    const norm = normalizeFaviconDomainInput(currentDomain);
    previewBox.replaceChildren(
      createSectionIconContent(
        section,
        visual,
        norm === 'svg' || !norm ? null : norm,
      ),
    );
    previewDomainLabel.textContent =
      norm && norm !== 'svg'
        ? `${tr('Источник иконки:', 'Icon source:')} ${norm}`
        : tr('Стандартная векторная иконка (SVG)', 'Default vector icon (SVG)');
  };

  const domainInput = E('input', {
    type: 'text',
    class: 'cbi-input-text',
    style: 'width: 100%;',
    placeholder: tr(
      'Например: youtube.com, discord.com, chatgpt.com, rutracker.org (или пусто для авто)',
      'e.g. youtube.com, discord.com, chatgpt.com, rutracker.org (or empty for auto)',
    ),
    value: currentDomain === 'svg' ? 'svg' : currentDomain,
    input: (ev: Event) => {
      updatePreview((ev.target as HTMLInputElement).value);
    },
  } as any) as HTMLInputElement;

  const presetChips = SECTION_ICON_PRESETS.map((preset) => {
    const chipUrls = buildFaviconCandidateUrls(preset.domain);
    const chipImg = E('img', {
      src: chipUrls[0] || '',
      width: 16,
      height: 16,
      style: 'border-radius: 4px; flex-shrink: 0;',
      referrerPolicy: 'no-referrer',
    } as any);
    return E(
      'button',
      {
        type: 'button',
        class: 'tachyon-icon-picker__chip',
        click: () => {
          domainInput.value = preset.domain;
          updatePreview(preset.domain);
        },
      },
      [chipImg, E('span', {}, preset.label)],
    );
  });

  const modalBody = E('div', { class: 'tachyon-icon-picker' }, [
    E('div', { class: 'tachyon-icon-picker__preview-row' }, [
      previewBox,
      E('div', { class: 'tachyon-icon-picker__preview-text' }, [
        E(
          'div',
          { style: 'font-weight: 800; font-size: 14px;' },
          section.displayName || secName,
        ),
        previewDomainLabel,
      ]),
    ]),
    E('div', { class: 'tachyon-icon-picker__field' }, [
      E(
        'label',
        {
          style:
            'font-weight: 700; font-size: 12px; display: block; margin-bottom: 4px;',
        },
        tr(
          'Домен сайта (подгрузит favicon.ico автоматически) или прямая ссылка на иконку:',
          'Website domain (loads favicon.ico automatically) or direct icon URL:',
        ),
      ),
      domainInput,
    ]),
    E('div', { class: 'tachyon-icon-picker__presets-wrap' }, [
      E(
        'div',
        {
          style:
            'font-weight: 700; font-size: 11px; opacity: 0.72; text-transform: uppercase; margin-bottom: 6px;',
        },
        tr('Быстрый выбор популярных сайтов:', 'Quick pick popular websites:'),
      ),
      E('div', { class: 'tachyon-icon-picker__chips-grid' }, [
        ...presetChips,
        E(
          'button',
          {
            type: 'button',
            class: 'tachyon-icon-picker__chip',
            click: () => {
              domainInput.value = '';
              updatePreview('');
            },
          },
          [
            renderCompassIcon(12),
            E('span', {}, tr('Авто (по правилам)', 'Auto (by rules)')),
          ],
        ),
        E(
          'button',
          {
            type: 'button',
            class: 'tachyon-icon-picker__chip',
            click: () => {
              domainInput.value = 'svg';
              updatePreview('svg');
            },
          },
          [
            renderSparklesIcon(12),
            E('span', {}, tr('Стандартная SVG', 'Default SVG')),
          ],
        ),
      ]),
    ]),
    E(
      'div',
      {
        style:
          'display: flex; justify-content: flex-end; gap: 8px; margin-top: 14px; padding-top: 10px; border-top: 1px solid rgba(128,128,128,0.18);',
      },
      [
        E(
          'button',
          {
            type: 'button',
            class: 'btn cbi-button',
            click: () => uiObj.hideModal(),
          },
          tr('Отмена', 'Cancel'),
        ),
        E(
          'button',
          {
            type: 'button',
            class: 'btn cbi-button cbi-button-positive important',
            click: () => {
              const savedNorm = normalizeFaviconDomainInput(domainInput.value);
              try {
                if (typeof localStorage !== 'undefined' && secName) {
                  if (savedNorm) {
                    localStorage.setItem(
                      `tachyon_sec_icon_${secName}`,
                      savedNorm,
                    );
                  } else {
                    localStorage.removeItem(`tachyon_sec_icon_${secName}`);
                  }
                }
              } catch {
                // ignore localStorage error
              }
              if (uciObj && secName) {
                const applyUciIcon = () => {
                  try {
                    if (savedNorm) {
                      if (typeof uciObj.set === 'function') {
                        uciObj.set(
                          'tachyon',
                          secName,
                          'icon_domain',
                          savedNorm,
                        );
                      }
                    } else if (typeof uciObj.unset === 'function') {
                      uciObj.unset('tachyon', secName, 'icon_domain');
                    } else if (typeof uciObj.set === 'function') {
                      uciObj.set('tachyon', secName, 'icon_domain', '');
                    }
                    if (typeof uciObj.save === 'function') {
                      void Promise.resolve(uciObj.save());
                    }
                  } catch {
                    // ignore uci error
                  }
                };
                try {
                  const hasLoaded =
                    typeof uciObj.get === 'function' &&
                    uciObj.get('tachyon', secName) != null;
                  if (!hasLoaded && typeof uciObj.load === 'function') {
                    void Promise.resolve(uciObj.load('tachyon')).then(
                      applyUciIcon,
                    );
                  } else {
                    applyUciIcon();
                  }
                } catch {
                  applyUciIcon();
                }
              }
              document
                .querySelectorAll<HTMLElement>(
                  `[data-section-icon-box="${secName}"]`,
                )
                .forEach((box) => {
                  const effDom = resolveSectionFaviconDomain(section);
                  box.replaceChildren(
                    createSectionIconContent(section, visual, effDom),
                  );
                });
              try {
                window.dispatchEvent(new CustomEvent('tachyon-uci-changed'));
              } catch {
                // ignore
              }
              uiObj.hideModal();
              onSaved?.(savedNorm);
            },
          },
          tr('Сохранить иконку', 'Save Icon'),
        ),
      ],
    ),
  ]);

  const dlg = uiObj.showModal(
    tr('Иконка секции маршрутизации', 'Routing Section Icon'),
    [modalBody],
    'cbi-modal',
  );
  if (dlg instanceof HTMLElement) {
    dlg.classList.add('cbi-modal');
  }
}

function formatDesyncPresetLabel(presetRaw: string): string {
  const p = (presetRaw || 'auto').trim().toLowerCase();
  if (p === 'auto' || p === 'disorder') {
    return tr('Auto (TCP/UDP)', 'Auto (TCP/UDP)');
  }
  if (p === 'google_youtube' || p === 'youtube') {
    return 'YouTube / QUIC';
  }
  if (p === 'discord') {
    return 'Discord (Voice/UDP)';
  }
  if (p === 'custom') {
    return 'Custom CLI';
  }
  return presetRaw;
}

export function resolveSectionEngineMeta(
  section: Tachyon.OutboundGroup,
): SectionEngineMeta {
  const secName = section.sectionName || section.code || '';
  const uciObj = getGlobalUci();
  const selectedOutbound = (section.outbounds || []).find((o) => o.selected);
  const selectedTypeUpper = (selectedOutbound?.type || '').toUpperCase();
  const rawAction = (
    section.serviceStatus?.serviceType ||
    section.action ||
    ''
  ).toLowerCase();

  const dpiTypes = new Set([
    'zapret',
    'zapret2',
    'byedpi',
    'desync',
    'wdtt',
    'olcrtc',
    'block',
    'reject',
    'bypass',
    'direct',
    'dns',
  ]);

  // Read UCI outbound_source_refs and condition_refs for rich DPI/Proxy engine info
  const sourceTypes: string[] = [];
  const uciSourceLinks: string[] = [];
  let desyncPreset = 'auto';
  let directNfqws = false;
  let byedpiOpts = '';
  let condSuggestsZapret2 = false;

  if (uciObj && typeof uciObj.get === 'function' && secName) {
    try {
      if (uciObj.get('tachyon', secName, 'direct_nfqws') === '1') {
        directNfqws = true;
      }
      const presetOnSec = uciObj.get('tachyon', secName, 'desync_preset');
      if (presetOnSec) desyncPreset = String(presetOnSec);

      const srcRefs = toStringArray(
        uciObj.get('tachyon', secName, 'outbound_source_refs'),
      );
      for (const sid of srcRefs) {
        const st = String(
          uciObj.get('tachyon', sid, 'source_type') || '',
        ).toLowerCase();
        if (st) sourceTypes.push(st);
        if (st === 'desync') {
          const sp = uciObj.get('tachyon', sid, 'desync_preset');
          if (sp) desyncPreset = String(sp);
        } else if (st === 'zapret2' || st === 'zapret') {
          if (uciObj.get('tachyon', sid, 'direct_nfqws') === '1') {
            directNfqws = true;
          }
        } else if (st === 'byedpi') {
          const bo = uciObj.get('tachyon', sid, 'byedpi_cmd_opts');
          if (bo) byedpiOpts = String(bo);
        }
        const rawUrl = uciObj.get('tachyon', sid, 'url');
        if (typeof rawUrl === 'string' && rawUrl.includes('://')) {
          uciSourceLinks.push(rawUrl);
        }
        const rawLinks = toStringArray(uciObj.get('tachyon', sid, 'links'));
        for (const lnk of rawLinks) {
          if (lnk.includes('://')) uciSourceLinks.push(lnk);
        }
      }

      const condRefs = toStringArray(
        uciObj.get('tachyon', secName, 'condition_refs'),
      );
      for (const cid of condRefs) {
        const cname = String(
          uciObj.get('tachyon', cid, 'name') || cid,
        ).toLowerCase();
        if (cname.includes('zapret2')) {
          condSuggestsZapret2 = true;
        }
      }
    } catch {
      // ignore uci lookup error
    }
  }

  // Determine primary engine
  let primaryEngine = rawAction;
  if (!dpiTypes.has(primaryEngine)) {
    if (dpiTypes.has(selectedTypeUpper.toLowerCase())) {
      primaryEngine = selectedTypeUpper.toLowerCase();
    } else if (
      sourceTypes.length > 0 &&
      sourceTypes.every((st) => dpiTypes.has(st))
    ) {
      primaryEngine = sourceTypes[0];
    } else if (
      (!section.outbounds || section.outbounds.length === 0) &&
      sourceTypes.length === 0 &&
      condSuggestsZapret2
    ) {
      primaryEngine = 'zapret2';
    }
  }

  const isDpiOnly = dpiTypes.has(primaryEngine);
  const engineBadges: SectionEngineMeta['engineBadges'] = [];
  const addedBadges = new Set<string>();
  const pushBadge = (
    label: string,
    kind: 'dpi' | 'proxy' | 'transport',
    title?: string,
    icon?: () => SVGElement,
  ) => {
    if (!label || addedBadges.has(label)) return;
    addedBadges.add(label);
    engineBadges.push({ label, kind, title, icon });
  };

  const addDpiBadgeFor = (eng: string) => {
    switch (eng.toLowerCase()) {
      case 'desync':
        pushBadge(
          'Core Desync',
          'dpi',
          tr(
            'Нативная десинхронизация пакетов в ядре Tachyon Core (без прокси)',
            'Native packet desynchronization inside Tachyon Core',
          ),
          () => renderZapIcon(11),
        );
        break;
      case 'zapret2':
        pushBadge(
          'Zapret2',
          'dpi',
          tr(
            'Обход DPI через Zapret2 (nfqws2 + Lua-стратегии)',
            'DPI bypass via Zapret2 (nfqws2 + Lua strategies)',
          ),
          () => renderZapIcon(11),
        );
        break;
      case 'zapret':
        pushBadge(
          'Zapret',
          'dpi',
          tr('Обход DPI через Zapret (nfqws)', 'DPI bypass via Zapret (nfqws)'),
          () => renderZapIcon(11),
        );
        break;
      case 'byedpi':
        pushBadge(
          'ByeDPI',
          'dpi',
          tr(
            'Обход DPI через ByeDPI (ciadpi SOCKS5)',
            'DPI bypass via ByeDPI (ciadpi SOCKS5)',
          ),
          () => renderZapIcon(11),
        );
        break;
      case 'wdtt':
        pushBadge('WDTT', 'dpi', 'WDTT Anti-DPI', () => renderZapIcon(11));
        break;
      case 'olcrtc':
        pushBadge('OLCRTC', 'dpi', 'OLCRTC WebRTC Bypass', () =>
          renderZapIcon(11),
        );
        break;
      case 'block':
      case 'reject':
        pushBadge(
          tr('Блокировка', 'Block'),
          'dpi',
          tr('Блокировка трафика (Reject)', 'Traffic block (Reject)'),
        );
        break;
      case 'bypass':
      case 'direct':
        pushBadge(
          tr('Напрямую', 'Bypass'),
          'transport',
          tr('Прямой выход мимо прокси (WAN)', 'Direct WAN bypass'),
        );
        break;
      case 'dns':
        pushBadge(
          'DNS',
          'transport',
          tr('Маршрутизация DNS-запросов', 'DNS routing rule'),
        );
        break;
    }
  };

  if (isDpiOnly) {
    addDpiBadgeFor(primaryEngine);
  } else {
    // Check if section has any DPI sources alongside proxy sources
    for (const st of sourceTypes) {
      if (dpiTypes.has(st)) {
        addDpiBadgeFor(st);
      }
    }
    for (const ob of section.outbounds || []) {
      const oType = (ob.type || '').toLowerCase();
      if (dpiTypes.has(oType)) {
        addDpiBadgeFor(oType);
      }
    }
  }

  const groupMetaTypes = new Set([
    'SELECTOR',
    'URLTEST',
    'PRIORITY',
    'GROUP',
    'CONNECTION',
    'SING_BOX',
  ]);

  // Also add Proxy/Tunnel protocol badge and transport badges (e.g. VLESS + GRPC / XHTTP)
  if (!isDpiOnly) {
    if (
      rawAction === 'fptn' ||
      sourceTypes.includes('fptn') ||
      selectedTypeUpper.includes('FPTN')
    ) {
      pushBadge('FPTN', 'proxy', 'FPTN VPN', () => renderShieldIcon(11));
    } else if (
      rawAction === 'warp' ||
      sourceTypes.includes('warp') ||
      selectedTypeUpper.includes('WARP')
    ) {
      pushBadge('WARP', 'proxy', 'Cloudflare WARP', () => renderCloudIcon(11));
    } else if (
      rawAction === 'awg' ||
      sourceTypes.includes('amnezia_config') ||
      sourceTypes.includes('awg') ||
      selectedTypeUpper.includes('AWG') ||
      selectedTypeUpper.includes('WIREGUARD')
    ) {
      pushBadge('AWG / WG', 'proxy', 'AmneziaWG / WireGuard', () =>
        renderLockIcon(11),
      );
    } else if (selectedOutbound || (section.outbounds || []).length > 0) {
      const info =
        selectedOutbound?.urlTestInfo || selectedOutbound?.priorityInfo;
      const activeChild = info?.outbounds?.find(
        (m) =>
          m.selected ||
          (info.selectedCode && m.code === info.selectedCode) ||
          (info.selectedName && m.displayName === info.selectedName),
      );
      const matchedNode = (section.outbounds || []).find(
        (o) =>
          (activeChild?.code && o.code === activeChild.code) ||
          (info?.selectedCode && o.code === info.selectedCode) ||
          (activeChild?.displayName &&
            o.displayName === activeChild.displayName),
      );

      let protoRaw = (
        activeChild?.type ||
        matchedNode?.type ||
        selectedOutbound?.type ||
        ''
      ).toUpperCase();

      if (!protoRaw || groupMetaTypes.has(protoRaw)) {
        const firstRealNode =
          (info?.outbounds || []).find(
            (m) => m.type && !groupMetaTypes.has(m.type.toUpperCase()),
          ) ||
          (section.outbounds || []).find(
            (o) => o.type && !groupMetaTypes.has(o.type.toUpperCase()),
          );
        if (firstRealNode?.type) {
          protoRaw = firstRealNode.type.toUpperCase();
        }
      }

      if (
        protoRaw &&
        !groupMetaTypes.has(protoRaw) &&
        !dpiTypes.has(protoRaw.toLowerCase())
      ) {
        pushBadge(protoRaw, 'proxy');
      }

      // Collect transport protocols (GRPC, XHTTP, WS, HTTPUPGRADE, QUIC, H2, TCP)
      const activeTransport =
        extractNodeTransportLabel(activeChild) ||
        extractNodeTransportLabel(matchedNode) ||
        extractNodeTransportLabel(selectedOutbound);

      const nonTcpTransports: string[] = [];
      let hasTcpTransport = false;
      const recordTransport = (trLabel: string) => {
        if (!trLabel) return;
        if (trLabel === 'TCP') {
          hasTcpTransport = true;
          return;
        }
        if (!nonTcpTransports.includes(trLabel)) {
          nonTcpTransports.push(trLabel);
        }
      };

      if (activeTransport) {
        recordTransport(activeTransport);
      }
      for (const m of info?.outbounds || []) {
        recordTransport(extractNodeTransportLabel(m));
      }
      for (const ob of section.outbounds || []) {
        recordTransport(extractNodeTransportLabel(ob));
        const subInfo = ob.urlTestInfo || ob.priorityInfo;
        for (const m of subInfo?.outbounds || []) {
          recordTransport(extractNodeTransportLabel(m));
        }
      }
      for (const lnk of uciSourceLinks) {
        recordTransport(
          normalizeTransportBadgeLabel(getProxyUrlTransport(lnk)),
        );
      }

      const orderedTransports = [...nonTcpTransports];
      if (
        hasTcpTransport &&
        (activeTransport === 'TCP' || orderedTransports.length === 0)
      ) {
        if (activeTransport === 'TCP') {
          orderedTransports.unshift('TCP');
        } else {
          orderedTransports.push('TCP');
        }
      }

      for (const trBadge of orderedTransports.slice(0, 3)) {
        const isCurrent = trBadge === activeTransport;
        pushBadge(
          trBadge,
          'transport',
          isCurrent
            ? `${tr('Активный транспорт узла', 'Active node transport')}: ${trBadge}`
            : `${tr('Транспорт узлов секции', 'Section node transport')}: ${trBadge}`,
        );
      }
    }
  }

  let dpiServerLabel: string | undefined;
  let dpiSelectorLabel: string | undefined;
  let dpiSubtitlePrefix: string | undefined;
  let col2Label = tr('Сервер', 'Server');
  let col3Label = tr('Селектор', 'Selector');

  const conditionSummaryLabels: string[] = [];
  if (uciObj && typeof uciObj.get === 'function' && secName) {
    try {
      const condRefs = toStringArray(
        uciObj.get('tachyon', secName, 'condition_refs'),
      );
      for (const cid of condRefs) {
        const cname = String(
          uciObj.get('tachyon', cid, 'name') ||
            uciObj.get('tachyon', cid, 'display_name') ||
            cid,
        ).trim();
        if (cname && !conditionSummaryLabels.includes(cname)) {
          conditionSummaryLabels.push(cname);
        }
      }
    } catch {
      // ignore
    }
  }
  const conditionSummaryText =
    conditionSummaryLabels.length > 0
      ? conditionSummaryLabels.slice(0, 2).join(', ')
      : '';

  if (isDpiOnly) {
    col2Label = tr('Движок', 'Engine');
    col3Label = tr('Стратегия', 'Strategy');
    if (primaryEngine === 'desync') {
      const presetText = formatDesyncPresetLabel(desyncPreset);
      dpiServerLabel = 'Tachyon Core (Desync)';
      dpiSelectorLabel = `Desync • ${presetText}`;
      dpiSubtitlePrefix = `Core Desync (${presetText})`;
    } else if (primaryEngine === 'zapret2') {
      dpiServerLabel = 'Zapret2 (nfqws2)';
      dpiSelectorLabel = directNfqws
        ? 'Direct NFQUEUE • Lua'
        : 'NFQUEUE • Lua Desync';
      dpiSubtitlePrefix = 'Zapret2 (nfqws2 Lua)';
    } else if (primaryEngine === 'zapret') {
      dpiServerLabel = 'Zapret (nfqws)';
      dpiSelectorLabel = directNfqws ? 'Direct NFQUEUE' : 'NFQUEUE Desync';
      dpiSubtitlePrefix = 'Zapret (nfqws)';
    } else if (primaryEngine === 'byedpi') {
      dpiServerLabel = 'ByeDPI (ciadpi)';
      dpiSelectorLabel = byedpiOpts
        ? `SOCKS5 • ${byedpiOpts.slice(0, 22)}`
        : 'SOCKS5 Desync';
      dpiSubtitlePrefix = 'ByeDPI (ciadpi)';
    } else if (primaryEngine === 'wdtt') {
      dpiServerLabel = 'WDTT Anti-DPI';
      dpiSelectorLabel = 'DPI Bypass';
      dpiSubtitlePrefix = 'WDTT Anti-DPI';
    } else if (primaryEngine === 'olcrtc') {
      dpiServerLabel = 'OLCRTC Bypass';
      dpiSelectorLabel = 'WebRTC Bypass';
      dpiSubtitlePrefix = 'OLCRTC';
    } else if (primaryEngine === 'block' || primaryEngine === 'reject') {
      col2Label = tr('Действие', 'Action');
      col3Label = tr('Правило', 'Rule');
      dpiServerLabel = tr('Блокировка (Reject)', 'Block (Reject)');
      dpiSelectorLabel =
        conditionSummaryText || tr('Отклонение трафика', 'Reject traffic');
      dpiSubtitlePrefix = 'Block';
    } else if (primaryEngine === 'bypass' || primaryEngine === 'direct') {
      col2Label = tr('Маршрут', 'Route');
      col3Label = tr('Режим', 'Mode');
      dpiServerLabel = tr('Прямой выход (WAN)', 'Direct (WAN)');
      dpiSelectorLabel =
        conditionSummaryText || tr('Напрямую (мимо прокси)', 'Direct bypass');
      dpiSubtitlePrefix = 'Bypass';
    } else if (primaryEngine === 'dns') {
      col2Label = tr('DNS-сервер', 'DNS Server');
      col3Label = tr('Протокол', 'Protocol');
      const dnsServers = uciObj
        ? toStringArray(
            uciObj.get?.('tachyon', secName, 'dns_server') ||
              uciObj.get?.('tachyon', secName, 'routed_dns_server'),
          )
        : [];
      const dnsTypeRaw = String(
        uciObj?.get?.('tachyon', secName, 'dns_type') || '',
      )
        .trim()
        .toUpperCase();
      dpiServerLabel =
        dnsServers.length > 0
          ? dnsServers.join(', ')
          : selectedOutbound?.displayName || 'DNS';
      const inferredProto =
        dnsTypeRaw ||
        (dpiServerLabel.startsWith('https://')
          ? 'DoH (HTTPS)'
          : dpiServerLabel.startsWith('tls://')
            ? 'DoT (TLS)'
            : dpiServerLabel.startsWith('quic://')
              ? 'DoQ (QUIC)'
              : 'UDP / TCP');
      dpiSelectorLabel =
        inferredProto === 'DOH'
          ? 'DoH (HTTPS)'
          : inferredProto === 'DOT'
            ? 'DoT (TLS)'
            : inferredProto === 'DOQ'
              ? 'DoQ (QUIC)'
              : inferredProto;
      dpiSubtitlePrefix = 'DNS';
    }
  }

  return {
    isDpiOnly,
    primaryEngine,
    engineBadges,
    dpiServerLabel,
    dpiSelectorLabel,
    dpiSubtitlePrefix,
    col2Label,
    col3Label,
  };
}

function getSectionVisualMeta(section: Tachyon.OutboundGroup): {
  color: string;
  bg: string;
  subtitle: string;
  iconNodes: SVGElement[];
} {
  const key = `${section.sectionName || ''} ${section.displayName || ''}`
    .toLowerCase()
    .trim();

  const calmColor = '#b4a5f0';
  const calmBg = 'rgba(255, 255, 255, 0.04)';

  if (key.includes('main') || key.includes('основн')) {
    return {
      color: calmColor,
      bg: 'rgba(148, 130, 224, 0.12)',
      subtitle: tr('Основной маршрут', 'Primary routing rule'),
      iconNodes: [
        svgEl('circle', { cx: '12', cy: '12', r: '10' }),
        svgEl('line', { x1: '2', y1: '12', x2: '22', y2: '12' }),
        svgEl('path', {
          d: 'M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z',
        }),
      ],
    };
  }

  if (
    key.includes('youtube') ||
    key.includes('ютуб') ||
    key.includes('video')
  ) {
    return {
      color: calmColor,
      bg: calmBg,
      subtitle: tr(
        'Видеостриминг и сервисы Google',
        'Video streaming & Google services',
      ),
      iconNodes: [
        svgEl('rect', { x: '2', y: '5', width: '20', height: '14', rx: '4' }),
        svgEl('polygon', { points: '10 9 15 12 10 15 10 9' }),
      ],
    };
  }

  if (
    key.includes('discord') ||
    key.includes('дискорд') ||
    key.includes('voice')
  ) {
    return {
      color: calmColor,
      bg: calmBg,
      subtitle: tr('Голосовой и текстовый чат', 'Voice and text chat'),
      iconNodes: [
        svgEl('path', {
          d: 'M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z',
        }),
      ],
    };
  }

  if (
    key.includes('telegram') ||
    key.includes('телеграм') ||
    /(?:^|[\s_-])tg(?:$|[\s_-])/i.test(key)
  ) {
    return {
      color: calmColor,
      bg: calmBg,
      subtitle: tr('Мессенджер и медиафайлы', 'Messenger & media'),
      iconNodes: [
        svgEl('line', { x1: '22', y1: '2', x2: '11', y2: '13' }),
        svgEl('polygon', { points: '22 2 15 22 11 13 2 9 22 2' }),
      ],
    };
  }

  if (
    /(?:^|[\s_-])(ai|openai|claude|chatgpt|gemini|llm)(?:$|[\s_-])/i.test(key)
  ) {
    return {
      color: calmColor,
      bg: calmBg,
      subtitle: tr('Нейросети и ИИ-платформы', 'AI platforms & APIs'),
      iconNodes: [
        svgEl('polygon', {
          points: '13 2 3 14 12 14 11 22 21 10 12 10 13 2',
        }),
      ],
    };
  }

  const actLower = (section.action || '').toLowerCase();
  if (actLower === 'block' || actLower === 'reject') {
    return {
      color: calmColor,
      bg: calmBg,
      subtitle: tr(
        'Блокировка рекламы и нежелательного трафика',
        'Ad & unwanted traffic blocking',
      ),
      iconNodes: [
        svgEl('circle', { cx: '12', cy: '12', r: '10' }),
        svgEl('line', { x1: '4.93', y1: '4.93', x2: '19.07', y2: '19.07' }),
      ],
    };
  }

  if (actLower === 'bypass' || actLower === 'direct') {
    return {
      color: calmColor,
      bg: calmBg,
      subtitle: tr(
        'Прямой выход мимо прокси (WAN)',
        'Direct routing bypassing proxy (WAN)',
      ),
      iconNodes: [
        svgEl('circle', { cx: '12', cy: '12', r: '10' }),
        svgEl('polyline', { points: '12 16 16 12 12 8' }),
        svgEl('line', { x1: '8', y1: '12', x2: '16', y2: '12' }),
      ],
    };
  }

  if (actLower === 'dns') {
    return {
      color: calmColor,
      bg: calmBg,
      subtitle: tr(
        'Маршрутизация DNS-запросов по условиям',
        'Conditional DNS query routing',
      ),
      iconNodes: [
        svgEl('circle', { cx: '12', cy: '12', r: '10' }),
        svgEl('polygon', {
          points: '16.24 7.76 14.12 14.12 7.76 16.24 9.88 9.88 16.24 7.76',
        }),
      ],
    };
  }

  if (
    ['zapret', 'zapret2', 'byedpi', 'desync', 'wdtt', 'olcrtc'].includes(
      section.action || '',
    ) ||
    Boolean(section.serviceStatus)
  ) {
    return {
      color: calmColor,
      bg: calmBg,
      subtitle: tr('Обход DPI и модификация пакетов', 'DPI bypass & desync'),
      iconNodes: [
        svgEl('path', { d: 'M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z' }),
      ],
    };
  }

  return {
    color: calmColor,
    bg: calmBg,
    subtitle: tr('Маршрутизация по правилам секции', 'Section traffic rule'),
    iconNodes: [
      svgEl('circle', { cx: '12', cy: '12', r: '10' }),
      svgEl('line', { x1: '2', y1: '12', x2: '22', y2: '12' }),
      svgEl('path', {
        d: 'M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z',
      }),
    ],
  };
}

function resolveSectionActiveInfo(
  section: Tachyon.OutboundGroup,
  engineMeta?: SectionEngineMeta,
): {
  serverName: string;
  selectorLabel: string;
  latencyMs?: number;
  selectedOutbound?: Tachyon.Outbound;
  activeMemberCode?: string;
  isInteractiveSelector: boolean;
  hasUrlTest: boolean;
  hasPriority: boolean;
} {
  const meta = engineMeta || resolveSectionEngineMeta(section);
  const selectedOutbound = (section.outbounds || []).find((o) => o.selected);
  const hasUrlTest = Boolean(selectedOutbound?.urlTestInfo);
  const hasPriority = Boolean(selectedOutbound?.priorityInfo);
  const isInteractiveSelector = hasUrlTest || hasPriority;

  let serverName = tr('Ожидание', 'Standby');
  let selectorLabel = tr('Ручной выбор', 'Manual');
  let latencyMs = selectedOutbound?.latency;
  let activeMemberCode: string | undefined;

  if (meta.isDpiOnly && meta.dpiServerLabel) {
    serverName = meta.dpiServerLabel;
    selectorLabel = meta.dpiSelectorLabel || 'DPI Bypass';
    activeMemberCode = selectedOutbound?.code;
    return {
      serverName,
      selectorLabel,
      latencyMs: undefined,
      selectedOutbound,
      activeMemberCode,
      isInteractiveSelector: false,
      hasUrlTest: false,
      hasPriority: false,
    };
  }

  if (selectedOutbound) {
    if (isInteractiveSelector) {
      const info =
        selectedOutbound.urlTestInfo || selectedOutbound.priorityInfo;
      const modeTag = hasUrlTest ? 'URLTest' : 'Priority';
      selectorLabel = selectedOutbound.displayName.includes(modeTag)
        ? selectedOutbound.displayName
        : `${selectedOutbound.displayName} (${modeTag})`;

      const rawMemberName =
        info?.selectedName ||
        info?.outbounds?.find(
          (m) =>
            m.selected || (info.selectedCode && m.code === info.selectedCode),
        )?.displayName ||
        '';
      activeMemberCode =
        info?.selectedCode ||
        info?.outbounds?.find(
          (m) =>
            m.selected || (rawMemberName && m.displayName === rawMemberName),
        )?.code;

      const matchedNode = (section.outbounds || []).find(
        (o) =>
          (activeMemberCode && o.code === activeMemberCode) ||
          (rawMemberName && o.displayName === rawMemberName),
      );

      if (rawMemberName) {
        serverName = ensureOutboundDisplayFlag({
          displayName: rawMemberName,
          country: matchedNode?.country,
          prefix: matchedNode?.prefix,
        });
      } else {
        serverName = selectedOutbound.displayName;
      }

      if (!latencyMs || latencyMs <= 0) {
        const member = info?.outbounds?.find(
          (m) =>
            m.selected ||
            (info.selectedCode && m.code === info.selectedCode) ||
            (rawMemberName && m.displayName === rawMemberName),
        );
        if (member?.latency) {
          latencyMs = member.latency;
        } else if (matchedNode?.latency) {
          latencyMs = matchedNode.latency;
        }
      }
    } else {
      serverName = ensureOutboundDisplayFlag(selectedOutbound);
      selectorLabel = tr('Ручной выбор', 'Manual');
      activeMemberCode = selectedOutbound.code;
    }
  } else if (section.serviceStatus) {
    const st = section.serviceStatus.serviceType || section.action || 'DPI';
    serverName = st.toUpperCase();
    selectorLabel = 'DPI Bypass';
  }

  return {
    serverName,
    selectorLabel,
    latencyMs,
    selectedOutbound,
    activeMemberCode,
    isInteractiveSelector,
    hasUrlTest,
    hasPriority,
  };
}

export function renderDashboardSectionsAndNodes(
  props: RenderDashboardSectionsAndNodesProps,
): HTMLElement[] {
  const {
    sections,
    selectedSectionCode,
    onSelectSection,
    getSectionStats,
    isTestingAllSections,
    onTestAllSections,
    latencyFetchingSections,
    onTestSectionLatency,
    onShowUrlTestInfo,
    onShowPriorityInfo,
  } = props;

  if (!sections || sections.length === 0) {
    return [];
  }

  const sectionsViewMode = getWidgetViewMode('routing_sections') || 'rows';

  // Separate proxy sections (which have selectable outbounds) and service-only sections
  const nonProxyActions = new Set([
    'zapret',
    'zapret2',
    'byedpi',
    'desync',
    'wdtt',
    'olcrtc',
    'block',
    'reject',
    'bypass',
    'direct',
    'dns',
  ]);
  const proxySections = sections.filter(
    (s) =>
      s.outbounds &&
      s.outbounds.length > 0 &&
      !nonProxyActions.has((s.action || '').toLowerCase()) &&
      !s.serviceStatus &&
      !resolveSectionEngineMeta(s).isDpiOnly,
  );

  const sectionItems = sections.map((section) => {
    const visual = getSectionVisualMeta(section);
    const engineMeta = resolveSectionEngineMeta(section);
    const stats = getSectionStats(section);
    const activeInfo = resolveSectionActiveInfo(section, engineMeta);
    const isRowSelected = Boolean(
      selectedSectionCode &&
        (section.code === selectedSectionCode ||
          section.sectionName === selectedSectionCode),
    );
    const isLatencyFetching = Boolean(
      latencyFetchingSections[section.sectionName],
    );

    const isServiceNode = Boolean(
      engineMeta.isDpiOnly ||
        section.serviceStatus ||
        nonProxyActions.has((section.action || '').toLowerCase()),
    );
    const hideTrafficAndConns =
      ['block', 'reject', 'bypass', 'direct', 'dns'].includes(
        engineMeta.primaryEngine,
      ) ||
      ['block', 'reject', 'bypass', 'direct', 'dns'].includes(
        (section.action || '').toLowerCase(),
      );
    const isHealthy = isServiceNode
      ? section.serviceStatus
        ? Boolean(section.serviceStatus.ready)
        : true
      : !section.configError;

    const totalSectionTraffic = (stats.download || 0) + (stats.upload || 0);
    const latencyMs = activeInfo.latencyMs;

    const showStatusLedOnly = isServiceNode;

    const latencyPillClass = showStatusLedOnly
      ? `tachyon-routing-row__ping tachyon-routing-row__ping--led ${
          isHealthy ? 'is-online' : 'is-offline'
        }`
      : latencyMs && latencyMs > 0
        ? latencyMs <= 150
          ? 'tachyon-routing-row__ping tachyon-routing-row__ping--fast'
          : latencyMs <= 350
            ? 'tachyon-routing-row__ping tachyon-routing-row__ping--medium'
            : 'tachyon-routing-row__ping tachyon-routing-row__ping--slow'
        : latencyMs === -1
          ? 'tachyon-routing-row__ping tachyon-routing-row__ping--slow'
          : 'tachyon-routing-row__ping tachyon-routing-row__ping--neutral';

    const latencyContent = showStatusLedOnly
      ? [
          E('span', {
            class: `tachyon-routing-row__status-dot ${
              isHealthy ? 'is-online' : 'is-offline'
            }`,
          }),
        ]
      : [
          isLatencyFetching
            ? tr('Проверка...', 'Checking...')
            : latencyMs && latencyMs > 0
              ? `● ${latencyMs} ms`
              : latencyMs === -1
                ? `● ${tr('Не отвечает', 'Offline')}`
                : '● —',
        ];

    const subtitleText = engineMeta.dpiSubtitlePrefix
      ? `${engineMeta.dpiSubtitlePrefix} • ${visual.subtitle}`
      : section.serviceStatus?.statusMessage &&
          section.serviceStatus.statusMessage !== _('Running') &&
          section.serviceStatus.statusMessage !== 'Запущен'
        ? formatServiceStatusMessage(section.serviceStatus.statusMessage)
        : visual.subtitle;

    const statusIndicatorNode = isHealthy
      ? E('span', {
          class: 'tachyon-routing-row__status-dot is-online',
          title: tr('Работает', 'Running'),
        })
      : E(
          'span',
          {
            class: 'tachyon-routing-row__status-badge is-error',
            title: section.configError || tr('Ошибка', 'Error'),
          },
          `● ${tr('Ошибка', 'Error')}`,
        );

    const badgeNodes = engineMeta.engineBadges.map((b) =>
      E(
        'span',
        {
          class: `tachyon-routing-row__engine-badge tachyon-routing-row__engine-badge--${b.kind}`,
          title: b.title || b.label,
        },
        b.icon ? [b.icon(), E('span', {}, b.label)] : b.label,
      ),
    );

    const iconBoxNode = E(
      'div',
      {
        class: 'tachyon-routing-row__icon is-clickable',
        'data-section-icon-box': section.sectionName || section.code,
        style: `background: ${visual.bg}; color: ${visual.color};`,
        title: tr(
          'Нажмите, чтобы выбрать сайт для иконки (favicon.ico)',
          'Click to choose website for section icon (favicon.ico)',
        ),
        click: (ev: MouseEvent) => {
          ev.preventDefault();
          ev.stopPropagation();
          openSectionIconPickerModal(section);
        },
      } as any,
      [createSectionIconContent(section, visual)],
    );

    const latencyBtnNode = E(
      'button',
      {
        type: 'button',
        class: latencyPillClass,
        'data-row-metric': 'latency',
        title: showStatusLedOnly
          ? isHealthy
            ? tr('Работает', 'Running')
            : tr('Остановлен', 'Stopped')
          : tr(
              'Нажмите для проверки задержки секции',
              'Click to test section latency',
            ),
        click: (ev: MouseEvent) => {
          ev.preventDefault();
          ev.stopPropagation();
          if (!isServiceNode && !isLatencyFetching) {
            onTestSectionLatency(section);
          } else {
            onSelectSection(section.code);
          }
        },
      } as any,
      latencyContent,
    );

    if (sectionsViewMode === 'protocol_matrix') {
      return E(
        'div',
        {
          class: [
            'tachyon-routing-matrix-card',
            isRowSelected ? 'is-selected' : '',
            section.configError ? 'has-error' : '',
          ]
            .filter(Boolean)
            .join(' '),
          'data-section-row-metrics': section.sectionName,
          click: (ev: MouseEvent) => {
            if (
              (ev.target as HTMLElement | null)?.closest(
                'button, a, [data-section-icon-box]',
              )
            ) {
              return;
            }
            onSelectSection(section.code);
          },
        } as any,
        [
          E('div', { class: 'tachyon-routing-matrix-card__left' }, [
            iconBoxNode,
            E('div', { class: 'tachyon-routing-matrix-card__info' }, [
              E('div', { class: 'tachyon-routing-row__title-line' }, [
                E(
                  'span',
                  { class: 'tachyon-routing-row__name' },
                  section.displayName,
                ),
                statusIndicatorNode,
                ...badgeNodes,
              ]),
              E('div', { class: 'tachyon-routing-matrix-card__node' }, [
                ...renderFlagEmojis(activeInfo.serverName),
                E('span', { class: 'tachyon-routing-matrix-card__sep' }, '•'),
                E(
                  'span',
                  { class: 'tachyon-routing-matrix-card__sel' },
                  activeInfo.selectorLabel,
                ),
              ]),
            ]),
          ]),
          E('div', { class: 'tachyon-routing-matrix-card__right' }, [
            ...(hideTrafficAndConns
              ? []
              : [
                  E('div', { class: 'tachyon-routing-matrix-card__stats' }, [
                    E(
                      'strong',
                      {
                        class: 'tachyon-routing-matrix-card__traffic',
                        'data-row-metric': 'session-total',
                      } as any,
                      prettyBytes(totalSectionTraffic),
                    ),
                    E('span', { class: 'tachyon-routing-matrix-card__conns' }, [
                      E(
                        'span',
                        { 'data-row-metric': 'conns' } as any,
                        String(stats.conns),
                      ),
                      ` ${tr('соед.', 'conns')}`,
                    ]),
                  ]),
                ]),
            latencyBtnNode,
          ]),
        ],
      );
    }

    if (sectionsViewMode === 'compact_tiles') {
      return E(
        'div',
        {
          class: [
            'tachyon-routing-compact-tile',
            isRowSelected ? 'is-selected' : '',
            section.configError ? 'has-error' : '',
          ]
            .filter(Boolean)
            .join(' '),
          'data-section-row-metrics': section.sectionName,
          click: (ev: MouseEvent) => {
            if (
              (ev.target as HTMLElement | null)?.closest(
                'button, a, [data-section-icon-box]',
              )
            ) {
              return;
            }
            onSelectSection(section.code);
          },
        } as any,
        [
          E('div', { class: 'tachyon-routing-compact-tile__top' }, [
            iconBoxNode,
            E('div', { class: 'tachyon-routing-compact-tile__titles' }, [
              E('div', { class: 'tachyon-routing-row__title-line' }, [
                E(
                  'span',
                  { class: 'tachyon-routing-row__name' },
                  section.displayName,
                ),
                statusIndicatorNode,
              ]),
              E(
                'div',
                { class: 'tachyon-routing-compact-tile__badges' },
                badgeNodes,
              ),
            ]),
            latencyBtnNode,
          ]),
          E('div', { class: 'tachyon-routing-compact-tile__bottom' }, [
            E(
              'span',
              {
                class: 'tachyon-routing-compact-tile__server',
                title: activeInfo.serverName,
              },
              renderFlagEmojis(activeInfo.serverName),
            ),
            ...(hideTrafficAndConns
              ? []
              : [
                  E(
                    'span',
                    {
                      class: 'tachyon-routing-compact-tile__stat',
                      'data-row-metric': 'session-total',
                    } as any,
                    prettyBytes(totalSectionTraffic),
                  ),
                ]),
          ]),
        ],
      );
    }

    if (sectionsViewMode === 'cards_grid') {
      return E(
        'div',
        {
          class: [
            'tachyon-routing-bento-card',
            isRowSelected ? 'is-selected' : '',
            section.configError ? 'has-error' : '',
          ]
            .filter(Boolean)
            .join(' '),
          'data-section-row-metrics': section.sectionName,
          click: (ev: MouseEvent) => {
            if (
              (ev.target as HTMLElement | null)?.closest(
                'button, a, [data-section-icon-box]',
              )
            ) {
              return;
            }
            onSelectSection(section.code);
          },
        } as any,
        [
          E('div', { class: 'tachyon-routing-bento-card__head' }, [
            iconBoxNode,
            E('div', { class: 'tachyon-routing-bento-card__head-main' }, [
              E('div', { class: 'tachyon-routing-row__title-line' }, [
                E(
                  'span',
                  { class: 'tachyon-routing-row__name' },
                  section.displayName,
                ),
                statusIndicatorNode,
                ...badgeNodes,
              ]),
              E(
                'div',
                { class: 'tachyon-routing-row__subtitle' },
                subtitleText,
              ),
            ]),
            latencyBtnNode,
          ]),
          E('div', { class: 'tachyon-routing-bento-card__body' }, [
            E('div', { class: 'tachyon-routing-bento-card__field' }, [
              E(
                'span',
                { class: 'tachyon-routing-row__col-label' },
                engineMeta.col2Label ||
                  (engineMeta.isDpiOnly
                    ? tr('Движок', 'Engine')
                    : tr('Сервер', 'Server')),
              ),
              E(
                'span',
                {
                  class: 'tachyon-routing-row__col-value',
                  title: activeInfo.serverName,
                },
                renderFlagEmojis(activeInfo.serverName),
              ),
            ]),
            E('div', { class: 'tachyon-routing-bento-card__field' }, [
              E(
                'span',
                { class: 'tachyon-routing-row__col-label' },
                engineMeta.col3Label ||
                  (engineMeta.isDpiOnly
                    ? tr('Стратегия', 'Strategy')
                    : tr('Селектор', 'Selector')),
              ),
              E(
                'span',
                {
                  class: 'tachyon-routing-row__col-value',
                  title: activeInfo.selectorLabel,
                },
                activeInfo.selectorLabel,
              ),
            ]),
          ]),
          ...(hideTrafficAndConns
            ? []
            : [
                E('div', { class: 'tachyon-routing-bento-card__foot' }, [
                  E('span', { class: 'tachyon-routing-bento-card__metric' }, [
                    E('span', { class: 'tachyon-routing-row__col-label' }, [
                      `${tr('Трафик', 'Traffic')}: `,
                    ]),
                    E(
                      'strong',
                      { 'data-row-metric': 'session-total' } as any,
                      prettyBytes(totalSectionTraffic),
                    ),
                  ]),
                  E('span', { class: 'tachyon-routing-bento-card__metric' }, [
                    E('span', { class: 'tachyon-routing-row__col-label' }, [
                      `${tr('Соед.', 'Conns')}: `,
                    ]),
                    E(
                      'strong',
                      { 'data-row-metric': 'conns' } as any,
                      String(stats.conns),
                    ),
                  ]),
                ]),
              ]),
        ],
      );
    }

    return E(
      'div',
      {
        class: [
          'tachyon-routing-row',
          hideTrafficAndConns ? 'tachyon-routing-row--no-traffic' : '',
          isRowSelected ? 'is-selected' : '',
          section.configError ? 'has-error' : '',
        ]
          .filter(Boolean)
          .join(' '),
        'data-section-row-metrics': section.sectionName,
        title: tr(
          'Нажмите, чтобы открыть узлы, балансировщики и условия секции',
          'Click to open section nodes, balancers and conditions',
        ),
        click: (ev: MouseEvent) => {
          if (
            (ev.target as HTMLElement | null)?.closest(
              'button, a, [data-section-icon-box]',
            )
          ) {
            return;
          }
          onSelectSection(section.code);
        },
      } as any,
      [
        // Col 1: Service Icon (favicon.ico or SVG) + Name + Status Dot + Protocol/Transport Badges + Subtitle
        E('div', { class: 'tachyon-routing-row__identity' }, [
          iconBoxNode,
          E('div', { class: 'tachyon-routing-row__titles' }, [
            E('div', { class: 'tachyon-routing-row__title-line' }, [
              E(
                'span',
                { class: 'tachyon-routing-row__name' },
                section.displayName,
              ),
              statusIndicatorNode,
              ...badgeNodes,
              ...(section.configError
                ? [
                    E(
                      'span',
                      {
                        class:
                          'tachyon_dashboard-page__outbound-section__config-error-badge',
                        title: section.configError,
                      },
                      tr('Есть ошибки', 'Has errors'),
                    ),
                  ]
                : []),
            ]),
            E('div', { class: 'tachyon-routing-row__subtitle' }, subtitleText),
          ]),
        ]),

        // Col 2: Сервер / Движок / Действие / Маршрут / DNS-сервер
        E('div', { class: 'tachyon-routing-row__col' }, [
          E(
            'span',
            { class: 'tachyon-routing-row__col-label' },
            engineMeta.col2Label ||
              (engineMeta.isDpiOnly
                ? tr('Движок', 'Engine')
                : tr('Сервер', 'Server')),
          ),
          E(
            'span',
            {
              class: 'tachyon-routing-row__col-value',
              title: activeInfo.serverName,
            },
            renderFlagEmojis(activeInfo.serverName),
          ),
        ]),

        // Col 3: Селектор / Стратегия / Правило / Режим / Протокол
        E('div', { class: 'tachyon-routing-row__col' }, [
          E(
            'span',
            { class: 'tachyon-routing-row__col-label' },
            engineMeta.col3Label ||
              (engineMeta.isDpiOnly
                ? tr('Стратегия', 'Strategy')
                : tr('Селектор', 'Selector')),
          ),
          E(
            activeInfo.isInteractiveSelector ? 'button' : 'span',
            {
              ...(activeInfo.isInteractiveSelector ? { type: 'button' } : {}),
              class: `tachyon-routing-row__selector-pill ${
                activeInfo.isInteractiveSelector ? 'is-interactive' : ''
              }`,
              title: activeInfo.isInteractiveSelector
                ? tr(
                    'Нажмите для просмотра деталей автовыбора',
                    'Click to inspect auto-selection details',
                  )
                : activeInfo.selectorLabel,
              click: activeInfo.isInteractiveSelector
                ? (ev: MouseEvent) => {
                    ev.preventDefault();
                    ev.stopPropagation();
                    if (!activeInfo.selectedOutbound) return;
                    if (activeInfo.hasUrlTest) {
                      onShowUrlTestInfo(section, activeInfo.selectedOutbound);
                    } else if (activeInfo.hasPriority) {
                      onShowPriorityInfo(section, activeInfo.selectedOutbound);
                    }
                  }
                : undefined,
            } as any,
            [
              E('span', {}, activeInfo.selectorLabel),
              ...(activeInfo.isInteractiveSelector ? [renderInfoIcon24()] : []),
            ],
          ),
        ]),

        // Col 4 & Col 5: Трафик за сессию и Соединения (скрываются для block / bypass / dns)
        ...(hideTrafficAndConns
          ? [
              E('div', {
                class:
                  'tachyon-routing-row__col tachyon-routing-row__col--empty',
              }),
              E('div', {
                class:
                  'tachyon-routing-row__col tachyon-routing-row__col--empty',
              }),
            ]
          : [
              E(
                'div',
                {
                  class:
                    'tachyon-routing-row__col tachyon-routing-row__col--num',
                  title: `↓ ${prettyBytes(stats.download || 0)} • ↑ ${prettyBytes(stats.upload || 0)}`,
                },
                [
                  E(
                    'span',
                    { class: 'tachyon-routing-row__col-label' },
                    tr('Трафик', 'Traffic'),
                  ),
                  E(
                    'span',
                    {
                      class: 'tachyon-routing-row__col-value',
                      'data-row-metric': 'session-total',
                    } as any,
                    prettyBytes(totalSectionTraffic),
                  ),
                  E(
                    'span',
                    {
                      style: 'display:none;',
                      'data-row-metric': 'session-down',
                    } as any,
                    `↓ ${prettyBytes(stats.download || 0)}`,
                  ),
                  E(
                    'span',
                    {
                      style: 'display:none;',
                      'data-row-metric': 'session-up',
                    } as any,
                    `↑ ${prettyBytes(stats.upload || 0)}`,
                  ),
                ],
              ),
              E(
                'div',
                {
                  class:
                    'tachyon-routing-row__col tachyon-routing-row__col--num',
                },
                [
                  E(
                    'span',
                    { class: 'tachyon-routing-row__col-label' },
                    tr('Соед.', 'Conns'),
                  ),
                  E(
                    'span',
                    {
                      class: 'tachyon-routing-row__col-value',
                      'data-row-metric': 'conns',
                    } as any,
                    String(stats.conns),
                  ),
                ],
              ),
            ]),

        // Col 6: Latency Pill or Green Status Dot + Chevron
        E('div', { class: 'tachyon-routing-row__right' }, [
          latencyBtnNode,
          E(
            'span',
            {
              class: `tachyon-routing-row__chevron ${
                isRowSelected ? 'is-selected' : ''
              }`,
            },
            '›',
          ),
        ]),
      ],
    );
  });

  const listClass =
    sectionsViewMode === 'cards_grid'
      ? 'tachyon-routing-sections-list tachyon-routing-sections-list--cards'
      : sectionsViewMode === 'compact_tiles'
        ? 'tachyon-routing-sections-list tachyon-routing-sections-list--tiles'
        : sectionsViewMode === 'protocol_matrix'
          ? 'tachyon-routing-sections-list tachyon-routing-sections-list--matrix'
          : 'tachyon-routing-sections-list';

  const sectionsBlock = E('div', { class: 'tachyon-routing-sections-block' }, [
    E('div', { class: 'tachyon-routing-sections-block__header' }, [
      E(
        'h3',
        { class: 'tachyon-routing-sections-block__title' },
        tr('Секции маршрутизации', 'Routing sections'),
      ),
      proxySections.length > 0
        ? E(
            'button',
            {
              type: 'button',
              id: 'dashboard-test-all-sections-button',
              class: 'tachyon-routing-sections-block__test-all-btn',
              disabled: isTestingAllSections ? true : undefined,
              click: () => {
                onTestAllSections();
              },
            } as any,
            isTestingAllSections
              ? [
                  renderLoaderCircleIcon24(),
                  E(
                    'span',
                    {},
                    tr('Проверка всех секций...', 'Testing all sections...'),
                  ),
                ]
              : [
                  E('span', {}, '↻'),
                  E(
                    'span',
                    {},
                    tr('Проверить все секции', 'Test all sections'),
                  ),
                ],
          )
        : '',
    ]),
    E('div', { class: listClass }, sectionItems),
  ]);

  return [sectionsBlock];
}

export function renderSectionConditionsAndBalancersView(
  section: Tachyon.OutboundGroup,
  callbacks: {
    onShowUrlTestInfo: (
      sec: Tachyon.OutboundGroup,
      ob: Tachyon.Outbound,
    ) => void;
    onShowPriorityInfo: (
      sec: Tachyon.OutboundGroup,
      ob: Tachyon.Outbound,
    ) => void;
    onChooseOutbound: (
      sectionName: string,
      selector: string,
      tag: string,
    ) => void;
  },
): HTMLElement {
  const g = globalThis as any;
  const uciObj = (typeof uci !== 'undefined' && uci) || g.uci || g.L?.uci;
  const secId = section.sectionName;

  const uciGet = (sec: string, opt: string): any => {
    try {
      return uciObj?.get?.('tachyon', sec, opt);
    } catch {
      return undefined;
    }
  };
  const uciSections = (type: string): any[] => {
    try {
      return uciObj?.sections?.('tachyon', type) || [];
    } catch {
      return [];
    }
  };

  // 1. Balancers (from runtime outbounds + UCI balancer_refs)
  const autoGroups = (section.outbounds || []).filter((o) =>
    Boolean(o.urlTestInfo || o.priorityInfo),
  );
  const allUciBalancers = uciSections('balancer');
  const balancerRefs = toStringArray(uciGet(secId, 'balancer_refs'));

  const balancerCards: HTMLElement[] = [];
  if (autoGroups.length > 0) {
    for (const ag of autoGroups) {
      const info = ag.urlTestInfo || ag.priorityInfo;
      const isUrlTest = Boolean(ag.urlTestInfo);
      const isSelected = Boolean(ag.selected);
      const selectedServer =
        info?.selectedName ||
        info?.outbounds?.find((m) => m.selected)?.displayName ||
        '—';
      const membersCount = info?.outbounds?.length || 0;

      balancerCards.push(
        E(
          'div',
          {
            class: `tachyon-sec-modal__card ${isSelected ? 'is-active' : ''}`,
          },
          [
            E('div', { class: 'tachyon-sec-modal__card-head' }, [
              E('div', { class: 'tachyon-sec-modal__card-title-row' }, [
                E(
                  'span',
                  { class: 'tachyon-sec-modal__badge-type' },
                  isUrlTest
                    ? [renderZapIcon(11), E('span', {}, 'URLTest')]
                    : [renderShieldIcon(11), E('span', {}, 'Priority')],
                ),
                E(
                  'strong',
                  { class: 'tachyon-sec-modal__card-title' },
                  ag.displayName,
                ),
                ...(isSelected
                  ? [
                      E('span', { class: 'tachyon-sec-modal__badge-active' }, [
                        renderCheckIcon(12),
                        E('span', {}, tr('Активен', 'Active')),
                      ]),
                    ]
                  : []),
              ]),
              E('div', { class: 'tachyon-sec-modal__card-actions' }, [
                ...(!isSelected && section.withTagSelect
                  ? [
                      E(
                        'button',
                        {
                          type: 'button',
                          class: 'btn cbi-button cbi-button-apply',
                          style: 'padding: 3px 10px; font-size: 12px;',
                          click: () => {
                            callbacks.onChooseOutbound(
                              section.sectionName,
                              section.code,
                              ag.code,
                            );
                          },
                        } as any,
                        tr('Выбрать', 'Select'),
                      ),
                    ]
                  : []),
                E(
                  'button',
                  {
                    type: 'button',
                    class: 'btn cbi-button cbi-button-neutral',
                    style: 'padding: 3px 10px; font-size: 12px;',
                    click: () => {
                      if (ag.urlTestInfo) {
                        callbacks.onShowUrlTestInfo(section, ag);
                      } else if (ag.priorityInfo) {
                        callbacks.onShowPriorityInfo(section, ag);
                      }
                    },
                  } as any,
                  tr('Детали и узлы →', 'Details & Nodes →'),
                ),
              ]),
            ]),
            E('div', { class: 'tachyon-sec-modal__facts' }, [
              E('span', { class: 'tachyon-sec-modal__fact' }, [
                E('span', { class: 'tachyon-sec-modal__fact-k' }, [
                  `${tr('Выбранный узел', 'Selected node')}: `,
                ]),
                E(
                  'strong',
                  {},
                  renderFlagEmojis(
                    ensureOutboundDisplayFlag({ displayName: selectedServer }),
                  ),
                ),
              ]),
              E('span', { class: 'tachyon-sec-modal__fact' }, [
                E('span', { class: 'tachyon-sec-modal__fact-k' }, [
                  `${tr('Узлов в группе', 'Group nodes')}: `,
                ]),
                E('strong', {}, String(membersCount)),
              ]),
              ...(ag.urlTestInfo?.interval
                ? [
                    E('span', { class: 'tachyon-sec-modal__fact' }, [
                      E('span', { class: 'tachyon-sec-modal__fact-k' }, [
                        `${tr('Интервал', 'Interval')}: `,
                      ]),
                      E('strong', {}, String(ag.urlTestInfo.interval)),
                    ]),
                  ]
                : []),
              ...(ag.urlTestInfo?.tolerance !== undefined
                ? [
                    E('span', { class: 'tachyon-sec-modal__fact' }, [
                      E('span', { class: 'tachyon-sec-modal__fact-k' }, [
                        `${tr('Допуск', 'Tolerance')}: `,
                      ]),
                      E('strong', {}, `${ag.urlTestInfo.tolerance} ms`),
                    ]),
                  ]
                : []),
            ]),
          ],
        ),
      );
    }
  } else if (balancerRefs.length > 0) {
    for (const bid of balancerRefs) {
      const b = allUciBalancers.find((x) => x['.name'] === bid);
      const bName = b?.name || bid;
      const bType = b?.balancer_type === 'priority' ? 'Priority' : 'URLTest';
      balancerCards.push(
        E('div', { class: 'tachyon-sec-modal__card' }, [
          E('div', { class: 'tachyon-sec-modal__card-head' }, [
            E('div', { class: 'tachyon-sec-modal__card-title-row' }, [
              E('span', { class: 'tachyon-sec-modal__badge-type' }, bType),
              E('strong', { class: 'tachyon-sec-modal__card-title' }, bName),
            ]),
            E('div', { class: 'tachyon-sec-modal__card-actions' }, [
              E(
                'button',
                {
                  type: 'button',
                  class: 'btn cbi-button cbi-button-neutral',
                  style: 'padding: 3px 10px; font-size: 12px;',
                  click: () => {
                    const openEntity = (globalThis as any)
                      .__tachyonOpenEntityModal;
                    if (typeof openEntity === 'function') {
                      openEntity('balancer', bid, 'balancers');
                    }
                  },
                } as any,
                [
                  renderSettingsIcon(12),
                  E('span', {}, `${tr('Изменить', 'Edit')} →`),
                ],
              ),
            ]),
          ]),
        ]),
      );
    }
  }

  // 2. Conditions & Routing Rules (from UCI condition_refs + direct section options)
  const allConditions = uciSections('condition');
  const condRefs = toStringArray(uciGet(secId, 'condition_refs'));
  const conditionCards: HTMLElement[] = [];

  for (const rawRef of condRefs) {
    const isNegated = rawRef.startsWith('!');
    const cleanId = isNegated ? rawRef.slice(1) : rawRef;
    const cond = allConditions.find((c) => c['.name'] === cleanId);
    const cName = cond?.name || cond?.label || cleanId;
    const cType = cond?.condition_type || cond?.type || 'rule';
    const cOp = (cond?.operator || cond?.mode || 'OR').toUpperCase();

    const values: string[] = Array.from(
      new Set([
        ...toStringArray(
          cond?.community_lists || cond?.domain_list || cond?.domain_lists,
        ).map((v) => `List:${v}`),
        ...toStringArray(
          cond?.domain_suffix ||
            cond?.domain ||
            cond?.domains ||
            cond?.user_domains,
        ),
        ...toStringArray(cond?.geosite || cond?.geosite_categories).map(
          (v) => `GeoSite:${v}`,
        ),
        ...toStringArray(
          cond?.geoip_country || cond?.geoip || cond?.geoip_countries,
        ).map((v) => `GeoIP:${v}`),
        ...toStringArray(cond?.rule_set || cond?.domain_ip_lists).map(
          (v) => `RuleSet:${v}`,
        ),
        ...toStringArray(cond?.ip_cidr || cond?.subnets || cond?.user_subnets),
        ...toStringArray(
          cond?.source_ip_cidr || cond?.local_ips || cond?.clients,
        ).map((v) => `Client:${v}`),
        ...toStringArray(cond?.source_macs).map((v) => `MAC:${v}`),
        ...toStringArray(cond?.dest_ports || cond?.ports).map(
          (v) => `Port:${v}`,
        ),
        ...toStringArray(cond?.members).map((v) => `Member:${v}`),
      ]),
    );

    conditionCards.push(
      E('div', { class: 'tachyon-sec-modal__card' }, [
        E('div', { class: 'tachyon-sec-modal__card-head' }, [
          E('div', { class: 'tachyon-sec-modal__card-title-row' }, [
            ...(isNegated
              ? [
                  E(
                    'span',
                    {
                      class:
                        'tachyon-sec-modal__badge-type tachyon-sec-modal__badge-type--neg',
                    },
                    'NOT (!)',
                  ),
                ]
              : []),
            E('span', { class: 'tachyon-sec-modal__badge-type' }, cOp),
            E('strong', { class: 'tachyon-sec-modal__card-title' }, cName),
            E('span', { class: 'tachyon-sec-modal__fact-k' }, `(${cType})`),
          ]),
          E('div', { class: 'tachyon-sec-modal__card-actions' }, [
            E(
              'button',
              {
                type: 'button',
                class: 'btn cbi-button cbi-button-neutral',
                style: 'padding: 3px 10px; font-size: 12px;',
                click: () => {
                  const openEntity = (globalThis as any)
                    .__tachyonOpenEntityModal;
                  if (typeof openEntity === 'function') {
                    openEntity('condition', cleanId, 'conditions');
                  }
                },
              } as any,
              [
                renderSettingsIcon(12),
                E('span', {}, `${tr('Открыть условие', 'Open Condition')} →`),
              ],
            ),
          ]),
        ]),
        values.length > 0
          ? E(
              'div',
              { class: 'tachyon-sec-modal__chips' },
              values
                .slice(0, 40)
                .map((v) => E('span', { class: 'tachyon-sec-modal__chip' }, v))
                .concat(
                  values.length > 40
                    ? [
                        E(
                          'span',
                          { class: 'tachyon-sec-modal__chip' },
                          `+${values.length - 40}`,
                        ),
                      ]
                    : [],
                ),
            )
          : E(
              'div',
              { class: 'tachyon-sec-modal__empty-hint' },
              tr('Условие активно', 'Condition active'),
            ),
      ]),
    );
  }

  // Direct rules configured on the section itself
  const directRuleGroups: Array<{ label: string; items: string[] }> = [
    {
      label: tr('Сервисы и пресеты', 'Service Presets'),
      items: toStringArray(uciGet(secId, 'domain_list')),
    },
    {
      label: tr('Пользовательские домены', 'Custom Domains'),
      items: toStringArray(uciGet(secId, 'user_domains')),
    },
    {
      label: 'GeoSite',
      items: toStringArray(uciGet(secId, 'geosite_categories')),
    },
    {
      label: 'GeoIP',
      items: toStringArray(uciGet(secId, 'geoip_countries')),
    },
    {
      label: tr('Подсети / IP (CIDR)', 'Subnets / IP (CIDR)'),
      items: toStringArray(uciGet(secId, 'user_subnets')),
    },
    {
      label: tr('Локальные клиенты (LAN)', 'LAN Clients'),
      items: toStringArray(
        uciGet(secId, 'local_ips') || uciGet(secId, 'src_ips'),
      ),
    },
    {
      label: tr('Порты назначения', 'Destination Ports'),
      items: toStringArray(uciGet(secId, 'dest_ports')),
    },
  ].filter((g) => g.items.length > 0);

  for (const grp of directRuleGroups) {
    conditionCards.push(
      E('div', { class: 'tachyon-sec-modal__card' }, [
        E('div', { class: 'tachyon-sec-modal__card-head' }, [
          E('div', { class: 'tachyon-sec-modal__card-title-row' }, [
            E(
              'span',
              { class: 'tachyon-sec-modal__badge-type' },
              tr('Прямое правило', 'Direct Rule'),
            ),
            E('strong', { class: 'tachyon-sec-modal__card-title' }, grp.label),
            E(
              'span',
              { class: 'tachyon-sec-modal__fact-k' },
              `(${grp.items.length})`,
            ),
          ]),
        ]),
        E(
          'div',
          { class: 'tachyon-sec-modal__chips' },
          grp.items
            .slice(0, 40)
            .map((v) => E('span', { class: 'tachyon-sec-modal__chip' }, v))
            .concat(
              grp.items.length > 40
                ? [
                    E(
                      'span',
                      { class: 'tachyon-sec-modal__chip' },
                      `+${grp.items.length - 40}`,
                    ),
                  ]
                : [],
            ),
        ),
      ]),
    );
  }

  return E('div', { class: 'tachyon-sec-modal__conditions-pane' }, [
    E('div', { class: 'tachyon-sec-modal__group' }, [
      E(
        'h4',
        { class: 'tachyon-sec-modal__group-title' },
        tr(
          'Условия маршрутизации и правила фильтрации',
          'Routing Conditions & Traffic Rules',
        ),
      ),
      ...(conditionCards.length > 0
        ? conditionCards
        : [
            E(
              'div',
              { class: 'tachyon-sec-modal__card' },
              tr(
                'Для этой секции не заданы отдельные фильтры доменов — правило применяется ко всему подходящему трафику по приоритету секции.',
                'No specific domain filters are attached to this section — matches traffic by section priority.',
              ),
            ),
          ]),
    ]),
    E('div', { class: 'tachyon-sec-modal__group' }, [
      E(
        'h4',
        { class: 'tachyon-sec-modal__group-title' },
        tr(
          'Балансировщики и политики отказоустойчивости',
          'Balancers & Failover Policies',
        ),
      ),
      ...(balancerCards.length > 0
        ? balancerCards
        : [
            E(
              'div',
              { class: 'tachyon-sec-modal__card' },
              tr(
                'В этой секции используется прямой или ручной выбор узла (без групп URLTest / Priority).',
                'This section uses direct or manual node selection (no URLTest / Priority balancers attached).',
              ),
            ),
          ]),
    ]),
  ]);
}
