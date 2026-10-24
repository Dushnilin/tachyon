import { svgEl } from '../../../../helpers';
import { prettyBytes } from '../../../../helpers/prettyBytes';
import { tr } from '../../../helpers/i18n';
import { ITopDomain } from '../connections';

export interface IConnection {
  ip: string;
  count: number;
  upload: number;
  download: number;
  name?: string;
}

export function renderConnections(
  connections: IConnection[],
  isCollapsed: boolean,
  onToggleCollapse: () => void,
  topDomains?: ITopDomain[],
) {
  const topDomainsSection =
    topDomains && topDomains.length > 0
      ? E('div', { class: 'tachyon_dashboard-page__top-domains-container' }, [
          E(
            'div',
            { class: 'tachyon_dashboard-page__top-domains-header' },
            tr('Популярные домены в обходе:', 'Top active domains in bypass:'),
          ),
          E(
            'div',
            { class: 'tachyon_dashboard-page__top-domains-list' },
            topDomains.map((item) =>
              E(
                'span',
                {
                  class: 'tachyon_dashboard-page__top-domain-chip',
                  'data-domain': item.domain,
                },
                [
                  E(
                    'span',
                    { class: 'tachyon_dashboard-page__top-domain-chip__icon' },
                    '🌐',
                  ),
                  E('b', {}, item.domain),
                  E(
                    'span',
                    { class: 'tachyon_dashboard-page__top-domain-chip__badge' },
                    `${item.count} ${tr('соед.', 'conns')}${item.traffic > 0 ? ` • ${prettyBytes(item.traffic)}` : ''}`,
                  ),
                ],
              ),
            ),
          ),
        ])
      : '';

  if (connections.length === 0 && (!topDomains || topDomains.length === 0)) {
    return E('div', { class: 'tachyon_dashboard-page__outbound-section' }, [
      E(
        'div',
        {
          class:
            'tachyon_dashboard-page__outbound-section__title-section tachyon-collapsible-title',
          click: onToggleCollapse,
        },
        [
          E(
            'div',
            {
              class:
                'tachyon_dashboard-page__outbound-section__title-section__title',
              style: 'display: flex; align-items: center; gap: 8px;',
            },
            [
              svgEl(
                'svg',
                {
                  width: '16',
                  height: '16',
                  viewBox: '0 0 24 24',
                  fill: 'none',
                  stroke: 'currentColor',
                  'stroke-width': '2',
                  'stroke-linecap': 'round',
                  'stroke-linejoin': 'round',
                  style: `transition: transform 0.2s; transform: rotate(${isCollapsed ? '-90deg' : '0deg'})`,
                },
                [svgEl('polyline', { points: '6 9 12 15 18 9' })],
              ),
              tr('Активные клиенты', 'Active Clients'),
            ],
          ),
        ],
      ),
      isCollapsed
        ? ''
        : E(
            'div',
            {
              class: 'tachyon-clients-empty',
            },
            tr('Нет активных клиентов', 'No active clients'),
          ),
    ]);
  }

  const rows = connections.map((c) => {
    const infoChildren: HTMLElement[] = [];

    if (c.name) {
      const isMac = /^([0-9a-fA-F]{2}[:-]){5}([0-9a-fA-F]{2})$/.test(c.name);
      const isRouter =
        c.ip === '127.0.0.1' ||
        c.name.includes('WAN') ||
        c.name.includes('Роутер') ||
        c.name.includes('Router');

      const badgeClasses = [
        'tachyon-client-row__name',
        'tachyon-client-row__name-badge',
      ];
      if (isMac) {
        badgeClasses.push(
          'tachyon-client-row__name-badge--mac',
          'tachyon_proto-popover-trigger',
        );
        const popover = E(
          'div',
          { class: 'tachyon_proto-popover tachyon_proto-popover--mac' },
          [
            E('div', { class: 'tachyon_proto-popover__header' }, c.name),
            E('div', { class: 'tachyon_proto-popover__row' }, [
              E(
                'span',
                { class: 'tachyon_proto-popover__label' },
                `${tr('Тип адреса', 'Address type')}:`,
              ),
              E(
                'span',
                { class: 'tachyon_proto-popover__val' },
                tr('Частный MAC (Wi-Fi)', 'Private MAC (Wi-Fi)'),
              ),
            ]),
            E('div', { class: 'tachyon_proto-popover__row' }, [
              E(
                'span',
                { class: 'tachyon_proto-popover__label' },
                `${tr('Имя устройства', 'Device name')}:`,
              ),
              E(
                'span',
                { class: 'tachyon_proto-popover__val' },
                tr('Скрыто клиентом', 'Hidden by client'),
              ),
            ]),
            E(
              'div',
              { class: 'tachyon_proto-popover__desc' },
              tr(
                'Устройство не передаёт своё имя по DHCP при включённой защите приватности (частный адрес Wi-Fi).',
                'Device does not broadcast its hostname via DHCP when privacy protection is enabled (Private Wi-Fi address).',
              ),
            ),
          ],
        );

        infoChildren.push(
          E('span', { class: badgeClasses.join(' ') }, [c.name, popover]),
          E('span', { class: 'tachyon-client-row__ip' }, c.ip),
        );
      } else {
        if (isRouter) {
          badgeClasses.push('tachyon-client-row__name-badge--router');
        } else {
          badgeClasses.push('tachyon-client-row__name-badge--host');
        }

        infoChildren.push(
          E('span', { class: badgeClasses.join(' '), title: c.name }, c.name),
          E('span', { class: 'tachyon-client-row__ip' }, c.ip),
        );
      }
    } else {
      infoChildren.push(
        E(
          'span',
          {
            class: 'tachyon-client-row__ip tachyon-client-row__ip--standalone',
          },
          c.ip,
        ),
      );
    }

    infoChildren.push(
      E(
        'span',
        { class: 'tachyon-client-row__conns' },
        `${c.count} ${tr('соед.', 'conns')}`,
      ),
    );

    return E(
      'div',
      {
        class: 'tachyon-client-row',
        'data-client-ip': c.ip,
        'data-client-name': c.name || '',
      },
      [
        E('div', { class: 'tachyon-client-row__info' }, infoChildren),
        E('div', { class: 'tachyon-client-row__traffic' }, [
          E(
            'span',
            { class: 'tachyon-traffic-pill tachyon-traffic-pill--down' },
            `↓ ${prettyBytes(c.download)}`,
          ),
          E(
            'span',
            { class: 'tachyon-traffic-pill tachyon-traffic-pill--up' },
            `↑ ${prettyBytes(c.upload)}`,
          ),
        ]),
      ],
    );
  });

  return E('div', { class: 'tachyon_dashboard-page__outbound-section' }, [
    E(
      'div',
      {
        class:
          'tachyon_dashboard-page__outbound-section__title-section tachyon-collapsible-title',
        click: onToggleCollapse,
      },
      [
        E(
          'div',
          {
            class:
              'tachyon_dashboard-page__outbound-section__title-section__title',
            style: 'display: flex; align-items: center; gap: 8px;',
          },
          [
            svgEl(
              'svg',
              {
                width: '16',
                height: '16',
                viewBox: '0 0 24 24',
                fill: 'none',
                stroke: 'currentColor',
                'stroke-width': '2',
                'stroke-linecap': 'round',
                'stroke-linejoin': 'round',
                style: `transition: transform 0.2s; transform: rotate(${isCollapsed ? '-90deg' : '0deg'})`,
              },
              [svgEl('polyline', { points: '6 9 12 15 18 9' })],
            ),
            tr('Активные клиенты', 'Active Clients'),
          ],
        ),
      ],
    ),
    isCollapsed
      ? ''
      : E(
          'div',
          {
            class:
              'tachyon_dashboard-page__outbound-grid tachyon-clients-container',
          },
          [...rows, topDomainsSection],
        ),
  ]);
}

export function patchClientRowValues(rowEl: HTMLElement, c: IConnection): void {
  const connsEl = rowEl.querySelector<HTMLElement>(
    '.tachyon-client-row__conns',
  );
  const expectedConns = `${c.count} ${tr('соед.', 'conns')}`;
  if (connsEl && connsEl.textContent !== expectedConns) {
    connsEl.textContent = expectedConns;
  }

  const downEl = rowEl.querySelector<HTMLElement>(
    '.tachyon-traffic-pill--down',
  );
  const expectedDown = `↓ ${prettyBytes(c.download)}`;
  if (downEl && downEl.textContent !== expectedDown) {
    downEl.textContent = expectedDown;
  }

  const upEl = rowEl.querySelector<HTMLElement>('.tachyon-traffic-pill--up');
  const expectedUp = `↑ ${prettyBytes(c.upload)}`;
  if (upEl && upEl.textContent !== expectedUp) {
    upEl.textContent = expectedUp;
  }
}

export function patchConnections(
  container: HTMLElement,
  connections: IConnection[],
  isCollapsed: boolean,
  topDomains?: ITopDomain[],
): boolean {
  const sectionEl = container.querySelector<HTMLElement>(
    '.tachyon_dashboard-page__outbound-section',
  );
  if (!sectionEl) return false;

  const emptyEl = container.querySelector<HTMLElement>(
    '.tachyon-clients-empty',
  );
  const clientsContainer = container.querySelector<HTMLElement>(
    '.tachyon-clients-container',
  );

  if (isCollapsed) {
    return !clientsContainer && !emptyEl;
  }

  const hasNoData =
    connections.length === 0 && (!topDomains || topDomains.length === 0);
  if (hasNoData) {
    return Boolean(emptyEl);
  }

  if (!clientsContainer || emptyEl) {
    return false;
  }

  const rowEls = clientsContainer.querySelectorAll<HTMLElement>(
    '.tachyon-client-row',
  );
  if (rowEls.length !== connections.length) {
    return false;
  }

  for (let i = 0; i < connections.length; i++) {
    const c = connections[i];
    const rowEl = rowEls[i];
    if (rowEl.getAttribute('data-client-ip') !== c.ip) {
      return false;
    }
    if ((rowEl.getAttribute('data-client-name') || '') !== (c.name || '')) {
      return false;
    }
  }

  const topDomainsEl = clientsContainer.querySelector<HTMLElement>(
    '.tachyon_dashboard-page__top-domains-container',
  );
  const hasDomains = Boolean(topDomains && topDomains.length > 0);

  if (!hasDomains) {
    if (topDomainsEl) return false;
  } else {
    if (!topDomainsEl) return false;
    const chips = topDomainsEl.querySelectorAll<HTMLElement>(
      '.tachyon_dashboard-page__top-domain-chip',
    );
    if (chips.length !== topDomains!.length) return false;

    for (let j = 0; j < topDomains!.length; j++) {
      const item = topDomains![j];
      const chip = chips[j];
      if (chip.getAttribute('data-domain') !== item.domain) {
        return false;
      }
      const badgeEl = chip.querySelector<HTMLElement>(
        '.tachyon_dashboard-page__top-domain-chip__badge',
      );
      const expectedBadge = `${item.count} ${tr('соед.', 'conns')}${item.traffic > 0 ? ` • ${prettyBytes(item.traffic)}` : ''}`;
      if (badgeEl && badgeEl.textContent !== expectedBadge) {
        badgeEl.textContent = expectedBadge;
      }
    }
  }

  for (let i = 0; i < connections.length; i++) {
    patchClientRowValues(rowEls[i], connections[i]);
  }

  return true;
}

export function patchExistingClientRowsByIp(
  container: HTMLElement,
  connections: IConnection[],
): void {
  const rowEls = container.querySelectorAll<HTMLElement>('.tachyon-client-row');
  if (!rowEls.length) return;
  const rowMap = new Map<string, HTMLElement>();
  for (let i = 0; i < rowEls.length; i++) {
    const ip = rowEls[i].getAttribute('data-client-ip');
    if (ip) rowMap.set(ip, rowEls[i]);
  }
  for (const c of connections) {
    const rowEl = rowMap.get(c.ip);
    if (rowEl) {
      patchClientRowValues(rowEl, c);
    }
  }
}
