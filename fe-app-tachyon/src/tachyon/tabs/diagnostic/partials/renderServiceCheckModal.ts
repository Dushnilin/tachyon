import { callBaseMethod } from '../../../methods/shell/callBaseMethod';
import { renderButton } from '../../../../partials';
import { renderZapIcon } from '../../../../icons';
import { Tachyon } from '../../../types';

interface ServiceCheckTarget {
  section: string;
  route_type: string;
  domain: string;
}

interface ServiceCheckResult extends ServiceCheckTarget {
  ip: string;
  dns_ms: number;
  tcp_ms: number;
  tls_ms: number;
  http_ms: number;
  status_class: string;
  success: boolean;
}

/**
 * Format raw backend route strings into localized display labels.
 */
function formatRouteType(routeType: string): string {
  if (!routeType) return _('Direct');
  const clean = routeType.trim();

  if (clean === 'connection' || clean === 'proxy' || clean === 'outbound') {
    return _('Proxy');
  }
  if (clean === 'direct') {
    return _('Direct');
  }
  if (clean === 'auto') {
    return _('Auto');
  }
  if (clean === 'hosts' || clean === 'dns') {
    return 'Hosts / DNS';
  }
  if (clean.startsWith('desync')) {
    return clean.replace(/^desync/, 'Desync');
  }

  return clean;
}

/**
 * Map section names to localized display titles.
 */
function formatSectionName(name: string): string {
  if (!name) return '';
  const clean = name.trim();

  const sectionMap: Record<string, string> = {
    'Базовая связность': _('Basic connectivity'),
    'Свои домены': _('Custom domains'),
    Custom: _('Custom'),
    'ChatGPT / OpenAI': 'ChatGPT / OpenAI',
    'Claude / Anthropic': 'Claude / Anthropic',
    'Gemini / Google AI': 'Gemini / Google AI',
    'Instagram / Meta': 'Instagram / Meta',
    'X / Twitter': 'X / Twitter',
    'X (Twitter)': 'X / Twitter',
    'UDP / QUIC': _('UDP / QUIC protocols'),
    Telegram: 'Telegram',
    Instagram: 'Instagram',
    YouTube: 'YouTube',
    TikTok: 'TikTok',
    Discord: 'Discord',
    Facebook: 'Facebook',
    WhatsApp: 'WhatsApp',
    Netflix: 'Netflix',
    Spotify: 'Spotify',
    Twitch: 'Twitch',
    Steam: 'Steam',
    GitHub: 'GitHub',
  };

  return sectionMap[clean] || clean;
}

/**
 * Render a native LuCI status badge matching active theme colors.
 */
function renderStatusBadge(
  statusClass: string,
  isTesting = false,
  isPending = false,
): HTMLElement {
  const monoFont =
    'font-family: var(--tachyon-font-mono, ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace); font-variant-numeric: tabular-nums;';
  if (isPending) {
    return E(
      'span',
      {
        style: `display: inline-flex; align-items: center; justify-content: center; font-size: 11px; font-weight: 600; padding: 2px 8px; border-radius: 4px; background: #18181c; color: #71717a; border: 1px solid rgba(255, 255, 255, 0.08); ${monoFont}`,
      },
      _('Pending...'),
    );
  }
  if (isTesting) {
    return E(
      'span',
      {
        style: `display: inline-flex; align-items: center; justify-content: center; font-size: 11px; font-weight: 600; padding: 2px 8px; border-radius: 4px; background: rgba(59, 130, 246, 0.12); color: #60a5fa; border: 1px solid rgba(59, 130, 246, 0.28); ${monoFont}`,
      },
      _('Testing...'),
    );
  }

  const cleanStatus = statusClass || '';
  const isOk =
    cleanStatus.toUpperCase().includes('OK') ||
    cleanStatus === '200' ||
    cleanStatus === 'OK';

  if (isOk) {
    return E(
      'span',
      {
        style: `display: inline-flex; align-items: center; justify-content: center; font-weight: 600; font-size: 11px; padding: 2px 8px; border-radius: 4px; background: rgba(16, 185, 129, 0.12); color: #34d399; border: 1px solid rgba(16, 185, 129, 0.28); ${monoFont}`,
      },
      _('Available'),
    );
  }

  return E(
    'span',
    {
      style: `display: inline-flex; align-items: center; justify-content: center; font-weight: 600; font-size: 11px; line-height: 1.3; padding: 2px 8px; border-radius: 4px; background: rgba(239, 68, 68, 0.12); color: #f87171; border: 1px solid rgba(239, 68, 68, 0.28); text-align: center; ${monoFont}`,
    },
    cleanStatus || _('Unavailable'),
  );
}

export function renderServiceCheckModal() {
  const container = E(
    'div',
    {
      class: 'tachyon-service-check-modal-wrapper',
      style: 'width: 100%; box-sizing: border-box;',
    },
    [
      E(
        'p',
        { style: 'text-align: center; margin-top: 20px;' },
        _('Loading service list...'),
      ),
      E(
        'div',
        {
          class: 'spinning',
          style:
            'text-align: center; color: var(--border-color, #007bff); display: flex; justify-content: center;',
        },
        [renderZapIcon(24)],
      ),
    ],
  );

  const modalContent = E(
    'div',
    { style: 'width: 100%; box-sizing: border-box;' },
    [
      container,
      E(
        'div',
        {
          id: 'tachyon-service-check-footer',
          style:
            'margin-top: 15px; display: flex; justify-content: space-between; align-items: center; gap: 10px; border-top: 1px solid var(--border-color, rgba(128,128,128,0.2)); padding-top: 12px; flex-wrap: wrap;',
        },
        [
          renderButton({
            text: _('Close'),
            onClick: () => ui.hideModal(),
          }),
        ],
      ),
    ],
  );

  ui.showModal(_('Service availability check'), modalContent);

  const loadTargets = (targetMode: 'active' | 'all') => {
    container.innerHTML = '';
    container.appendChild(
      E(
        'p',
        { style: 'text-align: center; margin-top: 20px;' },
        _('Loading service list...'),
      ),
    );

    const args =
      targetMode === 'all' ? ['get-targets', 'all'] : ['get-targets'];

    callBaseMethod(Tachyon.AvailableMethods.SERVICE_HEALTH_CHECK, args)
      .then((res: unknown) => {
        const response = res as {
          success?: boolean;
          data?: string | ServiceCheckTarget[];
        };
        container.innerHTML = '';
        if (!response || !response.success) {
          container.appendChild(
            E(
              'p',
              { style: 'color: var(--color-danger, #dc3545);' },
              _('Failed to start service check.'),
            ),
          );
          return;
        }

        let targets: ServiceCheckTarget[] = [];
        try {
          if (typeof response.data === 'string') {
            targets = JSON.parse(response.data);
          } else if (Array.isArray(response.data)) {
            targets = response.data;
          }
        } catch (_e) {
          container.appendChild(
            E(
              'p',
              { style: 'color: var(--color-danger, #dc3545);' },
              _('Failed to parse target list.'),
            ),
          );
          return;
        }

        if (targets.length === 0) {
          container.appendChild(
            E('p', {}, _('No check targets found in the configuration.')),
          );
          return;
        }

        const activeSectionsBtn = renderButton({
          text: _('Active routes'),
          classNames: [
            targetMode === 'active'
              ? 'cbi-button-action'
              : 'cbi-button-neutral',
          ],
          onClick: () => loadTargets('active'),
        });
        activeSectionsBtn.style.fontSize = '12px';
        activeSectionsBtn.style.padding = '4px 12px';

        const allProfilesBtn = renderButton({
          text: _('All services'),
          classNames: [
            targetMode === 'all' ? 'cbi-button-action' : 'cbi-button-neutral',
          ],
          onClick: () => loadTargets('all'),
        });
        allProfilesBtn.style.fontSize = '12px';
        allProfilesBtn.style.padding = '4px 12px';

        const modeSwitcherBar = E(
          'div',
          {
            style:
              'display: flex; gap: 10px; align-items: center; margin-bottom: 14px; border-bottom: 1px solid var(--border-color, rgba(128,128,128,0.2)); padding-bottom: 10px;',
          },
          [
            E(
              'span',
              { style: 'font-weight: 600; font-size: 13px; opacity: 0.9;' },
              _('Check mode:'),
            ),
            activeSectionsBtn,
            allProfilesBtn,
          ],
        );

        const sectionNames = Array.from(new Set(targets.map((t) => t.section)));
        let activeFilter = 'ALL';
        let searchQuery = '';

        const monoStyle =
          'font-family: var(--tachyon-font-mono, ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace); font-variant-numeric: tabular-nums;';

        const totalStatEl = E(
          'b',
          {
            style: `font-size: 18px; font-weight: 600; display: block; margin-top: 4px; color: #f4f4f5; ${monoStyle}`,
          },
          `${targets.length}`,
        );
        const passedStatEl = E(
          'b',
          {
            style: `font-size: 18px; font-weight: 600; color: #34d399; display: block; margin-top: 4px; ${monoStyle}`,
          },
          '0',
        );
        const failedStatEl = E(
          'b',
          {
            style: `font-size: 18px; font-weight: 600; color: #f87171; display: block; margin-top: 4px; ${monoStyle}`,
          },
          '0',
        );
        const latencyStatEl = E(
          'b',
          {
            style: `font-size: 18px; font-weight: 600; color: #60a5fa; display: block; margin-top: 4px; ${monoStyle}`,
          },
          '-',
        );

        const createStatCard = (
          title: string,
          valueEl: HTMLElement,
          dotColor = '#71717a',
        ) => {
          return E(
            'div',
            {
              style:
                'padding: 9px 12px; border: 1px solid rgba(255, 255, 255, 0.08); border-radius: 4px; text-align: left; background: #121215; margin: 0; box-sizing: border-box;',
            },
            [
              E(
                'small',
                {
                  style:
                    'display: inline-flex; align-items: center; gap: 6px; font-size: 11px; font-weight: 600; color: #a1a1aa;',
                },
                [
                  E('span', {
                    style: `width: 6px; height: 6px; border-radius: 50%; background: ${dotColor}; flex-shrink: 0;`,
                  }),
                  title,
                ],
              ),
              valueEl,
            ],
          );
        };

        const statsBar = E(
          'div',
          {
            style:
              'display: grid; grid-template-columns: repeat(auto-fit, minmax(130px, 1fr)); gap: 8px; margin-bottom: 12px; width: 100%; box-sizing: border-box;',
          },
          [
            createStatCard(_('Total targets'), totalStatEl, '#71717a'),
            createStatCard(_('Available'), passedStatEl, '#10b981'),
            createStatCard(_('Unavailable'), failedStatEl, '#ef4444'),
            createStatCard(_('Avg. latency'), latencyStatEl, '#3b82f6'),
          ],
        );

        const progressBarInner = E('div', {
          style:
            'width: 0%; height: 100%; background: #3b82f6; transition: width 0.18s cubic-bezier(0.22, 1, 0.36, 1);',
        });
        const progressBarContainer = E(
          'div',
          {
            style:
              'width: 100%; height: 4px; background: #18181c; border-radius: 2px; overflow: hidden; margin-bottom: 12px; display: none;',
          },
          [progressBarInner],
        );

        const sectionSelect = E(
          'select',
          {
            class: 'cbi-input-select',
            style:
              'padding: 4px 8px; font-size: 12px; border-radius: 4px; max-width: 240px;',
          },
          [
            E(
              'option',
              { value: 'ALL' },
              `${_('All services')} (${targets.length})`,
            ),
            ...sectionNames.map((sec) => {
              const count = targets.filter((t) => t.section === sec).length;
              return E(
                'option',
                { value: sec },
                `${formatSectionName(sec)} (${count})`,
              );
            }),
          ],
        ) as HTMLSelectElement;

        sectionSelect.onchange = () => {
          activeFilter = sectionSelect.value;
          applyTableFilter();
        };

        // Search Box
        const searchInput = E('input', {
          type: 'text',
          placeholder: _('Search domain or service...'),
          class: 'cbi-input-text',
          style:
            'width: 200px; padding: 4px 10px; font-size: 12px; border-radius: 4px;',
        });
        searchInput.oninput = (e: Event) => {
          const targetInput = e.target as HTMLInputElement;
          searchQuery = (targetInput?.value || '').toLowerCase().trim();
          applyTableFilter();
        };

        const toolbar = E(
          'div',
          {
            style:
              'display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px; gap: 10px; flex-wrap: wrap;',
          },
          [
            E(
              'div',
              {
                style:
                  'display: flex; gap: 8px; align-items: center; flex-wrap: wrap;',
              },
              [
                E(
                  'span',
                  { style: 'font-size: 12px; opacity: 0.8;' },
                  _('Filter by service:'),
                ),
                sectionSelect,
              ],
            ),
            searchInput,
          ],
        );

        // Table Container
        const tableHead = E('tr', { class: 'tr cbi-section-table-titles' }, [
          E(
            'th',
            { class: 'th', style: 'width: 28%; padding: 8px;' },
            _('Service / Target'),
          ),
          E(
            'th',
            { class: 'th', style: 'width: 17%; padding: 8px;' },
            _('Route'),
          ),
          E(
            'th',
            { class: 'th', style: 'width: 20%; padding: 8px;' },
            'IP / DNS',
          ),
          E(
            'th',
            {
              class: 'th',
              style: 'text-align: right; width: 7%; padding: 8px 4px;',
            },
            'TCP',
          ),
          E(
            'th',
            {
              class: 'th',
              style: 'text-align: right; width: 7%; padding: 8px 4px;',
            },
            'TLS',
          ),
          E(
            'th',
            {
              class: 'th',
              style: 'text-align: right; width: 7%; padding: 8px 4px;',
            },
            'HTTP',
          ),
          E(
            'th',
            {
              class: 'th',
              style: 'text-align: center; width: 14%; padding: 8px 6px;',
            },
            _('Status'),
          ),
        ]);

        const tableBody = E('tbody', {});
        const table = E(
          'table',
          {
            class: 'table cbi-section-table',
            style:
              'width: 100%; margin: 0; table-layout: fixed; box-sizing: border-box;',
          },
          [
            E(
              'thead',
              {
                style:
                  'position: sticky; top: 0; background: #16161a; z-index: 2; border-bottom: 1px solid rgba(255, 255, 255, 0.08);',
              },
              [tableHead],
            ),
            tableBody,
          ],
        );

        const tableScrollWrapper = E(
          'div',
          {
            style:
              'max-height: 400px; overflow-y: auto; overflow-x: hidden; border: 1px solid rgba(255, 255, 255, 0.08); border-radius: 6px; width: 100%; box-sizing: border-box; background: #121215;',
          },
          [table],
        );

        const rowMap: {
          target: ServiceCheckTarget;
          tr: HTMLElement;
          result?: ServiceCheckResult;
        }[] = [];

        targets.forEach((item, index) => {
          const rowClass =
            index % 2 === 0 ? 'cbi-rowstyle-1' : 'cbi-rowstyle-2';
          const badge = renderStatusBadge('', false, true);

          const tr = E('tr', { class: `tr ${rowClass}` }, [
            E(
              'td',
              { class: 'td', style: 'word-break: break-all; padding: 8px;' },
              [
                E(
                  'span',
                  { style: 'font-weight: 600; font-size: 12px;' },
                  formatSectionName(item.section),
                ),
                E('br'),
                E('small', { style: 'opacity: 0.8;' }, item.domain),
              ],
            ),
            E('td', { class: 'td', style: 'font-size: 12px; padding: 8px;' }, [
              E(
                'span',
                {
                  class: 'badge cbi-value-title',
                  style: 'font-size: 11px; padding: 2px 6px;',
                },
                formatRouteType(item.route_type),
              ),
            ]),
            E('td', { class: 'td', style: 'font-size: 12px; padding: 8px;' }, [
              E('span', {}, '?'),
              E('br'),
              E('small', { style: 'opacity: 0.6;' }, `-`),
            ]),
            E(
              'td',
              {
                class: 'td',
                style: 'text-align: right; font-size: 12px; padding: 8px 4px;',
              },
              '-',
            ),
            E(
              'td',
              {
                class: 'td',
                style: 'text-align: right; font-size: 12px; padding: 8px 4px;',
              },
              '-',
            ),
            E(
              'td',
              {
                class: 'td',
                style: 'text-align: right; font-size: 12px; padding: 8px 4px;',
              },
              '-',
            ),
            E(
              'td',
              { class: 'td', style: 'text-align: center; padding: 8px 6px;' },
              badge,
            ),
          ]);

          rowMap.push({ target: item, tr });
          tableBody.appendChild(tr);
        });

        const applyTableFilter = () => {
          rowMap.forEach(({ target, tr }) => {
            const matchesSection =
              activeFilter === 'ALL' || target.section === activeFilter;
            const matchesSearch =
              !searchQuery ||
              target.domain.toLowerCase().includes(searchQuery) ||
              target.section.toLowerCase().includes(searchQuery) ||
              formatSectionName(target.section)
                .toLowerCase()
                .includes(searchQuery);
            tr.style.display = matchesSection && matchesSearch ? '' : 'none';
          });
        };

        const updateSummaryStats = () => {
          let passed = 0;
          let failed = 0;
          let totalLat = 0;
          let countLat = 0;

          rowMap.forEach(({ result }) => {
            if (result) {
              if (result.success) passed++;
              else failed++;

              const lat = result.http_ms || result.tls_ms || result.tcp_ms || 0;
              if (lat > 0) {
                totalLat += lat;
                countLat++;
              }
            }
          });

          passedStatEl.textContent = `${passed}`;
          failedStatEl.textContent = `${failed}`;
          latencyStatEl.textContent =
            countLat > 0 ? `${Math.round(totalLat / countLat)} ms` : '-';
        };

        container.appendChild(modeSwitcherBar);
        container.appendChild(statsBar);
        container.appendChild(progressBarContainer);
        container.appendChild(toolbar);
        container.appendChild(tableScrollWrapper);

        // Custom domain input & Check Buttons
        const footer = document.getElementById('tachyon-service-check-footer');
        if (footer) {
          footer.innerHTML = '';

          const customDomainInput = E('input', {
            type: 'text',
            id: 'custom-domain-input',
            placeholder: _(
              'Enter a domain or IP to check (e.g. example.com)...',
            ),
            class: 'cbi-input-text',
            style:
              'flex: 1 1 200px; min-width: 150px; max-width: 300px; font-size: 12px; box-sizing: border-box;',
          });

          const customBtn = renderButton({
            text: _('Check domain'),
            classNames: ['cbi-button-neutral'],
            onClick: async () => {
              const domain = customDomainInput.value.trim();
              if (!domain) return;

              customBtn.disabled = true;
              customBtn.textContent = '...';

              try {
                const cRes = (await callBaseMethod(
                  Tachyon.AvailableMethods.SERVICE_HEALTH_CHECK,
                  ['check-custom', domain],
                )) as {
                  success?: boolean;
                  data?: string | ServiceCheckResult[];
                };

                if (cRes && cRes.success) {
                  const cResults: ServiceCheckResult[] =
                    typeof cRes.data === 'string'
                      ? JSON.parse(cRes.data)
                      : cRes.data || [];

                  if (cResults && cResults.length > 0) {
                    const cItem: ServiceCheckResult = cResults[0];
                    const cBadge = renderStatusBadge(cItem.status_class);

                    const customTr = E('tr', { class: 'tr cbi-rowstyle-1' }, [
                      E(
                        'td',
                        {
                          class: 'td',
                          style: 'word-break: break-all; padding: 8px;',
                        },
                        [
                          E(
                            'span',
                            { style: 'font-weight: 600;' },
                            formatSectionName(cItem.section),
                          ),
                          E('br'),
                          E('small', {}, cItem.domain),
                        ],
                      ),
                      E(
                        'td',
                        {
                          class: 'td',
                          style: 'font-size: 12px; padding: 8px;',
                        },
                        [
                          E(
                            'span',
                            {
                              class: 'badge cbi-value-title',
                              style: 'font-size: 11px; padding: 2px 6px;',
                            },
                            formatRouteType(cItem.route_type),
                          ),
                        ],
                      ),
                      E(
                        'td',
                        {
                          class: 'td',
                          style: 'font-size: 12px; padding: 8px;',
                        },
                        [
                          cItem.ip || '?',
                          E('br'),
                          E('small', {}, `${cItem.dns_ms}ms`),
                        ],
                      ),
                      E(
                        'td',
                        {
                          class: 'td',
                          style: 'text-align: right; padding: 8px 4px;',
                        },
                        cItem.tcp_ms > 0 ? `${cItem.tcp_ms}` : '-',
                      ),
                      E(
                        'td',
                        {
                          class: 'td',
                          style: 'text-align: right; padding: 8px 4px;',
                        },
                        cItem.tls_ms > 0 ? `${cItem.tls_ms}` : '-',
                      ),
                      E(
                        'td',
                        {
                          class: 'td',
                          style: 'text-align: right; padding: 8px 4px;',
                        },
                        cItem.http_ms > 0 ? `${cItem.http_ms}` : '-',
                      ),
                      E(
                        'td',
                        {
                          class: 'td',
                          style: 'text-align: center; padding: 8px 6px;',
                        },
                        cBadge,
                      ),
                    ]);

                    tableBody.insertBefore(customTr, tableBody.firstChild);
                    rowMap.unshift({
                      target: {
                        section: 'Custom',
                        route_type: 'auto',
                        domain: cItem.domain,
                      },
                      tr: customTr,
                      result: cItem,
                    });
                    updateSummaryStats();
                    customDomainInput.value = '';
                  }
                }
              } catch (_e) {
                // Ignore custom check errors
              } finally {
                customBtn.disabled = false;
                customBtn.textContent = _('Check domain');
              }
            },
          });

          const leftWrap = E(
            'div',
            {
              style:
                'display: flex; gap: 8px; align-items: center; flex: 1 1 300px; min-width: 0; flex-wrap: wrap;',
            },
            [customDomainInput, customBtn],
          );

          let isModalClosed = false;
          let activeCheckRunId = 0;
          const initiallyConnected = Boolean(container.isConnected);

          const checkAllBtn = renderButton({
            text: _('Check all'),
            classNames: ['cbi-button-action'],
            onClick: async () => {
              const myRunId = ++activeCheckRunId;
              checkAllBtn.disabled = true;
              checkAllBtn.textContent = _('Testing...');

              progressBarContainer.style.display = 'block';
              progressBarInner.style.width = '0%';

              const rowsToCheck = rowMap.filter((r) => {
                const matchSearch =
                  !searchQuery ||
                  r.target.domain.toLowerCase().includes(searchQuery) ||
                  r.target.section.toLowerCase().includes(searchQuery);
                const matchTab =
                  activeFilter === 'ALL' || r.target.section === activeFilter;
                return matchSearch && matchTab;
              });
              const targetRows = rowsToCheck.length > 0 ? rowsToCheck : rowMap;
              let completedCount = 0;
              let nextIdx = 0;
              const concurrency = Math.min(4, targetRows.length || 1);

              const runWorker = async () => {
                while (nextIdx < targetRows.length) {
                  if (
                    isModalClosed ||
                    myRunId !== activeCheckRunId ||
                    (initiallyConnected && !container.isConnected)
                  ) {
                    break;
                  }
                  const itemObj = targetRows[nextIdx++];
                  const { target, tr } = itemObj;

                  const badgeCell = tr.childNodes[6] as HTMLElement;
                  badgeCell.innerHTML = '';
                  badgeCell.appendChild(renderStatusBadge('', true));

                  try {
                    const cRes = (await callBaseMethod(
                      Tachyon.AvailableMethods.SERVICE_HEALTH_CHECK,
                      ['check-domain', JSON.stringify(target)],
                    )) as {
                      success?: boolean;
                      data?: string | ServiceCheckResult[];
                    };

                    if (cRes && cRes.success) {
                      const cResults: ServiceCheckResult[] =
                        typeof cRes.data === 'string'
                          ? JSON.parse(cRes.data)
                          : cRes.data || [];

                      if (cResults && cResults.length > 0) {
                        const cItem: ServiceCheckResult = cResults[0];
                        itemObj.result = cItem;

                        const cBadge = renderStatusBadge(cItem.status_class);

                        (tr.childNodes[2] as HTMLElement).innerHTML = '';
                        (tr.childNodes[2] as HTMLElement).appendChild(
                          document.createTextNode(cItem.ip || '?'),
                        );
                        (tr.childNodes[2] as HTMLElement).appendChild(E('br'));
                        (tr.childNodes[2] as HTMLElement).appendChild(
                          E(
                            'small',
                            { style: 'opacity: 0.6;' },
                            `${cItem.dns_ms}ms`,
                          ),
                        );

                        (tr.childNodes[3] as HTMLElement).textContent =
                          cItem.tcp_ms > 0 ? `${cItem.tcp_ms}` : '-';
                        (tr.childNodes[4] as HTMLElement).textContent =
                          cItem.tls_ms > 0 ? `${cItem.tls_ms}` : '-';
                        (tr.childNodes[5] as HTMLElement).textContent =
                          cItem.http_ms > 0 ? `${cItem.http_ms}` : '-';

                        badgeCell.innerHTML = '';
                        badgeCell.appendChild(cBadge);
                      }
                    }
                  } catch (_e) {
                    badgeCell.innerHTML = '';
                    badgeCell.appendChild(renderStatusBadge('Failed'));
                  }

                  completedCount++;
                  progressBarInner.style.width = `${Math.round((completedCount / targetRows.length) * 100)}%`;
                  updateSummaryStats();
                }
              };

              await Promise.all(
                Array.from({ length: concurrency }, () => runWorker()),
              );

              checkAllBtn.textContent = _('Check again');
              checkAllBtn.disabled = false;
            },
          });

          const closeBtn = renderButton({
            text: _('Close'),
            onClick: () => {
              isModalClosed = true;
              activeCheckRunId++;
              ui.hideModal();
            },
          });

          const rightWrap = E('div', { style: 'display: flex; gap: 8px;' }, [
            checkAllBtn,
            closeBtn,
          ]);

          footer.appendChild(leftWrap);
          footer.appendChild(rightWrap);

          setTimeout(() => {
            if (!isModalClosed) {
              checkAllBtn.click();
            }
          }, 30);
        }
      })
      .catch(() => {
        container.innerHTML = '';
        container.appendChild(
          E(
            'p',
            { style: 'color: var(--color-danger, #dc3545);' },
            _('Failed to start service check.'),
          ),
        );
      });
  };

  loadTargets('active');
}
