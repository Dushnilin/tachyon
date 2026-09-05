import { TachyonShellMethods } from '../../../methods/shell';
import { renderButton } from '../../../../partials';
import { Tachyon } from '../../../types';

export function renderDnsBenchmarkModal() {
  let pollInterval: number | null = null;
  let isRunning = false;

  const progressBar = E('div', {
    style:
      'width: 0%; height: 6px; background: linear-gradient(90deg, #007bff, #28a745); border-radius: 3px; transition: width 0.3s ease;',
  });

  const progressContainer = E(
    'div',
    {
      style:
        'width: 100%; height: 6px; background: rgba(255,255,255,0.1); border-radius: 3px; overflow: hidden; margin-bottom: 12px; display: none;',
    },
    [progressBar],
  );

  const statusLabel = E(
    'div',
    {
      style:
        'font-size: 13px; font-weight: 500; margin-bottom: 10px; color: var(--text-color-medium, #6c757d);',
    },
    _('Ready to benchmark DNS providers'),
  );

  const resultsTbody = E('tbody', {});

  const resultsTable = E(
    'table',
    {
      class: 'table cbi-section-table',
      style: 'width: 100%; font-size: 12px; margin-bottom: 16px;',
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
        'max-height: 280px; overflow-y: auto; border: 1px solid var(--border-color, rgba(255,255,255,0.1)); border-radius: 6px; margin-bottom: 16px;',
    },
    [resultsTable],
  );

  const recommendationContainer = E('div', {
    style:
      'display: none; padding: 12px; background: var(--background-color-secondary, rgba(0,0,0,0.25)); border: 1px solid var(--border-color, #28a745); border-radius: 8px; margin-bottom: 16px;',
  });

  const getRatingBadge = (status: string, latency: number) => {
    let color = '#6c757d';
    let text = status.toUpperCase();
    if (status === 'excellent') {
      color = '#28a745';
      text = _('EXCELLENT');
    } else if (status === 'good') {
      color = '#17a2b8';
      text = _('GOOD');
    } else if (status === 'fair') {
      color = '#ffc107';
      text = _('FAIR');
    } else if (status === 'slow') {
      color = '#fd7e14';
      text = _('SLOW');
    } else if (status === 'failed' || latency < 0) {
      color = '#dc3545';
      text = _('FAILED');
    }

    return E(
      'span',
      {
        style: `display: inline-block; padding: 2px 8px; border-radius: 10px; font-size: 11px; font-weight: 600; background: ${color}; color: #fff;`,
      },
      text,
    );
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
              style: 'text-align: center; opacity: 0.6; padding: 20px;',
            },
            _('No benchmark data yet. Click "Start Benchmark" to begin.'),
          ),
        ]),
      );
      return;
    }

    results.forEach((r) => {
      const latText = r.latency >= 0 ? `${r.latency} ms` : _('Timeout');
      let latColor = 'inherit';
      if (r.latency >= 0 && r.latency < 40) latColor = '#28a745';
      else if (r.latency >= 40 && r.latency < 80) latColor = '#17a2b8';
      else if (r.latency >= 80 && r.latency < 150) latColor = '#ffc107';
      else if (r.latency >= 150 || r.latency < 0) latColor = '#dc3545';

      const row = E('tr', { class: 'tr cbi-section-table-row' }, [
        E('td', { class: 'td', style: 'font-weight: 600;' }, [
          E('span', {}, r.provider),
          r.tag
            ? E(
                'small',
                {
                  style: 'opacity: 0.7; margin-left: 6px; font-weight: normal;',
                },
                `(${r.tag})`,
              )
            : '',
        ]),
        E('td', { class: 'td' }, [
          E(
            'span',
            {
              style: `display: inline-block; padding: 1px 6px; border-radius: 4px; font-size: 10px; font-weight: 600; text-transform: uppercase; background: ${
                r.type === 'doh' ? '#6f42c1' : '#007bff'
              }; color: #fff;`,
            },
            r.type.toUpperCase(),
          ),
        ]),
        E(
          'td',
          {
            class: 'td',
            style:
              'font-family: monospace; font-size: 11px; max-width: 200px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;',
            title: r.address,
          },
          r.address,
        ),
        E(
          'td',
          {
            class: 'td',
            style: `text-align: right; font-weight: 600; color: ${latColor};`,
          },
          latText,
        ),
        E(
          'td',
          { class: 'td', style: 'text-align: center; opacity: 0.85;' },
          `${r.lossPct}%`,
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
            'font-size: 14px; font-weight: 600; color: #28a745; margin-bottom: 8px; display: flex; align-items: center; gap: 6px;',
        },
        [
          E('span', {}, '⚡'),
          E('span', {}, _('Recommended DNS Configuration')),
        ],
      ),
      E(
        'div',
        {
          style:
            'display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 8px; font-size: 12px; margin-bottom: 8px;',
        },
        [
          E('div', {}, [
            E('strong', {}, _('DNS Protocol') + ': '),
            E(
              'span',
              {
                style:
                  'padding: 1px 6px; border-radius: 4px; font-size: 11px; font-weight: 600; background: #007bff; color: #fff;',
              },
              rec.dns_type.toUpperCase(),
            ),
          ]),
          E('div', {}, [
            E('strong', {}, _('Upstream Mode') + ': '),
            E(
              'span',
              { style: 'font-family: monospace;' },
              rec.dns_upstream_mode,
            ),
          ]),
          E('div', {}, [
            E('strong', {}, _('Primary DNS') + ': '),
            E(
              'span',
              { style: 'font-family: monospace;' },
              rec.dns_server.join(', '),
            ),
          ]),
          E('div', {}, [
            E('strong', {}, _('Bootstrap DNS') + ': '),
            E(
              'span',
              { style: 'font-family: monospace;' },
              rec.bootstrap_dns_server.join(', '),
            ),
          ]),
          E('div', {}, [
            E('strong', {}, _('Fallback DNS') + ': '),
            E(
              'span',
              { style: 'font-family: monospace;' },
              rec.dns_fallback_server.join(', '),
            ),
          ]),
        ],
      ),
      rec.reason
        ? E(
            'div',
            {
              style:
                'font-size: 11px; opacity: 0.8; font-style: italic; margin-top: 4px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 4px;',
            },
            `💡 ${rec.reason}`,
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
    text: `🚀 ${_('Apply Recommended DNS')}`,
    classNames: ['cbi-button-positive'],
    disabled: true,
    onClick: () => applyRecommended(),
  });

  const closeBtn = renderButton({
    text: _('Close'),
    classNames: ['cbi-button-neutral'],
    onClick: () => {
      if (pollInterval) clearInterval(pollInterval);
      if (isRunning) TachyonShellMethods.stopDnsBenchmark();
      if (ui.hideModal) ui.hideModal();
    },
  });

  const pollStatus = async () => {
    const res = await TachyonShellMethods.getDnsBenchmarkStatus();
    if (!res.success || !res.data) return;

    const data = res.data;
    isRunning = data.running;

    if (data.running) {
      progressContainer.style.display = 'block';
      progressBar.style.width = `${data.progress}%`;
      statusLabel.textContent = `⏳ ${data.current_server || _('Testing')} (${data.progress}%)`;
      if (startBtn) (startBtn as HTMLButtonElement).disabled = true;
      if (applyBtn) (applyBtn as HTMLButtonElement).disabled = true;
    } else {
      progressContainer.style.display = 'none';
      if (data.finished_at) {
        statusLabel.textContent = `✓ ${_('Benchmark completed successfully')}`;
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
  };

  const startBenchmark = async () => {
    statusLabel.textContent = `🚀 ${_('Starting DNS benchmark...')}`;
    progressContainer.style.display = 'block';
    progressBar.style.width = '0%';
    if (startBtn) (startBtn as HTMLButtonElement).disabled = true;
    if (applyBtn) (applyBtn as HTMLButtonElement).disabled = true;

    const res = await TachyonShellMethods.startDnsBenchmark();
    if (!res.success) {
      statusLabel.textContent = `✗ ${res.error || _('Failed to start benchmark')}`;
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
      applyBtn.textContent = `⏳ ${_('Applying...')}`;
    }

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
      window.location.reload();
    } else {
      ui.addNotification(
        _('Tachyon'),
        E('p', {}, res.error || _('Failed to apply DNS settings')),
        'error',
      );
      if (applyBtn) {
        (applyBtn as HTMLButtonElement).disabled = false;
        applyBtn.textContent = `🚀 ${_('Apply Recommended DNS')}`;
      }
    }
  };

  const modalContent = E('div', { style: 'padding: 8px;' }, [
    E(
      'p',
      { style: 'font-size: 13px; opacity: 0.85; margin-bottom: 12px;' },
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
        style:
          'display: flex; justify-content: flex-end; gap: 8px; margin-top: 16px; border-top: 1px solid var(--border-color, rgba(255,255,255,0.1)); padding-top: 12px;',
      },
      [startBtn, applyBtn, closeBtn],
    ),
  ]);

  ui.showModal(`⚡ ${_('Tachyon DNS Benchmark & Auto-Tuning')}`, modalContent);

  // Automatically start probe when modal opens
  startBenchmark();
}
