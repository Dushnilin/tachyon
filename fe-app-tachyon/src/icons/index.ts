import { svgEl } from '../helpers';

function createIcon(
  className: string,
  children: (SVGElement | null | undefined)[],
  extraAttrs: Partial<Record<string, string | number>> = {},
) {
  return svgEl(
    'svg',
    {
      xmlns: 'http://www.w3.org/2000/svg',
      viewBox: '0 0 24 24',
      fill: 'none',
      stroke: 'currentColor',
      'stroke-width': '2',
      'stroke-linecap': 'round',
      'stroke-linejoin': 'round',
      class: className,
      ...extraAttrs,
    },
    children,
  );
}

export function renderBookOpenTextIcon24() {
  return createIcon('lucide lucide-book-open-text-icon lucide-book-open-text', [
    svgEl('path', { d: 'M12 7v14' }),
    svgEl('path', { d: 'M16 12h2' }),
    svgEl('path', { d: 'M16 8h2' }),
    svgEl('path', {
      d: 'M3 18a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h5a4 4 0 0 1 4 4 4 4 0 0 1 4-4h5a1 1 0 0 1 1 1v13a1 1 0 0 1-1 1h-6a3 3 0 0 0-3 3 3 3 0 0 0-3-3z',
    }),
    svgEl('path', { d: 'M6 12h2' }),
    svgEl('path', { d: 'M6 8h2' }),
  ]);
}

export function renderCheckIcon24() {
  return createIcon('lucide lucide-check-icon lucide-check', [
    svgEl('path', { d: 'M20 6 9 17l-5-5' }),
  ]);
}

export function renderCircleAlertIcon24() {
  return createIcon(
    'lucide lucide-circle-alert-icon lucide-circle-alert',
    [
      svgEl('circle', { cx: '12', cy: '12', r: '10' }),
      svgEl('line', { x1: '12', y1: '8', x2: '12', y2: '12' }),
      svgEl('line', { x1: '12', y1: '16', x2: '12.01', y2: '16' }),
    ],
    { width: '24', height: '24' },
  );
}

export function renderCircleCheckBigIcon24() {
  return createIcon(
    'lucide lucide-circle-check-big-icon lucide-circle-check-big',
    [
      svgEl('path', { d: 'M21.801 10A10 10 0 1 1 17 3.335' }),
      svgEl('path', { d: 'm9 11 3 3L22 4' }),
    ],
  );
}

export function renderCircleCheckIcon24() {
  return createIcon(
    'lucide lucide-circle-check-icon lucide-circle-check',
    [
      svgEl('circle', { cx: '12', cy: '12', r: '10' }),
      svgEl('path', { d: 'M9 12l2 2 4-4' }),
    ],
    { width: '24', height: '24' },
  );
}

export function renderCirclePlayIcon24() {
  return createIcon('lucide lucide-circle-play-icon lucide-circle-play', [
    svgEl('path', {
      d: 'M9 9.003a1 1 0 0 1 1.517-.859l4.997 2.997a1 1 0 0 1 0 1.718l-4.997 2.997A1 1 0 0 1 9 14.996z',
    }),
    svgEl('circle', { cx: '12', cy: '12', r: '10' }),
  ]);
}

export function renderCircleSlashIcon24() {
  return createIcon(
    'lucide lucide-circle-slash-icon lucide-circle-slash',
    [
      svgEl('circle', { cx: '12', cy: '12', r: '10' }),
      svgEl('line', { x1: '9', y1: '15', x2: '15', y2: '9' }),
    ],
    { width: '24', height: '24' },
  );
}

export function renderCircleStopIcon24() {
  return createIcon('lucide lucide-circle-stop-icon lucide-circle-stop', [
    svgEl('circle', { cx: '12', cy: '12', r: '10' }),
    svgEl('rect', { x: '9', y: '9', width: '6', height: '6', rx: '1' }),
  ]);
}

export function renderCircleXIcon24() {
  return createIcon(
    'lucide lucide-circle-x-icon lucide-circle-x',
    [
      svgEl('circle', { cx: '12', cy: '12', r: '10' }),
      svgEl('path', { d: 'M15 9L9 15' }),
      svgEl('path', { d: 'M9 9L15 15' }),
    ],
    { width: '24', height: '24' },
  );
}

export function renderCogIcon24() {
  return createIcon('lucide lucide-cog-icon lucide-cog', [
    svgEl('path', { d: 'M11 10.27 7 3.34' }),
    svgEl('path', { d: 'm11 13.73-4 6.93' }),
    svgEl('path', { d: 'M12 22v-2' }),
    svgEl('path', { d: 'M12 2v2' }),
    svgEl('path', { d: 'M14 12h8' }),
    svgEl('path', { d: 'm17 20.66-1-1.73' }),
    svgEl('path', { d: 'm17 3.34-1 1.73' }),
    svgEl('path', { d: 'M2 12h2' }),
    svgEl('path', { d: 'm20.66 17-1.73-1' }),
    svgEl('path', { d: 'm20.66 7-1.73 1' }),
    svgEl('path', { d: 'm3.34 17 1.73-1' }),
    svgEl('path', { d: 'm3.34 7 1.73 1' }),
    svgEl('circle', { cx: '12', cy: '12', r: '2' }),
    svgEl('circle', { cx: '12', cy: '12', r: '8' }),
  ]);
}

export function renderCopyIcon24() {
  return createIcon(
    'lucide lucide-copy-icon lucide-copy',
    [
      svgEl('rect', {
        width: '14',
        height: '14',
        x: '8',
        y: '8',
        rx: '2',
        ry: '2',
      }),
      svgEl('path', {
        d: 'M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2',
      }),
    ],
    { width: '24', height: '24' },
  );
}

export function renderDownloadIcon24() {
  return createIcon('lucide lucide-download-icon lucide-download', [
    svgEl('path', { d: 'M12 15V3' }),
    svgEl('path', { d: 'M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4' }),
    svgEl('path', { d: 'm7 10 5 5 5-5' }),
  ]);
}

export function renderGlobeIcon24() {
  return createIcon(
    'lucide lucide-globe-icon lucide-globe',
    [
      svgEl('circle', { cx: '12', cy: '12', r: '10' }),
      svgEl('path', { d: 'M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20' }),
      svgEl('path', { d: 'M2 12h20' }),
    ],
    { width: '14', height: '14' },
  );
}

export function renderInfoIcon24() {
  return createIcon(
    'lucide lucide-info-icon lucide-info',
    [
      svgEl('circle', { cx: '12', cy: '12', r: '10' }),
      svgEl('path', { d: 'M12 16v-4' }),
      svgEl('path', { d: 'M12 8h.01' }),
    ],
    { width: '24', height: '24' },
  );
}

export function renderLinkIcon24() {
  return createIcon(
    'lucide lucide-link-icon lucide-link',
    [
      svgEl('path', {
        d: 'M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71',
      }),
      svgEl('path', {
        d: 'M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71',
      }),
    ],
    { width: '24', height: '24' },
  );
}

export function renderLoaderCircleIcon24() {
  return createIcon(
    'lucide lucide-loader-circle rotate',
    [
      svgEl('path', { d: 'M21 12a9 9 0 1 1-6.219-8.56' }),
      svgEl('animateTransform', {
        attributeName: 'transform',
        attributeType: 'XML',
        type: 'rotate',
        from: '0 12 12',
        to: '360 12 12',
        dur: '1s',
        repeatCount: 'indefinite',
      }),
    ],
    { width: '24', height: '24' },
  );
}

export function renderPauseIcon24() {
  return createIcon('lucide lucide-pause-icon lucide-pause', [
    svgEl('rect', { x: '14', y: '3', width: '5', height: '18', rx: '1' }),
    svgEl('rect', { x: '5', y: '3', width: '5', height: '18', rx: '1' }),
  ]);
}

export function renderPlayIcon24() {
  return createIcon('lucide lucide-play-icon lucide-play', [
    svgEl('path', {
      d: 'M5 5a2 2 0 0 1 3.008-1.728l11.997 6.998a2 2 0 0 1 .003 3.458l-12 7A2 2 0 0 1 5 19z',
    }),
  ]);
}

export function renderRotateCcwIcon24() {
  return createIcon('lucide lucide-rotate-ccw-icon lucide-rotate-ccw', [
    svgEl('path', { d: 'M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8' }),
    svgEl('path', { d: 'M3 3v5h5' }),
  ]);
}

export function renderSearchIcon24() {
  return createIcon('lucide lucide-search-icon lucide-search', [
    svgEl('path', { d: 'm21 21-4.34-4.34' }),
    svgEl('circle', { cx: '11', cy: '11', r: '8' }),
  ]);
}

export function renderSendIcon24() {
  return createIcon(
    'lucide lucide-send-icon lucide-send',
    [
      svgEl('path', {
        d: 'M14.536 21.686a.5.5 0 0 0 .937-.024l6.5-19a.496.496 0 0 0-.635-.635l-19 6.5a.5.5 0 0 0-.024.937l7.93 3.18a2 2 0 0 1 1.112 1.11z',
      }),
      svgEl('path', { d: 'm21.854 2.147-10.94 10.939' }),
    ],
    { width: '24', height: '24' },
  );
}

export function renderSquareChartGanttIcon24() {
  return createIcon(
    'lucide lucide-square-chart-gantt-icon lucide-square-chart-gantt',
    [
      svgEl('rect', { width: '18', height: '18', x: '3', y: '3', rx: '2' }),
      svgEl('path', { d: 'M9 8h7' }),
      svgEl('path', { d: 'M8 12h6' }),
      svgEl('path', { d: 'M11 16h5' }),
    ],
  );
}

export function renderTriangleAlertIcon24() {
  return createIcon('lucide lucide-triangle-alert-icon lucide-triangle-alert', [
    svgEl('path', {
      d: 'm21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3',
    }),
    svgEl('path', { d: 'M12 9v4' }),
    svgEl('path', { d: 'M12 17h.01' }),
  ]);
}

export function renderXIcon24() {
  return createIcon('lucide lucide-x-icon lucide-x', [
    svgEl('path', { d: 'M18 6 6 18' }),
    svgEl('path', { d: 'm6 6 12 12' }),
  ]);
}
