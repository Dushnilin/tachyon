/* eslint-disable @typescript-eslint/no-explicit-any */
import { renderButton } from '../../../../partials';
import { showToast } from '../../../../helpers/showToast';
import { TachyonShellMethods } from '../../../methods';
import { logger } from '../../../services';
import { Tachyon } from '../../../types';

export interface AiDoctorHistoryEntry {
  timestamp: string;
  report: string;
  quickFixes: string[];
}

export interface AiDoctorModalOptions {
  report: string;
  quickFixes?: string[];
  backendNodes?: Array<{ name: string; status: 'OK' | 'WARN' | 'FAIL' }> | null;
  onRefreshServices?: () => Promise<void>;
}

const AI_DOCTOR_HISTORY_STORAGE_KEY = 'tachyon_ai_doctor_history';

export function getAiDoctorHistory(): AiDoctorHistoryEntry[] {
  try {
    const raw = localStorage.getItem(AI_DOCTOR_HISTORY_STORAGE_KEY);
    return raw ? (JSON.parse(raw) as AiDoctorHistoryEntry[]) : [];
  } catch (_e) {
    return [];
  }
}

export function saveAiDoctorHistory(entry: AiDoctorHistoryEntry): void {
  try {
    const current = getAiDoctorHistory();
    const updated = [entry, ...current].slice(0, 5);
    localStorage.setItem(
      AI_DOCTOR_HISTORY_STORAGE_KEY,
      JSON.stringify(updated),
    );
  } catch (_e) {
    // Ignore storage errors
  }
}

export const FIX_LABELS: Record<string, string> = {
  start_singbox: _('Start sing-box'),
  rebuild_rules: _('Rebuild firewall rules'),
  fix_dnsmasq: _('Restart dnsmasq'),
  fix_resolv_symlink: _('Fix resolv.conf'),
  start_watchdog: _('Start watchdog'),
  restart_singbox_dns: _('Restart sing-box DNS'),
  fix_uci_config: _('Restore config backup'),
  fix_wan_interface: _('Reconnect WAN'),
  fix_gateway: _('Resolve gateway'),
  clear_dns_cache: _('Clear DNS cache'),
  update_subscriptions: _('Update subscriptions'),
  reset_firewall: _('Restart firewall'),
  restart_network: _('Restart network'),
  restart_zapret: _('Restart Zapret/ByeDPI'),
  optimize_memory: _('Optimize RAM memory'),
  switch_to_doh: _('Switch DNS to DoH'),
  heal_network_stack: _('Auto-Heal Network Stack'),
  enable_safe_bypass: _('Enable Direct WAN Bypass'),
  restore_native_internet: _('Restore Native Internet (Stop Tachyon)'),
  fix_system_time: _('Sync System Time (NTP)'),
  flush_conntrack: _('Flush Conntrack Table'),
  fix_bootstrap_dns: _('Reset Bootstrap DNS'),
  optimize_mtu: _('Optimize AWG MTU'),
};

function getUi(): any {
  if (typeof ui !== 'undefined') return ui;
  if (typeof window !== 'undefined' && (window as any).ui)
    return (window as any).ui;
  if (typeof globalThis !== 'undefined' && (globalThis as any).ui)
    return (globalThis as any).ui;
  return null;
}

export function getDeviceIcon(hostname: string): string {
  const h = hostname.toLowerCase();
  if (
    h.includes('tv') ||
    h.includes('samsung') ||
    h.includes('lg') ||
    h.includes('bravia') ||
    h.includes('roku') ||
    h.includes('appletv')
  )
    return '📺';
  if (
    h.includes('phone') ||
    h.includes('iphone') ||
    h.includes('android') ||
    h.includes('pixel') ||
    h.includes('xiaomi') ||
    h.includes('galaxy')
  )
    return '📱';
  if (
    h.includes('mac') ||
    h.includes('pc') ||
    h.includes('laptop') ||
    h.includes('desktop') ||
    h.includes('thinkpad')
  )
    return '💻';
  if (
    h.includes('playstation') ||
    h.includes('ps4') ||
    h.includes('ps5') ||
    h.includes('xbox') ||
    h.includes('switch') ||
    h.includes('nintendo')
  )
    return '🎮';
  return '📟';
}

export function renderAiDoctorModal(options: AiDoctorModalOptions): void {
  const report = options.report;
  const quickFixes = options.quickFixes || [];
  const repLower = report.toLowerCase();

  const nodes = options.backendNodes ?? [
    {
      name: 'WAN',
      status:
        repLower.includes('wan interface down') ||
        repLower.includes(
          'шлюз по умолчанию или внешний интернет недоступен',
        ) ||
        repLower.includes('wan interface is unreachable')
          ? ('FAIL' as const)
          : ('OK' as const),
    },
    {
      name: 'DNS',
      status:
        repLower.includes('сбой разрешения dns') ||
        repLower.includes('dns resolution failed') ||
        repLower.includes('dns failed') ||
        repLower.includes('dnsmasq failed')
          ? ('FAIL' as const)
          : ('OK' as const),
    },
    {
      name: 'sing-box',
      status:
        (repLower.includes('sing-box') || repLower.includes('proxy')) &&
        (repLower.includes('остановлен') ||
          repLower.includes('stopped') ||
          repLower.includes('не функционирует') ||
          repLower.includes('error') ||
          repLower.includes('crash'))
          ? ('FAIL' as const)
          : ('OK' as const),
    },
    {
      name: 'nftables',
      status:
        (repLower.includes('nftables') ||
          repLower.includes('правила файрвола') ||
          repLower.includes('firewall rules')) &&
        (repLower.includes('нарушены') ||
          repLower.includes('damaged') ||
          repLower.includes('corrupted') ||
          repLower.includes('compromised'))
          ? ('WARN' as const)
          : ('OK' as const),
    },
  ];

  let historyEntries = getAiDoctorHistory();
  let activeTab: 'diagnosis' | 'devices' | 'history' = 'diagnosis';
  let lanClients: Tachyon.LanClient[] = [];
  let loadingClients = false;

  const loadLanClients = async () => {
    if (loadingClients) return;
    loadingClients = true;
    renderModalLayout();
    try {
      const res = await TachyonShellMethods.getLanClients();
      if (res && res.success && res.data && Array.isArray(res.data.clients)) {
        lanClients = res.data.clients;
      }
    } catch (e) {
      logger.error(
        '[DIAGNOSTIC]',
        'getLanClients error',
        e instanceof Error ? e.message : String(e),
      );
    } finally {
      loadingClients = false;
      renderModalLayout();
    }
  };

  const copySupportReport = async () => {
    let currentClients = lanClients;
    if (currentClients.length === 0) {
      try {
        const res = await TachyonShellMethods.getLanClients();
        if (res && res.success && res.data?.clients) {
          lanClients = res.data.clients;
          currentClients = lanClients;
        }
      } catch (_e) {
        // ignore network clients error when copying report
      }
    }

    const nodeSummary = nodes.map((n) => `${n.name}: ${n.status}`).join(' | ');
    const fixesSummary =
      quickFixes.length > 0
        ? quickFixes.map((f) => FIX_LABELS[f] || f).join(', ')
        : _('None');
    const clientsSummary =
      currentClients.length > 0
        ? currentClients
            .map(
              (c) =>
                `- ${c.hostname} (IP: ${c.ip}, MAC: ${c.mac.slice(0, 8)}**): ${c.mode.toUpperCase()}`,
            )
            .join('\n')
        : _('No DHCP clients detected');

    const text = [
      '# Tachyon AI Doctor Diagnostic Report',
      `Generated: ${new Date().toISOString()}`,
      `Pillars: ${nodeSummary}`,
      `Recommended Fixes: ${fixesSummary}`,
      '',
      '## Diagnosis:',
      report,
      '',
      '## LAN Devices Routing:',
      clientsSummary,
    ].join('\n');

    try {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        await navigator.clipboard.writeText(text);
      } else {
        const ta = document.createElement('textarea');
        ta.value = text;
        document.body.appendChild(ta);
        ta.select();
        document.execCommand('copy');
        document.body.removeChild(ta);
      }
      showToast(_('Anonymized support report copied to clipboard'), 'success');
    } catch (_err) {
      showToast(_('Failed to copy report to clipboard'), 'error');
    }
  };

  const renderRootCauseBanner = () => {
    return E(
      'div',
      {
        class: 'cbi-section-node',
        style:
          'display: flex; align-items: center; justify-content: space-around; gap: 8px; flex-wrap: wrap; padding: 8px 12px; margin-bottom: 12px; border-radius: 6px; background: var(--background-color-high, rgba(0,0,0,0.03)); border: 1px solid var(--border-color, rgba(0,0,0,0.1));',
      },
      nodes.map((node) => {
        const labelClass =
          node.status === 'OK'
            ? 'label-success'
            : node.status === 'WARN'
              ? 'label-warning'
              : 'label-danger';
        const icon =
          node.status === 'OK' ? '✓' : node.status === 'WARN' ? '⚠' : '✕';
        return E(
          'span',
          {
            class: `label ${labelClass}`,
            style:
              'font-size: 11px; padding: 4px 10px; border-radius: 4px; display: inline-flex; align-items: center; gap: 4px; font-weight: bold;',
          },
          [E('span', {}, node.name), E('span', {}, `${icon} ${node.status}`)],
        );
      }),
    );
  };

  const renderDiagnosisTabContent = () => {
    return E('div', { class: 'cbi-section-node' }, [
      renderRootCauseBanner(),
      E(
        'pre',
        {
          class: 'tachyon-partial-modal__content alert-message notice',
          style:
            'white-space: pre-wrap; font-family: inherit; font-size: 12px; line-height: 1.5; max-height: 320px; overflow-y: auto; margin: 0; padding: 12px; border-radius: 6px; border: 1px solid var(--border-color, rgba(0,0,0,0.1));',
        },
        report,
      ),
      quickFixes.length > 0
        ? E(
            'div',
            {
              class: 'alert-message warning',
              style:
                'margin-top: 12px; padding: 10px 12px; border-radius: 6px;',
            },
            [
              E(
                'div',
                {
                  style:
                    'font-weight: bold; margin-bottom: 8px; font-size: 12px;',
                },
                '🛠️ ' + _('Recommended Quick Fixes:'),
              ),
              E(
                'div',
                {
                  style: 'display: flex; gap: 6px; flex-wrap: wrap;',
                },
                quickFixes.map((code) => {
                  let applied = false;
                  const friendlyLabel = FIX_LABELS[code] || code;
                  const btn = renderButton({
                    classNames: ['cbi-button-apply'],
                    text: `⚡ ${friendlyLabel}`,
                    onClick: async () => {
                      if (applied) return;
                      btn.textContent =
                        '⏳ ' + _('Applying...') + ' ' + friendlyLabel;
                      showToast(
                        _('Applying fix') + ': ' + friendlyLabel + '...',
                        'success',
                      );
                      const fixRes =
                        await TachyonShellMethods.applyQuickFix(code);
                      if (
                        fixRes &&
                        typeof fixRes === 'object' &&
                        (fixRes as { success?: boolean }).success
                      ) {
                        applied = true;
                        btn.textContent = `✓ ${friendlyLabel} (${_('Fixed')})`;
                        btn.classList.remove('cbi-button-apply');
                        btn.classList.add('cbi-button-neutral');
                        showToast(
                          _('Fix applied') + ': ' + friendlyLabel,
                          'success',
                        );
                      } else {
                        btn.textContent = `⚡ ${friendlyLabel}`;
                        showToast(
                          _('Failed to apply fix') + ': ' + friendlyLabel,
                          'error',
                        );
                      }
                    },
                  });
                  return btn;
                }),
              ),
            ],
          )
        : nodes.some((n) => n.status === 'FAIL' || n.status === 'WARN')
          ? E(
              'div',
              {
                class: 'alert-message warning',
                style:
                  'margin-top: 12px; padding: 8px 12px; font-size: 12px; border-radius: 6px;',
              },
              '⚠️ ' + _('Issues detected. Review the diagnosis above.'),
            )
          : E(
              'div',
              {
                class: 'alert-message success',
                style:
                  'margin-top: 12px; padding: 8px 12px; font-size: 12px; border-radius: 6px;',
              },
              '✓ ' + _('No issues detected. System is running normally.'),
            ),
    ]);
  };

  const renderDevicesTabContent = () => {
    if (loadingClients) {
      return E(
        'div',
        {
          class: 'cbi-section-node',
          style: 'padding: 20px; text-align: center; font-size: 13px;',
        },
        '⏳ ' + _('Loading connected LAN devices...'),
      );
    }

    if (lanClients.length === 0) {
      return E('div', { class: 'cbi-section-node' }, [
        E(
          'div',
          {
            class: 'alert-message info',
            style: 'margin: 0 0 10px 0; padding: 12px;',
          },
          _('No active DHCP clients found on local network.'),
        ),
        renderButton({
          classNames: ['cbi-button-action'],
          text: '🔄 ' + _('Refresh Device List'),
          onClick: loadLanClients,
        }),
      ]);
    }

    return E('div', { class: 'cbi-section-node' }, [
      E(
        'div',
        {
          style:
            'display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px;',
        },
        [
          E(
            'span',
            { style: 'font-weight: bold; font-size: 12px;' },
            `📱 ${_('Connected Devices')}: ${lanClients.length}`,
          ),
          renderButton({
            classNames: ['cbi-button-neutral'],
            text: '🔄 ' + _('Refresh'),
            onClick: loadLanClients,
          }),
        ],
      ),
      E(
        'div',
        {
          style:
            'display: flex; flex-direction: column; gap: 8px; max-height: 340px; overflow-y: auto;',
        },
        lanClients.map((client) => {
          const icon = getDeviceIcon(client.hostname);
          const isDirect = client.mode === 'direct';
          return E(
            'div',
            {
              class: 'cbi-section-node',
              style:
                'display: flex; justify-content: space-between; align-items: center; gap: 10px; padding: 8px 12px; border-radius: 6px; border: 1px solid var(--border-color, rgba(0,0,0,0.1)); background: var(--background-color-high, rgba(0,0,0,0.02)); flex-wrap: wrap;',
            },
            [
              E(
                'div',
                {
                  style: 'display: flex; align-items: center; gap: 8px;',
                },
                [
                  E('span', { style: 'font-size: 18px;' }, icon),
                  E('div', {}, [
                    E(
                      'div',
                      { style: 'font-weight: bold; font-size: 12px;' },
                      client.hostname,
                    ),
                    E(
                      'div',
                      { style: 'font-size: 11px; opacity: 0.75;' },
                      `${client.ip} (${client.mac})`,
                    ),
                  ]),
                ],
              ),
              E(
                'div',
                {
                  style: 'display: flex; align-items: center; gap: 8px;',
                },
                [
                  E(
                    'span',
                    {
                      class: `label ${isDirect ? 'label-warning' : 'label-success'}`,
                      style:
                        'font-size: 11px; padding: 3px 8px; border-radius: 4px;',
                    },
                    isDirect
                      ? '🌐 ' + _('Direct WAN')
                      : '🛡️ ' + _('Proxy / DPI'),
                  ),
                  renderButton({
                    classNames: [
                      isDirect ? 'cbi-button-action' : 'cbi-button-apply',
                    ],
                    text: isDirect
                      ? '🛡️ ' + _('Route via Proxy')
                      : '⚡ ' + _('Direct Bypass'),
                    onClick: async () => {
                      showToast(
                        _('Updating device routing mode...'),
                        'success',
                      );
                      const res = await TachyonShellMethods.toggleClientBypass(
                        client.ip,
                      );
                      if (res && res.success && res.data) {
                        client.mode = res.data.mode;
                        showToast(
                          _('Device updated') + ': ' + client.hostname,
                          'success',
                        );
                        renderModalLayout();
                      } else {
                        showToast(_('Failed to update device'), 'error');
                      }
                    },
                  }),
                ],
              ),
            ],
          );
        }),
      ),
    ]);
  };

  const renderHistoryTabContent = () => {
    if (historyEntries.length === 0) {
      return E(
        'div',
        { class: 'alert-message info', style: 'margin: 0; padding: 12px;' },
        _('No diagnostic history available yet.'),
      );
    }

    return E(
      'div',
      {
        style:
          'display: flex; flex-direction: column; gap: 8px; max-height: 360px; overflow-y: auto;',
      },
      historyEntries.map((h, i) =>
        E(
          'div',
          {
            class: 'cbi-section-node',
            style:
              'padding: 10px; border-radius: 6px; border: 1px solid var(--border-color, rgba(0,0,0,0.1)); background: var(--background-color-high, rgba(0,0,0,0.02));',
          },
          [
            E(
              'div',
              {
                style:
                  'display: flex; justify-content: space-between; font-weight: bold; font-size: 11px; margin-bottom: 6px; opacity: 0.8;',
              },
              [
                E('span', {}, `#${historyEntries.length - i}`),
                E('span', {}, h.timestamp),
              ],
            ),
            E(
              'pre',
              {
                class: 'tachyon-partial-modal__content',
                style:
                  'margin: 0; white-space: pre-wrap; font-size: 11px; max-height: 120px; overflow-y: auto; padding: 8px; border-radius: 4px; background: rgba(0,0,0,0.05);',
              },
              h.report,
            ),
          ],
        ),
      ),
    );
  };

  const mainContainer = E(
    'div',
    {
      class: 'tachyon-partial-modal__body',
      style: 'width: 100%; box-sizing: border-box;',
    },
    [],
  );

  const uiObj = getUi();

  const renderModalLayout = () => {
    mainContainer.replaceChildren(
      E('div', {}, [
        E(
          'div',
          {
            style:
              'display: flex; gap: 8px; margin-bottom: 12px; border-bottom: 1px solid var(--border-color, rgba(0,0,0,0.1)); padding-bottom: 8px; flex-wrap: wrap;',
          },
          [
            renderButton({
              classNames: [
                activeTab === 'diagnosis'
                  ? 'cbi-button-action'
                  : 'cbi-button-neutral',
              ],
              text: '🔍 ' + _('Current Diagnosis'),
              onClick: () => {
                activeTab = 'diagnosis';
                renderModalLayout();
              },
            }),
            renderButton({
              classNames: [
                activeTab === 'devices'
                  ? 'cbi-button-action'
                  : 'cbi-button-neutral',
              ],
              text: `📱 ${_('LAN Devices')} ${lanClients.length > 0 ? `(${lanClients.length})` : ''}`,
              onClick: () => {
                activeTab = 'devices';
                if (lanClients.length === 0) {
                  void loadLanClients();
                } else {
                  renderModalLayout();
                }
              },
            }),
            renderButton({
              classNames: [
                activeTab === 'history'
                  ? 'cbi-button-action'
                  : 'cbi-button-neutral',
              ],
              text: `🕒 ${_('History')} (${historyEntries.length})`,
              onClick: () => {
                historyEntries = getAiDoctorHistory();
                activeTab = 'history';
                renderModalLayout();
              },
            }),
          ],
        ),
        activeTab === 'diagnosis'
          ? renderDiagnosisTabContent()
          : activeTab === 'devices'
            ? renderDevicesTabContent()
            : renderHistoryTabContent(),
        E(
          'div',
          {
            class: 'tachyon-partial-modal__footer',
            style:
              'margin-top: 15px; display: flex; justify-content: space-between; align-items: center; gap: 8px; flex-wrap: wrap;',
          },
          [
            E(
              'div',
              {
                style:
                  'display: flex; gap: 8px; flex-wrap: wrap; align-items: center;',
              },
              [
                renderButton({
                  classNames: ['cbi-button-action'],
                  text: '📋 ' + _('Copy Support Report'),
                  onClick: () => {
                    void copySupportReport();
                  },
                }),
                renderButton({
                  classNames: ['cbi-button-reset'],
                  text: '🚨 ' + _('Restore Native Internet (Stop Tachyon)'),
                  onClick: async () => {
                    showToast(
                      _(
                        'Restoring native direct internet (stopping Tachyon)...',
                      ),
                      'success',
                    );
                    const fixRes = await TachyonShellMethods.applyQuickFix(
                      'restore_native_internet',
                    );
                    if (
                      fixRes &&
                      typeof fixRes === 'object' &&
                      (fixRes as { success?: boolean }).success
                    ) {
                      showToast(
                        _('Native internet restored. Tachyon stopped.'),
                        'success',
                      );
                      uiObj?.hideModal();
                      if (options.onRefreshServices) {
                        await options.onRefreshServices();
                      }
                    } else {
                      showToast(
                        _('Failed to restore native internet'),
                        'error',
                      );
                    }
                  },
                }),
              ],
            ),
            renderButton({
              classNames: ['cbi-button-neutral'],
              text: _('Close'),
              onClick: () => uiObj?.hideModal(),
            }),
          ],
        ),
      ]),
    );
  };

  renderModalLayout();
  uiObj?.showModal(_('AI Doctor Diagnosis'), mainContainer);
}
