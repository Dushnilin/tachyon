const FLAG_EMOJI_PATTERN =
  /([\u{1f1e6}-\u{1f1ff}]{2}|\u{1f3f4}[\u{e0061}-\u{e007a}]+\u{e007f})/gu;
const EXACT_FLAG_EMOJI_PATTERN =
  /^([\u{1f1e6}-\u{1f1ff}]{2}|\u{1f3f4}[\u{e0061}-\u{e007a}]+\u{e007f})$/u;

const SVG_NS = 'http://www.w3.org/2000/svg';

function svgNode(
  tag: string,
  attrs: Record<string, string | number>,
  children: SVGElement[] = [],
): SVGElement {
  const el = document.createElementNS(SVG_NS, tag);
  for (const [k, v] of Object.entries(attrs)) {
    el.setAttribute(k, String(v));
  }
  for (const child of children) {
    el.appendChild(child);
  }
  return el;
}

const H_TRICOLOR_FLAGS: Record<string, [string, string, string]> = {
  RU: ['#ffffff', '#2563eb', '#dc2626'],
  NL: ['#dc2626', '#ffffff', '#1d4ed8'],
  DE: ['#18181b', '#dc2626', '#eab308'],
  AT: ['#dc2626', '#ffffff', '#dc2626'],
  LV: ['#991b1b', '#ffffff', '#991b1b'],
  EE: ['#2563eb', '#18181b', '#ffffff'],
  LT: ['#eab308', '#16a34a', '#dc2626'],
  BG: ['#ffffff', '#16a34a', '#dc2626'],
  HU: ['#dc2626', '#ffffff', '#16a34a'],
  ES: ['#dc2626', '#eab308', '#dc2626'],
  AM: ['#dc2626', '#1d4ed8', '#eab308'],
  AZ: ['#0284c7', '#dc2626', '#16a34a'],
  RS: ['#dc2626', '#1d4ed8', '#ffffff'],
  LU: ['#dc2626', '#ffffff', '#38bdf8'],
  AE: ['#16a34a', '#ffffff', '#18181b'],
  IN: ['#f97316', '#ffffff', '#16a34a'],
  AR: ['#38bdf8', '#ffffff', '#38bdf8'],
  CO: ['#eab308', '#1d4ed8', '#dc2626'],
};

const V_TRICOLOR_FLAGS: Record<string, [string, string, string]> = {
  FR: ['#1d4ed8', '#ffffff', '#dc2626'],
  IT: ['#16a34a', '#ffffff', '#dc2626'],
  IE: ['#16a34a', '#ffffff', '#ea580c'],
  BE: ['#18181b', '#eab308', '#dc2626'],
  RO: ['#1d4ed8', '#eab308', '#dc2626'],
  MD: ['#1d4ed8', '#eab308', '#dc2626'],
  MX: ['#16a34a', '#ffffff', '#dc2626'],
  CA: ['#dc2626', '#ffffff', '#dc2626'],
};

const H_BICOLOR_FLAGS: Record<string, [string, string]> = {
  PL: ['#ffffff', '#dc2626'],
  UA: ['#2563eb', '#eab308'],
  SG: ['#dc2626', '#ffffff'],
  ID: ['#dc2626', '#ffffff'],
  MC: ['#dc2626', '#ffffff'],
  BY: ['#dc2626', '#16a34a'],
};

const NORDIC_FLAGS: Record<string, [string, string]> = {
  FI: ['#ffffff', '#1d4ed8'],
  SE: ['#1d4ed8', '#eab308'],
  DK: ['#dc2626', '#ffffff'],
  NO: ['#dc2626', '#1d4ed8'],
  IS: ['#1d4ed8', '#dc2626'],
};

export function createCountryFlagSvgElement(ccRaw: string): HTMLElement {
  const cc = (ccRaw || '').toUpperCase().trim();
  const shapes: SVGElement[] = [];

  if (H_TRICOLOR_FLAGS[cc]) {
    const [c1, c2, c3] = H_TRICOLOR_FLAGS[cc];
    shapes.push(
      svgNode('rect', { width: 16, height: 3.7, y: 0, fill: c1 }),
      svgNode('rect', { width: 16, height: 3.7, y: 3.65, fill: c2 }),
      svgNode('rect', { width: 16, height: 3.7, y: 7.3, fill: c3 }),
    );
  } else if (V_TRICOLOR_FLAGS[cc]) {
    const [c1, c2, c3] = V_TRICOLOR_FLAGS[cc];
    shapes.push(
      svgNode('rect', { width: 5.4, height: 11, x: 0, fill: c1 }),
      svgNode('rect', { width: 5.4, height: 11, x: 5.3, fill: c2 }),
      svgNode('rect', { width: 5.4, height: 11, x: 10.6, fill: c3 }),
    );
    if (cc === 'CA') {
      shapes.push(
        svgNode('circle', { cx: 8, cy: 5.5, r: 1.8, fill: '#dc2626' }),
      );
    }
  } else if (H_BICOLOR_FLAGS[cc]) {
    const [c1, c2] = H_BICOLOR_FLAGS[cc];
    shapes.push(
      svgNode('rect', { width: 16, height: 5.5, y: 0, fill: c1 }),
      svgNode('rect', { width: 16, height: 5.5, y: 5.5, fill: c2 }),
    );
  } else if (NORDIC_FLAGS[cc]) {
    const [bg, cross] = NORDIC_FLAGS[cc];
    shapes.push(
      svgNode('rect', { width: 16, height: 11, fill: bg }),
      svgNode('rect', { width: 16, height: 2.4, y: 4.3, fill: cross }),
      svgNode('rect', { width: 2.4, height: 11, x: 4.6, fill: cross }),
    );
  } else if (cc === 'US') {
    shapes.push(
      svgNode('rect', { width: 16, height: 11, fill: '#dc2626' }),
      svgNode('rect', { width: 16, height: 1.6, y: 1.6, fill: '#ffffff' }),
      svgNode('rect', { width: 16, height: 1.6, y: 4.8, fill: '#ffffff' }),
      svgNode('rect', { width: 16, height: 1.6, y: 8.0, fill: '#ffffff' }),
      svgNode('rect', { width: 7.5, height: 6.2, x: 0, y: 0, fill: '#1e3a8a' }),
    );
  } else if (cc === 'GB' || cc === 'UK') {
    shapes.push(
      svgNode('rect', { width: 16, height: 11, fill: '#1e3a8a' }),
      svgNode('path', {
        d: 'M0 0 L16 11 M16 0 L0 11',
        stroke: '#ffffff',
        'stroke-width': 2.2,
      }),
      svgNode('rect', { width: 16, height: 3.2, y: 3.9, fill: '#ffffff' }),
      svgNode('rect', { width: 3.2, height: 11, x: 6.4, fill: '#ffffff' }),
      svgNode('rect', { width: 16, height: 1.8, y: 4.6, fill: '#dc2626' }),
      svgNode('rect', { width: 1.8, height: 11, x: 7.1, fill: '#dc2626' }),
    );
  } else if (cc === 'CH') {
    shapes.push(
      svgNode('rect', { width: 16, height: 11, fill: '#dc2626' }),
      svgNode('rect', {
        width: 6.8,
        height: 2.2,
        x: 4.6,
        y: 4.4,
        fill: '#ffffff',
      }),
      svgNode('rect', {
        width: 2.2,
        height: 6.8,
        x: 6.9,
        y: 2.1,
        fill: '#ffffff',
      }),
    );
  } else if (cc === 'JP') {
    shapes.push(
      svgNode('rect', { width: 16, height: 11, fill: '#ffffff' }),
      svgNode('circle', { cx: 8, cy: 5.5, r: 3.1, fill: '#dc2626' }),
    );
  } else if (cc === 'KR') {
    shapes.push(
      svgNode('rect', { width: 16, height: 11, fill: '#ffffff' }),
      svgNode('circle', { cx: 8, cy: 5.5, r: 3.0, fill: '#dc2626' }),
      svgNode('path', {
        d: 'M5 5.5 A3 3 0 0 0 11 5.5 Z',
        fill: '#1d4ed8',
      }),
    );
  } else if (cc === 'TR' || cc === 'HK' || cc === 'CN' || cc === 'VN') {
    shapes.push(
      svgNode('rect', { width: 16, height: 11, fill: '#dc2626' }),
      svgNode('circle', {
        cx: 7.5,
        cy: 5.5,
        r: 2.4,
        fill: cc === 'CN' || cc === 'VN' ? '#eab308' : '#ffffff',
      }),
    );
  } else if (cc === 'KZ') {
    shapes.push(
      svgNode('rect', { width: 16, height: 11, fill: '#0284c7' }),
      svgNode('circle', { cx: 8, cy: 5.5, r: 2.3, fill: '#eab308' }),
    );
  } else if (cc === 'CZ') {
    shapes.push(
      svgNode('rect', { width: 16, height: 5.5, y: 0, fill: '#ffffff' }),
      svgNode('rect', { width: 16, height: 5.5, y: 5.5, fill: '#dc2626' }),
      svgNode('polygon', { points: '0,0 8,5.5 0,11', fill: '#1d4ed8' }),
    );
  } else if (cc === 'IL') {
    shapes.push(
      svgNode('rect', { width: 16, height: 11, fill: '#ffffff' }),
      svgNode('rect', { width: 16, height: 1.6, y: 1.2, fill: '#2563eb' }),
      svgNode('rect', { width: 16, height: 1.6, y: 8.2, fill: '#2563eb' }),
      svgNode('circle', {
        cx: 8,
        cy: 5.5,
        r: 1.7,
        fill: 'none',
        stroke: '#2563eb',
        'stroke-width': 1.2,
      }),
    );
  } else if (cc === 'BR') {
    shapes.push(
      svgNode('rect', { width: 16, height: 11, fill: '#16a34a' }),
      svgNode('polygon', {
        points: '8,1.5 14,5.5 8,9.5 2,5.5',
        fill: '#eab308',
      }),
      svgNode('circle', { cx: 8, cy: 5.5, r: 2.0, fill: '#1d4ed8' }),
    );
  } else {
    shapes.push(
      svgNode('rect', { width: 16, height: 3.7, y: 0, fill: '#0a84ff' }),
      svgNode('rect', { width: 16, height: 3.7, y: 3.65, fill: '#f4f4f5' }),
      svgNode('rect', { width: 16, height: 3.7, y: 7.3, fill: '#3f3f46' }),
    );
  }

  const svg = svgNode(
    'svg',
    {
      width: 15,
      height: 11,
      viewBox: '0 0 16 11',
      style:
        'border-radius: 2px; border: 1px solid rgba(255,255,255,0.16); display: block; flex-shrink: 0;',
    },
    shapes,
  );

  return E(
    'span',
    {
      class: 'tachyon_dashboard-page__flag-emoji tachyon-svg-flag',
      title: cc,
      style:
        'display: inline-flex; align-items: center; vertical-align: middle; margin-right: 4px;',
    },
    [svg as unknown as HTMLElement],
  );
}

function flagEmojiToIsoCode(part: string): string | null {
  const chars = Array.from(part);
  if (chars.length === 2) {
    const cp1 = chars[0].codePointAt(0) || 0;
    const cp2 = chars[1].codePointAt(0) || 0;
    if (cp1 >= 0x1f1e6 && cp1 <= 0x1f1ff && cp2 >= 0x1f1e6 && cp2 <= 0x1f1ff) {
      return (
        String.fromCharCode(cp1 - 0x1f1e6 + 65) +
        String.fromCharCode(cp2 - 0x1f1e6 + 65)
      );
    }
  }
  return null;
}

export function renderFlagEmojis(value: string): (HTMLElement | string)[] {
  return value
    .split(FLAG_EMOJI_PATTERN)
    .filter(Boolean)
    .map((part) => {
      if (EXACT_FLAG_EMOJI_PATTERN.test(part)) {
        const cc = flagEmojiToIsoCode(part);
        if (cc) {
          return createCountryFlagSvgElement(cc);
        }
        return E('span', { class: 'tachyon_dashboard-page__flag-emoji' }, part);
      }
      return part;
    });
}
