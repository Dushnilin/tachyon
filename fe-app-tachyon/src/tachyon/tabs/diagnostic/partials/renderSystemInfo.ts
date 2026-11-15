import { insertIf } from '../../../../helpers';
import { renderServerIcon } from '../../../../icons';

export interface IRenderSystemInfoRow {
  key: string;
  value: string;
  subvalue?: string;
  progressPct?: number;
  progressTone?: 'accent' | 'success' | 'warning' | 'danger';
  tag?: {
    label: string;
    kind: 'neutral' | 'warning' | 'success';
  };
}

interface IRenderSystemInfoProps {
  items: Array<IRenderSystemInfoRow>;
}

export function renderSystemInfo({ items }: IRenderSystemInfoProps) {
  return E(
    'section',
    { class: 'tachyon_diagnostic-page__right-bar__system-info' },
    [
      E(
        'header',
        { class: 'tachyon_diagnostic-page__right-bar__system-info__title' },
        [
          E('span', { class: 'tachyon_diagnostic-sys-head-left' }, [
            renderServerIcon(13),
            _('System information'),
          ]),
          E(
            'span',
            { class: 'tachyon_diagnostic-sys-head-code' },
            'NODE · KERNEL · RUNTIME',
          ),
        ],
      ),
      E(
        'div',
        { class: 'tachyon_diagnostic-sys-grid' },
        items.map((item) => {
          const tagClass = [
            'tachyon_diagnostic-page__right-bar__system-info__row__tag',
            ...insertIf(item.tag?.kind === 'neutral', [
              'tachyon_diagnostic-page__right-bar__system-info__row__tag--neutral',
            ]),
            ...insertIf(item.tag?.kind === 'warning', [
              'tachyon_diagnostic-page__right-bar__system-info__row__tag--warning',
            ]),
            ...insertIf(item.tag?.kind === 'success', [
              'tachyon_diagnostic-page__right-bar__system-info__row__tag--success',
            ]),
          ]
            .filter(Boolean)
            .join(' ');

          return E(
            'div',
            { class: 'tachyon_diagnostic-page__right-bar__system-info__row' },
            [
              E('b', {}, item.key),
              E('div', {}, [
                E('span', {}, item.value),
                ...(item.tag?.label
                  ? [E('span', { class: tagClass }, item.tag.label)]
                  : []),
              ]),
              ...(typeof item.progressPct === 'number'
                ? [
                    E(
                      'div',
                      {
                        class:
                          'tachyon_diagnostic-page__right-bar__system-info__row__progress',
                      },
                      [
                        E('span', {
                          class: `tachyon_diagnostic-page__right-bar__system-info__row__progress-fill is-${item.progressTone || 'accent'}`,
                          style: `width: ${Math.max(2, Math.min(100, Math.round(item.progressPct)))}%`,
                        }),
                      ],
                    ),
                  ]
                : []),
              ...(item.subvalue
                ? [
                    E(
                      'span',
                      {
                        class:
                          'tachyon_diagnostic-page__right-bar__system-info__row__sub',
                      },
                      item.subvalue,
                    ),
                  ]
                : []),
            ],
          );
        }),
      ),
    ],
  );
}
