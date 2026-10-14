export interface PrefixPalette {
  name: string;
  bg: string;
  color: string;
  border: string;
}

export const BASE_PREFIX_PALETTES: PrefixPalette[] = [
  { name: 'Blue', bg: '#2563eb', color: '#ffffff', border: '#3b82f6' },
  { name: 'Green', bg: '#16a34a', color: '#ffffff', border: '#22c55e' },
  { name: 'Purple', bg: '#9333ea', color: '#ffffff', border: '#a855f7' },
  { name: 'Orange', bg: '#ea580c', color: '#ffffff', border: '#f97316' },
  { name: 'Cyan', bg: '#0891b2', color: '#ffffff', border: '#06b6d4' },
  { name: 'Rose', bg: '#e11d48', color: '#ffffff', border: '#f43f5e' },
  { name: 'Amber', bg: '#d97706', color: '#ffffff', border: '#f59e0b' },
  { name: 'Indigo', bg: '#4f46e5', color: '#ffffff', border: '#6366f1' },
  { name: 'Teal', bg: '#0d9488', color: '#ffffff', border: '#14b8a6' },
  { name: 'Dark', bg: '#1e293b', color: '#f8fafc', border: '#475569' },
];

export const BASE_TEXT_COLORS: Array<{ name: string; color: string }> = [
  { name: 'White', color: '#ffffff' },
  { name: 'Light Blue', color: '#bfdbfe' },
  { name: 'Light Green', color: '#bbf7d0' },
  { name: 'Light Yellow', color: '#fef08a' },
  { name: 'Light Pink', color: '#fbcfe8' },
  { name: 'Cyan', color: '#a5f3fc' },
  { name: 'Orange', color: '#fed7aa' },
  { name: 'Dark', color: '#0f172a' },
];

export function getPrefixCustomColors(): Record<
  string,
  { bg?: string; color?: string; border?: string }
> {
  try {
    return JSON.parse(
      localStorage.getItem('tachyon_prefix_colors_v1') || '{}',
    ) as Record<string, { bg?: string; color?: string; border?: string }>;
  } catch {
    return {};
  }
}

export function setPrefixCustomColor(
  prefix: string,
  style: { bg?: string; color?: string; border?: string } | null,
) {
  try {
    const map = getPrefixCustomColors();
    if (!style) {
      delete map[prefix];
    } else {
      map[prefix] = style;
    }
    localStorage.setItem('tachyon_prefix_colors_v1', JSON.stringify(map));
  } catch {
    // ignore storage errors
  }
}

export function resolvePrefixBadgeStyle(prefix?: string): PrefixPalette {
  const customMap = getPrefixCustomColors();
  const key = (prefix || '').trim();
  const uciMap =
    typeof window !== 'undefined' &&
    (
      window as unknown as {
        __tachyonUciPrefixStyles?: Record<
          string,
          { bg?: string; color?: string }
        >;
      }
    ).__tachyonUciPrefixStyles
      ? (
          window as unknown as {
            __tachyonUciPrefixStyles: Record<
              string,
              { bg?: string; color?: string }
            >;
          }
        ).__tachyonUciPrefixStyles[key]
      : undefined;
  let hash = 0;
  for (let i = 0; i < key.length; i++) {
    hash = (hash * 31 + key.charCodeAt(i)) >>> 0;
  }
  const base = BASE_PREFIX_PALETTES[hash % BASE_PREFIX_PALETTES.length];
  const localCustom = customMap[key];
  if (localCustom && (localCustom.bg || localCustom.color)) {
    return {
      name: 'Custom',
      bg: localCustom.bg || uciMap?.bg || base.bg,
      color: localCustom.color || uciMap?.color || base.color,
      border: localCustom.border || localCustom.bg || uciMap?.bg || base.border,
    };
  }
  if (uciMap && (uciMap.bg || uciMap.color)) {
    return {
      name: 'UCI',
      bg: uciMap.bg || base.bg,
      color: uciMap.color || base.color,
      border: uciMap.bg || base.border,
    };
  }
  return base;
}

export function openPrefixColorPickerModal(prefix: string, event?: MouseEvent) {
  if (event) {
    event.stopPropagation();
    event.preventDefault();
  }
  const key = (prefix || '').trim();
  if (!key || typeof ui === 'undefined' || !ui.showModal) return;
  const current = resolvePrefixBadgeStyle(key);
  let selectedBg = current.bg;
  let selectedColor = current.color;

  const previewBadge = E(
    'span',
    {
      class: 'tachyon_dashboard-page__outbound-grid__item__prefix-badge',
      style: `background: ${selectedBg}; color: ${selectedColor}; border: 1px solid ${selectedBg}; font-size: 13px; padding: 3px 10px; font-weight: 600;`,
    },
    key,
  ) as HTMLElement;

  const bgInput = E('input', {
    type: 'color',
    value: selectedBg.startsWith('#') ? selectedBg : '#2563eb',
    style:
      'width: 44px; height: 30px; padding: 0; border: 1px solid rgba(128,128,128,0.4); border-radius: 4px; cursor: pointer;',
    change: (ev: Event) => {
      selectedBg = (ev.target as HTMLInputElement).value;
      updatePreview();
    },
  } as unknown as Record<string, unknown>) as HTMLInputElement;

  const colorInput = E('input', {
    type: 'color',
    value: selectedColor.startsWith('#') ? selectedColor : '#ffffff',
    style:
      'width: 44px; height: 30px; padding: 0; border: 1px solid rgba(128,128,128,0.4); border-radius: 4px; cursor: pointer;',
    change: (ev: Event) => {
      selectedColor = (ev.target as HTMLInputElement).value;
      updatePreview();
    },
  } as unknown as Record<string, unknown>) as HTMLInputElement;

  function updatePreview() {
    previewBadge.style.background = selectedBg;
    previewBadge.style.color = selectedColor;
    previewBadge.style.borderColor = selectedBg;
  }

  function applyLiveToDom(bg: string, color: string) {
    document
      .querySelectorAll(
        '.tachyon_dashboard-page__outbound-grid__item__prefix-badge',
      )
      .forEach((el) => {
        if ((el.textContent || '').trim() === key) {
          const htmlEl = el as HTMLElement;
          htmlEl.style.background = bg;
          htmlEl.style.color = color;
          htmlEl.style.borderColor = bg;
        }
      });
  }

  ui.showModal(_('Customize prefix color:') + ' ' + key, [
    E(
      'div',
      {
        style:
          'margin-bottom: 14px; display: flex; align-items: center; gap: 10px;',
      },
      [E('span', { style: 'font-weight: 500;' }, _('Preview:')), previewBadge],
    ),
    E('div', { style: 'margin-bottom: 12px;' }, [
      E(
        'div',
        { style: 'font-weight: 500; margin-bottom: 6px;' },
        _('Background color presets:'),
      ),
      E(
        'div',
        { style: 'display: flex; flex-wrap: wrap; gap: 6px;' },
        BASE_PREFIX_PALETTES.map((p) =>
          E(
            'button',
            {
              type: 'button',
              class: 'btn',
              style: `background: ${p.bg}; color: ${p.color}; border: 1px solid ${p.border}; padding: 4px 10px; border-radius: 4px; font-size: 12px; font-weight: 600; cursor: pointer;`,
              click: () => {
                selectedBg = p.bg;
                selectedColor = p.color;
                bgInput.value = p.bg;
                colorInput.value = p.color;
                updatePreview();
              },
            },
            p.name,
          ),
        ),
      ),
    ]),
    E('div', { style: 'margin-bottom: 12px;' }, [
      E(
        'div',
        { style: 'font-weight: 500; margin-bottom: 6px;' },
        _('Text color presets:'),
      ),
      E(
        'div',
        { style: 'display: flex; flex-wrap: wrap; gap: 6px;' },
        BASE_TEXT_COLORS.map((t) =>
          E(
            'button',
            {
              type: 'button',
              class: 'btn',
              style: `background: #334155; color: ${t.color}; border: 1px solid rgba(255,255,255,0.2); padding: 4px 10px; border-radius: 4px; font-size: 12px; font-weight: 600; cursor: pointer;`,
              click: () => {
                selectedColor = t.color;
                colorInput.value = t.color;
                updatePreview();
              },
            },
            t.name,
          ),
        ),
      ),
    ]),
    E(
      'div',
      {
        style:
          'display: flex; align-items: center; gap: 16px; margin-bottom: 16px;',
      },
      [
        E(
          'label',
          {
            style:
              'display: flex; align-items: center; gap: 6px; cursor: pointer;',
          },
          [_('Background:'), bgInput],
        ),
        E(
          'label',
          {
            style:
              'display: flex; align-items: center; gap: 6px; cursor: pointer;',
          },
          [_('Text:'), colorInput],
        ),
      ],
    ),
    E(
      'div',
      {
        class: 'right',
        style: 'display: flex; justify-content: flex-end; gap: 8px;',
      },
      [
        E(
          'button',
          {
            type: 'button',
            class: 'btn',
            click: () => {
              setPrefixCustomColor(key, null);
              const def = resolvePrefixBadgeStyle(key);
              applyLiveToDom(def.bg, def.color);
              ui.hideModal();
            },
          },
          _('Reset to default'),
        ),
        E(
          'button',
          {
            type: 'button',
            class: 'btn',
            click: () => ui.hideModal(),
          },
          _('Cancel'),
        ),
        E(
          'button',
          {
            type: 'button',
            class: 'btn cbi-button-action important',
            click: () => {
              setPrefixCustomColor(key, {
                bg: selectedBg,
                color: selectedColor,
                border: selectedBg,
              });
              applyLiveToDom(selectedBg, selectedColor);
              ui.hideModal();
            },
          },
          _('Save'),
        ),
      ],
    ),
  ] as unknown as HTMLElement);
}

export function formatOutboundType(type?: string, transport?: string): string {
  const cleanType = (type || '').trim();
  const cleanTransport = (transport || '').trim().toUpperCase();

  if (!cleanType) {
    return cleanTransport ? `(${cleanTransport})` : '';
  }

  if (!cleanTransport) {
    return cleanType;
  }

  if (cleanType.toUpperCase().includes(`(${cleanTransport})`)) {
    return cleanType;
  }

  return `${cleanType} (${cleanTransport})`;
}

export function parseNodeProtocolBreakdown(
  type?: string,
  transport?: string,
  details?: string,
) {
  const base = formatOutboundType(type, transport);
  const rawParts = (details || '')
    .split('·')
    .map((s) => s.trim())
    .filter(Boolean);
  const rows: Array<{ label: string; value: string }> = [];
  const proto = (type || '').trim().toUpperCase();
  if (proto) {
    rows.push({ label: 'Protocol', value: proto });
  }
  const seen = new Set<string>();
  for (const part of rawParts) {
    const low = part.toLowerCase();
    if (seen.has(low)) continue;
    seen.add(low);
    if (low === proto.toLowerCase()) continue;
    if (
      low === 'reality' ||
      low === 'tls' ||
      low === 'none' ||
      low.startsWith('reality')
    ) {
      rows.push({ label: 'Security', value: part.toUpperCase() });
    } else if (low.startsWith('xtls-') || low.startsWith('flow:')) {
      rows.push({ label: 'Flow', value: part.replace(/^flow:\s*/i, '') });
    } else if (
      low.startsWith('xhttp') ||
      low === 'ws' ||
      low === 'grpc' ||
      low === 'http' ||
      low === 'httpupgrade' ||
      low === 'quic' ||
      low === 'tcp'
    ) {
      rows.push({ label: 'Transport', value: part });
    } else if (low.startsWith('xmux')) {
      rows.push({
        label: 'XMUX',
        value: part.replace(/^xmux\s*\((.*)\)$/i, '$1'),
      });
    } else if (low.startsWith('utls:')) {
      rows.push({ label: 'uTLS Fingerprint', value: part.slice(5).trim() });
    } else if (low.startsWith('alpn:')) {
      rows.push({ label: 'ALPN', value: part.slice(5).trim() });
    } else if (low.startsWith('sni:')) {
      rows.push({ label: 'SNI / Host', value: part.slice(4).trim() });
    } else if (low.startsWith('pin:')) {
      rows.push({ label: 'Pinning', value: part.slice(4).trim() });
    } else if (low.startsWith('mux:')) {
      rows.push({ label: 'Multiplex', value: part.slice(4).trim() });
    } else if (low.startsWith(':')) {
      rows.push({ label: 'Port', value: part.slice(1).trim() });
    } else {
      rows.push({ label: 'Info', value: part });
    }
  }
  if (
    !rows.some((r) => r.label === 'Transport') &&
    transport &&
    transport.toLowerCase() !== proto.toLowerCase()
  ) {
    rows.push({ label: 'Transport', value: transport.toUpperCase() });
  }
  return { base, rows };
}

export function formatOutboundTypeTooltip(
  type?: string,
  transport?: string,
  details?: string,
): string {
  const { base, rows } = parseNodeProtocolBreakdown(type, transport, details);
  if (!rows.length) return base;
  return [base, ...rows.map((r) => `${r.label}: ${r.value}`)].join('\n');
}

export function renderProtocolPopoverNodes(
  type?: string,
  transport?: string,
  details?: string,
): HTMLElement | null {
  const { base, rows } = parseNodeProtocolBreakdown(type, transport, details);
  if (rows.length <= 1 && !details) {
    return null;
  }
  return E('div', { class: 'tachyon_proto-popover' }, [
    E('div', { class: 'tachyon_proto-popover__header' }, base),
    ...rows.map((r) =>
      E('div', { class: 'tachyon_proto-popover__row' }, [
        E('span', { class: 'tachyon_proto-popover__label' }, `${r.label}:`),
        E('span', { class: 'tachyon_proto-popover__val' }, r.value),
      ]),
    ),
  ]);
}

export function renderOutboundTypeWithPopover(
  type?: string,
  transport?: string,
  details?: string,
  className?: string,
  extraSuffix?: string,
): HTMLElement {
  const baseType = formatOutboundType(type, transport);
  const labelText = extraSuffix ? `${baseType} ${extraSuffix}` : baseType;
  const popover = renderProtocolPopoverNodes(type, transport, details);
  const tooltip = formatOutboundTypeTooltip(type, transport, details);
  return E(
    'span',
    {
      class: [className || '', popover ? 'tachyon_proto-popover-trigger' : '']
        .filter(Boolean)
        .join(' '),
      title: popover ? undefined : tooltip,
    },
    [E('span', {}, labelText), ...(popover ? [popover] : [])],
  );
}
