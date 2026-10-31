import { svgEl } from '../helpers';
export { renderTachyonLogoSvg, renderTachyonDuckMascotSvg } from './duckMascot';

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

export function renderFileTextIcon14() {
  return createIcon(
    'lucide lucide-file-text-icon lucide-file-text',
    [
      svgEl('path', {
        d: 'M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z',
      }),
      svgEl('path', { d: 'M14 2v4a2 2 0 0 0 2 2h4' }),
      svgEl('path', { d: 'M10 9H8' }),
      svgEl('path', { d: 'M16 13H8' }),
      svgEl('path', { d: 'M16 17H8' }),
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

export function renderLinkIcon(size = 14, className = '') {
  return createIcon(
    `lucide lucide-link-icon lucide-link ${className}`.trim(),
    [
      svgEl('path', {
        d: 'M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71',
      }),
      svgEl('path', {
        d: 'M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71',
      }),
    ],
    { width: size, height: size },
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

export function renderHeartIcon24() {
  return createIcon(
    'lucide lucide-heart-icon lucide-heart',
    [
      svgEl('path', {
        d: 'M19 14c1.49-1.46 3-3.21 3-5.5A5.5 5.5 0 0 0 16.5 3c-1.76 0-3 .5-4.5 2-1.5-1.5-2.74-2-4.5-2A5.5 5.5 0 0 0 2 8.5c0 2.3 1.5 4.05 3 5.5l7 7Z',
      }),
    ],
    { width: '24', height: '24' },
  );
}

export function renderZapIcon(size = 14, className = '') {
  return createIcon(
    `lucide lucide-zap-icon lucide-zap ${className}`.trim(),
    [svgEl('polygon', { points: '13 2 3 14 12 14 11 22 21 10 12 10 13 2' })],
    { width: size, height: size },
  );
}

export function renderShieldIcon(size = 14, className = '') {
  return createIcon(
    `lucide lucide-shield-icon lucide-shield ${className}`.trim(),
    [svgEl('path', { d: 'M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10' })],
    { width: size, height: size },
  );
}

export function renderFileTextIcon(size = 14, className = '') {
  return createIcon(
    `lucide lucide-file-text-icon lucide-file-text ${className}`.trim(),
    [
      svgEl('path', {
        d: 'M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z',
      }),
      svgEl('path', { d: 'M14 2v4a2 2 0 0 0 2 2h4' }),
      svgEl('path', { d: 'M10 9H8' }),
      svgEl('path', { d: 'M16 13H8' }),
      svgEl('path', { d: 'M16 17H8' }),
    ],
    { width: size, height: size },
  );
}

export function renderTrashIcon(size = 14, className = '') {
  return createIcon(
    `lucide lucide-trash-2-icon lucide-trash-2 ${className}`.trim(),
    [
      svgEl('path', { d: 'M3 6h18' }),
      svgEl('path', { d: 'M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6' }),
      svgEl('path', { d: 'M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2' }),
      svgEl('line', { x1: '10', x2: '10', y1: '11', y2: '17' }),
      svgEl('line', { x1: '14', x2: '14', y1: '11', y2: '17' }),
    ],
    { width: size, height: size },
  );
}

export function renderCopyIcon(size = 14, className = '') {
  return createIcon(
    `lucide lucide-copy-icon lucide-copy ${className}`.trim(),
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
    { width: size, height: size },
  );
}

export function renderSettingsIcon(size = 14, className = '') {
  return createIcon(
    `lucide lucide-settings-icon lucide-settings ${className}`.trim(),
    [
      svgEl('circle', { cx: '12', cy: '12', r: '3' }),
      svgEl('path', {
        d: 'M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z',
      }),
    ],
    { width: size, height: size },
  );
}

export function renderSlidersIcon(size = 14, className = '') {
  return createIcon(
    `lucide lucide-sliders-icon lucide-sliders ${className}`.trim(),
    [
      svgEl('line', { x1: '4', x2: '4', y1: '21', y2: '14' }),
      svgEl('line', { x1: '4', x2: '4', y1: '10', y2: '3' }),
      svgEl('line', { x1: '12', x2: '12', y1: '21', y2: '12' }),
      svgEl('line', { x1: '12', x2: '12', y1: '8', y2: '3' }),
      svgEl('line', { x1: '20', x2: '20', y1: '21', y2: '16' }),
      svgEl('line', { x1: '20', x2: '20', y1: '12', y2: '3' }),
      svgEl('line', { x1: '1', x2: '7', y1: '14', y2: '14' }),
      svgEl('line', { x1: '9', x2: '15', y1: '8', y2: '8' }),
      svgEl('line', { x1: '17', x2: '23', y1: '16', y2: '16' }),
    ],
    { width: size, height: size },
  );
}

export function renderTargetIcon(size = 12, className = '') {
  return createIcon(
    `lucide lucide-target-icon lucide-target ${className}`.trim(),
    [
      svgEl('circle', { cx: '12', cy: '12', r: '10' }),
      svgEl('circle', { cx: '12', cy: '12', r: '6' }),
      svgEl('circle', { cx: '12', cy: '12', r: '2' }),
    ],
    { width: size, height: size },
  );
}

export function renderRadioIcon(size = 14, className = '') {
  return createIcon(
    `lucide lucide-radio-icon lucide-radio ${className}`.trim(),
    [
      svgEl('path', { d: 'M4.9 19.1C1 15.2 1 8.8 4.9 4.9' }),
      svgEl('path', { d: 'M7.8 16.2c-2.3-2.3-2.3-6.1 0-8.5' }),
      svgEl('circle', { cx: '12', cy: '12', r: '2' }),
      svgEl('path', { d: 'M16.2 7.8c2.3 2.3 2.3 6.1 0 8.5' }),
      svgEl('path', { d: 'M19.1 4.9C23 8.8 23 15.1 19.1 19' }),
    ],
    { width: size, height: size },
  );
}

export function renderScaleIcon(size = 12, className = '') {
  return createIcon(
    `lucide lucide-scale-icon lucide-scale ${className}`.trim(),
    [
      svgEl('path', { d: 'm16 16 3-8 3 8c-.87.65-1.92 1-3 1s-2.13-.35-3-1Z' }),
      svgEl('path', { d: 'm2 16 3-8 3 8c-.87.65-1.92 1-3 1s-2.13-.35-3-1Z' }),
      svgEl('path', { d: 'M7 21h10' }),
      svgEl('path', { d: 'M12 3v18' }),
      svgEl('path', { d: 'M3 7h2c2 0 5-1 7-2 2 1 5 2 7 2h2' }),
    ],
    { width: size, height: size },
  );
}

export function renderFolderIcon(size = 14, className = '') {
  return createIcon(
    `lucide lucide-folder-icon lucide-folder ${className}`.trim(),
    [
      svgEl('path', {
        d: 'M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z',
      }),
    ],
    { width: size, height: size },
  );
}

export function renderPinIcon(size = 12, className = '') {
  return createIcon(
    `lucide lucide-pin-icon lucide-pin ${className}`.trim(),
    [
      svgEl('path', { d: 'M12 17v5' }),
      svgEl('path', {
        d: 'M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V7a1 1 0 0 1 1-1 2 2 0 0 0 0-4H8a2 2 0 0 0 0 4 1 1 0 0 1 1 1z',
      }),
    ],
    { width: size, height: size },
  );
}

export function renderSubRouteIcon(size = 12, className = '') {
  return createIcon(
    `lucide lucide-corner-down-right-icon lucide-corner-down-right ${className}`.trim(),
    [
      svgEl('polyline', { points: '15 10 20 15 15 20' }),
      svgEl('path', { d: 'M4 4v7a4 4 0 0 0 4 4h12' }),
    ],
    { width: size, height: size },
  );
}

export function renderClockIcon(size = 12, className = '') {
  return createIcon(
    `lucide lucide-clock-icon lucide-clock ${className}`.trim(),
    [
      svgEl('circle', { cx: '12', cy: '12', r: '10' }),
      svgEl('polyline', { points: '12 6 12 12 16 14' }),
    ],
    { width: size, height: size },
  );
}

export function renderBanIcon(size = 12, className = '') {
  return createIcon(
    `lucide lucide-ban-icon lucide-ban ${className}`.trim(),
    [
      svgEl('circle', { cx: '12', cy: '12', r: '10' }),
      svgEl('path', { d: 'm4.9 4.9 14.2 14.2' }),
    ],
    { width: size, height: size },
  );
}

export function renderGlobeIcon(size = 12, className = '') {
  return createIcon(
    `lucide lucide-globe-icon lucide-globe ${className}`.trim(),
    [
      svgEl('circle', { cx: '12', cy: '12', r: '10' }),
      svgEl('path', { d: 'M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20' }),
      svgEl('path', { d: 'M2 12h20' }),
    ],
    { width: size, height: size },
  );
}

export function renderWandIcon(size = 14, className = '') {
  return createIcon(
    `lucide lucide-wand-icon lucide-wand ${className}`.trim(),
    [
      svgEl('path', {
        d: 'm21.64 3.64-1.28-1.28a1.21 1.21 0 0 0-1.72 0L2.36 18.64a1.21 1.21 0 0 0 0 1.72l1.28 1.28a1.2 1.2 0 0 0 1.72 0L21.64 5.36a1.2 1.2 0 0 0 0-1.72',
      }),
      svgEl('path', { d: 'm14 7 3 3' }),
      svgEl('path', { d: 'M5 6v4' }),
      svgEl('path', { d: 'M19 14v4' }),
      svgEl('path', { d: 'M10 2v2' }),
      svgEl('path', { d: 'M7 8H3' }),
      svgEl('path', { d: 'M21 16h-4' }),
      svgEl('path', { d: 'M11 3H9' }),
    ],
    { width: size, height: size },
  );
}

export function renderRocketIcon(size = 14, className = '') {
  return createIcon(
    `lucide lucide-rocket-icon lucide-rocket ${className}`.trim(),
    [
      svgEl('path', {
        d: 'M4.5 16.5c-1.5 1.26-2 5-2 5s3.74-.5 5-2c.71-.84.7-2.13-.09-2.91a2.18 2.18 0 0 0-2.91-.09z',
      }),
      svgEl('path', {
        d: 'm12 15-3-3a22 22 0 0 1 2-3.95A12.88 12.88 0 0 1 22 2c0 2.72-.78 7.5-6 11a22.35 22.35 0 0 1-4 2z',
      }),
      svgEl('path', { d: 'M9 12H4s.55-3.03 2-4c1.62-1.08 5 0 5 0' }),
      svgEl('path', { d: 'M12 15v5s3.03-.55 4-2c1.08-1.62 0-5 0-5' }),
    ],
    { width: size, height: size },
  );
}

export function renderPlusIcon(size = 14, className = '') {
  return createIcon(
    `lucide lucide-plus-icon lucide-plus ${className}`.trim(),
    [svgEl('path', { d: 'M5 12h14' }), svgEl('path', { d: 'M12 5v14' })],
    { width: size, height: size },
  );
}

export function renderArrowUpRightIcon(size = 12, className = '') {
  return createIcon(
    `lucide lucide-arrow-up-right-icon lucide-arrow-up-right ${className}`.trim(),
    [svgEl('path', { d: 'M7 7h10v10' }), svgEl('path', { d: 'M7 17 17 7' })],
    { width: size, height: size },
  );
}

export function renderCompassIcon(size = 12, className = '') {
  return createIcon(
    `lucide lucide-compass-icon lucide-compass ${className}`.trim(),
    [
      svgEl('circle', { cx: '12', cy: '12', r: '10' }),
      svgEl('polygon', {
        points: '16.24 7.76 14.12 14.12 7.76 16.24 9.88 9.88 16.24 7.76',
      }),
    ],
    { width: size, height: size },
  );
}

export function renderServerIcon(size = 14, className = '') {
  return createIcon(
    `lucide lucide-server-icon lucide-server ${className}`.trim(),
    [
      svgEl('rect', {
        width: '20',
        height: '8',
        x: '2',
        y: '2',
        rx: '2',
        ry: '2',
      }),
      svgEl('rect', {
        width: '20',
        height: '8',
        x: '2',
        y: '14',
        rx: '2',
        ry: '2',
      }),
      svgEl('line', { x1: '6', x2: '6.01', y1: '6', y2: '6' }),
      svgEl('line', { x1: '6', x2: '6.01', y1: '18', y2: '18' }),
    ],
    { width: size, height: size },
  );
}

export function renderStatusDot(
  color: 'green' | 'amber' | 'red' | 'blue' = 'green',
  size = 8,
) {
  const colorMap = {
    green: '#10b981',
    amber: '#f59e0b',
    red: '#ef4444',
    blue: '#3b82f6',
  };
  return svgEl(
    'svg',
    {
      width: size,
      height: size,
      viewBox: '0 0 10 10',
      fill: 'none',
      style: `display:inline-block;vertical-align:middle;flex-shrink:0;`,
    },
    [
      svgEl('circle', {
        cx: '5',
        cy: '5',
        r: '4',
        fill: colorMap[color] || colorMap.green,
      }),
    ],
  );
}

export function renderQrCodeIcon(size = 14, className = '') {
  return createIcon(
    `lucide lucide-qr-code-icon lucide-qr-code ${className}`.trim(),
    [
      svgEl('rect', { width: '5', height: '5', x: '3', y: '3', rx: '1' }),
      svgEl('rect', { width: '5', height: '5', x: '16', y: '3', rx: '1' }),
      svgEl('rect', { width: '5', height: '5', x: '3', y: '16', rx: '1' }),
      svgEl('path', { d: 'M21 16h-3a2 2 0 0 0-2 2v3' }),
      svgEl('path', { d: 'M21 21v.01' }),
      svgEl('path', { d: 'M12 7v3a2 2 0 0 1-2 2H7' }),
      svgEl('path', { d: 'M3 12h.01' }),
      svgEl('path', { d: 'M12 3h.01' }),
      svgEl('path', { d: 'M12 16v.01' }),
      svgEl('path', { d: 'M16 12h1' }),
      svgEl('path', { d: 'M21 12v.01' }),
      svgEl('path', { d: 'M12 21v-1' }),
    ],
    { width: size, height: size },
  );
}

export function renderPuzzleIcon(size = 14, className = '') {
  return createIcon(
    `lucide lucide-puzzle-icon lucide-puzzle ${className}`.trim(),
    [
      svgEl('path', {
        d: 'M14 7a2 2 0 0 1 2-2h2a2 2 0 0 1 2 2v2a2 2 0 0 0 2 2 2 2 0 0 1 2 2v2a2 2 0 0 1-2 2 2 2 0 0 0-2 2v2a2 2 0 0 1-2 2h-2a2 2 0 0 1-2-2 2 2 0 0 0-2-2 2 2 0 0 1-2-2v-2a2 2 0 0 1 2-2 2 2 0 0 0 2-2V7a2 2 0 0 1-2-2',
      }),
    ],
    { width: size, height: size },
  );
}

export function renderUsersIcon(size = 14, className = '') {
  return createIcon(
    `lucide lucide-users-icon lucide-users ${className}`.trim(),
    [
      svgEl('path', { d: 'M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2' }),
      svgEl('circle', { cx: '9', cy: '7', r: '4' }),
      svgEl('path', { d: 'M22 21v-2a4 4 0 0 0-3-3.87' }),
      svgEl('path', { d: 'M16 3.13a4 4 0 0 1 0 7.75' }),
    ],
    { width: size, height: size },
  );
}

export function renderTagIcon(size = 12, className = '') {
  return createIcon(
    `lucide lucide-tag-icon lucide-tag ${className}`.trim(),
    [
      svgEl('path', {
        d: 'M12 2H2v10l9.29 9.29c.94.94 2.48.94 3.42 0l6.58-6.58c.94-.94.94-2.48 0-3.42L12 2Z',
      }),
      svgEl('line', { x1: '7', x2: '7.01', y1: '7', y2: '7' }),
    ],
    { width: size, height: size },
  );
}

export function renderLockIcon(size = 14, className = '') {
  return createIcon(
    `lucide lucide-lock-icon lucide-lock ${className}`.trim(),
    [
      svgEl('rect', {
        width: '18',
        height: '11',
        x: '3',
        y: '11',
        rx: '2',
        ry: '2',
      }),
      svgEl('path', { d: 'M7 11V7a5 5 0 0 1 10 0v4' }),
    ],
    { width: size, height: size },
  );
}

export function renderCloudIcon(size = 14, className = '') {
  return createIcon(
    `lucide lucide-cloud-icon lucide-cloud ${className}`.trim(),
    [
      svgEl('path', {
        d: 'M17.5 19H9a7 7 0 1 1 6.71-9h1.79a4.5 4.5 0 1 1 0 9Z',
      }),
    ],
    { width: size, height: size },
  );
}

export function renderSparklesIcon(size = 14, className = '') {
  return createIcon(
    `lucide lucide-sparkles-icon lucide-sparkles ${className}`.trim(),
    [
      svgEl('path', {
        d: 'M9.937 15.5A2 2 0 0 0 8.5 14.063l-6.135-1.582a.5.5 0 0 1 0-.962L8.5 9.936A2 2 0 0 0 9.937 8.5l1.582-6.135a.5.5 0 0 1 .963 0L14.063 8.5A2 2 0 0 0 15.5 9.937l6.135 1.581a.5.5 0 0 1 0 .964L15.5 14.063a2 2 0 0 0-1.437 1.437l-1.582 6.135a.5.5 0 0 1-.963 0z',
      }),
      svgEl('path', { d: 'M20 3v4' }),
      svgEl('path', { d: 'M22 5h-4' }),
      svgEl('path', { d: 'M4 17v2' }),
      svgEl('path', { d: 'M5 18H3' }),
    ],
    { width: size, height: size },
  );
}

export function renderTrendingUpIcon(size = 14, className = '') {
  return createIcon(
    `lucide lucide-trending-up-icon lucide-trending-up ${className}`.trim(),
    [
      svgEl('polyline', { points: '22 7 13.5 15.5 8.5 10.5 2 17' }),
      svgEl('polyline', { points: '16 7 22 7 22 13' }),
    ],
    { width: size, height: size },
  );
}

export function renderBarChart2Icon(size = 14, className = '') {
  return createIcon(
    `lucide lucide-bar-chart-2-icon lucide-bar-chart-2 ${className}`.trim(),
    [
      svgEl('line', { x1: '18', x2: '18', y1: '20', y2: '10' }),
      svgEl('line', { x1: '12', x2: '12', y1: '20', y2: '4' }),
      svgEl('line', { x1: '6', x2: '6', y1: '20', y2: '14' }),
    ],
    { width: size, height: size },
  );
}

export function renderBotIcon(size = 14, className = '') {
  return createIcon(
    `lucide lucide-bot-icon lucide-bot ${className}`.trim(),
    [
      svgEl('path', { d: 'M12 8V4H8' }),
      svgEl('rect', { width: '16', height: '12', x: '4', y: '8', rx: '2' }),
      svgEl('path', { d: 'M2 14h2' }),
      svgEl('path', { d: 'M20 14h2' }),
      svgEl('path', { d: 'M15 13v2' }),
      svgEl('path', { d: 'M9 13v2' }),
    ],
    { width: size, height: size },
  );
}

export function renderGamepad2Icon(size = 14, className = '') {
  return createIcon(
    `lucide lucide-gamepad-2-icon lucide-gamepad-2 ${className}`.trim(),
    [
      svgEl('line', { x1: '6', x2: '10', y1: '12', y2: '12' }),
      svgEl('line', { x1: '8', x2: '8', y1: '10', y2: '14' }),
      svgEl('line', { x1: '15', x2: '15.01', y1: '13', y2: '13' }),
      svgEl('line', { x1: '18', x2: '18.01', y1: '11', y2: '11' }),
      svgEl('rect', { width: '20', height: '12', x: '2', y: '6', rx: '2' }),
    ],
    { width: size, height: size },
  );
}

export function renderTvIcon(size = 14, className = '') {
  return createIcon(
    `lucide lucide-tv-icon lucide-tv ${className}`.trim(),
    [
      svgEl('rect', {
        width: '20',
        height: '15',
        x: '2',
        y: '7',
        rx: '2',
        ry: '2',
      }),
      svgEl('polyline', { points: '17 2 12 7 7 2' }),
    ],
    { width: size, height: size },
  );
}

export function renderCheckIcon(size = 14, className = '') {
  return createIcon(
    `lucide lucide-check-icon lucide-check ${className}`.trim(),
    [svgEl('polyline', { points: '20 6 9 17 4 12' })],
    { width: size, height: size },
  );
}

export function renderXIcon(size = 14, className = '') {
  return createIcon(
    `lucide lucide-x-icon lucide-x ${className}`.trim(),
    [
      svgEl('line', { x1: '18', x2: '6', y1: '6', y2: '18' }),
      svgEl('line', { x1: '6', x2: '18', y1: '6', y2: '18' }),
    ],
    { width: size, height: size },
  );
}

export function renderLayersIcon(size = 14, className = '') {
  return createIcon(
    `lucide lucide-layers-icon lucide-layers ${className}`.trim(),
    [
      svgEl('path', {
        d: 'm12.83 2.18a2 2 0 0 0-1.66 0L2.6 6.08a1 1 0 0 0 0 1.83l8.58 3.91a2 2 0 0 0 1.66 0l8.58-3.9a1 1 0 0 0 0-1.83Z',
      }),
      svgEl('path', { d: 'm22 17.65-9.17 4.16a2 2 0 0 1-1.66 0L2 17.65' }),
      svgEl('path', { d: 'm22 12.65-9.17 4.16a2 2 0 0 1-1.66 0L2 12.65' }),
    ],
    { width: size, height: size },
  );
}

export function renderLayoutGridIcon(size = 14, className = '') {
  return createIcon(
    `lucide lucide-layout-grid-icon lucide-layout-grid ${className}`.trim(),
    [
      svgEl('rect', { width: '7', height: '7', x: '3', y: '3', rx: '1' }),
      svgEl('rect', { width: '7', height: '7', x: '14', y: '3', rx: '1' }),
      svgEl('rect', { width: '7', height: '7', x: '14', y: '14', rx: '1' }),
      svgEl('rect', { width: '7', height: '7', x: '3', y: '14', rx: '1' }),
    ],
    { width: size, height: size },
  );
}

export function renderListIcon(size = 14, className = '') {
  return createIcon(
    `lucide lucide-list-icon lucide-list ${className}`.trim(),
    [
      svgEl('line', { x1: '8', x2: '21', y1: '6', y2: '6' }),
      svgEl('line', { x1: '8', x2: '21', y1: '12', y2: '12' }),
      svgEl('line', { x1: '8', x2: '21', y1: '18', y2: '18' }),
      svgEl('line', { x1: '3', x2: '3.01', y1: '6', y2: '6' }),
      svgEl('line', { x1: '3', x2: '3.01', y1: '12', y2: '12' }),
      svgEl('line', { x1: '3', x2: '3.01', y1: '18', y2: '18' }),
    ],
    { width: size, height: size },
  );
}

export function renderPlaneIcon(size = 14, className = '') {
  return createIcon(
    `lucide lucide-plane-icon lucide-plane ${className}`.trim(),
    [
      svgEl('path', {
        d: 'M17.8 19.2 16 11l3.5-3.5C21 6 21.5 4 21 3c-1-.5-3 0-4.5 1.5L13 8 4.8 6.2c-.5-.1-.9.1-1.1.5l-.3.5c-.2.5-.1 1 .3 1.3L9 12l-2 3H4l-1 1 3 2 2 3 1-1v-3l3-2 3.5 5.3c.3.4.8.5 1.3.3l.5-.2c.4-.3.6-.7.5-1.2z',
      }),
    ],
    { width: size, height: size },
  );
}

export function renderPlayIcon(size = 14, className = '') {
  return createIcon(
    `lucide lucide-play-icon lucide-play ${className}`.trim(),
    [svgEl('polygon', { points: '6 3 20 12 6 21 6 3' })],
    { width: size, height: size },
  );
}

export function renderActivityIcon(size = 14, className = '') {
  return createIcon(
    `lucide lucide-activity-icon lucide-activity ${className}`.trim(),
    [svgEl('path', { d: 'M22 12h-4l-3 9L9 3l-3 9H2' })],
    { width: size, height: size },
  );
}

export function renderWrenchIcon(size = 14, className = '') {
  return createIcon(
    `lucide lucide-wrench-icon lucide-wrench ${className}`.trim(),
    [
      svgEl('path', {
        d: 'M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z',
      }),
    ],
    { width: size, height: size },
  );
}

export function renderCommunityListServiceIcon(
  key: string,
  size = 11,
): SVGElement {
  const k = String(key || '')
    .toLowerCase()
    .replace(/^@\s*/, '')
    .trim();
  if (k === 'youtube' || k === 'google_play') return renderPlayIcon(size);
  if (k === 'telegram') return renderPlaneIcon(size);
  if (k === 'discord') return renderGamepad2Icon(size);
  if (
    k.startsWith('ai') ||
    k.includes('openai') ||
    k.includes('anthropic') ||
    k.includes('google_ai') ||
    k.includes('xai')
  ) {
    return renderBotIcon(size);
  }
  if (['meta', 'twitter', 'tiktok', 'pinterest', 'social'].includes(k)) {
    return renderGlobeIcon(size);
  }
  if (
    [
      'spotify',
      'netflix',
      'twitch',
      'twitch_ads',
      'hdrezka',
      'anime',
      'streaming',
      'media',
    ].includes(k)
  ) {
    return renderTvIcon(size);
  }
  if (
    [
      'steam',
      'epicgames',
      'riot',
      'origin',
      'roblox',
      'supercell',
      'escapefromtarkov',
      'faceit',
      'gaming',
      'games',
    ].includes(k)
  ) {
    return renderGamepad2Icon(size);
  }
  if (
    [
      'github',
      'docker',
      'cloudflare',
      'cloudfront',
      'fastly',
      'hetzner',
      'ovh',
      'digitalocean',
      'cloud',
      'dev_cloud',
    ].includes(k)
  ) {
    return renderCloudIcon(size);
  }
  if (
    [
      'russia_inside',
      'geoblock',
      'block',
      'ru_blocked',
      'ru_blocked_all',
      'antifilter',
      'refilter',
      'hodca',
      'rkn',
      'rkn_geoblock',
      'antifilter_refilter',
    ].includes(k)
  ) {
    return renderShieldIcon(size);
  }
  if (['ads_hagezi_pro', 'win_spy'].includes(k)) {
    return renderBanIcon(size);
  }
  if (['apple', 'microsoft', 'ecosystems'].includes(k)) {
    return renderSparklesIcon(size);
  }
  if (['news', 'torrent', 'tor', 'media_extra', 'extra', 'porn'].includes(k)) {
    return renderLockIcon(size);
  }
  if (
    [
      'russia_outside',
      'ru_whitelist',
      'ru_domains',
      'ru_only_inside',
      'push',
    ].includes(k)
  ) {
    return renderGlobeIcon(size);
  }
  return renderTargetIcon(size);
}

export function renderSmartphoneIcon(size = 14, className = '') {
  return createIcon(
    `lucide lucide-smartphone-icon lucide-smartphone ${className}`.trim(),
    [
      svgEl('rect', {
        width: '14',
        height: '20',
        x: '5',
        y: '2',
        rx: '2',
        ry: '2',
      }),
      svgEl('path', { d: 'M12 18h.01' }),
    ],
    { width: size, height: size },
  );
}

export function renderLaptopIcon(size = 14, className = '') {
  return createIcon(
    `lucide lucide-laptop-icon lucide-laptop ${className}`.trim(),
    [
      svgEl('path', {
        d: 'M20 16V7a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v9m16 0H4m16 0 1.28 2.55a1 1 0 0 1-.9 1.45H3.62a1 1 0 0 1-.9-1.45L4 16',
      }),
    ],
    { width: size, height: size },
  );
}
