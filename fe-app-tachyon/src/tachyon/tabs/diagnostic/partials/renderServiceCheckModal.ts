import { callBaseMethod } from '../../../methods/shell/callBaseMethod';
import { renderButton } from '../../../../partials';
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
 * Format raw backend route strings into clean, user-friendly labels.
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
  if (clean.startsWith('zapret2')) {
    return clean.replace(/^zapret2/, 'Zapret 2');
  }
  if (clean.startsWith('zapret')) {
    return clean.replace(/^zapret/, 'Zapret');
  }
  if (clean.startsWith('byedpi')) {
    return clean.replace(/^byedpi/, 'ByeDPI');
  }

  return clean;
}

/**
 * Format raw section names for UI display.
 */
function formatSectionName(name: string): string {
  if (name === 'Свои домены') {
    return _('Custom Domains');
  }
  return name;
}

/**
 * Render a native LuCI status badge matching active theme colors.
 */
function renderStatusBadge(
  statusClass: string,
  isTesting = false,
  isPending = false,
): HTMLElement {
  if (isPending) {
    return E(
      'span',
      {
        class: 'badge cbi-value-title',
        style: 'opacity: 0.6; font-size: 11px; padding: 2px 8px;',
      },
      _('Pending'),
    );
  }
  if (isTesting) {
    return E(
      'span',
      {
        class: 'badge cbi-button-action',
        style: 'font-size: 11px; padding: 2px 8px;',
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
        class: 'badge cbi-button-save',
        style: 'font-weight: bold; font-size: 11px; padding: 2px 8px;',
      },
      _('Available'),
    );
  }

  return E(
    'span',
    {
      class: 'badge cbi-button-reset',
      style: 'font-weight: bold; font-size: 11px; padding: 2px 8px;',
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
        _('Fetching service targets...'),
      ),
      E(
        'div',
        {
          class: 'spinning',
          style:
            'text-align: center; font-size: 24px; color: var(--border-color, #007bff);',
        },
        '⚡',
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

  ui.showModal(_('Service Availability Check'), modalContent);

  const loadTargets = (targetMode: 'active' | 'all') => {
    container.innerHTML = '';
    container.appendChild(
      E(
        'p',
        { style: 'text-align: center; margin-top: 20px;' },
        _('Fetching service targets...'),
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
              _('Failed to run service check.'),
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
            E('p', {}, _('No targets found in section configs.')),
          );
          return;
        }

        // Mode Switcher Toolbar
        const activeSectionsBtn = renderButton({
          text: _('Active Routes'),
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
          text: _('All Services'),
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
              _('Check Mode:'),
            ),
            activeSectionsBtn,
            allProfilesBtn,
          ],
        );

        // Extract unique sections for filter tabs
        const sectionNames = Array.from(new Set(targets.map((t) => t.section)));
        let activeFilter = 'ALL';
        let searchQuery = '';

        // Summary Stats Elements
        const totalStatEl = E(
          'b',
          {
            style: 'font-size: 18px; display: block; margin-top: 2px;',
          },
          `${targets.length}`,
        );
        const passedStatEl = E(
          'b',
          {
            style:
              'font-size: 18px; color: var(--color-success, #28a745); display: block; margin-top: 2px;',
          },
          '0',
        );
        const failedStatEl = E(
          'b',
          {
            style:
              'font-size: 18px; color: var(--color-danger, #dc3545); display: block; margin-top: 2px;',
          },
          '0',
        );
        const latencyStatEl = E(
          'b',
          {
            style:
              'font-size: 18px; color: var(--color-info, #17a2b8); display: block; margin-top: 2px;',
          },
          '-',
        );

        const createStatCard = (title: string, valueEl: HTMLElement) => {
          return E(
            'div',
            {
              class: 'cbi-value',
              style:
                'flex: 1 1 110px; min-width: 100px; padding: 8px 10px; border: 1px solid var(--border-color, rgba(128,128,128,0.25)); border-radius: 6px; text-align: center; background: var(--background-color-secondary, rgba(128,128,128,0.05)); margin: 0; box-sizing: border-box;',
            },
            [
              E(
                'small',
                { style: 'display: block; opacity: 0.75; font-size: 11px;' },
                title,
              ),
              valueEl,
            ],
          );
        };

        const statsBar = E(
          'div',
          {
            style:
              'display: flex; gap: 10px; flex-wrap: wrap; margin-bottom: 14px; width: 100%; box-sizing: border-box;',
          },
          [
            createStatCard(_('Total Targets'), totalStatEl),
            createStatCard(_('Available'), passedStatEl),
            createStatCard(_('Unavailable'), failedStatEl),
            createStatCard(_('Avg Latency'), latencyStatEl),
          ],
        );

        // Progress Bar Container
        const progressBarInner = E('div', {
          style:
            'width: 0%; height: 100%; background: var(--color-success, #28a745); transition: width 0.2s ease;',
        });
        const progressBarContainer = E(
          'div',
          {
            style:
              'width: 100%; height: 6px; background: var(--border-color, rgba(128,128,128,0.2)); border-radius: 3px; overflow: hidden; margin-bottom: 14px; display: none;',
          },
          [progressBarInner],
        );

        // Filter Tabs Toolbar
        const createFilterTab = (label: string, sectionKey: string) => {
          const isActive = activeFilter === sectionKey;
          const targetCount =
            sectionKey === 'ALL'
              ? targets.length
              : targets.filter((t) => t.section === sectionKey).length;

          const badge = E(
            'span',
            {
              class: 'badge',
              style:
                'margin-left: 6px; padding: 1px 6px; font-size: 10px; opacity: 0.85; border-radius: 10px; background: var(--border-color, rgba(128,128,128,0.3)); font-weight: bold;',
            },
            `${targetCount}`,
          );

          const btn = E(
            'button',
            {
              type: 'button',
              class: `cbi-button ${isActive ? 'cbi-button-action' : 'cbi-button-neutral'}`,
              style:
                'padding: 3px 10px; font-size: 12px; border-radius: 14px; display: inline-flex; align-items: center;',
            },
            [E('span', {}, label), badge],
          );
          btn.onclick = () => {
            activeFilter = sectionKey;
            updateFilterTabs();
            applyTableFilter();
          };
          return btn;
        };

        const filterTabsContainer = E('div', {
          style:
            'display: flex; gap: 6px; flex-wrap: wrap; align-items: center;',
        });

        const updateFilterTabs = () => {
          filterTabsContainer.innerHTML = '';
          filterTabsContainer.appendChild(createFilterTab(_('All'), 'ALL'));
          sectionNames.forEach((sec) => {
            filterTabsContainer.appendChild(
              createFilterTab(formatSectionName(sec), sec),
            );
          });
        };
        updateFilterTabs();

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
          [filterTabsContainer, searchInput],
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
            _('Route Type'),
          ),
          E(
            'th',
            { class: 'th', style: 'width: 20%; padding: 8px;' },
            _('Resolved IP / DNS'),
          ),
          E(
            'th',
            {
              class: 'th',
              style: 'text-align: right; width: 7%; padding: 8px 4px;',
            },
            _('TCP'),
          ),
          E(
            'th',
            {
              class: 'th',
              style: 'text-align: right; width: 7%; padding: 8px 4px;',
            },
            _('TLS'),
          ),
          E(
            'th',
            {
              class: 'th',
              style: 'text-align: right; width: 7%; padding: 8px 4px;',
            },
            _('HTTP'),
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
                  'position: sticky; top: 0; background: var(--background-color-primary, #ffffff); z-index: 2;',
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
              'max-height: 380px; overflow-y: auto; overflow-x: hidden; border: 1px solid var(--border-color, rgba(128,128,128,0.25)); border-radius: 6px; width: 100%; box-sizing: border-box;',
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
            placeholder: _('Check domain or IP (e.g. example.com)...'),
            class: 'cbi-input-text',
            style: 'width: 260px; font-size: 12px;',
          });

          const customBtn = renderButton({
            text: _('Check Domain'),
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
                customBtn.textContent = _('Check Domain');
              }
            },
          });

          const leftWrap = E(
            'div',
            {
              style:
                'display: flex; gap: 8px; align-items: center; flex-wrap: wrap;',
            },
            [customDomainInput, customBtn],
          );

          const checkAllBtn = renderButton({
            text: _('Check All'),
            classNames: ['cbi-button-action'],
            onClick: async () => {
              checkAllBtn.disabled = true;
              checkAllBtn.textContent = _('Checking...');

              progressBarContainer.style.display = 'block';
              progressBarInner.style.width = '0%';

              for (let i = 0; i < rowMap.length; i++) {
                const itemObj = rowMap[i];
                const { target, tr } = itemObj;

                progressBarInner.style.width = `${Math.round(((i + 1) / rowMap.length) * 100)}%`;

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

                updateSummaryStats();
              }

              checkAllBtn.textContent = _('Check Again');
              checkAllBtn.disabled = false;
            },
          });

          const closeBtn = renderButton({
            text: _('Close'),
            onClick: () => ui.hideModal(),
          });

          const rightWrap = E('div', { style: 'display: flex; gap: 8px;' }, [
            checkAllBtn,
            closeBtn,
          ]);

          footer.appendChild(leftWrap);
          footer.appendChild(rightWrap);
        }
      })
      .catch(() => {
        container.innerHTML = '';
        container.appendChild(
          E(
            'p',
            { style: 'color: var(--color-danger, #dc3545);' },
            _('Failed to run service check.'),
          ),
        );
      });
  };

  loadTargets('active');
}
