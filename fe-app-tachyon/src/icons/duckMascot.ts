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
        // Main purple lightning gradient (top-left bright lavender to deep electric violet)
        svgEl(
          'linearGradient',
          { id: `${uid}-bolt-main`, x1: '20%', y1: '5%', x2: '80%', y2: '95%' },
          [
            svgEl('stop', { offset: '0%', 'stop-color': '#f5d0fe' }),
            svgEl('stop', { offset: '28%', 'stop-color': '#d946ef' }),
            svgEl('stop', { offset: '65%', 'stop-color': '#a855f7' }),
            svgEl('stop', { offset: '100%', 'stop-color': '#7c3aed' }),
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
            svgEl('stop', { offset: '0%', 'stop-color': '#9333ea' }),
            svgEl('stop', { offset: '100%', 'stop-color': '#4c1d95' }),
          ],
        ),
        // Soft ambient purple glow
        svgEl(
          'radialGradient',
          { id: `${uid}-glow`, cx: '50%', cy: '50%', r: '48%' },
          [
            svgEl('stop', {
              offset: '0%',
              'stop-color': '#c084fc',
              'stop-opacity': '0.36',
            }),
            svgEl('stop', {
              offset: '100%',
              'stop-color': '#a855f7',
              'stop-opacity': '0',
            }),
          ],
        ),
      ]),

      // Soft ambient purple glow behind the bolt
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

      // Main bright purple lightning bolt body
      svgEl('path', {
        d: 'M 120 12 L 42 108 L 96 108 L 74 190 L 152 88 L 104 88 Z',
        fill: `url(#${uid}-bolt-main)`,
      }),

      // Crisp upper-left specular highlight facet
      svgEl('path', {
        d: 'M 120 12 L 42 108 L 91 108 L 104 88 L 78 88 Z',
        fill: '#fae8ff',
        opacity: '0.5',
      }),
    ],
  );
}

// Backwards-compatible alias
export const renderTachyonDuckMascotSvg = renderTachyonLogoSvg;
