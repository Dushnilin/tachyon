import { tr } from '../../helpers/i18n';
import {
  DNS_BLOCK_PERIODS,
  DnsBlockClientStat,
  DnsBlockDomainStat,
  DnsBlockEventItem,
  DnsBlockPeriod,
  DnsBlockStatsResponse,
  clearDnsBlockStats,
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

export interface DnsBlockStatsRenderOptions {
  searchQuery?: string;
  selectedClientIp?: string;
  onSelectClient?: (ip: string) => void;
}

function normalizeFilterQuery(raw?: string): string {
  return String(raw || '')
    .trim()
    .toLowerCase();
}

function matchesSearch(
  query: string,
  ...parts: Array<string | undefined>
): boolean {
  if (!query) return true;
  return parts.some((p) =>
    String(p || '')
      .toLowerCase()
      .includes(query),
  );
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
        tr('Заблокировано обращений', 'Blocked requests'),
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
        tr('Уникальных доменов и IP', 'Unique domains & IPs'),
      ),
      E(
        'strong',
        { class: 'tachyon_monitoring-page__dns-metric-value' },
        String(data.unique_domains),
      ),
    ]),
  ]);
}

function deriveClientDomainsFromEvents(
  events: DnsBlockEventItem[],
): DnsBlockDomainStat[] {
  const byDomain = new Map<string, DnsBlockDomainStat>();
  for (const ev of events) {
    const prev = byDomain.get(ev.domain);
    if (prev) {
      prev.count += 1;
      if (ev.timestamp_unix >= prev.last_seen) {
        prev.last_seen = ev.timestamp_unix;
        prev.matched_rule = ev.matched_rule;
        prev.list_source = ev.list_source;
      }
    } else {
      byDomain.set(ev.domain, {
        domain: ev.domain,
        count: 1,
        matched_rule: ev.matched_rule,
        list_source: ev.list_source,
        last_seen: ev.timestamp_unix,
      });
    }
  }
  return Array.from(byDomain.values()).sort(
    (a, b) => b.count - a.count || a.domain.localeCompare(b.domain),
  );
}

function renderClientsTable(
  clients: DnsBlockClientStat[],
  selectedClientIp: string,
  onSelectClient?: (ip: string) => void,
) {
  if (!clients.length) {
    return null;
  }
  const rows = clients.map((client) => {
    const label = client.client_name
      ? `${client.client_name} (${client.client_ip})`
      : client.client_ip;
    const topItem = client.top_domains[0];
    const topDomainText = topItem ? topItem.domain : '-';
    const topRuleText = topItem ? topItem.matched_rule : '-';
    const isSelected = Boolean(
      selectedClientIp && selectedClientIp === client.client_ip,
    );
    return E(
      'tr',
      {
        class: `tachyon_monitoring-page__dns-client-row${isSelected ? ' is-selected' : ''}`,
        title: tr(
          'Нажмите, чтобы отфильтровать домены и события этого клиента',
          'Click to filter domains and events for this client',
        ),
        click: () => {
          onSelectClient?.(isSelected ? '' : client.client_ip);
        },
      },
      [
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
          tr('Целей', 'Targets'),
          String(client.unique_domains),
          'tachyon_monitoring-page__dns-cell-num',
        ),
        dnsCell(tr('Частый домен / IP', 'Top domain / IP'), topDomainText),
        dnsCell(
          tr('Правило', 'Matched rule'),
          E(
            'code',
            { class: 'tachyon_monitoring-page__dns-code' },
            topRuleText,
          ),
        ),
      ],
    );
  });

  return E('div', { class: 'tachyon_monitoring-page__dns-block' }, [
    E(
      'div',
      { class: 'tachyon_monitoring-page__dns-subtitle' },
      tr(
        'Клиенты (кликните по строке для фильтрации)',
        'Clients (click row to filter)',
      ),
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
              tr('Целей', 'Targets'),
            ),
            E('th', {}, tr('Частый домен / IP', 'Top domain / IP')),
            E('th', {}, tr('Правило', 'Matched rule')),
          ]),
        ]),
        E('tbody', {}, rows),
      ]),
    ]),
  ]);
}

function renderTopDomainsTable(
  domains: DnsBlockDomainStat[],
  totalDenominator: number,
) {
  if (!domains.length) {
    return null;
  }
  const sliced = domains.slice(0, 50);
  const maxCount = Math.max(1, ...sliced.map((d) => d.count));
  const denom = Math.max(1, totalDenominator);

  const rows = sliced.map((item) => {
    const sharePct = Math.min(
      100,
      Math.round((item.count * 1000) / denom) / 10,
    );
    const barPct = Math.max(
      4,
      Math.min(100, Math.round((item.count * 100) / maxCount)),
    );
    const hitsWidget = E(
      'div',
      { class: 'tachyon_monitoring-page__dns-hits-cell' },
      [
        E('span', {}, String(item.count)),
        E(
          'span',
          { class: 'tachyon_monitoring-page__dns-pct' },
          `${sharePct % 1 === 0 ? sharePct.toFixed(0) : sharePct.toFixed(1)}%`,
        ),
        E('span', { class: 'tachyon_monitoring-page__dns-bar-track' }, [
          E('span', {
            class: 'tachyon_monitoring-page__dns-bar-fill',
            style: `width:${barPct}%`,
          }),
        ]),
      ],
    );

    return E('tr', {}, [
      dnsCell(
        tr('Домен / IP', 'Domain / IP'),
        item.domain,
        'tachyon_monitoring-page__dns-cell-mono',
      ),
      dnsCell(
        tr('Срабатываний', 'Hits'),
        hitsWidget,
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
        tr('Список / причина', 'Source'),
        E(
          'code',
          {
            class: 'tachyon_monitoring-page__dns-code',
            title: item.list_source,
          },
          formatListSourceLabel(item.list_source),
        ),
      ),
    ]);
  });

  return E('div', { class: 'tachyon_monitoring-page__dns-block' }, [
    E(
      'div',
      { class: 'tachyon_monitoring-page__dns-subtitle' },
      tr('Топ заблокированных доменов и IP', 'Top Blocked Domains & IPs'),
    ),
    E('div', { class: 'tachyon_monitoring-page__table-wrap' }, [
      E('table', { class: 'tachyon_monitoring-page__table' }, [
        E('thead', {}, [
          E('tr', {}, [
            E('th', {}, tr('Домен / IP', 'Domain / IP')),
            E(
              'th',
              { class: 'tachyon_monitoring-page__dns-col-num' },
              tr('Срабатываний', 'Hits'),
            ),
            E('th', {}, tr('Правило', 'Rule')),
            E('th', {}, tr('Список / причина', 'Source')),
          ]),
        ]),
        E('tbody', {}, rows),
      ]),
    ]),
  ]);
}

function renderRecentEventsTable(events: DnsBlockEventItem[]) {
  if (!events.length) {
    return null;
  }
  const rows = events.slice(0, 50).map((ev) => {
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
      dnsCell(
        tr('Домен / IP', 'Domain / IP'),
        ev.domain,
        'tachyon_monitoring-page__dns-cell-mono',
      ),
      dnsCell(
        tr('Правило', 'Rule'),
        E(
          'code',
          { class: 'tachyon_monitoring-page__dns-code' },
          ev.matched_rule,
        ),
      ),
      dnsCell(
        tr('Список / причина', 'Source'),
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
      tr('Журнал последних блокировок', 'Recent Blocked Log'),
    ),
    E('div', { class: 'tachyon_monitoring-page__table-wrap' }, [
      E('table', { class: 'tachyon_monitoring-page__table' }, [
        E('thead', {}, [
          E('tr', {}, [
            E('th', {}, tr('Время', 'Time')),
            E('th', {}, tr('Клиент', 'Client')),
            E('th', {}, tr('Домен / IP', 'Domain / IP')),
            E('th', {}, tr('Правило', 'Rule')),
            E('th', {}, tr('Список / причина', 'Source')),
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
  options: DnsBlockStatsRenderOptions = {},
): HTMLElement {
  if (loading && !data.generated_at) {
    return E(
      'div',
      {
        class:
          'tachyon_monitoring-page__state tachyon_monitoring-page__state--loading',
      },
      tr(
        'Загрузка статистики блокировок...',
        'Loading blocked domains statistics...',
      ),
    );
  }

  if (data.error && !data.total_blocked) {
    return E(
      'div',
      { class: 'tachyon_monitoring-page__state' },
      `${tr('Ошибка загрузки статистики DNS:', 'Failed to load DNS statistics:')} ${data.error}`,
    );
  }

  const query = normalizeFilterQuery(options.searchQuery);
  const selectedClientIp = String(options.selectedClientIp || '').trim();

  const matchingClients = data.clients.filter((c) => {
    if (selectedClientIp && c.client_ip !== selectedClientIp) return false;
    return matchesSearch(
      query,
      c.client_ip,
      c.client_name,
      c.top_domains[0]?.domain,
      c.top_domains[0]?.matched_rule,
    );
  });

  const matchingRecent = data.recent_events.filter((ev) => {
    if (selectedClientIp && ev.client_ip !== selectedClientIp) return false;
    return matchesSearch(
      query,
      ev.domain,
      ev.client_ip,
      ev.client_name,
      ev.matched_rule,
      ev.list_source,
    );
  });

  let domainSource = data.top_domains;
  let shareTotal = data.total_blocked;
  if (selectedClientIp) {
    const clientObj = data.clients.find(
      (c) => c.client_ip === selectedClientIp,
    );
    const derived = deriveClientDomainsFromEvents(matchingRecent);
    if (clientObj && clientObj.top_domains.length > 0) {
      domainSource = clientObj.top_domains;
      shareTotal = Math.max(1, clientObj.blocked_count);
    } else {
      domainSource = derived;
      shareTotal = Math.max(1, matchingRecent.length);
    }
  }
  const matchingDomains = domainSource.filter((d) =>
    matchesSearch(query, d.domain, d.matched_rule, d.list_source),
  );

  const children: HTMLElement[] = [renderSummaryRow(data)];
  const clientsTbl = renderClientsTable(
    matchingClients,
    selectedClientIp,
    options.onSelectClient,
  );
  const domainsTbl = renderTopDomainsTable(matchingDomains, shareTotal);
  const recentTbl = renderRecentEventsTable(matchingRecent);

  if (domainsTbl) children.push(domainsTbl);
  if (clientsTbl) children.push(clientsTbl);
  if (recentTbl) children.push(recentTbl);

  if (!clientsTbl && !domainsTbl && !recentTbl) {
    children.push(
      E(
        'div',
        { class: 'tachyon_monitoring-page__dns-empty' },
        query || selectedClientIp
          ? tr(
              'По заданному фильтру заблокированных обращений не найдено.',
              'No blocked requests match the current filter.',
            )
          : tr(
              'За выбранный период срабатываний правил блокировки не зафиксировано.',
              'No blocked requests recorded for the selected period.',
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
        'tachyon_monitoring-page__panel tachyon_monitoring-page__dns-panel tachyon_monitoring-page__dns-panel--hidden',
    },
    [
      E('div', { class: 'tachyon_monitoring-page__dns-header' }, [
        E(
          'div',
          { class: 'tachyon_monitoring-page__dns-title' },
          tr('Заблокированные домены и реклама', 'Blocked domains & ads'),
        ),
        E('div', { class: 'tachyon_monitoring-page__dns-controls' }, [
          E(
            'button',
            {
              id: 'monitoring-dns-client-chip',
              type: 'button',
              class: 'btn cbi-button tachyon_monitoring-page__dns-chip-btn',
              hidden: true,
            },
            '',
          ),
          E('label', { class: 'tachyon_monitoring-page__search' }, [
            E('input', {
              id: 'monitoring-dns-search',
              type: 'search',
              class:
                'cbi-input-text tachyon_monitoring-page__search-input tachyon_monitoring-page__dns-search',
              placeholder: tr(
                'Поиск домена, IP, правила или клиента...',
                'Search domain, IP, rule or client...',
              ),
              autocomplete: 'off',
            }),
          ]),
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
          E(
            'button',
            {
              id: 'monitoring-dns-clear',
              type: 'button',
              class: 'btn cbi-button tachyon_monitoring-page__tab',
            },
            tr('Очистить', 'Clear'),
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

export interface DnsBlockStatsControllerOptions {
  onData?: (data: DnsBlockStatsResponse) => void;
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
  controllerOptions: DnsBlockStatsControllerOptions = {},
): DnsBlockStatsController {
  let currentPeriod: DnsBlockPeriod = '24h';
  let searchQuery = '';
  let selectedClientIp = '';
  let latestData: DnsBlockStatsResponse = createEmptyDnsBlockStats('24h');
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

  function syncClientChip() {
    const chip = document.getElementById(
      'monitoring-dns-client-chip',
    ) as HTMLButtonElement | null;
    if (!chip) return;
    if (!selectedClientIp) {
      chip.hidden = true;
      chip.textContent = '';
      return;
    }
    chip.hidden = false;
    chip.textContent = `${tr('Клиент:', 'Client:')} ${selectedClientIp} ×`;
  }

  function renderData(data: DnsBlockStatsResponse, loading: boolean) {
    latestData = data;
    syncClientChip();
    const body = document.getElementById('monitoring-dns-block-stats-body');
    if (!body) return;
    body.replaceChildren(
      renderDnsBlockStatsBody(data, loading, {
        searchQuery,
        selectedClientIp,
        onSelectClient: (nextIp) => {
          selectedClientIp = nextIp;
          renderData(latestData, false);
        },
      }),
    );
  }

  async function refresh() {
    if (!document.getElementById('monitoring-dns-block-stats-body')) {
      return;
    }
    const seq = ++reqSeq;
    const data = await fetchDnsBlockStats(currentPeriod, fetchImpl);
    if (!mounted || seq !== reqSeq) return;
    controllerOptions.onData?.(data);
    renderData(data, false);
  }

  async function setPeriod(period: DnsBlockPeriod) {
    currentPeriod = period;
    syncPeriodTabs();
    renderData(createEmptyDnsBlockStats(currentPeriod), true);
    await refresh();
  }

  async function clearStats() {
    const res = await clearDnsBlockStats(fetchImpl);
    if (!mounted) return;
    if (res.ok) {
      selectedClientIp = '';
      await refresh();
    }
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
    const clearBtn = document.getElementById('monitoring-dns-clear');
    if (clearBtn) {
      clearBtn.onclick = () => {
        void clearStats();
      };
    }
    const chip = document.getElementById('monitoring-dns-client-chip');
    if (chip) {
      chip.onclick = () => {
        selectedClientIp = '';
        renderData(latestData, false);
      };
    }
    const searchInput = document.getElementById(
      'monitoring-dns-search',
    ) as HTMLInputElement | null;
    if (searchInput) {
      searchInput.oninput = () => {
        searchQuery = String(searchInput.value || '');
        renderData(latestData, false);
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
