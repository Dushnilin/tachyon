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

export function renderServiceCheckModal() {
  let currentTargetMode: 'active' | 'all' = 'active';

  const container = E(
    'div',
    {
      class: 'tachyon-service-check-modal-wrapper',
      style: 'width: 100%; max-width: 820px; box-sizing: border-box;',
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
    { style: 'width: 100%; max-width: 820px; box-sizing: border-box;' },
    [
      container,
      E(
        'div',
        {
          id: 'tachyon-service-check-footer',
          style:
            'margin-top: 15px; display: flex; justify-content: space-between; align-items: center; gap: 10px; border-top: 1px solid var(--border-color, rgba(255,255,255,0.15)); padding-top: 12px; flex-wrap: wrap;',
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

  ui.showModal(_('Service Health Check'), modalContent);

  const loadTargets = (targetMode: 'active' | 'all') => {
    currentTargetMode = targetMode;
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
              { style: 'color: #dc3545;' },
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
              { style: 'color: #dc3545;' },
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
          text: _('Active Sections'),
          classNames: [
            targetMode === 'active'
              ? 'cbi-button-action'
              : 'cbi-button-neutral',
          ],
          onClick: () => loadTargets('active'),
        });
        activeSectionsBtn.style.fontSize = '12px';
        activeSectionsBtn.style.padding = '3px 12px';

        const allProfilesBtn = renderButton({
          text: _('All Profiles'),
          classNames: [
            targetMode === 'all' ? 'cbi-button-action' : 'cbi-button-neutral',
          ],
          onClick: () => loadTargets('all'),
        });
        allProfilesBtn.style.fontSize = '12px';
        allProfilesBtn.style.padding = '3px 12px';

        const modeSwitcherBar = E(
          'div',
          {
            style:
              'display: flex; gap: 8px; align-items: center; margin-bottom: 12px; border-bottom: 1px solid var(--border-color, rgba(255,255,255,0.1)); padding-bottom: 8px;',
          },
          [
            E(
              'span',
              { style: 'font-weight: 600; font-size: 12px; opacity: 0.8;' },
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
          'div',
          {
            class: 'stat-val',
            style: 'font-size: 18px; font-weight: bold; margin-top: 2px;',
          },
          `${targets.length}`,
        );
        const passedStatEl = E(
          'div',
          {
            class: 'stat-val',
            style:
              'font-size: 18px; font-weight: bold; color: #28a745; margin-top: 2px;',
          },
          '0',
        );
        const failedStatEl = E(
          'div',
          {
            class: 'stat-val',
            style:
              'font-size: 18px; font-weight: bold; color: #dc3545; margin-top: 2px;',
          },
          '0',
        );
        const latencyStatEl = E(
          'div',
          {
            class: 'stat-val',
            style:
              'font-size: 18px; font-weight: bold; color: #17a2b8; margin-top: 2px;',
          },
          '-',
        );

        const statsBar = E(
          'div',
          {
            style:
              'display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 12px; width: 100%; box-sizing: border-box;',
          },
          [
            E(
              'div',
              {
                style:
                  'flex: 1 1 120px; min-width: 110px; background: var(--background-color-secondary, rgba(255,255,255,0.05)); border: 1px solid var(--border-color, rgba(255,255,255,0.15)); border-radius: 6px; padding: 6px 10px; text-align: center; box-sizing: border-box;',
              },
              [
                E(
                  'small',
                  { style: 'display: block; font-size: 11px; opacity: 0.75;' },
                  _('Total Targets'),
                ),
                totalStatEl,
              ],
            ),
            E(
              'div',
              {
                style:
                  'flex: 1 1 120px; min-width: 110px; background: var(--background-color-secondary, rgba(255,255,255,0.05)); border: 1px solid var(--border-color, rgba(255,255,255,0.15)); border-radius: 6px; padding: 6px 10px; text-align: center; box-sizing: border-box;',
              },
              [
                E(
                  'small',
                  { style: 'display: block; font-size: 11px; opacity: 0.75;' },
                  _('Passed'),
                ),
                passedStatEl,
              ],
            ),
            E(
              'div',
              {
                style:
                  'flex: 1 1 120px; min-width: 110px; background: var(--background-color-secondary, rgba(255,255,255,0.05)); border: 1px solid var(--border-color, rgba(255,255,255,0.15)); border-radius: 6px; padding: 6px 10px; text-align: center; box-sizing: border-box;',
              },
              [
                E(
                  'small',
                  { style: 'display: block; font-size: 11px; opacity: 0.75;' },
                  _('Failed'),
                ),
                failedStatEl,
              ],
            ),
            E(
              'div',
              {
                style:
                  'flex: 1 1 120px; min-width: 110px; background: var(--background-color-secondary, rgba(255,255,255,0.05)); border: 1px solid var(--border-color, rgba(255,255,255,0.15)); border-radius: 6px; padding: 6px 10px; text-align: center; box-sizing: border-box;',
              },
              [
                E(
                  'small',
                  { style: 'display: block; font-size: 11px; opacity: 0.75;' },
                  _('Avg Latency'),
                ),
                latencyStatEl,
              ],
            ),
          ],
        );

        // Progress Bar Container
        const progressBarInner = E('div', {
          style:
            'width: 0%; height: 100%; background: #28a745; transition: width 0.2s ease;',
        });
        const progressBarContainer = E(
          'div',
          {
            style:
              'width: 100%; height: 6px; background: rgba(255,255,255,0.1); border-radius: 3px; overflow: hidden; margin-bottom: 12px; display: none;',
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
              style:
                'margin-left: 5px; padding: 1px 6px; border-radius: 10px; font-size: 10px; opacity: 0.85; background: rgba(255,255,255,0.18); font-weight: bold;',
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
            filterTabsContainer.appendChild(createFilterTab(sec, sec));
          });
        };
        updateFilterTabs();

        // Search Box
        const searchInput = E('input', {
          type: 'text',
          placeholder: _('Search domain...'),
          class: 'cbi-input-text',
          style:
            'width: 180px; padding: 4px 8px; font-size: 12px; border-radius: 4px;',
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
            { class: 'th', style: 'width: 28%; padding: 6px 8px;' },
            _('Section / Target'),
          ),
          E(
            'th',
            { class: 'th', style: 'width: 17%; padding: 6px 8px;' },
            _('Outbound Route'),
          ),
          E(
            'th',
            { class: 'th', style: 'width: 20%; padding: 6px 8px;' },
            _('Resolved IP / DNS'),
          ),
          E(
            'th',
            {
              class: 'th',
              style: 'text-align: right; width: 7%; padding: 6px 4px;',
            },
            _('TCP'),
          ),
          E(
            'th',
            {
              class: 'th',
              style: 'text-align: right; width: 7%; padding: 6px 4px;',
            },
            _('TLS'),
          ),
          E(
            'th',
            {
              class: 'th',
              style: 'text-align: right; width: 7%; padding: 6px 4px;',
            },
            _('HTTP'),
          ),
          E(
            'th',
            {
              class: 'th',
              style: 'text-align: center; width: 14%; padding: 6px 6px;',
            },
            _('Verdict'),
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
                  'position: sticky; top: 0; background: var(--background-color-primary, #1e1e1e); z-index: 2;',
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
              'max-height: 380px; overflow-y: auto; overflow-x: hidden; border: 1px solid var(--border-color, rgba(255,255,255,0.15)); border-radius: 6px; width: 100%; box-sizing: border-box;',
          },
          [table],
        );

        const rowMap: {
          target: ServiceCheckTarget;
          tr: HTMLElement;
          result?: ServiceCheckResult;
        }[] = [];

        targets.forEach((item) => {
          const badge = E(
            'span',
            {
              style:
                'display: inline-block; padding: 2px 6px; border-radius: 8px; color: #fff; font-size: 10px; font-weight: 500; background: #6c757d; text-align: center; white-space: nowrap; max-width: 100%; overflow: hidden; text-overflow: ellipsis;',
            },
            _('Pending'),
          );

          const tr = E('tr', { class: 'tr cbi-rowstyle-1' }, [
            E('td', { class: 'td', style: 'word-break: break-all;' }, [
              E(
                'span',
                { style: 'font-weight: 600; font-size: 12px;' },
                item.section,
              ),
              E('br'),
              E('small', { style: 'opacity: 0.8;' }, item.domain),
            ]),
            E('td', { class: 'td', style: 'font-size: 11px;' }, [
              E(
                'code',
                {
                  style:
                    'background: rgba(255,255,255,0.06); padding: 2px 4px; border-radius: 3px;',
                },
                item.route_type,
              ),
            ]),
            E('td', { class: 'td', style: 'font-size: 11px;' }, [
              E('span', {}, '?'),
              E('br'),
              E('small', { style: 'opacity: 0.6;' }, `-`),
            ]),
            E(
              'td',
              { class: 'td', style: 'text-align: right; font-size: 12px;' },
              '-',
            ),
            E(
              'td',
              { class: 'td', style: 'text-align: right; font-size: 12px;' },
              '-',
            ),
            E(
              'td',
              { class: 'td', style: 'text-align: right; font-size: 12px;' },
              '-',
            ),
            E('td', { class: 'td', style: 'text-align: center;' }, badge),
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
              target.section.toLowerCase().includes(searchQuery);
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
            text: _('Check Custom'),
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
                    const cBadgeColor = cItem.success ? '#28a745' : '#dc3545';
                    const cBadge = E(
                      'span',
                      {
                        style: `display: inline-block; padding: 2px 6px; border-radius: 8px; color: #fff; font-size: 10px; font-weight: 500; background: ${cBadgeColor}; text-align: center; white-space: nowrap; max-width: 100%; overflow: hidden; text-overflow: ellipsis;`,
                      },
                      cItem.status_class,
                    );

                    const customTr = E('tr', { class: 'tr cbi-rowstyle-2' }, [
                      E(
                        'td',
                        { class: 'td', style: 'word-break: break-all;' },
                        [
                          E(
                            'span',
                            { style: 'font-weight:600;' },
                            cItem.section,
                          ),
                          E('br'),
                          E('small', {}, cItem.domain),
                        ],
                      ),
                      E('td', { class: 'td', style: 'font-size: 11px;' }, [
                        E('code', {}, cItem.route_type),
                      ]),
                      E('td', { class: 'td', style: 'font-size: 11px;' }, [
                        cItem.ip || '?',
                        E('br'),
                        E('small', {}, `${cItem.dns_ms}ms`),
                      ]),
                      E(
                        'td',
                        { class: 'td', style: 'text-align: right;' },
                        cItem.tcp_ms > 0 ? `${cItem.tcp_ms}` : '-',
                      ),
                      E(
                        'td',
                        { class: 'td', style: 'text-align: right;' },
                        cItem.tls_ms > 0 ? `${cItem.tls_ms}` : '-',
                      ),
                      E(
                        'td',
                        { class: 'td', style: 'text-align: right;' },
                        cItem.http_ms > 0 ? `${cItem.http_ms}` : '-',
                      ),
                      E(
                        'td',
                        { class: 'td', style: 'text-align: center;' },
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
                customBtn.textContent = _('Check Custom');
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
                badgeCell.appendChild(
                  E(
                    'span',
                    {
                      style:
                        'display: inline-block; padding: 2px 6px; border-radius: 8px; color: #fff; font-size: 10px; font-weight: 500; background: #007bff; text-align: center; white-space: nowrap; max-width: 100%; overflow: hidden; text-overflow: ellipsis;',
                    },
                    _('Testing...'),
                  ),
                );

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

                      const cBadgeColor = cItem.success ? '#28a745' : '#dc3545';
                      const cBadge = E(
                        'span',
                        {
                          style: `display: inline-block; padding: 2px 6px; border-radius: 8px; color: #fff; font-size: 10px; font-weight: 500; background: ${cBadgeColor}; text-align: center; white-space: nowrap; max-width: 100%; overflow: hidden; text-overflow: ellipsis;`,
                        },
                        cItem.status_class,
                      );

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
                  badgeCell.appendChild(
                    E(
                      'span',
                      {
                        style:
                          'display: inline-block; padding: 2px 6px; border-radius: 8px; color: #fff; font-size: 10px; font-weight: 500; background: #dc3545; text-align: center; white-space: nowrap; max-width: 100%; overflow: hidden; text-overflow: ellipsis;',
                      },
                      _('Failed'),
                    ),
                  );
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
            { style: 'color: #dc3545;' },
            _('Failed to run service check.'),
          ),
        );
      });
  };

  loadTargets('active');
}
