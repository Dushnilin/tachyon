import { callBaseMethod } from '../../../methods/shell/callBaseMethod';
import { renderButton } from '../../../../partials';

interface ServiceCheckResult {
  section: string;
  route_type: string;
  domain: string;
  ip: string;
  dns_ms: number;
  tcp_ms: number;
  tls_ms: number;
  http_ms: number;
  status_class: string;
  success: boolean;
}

export function renderServiceCheckModal() {
  const container = E('div', { class: 'tachyon-service-check-modal' }, [
    E('p', {}, _('Fetching service status, please wait...')),
    E('div', { class: 'spinning' }, '...'),
  ]);

  ui.showModal(_('Service Health Check'), E('div', {}, [
      container,
      E('div', { style: 'margin-top: 15px; text-align: right;' }, [
          renderButton({
              text: _('Close'),
              onClick: () => ui.hideModal()
          })
      ])
  ]));

  callBaseMethod('diagnostics/status.uc' as any, [
    'service-health-check',
  ])
    .then((res: any) => {
      container.innerHTML = '';
      if (!res.success) {
        container.appendChild(E('p', {}, _('Failed to execute service check.')));
        return;
      }

      let results: ServiceCheckResult[] = [];
      try {
        if (typeof res.data === 'string') {
          results = JSON.parse(res.data);
        }
      } catch (e) {
        container.appendChild(E('p', {}, _('Failed to parse service check results.')));
        return;
      }

      if (results.length === 0) {
        container.appendChild(E('p', {}, _('No domains found to check.')));
      }

      const table = E('table', { class: 'table cbi-section-table' }, [
        E('tr', { class: 'tr cbi-section-table-titles' }, [
          E('th', { class: 'th' }, _('Section / Domain')),
          E('th', { class: 'th' }, _('Outbound')),
          E('th', { class: 'th' }, _('IP / DNS')),
          E('th', { class: 'th' }, _('TCP (ms)')),
          E('th', { class: 'th' }, _('TLS (ms)')),
          E('th', { class: 'th' }, _('HTTP (ms)')),
          E('th', { class: 'th' }, _('Verdict')),
        ]),
      ]);

      results.forEach((item) => {
        const badgeColor = item.success
          ? '#28a745'
          : item.status_class.includes('Timeout') || item.status_class.includes('HTTP') || item.status_class.includes('Reset')
            ? '#dc3545'
            : '#ffc107';

        const badge = E(
          'span',
          {
            style: `display: inline-block; padding: 2px 6px; border-radius: 4px; color: white; font-weight: bold; font-size: 11px; background: ${badgeColor};`,
          },
          item.status_class,
        );

        table.appendChild(
          E('tr', { class: 'tr cbi-rowstyle-1' }, [
            E('td', { class: 'td' }, [
              E('strong', {}, item.section),
              E('br'),
              E('small', {}, item.domain),
            ]),
            E('td', { class: 'td' }, item.route_type),
            E('td', { class: 'td' }, [
              item.ip || '?',
              E('br'),
              E('small', {}, `${item.dns_ms}ms`),
            ]),
            E('td', { class: 'td' }, item.tcp_ms > 0 ? `${item.tcp_ms}` : '-'),
            E('td', { class: 'td' }, item.tls_ms > 0 ? `${item.tls_ms}` : '-'),
            E('td', { class: 'td' }, item.http_ms > 0 ? `${item.http_ms}` : '-'),
            E('td', { class: 'td' }, badge),
          ]),
        );
      });

      if (results.length > 0) {
        container.appendChild(table);
      }
      
      const customDomainWrap = E('div', { style: 'margin-top: 15px; display: flex; gap: 10px;' }, [
        E('input', { type: 'text', id: 'custom-domain-check-input', placeholder: _('Custom domain (e.g. google.com)') })
    ]);

    let customBtn: HTMLButtonElement;
    customBtn = renderButton({
            text: _('Check Custom Domain'),
            classNames: ['cbi-button-action'],
            onClick: () => {
                const input = document.getElementById('custom-domain-check-input') as HTMLInputElement;
                if (!input || !input.value) return;
                const domain = input.value.trim();
                
                if (customBtn) {
                    customBtn.disabled = true;
                    customBtn.textContent = '...';
                }
                
                callBaseMethod('diagnostics/status.uc' as any, ['service-health-check', 'check-custom', domain]).then((cRes: any) => {
                    if (customBtn) {
                        customBtn.disabled = false;
                        customBtn.textContent = _('Check Custom Domain');
                    }
                    if (cRes && cRes.success) {
                        try {
                            const cResults = JSON.parse(cRes.data);
                            if (cResults.length > 0) {
                                const cItem = cResults[0];
                                const cBadgeColor = cItem.success ? '#28a745' : '#dc3545';
                                const cBadge = E('span', { style: `display: inline-block; padding: 2px 6px; border-radius: 4px; color: white; font-weight: bold; font-size: 11px; background: ${cBadgeColor};` }, cItem.status_class);
                                
                                if (results.length === 0 && !document.body.contains(table)) {
                                  container.insertBefore(table, customDomainWrap);
                                }
                                
                                table.appendChild(E('tr', { class: 'tr cbi-rowstyle-2' }, [
                                    E('td', { class: 'td' }, [E('strong', {}, cItem.section), E('br'), E('small', {}, cItem.domain)]),
                                    E('td', { class: 'td' }, cItem.route_type),
                                    E('td', { class: 'td' }, [cItem.ip || '?', E('br'), E('small', {}, `${cItem.dns_ms}ms`)]),
                                    E('td', { class: 'td' }, cItem.tcp_ms > 0 ? `${cItem.tcp_ms}` : '-'),
                                    E('td', { class: 'td' }, cItem.tls_ms > 0 ? `${cItem.tls_ms}` : '-'),
                                    E('td', { class: 'td' }, cItem.http_ms > 0 ? `${cItem.http_ms}` : '-'),
                                    E('td', { class: 'td' }, cBadge),
                                ]));
                            }
                        } catch(e) {}
                    }
                });
            }
        });
        customDomainWrap.appendChild(customBtn);
        container.appendChild(customDomainWrap);
    })
    .catch(() => {
      container.innerHTML = '';
      container.appendChild(E('p', {}, _('An error occurred while checking services.')));
    });
}
