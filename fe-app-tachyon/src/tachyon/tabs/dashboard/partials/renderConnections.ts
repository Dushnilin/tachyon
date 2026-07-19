import { svgEl } from '../../../../helpers';
import { prettyBytes } from '../../../../helpers/prettyBytes';

export interface IConnection {
  ip: string;
  count: number;
  upload: number;
  download: number;
  name?: string;
}

export function renderConnections(connections: IConnection[], isCollapsed: boolean, onToggleCollapse: () => void) {
  if (connections.length === 0) {
    return E('div', { class: 'tachyon_dashboard-page__outbound-section' }, [
      E('div', { 
        class: 'tachyon_dashboard-page__outbound-section__title-section',
        style: 'cursor: pointer; user-select: none;',
        click: onToggleCollapse
      }, [
        E('div', { class: 'tachyon_dashboard-page__outbound-section__title-section__title', style: 'display: flex; align-items: center; gap: 8px;' }, [
          svgEl('svg', {
            width: '16',
            height: '16',
            viewBox: '0 0 24 24',
            fill: 'none',
            stroke: 'currentColor',
            'stroke-width': '2',
            'stroke-linecap': 'round',
            'stroke-linejoin': 'round',
            style: `transition: transform 0.2s; transform: rotate(${isCollapsed ? '-90deg' : '0deg'})`
          }, [
            svgEl('polyline', { points: '6 9 12 15 18 9' })
          ]),
          _('Active Clients')
        ]),
      ]),
      isCollapsed ? '' : E('div', { class: 'tachyon_dashboard-page__outbound-section centered', style: 'height: 60px;' }, _('No active clients')),
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
    E('div', { 
      class: 'tachyon_dashboard-page__outbound-section__title-section',
      style: 'cursor: pointer; user-select: none;',
      click: onToggleCollapse
    }, [
      E('div', { class: 'tachyon_dashboard-page__outbound-section__title-section__title', style: 'display: flex; align-items: center; gap: 8px;' }, [
        svgEl('svg', {
          width: '16',
          height: '16',
          viewBox: '0 0 24 24',
          fill: 'none',
          stroke: 'currentColor',
          'stroke-width': '2',
          'stroke-linecap': 'round',
          'stroke-linejoin': 'round',
          style: `transition: transform 0.2s; transform: rotate(${isCollapsed ? '-90deg' : '0deg'})`
        }, [
          svgEl('polyline', { points: '6 9 12 15 18 9' })
        ]),
        _('Active Clients')
      ]),
    ]),
    isCollapsed ? '' : E('div', { class: 'tachyon_dashboard-page__outbound-grid', style: 'padding: 12px; display: block;' }, rows),
  ]);
}
