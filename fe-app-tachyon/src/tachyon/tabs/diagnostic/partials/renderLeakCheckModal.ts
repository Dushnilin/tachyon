import { TachyonShellMethods } from '../../../methods/shell';
import { renderButton } from '../../../../partials';
import { renderRotateCcwIcon24 } from '../../../../icons';
import { Tachyon } from '../../../types';

export function renderLeakCheckModal() {
  let isRunning = false;

  const progressBar = E('div', {
    style:
      'width: 0%; height: 6px; background: linear-gradient(90deg, #007bff, #28a745); border-radius: 3px; transition: width 0.4s ease;',
  });

  const progressContainer = E(
    'div',
    {
      style:
        'width: 100%; height: 6px; background: rgba(128,128,128,0.2); border-radius: 3px; overflow: hidden; margin-bottom: 14px;',
    },
    [progressBar],
  );

  const statusLabel = E(
    'div',
    {
      style:
        'font-size: 13px; font-weight: 500; margin-bottom: 12px; color: var(--text-color-medium, #6c757d);',
    },
    _('Initializing router-level IP & DNS leak test...'),
  );

  const resultsContainer = E('div', {
    style: 'display: none; margin-bottom: 16px;',
  });

  const startTest = async () => {
    if (isRunning) return;
    isRunning = true;

    resultsContainer.style.display = 'none';
    progressContainer.style.display = 'block';
    progressBar.style.width = '30%';
    statusLabel.textContent = _(
      'Querying direct connection and proxy outbound...',
    );

    if (retryBtn) (retryBtn as HTMLButtonElement).disabled = true;

    // Advance progress smoothly
    const timer = setTimeout(() => {
      progressBar.style.width = '70%';
      statusLabel.textContent = _('Testing upstream DNS resolvers...');
    }, 1500);

    try {
      const response = await TachyonShellMethods.leakCheck(
        (progress, stage) => {
          clearTimeout(timer);
          progressBar.style.width = `${progress}%`;
          if (stage === 'dns') {
            statusLabel.textContent = _('Testing upstream DNS resolvers...');
          } else if (stage === 'ip') {
            statusLabel.textContent = _(
              'Querying direct connection and proxy outbound...',
            );
          }
        },
      );
      clearTimeout(timer);
      progressBar.style.width = '100%';

      if (response.success && response.data) {
        statusLabel.textContent = _('Diagnostic check completed');
        setTimeout(() => {
          progressContainer.style.display = 'none';
          progressBar.style.width = '0%';
        }, 400);

        renderResults(response.data);
      } else {
        const err =
          !response.success && response.error
            ? response.error
            : _('Diagnostic check failed to complete');
        progressContainer.style.display = 'none';
        statusLabel.textContent = err;
        resultsContainer.innerHTML = '';
        resultsContainer.appendChild(
          E(
            'div',
            { class: 'alert-message warning' },
            err ||
              _(
                'Could not contact leak test endpoints. Please ensure router has internet access.',
              ),
          ),
        );
        resultsContainer.style.display = 'block';
      }
    } catch (e) {
      clearTimeout(timer);
      progressContainer.style.display = 'none';
      statusLabel.textContent = _('An unexpected error occurred during test');
      resultsContainer.innerHTML = '';
      resultsContainer.appendChild(
        E(
          'div',
          { class: 'alert-message warning' },
          e instanceof Error ? e.message : String(e),
        ),
      );
      resultsContainer.style.display = 'block';
    } finally {
      isRunning = false;
      if (retryBtn) (retryBtn as HTMLButtonElement).disabled = false;
    }
  };

  const renderResults = (data: Tachyon.LeakCheckResult) => {
    resultsContainer.innerHTML = '';
    const { ip_leak, dns_leak } = data;

    // --- 1. IP Leak Section ---
    const isDirectRouting =
      ip_leak.proxy_online &&
      (ip_leak.leaked || ip_leak.direct_ip === ip_leak.proxy_ip);

    const ipAlertClass = !ip_leak.proxy_online
      ? 'alert-message info'
      : isDirectRouting
        ? 'alert-message info'
        : 'alert-message success';

    const ipAlertText = !ip_leak.proxy_online
      ? _('Proxy outbound is inactive or not configured for local testing.')
      : isDirectRouting
        ? _(
            'ℹ️ Direct connection (WAN): Public IP matches your ISP. Under selective routing (by domains or blocklists), unblocked resources bypass the proxy — this is standard operation.',
          )
        : _('🛡️ SECURE: Public IP is concealed behind the proxy outbound.');

    const ipTable = E(
      'table',
      {
        class: 'table cbi-section-table',
        style: 'width: 100%; margin-bottom: 12px; font-size: 12px;',
      },
      [
        E('thead', {}, [
          E('tr', { class: 'tr cbi-section-table-titles' }, [
            E('th', { class: 'th' }, _('Connection Path')),
            E('th', { class: 'th' }, _('Observed Public IP')),
            E('th', { class: 'th' }, _('Location')),
            E('th', { class: 'th' }, _('ISP / Organization')),
            E('th', { class: 'th', style: 'text-align: center;' }, _('Status')),
          ]),
        ]),
        E('tbody', {}, [
          E('tr', { class: 'tr cbi-section-table-row' }, [
            E('td', { class: 'td' }, [
              E('b', {}, _('Direct WAN (ISP)')),
              E(
                'div',
                {
                  style:
                    'font-size: 11px; color: var(--text-color-medium, #6c757d);',
                },
                _('Direct connection via ISP'),
              ),
            ]),
            E('td', { class: 'td' }, [E('code', {}, ip_leak.direct_ip || '—')]),
            E(
              'td',
              { class: 'td' },
              [ip_leak.direct_country, ip_leak.direct_city]
                .filter(Boolean)
                .join(', ') || '—',
            ),
            E('td', { class: 'td' }, ip_leak.direct_isp || '—'),
            E('td', { class: 'td', style: 'text-align: center;' }, [
              E(
                'span',
                {
                  class: 'badge',
                  style:
                    'background: var(--text-color-medium, #6c757d); color: #fff; padding: 2px 6px; border-radius: 4px; font-size: 11px;',
                },
                _('WAN'),
              ),
            ]),
          ]),
          E('tr', { class: 'tr cbi-section-table-row' }, [
            E('td', { class: 'td' }, [
              E('b', {}, _('Proxy Outbound')),
              E(
                'div',
                {
                  style:
                    'font-size: 11px; color: var(--text-color-medium, #6c757d);',
                },
                _('Tachyon proxy routing'),
              ),
            ]),
            E('td', { class: 'td' }, [E('code', {}, ip_leak.proxy_ip || '—')]),
            E(
              'td',
              { class: 'td' },
              [ip_leak.proxy_country, ip_leak.proxy_city]
                .filter(Boolean)
                .join(', ') || '—',
            ),
            E('td', { class: 'td' }, ip_leak.proxy_org || '—'),
            E('td', { class: 'td', style: 'text-align: center;' }, [
              !ip_leak.proxy_online
                ? E(
                    'span',
                    {
                      class: 'badge',
                      style:
                        'background: #6c757d; color: #fff; padding: 2px 6px; border-radius: 4px; font-size: 11px;',
                    },
                    _('INACTIVE'),
                  )
                : isDirectRouting
                  ? E(
                      'span',
                      {
                        class: 'badge',
                        style:
                          'background: #17a2b8; color: #fff; padding: 2px 6px; border-radius: 4px; font-size: 11px;',
                      },
                      _('DIRECT'),
                    )
                  : E(
                      'span',
                      {
                        class: 'badge',
                        style:
                          'background: #28a745; color: #fff; padding: 2px 6px; border-radius: 4px; font-size: 11px;',
                      },
                      _('SECURE'),
                    ),
            ]),
          ]),
        ]),
      ],
    );

    const ipSection = E(
      'div',
      {
        class: 'cbi-section',
        style:
          'margin-bottom: 20px; border: 1px solid var(--border-color, rgba(128,128,128,0.2)); border-radius: 6px; padding: 12px;',
      },
      [
        E('h4', { style: 'margin-top: 0; margin-bottom: 8px;' }, [
          '🌐 ',
          _('Public IP Address Isolation'),
        ]),
        E('div', { class: ipAlertClass, style: 'margin-bottom: 12px;' }, [
          ipAlertText,
        ]),
        ipTable,
      ],
    );

    // --- 2. DNS Leak Section ---
    const dnsAlertClass =
      !dns_leak.proxy_online || (dns_leak.dns_servers || []).length === 0
        ? 'alert-message info'
        : dns_leak.dns_leaked
          ? 'alert-message warning'
          : 'alert-message success';

    const dnsAlertText =
      !dns_leak.proxy_online || (dns_leak.dns_servers || []).length === 0
        ? _(
            'No DNS resolvers captured through proxy (proxy is offline or test domain is not intercepted).',
          )
        : dns_leak.dns_leaked
          ? _(
              'ℹ️ ISP DNS detected: DNS queries are handled by your local Internet Service Provider. If you use selective routing, this is standard behavior for direct connections.',
            )
          : _(
              '🛡️ SECURE: All DNS queries are resolved through independent secure DNS servers.',
            );

    const dnsTableRows = (dns_leak.dns_servers || []).map((s) =>
      E('tr', { class: 'tr cbi-section-table-row' }, [
        E('td', { class: 'td' }, [E('code', {}, s.ip)]),
        E('td', { class: 'td' }, s.country || '—'),
        E('td', { class: 'td' }, s.isp || '—'),
        E('td', { class: 'td', style: 'text-align: center;' }, [
          s.is_isp
            ? E(
                'span',
                {
                  class: 'badge',
                  style:
                    'background: #fd7e14; color: #fff; padding: 2px 6px; border-radius: 4px; font-size: 11px;',
                },
                _('ISP DNS'),
              )
            : E(
                'span',
                {
                  class: 'badge',
                  style:
                    'background: #28a745; color: #fff; padding: 2px 6px; border-radius: 4px; font-size: 11px;',
                },
                _('SAFE'),
              ),
        ]),
      ]),
    );

    const dnsTable = E(
      'table',
      {
        class: 'table cbi-section-table',
        style: 'width: 100%; font-size: 12px; margin-bottom: 12px;',
      },
      [
        E('thead', {}, [
          E('tr', { class: 'tr cbi-section-table-titles' }, [
            E('th', { class: 'th' }, _('Resolver IP')),
            E('th', { class: 'th' }, _('Country')),
            E('th', { class: 'th' }, _('Upstream Provider / ASN')),
            E(
              'th',
              { class: 'th', style: 'text-align: center;' },
              _('Verdict'),
            ),
          ]),
        ]),
        E(
          'tbody',
          {},
          dnsTableRows.length > 0
            ? dnsTableRows
            : [
                E('tr', { class: 'tr' }, [
                  E(
                    'td',
                    {
                      class: 'td',
                      colSpan: 4,
                      style: 'text-align: center; opacity: 0.7;',
                    },
                    _('No DNS resolvers recorded'),
                  ),
                ]),
              ],
        ),
      ],
    );

    const dnsSection = E(
      'div',
      {
        class: 'cbi-section',
        style:
          'border: 1px solid var(--border-color, rgba(128,128,128,0.2)); border-radius: 6px; padding: 12px;',
      },
      [
        E('h4', { style: 'margin-top: 0; margin-bottom: 8px;' }, [
          '🔍 ',
          _('DNS Upstream Resolver Analysis'),
        ]),
        E('div', { class: dnsAlertClass, style: 'margin-bottom: 12px;' }, [
          dnsAlertText,
        ]),
        dnsTable,
      ],
    );

    resultsContainer.appendChild(ipSection);
    resultsContainer.appendChild(dnsSection);
    resultsContainer.style.display = 'block';
  };

  const retryBtn = renderButton({
    classNames: ['cbi-button-action'],
    onClick: startTest,
    icon: renderRotateCcwIcon24,
    text: _('Re-run Leak Test'),
  });

  const closeBtn = renderButton({
    classNames: ['cbi-button'],
    onClick: () => {
      if (ui.hideModal) ui.hideModal();
    },
    text: _('Close'),
  });

  const modalContent = E('div', { style: 'padding: 8px;' }, [
    E(
      'p',
      {
        style:
          'font-size: 13px; color: var(--text-color-medium, #6c757d); margin-bottom: 14px;',
      },
      _(
        'Simultaneous check of your public IP address and upstream DNS resolvers to verify network visibility through direct connection and proxy.',
      ),
    ),
    statusLabel,
    progressContainer,
    resultsContainer,
    E(
      'div',
      {
        style:
          'display: flex; justify-content: flex-end; gap: 8px; margin-top: 16px; border-top: 1px solid var(--border-color, rgba(128,128,128,0.2)); padding-top: 12px;',
      },
      [retryBtn, closeBtn],
    ),
  ]);

  ui.showModal(`🛡️ ${_('Tachyon IP & DNS Leak Detection')}`, modalContent);

  // Auto-run test on open
  startTest();
}
