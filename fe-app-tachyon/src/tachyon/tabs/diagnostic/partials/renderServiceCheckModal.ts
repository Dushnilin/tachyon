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

function formatRouteType(routeType: string): string {
  if (!routeType) return _('Direct');
  const clean = routeType.trim();
  if (clean === 'connection' || clean === 'proxy' || clean === 'outbound') return _('Proxy');
  if (clean === 'direct') return _('Direct');
  if (clean === 'auto') return _('Auto');
  if (clean.startsWith('zapret2')) return clean.replace(/^zapret2/, 'Zapret 2');
  if (clean.startsWith('zapret')) return clean.replace(/^zapret/, 'Zapret');
  if (clean.startsWith('byedpi')) return clean.replace(/^byedpi/, 'ByeDPI');
  return clean;
}

function formatSectionName(name: string): string {
  if (!name) return '';
  const sectionMap: Record<string, string> = {
    Custom: _('Custom'),
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
  return sectionMap[name.trim()] || name.trim();
}

function renderStatusBadge(
  statusClass: string,
  isTesting = false,
  isPending = false,
): HTMLElement {
  if (isPending) {
    return E('span', { class: 'badge cbi-button-neutral', style: 'opacity: 0.6; font-size: 11px; padding: 2px 8px;' }, _('Pending...'));
  }
  if (isTesting) {
    return E('span', { class: 'badge cbi-button-action', style: 'font-size: 11px; padding: 2px 8px;' }, _('Testing...'));
  }

  const isOk = (statusClass || '').toUpperCase().includes('OK') || statusClass === '200' || statusClass === 'OK';
  if (isOk) {
    return E('span', { class: 'badge cbi-button-save', style: 'font-weight: bold; font-size: 11px; padding: 2px 8px;' }, _('Available'));
  }
  return E('span', { class: 'badge cbi-button-reset', style: 'font-weight: bold; font-size: 11px; padding: 2px 8px;' }, statusClass || _('Unavailable'));
}

export function renderServiceCheckModal() {
  const container = E('div', { class: 'tachyon-service-check-modal-wrapper' }, [
    E('p', { style: 'text-align: center; margin-top: 20px;' }, _('Loading service list...')),
    E('div', { class: 'spinning', style: 'text-align: center; font-size: 24px;' }, ''),
  ]);

  const modalContent = E('div', { style: 'width: 100%;' }, [
    container,
    E('div', { id: 'tachyon-service-check-footer', class: 'tachyon_service_check__footer' }, [
      renderButton({ text: _('Close'), onClick: () => ui.hideModal() }),
    ]),
  ]);

  ui.showModal(_('Service Availability Check'), modalContent);

  const loadTargets = (targetMode: 'active' | 'all') => {
    container.innerHTML = '';
    container.appendChild(E('p', { style: 'text-align: center; margin-top: 20px;' }, _('Loading service list...')));

    const args = targetMode === 'all' ? ['get-targets', 'all'] : ['get-targets'];

    callBaseMethod(Tachyon.AvailableMethods.SERVICE_HEALTH_CHECK, args)
      .then((res: unknown) => {
        const response = res as { success?: boolean; data?: string | ServiceCheckTarget[] };
        container.innerHTML = '';
        if (!response || !response.success) {
          container.appendChild(E('p', { style: 'color: var(--error-color, #dc3545);' }, _('Failed to launch service check.')));
          return;
        }

        let targets: ServiceCheckTarget[] = [];
        try {
          if (typeof response.data === 'string') targets = JSON.parse(response.data);
          else if (Array.isArray(response.data)) targets = response.data;
        } catch (_e) {
          container.appendChild(E('p', { style: 'color: var(--error-color, #dc3545);' }, _('Failed to parse target list.')));
          return;
        }

        if (targets.length === 0) {
          container.appendChild(E('p', {}, _('No targets found in configuration.')));
          return;
        }

        // Mode switcher
        const activeBtn = renderButton({
          text: _('Active routes'),
          classNames: [targetMode === 'active' ? 'cbi-button cbi-button-action' : 'cbi-button cbi-button-neutral'],
          onClick: () => loadTargets('active'),
        });
        const allBtn = renderButton({
          text: _('All services'),
          classNames: [targetMode === 'all' ? 'cbi-button cbi-button-action' : 'cbi-button cbi-button-neutral'],
          onClick: () => loadTargets('all'),
        });
        const modeBar = E('div', { class: 'tachyon_service_check__mode-bar' }, [
          E('span', { style: 'font-weight: 600; font-size: 13px;' }, _('Check mode:')),
          activeBtn,
          allBtn,
        ]);

        // Stats
        const sectionNames = Array.from(new Set(targets.map((t) => t.section)));
        let activeFilter = 'ALL';
        let searchQuery = '';

        const totalStatEl = E('b', {}, `${targets.length}`);
        const passedStatEl = E('b', { style: 'color: var(--success-color, #28a745);' }, '0');
        const failedStatEl = E('b', { style: 'color: var(--error-color, #dc3545);' }, '0');
        const latencyStatEl = E('b', { style: 'color: var(--primary-color, #007bff);' }, '-');

        const statsBar = E('div', { class: 'tachyon_service_check__stats' }, [
          E('div', { class: 'tachyon_service_check__stat' }, [E('small', {}, _('Total')), totalStatEl]),
          E('div', { class: 'tachyon_service_check__stat' }, [E('small', {}, _('Available')), passedStatEl]),
          E('div', { class: 'tachyon_service_check__stat' }, [E('small', {}, _('Unavailable')), failedStatEl]),
          E('div', { class: 'tachyon_service_check__stat' }, [E('small', {}, _('Avg latency')), latencyStatEl]),
        ]);

        // Progress bar
        const progressBarInner = E('div', { style: 'width: 0%; height: 100%; background: var(--success-color, #28a745); transition: width 0.2s ease;' });
        const progressBarContainer = E('div', {
          style: 'width: 100%; height: 6px; background: var(--border-color-light, #eee); border-radius: 3px; overflow: hidden; margin-bottom: 12px; display: none;',
        }, [progressBarInner]);

        // Filter & search
        const sectionSelect = E('select', {
          class: 'cbi-input-select',
          style: 'max-width: 240px;',
        }, [
          E('option', { value: 'ALL' }, `${_('All services')} (${targets.length})`),
          ...sectionNames.map((sec) => {
            const count = targets.filter((t) => t.section === sec).length;
            return E('option', { value: sec }, `${formatSectionName(sec)} (${count})`);
          }),
        ]) as HTMLSelectElement;
        sectionSelect.onchange = () => { activeFilter = sectionSelect.value; applyTableFilter(); };

        const searchInput = E('input', {
          type: 'text',
          placeholder: _('Search domain or service...'),
          class: 'cbi-input-text',
          style: 'width: 200px;',
        });
        searchInput.oninput = (e: Event) => {
          searchQuery = ((e.target as HTMLInputElement)?.value || '').toLowerCase().trim();
          applyTableFilter();
        };

        const toolbar = E('div', { style: 'display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px; gap: 8px; flex-wrap: wrap;' }, [
          E('div', { style: 'display: flex; gap: 6px; align-items: center;' }, [
            E('span', { style: 'font-size: 12px;' }, _('Filter:')),
            sectionSelect,
          ]),
          searchInput,
        ]);

        // Table
        const tableHead = E('tr', { class: 'tr cbi-section-table-titles' }, [
          E('th', { class: 'th', style: 'width: 28%;' }, _('Service / Target')),
          E('th', { class: 'th', style: 'width: 17%;' }, _('Route')),
          E('th', { class: 'th', style: 'width: 20%;' }, _('IP / DNS')),
          E('th', { class: 'th', style: 'text-align: right; width: 7%;' }, 'TCP'),
          E('th', { class: 'th', style: 'text-align: right; width: 7%;' }, 'TLS'),
          E('th', { class: 'th', style: 'text-align: right; width: 7%;' }, 'HTTP'),
          E('th', { class: 'th', style: 'text-align: center; width: 14%;' }, _('Status')),
        ]);

        const tableBody = E('tbody', {});
        const table = E('table', { class: 'table cbi-section-table' }, [
          E('thead', {}, [tableHead]),
          tableBody,
        ]);
        const tableScrollWrapper = E('div', { class: 'tachyon_service_check__table-scroll' }, [table]);

        const rowMap: { target: ServiceCheckTarget; tr: HTMLElement; result?: ServiceCheckResult }[] = [];

        targets.forEach((item, index) => {
          const rowClass = index % 2 === 0 ? 'cbi-rowstyle-1' : 'cbi-rowstyle-2';
          const tr = E('tr', { class: `tr ${rowClass}` }, [
            E('td', { class: 'td' }, [
              E('span', { style: 'font-weight: 600; font-size: 12px;' }, formatSectionName(item.section)),
              E('br'),
              E('small', { style: 'opacity: 0.8;' }, item.domain),
            ]),
            E('td', { class: 'td', style: 'font-size: 12px;' }, [
              E('span', { class: 'badge cbi-value-title', style: 'font-size: 11px; padding: 2px 6px;' }, formatRouteType(item.route_type)),
            ]),
            E('td', { class: 'td', style: 'font-size: 12px;' }, [
              E('span', {}, '?'),
              E('br'),
              E('small', { style: 'opacity: 0.6;' }, '-'),
            ]),
            E('td', { class: 'td', style: 'text-align: right; font-size: 12px;' }, '-'),
            E('td', { class: 'td', style: 'text-align: right; font-size: 12px;' }, '-'),
            E('td', { class: 'td', style: 'text-align: right; font-size: 12px;' }, '-'),
            E('td', { class: 'td', style: 'text-align: center;' }, renderStatusBadge('', false, true)),
          ]);
          rowMap.push({ target: item, tr });
          tableBody.appendChild(tr);
        });

        const applyTableFilter = () => {
          rowMap.forEach(({ target, tr }) => {
            const matchSection = activeFilter === 'ALL' || target.section === activeFilter;
            const matchSearch = !searchQuery ||
              target.domain.toLowerCase().includes(searchQuery) ||
              target.section.toLowerCase().includes(searchQuery) ||
              formatSectionName(target.section).toLowerCase().includes(searchQuery);
            tr.style.display = matchSection && matchSearch ? '' : 'none';
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
              if (lat > 0) { totalLat += lat; countLat++; }
            }
          });
          passedStatEl.textContent = `${passed}`;
          failedStatEl.textContent = `${failed}`;
          latencyStatEl.textContent = countLat > 0 ? `${Math.round(totalLat / countLat)} ms` : '-';
        };

        container.appendChild(modeBar);
        container.appendChild(statsBar);
        container.appendChild(progressBarContainer);
        container.appendChild(toolbar);
        container.appendChild(tableScrollWrapper);

        // Footer
        const footer = document.getElementById('tachyon-service-check-footer');
        if (footer) {
          footer.innerHTML = '';

          const customDomainInput = E('input', {
            type: 'text',
            placeholder: _('Check domain or IP (e.g. example.com)...'),
            class: 'cbi-input-text',
            style: 'width: 250px;',
          });

          const customBtn = renderButton({
            text: _('Check domain'),
            classNames: ['cbi-button cbi-button-neutral'],
            onClick: async () => {
              const domain = customDomainInput.value.trim();
              if (!domain) return;
              customBtn.disabled = true;
              try {
                const cRes = (await callBaseMethod(Tachyon.AvailableMethods.SERVICE_HEALTH_CHECK, ['check-custom', domain])) as { success?: boolean; data?: string | ServiceCheckResult[] };
                if (cRes && cRes.success) {
                  const cResults: ServiceCheckResult[] = typeof cRes.data === 'string' ? JSON.parse(cRes.data) : cRes.data || [];
                  if (cResults && cResults.length > 0) {
                    const cItem = cResults[0];
                    const customTr = E('tr', { class: 'tr cbi-rowstyle-1' }, [
                      E('td', { class: 'td' }, [E('span', { style: 'font-weight: 600;' }, formatSectionName(cItem.section)), E('br'), E('small', {}, cItem.domain)]),
                      E('td', { class: 'td', style: 'font-size: 12px;' }, [E('span', { class: 'badge cbi-value-title', style: 'font-size: 11px; padding: 2px 6px;' }, formatRouteType(cItem.route_type))]),
                      E('td', { class: 'td', style: 'font-size: 12px;' }, [cItem.ip || '?', E('br'), E('small', {}, `${cItem.dns_ms}ms`)]),
                      E('td', { class: 'td', style: 'text-align: right;' }, cItem.tcp_ms > 0 ? `${cItem.tcp_ms}` : '-'),
                      E('td', { class: 'td', style: 'text-align: right;' }, cItem.tls_ms > 0 ? `${cItem.tls_ms}` : '-'),
                      E('td', { class: 'td', style: 'text-align: right;' }, cItem.http_ms > 0 ? `${cItem.http_ms}` : '-'),
                      E('td', { class: 'td', style: 'text-align: center;' }, renderStatusBadge(cItem.status_class)),
                    ]);
                    tableBody.insertBefore(customTr, tableBody.firstChild);
                    rowMap.unshift({ target: { section: 'Custom', route_type: 'auto', domain: cItem.domain }, tr: customTr, result: cItem });
                    updateSummaryStats();
                    customDomainInput.value = '';
                  }
                }
              } catch (_e) {}
              finally { customBtn.disabled = false; }
            },
          });

          const checkAllBtn = renderButton({
            text: _('Check all'),
            classNames: ['cbi-button cbi-button-action'],
            onClick: async () => {
              checkAllBtn.disabled = true;
              progressBarContainer.style.display = 'block';
              progressBarInner.style.width = '0%';

              for (let i = 0; i < rowMap.length; i++) {
                const itemObj = rowMap[i];
                progressBarInner.style.width = `${Math.round(((i + 1) / rowMap.length) * 100)}%`;
                const badgeCell = itemObj.tr.childNodes[6] as HTMLElement;
                badgeCell.innerHTML = '';
                badgeCell.appendChild(renderStatusBadge('', true));

                try {
                  const cRes = (await callBaseMethod(Tachyon.AvailableMethods.SERVICE_HEALTH_CHECK, ['check-domain', JSON.stringify(itemObj.target)])) as { success?: boolean; data?: string | ServiceCheckResult[] };
                  if (cRes && cRes.success) {
                    const cResults: ServiceCheckResult[] = typeof cRes.data === 'string' ? JSON.parse(cRes.data) : cRes.data || [];
                    if (cResults && cResults.length > 0) {
                      const cItem = cResults[0];
                      itemObj.result = cItem;
                      (itemObj.tr.childNodes[2] as HTMLElement).innerHTML = '';
                      (itemObj.tr.childNodes[2] as HTMLElement).appendChild(document.createTextNode(cItem.ip || '?'));
                      (itemObj.tr.childNodes[2] as HTMLElement).appendChild(E('br'));
                      (itemObj.tr.childNodes[2] as HTMLElement).appendChild(E('small', { style: 'opacity: 0.6;' }, `${cItem.dns_ms}ms`));
                      (itemObj.tr.childNodes[3] as HTMLElement).textContent = cItem.tcp_ms > 0 ? `${cItem.tcp_ms}` : '-';
                      (itemObj.tr.childNodes[4] as HTMLElement).textContent = cItem.tls_ms > 0 ? `${cItem.tls_ms}` : '-';
                      (itemObj.tr.childNodes[5] as HTMLElement).textContent = cItem.http_ms > 0 ? `${cItem.http_ms}` : '-';
                      badgeCell.innerHTML = '';
                      badgeCell.appendChild(renderStatusBadge(cItem.status_class));
                    }
                  }
                } catch (_e) {
                  badgeCell.innerHTML = '';
                  badgeCell.appendChild(renderStatusBadge('Failed'));
                }
                updateSummaryStats();
              }

              checkAllBtn.textContent = _('Check again');
              checkAllBtn.disabled = false;
            },
          });

          const closeBtn = renderButton({ text: _('Close'), onClick: () => ui.hideModal() });

          footer.appendChild(E('div', { style: 'display: flex; gap: 6px; align-items: center; flex-wrap: wrap;' }, [customDomainInput, customBtn]));
          footer.appendChild(E('div', { style: 'display: flex; gap: 6px;' }, [checkAllBtn, closeBtn]));
        }
      })
      .catch(() => {
        container.innerHTML = '';
        container.appendChild(E('p', { style: 'color: var(--error-color, #dc3545);' }, _('Failed to launch service check.')));
      });
  };

  loadTargets('active');
}
