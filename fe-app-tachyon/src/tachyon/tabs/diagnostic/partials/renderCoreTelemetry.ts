import {
  renderActivityIcon,
  renderRotateCcwIcon24,
  renderServerIcon,
  renderShieldIcon,
} from '../../../../icons';
import { tr } from '../../../helpers/i18n';

function iconMarkup(
  kind: 'activity' | 'cpu' | 'shield' | 'zap' | 'refresh',
  cls: string,
): HTMLElement {
  const wrap = E('span', { class: cls }) as HTMLElement;
  if (kind === 'activity') {
    wrap.appendChild(renderActivityIcon(15));
  } else if (kind === 'cpu' || kind === 'zap') {
    wrap.appendChild(renderServerIcon(14));
  } else if (kind === 'shield') {
    wrap.appendChild(renderShieldIcon(15));
  } else {
    wrap.appendChild(renderRotateCcwIcon24());
  }
  return wrap;
}

export interface ICoreTelemetryMemory {
  rss_bytes?: number;
  vm_bytes?: number;
  system_available_bytes?: number;
  total_ram_mb?: number;
  pressure_level?: string;
  under_pressure?: boolean;
  connections?: {
    active_connections?: number;
    device_buckets?: number;
    inbound_buckets?: number;
    user_buckets?: number;
  };
  dns?: {
    cache_entries?: number;
    reverse_entries?: number;
    fakeip_entries?: number;
  };
}

export interface ICoreTelemetryTraffic {
  upload_bps?: number;
  download_bps?: number;
  upload_total?: number;
  download_total?: number;
  proxied_upload?: number;
  proxied_download?: number;
  direct_upload?: number;
  direct_download?: number;
  total_devices?: number;
  active_connections?: number;
  history?: Array<[number, number]>;
}

export interface ICoreTelemetryOutbound {
  tag: string;
  active_connections?: number;
  upload?: number;
  download?: number;
  recent_hits?: number;
}

export interface ICoreTelemetryFailoverGroup {
  tag: string;
  type?: string;
  mode?: string;
  primary?: string;
  current?: string;
  on_backup?: boolean;
  primary_healthy?: boolean;
  primary_rtt_ms?: number | null;
  primary_failures?: number;
  primary_quarantine_rem_s?: number;
  member_count?: number;
}

export interface ICoreTelemetryFlightEntry {
  id?: number;
  timestamp_ms?: number;
  network?: string;
  inbound?: string;
  source?: string;
  host?: string;
  destination?: string;
  outbound?: string;
  rule?: string;
  upload?: number;
  download?: number;
  duration_ms?: number;
  status?: string;
}

export interface ICoreTelemetrySnapshot {
  success?: boolean;
  memory?: ICoreTelemetryMemory;
  traffic?: ICoreTelemetryTraffic;
  protocols?: {
    tcp?: number;
    udp?: number;
    quic?: number;
  };
  outbounds?: ICoreTelemetryOutbound[];
  failover?: {
    any_on_backup?: boolean;
    groups?: ICoreTelemetryFailoverGroup[];
  };
  leak?: {
    status?: string;
    ipv4?: { outbound?: string; rule?: string; is_direct?: boolean };
    ipv6?: {
      outbound?: string;
      rule?: string;
      is_direct?: boolean;
      leak_risk?: boolean;
    };
    webrtc_stun?: {
      outbound?: string;
      rule?: string;
      is_direct?: boolean;
      leak_risk?: boolean;
    };
    dns?: { engine_enabled?: boolean };
  };
  flight?: {
    count?: number;
    entries?: ICoreTelemetryFlightEntry[];
  };
}

export interface ICoreTelemetryActions {
  onRefresh?: () => void;
  onTrimMemory?: () => void;
  onRecheckRoutes?: () => void;
  onRestoreFailover?: () => void;
  onClearFlight?: () => void;
}

function formatBytes(bytes: number): string {
  const val = Number(bytes) || 0;
  if (val <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  const idx = Math.min(
    units.length - 1,
    Math.floor(Math.log(val) / Math.log(1024)),
  );
  const scaled = val / Math.pow(1024, idx);
  return `${scaled >= 100 || idx === 0 ? Math.round(scaled) : scaled.toFixed(1)} ${units[idx]}`;
}

function formatRate(bps: number): string {
  return `${formatBytes(bps)}/s`;
}

function renderSparklineSvg(history: Array<[number, number]>): HTMLElement {
  const width = 420;
  const height = 104;
  const padTop = 8;
  const padBottom = 8;
  const plotHeight = height - padTop - padBottom;

  const samples =
    Array.isArray(history) && history.length > 0
      ? history.slice(-60)
      : Array.from({ length: 60 }, () => [0, 0] as [number, number]);

  while (samples.length < 60) {
    samples.unshift([0, 0]);
  }

  let maxVal = 1024;
  for (const [up, down] of samples) {
    if (up > maxVal) maxVal = up;
    if (down > maxVal) maxVal = down;
  }

  const toPoints = (idxVal: 0 | 1): string =>
    samples
      .map((pair, idx) => {
        const x = (idx / Math.max(1, samples.length - 1)) * width;
        const v = Math.max(0, Number(pair[idxVal]) || 0);
        const y = padTop + plotHeight - (v / maxVal) * plotHeight;
        return `${x.toFixed(1)},${y.toFixed(1)}`;
      })
      .join(' ');

  const downPoints = toPoints(1);
  const upPoints = toPoints(0);
  const downArea = `0,${height - padBottom} ${downPoints} ${width},${height - padBottom}`;
  const upArea = `0,${height - padBottom} ${upPoints} ${width},${height - padBottom}`;

  const wrapper = E('div', {
    class: 'tachyon_diag-telemetry__sparkline-wrap',
  }) as HTMLElement;
  wrapper.innerHTML = `
        <svg class="tachyon_diag-telemetry__sparkline" viewBox="0 0 ${width} ${height}" preserveAspectRatio="none" aria-label="60s traffic chart">
            <defs>
                <linearGradient id="tachyonDiagDownGrad" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="0%" stop-color="#0a84ff" stop-opacity="0.34"/>
                    <stop offset="100%" stop-color="#0a84ff" stop-opacity="0.0"/>
                </linearGradient>
                <linearGradient id="tachyonDiagUpGrad" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="0%" stop-color="#30d158" stop-opacity="0.26"/>
                    <stop offset="100%" stop-color="#30d158" stop-opacity="0.0"/>
                </linearGradient>
            </defs>
            <line x1="0" y1="${padTop}" x2="${width}" y2="${padTop}" stroke="rgba(255,255,255,0.06)" stroke-dasharray="3 3" stroke-width="1"/>
            <line x1="0" y1="${Math.round(height / 2)}" x2="${width}" y2="${Math.round(height / 2)}" stroke="rgba(255,255,255,0.05)" stroke-dasharray="3 3" stroke-width="1"/>
            <line x1="0" y1="${height - padBottom}" x2="${width}" y2="${height - padBottom}" stroke="rgba(255,255,255,0.08)" stroke-width="1"/>
            <polygon points="${downArea}" fill="url(#tachyonDiagDownGrad)"/>
            <polygon points="${upArea}" fill="url(#tachyonDiagUpGrad)"/>
            <polyline points="${downPoints}" fill="none" stroke="#0a84ff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>
            <polyline points="${upPoints}" fill="none" stroke="#30d158" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
        </svg>
        <div class="tachyon_diag-telemetry__sparkline-meta">
            <span>${tr('-60с', '-60s')}</span>
            <span>${tr('Пик шкалы', 'Scale peak')}: ${formatRate(maxVal)}</span>
            <span>${tr('Сейчас', 'Now')}</span>
        </div>
    `;
  return wrapper;
}

export function renderCoreTelemetry(
  snapshot?: ICoreTelemetrySnapshot | null,
  actions: ICoreTelemetryActions = {},
): HTMLElement {
  const traffic = snapshot?.traffic || {};
  const memory = snapshot?.memory || {};
  const protocols = snapshot?.protocols || {};
  const outbounds = Array.isArray(snapshot?.outbounds)
    ? snapshot!.outbounds!
    : [];
  const failoverGroups = Array.isArray(snapshot?.failover?.groups)
    ? snapshot!.failover!.groups!
    : [];
  const leak = snapshot?.leak || {};
  const flightEntries = Array.isArray(snapshot?.flight?.entries)
    ? snapshot!.flight!.entries!
    : [];
  const flightCount =
    Number(snapshot?.flight?.count ?? flightEntries.length) || 0;

  const downBps = Number(traffic.download_bps) || 0;
  const upBps = Number(traffic.upload_bps) || 0;
  const downTotal = Number(traffic.download_total) || 0;
  const upTotal = Number(traffic.upload_total) || 0;
  const proxiedBytes =
    (Number(traffic.proxied_download) || 0) +
    (Number(traffic.proxied_upload) || 0);
  const directBytes =
    (Number(traffic.direct_download) || 0) +
    (Number(traffic.direct_upload) || 0);
  const splitSum = proxiedBytes + directBytes;
  const proxiedPct =
    splitSum > 0 ? Math.round((proxiedBytes / splitSum) * 100) : 50;
  const directPct = splitSum > 0 ? Math.max(0, 100 - proxiedPct) : 50;

  const tcpCount = Number(protocols.tcp) || 0;
  const udpCount = Number(protocols.udp) || 0;
  const quicCount = Number(protocols.quic) || 0;

  // Card 1: Throughput & Traffic Split
  const throughputCard = E(
    'article',
    { class: 'tachyon_diag-telemetry__card' },
    [
      E('header', { class: 'tachyon_diag-telemetry__card-head' }, [
        E('div', { class: 'tachyon_diag-telemetry__title-group' }, [
          iconMarkup('activity', 'tachyon_diag-telemetry__title-icon'),
          E('div', {}, [
            E(
              'h4',
              { class: 'tachyon_diag-telemetry__title' },
              tr(
                'Пропускная способность и баланс трафика',
                'Throughput & Traffic Split',
              ),
            ),
            E(
              'p',
              { class: 'tachyon_diag-telemetry__subtitle' },
              tr(
                'Живая телеметрия потока данных за 60 секунд и распределение маршрутов',
                'Live 60-second traffic telemetry and route distribution',
              ),
            ),
          ]),
        ]),
        E('div', { class: 'tachyon_diag-telemetry__rate-pills' }, [
          E(
            'span',
            { class: 'tachyon_diag-telemetry__rate-pill is-down' },
            `↓ ${formatRate(downBps)}`,
          ),
          E(
            'span',
            { class: 'tachyon_diag-telemetry__rate-pill is-up' },
            `↑ ${formatRate(upBps)}`,
          ),
        ]),
      ]),
      renderSparklineSvg(traffic.history || []),
      E('div', { class: 'tachyon_diag-telemetry__kpi-grid' }, [
        E('div', { class: 'tachyon_diag-telemetry__kpi' }, [
          E(
            'span',
            { class: 'tachyon_diag-telemetry__kpi-label' },
            tr('Принято всего', 'Total Received'),
          ),
          E(
            'strong',
            { class: 'tachyon_diag-telemetry__kpi-val' },
            formatBytes(downTotal),
          ),
        ]),
        E('div', { class: 'tachyon_diag-telemetry__kpi' }, [
          E(
            'span',
            { class: 'tachyon_diag-telemetry__kpi-label' },
            tr('Отправлено всего', 'Total Sent'),
          ),
          E(
            'strong',
            { class: 'tachyon_diag-telemetry__kpi-val' },
            formatBytes(upTotal),
          ),
        ]),
        E('div', { class: 'tachyon_diag-telemetry__kpi' }, [
          E(
            'span',
            { class: 'tachyon_diag-telemetry__kpi-label' },
            tr('Клиенты в пуле', 'Clients in Pool'),
          ),
          E(
            'strong',
            { class: 'tachyon_diag-telemetry__kpi-val' },
            String(Number(traffic.total_devices) || 0),
          ),
        ]),
        E('div', { class: 'tachyon_diag-telemetry__kpi' }, [
          E(
            'span',
            { class: 'tachyon_diag-telemetry__kpi-label' },
            tr('Активные сессии', 'Active Sessions'),
          ),
          E(
            'strong',
            { class: 'tachyon_diag-telemetry__kpi-val' },
            String(Number(traffic.active_connections) || 0),
          ),
        ]),
      ]),
      E('div', { class: 'tachyon_diag-telemetry__split-box' }, [
        E('div', { class: 'tachyon_diag-telemetry__split-head' }, [
          E(
            'span',
            { class: 'tachyon_diag-telemetry__split-tag is-proxied' },
            `${tr('Через туннели', 'Via Tunnels')}: ${formatBytes(proxiedBytes)} (${splitSum > 0 ? proxiedPct : 0}%)`,
          ),
          E(
            'span',
            { class: 'tachyon_diag-telemetry__split-tag is-direct' },
            `${tr('Напрямую', 'Direct')}: ${formatBytes(directBytes)} (${splitSum > 0 ? directPct : 0}%)`,
          ),
        ]),
        E('div', { class: 'tachyon_diag-telemetry__split-bar' }, [
          E('span', {
            class: 'tachyon_diag-telemetry__split-seg is-proxied',
            style: `width: ${proxiedPct}%`,
          }),
          E('span', {
            class: 'tachyon_diag-telemetry__split-seg is-direct',
            style: `width: ${directPct}%`,
          }),
        ]),
        E('div', { class: 'tachyon_diag-telemetry__proto-row' }, [
          E(
            'span',
            { class: 'tachyon_diag-telemetry__proto-chip' },
            `TCP: ${tcpCount}`,
          ),
          E(
            'span',
            { class: 'tachyon_diag-telemetry__proto-chip' },
            `UDP: ${udpCount}`,
          ),
          E(
            'span',
            { class: 'tachyon_diag-telemetry__proto-chip' },
            `QUIC/443: ${quicCount}`,
          ),
        ]),
      ]),
    ],
  );

  // Card 2: Core Memory, DNS Caches & Outbounds
  const rssBytes = Number(memory.rss_bytes) || 0;
  const vmBytes = Number(memory.vm_bytes) || 0;
  const sysAvailBytes = Number(memory.system_available_bytes) || 0;
  const totalRamBytes = (Number(memory.total_ram_mb) || 0) * 1024 * 1024;
  const usedSysPct =
    totalRamBytes > 0
      ? Math.min(
          100,
          Math.max(
            0,
            Math.round(((totalRamBytes - sysAvailBytes) / totalRamBytes) * 100),
          ),
        )
      : 0;
  const pressureRaw = String(memory.pressure_level || 'normal').toLowerCase();
  const isUnderPressure =
    Boolean(memory.under_pressure) || pressureRaw !== 'normal';
  const pressureLabel = isUnderPressure
    ? tr('Нагрузка RAM', 'RAM Pressure')
    : tr('Норма (Normal)', 'Normal');

  const maxOutboundScore = outbounds.reduce((acc, item) => {
    const s =
      (Number(item.download) || 0) +
      (Number(item.upload) || 0) +
      (Number(item.recent_hits) || 0) * 4096;
    return s > acc ? s : acc;
  }, 1);

  const trimBtn = E(
    'button',
    {
      type: 'button',
      class: 'cbi-button tachyon_diag-telemetry__action-btn',
      click: () => {
        if (typeof actions.onTrimMemory === 'function') actions.onTrimMemory();
      },
    },
    [
      iconMarkup('zap', 'tachyon_diag-telemetry__btn-icon'),
      E('span', {}, tr('Очистить кэши RAM', 'Trim RAM Caches')),
    ],
  );

  const recheckBtn = E(
    'button',
    {
      type: 'button',
      class: 'cbi-button tachyon_diag-telemetry__action-btn',
      click: () => {
        if (typeof actions.onRecheckRoutes === 'function')
          actions.onRecheckRoutes();
      },
    },
    [
      iconMarkup('refresh', 'tachyon_diag-telemetry__btn-icon'),
      E('span', {}, tr('Перепроверить маршруты', 'Re-evaluate Routes')),
    ],
  );

  const resourcesCard = E(
    'article',
    { class: 'tachyon_diag-telemetry__card' },
    [
      E('header', { class: 'tachyon_diag-telemetry__card-head' }, [
        E('div', { class: 'tachyon_diag-telemetry__title-group' }, [
          iconMarkup('cpu', 'tachyon_diag-telemetry__title-icon'),
          E('div', {}, [
            E(
              'h4',
              { class: 'tachyon_diag-telemetry__title' },
              tr(
                'Ресурсы ядра, DNS-кэши и узлы',
                'Core Resources, DNS Caches & Outbounds',
              ),
            ),
            E(
              'p',
              { class: 'tachyon_diag-telemetry__subtitle' },
              tr(
                'Потребление памяти tachyon-core, состояние таблиц DNS и активность выходов',
                'tachyon-core memory usage, DNS tables state and outbound activity',
              ),
            ),
          ]),
        ]),
        E(
          'span',
          {
            class: `tachyon_diag-telemetry__status-badge ${isUnderPressure ? 'is-warn' : 'is-ok'}`,
          },
          pressureLabel,
        ),
      ]),
      E('div', { class: 'tachyon_diag-telemetry__mem-strip' }, [
        E('div', { class: 'tachyon_diag-telemetry__mem-meta' }, [
          E(
            'span',
            {},
            `Core RSS: ${formatBytes(rssBytes)} · VM: ${formatBytes(vmBytes)}`,
          ),
          E(
            'span',
            {},
            `${tr('Свободно ОЗУ', 'Free RAM')}: ${formatBytes(sysAvailBytes)}`,
          ),
        ]),
        E('div', { class: 'tachyon_diag-telemetry__progress-track' }, [
          E('span', {
            class: `tachyon_diag-telemetry__progress-fill ${usedSysPct > 85 ? 'is-danger' : usedSysPct > 70 ? 'is-warn' : 'is-accent'}`,
            style: `width: ${usedSysPct}%`,
          }),
        ]),
      ]),
      E('div', { class: 'tachyon_diag-telemetry__kpi-grid' }, [
        E('div', { class: 'tachyon_diag-telemetry__kpi' }, [
          E(
            'span',
            { class: 'tachyon_diag-telemetry__kpi-label' },
            tr('Кэш DNS', 'DNS Cache'),
          ),
          E(
            'strong',
            { class: 'tachyon_diag-telemetry__kpi-val' },
            String(Number(memory.dns?.cache_entries) || 0),
          ),
        ]),
        E('div', { class: 'tachyon_diag-telemetry__kpi' }, [
          E(
            'span',
            { class: 'tachyon_diag-telemetry__kpi-label' },
            'Reverse DNS',
          ),
          E(
            'strong',
            { class: 'tachyon_diag-telemetry__kpi-val' },
            String(Number(memory.dns?.reverse_entries) || 0),
          ),
        ]),
        E('div', { class: 'tachyon_diag-telemetry__kpi' }, [
          E(
            'span',
            { class: 'tachyon_diag-telemetry__kpi-label' },
            tr('Таблица FakeIP', 'FakeIP Table'),
          ),
          E(
            'strong',
            { class: 'tachyon_diag-telemetry__kpi-val' },
            String(Number(memory.dns?.fakeip_entries) || 0),
          ),
        ]),
        E('div', { class: 'tachyon_diag-telemetry__kpi' }, [
          E(
            'span',
            { class: 'tachyon_diag-telemetry__kpi-label' },
            tr('Пул устройств', 'Device Pool'),
          ),
          E(
            'strong',
            { class: 'tachyon_diag-telemetry__kpi-val' },
            String(Number(memory.connections?.device_buckets) || 0),
          ),
        ]),
      ]),
      E('div', { class: 'tachyon_diag-telemetry__outbounds' }, [
        E(
          'div',
          { class: 'tachyon_diag-telemetry__section-caption' },
          tr(
            'Активные направления маршрутизации (Outbounds)',
            'Active Routing Outbounds',
          ),
        ),
        outbounds.length > 0
          ? E(
              'div',
              { class: 'tachyon_diag-telemetry__outbound-list' },
              outbounds.slice(0, 5).map((ob) => {
                const bytes =
                  (Number(ob.download) || 0) + (Number(ob.upload) || 0);
                const hits = Number(ob.recent_hits) || 0;
                const act = Number(ob.active_connections) || 0;
                const score = bytes + hits * 4096;
                const widthPct = Math.max(
                  6,
                  Math.min(100, Math.round((score / maxOutboundScore) * 100)),
                );
                return E(
                  'div',
                  { class: 'tachyon_diag-telemetry__outbound-row' },
                  [
                    E(
                      'div',
                      { class: 'tachyon_diag-telemetry__outbound-top' },
                      [
                        E(
                          'span',
                          { class: 'tachyon_diag-telemetry__outbound-tag' },
                          ob.tag,
                        ),
                        E(
                          'span',
                          { class: 'tachyon_diag-telemetry__outbound-stats' },
                          `${act > 0 ? `${act} ${tr('сесс.', 'sess.')} · ` : ''}${hits > 0 ? `${hits} ${tr('зап.', 'req.')} · ` : ''}${formatBytes(bytes)}`,
                        ),
                      ],
                    ),
                    E(
                      'div',
                      { class: 'tachyon_diag-telemetry__outbound-bar' },
                      [
                        E('span', {
                          class: 'tachyon_diag-telemetry__outbound-fill',
                          style: `width: ${widthPct}%`,
                        }),
                      ],
                    ),
                  ],
                );
              }),
            )
          : E(
              'div',
              { class: 'tachyon_diag-telemetry__empty' },
              tr(
                'Нет накопленной статистики по направлениям',
                'No outbound statistics collected yet',
              ),
            ),
      ]),
      E('div', { class: 'tachyon_diag-telemetry__card-actions' }, [
        trimBtn,
        recheckBtn,
      ]),
    ],
  );

  // Card 3: Leak Audit, Failover & Flight Recorder
  const ipv6LeakRisk = Boolean(leak.ipv6?.leak_risk);
  const stunLeakRisk = Boolean(leak.webrtc_stun?.leak_risk);
  const stunOutbound = String(leak.webrtc_stun?.outbound || '').trim();
  const stunStatusText = stunLeakRisk
    ? tr('Открыт', 'Exposed')
    : !leak.webrtc_stun?.is_direct && stunOutbound
      ? tr('Через прокси', 'Via proxy')
      : tr('Под контролем', 'Protected');
  const dnsEnabled = leak.dns?.engine_enabled !== false;
  const isBackupWarn = (g: (typeof failoverGroups)[number]): boolean =>
    Boolean(g.on_backup) &&
    (!g.primary_healthy || String(g.type || '').toLowerCase() !== 'urltest');
  const anyWarnBackup = failoverGroups.some(isBackupWarn);

  const restoreBtn = E(
    'button',
    {
      type: 'button',
      class: 'cbi-button tachyon_diag-telemetry__mini-btn',
      click: () => {
        if (typeof actions.onRestoreFailover === 'function')
          actions.onRestoreFailover();
      },
    },
    tr('Восстановить основные', 'Restore Primary'),
  );

  const clearFlightBtn = E(
    'button',
    {
      type: 'button',
      class: 'cbi-button tachyon_diag-telemetry__mini-btn',
      click: () => {
        if (typeof actions.onClearFlight === 'function')
          actions.onClearFlight();
      },
    },
    tr('Очистить', 'Clear'),
  );

  const auditCard = E('article', { class: 'tachyon_diag-telemetry__card' }, [
    E('header', { class: 'tachyon_diag-telemetry__card-head' }, [
      E('div', { class: 'tachyon_diag-telemetry__title-group' }, [
        iconMarkup('shield', 'tachyon_diag-telemetry__title-icon'),
        E('div', {}, [
          E(
            'h4',
            { class: 'tachyon_diag-telemetry__title' },
            tr(
              'Защита контура и Бортовой самописец',
              'Leak Guard & Flight Recorder',
            ),
          ),
          E(
            'p',
            { class: 'tachyon_diag-telemetry__subtitle' },
            tr(
              'Контроль утечек, статус отказоустойчивости и журнал завершённых сессий',
              'Leak protection, failover status and closed session log',
            ),
          ),
        ]),
      ]),
      E(
        'span',
        {
          class: `tachyon_diag-telemetry__status-badge ${anyWarnBackup || ipv6LeakRisk || stunLeakRisk ? 'is-warn' : 'is-ok'}`,
        },
        anyWarnBackup
          ? tr('На резерве', 'On Backup')
          : tr('Защищено', 'Protected'),
      ),
    ]),
    E('div', { class: 'tachyon_diag-telemetry__leak-grid' }, [
      E('div', { class: 'tachyon_diag-telemetry__leak-chip is-ok' }, [
        E(
          'span',
          { class: 'tachyon_diag-telemetry__leak-name' },
          tr('IPv4 контур', 'IPv4 Route'),
        ),
        E(
          'strong',
          { class: 'tachyon_diag-telemetry__leak-val' },
          String(leak.ipv4?.outbound || 'direct-out'),
        ),
      ]),
      E(
        'div',
        {
          class: `tachyon_diag-telemetry__leak-chip ${ipv6LeakRisk ? 'is-warn' : 'is-ok'}`,
        },
        [
          E(
            'span',
            { class: 'tachyon_diag-telemetry__leak-name' },
            tr('IPv6 контур', 'IPv6 Route'),
          ),
          E(
            'strong',
            { class: 'tachyon_diag-telemetry__leak-val' },
            ipv6LeakRisk
              ? tr('Риск утечки', 'Leak Risk')
              : String(leak.ipv6?.outbound || tr('Защищено', 'Protected')),
          ),
        ],
      ),
      E(
        'div',
        {
          class: `tachyon_diag-telemetry__leak-chip ${stunLeakRisk ? 'is-warn' : 'is-ok'}`,
          title: stunOutbound || undefined,
        },
        [
          E(
            'span',
            { class: 'tachyon_diag-telemetry__leak-name' },
            'WebRTC STUN',
          ),
          E(
            'strong',
            { class: 'tachyon_diag-telemetry__leak-val' },
            stunStatusText,
          ),
        ],
      ),
      E(
        'div',
        {
          class: `tachyon_diag-telemetry__leak-chip ${dnsEnabled ? 'is-ok' : 'is-warn'}`,
        },
        [
          E(
            'span',
            { class: 'tachyon_diag-telemetry__leak-name' },
            tr('Перехват DNS', 'DNS Intercept'),
          ),
          E(
            'strong',
            { class: 'tachyon_diag-telemetry__leak-val' },
            dnsEnabled
              ? tr('Активен (Core)', 'Active (Core)')
              : tr('Отключён', 'Disabled'),
          ),
        ],
      ),
    ]),
    E('div', { class: 'tachyon_diag-telemetry__failover-box' }, [
      E('div', { class: 'tachyon_diag-telemetry__subhead' }, [
        E(
          'span',
          { class: 'tachyon_diag-telemetry__section-caption' },
          `${tr('Группы балансировки и резерва', 'Failover & Balancer Groups')} (${failoverGroups.length})`,
        ),
        restoreBtn,
      ]),
      failoverGroups.length > 0
        ? E(
            'div',
            { class: 'tachyon_diag-telemetry__failover-list' },
            failoverGroups.slice(0, 4).map((g) => {
              const rtt =
                g.primary_rtt_ms != null ? `${g.primary_rtt_ms} ms` : '—';
              return E(
                'div',
                { class: 'tachyon_diag-telemetry__failover-item' },
                [
                  E('div', { class: 'tachyon_diag-telemetry__failover-main' }, [
                    E(
                      'strong',
                      { class: 'tachyon_diag-telemetry__failover-tag' },
                      g.tag,
                    ),
                    E(
                      'span',
                      { class: 'tachyon_diag-telemetry__failover-node' },
                      `→ ${g.current || g.primary || '—'}`,
                    ),
                  ]),
                  E(
                    'div',
                    { class: 'tachyon_diag-telemetry__failover-badges' },
                    [
                      E(
                        'span',
                        { class: 'tachyon_diag-telemetry__rtt-pill' },
                        rtt,
                      ),
                      E(
                        'span',
                        {
                          class: `tachyon_diag-telemetry__backup-pill ${isBackupWarn(g) ? 'is-warn' : 'is-ok'}`,
                        },
                        isBackupWarn(g)
                          ? tr('Резерв', 'Backup')
                          : g.on_backup
                            ? tr('Автовыбор', 'Auto')
                            : tr('Основной', 'Primary'),
                      ),
                    ],
                  ),
                ],
              );
            }),
          )
        : E(
            'div',
            { class: 'tachyon_diag-telemetry__empty' },
            tr(
              'Группы балансировки не настроены',
              'No balancer groups configured',
            ),
          ),
    ]),
    E('div', { class: 'tachyon_diag-telemetry__flight-box' }, [
      E('div', { class: 'tachyon_diag-telemetry__subhead' }, [
        E(
          'span',
          { class: 'tachyon_diag-telemetry__section-caption' },
          `${tr('Бортовой самописец (Flight Recorder)', 'Flight Recorder')} · ${flightCount}`,
        ),
        clearFlightBtn,
      ]),
      flightEntries.length > 0
        ? E(
            'div',
            { class: 'tachyon_diag-telemetry__flight-list' },
            flightEntries.slice(0, 8).map((fl) => {
              const st = String(fl.status || 'ok').toLowerCase();
              const isZero = st === 'zero_transfer';
              const isOk =
                st === 'ok' ||
                st === 'completed' ||
                st === 'closed' ||
                st === 'done' ||
                st === 'success' ||
                st === 'finished';
              const isErr = !isOk && !isZero;
              const badgeText = isErr ? 'ERR' : isZero ? '0 B' : 'OK';
              const badgeTone = isErr
                ? 'is-danger'
                : isZero
                  ? 'is-warn'
                  : 'is-ok';
              const target = fl.host || fl.destination || '—';
              const bytes =
                (Number(fl.download) || 0) + (Number(fl.upload) || 0);
              return E('div', { class: 'tachyon_diag-telemetry__flight-row' }, [
                E(
                  'span',
                  { class: `tachyon_diag-telemetry__flight-pill ${badgeTone}` },
                  badgeText,
                ),
                E(
                  'span',
                  { class: 'tachyon_diag-telemetry__flight-net' },
                  String(fl.network || 'tcp').toUpperCase(),
                ),
                E(
                  'span',
                  {
                    class: 'tachyon_diag-telemetry__flight-host',
                    title: target,
                  },
                  target,
                ),
                E(
                  'span',
                  { class: 'tachyon_diag-telemetry__flight-out' },
                  String(fl.outbound || 'direct'),
                ),
                E(
                  'span',
                  { class: 'tachyon_diag-telemetry__flight-dur' },
                  `${Number(fl.duration_ms) || 0} ms · ${formatBytes(bytes)}`,
                ),
              ]);
            }),
          )
        : E(
            'div',
            { class: 'tachyon_diag-telemetry__empty' },
            tr(
              'Журнал бортового самописца пуст',
              'Flight recorder log is empty',
            ),
          ),
    ]),
  ]);

  return E('section', { class: 'tachyon_diag-telemetry' }, [
    throughputCard,
    resourcesCard,
    auditCard,
  ]);
}
