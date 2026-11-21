import { tr } from '../../helpers/i18n';
import {
  DNS_BLOCK_PERIODS,
  DnsBlockPeriod,
  DnsBlockStatsResponse,
  createEmptyDnsBlockStats,
  fetchDnsBlockStats,
  formatBlockTimestamp,
  formatListSourceLabel,
} from '../../helpers/dnsBlockStats';

function getPeriodLabel(period: DnsBlockPeriod): string {
  switch (period) {
    case '1h':
      return tr('1 час', '1h');
    case '24h':
      return tr('24 часа', '24h');
    case '7d':
      return tr('7 дней', '7d');
    case 'all':
      return tr('Всё время', 'All');
  }
}

function dnsCell(
  label: string,
  value: string | HTMLElement,
  valueClass = '',
): HTMLElement {
  const cls = ['tachyon_monitoring-page__value', valueClass]
    .filter(Boolean)
    .join(' ');
  return E('td', {}, [
    E('span', { class: 'tachyon_monitoring-page__label' }, label),
    E('span', { class: cls }, typeof value === 'string' ? value : [value]),
  ]);
}

function renderSummaryRow(data: DnsBlockStatsResponse) {
  return E('div', { class: 'tachyon_monitoring-page__dns-summary' }, [
    E('div', { class: 'tachyon_monitoring-page__dns-metric' }, [
      E(
        'span',
        { class: 'tachyon_monitoring-page__dns-metric-label' },
        tr('Заблокировано запросов', 'Blocked queries'),
      ),
      E(
        'strong',
        { class: 'tachyon_monitoring-page__dns-metric-value' },
        String(data.total_blocked),
      ),
    ]),
    E('div', { class: 'tachyon_monitoring-page__dns-metric' }, [
      E(
        'span',
        { class: 'tachyon_monitoring-page__dns-metric-label' },
        tr('Клиентов', 'Clients'),
      ),
      E(
        'strong',
        { class: 'tachyon_monitoring-page__dns-metric-value' },
        String(data.unique_clients),
      ),
    ]),
    E('div', { class: 'tachyon_monitoring-page__dns-metric' }, [
      E(
        'span',
        { class: 'tachyon_monitoring-page__dns-metric-label' },
        tr('Уникальных доменов', 'Unique domains'),
      ),
      E(
        'strong',
        { class: 'tachyon_monitoring-page__dns-metric-value' },
        String(data.unique_domains),
      ),
    ]),
  ]);
}

function renderClientsTable(data: DnsBlockStatsResponse) {
  if (!data.clients.length) {
    return null;
  }
  const rows = data.clients.map((client) => {
    const label = client.client_name
      ? `${client.client_name} (${client.client_ip})`
      : client.client_ip;
    const topItem = client.top_domains[0];
    const topDomainText = topItem ? topItem.domain : '-';
    const topRuleText = topItem ? topItem.matched_rule : '-';
    return E('tr', {}, [
      dnsCell(
        tr('Клиент', 'Client'),
        label,
        'tachyon_monitoring-page__dns-cell-mono',
      ),
      dnsCell(
        tr('Блокировок', 'Blocked'),
        String(client.blocked_count),
        'tachyon_monitoring-page__dns-cell-num',
      ),
      dnsCell(
        tr('Доменов', 'Domains'),
        String(client.unique_domains),
        'tachyon_monitoring-page__dns-cell-num',
      ),
      dnsCell(tr('Частый домен', 'Top domain'), topDomainText),
      dnsCell(
        tr('Правило', 'Matched rule'),
        E('code', { class: 'tachyon_monitoring-page__dns-code' }, topRuleText),
      ),
    ]);
  });

  return E('div', { class: 'tachyon_monitoring-page__dns-block' }, [
    E(
      'div',
      { class: 'tachyon_monitoring-page__dns-subtitle' },
      tr('Статистика по клиентам', 'Per-Client Statistics'),
    ),
    E('div', { class: 'tachyon_monitoring-page__table-wrap' }, [
      E('table', { class: 'tachyon_monitoring-page__table' }, [
        E('thead', {}, [
          E('tr', {}, [
            E('th', {}, tr('Клиент', 'Client')),
            E(
              'th',
              { class: 'tachyon_monitoring-page__dns-col-num' },
              tr('Блокировок', 'Blocked'),
            ),
            E(
              'th',
              { class: 'tachyon_monitoring-page__dns-col-num' },
              tr('Доменов', 'Domains'),
            ),
            E('th', {}, tr('Частый домен', 'Top domain')),
            E('th', {}, tr('Правило', 'Matched rule')),
          ]),
        ]),
        E('tbody', {}, rows),
      ]),
    ]),
  ]);
}

function renderTopDomainsTable(data: DnsBlockStatsResponse) {
  if (!data.top_domains.length) {
    return null;
  }
  const rows = data.top_domains.slice(0, 25).map((item) =>
    E('tr', {}, [
      dnsCell(tr('Домен', 'Domain'), item.domain),
      dnsCell(
        tr('Срабатываний', 'Hits'),
        String(item.count),
        'tachyon_monitoring-page__dns-cell-num',
      ),
      dnsCell(
        tr('Правило', 'Rule'),
        E(
          'code',
          { class: 'tachyon_monitoring-page__dns-code' },
          item.matched_rule,
        ),
      ),
      dnsCell(
        tr('Список', 'List'),
        E(
          'code',
          {
            class: 'tachyon_monitoring-page__dns-code',
            title: item.list_source,
          },
          formatListSourceLabel(item.list_source),
        ),
      ),
    ]),
  );

  return E('div', { class: 'tachyon_monitoring-page__dns-block' }, [
    E(
      'div',
      { class: 'tachyon_monitoring-page__dns-subtitle' },
      tr('Заблокированные домены и правила', 'Blocked Domains & Rules'),
    ),
    E('div', { class: 'tachyon_monitoring-page__table-wrap' }, [
      E('table', { class: 'tachyon_monitoring-page__table' }, [
        E('thead', {}, [
          E('tr', {}, [
            E('th', {}, tr('Домен', 'Domain')),
            E(
              'th',
              { class: 'tachyon_monitoring-page__dns-col-num' },
              tr('Срабатываний', 'Hits'),
            ),
            E('th', {}, tr('Правило', 'Rule')),
            E('th', {}, tr('Список', 'Source list')),
          ]),
        ]),
        E('tbody', {}, rows),
      ]),
    ]),
  ]);
}

function renderRecentEventsTable(data: DnsBlockStatsResponse) {
  if (!data.recent_events.length) {
    return null;
  }
  const rows = data.recent_events.slice(0, 20).map((ev) => {
    const clientLabel = ev.client_name
      ? `${ev.client_name} (${ev.client_ip})`
      : ev.client_ip;
    return E('tr', {}, [
      dnsCell(
        tr('Время', 'Time'),
        formatBlockTimestamp(ev.timestamp_unix),
        'tachyon_monitoring-page__dns-cell-num',
      ),
      dnsCell(
        tr('Клиент', 'Client'),
        clientLabel,
        'tachyon_monitoring-page__dns-cell-mono',
      ),
      dnsCell(tr('Домен', 'Domain'), ev.domain),
      dnsCell(
        tr('Правило', 'Rule'),
        E(
          'code',
          { class: 'tachyon_monitoring-page__dns-code' },
          ev.matched_rule,
        ),
      ),
      dnsCell(
        tr('Список', 'List'),
        E(
          'code',
          {
            class: 'tachyon_monitoring-page__dns-code',
            title: ev.list_source,
          },
          formatListSourceLabel(ev.list_source),
        ),
      ),
    ]);
  });

  return E('div', { class: 'tachyon_monitoring-page__dns-block' }, [
    E(
      'div',
      { class: 'tachyon_monitoring-page__dns-subtitle' },
      tr('Последние срабатывания', 'Recent Blocked Queries'),
    ),
    E('div', { class: 'tachyon_monitoring-page__table-wrap' }, [
      E('table', { class: 'tachyon_monitoring-page__table' }, [
        E('thead', {}, [
          E('tr', {}, [
            E('th', {}, tr('Время', 'Time')),
            E('th', {}, tr('Клиент', 'Client')),
            E('th', {}, tr('Домен', 'Domain')),
            E('th', {}, tr('Правило', 'Rule')),
            E('th', {}, tr('Список', 'List')),
          ]),
        ]),
        E('tbody', {}, rows),
      ]),
    ]),
  ]);
}

export function renderDnsBlockStatsBody(
  data: DnsBlockStatsResponse,
  loading: boolean,
): HTMLElement {
  if (loading && !data.generated_at) {
    return E(
      'div',
      {
        class:
          'tachyon_monitoring-page__state tachyon_monitoring-page__state--loading',
      },
      tr('Загрузка статистики DNS...', 'Loading DNS statistics...'),
    );
  }

  if (data.error && !data.total_blocked) {
    return E(
      'div',
      { class: 'tachyon_monitoring-page__state' },
      `${tr('Ошибка загрузки статистики DNS:', 'Failed to load DNS statistics:')} ${data.error}`,
    );
  }

  const children: HTMLElement[] = [renderSummaryRow(data)];
  const clientsTbl = renderClientsTable(data);
  const domainsTbl = renderTopDomainsTable(data);
  const recentTbl = renderRecentEventsTable(data);

  if (clientsTbl) children.push(clientsTbl);
  if (domainsTbl) children.push(domainsTbl);
  if (recentTbl) children.push(recentTbl);

  if (!clientsTbl && !domainsTbl) {
    children.push(
      E(
        'div',
        { class: 'tachyon_monitoring-page__dns-empty' },
        tr(
          'За выбранный период срабатываний правил блокировки DNS не зафиксировано.',
          'No blocked DNS queries recorded for the selected period.',
        ),
      ),
    );
  }

  return E('div', { class: 'tachyon_monitoring-page__dns-content' }, children);
}

export function renderDnsBlockStatsPanel(): HTMLElement {
  const periodButtons = DNS_BLOCK_PERIODS.map((p) =>
    E(
      'button',
      {
        id: `monitoring-dns-period-${p}`,
        type: 'button',
        class:
          p === '24h'
            ? 'btn cbi-button tachyon_monitoring-page__tab tachyon_monitoring-page__tab--active'
            : 'btn cbi-button tachyon_monitoring-page__tab',
      },
      getPeriodLabel(p),
    ),
  );

  return E(
    'div',
    {
      id: 'monitoring-dns-block-stats',
      class:
        'tachyon_monitoring-page__panel tachyon_monitoring-page__dns-panel',
    },
    [
      E('div', { class: 'tachyon_monitoring-page__dns-header' }, [
        E(
          'div',
          { class: 'tachyon_monitoring-page__dns-title' },
          tr('Статистика блокировки DNS', 'DNS Block Statistics'),
        ),
        E('div', { class: 'tachyon_monitoring-page__dns-controls' }, [
          E(
            'div',
            {
              id: 'monitoring-dns-period-tabs',
              class: 'tachyon_monitoring-page__tabs',
              role: 'group',
              'aria-label': tr('Период', 'Period'),
            },
            periodButtons,
          ),
          E(
            'button',
            {
              id: 'monitoring-dns-refresh',
              type: 'button',
              class: 'btn cbi-button tachyon_monitoring-page__tab',
            },
            tr('Обновить', 'Refresh'),
          ),
        ]),
      ]),
      E(
        'div',
        {
          id: 'monitoring-dns-block-stats-body',
          class: 'tachyon_monitoring-page__dns-body',
        },
        [renderDnsBlockStatsBody(createEmptyDnsBlockStats('24h'), true)],
      ),
    ],
  );
}

export interface DnsBlockStatsController {
  mount: () => void;
  unmount: () => void;
  refresh: () => Promise<void>;
  setPeriod: (period: DnsBlockPeriod) => Promise<void>;
  getPeriod: () => DnsBlockPeriod;
}

export function createDnsBlockStatsController(
  fetchImpl?: typeof fetch,
): DnsBlockStatsController {
  let currentPeriod: DnsBlockPeriod = '24h';
  let timer: ReturnType<typeof setInterval> | null = null;
  let mounted = false;
  let reqSeq = 0;

  function syncPeriodTabs() {
    for (const p of DNS_BLOCK_PERIODS) {
      const btn = document.getElementById(`monitoring-dns-period-${p}`);
      if (!btn) continue;
      btn.className =
        p === currentPeriod
          ? 'btn cbi-button tachyon_monitoring-page__tab tachyon_monitoring-page__tab--active'
          : 'btn cbi-button tachyon_monitoring-page__tab';
    }
  }

  function renderData(data: DnsBlockStatsResponse, loading: boolean) {
    const body = document.getElementById('monitoring-dns-block-stats-body');
    if (!body) return;
    body.replaceChildren(renderDnsBlockStatsBody(data, loading));
  }

  async function refresh() {
    if (!document.getElementById('monitoring-dns-block-stats-body')) {
      return;
    }
    const seq = ++reqSeq;
    const data = await fetchDnsBlockStats(currentPeriod, fetchImpl);
    if (!mounted || seq !== reqSeq) return;
    renderData(data, false);
  }

  async function setPeriod(period: DnsBlockPeriod) {
    currentPeriod = period;
    syncPeriodTabs();
    renderData(createEmptyDnsBlockStats(currentPeriod), true);
    await refresh();
  }

  function bindEvents() {
    for (const p of DNS_BLOCK_PERIODS) {
      const btn = document.getElementById(`monitoring-dns-period-${p}`);
      if (btn) {
        btn.onclick = () => {
          void setPeriod(p);
        };
      }
    }
    const refreshBtn = document.getElementById('monitoring-dns-refresh');
    if (refreshBtn) {
      refreshBtn.onclick = () => {
        void refresh();
      };
    }
  }

  function mount() {
    unmount();
    mounted = true;
    syncPeriodTabs();
    bindEvents();
    void refresh();
    timer = setInterval(() => {
      if (mounted && !(typeof document !== 'undefined' && document.hidden)) {
        void refresh();
      }
    }, 10_000);
  }

  function unmount() {
    mounted = false;
    reqSeq += 1;
    if (timer) {
      clearInterval(timer);
      timer = null;
    }
  }

  return {
    mount,
    unmount,
    refresh,
    setPeriod,
    getPeriod: () => currentPeriod,
  };
}
