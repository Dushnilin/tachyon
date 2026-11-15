import { TachyonShellMethods } from '../../../methods/shell';
import { renderButton } from '../../../../partials';
import {
  renderRotateCcwIcon24,
  renderGlobeIcon,
  renderSearchIcon24,
} from '../../../../icons';
import { Tachyon } from '../../../types';

export function renderLeakCheckModal() {
  let isRunning = false;
  let savedPlus = false;
  try {
    savedPlus = localStorage.getItem('tachyon.dns-leak.plus') === '1';
  } catch {
    /* Storage may be unavailable. */
  }
  const plusCheckbox = E('input', {
    type: 'checkbox',
    checked: savedPlus,
  }) as HTMLInputElement;
  plusCheckbox.addEventListener('change', () => {
    try {
      localStorage.setItem(
        'tachyon.dns-leak.plus',
        plusCheckbox.checked ? '1' : '0',
      );
    } catch {
      /* Keep the session preference. */
    }
  });

  const progressBar = E('div', {
    style:
      'width: 0%; height: 6px; background: var(--tachyon-accent, #5b8af0); border-radius: 3px; transition: width 0.4s cubic-bezier(0.22, 1, 0.36, 1);',
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
    plusCheckbox.disabled = true;

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
        plusCheckbox.checked,
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
      plusCheckbox.disabled = false;
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
        ? 'alert-message warning'
        : 'alert-message success';

    const ipAlertText = !ip_leak.proxy_online
      ? _('Proxy outbound is inactive or not configured for local testing.')
      : isDirectRouting
        ? _(
            'Direct connection (WAN): Public IP matches your ISP. Under selective routing (by domains or blocklists), unblocked resources bypass the proxy — this is standard operation.',
          )
        : _('SECURE: Public IP is concealed behind the proxy outbound.');

    const ipTable = E(
      'table',
      {
        class: 'table cbi-section-table',
        style:
          'width: 100%; margin-bottom: 4px; font-size: 12px; table-layout: fixed; word-break: break-word;',
      },
      [
        E('thead', {}, [
          E('tr', { class: 'tr cbi-section-table-titles' }, [
            E(
              'th',
              { class: 'th', style: 'padding: 6px 8px;' },
              _('Connection Path'),
            ),
            E(
              'th',
              { class: 'th', style: 'padding: 6px 8px;' },
              _('Observed Public IP'),
            ),
            E('th', { class: 'th', style: 'padding: 6px 8px;' }, _('Location')),
            E(
              'th',
              { class: 'th', style: 'padding: 6px 8px;' },
              _('ISP / Organization'),
            ),
            E(
              'th',
              {
                class: 'th',
                style: 'padding: 6px 8px; text-align: center; width: 110px;',
              },
              _('Status'),
            ),
          ]),
        ]),
        E('tbody', {}, [
          E('tr', { class: 'tr cbi-section-table-row' }, [
            E('td', { class: 'td', style: 'padding: 6px 8px;' }, [
              E('b', { style: 'font-size: 12px;' }, _('Direct WAN (ISP)')),
            ]),
            E(
              'td',
              {
                class: 'td',
                style:
                  'padding: 6px 8px; font-family: ui-monospace, monospace;',
              },
              [E('code', {}, ip_leak.direct_ip || '—')],
            ),
            E(
              'td',
              { class: 'td', style: 'padding: 6px 8px;' },
              [ip_leak.direct_country, ip_leak.direct_city]
                .filter(Boolean)
                .join(', ') || '—',
            ),
            E(
              'td',
              { class: 'td', style: 'padding: 6px 8px;' },
              ip_leak.direct_isp || '—',
            ),
            E(
              'td',
              { class: 'td', style: 'padding: 6px 8px; text-align: center;' },
              [
                E(
                  'span',
                  {
                    class: 'badge',
                    style:
                      'background: rgba(255,255,255,0.06); color: #a1a1a6; border: 1px solid rgba(255,255,255,0.12); padding: 2px 7px; border-radius: 5px; font-size: 10.5px; font-weight: 600;',
                  },
                  _('WAN'),
                ),
              ],
            ),
          ]),
          E('tr', { class: 'tr cbi-section-table-row' }, [
            E('td', { class: 'td', style: 'padding: 6px 8px;' }, [
              E('b', { style: 'font-size: 12px;' }, _('Proxy Outbound')),
            ]),
            E(
              'td',
              {
                class: 'td',
                style:
                  'padding: 6px 8px; font-family: ui-monospace, monospace;',
              },
              [E('code', {}, ip_leak.proxy_ip || '—')],
            ),
            E(
              'td',
              { class: 'td', style: 'padding: 6px 8px;' },
              [ip_leak.proxy_country, ip_leak.proxy_city]
                .filter(Boolean)
                .join(', ') || '—',
            ),
            E(
              'td',
              { class: 'td', style: 'padding: 6px 8px;' },
              ip_leak.proxy_org || '—',
            ),
            E(
              'td',
              { class: 'td', style: 'padding: 6px 8px; text-align: center;' },
              [
                !ip_leak.proxy_online
                  ? E(
                      'span',
                      {
                        class: 'badge',
                        style:
                          'background: rgba(255,255,255,0.06); color: #a1a1a6; border: 1px solid rgba(255,255,255,0.12); padding: 2px 7px; border-radius: 5px; font-size: 10.5px; font-weight: 600;',
                      },
                      _('INACTIVE'),
                    )
                  : isDirectRouting
                    ? E(
                        'span',
                        {
                          class: 'badge',
                          style:
                            'background: rgba(10,132,255,0.12); color: #409cff; border: 1px solid rgba(10,132,255,0.28); padding: 2px 7px; border-radius: 5px; font-size: 10.5px; font-weight: 600;',
                        },
                        _('DIRECT'),
                      )
                    : E(
                        'span',
                        {
                          class: 'badge',
                          style:
                            'background: rgba(48,209,88,0.12); color: #30d158; border: 1px solid rgba(48,209,88,0.28); padding: 2px 7px; border-radius: 5px; font-size: 10.5px; font-weight: 600;',
                        },
                        _('SECURE'),
                      ),
              ],
            ),
          ]),
        ]),
      ],
    );

    const ipSection = E(
      'div',
      {
        class: 'cbi-section',
        style:
          'margin-bottom: 10px; border: 1px solid rgba(255,255,255,0.08); background: #141417; border-radius: 8px; padding: 10px 12px; width: 100%; box-sizing: border-box;',
      },
      [
        E(
          'div',
          {
            style:
              'display: flex; align-items: center; justify-content: space-between; gap: 8px; margin-bottom: 6px;',
          },
          [
            E(
              'h4',
              {
                style:
                  'margin: 0; font-size: 13px; font-weight: 600; display: inline-flex; align-items: center; gap: 6px;',
              },
              [renderGlobeIcon(14), _('Public IP Address Isolation')],
            ),
          ],
        ),
        E(
          'div',
          {
            class: ipAlertClass,
            style:
              'margin-bottom: 8px; padding: 6px 10px; font-size: 12px; width: 100%; box-sizing: border-box;',
          },
          [ipAlertText],
        ),
        E('div', { style: 'width: 100%; overflow-x: hidden;' }, [ipTable]),
      ],
    );

    // --- 2. DNS Leak Section ---
    const proxyDnsServers = dns_leak.dns_servers || [];
    const directDnsServers = dns_leak.direct_dns_servers || [];
    const hasProxyDns = proxyDnsServers.length > 0;

    const dnsAlertClass =
      dns_leak.verdict === 'plaintext_observed'
        ? 'alert-message warning'
        : !hasProxyDns
          ? 'alert-message info'
          : dns_leak.dns_leaked
            ? 'alert-message warning'
            : dns_leak.verdict === 'inconclusive'
              ? 'alert-message info'
              : 'alert-message success';

    const dnsAlertText =
      dns_leak.verdict === 'plaintext_observed'
        ? _(
            'Test DNS queries were observed unencrypted on the selected WAN interface.',
          )
        : !hasProxyDns
          ? _(
              'DNS resolvers through proxy are not captured (proxy is offline or test domain is not intercepted).',
            )
          : dns_leak.dns_leaked
            ? _(
                'A resolver matches a configured WAN DNS address. This is a warning for the proxy probe, not proof that all client DNS leaks.',
              )
            : dns_leak.verdict === 'inconclusive'
              ? _(
                  'Resolver ownership is not confirmed. No reliable leak verdict can be made.',
                )
              : _(
                  'No configured WAN DNS address was observed in the proxy probe. Resolver ownership does not verify DNS encryption.',
                );

    const makeDnsRow = (s: Tachyon.DNSResolverInfo, pathLabel: string) =>
      E('tr', { class: 'tr cbi-section-table-row' }, [
        E(
          'td',
          {
            class: 'td',
            style: 'padding: 6px 8px; font-family: ui-monospace, monospace;',
          },
          [E('code', {}, s.ip)],
        ),
        E('td', { class: 'td', style: 'padding: 6px 8px;' }, s.country || '—'),
        E('td', { class: 'td', style: 'padding: 6px 8px;' }, s.isp || '—'),
        E(
          'td',
          { class: 'td', style: 'padding: 6px 8px; text-align: center;' },
          s.is_isp
            ? E(
                'span',
                {
                  class: 'badge',
                  style:
                    'background: rgba(255,159,10,0.14); color: #ff9f0a; border: 1px solid rgba(255,159,10,0.3); padding: 2px 7px; border-radius: 5px; font-size: 10.5px; font-weight: 600;',
                },
                s.verdict ? _('WAN DNS') : _('ISP DNS'),
              )
            : E(
                'span',
                {
                  class: 'badge',
                  style:
                    s.verdict === 'unknown' || s.verdict === 'shared'
                      ? 'background: rgba(255,255,255,0.06); color: #a1a1a6; border: 1px solid rgba(255,255,255,0.12); padding: 2px 7px; border-radius: 5px; font-size: 10.5px; font-weight: 600;'
                      : 'background: rgba(48,209,88,0.12); color: #30d158; border: 1px solid rgba(48,209,88,0.28); padding: 2px 7px; border-radius: 5px; font-size: 10.5px; font-weight: 600;',
                },
                s.verdict === 'unknown' || s.verdict === 'shared'
                  ? _('UNCONFIRMED')
                  : s.is_public
                    ? _('PUBLIC DNS')
                    : _('SAFE'),
              ),
        ),
        E(
          'td',
          {
            class: 'td',
            style: 'padding: 6px 8px; font-size: 11px; color: #a1a1a6;',
          },
          pathLabel,
        ),
      ]);

    const proxyDnsRows = proxyDnsServers.map((s) =>
      makeDnsRow(s, _('via Proxy (HTTP probe)')),
    );
    const directDnsRows = directDnsServers.map((s) =>
      makeDnsRow(s, _('via WAN (HTTP probe)')),
    );
    const routerDnsRows = (dns_leak.router_dns_servers || []).map((s) =>
      makeDnsRow(s, _('Router DNS (127.0.0.1)')),
    );
    const allDnsRows = [...routerDnsRows, ...proxyDnsRows, ...directDnsRows];

    const dnsTable = E(
      'table',
      {
        class: 'table cbi-section-table',
        style:
          'width: 100%; font-size: 12px; margin-bottom: 4px; table-layout: fixed; word-break: break-word;',
      },
      [
        E('thead', {}, [
          E('tr', { class: 'tr cbi-section-table-titles' }, [
            E(
              'th',
              { class: 'th', style: 'padding: 6px 8px;' },
              _('Resolver IP'),
            ),
            E('th', { class: 'th', style: 'padding: 6px 8px;' }, _('Country')),
            E(
              'th',
              { class: 'th', style: 'padding: 6px 8px;' },
              _('Upstream Provider / ASN'),
            ),
            E(
              'th',
              {
                class: 'th',
                style: 'padding: 6px 8px; text-align: center; width: 110px;',
              },
              _('Verdict'),
            ),
            E('th', { class: 'th', style: 'padding: 6px 8px;' }, _('Path')),
          ]),
        ]),
        E(
          'tbody',
          {},
          allDnsRows.length > 0
            ? allDnsRows
            : [
                E('tr', { class: 'tr' }, [
                  E(
                    'td',
                    {
                      class: 'td',
                      colSpan: 5,
                      style: 'text-align: center; opacity: 0.7;',
                    },
                    _('No DNS resolvers recorded'),
                  ),
                ]),
              ],
        ),
      ],
    );

    const searchIcon = renderSearchIcon24();
    searchIcon.setAttribute('width', '14');
    searchIcon.setAttribute('height', '14');

    const dnsSection = E(
      'div',
      {
        class: 'cbi-section',
        style:
          'border: 1px solid rgba(255,255,255,0.08); background: #141417; border-radius: 8px; padding: 10px 12px; width: 100%; box-sizing: border-box;',
      },
      [
        E(
          'h4',
          {
            style:
              'margin-top: 0; margin-bottom: 6px; font-size: 13px; font-weight: 600; display: inline-flex; align-items: center; gap: 6px;',
          },
          [searchIcon, _('DNS Upstream Resolver Analysis')],
        ),
        E(
          'div',
          {
            class: dnsAlertClass,
            style:
              'margin-bottom: 8px; padding: 6px 10px; font-size: 12px; width: 100%; box-sizing: border-box;',
          },
          [dnsAlertText],
        ),
        E('div', { style: 'width: 100%; overflow-x: hidden;' }, [dnsTable]),
        ...(data.mode === 'plus'
          ? [
              E('h4', {}, _('Plus: router DNS and configured transport')),
              E(
                'div',
                {
                  class:
                    dns_leak.wan_dns_capture?.status === 'plaintext_observed'
                      ? 'alert-message warning'
                      : 'alert-message info',
                  style: 'margin-bottom: 12px; overflow-wrap: anywhere;',
                },
                [
                  E('b', {}, _('Unencrypted DNS on WAN')),
                  E(
                    'p',
                    {},
                    dns_leak.wan_dns_capture?.status === 'plaintext_observed'
                      ? _(
                          'Test DNS queries were observed unencrypted on the selected WAN interface.',
                        )
                      : dns_leak.wan_dns_capture?.status === 'not_observed'
                        ? _(
                            'No test DNS names were observed on WAN port 53. This alone does not prove encryption or absence of other leaks.',
                          )
                        : _(
                            'Packet capture is unavailable or incomplete; unencrypted DNS could not be checked.',
                          ),
                  ),
                  E(
                    'div',
                    {},
                    `${_('Interface')}: ${dns_leak.wan_dns_capture?.interface || '—'} · ${_('Observed test queries')}: ${dns_leak.wan_dns_capture?.queries ?? 0}`,
                  ),
                ],
              ),
              E(
                'div',
                {
                  class:
                    dns_leak.doh_tls_probe?.status === 'verified' &&
                    !dns_leak.doh_tls_probe?.router_verification_disabled
                      ? 'alert-message success'
                      : 'alert-message info',
                  style: 'margin-bottom: 12px; overflow-wrap: anywhere;',
                },
                [
                  E('b', {}, _('Independent DoH/TLS probe')),
                  E(
                    'p',
                    {},
                    dns_leak.doh_tls_probe?.status === 'verified'
                      ? _(
                          'A real DNS answer was received over HTTPS with certificate validation.',
                        )
                      : dns_leak.doh_tls_probe?.status === 'unsupported'
                        ? _(
                            'TLS probe supports the active DoH server; other DNS protocols are not verified.',
                          )
                        : _(
                            'The TLS certificate or DNS answer could not be verified.',
                          ),
                  ),
                  E('div', {}, dns_leak.doh_tls_probe?.server || '—'),
                  ...(dns_leak.doh_tls_probe?.router_verification_disabled
                    ? [
                        E(
                          'p',
                          { class: 'alert-message warning' },
                          _(
                            'TLS verification is disabled in the router DNS configuration. The independent probe does not change this setting.',
                          ),
                        ),
                      ]
                    : []),
                ],
              ),
              E(
                'p',
                {},
                dns_leak.router_dns_status === 'observed'
                  ? _('Router DNS queries were observed by the test service.')
                  : _(
                      'Router DNS observations are unavailable. This does not mean the connection is safe.',
                    ),
              ),
              E(
                'p',
                {},
                _(
                  'HTTP probe paths do not prove DNS packet routing. Transport below is taken from the generated configuration. Engine encryption on the wire is not verified by the independent DoH probe.',
                ),
              ),
              E(
                'div',
                { style: 'display: grid; gap: 8px; overflow-wrap: anywhere;' },
                (dns_leak.configured_dns || [])
                  .filter(
                    (s) =>
                      !s.tag.startsWith('dns-health-') &&
                      ['https', 'tls', 'quic', 'h3', 'udp', 'tcp'].includes(
                        s.protocol,
                      ) &&
                      s.server !== '127.0.0.1',
                  )
                  .map((s) =>
                    E(
                      'div',
                      {
                        style:
                          'border: 1px solid var(--border-color, #666); border-radius: 4px; padding: 8px;',
                      },
                      [
                        E('b', {}, s.tag),
                        E('div', {}, [
                          s.server || '—',
                          ' · ',
                          s.protocol.toUpperCase(),
                          ' · ',
                          s.encrypted
                            ? _('Encrypted protocol configured')
                            : _('Encryption not confirmed'),
                        ]),
                        E(
                          'div',
                          {},
                          s.detour
                            ? `${_('Configured detour')}: ${s.detour}`
                            : _(
                                'No explicit DNS detour; default routing applies',
                              ),
                        ),
                      ],
                    ),
                  ),
              ),
              E(
                'p',
                {},
                _(
                  'Unencrypted bootstrap DNS alone is not proof of a DNS leak. Browser Secure DNS may use a different resolver.',
                ),
              ),
            ]
          : []),
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

  const modalContent = E(
    'div',
    {
      class: 'tachyon-leak-check-modal',
      style: 'padding: 4px 2px; width: 100%; box-sizing: border-box;',
    },
    [
      E(
        'div',
        {
          style:
            'display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap; padding: 8px 10px; border-radius: 8px; background: #141417; border: 1px solid rgba(255,255,255,0.08); margin-bottom: 10px;',
        },
        [
          E(
            'div',
            {
              style: 'font-size: 12px; color: #a1a1a6; flex: 1 1 280px;',
            },
            _(
              'Simultaneous check of your public IP address and upstream DNS resolvers to verify network visibility through direct connection and proxy.',
            ),
          ),
          E(
            'label',
            {
              style:
                'display: inline-flex; align-items: center; gap: 6px; cursor: pointer; font-size: 12px; font-weight: 500; color: #f5f5f7; padding: 4px 8px; border-radius: 6px; background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.08); flex-shrink: 0;',
              title: _(
                'Plus tests router DNS, looks for unencrypted test queries on WAN and checks an independent DoH/TLS connection. Select the mode and re-run the test.',
              ),
            },
            [plusCheckbox, _('Plus mode')],
          ),
        ],
      ),
      statusLabel,
      progressContainer,
      resultsContainer,
      E(
        'div',
        {
          style:
            'display: flex; justify-content: flex-end; gap: 8px; margin-top: 10px; border-top: 1px solid rgba(255,255,255,0.08); padding-top: 10px;',
        },
        [retryBtn, closeBtn],
      ),
    ],
  );

  ui.showModal(_('Tachyon IP & DNS Leak Detection'), modalContent);

  // Auto-run test on open
  startTest();
}
