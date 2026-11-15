import { TachyonShellMethods } from '../../../methods/shell';
import { renderButton } from '../../../../partials';
import {
  renderZapIcon,
  renderLightbulbIcon,
  renderHourglassIcon,
  renderCheckIcon,
  renderXIcon,
} from '../../../../icons';
import { Tachyon } from '../../../types';

export function renderDnsBenchmarkModal() {
  let pollInterval: number | null = null;
  let isRunning = false;

  const progressBar = E('div', {
    class: 'progress-fill',
    style: 'width: 0%;',
  });

  const progressContainer = E(
    'div',
    {
      class: 'progress',
      style: 'margin-bottom: 12px; display: none;',
    },
    [progressBar],
  );

  const statusLabel = E(
    'div',
    {
      style:
        'font-size: 13px; font-weight: 500; margin-bottom: 10px; color: var(--text2, #a1a1a6); display: flex; align-items: center; gap: 6px;',
    },
    _('Ready to benchmark DNS providers'),
  );

  const resultsTbody = E('tbody', {});

  const resultsTable = E(
    'table',
    {
      class: 'table cbi-section-table',
      style: 'width: 100%; font-size: 13px; margin-bottom: 0;',
    },
    [
      E('thead', {}, [
        E('tr', { class: 'tr cbi-section-table-titles' }, [
          E('th', { class: 'th' }, _('Provider')),
          E('th', { class: 'th' }, _('Protocol')),
          E('th', { class: 'th' }, _('Address')),
          E('th', { class: 'th', style: 'text-align: right;' }, _('Latency')),
          E('th', { class: 'th', style: 'text-align: center;' }, _('Loss')),
          E('th', { class: 'th', style: 'text-align: center;' }, _('Rating')),
        ]),
      ]),
      resultsTbody,
    ],
  );

  const tableContainer = E(
    'div',
    {
      style:
        'max-height: 280px; overflow-y: auto; background: var(--bg, #0d0e12); border: 1px solid var(--border, rgba(255,255,255,0.08)); border-radius: var(--r-btn, 8px); margin-bottom: 14px;',
    },
    [resultsTable],
  );

  const recommendationContainer = E('div', {
    class: 'card',
    style:
      'display: none; padding: 14px 16px; background: var(--bg, #0d0e12); border: 1px solid rgba(48, 209, 88, 0.35); border-radius: var(--r-card, 12px); margin-bottom: 14px;',
  });

  const getRatingBadge = (status: string, latency: number) => {
    const normalized = String(
      status || (latency >= 0 && latency < 40 ? 'excellent' : 'good'),
    ).toLowerCase();
    let badgeClass = 'badge badge-off';
    let text = normalized.toUpperCase();
    if (normalized === 'excellent') {
      badgeClass = 'badge badge-on';
      text = _('EXCELLENT');
    } else if (normalized === 'good') {
      badgeClass = 'badge badge-proto';
      text = _('GOOD');
    } else if (normalized === 'fair' || normalized === 'slow') {
      badgeClass = 'badge badge-warn';
      text = normalized === 'fair' ? _('FAIR') : _('SLOW');
    } else if (normalized === 'failed' || latency < 0) {
      badgeClass = 'badge badge-danger';
      text = _('FAILED');
    }

    return E('span', { class: badgeClass }, text);
  };

  const updateTable = (results: Tachyon.DnsBenchmarkServerResult[]) => {
    resultsTbody.innerHTML = '';
    if (!results || results.length === 0) {
      resultsTbody.appendChild(
        E('tr', {}, [
          E(
            'td',
            {
              colSpan: 6,
              style:
                'text-align: center; color: var(--text3, #6e6e73); padding: 20px;',
            },
            _('No benchmark data yet. Click "Start Benchmark" to begin.'),
          ),
        ]),
      );
      return;
    }

    results.forEach((r) => {
      const latText = r.latency >= 0 ? `${r.latency} ms` : _('Timeout');
      let latColor = 'var(--text, #f5f5f7)';
      if (r.latency >= 0 && r.latency < 50) latColor = 'var(--ok, #30d158)';
      else if (r.latency >= 50 && r.latency < 120)
        latColor = 'var(--warn, #ff9f0a)';
      else if (r.latency >= 120 || r.latency < 0)
        latColor = 'var(--danger, #ff453a)';

      const row = E('tr', { class: 'tr cbi-section-table-row' }, [
        E('td', { class: 'td', style: 'font-weight: 600;' }, [
          E('span', {}, r.provider || r.id || 'DNS'),
          r.tag
            ? E(
                'small',
                {
                  style:
                    'color: var(--text3, #6e6e73); margin-left: 6px; font-weight: 400;',
                },
                `(${r.tag})`,
              )
            : '',
        ]),
        E('td', { class: 'td' }, [
          E(
            'span',
            {
              class: 'badge badge-proto',
            },
            String(r.type || 'udp').toUpperCase(),
          ),
        ]),
        E(
          'td',
          {
            class: 'td mono',
            style:
              'font-size: 12px; color: var(--text2, #a1a1a6); max-width: 220px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;',
            title: r.address,
          },
          r.address,
        ),
        E(
          'td',
          {
            class: 'td tabnum mono',
            style: `text-align: right; font-weight: 600; color: ${latColor};`,
          },
          latText,
        ),
        E(
          'td',
          {
            class: 'td tabnum',
            style: 'text-align: center; color: var(--text2, #a1a1a6);',
          },
          `${r.lossPct ?? 0}%`,
        ),
        E(
          'td',
          { class: 'td', style: 'text-align: center;' },
          getRatingBadge(r.status, r.latency),
        ),
      ]);
      resultsTbody.appendChild(row);
    });
  };

  const updateRecommendation = (
    rec: Tachyon.DnsBenchmarkRecommendation | null,
  ) => {
    if (!rec) {
      recommendationContainer.style.display = 'none';
      recommendationContainer.innerHTML = '';
      return;
    }

    recommendationContainer.style.display = 'block';
    recommendationContainer.innerHTML = '';

    const recContent = E('div', {}, [
      E(
        'div',
        {
          style:
            'font-size: 13px; font-weight: 600; color: var(--ok, #30d158); margin-bottom: 10px; display: flex; align-items: center; gap: 6px;',
        },
        [renderZapIcon(14), E('span', {}, _('Recommended DNS Configuration'))],
      ),
      E(
        'div',
        {
          style:
            'display: grid; grid-template-columns: repeat(auto-fit, minmax(210px, 1fr)); gap: 8px; font-size: 12px; margin-bottom: 8px;',
        },
        [
          E('div', {}, [
            E(
              'span',
              { style: 'color: var(--text3, #6e6e73); font-weight: 500;' },
              _('DNS Protocol') + ': ',
            ),
            E(
              'span',
              { class: 'badge badge-proto' },
              String(rec.dns_type || 'udp').toUpperCase(),
            ),
          ]),
          E('div', {}, [
            E(
              'span',
              { style: 'color: var(--text3, #6e6e73); font-weight: 500;' },
              _('Upstream Mode') + ': ',
            ),
            E('span', { class: 'mono' }, rec.dns_upstream_mode),
          ]),
          E('div', {}, [
            E(
              'span',
              { style: 'color: var(--text3, #6e6e73); font-weight: 500;' },
              _('Primary DNS') + ': ',
            ),
            E('span', { class: 'mono' }, (rec.dns_server || []).join(', ')),
          ]),
          E('div', {}, [
            E(
              'span',
              { style: 'color: var(--text3, #6e6e73); font-weight: 500;' },
              _('Bootstrap DNS') + ': ',
            ),
            E(
              'span',
              { class: 'mono' },
              (rec.bootstrap_dns_server || []).join(', '),
            ),
          ]),
          E('div', {}, [
            E(
              'span',
              { style: 'color: var(--text3, #6e6e73); font-weight: 500;' },
              _('Fallback DNS') + ': ',
            ),
            E(
              'span',
              { class: 'mono' },
              (rec.dns_fallback_server || []).join(', '),
            ),
          ]),
        ],
      ),
      rec.reason
        ? E(
            'div',
            {
              style:
                'font-size: 12px; color: var(--text2, #a1a1a6); margin-top: 6px; border-top: 1px solid var(--border, rgba(255,255,255,0.08)); padding-top: 6px; display: inline-flex; align-items: center; gap: 6px;',
            },
            [renderLightbulbIcon(12), E('span', {}, rec.reason)],
          )
        : '',
    ]);

    recommendationContainer.appendChild(recContent);
  };

  const startBtn = renderButton({
    text: _('Start Benchmark'),
    classNames: ['cbi-button-action'],
    onClick: () => startBenchmark(),
  });

  const applyBtn = renderButton({
    text: _('Apply Recommended DNS'),
    classNames: ['cbi-button-positive'],
    disabled: true,
    onClick: () => applyRecommended(),
  });

  let isPolling = false;
  let isDisposed = false;
  let hasMounted = false;

  const closeBtn = renderButton({
    text: _('Close'),
    classNames: ['cbi-button-neutral'],
    onClick: () => {
      isDisposed = true;
      if (pollInterval) {
        clearInterval(pollInterval);
        pollInterval = null;
      }
      if (isRunning) TachyonShellMethods.stopDnsBenchmark();
      if (ui.hideModal) ui.hideModal();
    },
  });

  const pollStatus = async () => {
    if (statusLabel.isConnected) {
      hasMounted = true;
    }
    if (isDisposed || (hasMounted && !statusLabel.isConnected)) {
      if (pollInterval) {
        clearInterval(pollInterval);
        pollInterval = null;
      }
      return;
    }
    if (isPolling) return;
    isPolling = true;
    try {
      const res = await TachyonShellMethods.getDnsBenchmarkStatus();
      if (isDisposed || (hasMounted && !statusLabel.isConnected)) {
        if (pollInterval) {
          clearInterval(pollInterval);
          pollInterval = null;
        }
        return;
      }
      if (!res.success || !res.data) return;

      const data = res.data;
      isRunning = data.running;

      if (data.running) {
        progressContainer.style.display = 'block';
        progressBar.style.width = `${data.progress}%`;
        statusLabel.replaceChildren(
          renderHourglassIcon(14),
          document.createTextNode(
            ` ${data.current_server || _('Testing')} (${data.progress}%)`,
          ),
        );
        if (startBtn) (startBtn as HTMLButtonElement).disabled = true;
        if (applyBtn) (applyBtn as HTMLButtonElement).disabled = true;
      } else {
        progressContainer.style.display = 'none';
        if (data.error) {
          statusLabel.replaceChildren(
            renderXIcon(14),
            document.createTextNode(` ${data.error}`),
          );
          if (startBtn) (startBtn as HTMLButtonElement).disabled = false;
          if (applyBtn)
            (applyBtn as HTMLButtonElement).disabled = !data.recommendation;
        } else if (data.finished_at) {
          statusLabel.replaceChildren(
            renderCheckIcon(14),
            document.createTextNode(
              ` ${_('Benchmark completed successfully')}`,
            ),
          );
          if (startBtn) (startBtn as HTMLButtonElement).disabled = false;
          if (applyBtn)
            (applyBtn as HTMLButtonElement).disabled = !data.recommendation;
        }
        if (pollInterval) {
          clearInterval(pollInterval);
          pollInterval = null;
        }
      }

      if (data.results && data.results.length > 0) {
        updateTable(data.results);
      }
      if (data.recommendation) {
        updateRecommendation(data.recommendation);
      }
    } finally {
      isPolling = false;
    }
  };

  const startBenchmark = async () => {
    statusLabel.replaceChildren(
      renderZapIcon(14),
      document.createTextNode(` ${_('Starting DNS benchmark...')}`),
    );
    progressContainer.style.display = 'block';
    progressBar.style.width = '0%';
    if (startBtn) (startBtn as HTMLButtonElement).disabled = true;
    if (applyBtn) (applyBtn as HTMLButtonElement).disabled = true;

    const res = await TachyonShellMethods.startDnsBenchmark();
    if (!res.success) {
      statusLabel.replaceChildren(
        renderXIcon(14),
        document.createTextNode(
          ` ${res.error || _('Failed to start benchmark')}`,
        ),
      );
      if (startBtn) (startBtn as HTMLButtonElement).disabled = false;
      progressContainer.style.display = 'none';
      return;
    }

    if (pollInterval) clearInterval(pollInterval);
    pollInterval = window.setInterval(pollStatus, 1000);
    pollStatus();
  };

  const applyRecommended = async () => {
    if (applyBtn) {
      (applyBtn as HTMLButtonElement).disabled = true;
      applyBtn.textContent = _('Applying...');
    }

    try {
      const res = await TachyonShellMethods.applyDnsBenchmark();
      if (res.success) {
        ui.addNotification(
          _('Tachyon'),
          E(
            'p',
            {},
            _(
              'Recommended DNS settings applied successfully and service restarted!',
            ),
          ),
          'info',
        );
        if (ui.hideModal) ui.hideModal();
        window.setTimeout(() => window.location.reload(), 600);
      } else {
        ui.addNotification(
          _('Tachyon'),
          E('p', {}, res.error || _('Failed to apply DNS settings')),
          'error',
        );
        if (applyBtn) {
          (applyBtn as HTMLButtonElement).disabled = false;
          applyBtn.textContent = _('Apply Recommended DNS');
        }
      }
    } catch (err) {
      ui.addNotification(
        _('Tachyon'),
        E(
          'p',
          {},
          (err as Error)?.message || _('Failed to apply DNS settings'),
        ),
        'error',
      );
      if (applyBtn) {
        (applyBtn as HTMLButtonElement).disabled = false;
        applyBtn.textContent = _('Apply Recommended DNS');
      }
    }
  };

  const modalContent = E('div', { style: 'padding: 2px 0 0 0;' }, [
    E(
      'p',
      {
        style:
          'font-size: 13px; color: var(--text2, #a1a1a6); line-height: 1.5; margin: 0 0 12px 0;',
      },
      _(
        'Benchmark measures actual latency and resolution reliability of major DNS servers (UDP 53 and encrypted DoH) directly from your router to find the fastest, unblocked upstream for your ISP.',
      ),
    ),
    statusLabel,
    progressContainer,
    tableContainer,
    recommendationContainer,
    E(
      'div',
      {
        class: 'button-row',
        style:
          'display: flex; justify-content: flex-end; gap: 8px; margin-top: 16px; border-top: 1px solid var(--border, rgba(255,255,255,0.08)); padding-top: 12px;',
      },
      [startBtn, applyBtn, closeBtn],
    ),
  ]);

  ui.showModal(_('Tachyon DNS Benchmark & Auto-Tuning'), modalContent);

  // Automatically start probe when modal opens
  startBenchmark();
}
