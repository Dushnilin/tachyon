/* eslint-disable @typescript-eslint/no-explicit-any */
import { renderButton } from '../../../../partials';
import {
  renderCircleCheckBigIcon24,
  renderRotateCcwIcon24,
} from '../../../../icons';
import { prettyBytes } from '../../../../helpers/prettyBytes';
import { showToast } from '../../../../helpers/showToast';
import {
  stabilityClient,
  StabilityReport,
} from '../../../services/stabilityClient';
import {
  serverStatsClient,
  ServerMetricEntry,
  ServerStatsSummary,
} from '../../../services/serverStatsClient';
import { renderFlagEmojis } from '../../dashboard/partials/renderFlagEmojis';

type StabilityModalTab = 'overview' | 'fleet' | 'incidents';

function getUi(): any {
  if (typeof ui !== 'undefined') return ui;
  if (typeof window !== 'undefined' && (window as any).ui)
    return (window as any).ui;
  if (typeof globalThis !== 'undefined' && (globalThis as any).ui)
    return (globalThis as any).ui;
  return null;
}

export async function renderStabilityModal(): Promise<void> {
  let activeTab: StabilityModalTab = 'overview';
  let reportData: StabilityReport | null = null;
  let summaryData: ServerStatsSummary | null = null;
  let bestServersData: ServerMetricEntry[] = [];
  let isProbingAll = false;
  let probingSingleTag: string | null = null;

  // Root container
  const modalContainer = E(
    'div',
    {
      class: 'tachyon_stability-modal',
      style:
        'max-width: 820px; width: 100%; box-sizing: border-box; padding: 4px; font-size: 13px;',
    },
    [],
  );

  const renderLoadingView = (message = _('Loading stability metrics...')) => {
    return E(
      'div',
      {
        style:
          'padding: 32px 16px; text-align: center; color: var(--text-color-medium, #666);',
      },
      [
        E(
          'div',
          {
            style: 'font-size: 18px; margin-bottom: 8px; font-weight: bold;',
          },
          '⏳',
        ),
        E('div', {}, message),
      ],
    );
  };

  const getScoreBadgeClass = (grade: string) => {
    switch (grade) {
      case 'optimal':
        return 'label-success';
      case 'healthy':
        return 'label-success';
      case 'degraded':
        return 'label-warning';
      case 'critical':
        return 'label-danger';
      default:
        return 'label-default';
    }
  };

  const getLatencyColor = (latencyMs: number) => {
    if (latencyMs <= 0) return 'var(--text-color-medium, #888)';
    if (latencyMs < 180) return '#2ea043';
    if (latencyMs < 350) return '#d29922';
    return '#f85149';
  };

  const updateModalContent = () => {
    modalContainer.innerHTML = '';

    if (!reportData) {
      modalContainer.appendChild(renderLoadingView());
      return;
    }

    // 1. Header Banner
    const score = reportData.health?.score ?? 100;
    const grade = reportData.health?.grade ?? 'optimal';
    const badgeClass = getScoreBadgeClass(grade);
    const systemUptime = reportData.uptimes?.system?.pretty ?? '—';
    const totalServers =
      summaryData?.total_servers ?? reportData.server_fleet?.total_servers ?? 0;
    const healthyServers =
      summaryData?.healthy_count ?? reportData.server_fleet?.healthy_count ?? 0;
    const avgLatency =
      summaryData?.avg_latency_ms ??
      reportData.server_fleet?.avg_latency_ms ??
      0;

    const header = E(
      'div',
      {
        class: 'cbi-section-node',
        style:
          'display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap; gap: 12px; padding: 12px 16px; margin-bottom: 12px; border-radius: 6px; background: var(--background-color-high, rgba(0,0,0,0.03)); border: 1px solid var(--border-color, rgba(0,0,0,0.1));',
      },
      [
        E('div', { style: 'display: flex; align-items: center; gap: 10px;' }, [
          E(
            'span',
            {
              class: `label ${badgeClass}`,
              style:
                'font-size: 15px; font-weight: bold; padding: 6px 12px; border-radius: 4px;',
            },
            `${score}% ${grade.toUpperCase()}`,
          ),
          E('div', {}, [
            E(
              'div',
              { style: 'font-weight: bold; font-size: 14px;' },
              _('System Stability Index'),
            ),
            E(
              'div',
              {
                style:
                  'font-size: 11px; color: var(--text-color-medium, #777);',
              },
              `${_('System uptime')}: ${systemUptime}`,
            ),
          ]),
        ]),
        E(
          'div',
          {
            style:
              'display: flex; gap: 14px; align-items: center; font-size: 12px;',
          },
          [
            E('div', { style: 'text-align: right;' }, [
              E(
                'div',
                { style: 'font-weight: bold;' },
                `${healthyServers} / ${totalServers} ${_('Nodes OK')}`,
              ),
              E(
                'div',
                {
                  style:
                    'font-size: 11px; color: var(--text-color-medium, #777);',
                },
                avgLatency > 0
                  ? `${_('Fleet Latency')}: ~${Math.round(avgLatency)} ms`
                  : _('Untested fleet'),
              ),
            ]),
          ],
        ),
      ],
    );

    // 2. Tab Navigation
    const tabsRow = E(
      'div',
      {
        style:
          'display: flex; gap: 8px; margin-bottom: 14px; border-bottom: 1px solid var(--border-color, rgba(128,128,128,0.2)); padding-bottom: 6px;',
      },
      [
        renderButton({
          classNames: [
            'btn',
            'cbi-button',
            activeTab === 'overview' ? 'cbi-button-action' : '',
          ],
          text: _('🏥 System Health & Daemons'),
          onClick: () => {
            activeTab = 'overview';
            updateModalContent();
          },
        }),
        renderButton({
          classNames: [
            'btn',
            'cbi-button',
            activeTab === 'fleet' ? 'cbi-button-action' : '',
          ],
          text: _('🌐 Server Fleet & Rankings'),
          onClick: () => {
            activeTab = 'fleet';
            updateModalContent();
          },
        }),
        renderButton({
          classNames: [
            'btn',
            'cbi-button',
            activeTab === 'incidents' ? 'cbi-button-action' : '',
          ],
          text: _('📜 Incidents & Timeline'),
          onClick: () => {
            activeTab = 'incidents';
            updateModalContent();
          },
        }),
      ],
    );

    // 3. Tab Content
    let tabContent: HTMLElement;
    if (activeTab === 'overview') {
      tabContent = renderOverviewTab();
    } else if (activeTab === 'fleet') {
      tabContent = renderFleetTab();
    } else {
      tabContent = renderIncidentsTab();
    }

    // 4. Modal Footer
    const footer = E(
      'div',
      {
        style:
          'display: flex; justify-content: space-between; align-items: center; padding-top: 14px; margin-top: 14px; border-top: 1px solid var(--border-color, rgba(128, 128, 128, 0.2));',
      },
      [
        renderButton({
          classNames: ['btn', 'cbi-button'],
          icon: renderRotateCcwIcon24,
          text: _('Refresh Report'),
          onClick: async () => {
            await fetchAllData();
          },
        }),
        renderButton({
          classNames: ['btn', 'cbi-button-apply'],
          text: _('Close'),
          onClick: () => {
            const uiObj = getUi();
            if (uiObj?.hideModal) {
              uiObj.hideModal();
            }
          },
        }),
      ],
    );

    modalContainer.appendChild(header);
    modalContainer.appendChild(tabsRow);
    modalContainer.appendChild(tabContent);
    modalContainer.appendChild(footer);
  };

  const renderOverviewTab = (): HTMLElement => {
    const daemons = reportData?.uptimes?.daemons ?? {};
    const flaps = reportData?.restarts_and_flaps ?? {
      wan_flaps: 0,
      watchdog_restarts: 0,
      engine_crashes: 0,
      dnsmasq_restarts: 0,
      dns_failovers: 0,
      config_rollbacks: 0,
    };
    const mem = reportData?.resources?.memory;
    const fds = reportData?.resources?.file_descriptors;
    const penalties = reportData?.health?.penalties ?? [];

    // Penalties Banner
    const penaltiesElement =
      penalties.length > 0
        ? E(
            'div',
            {
              class: 'alert-message warning',
              style: 'margin-bottom: 12px; font-size: 12px;',
            },
            [
              E('b', {}, _('Stability penalties detected on active system:')),
              E(
                'ul',
                { style: 'margin: 4px 0 0 16px; padding: 0;' },
                penalties.map((p) => E('li', {}, p)),
              ),
            ],
          )
        : E(
            'div',
            {
              class: 'alert-message notice',
              style:
                'margin-bottom: 12px; font-size: 12px; color: #2ea043; border-color: rgba(46,160,67,0.3); background: rgba(46,160,67,0.06);',
            },
            [
              E(
                'span',
                {},
                '✓ ' +
                  _(
                    'All system invariants satisfied. No flaps, memory leaks, or crashes detected.',
                  ),
              ),
            ],
          );

    // Daemons Table
    const daemonRows = Object.keys(daemons).map((daemonName) => {
      const info = daemons[daemonName];
      const isRunning = info.running;
      const pidStr = info.pid ? String(info.pid) : '—';
      const uptimeStr = info.pretty || (isRunning ? 'running' : 'stopped');
      const rssKb = mem?.daemons_rss_kb?.[daemonName];
      const rssStr = rssKb ? prettyBytes(rssKb * 1024) : '—';
      const daemonFd = fds?.daemons?.[daemonName];
      const fdStr = daemonFd !== undefined ? String(daemonFd) : '—';

      return E('tr', { class: 'cbi-section-table-row' }, [
        E(
          'td',
          { class: 'cbi-section-table-cell', style: 'font-weight: 500;' },
          daemonName,
        ),
        E('td', { class: 'cbi-section-table-cell' }, [
          E(
            'span',
            {
              class: `label ${isRunning ? 'label-success' : 'label-default'}`,
              style: 'font-size: 11px; padding: 2px 6px;',
            },
            isRunning ? _('Running') : _('Stopped'),
          ),
        ]),
        E(
          'td',
          {
            class: 'cbi-section-table-cell',
            style: 'font-family: monospace;',
          },
          pidStr,
        ),
        E('td', { class: 'cbi-section-table-cell' }, uptimeStr),
        E('td', { class: 'cbi-section-table-cell' }, rssStr),
        E('td', { class: 'cbi-section-table-cell' }, fdStr),
      ]);
    });

    const daemonsTable = E('div', { class: 'cbi-section' }, [
      E(
        'div',
        {
          class: 'cbi-section-title',
          style: 'font-size: 13px; font-weight: bold; margin-bottom: 6px;',
        },
        _('Managed Daemons Status'),
      ),
      E(
        'table',
        {
          class: 'cbi-section-table',
          style: 'width: 100%; border-collapse: collapse;',
        },
        [
          E('tr', { class: 'cbi-section-table-titles' }, [
            E('th', { class: 'cbi-section-table-cell' }, _('Service')),
            E('th', { class: 'cbi-section-table-cell' }, _('State')),
            E('th', { class: 'cbi-section-table-cell' }, _('PID')),
            E('th', { class: 'cbi-section-table-cell' }, _('Uptime')),
            E('th', { class: 'cbi-section-table-cell' }, _('RAM (RSS)')),
            E('th', { class: 'cbi-section-table-cell' }, _('FDs')),
          ]),
          ...daemonRows,
        ],
      ),
    ]);

    // Flaps & Resources Grid
    const memoryUsedPct = mem?.used_pct ?? 0;
    const memoryTotalStr = mem?.total_kb
      ? prettyBytes(mem.total_kb * 1024)
      : '—';
    const memoryFreeStr = mem?.available_kb
      ? prettyBytes(mem.available_kb * 1024)
      : '—';

    const flapsAndMetrics = E(
      'div',
      {
        style:
          'display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 10px; margin-top: 14px;',
      },
      [
        // Flaps Card
        E(
          'div',
          {
            class: 'cbi-section-node',
            style:
              'padding: 10px 14px; border-radius: 6px; border: 1px solid var(--border-color, rgba(0,0,0,0.1));',
          },
          [
            E(
              'div',
              {
                style:
                  'font-weight: bold; margin-bottom: 6px; font-size: 12px;',
              },
              _('Failovers & Restarts'),
            ),
            E(
              'div',
              {
                style:
                  'display: flex; justify-content: space-between; font-size: 12px; margin-bottom: 2px;',
              },
              [
                E('span', {}, _('Watchdog recoveries:')),
                E(
                  'b',
                  {
                    style: flaps.watchdog_restarts > 0 ? 'color: #d29922;' : '',
                  },
                  String(flaps.watchdog_restarts),
                ),
              ],
            ),
            E(
              'div',
              {
                style:
                  'display: flex; justify-content: space-between; font-size: 12px; margin-bottom: 2px;',
              },
              [
                E('span', {}, _('Engine crashes:')),
                E(
                  'b',
                  {
                    style: flaps.engine_crashes > 0 ? 'color: #f85149;' : '',
                  },
                  String(flaps.engine_crashes),
                ),
              ],
            ),
            E(
              'div',
              {
                style:
                  'display: flex; justify-content: space-between; font-size: 12px; margin-bottom: 2px;',
              },
              [
                E('span', {}, _('DNS failovers:')),
                E('b', {}, String(flaps.dns_failovers)),
              ],
            ),
            E(
              'div',
              {
                style:
                  'display: flex; justify-content: space-between; font-size: 12px; margin-bottom: 2px;',
              },
              [
                E('span', {}, _('WAN network flaps:')),
                E('b', {}, String(flaps.wan_flaps)),
              ],
            ),
            E(
              'div',
              {
                style:
                  'display: flex; justify-content: space-between; font-size: 12px;',
              },
              [
                E('span', {}, _('Config rollbacks:')),
                E('b', {}, String(flaps.config_rollbacks)),
              ],
            ),
          ],
        ),

        // Memory Pressure Card
        E(
          'div',
          {
            class: 'cbi-section-node',
            style:
              'padding: 10px 14px; border-radius: 6px; border: 1px solid var(--border-color, rgba(0,0,0,0.1));',
          },
          [
            E(
              'div',
              {
                style:
                  'font-weight: bold; margin-bottom: 6px; font-size: 12px;',
              },
              _('RAM & Resource Pressure'),
            ),
            E(
              'div',
              {
                style:
                  'display: flex; justify-content: space-between; font-size: 12px; margin-bottom: 4px;',
              },
              [
                E('span', {}, _('RAM usage:')),
                E('b', {}, `${memoryUsedPct}% (${memoryTotalStr} total)`),
              ],
            ),
            E(
              'div',
              {
                style:
                  'width: 100%; height: 6px; background: rgba(0,0,0,0.1); border-radius: 3px; overflow: hidden; margin-bottom: 8px;',
              },
              [
                E('div', {
                  style: `width: ${Math.min(100, Math.max(0, memoryUsedPct))}%; height: 100%; background: ${memoryUsedPct > 85 ? '#f85149' : memoryUsedPct > 65 ? '#d29922' : '#2ea043'};`,
                }),
              ],
            ),
            E(
              'div',
              {
                style:
                  'display: flex; justify-content: space-between; font-size: 12px; margin-bottom: 2px;',
              },
              [
                E('span', {}, _('Available memory:')),
                E('span', {}, memoryFreeStr),
              ],
            ),
            E(
              'div',
              {
                style:
                  'display: flex; justify-content: space-between; font-size: 12px;',
              },
              [
                E('span', {}, _('System FDs allocated:')),
                E(
                  'span',
                  {},
                  `${fds?.system_allocated ?? '—'} / ${fds?.system_max ?? '—'}`,
                ),
              ],
            ),
          ],
        ),
      ],
    );

    return E('div', {}, [penaltiesElement, daemonsTable, flapsAndMetrics]);
  };

  const renderFleetTab = (): HTMLElement => {
    const total = summaryData?.total_servers ?? 0;
    const healthy = summaryData?.healthy_count ?? 0;
    const untested = summaryData?.untested_count ?? 0;
    const unhealthy = summaryData?.unhealthy_count ?? 0;

    // Controls Row
    const controls = E(
      'div',
      {
        style:
          'display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap; gap: 8px; margin-bottom: 12px;',
      },
      [
        E(
          'div',
          { style: 'font-size: 12px; color: var(--text-color-medium, #666);' },
          `${_('Total servers')}: ${total} • ${_('Healthy')}: ${healthy} • ${_('Untested')}: ${untested} • ${_('Degraded')}: ${unhealthy}`,
        ),
        E('div', { style: 'display: flex; gap: 8px;' }, [
          renderButton({
            classNames: ['btn', 'cbi-button-action'],
            icon: renderCircleCheckBigIcon24,
            text: isProbingAll ? _('Probing all...') : _('Probe All Servers'),
            loading: isProbingAll,
            disabled: isProbingAll,
            onClick: async () => {
              isProbingAll = true;
              updateModalContent();
              try {
                const res = await serverStatsClient.probeAll('all', 3000);
                if (res) {
                  showToast(
                    _('Probed') +
                      ` ${res.total_probed} ` +
                      _('servers') +
                      `: ${res.successful} ` +
                      _('online') +
                      `, ${res.failed} ` +
                      _('failed'),
                    'success',
                  );
                }
              } catch (_err) {
                showToast(_('Server probe failed'), 'error');
              } finally {
                isProbingAll = false;
                await fetchAllData();
              }
            },
          }),
          renderButton({
            classNames: ['btn', 'cbi-button-reset'],
            text: _('Reset Stats'),
            onClick: async () => {
              const ok = await serverStatsClient.reset();
              if (ok) {
                showToast(_('Server stats reset successfully'), 'success');
                await fetchAllData();
              }
            },
          }),
        ]),
      ],
    );

    // Candidates Table
    const serverRows = bestServersData.map((server, index) => {
      const isProbingThis = probingSingleTag === server.tag;
      const latencyMs = server.last_latency || server.avg_latency || 0;
      const latencyColor = getLatencyColor(latencyMs);
      const flagAndName = renderFlagEmojis(server.name || server.tag);

      return E('tr', { class: 'cbi-section-table-row' }, [
        E(
          'td',
          {
            class: 'cbi-section-table-cell',
            style: 'font-weight: bold; width: 36px;',
          },
          `#${index + 1}`,
        ),
        E('td', { class: 'cbi-section-table-cell' }, flagAndName),
        E(
          'td',
          {
            class: 'cbi-section-table-cell',
            style: 'font-size: 11px; color: var(--text-color-medium, #777);',
          },
          server.section,
        ),
        E(
          'td',
          {
            class: 'cbi-section-table-cell',
            style: 'font-size: 11px; font-weight: bold;',
          },
          server.type,
        ),
        E(
          'td',
          {
            class: 'cbi-section-table-cell',
            style: `font-weight: bold; color: ${latencyColor};`,
          },
          latencyMs > 0 ? `${latencyMs} ms` : '—',
        ),
        E(
          'td',
          { class: 'cbi-section-table-cell', style: 'font-size: 11px;' },
          server.jitter > 0 ? `±${server.jitter} ms` : '0 ms',
        ),
        E('td', { class: 'cbi-section-table-cell' }, `${server.success_rate}%`),
        E('td', { class: 'cbi-section-table-cell' }, [
          renderButton({
            classNames: ['btn', 'cbi-button'],
            text: isProbingThis ? '...' : _('Probe'),
            loading: isProbingThis,
            disabled: isProbingThis || isProbingAll,
            onClick: async () => {
              probingSingleTag = server.tag;
              updateModalContent();
              try {
                const probeRes = await serverStatsClient.probe(
                  server.tag,
                  3000,
                );
                if (probeRes?.status === 'ok') {
                  showToast(
                    `${server.name}: ${probeRes.latency_ms} ms (${_('online')})`,
                    'success',
                  );
                } else {
                  showToast(
                    `${server.name}: ${_('failed')} (${probeRes?.error || 'timeout'})`,
                    'error',
                  );
                }
              } finally {
                probingSingleTag = null;
                await fetchAllData();
              }
            },
          }),
        ]),
      ]);
    });

    const emptyNotice =
      bestServersData.length === 0
        ? E(
            'div',
            {
              class: 'alert-message notice',
              style: 'text-align: center; margin-top: 12px;',
            },
            _(
              'No tested servers recorded yet. Click "Probe All Servers" to evaluate node latency and reliability.',
            ),
          )
        : null;

    const table = E(
      'table',
      {
        class: 'cbi-section-table',
        style: 'width: 100%; border-collapse: collapse;',
      },
      [
        E('tr', { class: 'cbi-section-table-titles' }, [
          E('th', { class: 'cbi-section-table-cell' }, _('Rank')),
          E('th', { class: 'cbi-section-table-cell' }, _('Server Name')),
          E('th', { class: 'cbi-section-table-cell' }, _('Section')),
          E('th', { class: 'cbi-section-table-cell' }, _('Type')),
          E('th', { class: 'cbi-section-table-cell' }, _('Latency')),
          E('th', { class: 'cbi-section-table-cell' }, _('Jitter')),
          E('th', { class: 'cbi-section-table-cell' }, _('Success')),
          E('th', { class: 'cbi-section-table-cell' }, _('Action')),
        ]),
        ...serverRows,
      ],
    );

    return E(
      'div',
      {},
      emptyNotice ? [controls, table, emptyNotice] : [controls, table],
    );
  };

  const renderIncidentsTab = (): HTMLElement => {
    const incidents = reportData?.recent_incidents ?? [];

    if (incidents.length === 0) {
      return E(
        'div',
        {
          class: 'alert-message notice',
          style: 'text-align: center; padding: 24px;',
        },
        [
          E('div', { style: 'font-size: 16px; margin-bottom: 4px;' }, '✓'),
          E(
            'b',
            {},
            _('No critical incidents or crashes recorded in the journal.'),
          ),
          E(
            'div',
            {
              style:
                'font-size: 11px; color: var(--text-color-medium, #777); margin-top: 4px;',
            },
            _(
              'Event bus journal and syslog monitoring report clean operation.',
            ),
          ),
        ],
      );
    }

    const rows = incidents.map((inc) => {
      const timeStr = new Date(inc.time * 1000).toLocaleTimeString();
      const badgeClass =
        inc.severity === 'error'
          ? 'label-danger'
          : inc.severity === 'warn'
            ? 'label-warning'
            : 'label-info';

      return E('tr', { class: 'cbi-section-table-row' }, [
        E(
          'td',
          {
            class: 'cbi-section-table-cell',
            style: 'font-family: monospace; font-size: 11px;',
          },
          timeStr,
        ),
        E('td', { class: 'cbi-section-table-cell' }, [
          E(
            'span',
            {
              class: `label ${badgeClass}`,
              style: 'font-size: 10px; padding: 1px 5px;',
            },
            inc.severity.toUpperCase(),
          ),
        ]),
        E(
          'td',
          { class: 'cbi-section-table-cell', style: 'font-weight: 500;' },
          inc.source,
        ),
        E('td', { class: 'cbi-section-table-cell' }, inc.message || inc.title),
      ]);
    });

    return E('div', { class: 'cbi-section' }, [
      E(
        'table',
        {
          class: 'cbi-section-table',
          style: 'width: 100%; border-collapse: collapse;',
        },
        [
          E('tr', { class: 'cbi-section-table-titles' }, [
            E('th', { class: 'cbi-section-table-cell' }, _('Time')),
            E('th', { class: 'cbi-section-table-cell' }, _('Severity')),
            E('th', { class: 'cbi-section-table-cell' }, _('Source')),
            E('th', { class: 'cbi-section-table-cell' }, _('Message')),
          ]),
          ...rows,
        ],
      ),
    ]);
  };

  const fetchAllData = async () => {
    updateModalContent();
    try {
      const [rep, sum, best] = await Promise.all([
        stabilityClient.getReport(),
        serverStatsClient.getSummary(),
        serverStatsClient.getBestCandidates('all', 15),
      ]);
      reportData = rep;
      summaryData = sum;
      bestServersData = best;
    } catch (_err) {
      showToast(_('Failed to fetch stability report'), 'error');
    } finally {
      updateModalContent();
    }
  };

  // Show modal immediately with loading indicator
  modalContainer.appendChild(renderLoadingView());
  const uiObj = getUi();
  if (uiObj?.showModal) {
    uiObj.showModal(
      `📊 ${_('System Stability & Server Fleet Report')}`,
      modalContainer,
    );
  }

  // Fetch initial data
  await fetchAllData();
}
