import { prettyBytes } from '../../../../helpers/prettyBytes';

export interface IConnection {
  ip: string;
  count: number;
  upload: number;
  download: number;
  name?: string;
}

export function renderConnections(connections: IConnection[]) {
  if (connections.length === 0) {
    return E('div', { class: 'tachyon_dashboard-page__outbound-section' }, [
      E('div', { class: 'tachyon_dashboard-page__outbound-section__title-section' }, [
        E('div', { class: 'tachyon_dashboard-page__outbound-section__title-section__title' }, _('Active Clients')),
      ]),
      E('div', { class: 'tachyon_dashboard-page__outbound-section centered', style: 'height: 60px;' }, _('No active clients')),
    ]);
  }

  const rows = connections.map(c => {
    return E('div', { class: 'tachyon_dashboard-page__widgets-section__item__row', style: 'padding: 8px 0; border-bottom: 1px solid rgba(128, 128, 128, 0.1); display: flex; justify-content: space-between;' }, [
      E('div', {}, [
        E('b', {}, c.name ? `${c.name} (${c.ip})` : c.ip),
        E('span', { style: 'opacity: 0.7; font-size: 13px; margin-left: 8px;' }, `(${c.count} conns)`)
      ]),
      E('div', { style: 'font-size: 13px;' }, `▲ ${prettyBytes(c.upload)} | ▼ ${prettyBytes(c.download)}`)
    ]);
  });

  return E('div', { class: 'tachyon_dashboard-page__outbound-section' }, [
    E('div', { class: 'tachyon_dashboard-page__outbound-section__title-section' }, [
      E('div', { class: 'tachyon_dashboard-page__outbound-section__title-section__title' }, _('Active Clients')),
    ]),
    E('div', { class: 'tachyon_dashboard-page__outbound-grid', style: 'padding: 12px; display: block;' }, rows),
  ]);
}
