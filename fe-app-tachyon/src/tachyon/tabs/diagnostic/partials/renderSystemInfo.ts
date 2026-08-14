import { insertIf } from '../../../../helpers';

interface IRenderSystemInfoRow {
  key: string;
  value: string;
  tag?: {
    label: string;
    kind: 'neutral' | 'warning' | 'success';
  };
}

interface IRenderSystemInfoProps {
  items: Array<IRenderSystemInfoRow>;
}

export function renderSystemInfo({ items }: IRenderSystemInfoProps) {
  const TAG_CLASS: Record<string, string> = {
    neutral: 'cbi-button-neutral',
    warning: 'cbi-button-reset',
    success: 'cbi-button-save',
  };

  return E('div', { class: 'tachyon_diagnostic-page__system-info' }, [
    E('h3', { style: 'margin: 0 0 6px 0; font-size: 14px;' }, _('System information')),
    ...items.map((item) => {
      const tagBadge = item.tag
        ? E(
            'span',
            {
              class: `badge ${TAG_CLASS[item.tag.kind] || 'cbi-button-neutral'}`,
              style: 'font-size: 11px; padding: 1px 6px; margin-left: 6px;',
            },
            item.tag.label,
          )
        : null;

      return E('div', { class: 'tachyon_diagnostic-page__system-info__row' }, [
        E('b', {}, item.key),
        E('span', {}, tagBadge ? [item.value, tagBadge] : item.value),
      ]);
    }),
  ]);
}
