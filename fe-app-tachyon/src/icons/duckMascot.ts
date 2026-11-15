import { svgEl } from '../helpers';

let tachyonLogoSeq = 0;

/**
 * Renders the Tachyon SVG logo: a sharp, frameless faceted electric purple lightning bolt.
 */
export function renderTachyonLogoSvg(size = 40, extraClass = ''): SVGElement {
  const uid = `tachyon-bolt-${++tachyonLogoSeq}`;

  return svgEl(
    'svg',
    {
      viewBox: '0 0 200 200',
      width: String(size),
      height: String(size),
      fill: 'none',
      class: ['tachyon-project-logo', extraClass].filter(Boolean).join(' '),
      'aria-label': 'Tachyon',
    },
    [
      svgEl('defs', {}, [
        // Main superluminal blue lightning gradient (tachyon-ui Apple Blue / Cyan)
        svgEl(
          'linearGradient',
          { id: `${uid}-bolt-main`, x1: '20%', y1: '5%', x2: '80%', y2: '95%' },
          [
            svgEl('stop', { offset: '0%', 'stop-color': '#e0f2fe' }),
            svgEl('stop', { offset: '28%', 'stop-color': '#64d2ff' }),
            svgEl('stop', { offset: '65%', 'stop-color': '#0a84ff' }),
            svgEl('stop', { offset: '100%', 'stop-color': '#0066cc' }),
          ],
        ),
        // Darker 3D right/lower facet for crisp depth in both light & dark themes
        svgEl(
          'linearGradient',
          {
            id: `${uid}-bolt-dark`,
            x1: '0%',
            y1: '0%',
            x2: '100%',
            y2: '100%',
          },
          [
            svgEl('stop', { offset: '0%', 'stop-color': '#0066cc' }),
            svgEl('stop', { offset: '100%', 'stop-color': '#003366' }),
          ],
        ),
        // Soft ambient blue glow
        svgEl(
          'radialGradient',
          { id: `${uid}-glow`, cx: '50%', cy: '50%', r: '48%' },
          [
            svgEl('stop', {
              offset: '0%',
              'stop-color': '#64d2ff',
              'stop-opacity': '0.32',
            }),
            svgEl('stop', {
              offset: '100%',
              'stop-color': '#0a84ff',
              'stop-opacity': '0',
            }),
          ],
        ),
      ]),

      // Soft ambient blue glow behind the bolt
      svgEl('circle', {
        cx: '100',
        cy: '100',
        r: '86',
        fill: `url(#${uid}-glow)`,
      }),

      // Outer 3D shadow / dark facet of the lightning bolt
      svgEl('path', {
        d: 'M 120 12 L 42 108 L 96 108 L 74 190 L 162 86 L 106 86 Z',
        fill: `url(#${uid}-bolt-dark)`,
      }),

      // Main bright blue lightning bolt body
      svgEl('path', {
        d: 'M 120 12 L 42 108 L 96 108 L 74 190 L 152 88 L 104 88 Z',
        fill: `url(#${uid}-bolt-main)`,
      }),

      // Crisp upper-left specular highlight facet
      svgEl('path', {
        d: 'M 120 12 L 42 108 L 91 108 L 104 88 L 78 88 Z',
        fill: '#e0f2fe',
        opacity: '0.5',
      }),
    ],
  );
}

/**
 * Renders the Tachyon-UI topbar mark: a crisp blue ring with a lightning bolt inside.
 */
export function renderTachyonUiMarkSvg(size = 20, extraClass = ''): SVGElement {
  return svgEl(
    'svg',
    {
      viewBox: '0 0 24 24',
      width: String(size),
      height: String(size),
      fill: 'none',
      stroke: 'currentColor',
      'stroke-width': '1.6',
      'stroke-linecap': 'round',
      'stroke-linejoin': 'round',
      class: ['tachyon-ui-mark', extraClass].filter(Boolean).join(' '),
      'aria-label': 'Tachyon',
      style: 'color: #0a84ff; flex-shrink: 0;',
    },
    [
      svgEl('circle', { cx: '12', cy: '12', r: '10' }),
      svgEl('path', { d: 'm8 12 4-8 1 6h3l-4 8-1-6z' }),
    ],
  );
}

// Backwards-compatible alias
export const renderTachyonDuckMascotSvg = renderTachyonLogoSvg;
