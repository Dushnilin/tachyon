import { TachyonShellMethods } from '../../../methods';
import { renderButton } from '../../../../partials';
import { showToast } from '../../../../helpers/showToast';
import { Tachyon } from '../../../types';

export function renderStrategyFuzzerModal(ruleNames: string[] = []) {
  let pollingInterval: ReturnType<typeof setInterval> | null = null;
  let isPolling = false;

  // Modal State
  let selectedEngine: Tachyon.FuzzerEngine = 'zapret2';
  let selectedTarget: Tachyon.FuzzerTarget = 'youtube';
  let customUrl = '';
  let selectedRuleSection = '';
  let isRunning = false;
  let currentState: Tachyon.FuzzerState | null = null;

  const modalContainer = E('div', {
    class: 'tachyon_fuzzer_modal',
    style:
      'display: flex; flex-direction: column; gap: 16px; width: 100%; max-width: 860px; box-sizing: border-box;',
  });

  // ── Header & Description ──────────────────────────────────────────────────
  const headerEl = E(
    'div',
    {
      style:
        'padding: 12px 16px; background: var(--background-color-secondary, rgba(0,0,0,0.25)); border: 1px solid var(--border-color, rgba(255,255,255,0.12)); border-radius: 8px;',
    },
    [
      E(
        'div',
        {
          style:
            'font-size: 15px; font-weight: bold; margin-bottom: 4px; display: flex; align-items: center; gap: 8px;',
        },
        [
          E('span', {}, '⚡'),
          E('span', {}, _('Automated DPI Strategy Fuzzer & Auto-Tuner')),
        ],
      ),
      E(
        'div',
        {
          style: 'font-size: 12px; opacity: 0.75; line-height: 1.4;',
        },
        _(
          'Benchmarks a suite of packet desynchronization strategies in an isolated sandbox without disrupting active traffic, ranking them by latency, TTFB, and throughput.',
        ),
      ),
    ],
  );

  // ── Configuration Controls ────────────────────────────────────────────────
  const controlsGrid = E('div', {
    style:
      'display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 12px; align-items: end;',
  });

  // 1. Engine Select
  const engineSelect = E(
    'select',
    { class: 'cbi-input-select', style: 'width: 100%;' },
    [
      E(
        'option',
        { value: 'zapret2', selected: true },
        _('Zapret v2 (nfqws2)'),
      ),
      E('option', { value: 'zapret' }, _('Zapret v1 (nfqws)')),
      E('option', { value: 'byedpi' }, _('ByeDPI (ciadpi)')),
      E('option', { value: 'all' }, _('All Engines (Full Matrix)')),
    ],
  );
  engineSelect.addEventListener('change', () => {
    selectedEngine = (engineSelect as HTMLSelectElement)
      .value as Tachyon.FuzzerEngine;
  });

  const engineGroup = E(
    'div',
    { style: 'display: flex; flex-direction: column; gap: 4px;' },
    [
      E(
        'label',
        { style: 'font-size: 12px; font-weight: 600;' },
        _('DPI Engine'),
      ),
      engineSelect,
    ],
  );

  // Dynamically query available engines and annotate options
  TachyonShellMethods.getFuzzerStrategies()
    .then((res) => {
      if (res.success && res.data?.available_engines) {
        const av = res.data.available_engines;
        const opts = (engineSelect as HTMLSelectElement).options;
        for (let i = 0; i < opts.length; i++) {
          const opt = opts[i];
          if (opt.value === 'zapret2') {
            opt.text = av.zapret2
              ? _('Zapret v2 (nfqws2)') + ' — ' + _('Installed')
              : _('Zapret v2 (nfqws2)') + ' — ' + _('Not installed');
            if (!av.zapret2) opt.disabled = true;
          } else if (opt.value === 'zapret') {
            opt.text = av.zapret
              ? _('Zapret v1 (nfqws)') + ' — ' + _('Installed')
              : _('Zapret v1 (nfqws)') + ' — ' + _('Not installed');
            if (!av.zapret) opt.disabled = true;
          } else if (opt.value === 'byedpi') {
            opt.text = av.byedpi
              ? _('ByeDPI (ciadpi)') + ' — ' + _('Installed')
              : _('ByeDPI (ciadpi)') + ' — ' + _('Not installed');
            if (!av.byedpi) opt.disabled = true;
          }
        }
        if (av.zapret2) {
          selectedEngine = 'zapret2';
          (engineSelect as HTMLSelectElement).value = 'zapret2';
        } else if (av.byedpi) {
          selectedEngine = 'byedpi';
          (engineSelect as HTMLSelectElement).value = 'byedpi';
        } else if (av.zapret) {
          selectedEngine = 'zapret';
          (engineSelect as HTMLSelectElement).value = 'zapret';
        }
      }
    })
    .catch(() => {});

  // 2. Target Preset Select
  const targetSelect = E(
    'select',
    { class: 'cbi-input-select', style: 'width: 100%;' },
    [
      E(
        'option',
        { value: 'youtube', selected: true },
        _('YouTube (GoogleVideo 4K stream)'),
      ),
      E('option', { value: 'youtube_web' }, _('YouTube Web (Interface)')),
      E('option', { value: 'discord' }, _('Discord (Gateway / API / Voice)')),
      E('option', { value: 'instagram' }, _('Instagram / Meta (TLS 1.3)')),
      E('option', { value: 'rutracker' }, _('RuTracker (HTTP/HTTPS)')),
      E('option', { value: 'telegram' }, _('Telegram Web')),
      E('option', { value: 'custom' }, _('Custom Target URL...')),
    ],
  );

  const customUrlInput = E('input', {
    type: 'text',
    class: 'cbi-input-text',
    placeholder: 'https://example.com',
    style: 'width: 100%; display: none; margin-top: 4px;',
  });

  targetSelect.addEventListener('change', () => {
    selectedTarget = (targetSelect as HTMLSelectElement)
      .value as Tachyon.FuzzerTarget;
    if (selectedTarget === 'custom') {
      (customUrlInput as HTMLElement).style.display = 'block';
    } else {
      (customUrlInput as HTMLElement).style.display = 'none';
    }
  });

  customUrlInput.addEventListener('input', () => {
    customUrl = (customUrlInput as HTMLInputElement).value.trim();
  });

  const targetGroup = E(
    'div',
    { style: 'display: flex; flex-direction: column; gap: 4px;' },
    [
      E(
        'label',
        { style: 'font-size: 12px; font-weight: 600;' },
        _('Target Service'),
      ),
      targetSelect,
      customUrlInput,
    ],
  );

  // 3. Rule / Apply Target Select
  const ruleSelectOptions = [
    E('option', { value: '', selected: true }, _('Provider Global Default')),
    ...ruleNames.map((r) => E('option', { value: r }, `${_('Rule:')} ${r}`)),
  ];
  const ruleSelect = E(
    'select',
    { class: 'cbi-input-select', style: 'width: 100%;' },
    ruleSelectOptions,
  );
  ruleSelect.addEventListener('change', () => {
    selectedRuleSection = (ruleSelect as HTMLSelectElement).value;
  });

  const ruleGroup = E(
    'div',
    { style: 'display: flex; flex-direction: column; gap: 4px;' },
    [
      E(
        'label',
        { style: 'font-size: 12px; font-weight: 600;' },
        _('Apply Strategy To'),
      ),
      ruleSelect,
    ],
  );

  let selectedMode: Tachyon.FuzzerMode = 'presets';

  const modeSelect = E(
    'select',
    { class: 'cbi-input-select', style: 'width: 100%;' },
    [
      E(
        'option',
        { value: 'presets', selected: true },
        _('⚡ Quick Benchmark (Presets ~12-14)'),
      ),
      E(
        'option',
        { value: 'combinatorial' },
        _('🔍 Combinatorial Deep Fuzzing (~40-60)'),
      ),
    ],
  );
  modeSelect.addEventListener('change', () => {
    selectedMode = (modeSelect as HTMLSelectElement)
      .value as Tachyon.FuzzerMode;
  });

  const modeGroup = E(
    'div',
    { style: 'display: flex; flex-direction: column; gap: 4px;' },
    [
      E(
        'label',
        { style: 'font-size: 12px; font-weight: 600;' },
        _('Search Mode'),
      ),
      modeSelect,
    ],
  );

  controlsGrid.append(engineGroup, targetGroup, ruleGroup, modeGroup);

  // ── AI Synthesizer Section ────────────────────────────────────────────────
  const aiPromptInput = E('input', {
    type: 'text',
    class: 'cbi-input-text',
    placeholder: _(
      'Optional notes for AI (e.g. "Rostelecom, YouTube 4K stream is slow")...',
    ),
    style: 'flex: 1 1 auto; font-size: 12px;',
  });

  const aiSynthesizeBtn = renderButton({
    text: _('🧠 Synthesize with AI'),
    classNames: ['cbi-button-action'],
    onClick: () => handleAiSynthesize(),
  });

  const aiAnalysisContainer = E(
    'div',
    {
      id: 'tachyon-fuzzer-ai-analysis',
      style:
        'display: none; padding: 10px 14px; background: rgba(0, 123, 255, 0.08); border-left: 3px solid #007bff; border-radius: 4px; font-size: 12px; line-height: 1.4;',
    },
    [
      E(
        'div',
        {
          style:
            'font-weight: bold; margin-bottom: 4px; display: flex; align-items: center; gap: 6px;',
        },
        [
          E('span', {}, '🧠'),
          E('span', {}, _('AI Diagnostics & Strategy Rationale')),
        ],
      ),
      E(
        'div',
        { id: 'tachyon-fuzzer-ai-analysis-text', style: 'opacity: 0.85;' },
        '',
      ),
    ],
  );

  const aiSynthesizerCard = E(
    'div',
    {
      style:
        'padding: 10px 14px; background: var(--background-color-secondary, rgba(0,0,0,0.15)); border: 1px dashed var(--border-color, rgba(255,255,255,0.15)); border-radius: 8px; display: flex; flex-direction: column; gap: 8px;',
    },
    [
      E(
        'div',
        {
          style:
            'font-size: 12px; font-weight: 600; display: flex; align-items: center; justify-content: space-between;',
        },
        [
          E(
            'span',
            {},
            '🧠 ' + _('AI DPI Engineer & Strategy Synthesizer (RAG-Powered)'),
          ),
          E(
            'span',
            { style: 'font-size: 10px; opacity: 0.6; font-weight: normal;' },
            _('Knowledge Base + Live Probe Context'),
          ),
        ],
      ),
      E('div', { style: 'display: flex; gap: 8px; align-items: center;' }, [
        aiPromptInput,
        aiSynthesizeBtn,
      ]),
      aiAnalysisContainer,
    ],
  );

  // ── Progress & Status Bar ─────────────────────────────────────────────────
  const progressContainer = E(
    'div',
    {
      style:
        'display: none; flex-direction: column; gap: 6px; padding: 12px; background: var(--background-color-secondary, rgba(0,0,0,0.18)); border-radius: 8px; border: 1px solid var(--border-color, rgba(255,255,255,0.1));',
    },
    [
      E(
        'div',
        {
          style:
            'display: flex; justify-content: space-between; font-size: 12px; font-weight: 600;',
        },
        [
          E(
            'span',
            { id: 'tachyon-fuzzer-status-text' },
            _('Benchmarking in progress...'),
          ),
          E('span', { id: 'tachyon-fuzzer-progress-pct' }, '0%'),
        ],
      ),
      E(
        'div',
        {
          style:
            'width: 100%; height: 8px; background: rgba(255,255,255,0.1); border-radius: 4px; overflow: hidden;',
        },
        [
          E('div', {
            id: 'tachyon-fuzzer-progress-bar',
            style:
              'height: 100%; width: 0%; background: linear-gradient(90deg, #007bff, #00d2ff); transition: width 0.3s ease;',
          }),
        ],
      ),
      E(
        'div',
        {
          id: 'tachyon-fuzzer-current-strategy',
          style: 'font-size: 11px; opacity: 0.7; font-family: monospace;',
        },
        '',
      ),
    ],
  );

  // ── Results Table ─────────────────────────────────────────────────────────
  const resultsContainer = E('div', {
    style:
      'max-height: 380px; overflow-y: auto; border: 1px solid var(--border-color, rgba(255,255,255,0.12)); border-radius: 8px;',
  });

  const tableEl = E(
    'table',
    {
      class: 'table',
      style:
        'width: 100%; margin: 0; font-size: 12px; text-align: left; border-collapse: collapse;',
    },
    [
      E(
        'thead',
        {
          style:
            'background: var(--background-color-secondary, rgba(0,0,0,0.3)); position: sticky; top: 0; z-index: 2;',
        },
        [
          E('tr', {}, [
            E('th', { style: 'padding: 8px 10px; width: 40px;' }, '#'),
            E('th', { style: 'padding: 8px 10px; width: 80px;' }, _('Engine')),
            E(
              'th',
              { style: 'padding: 8px 10px;' },
              _('Strategy & Parameters'),
            ),
            E('th', { style: 'padding: 8px 10px; width: 70px;' }, _('Status')),
            E('th', { style: 'padding: 8px 10px; width: 65px;' }, _('TTFB')),
            E('th', { style: 'padding: 8px 10px; width: 75px;' }, _('Speed')),
            E('th', { style: 'padding: 8px 10px; width: 90px;' }, _('Score')),
            E(
              'th',
              { style: 'padding: 8px 10px; width: 80px; text-align: center;' },
              _('Action'),
            ),
          ]),
        ],
      ),
      E('tbody', { id: 'tachyon-fuzzer-results-tbody' }, [
        E(
          'tr',
          {},
          E(
            'td',
            {
              colSpan: 8,
              style: 'padding: 24px; text-align: center; opacity: 0.6;',
            },
            _(
              'No benchmark results yet. Select engine and click "Start Benchmark" or "Synthesize with AI".',
            ),
          ),
        ),
      ]),
    ],
  );

  resultsContainer.appendChild(tableEl);

  // ── Action Buttons & Footer ───────────────────────────────────────────────
  const startBtn = renderButton({
    text: _('🚀 Start Benchmark'),
    classNames: ['cbi-button-action'],
    onClick: () => handleToggleRun(),
  });

  const applyBestBtn = renderButton({
    text: _('🏆 Apply Best Strategy'),
    classNames: ['cbi-button-save'],
    disabled: true,
    onClick: () => handleApplyBest(),
  });

  const closeBtn = renderButton({
    text: _('Close'),
    classNames: ['cbi-button-neutral'],
    onClick: () => {
      stopPolling();
      ui.hideModal();
    },
  });

  const footerActions = E(
    'div',
    {
      style:
        'display: flex; justify-content: space-between; align-items: center; padding-top: 8px; border-top: 1px solid var(--border-color, rgba(255,255,255,0.1));',
    },
    [
      E('div', { style: 'display: flex; gap: 8px;' }, [startBtn]),
      E('div', { style: 'display: flex; gap: 8px;' }, [applyBestBtn, closeBtn]),
    ],
  );

  // ── Render Helpers ────────────────────────────────────────────────────────
  const renderResults = (state: Tachyon.FuzzerState) => {
    const tbody = document.getElementById('tachyon-fuzzer-results-tbody');
    if (!tbody) return;

    if (!state.results || state.results.length === 0) {
      if (state.running) {
        tbody.innerHTML = `<tr><td colspan="8" style="padding: 20px; text-align: center;">${_(
          'Running initial strategy probe...',
        )}</td></tr>`;
      }
      return;
    }

    tbody.innerHTML = '';
    state.results.forEach((item, idx) => {
      const isBest = state.best_strategy && state.best_strategy.id === item.id;
      const statusBadge = item.success
        ? `<span class="badge" style="background: #28a745; color: #fff; padding: 2px 6px; border-radius: 4px; font-size: 10px;">${item.http_code || 200} OK</span>`
        : `<span class="badge" style="background: #dc3545; color: #fff; padding: 2px 6px; border-radius: 4px; font-size: 10px;">${item.error || 'Blocked'}</span>`;

      let badgeHtml = '';
      if (item.badge) {
        badgeHtml = `<span style="display: inline-block; font-size: 10px; font-weight: bold; color: #ffc107; margin-left: 6px;">${item.badge}</span>`;
      }

      const tr = E(
        'tr',
        {
          style: `border-bottom: 1px solid var(--border-color, rgba(255,255,255,0.06)); ${
            isBest
              ? 'background: rgba(40, 167, 69, 0.12); font-weight: 500;'
              : ''
          }`,
        },
        [
          E('td', { style: 'padding: 8px 10px;' }, String(idx + 1)),
          E(
            'td',
            {
              style:
                'padding: 8px 10px; font-family: monospace; font-size: 11px;',
            },
            item.engine,
          ),
          E('td', { style: 'padding: 8px 10px;' }, [
            E('div', { style: 'font-weight: 600;' }, [
              E('span', {}, item.name),
              E('span', { innerHTML: badgeHtml }),
            ]),
            E(
              'div',
              {
                style:
                  'font-size: 10px; opacity: 0.7; font-family: monospace; word-break: break-all; margin-top: 2px;',
              },
              item.args,
            ),
          ]),
          E('td', { style: 'padding: 8px 10px;', innerHTML: statusBadge }),
          E(
            'td',
            { style: 'padding: 8px 10px;' },
            item.success ? `${item.ttfb_ms}ms` : '—',
          ),
          E(
            'td',
            { style: 'padding: 8px 10px;' },
            item.success ? `${(item.speed_kbps / 1024).toFixed(1)}MB/s` : '—',
          ),
          E(
            'td',
            { style: 'padding: 8px 10px; font-weight: bold;' },
            item.success ? String(item.score) : '0',
          ),
          E('td', { style: 'padding: 8px 10px; text-align: center;' }, [
            renderButton({
              text: _('Apply'),
              classNames: ['cbi-button-action'],
              disabled: !item.success,
              onClick: () => handleApplySingle(item),
            }),
          ]),
        ],
      );

      tbody.appendChild(tr);
    });
  };

  const updateProgressUI = (state: Tachyon.FuzzerState) => {
    const statusText = document.getElementById('tachyon-fuzzer-status-text');
    const pctText = document.getElementById('tachyon-fuzzer-progress-pct');
    const progressBar = document.getElementById('tachyon-fuzzer-progress-bar');
    const currentStratEl = document.getElementById(
      'tachyon-fuzzer-current-strategy',
    );

    if (progressContainer) {
      progressContainer.style.display =
        state.running || state.results?.length ? 'flex' : 'none';
    }

    if (pctText) pctText.innerText = `${state.progress_pct}%`;
    if (progressBar) progressBar.style.width = `${state.progress_pct}%`;

    if (statusText) {
      if (state.running) {
        statusText.innerText = `${_('Testing strategy')} ${state.current_index} / ${state.total_strategies}...`;
      } else if (state.finished_at > 0) {
        statusText.innerText = state.best_strategy
          ? _('✅ Benchmark completed! Optimal strategy identified.')
          : _(
              '⚠️ Benchmark completed. No working bypass found for this target.',
            );
      }
    }

    if (currentStratEl && state.current_strategy) {
      currentStratEl.innerText = `Testing: [${state.current_strategy.name}] -> ${state.current_strategy.args}`;
    } else if (currentStratEl && !state.running) {
      currentStratEl.innerText = '';
    }

    if (state.best_strategy && applyBestBtn) {
      (applyBestBtn as HTMLButtonElement).disabled = false;
    }
  };

  // ── Polling & Execution Logic ─────────────────────────────────────────────
  const pollStatus = async () => {
    if (isPolling) return;
    isPolling = true;
    try {
      const res = await TachyonShellMethods.getFuzzerStatus();
      if (res.success && res.data) {
        currentState = res.data;
        isRunning = res.data.running;

        updateProgressUI(res.data);
        renderResults(res.data);

        if (!isRunning) {
          stopPolling();
          startBtn.innerText = _('🚀 Run Benchmark Again');
          (startBtn as HTMLButtonElement).disabled = false;
        }
      }
    } catch {
      // transient error ignore
    } finally {
      isPolling = false;
    }
  };

  const startPolling = () => {
    stopPolling();
    pollingInterval = setInterval(pollStatus, 1000);
    pollStatus();
  };

  const stopPolling = () => {
    if (pollingInterval) {
      clearInterval(pollingInterval);
      pollingInterval = null;
    }
  };

  const handleToggleRun = async () => {
    if (isRunning) {
      await TachyonShellMethods.stopFuzzer();
      showToast(_('Benchmark stopped'), 'success');
      stopPolling();
      pollStatus();
      return;
    }

    (startBtn as HTMLButtonElement).disabled = true;
    startBtn.innerText = _('🛑 Stop Benchmark');

    const res = await TachyonShellMethods.startFuzzer(
      selectedEngine,
      selectedTarget,
      customUrl,
      selectedRuleSection,
      '',
      selectedMode,
    );

    if (res.success) {
      showToast(_('Strategy benchmark started'), 'success');
      (startBtn as HTMLButtonElement).disabled = false;
      isRunning = true;
      startPolling();
    } else {
      const errMsg = !res.success ? res.error : _('Unknown error');
      showToast(`${_('Failed to start benchmark')}: ${errMsg}`, 'error');
      (startBtn as HTMLButtonElement).disabled = false;
      startBtn.innerText = _('🚀 Start Benchmark');
    }
  };

  const handleAiSynthesize = async () => {
    const userPrompt = (aiPromptInput as HTMLInputElement).value.trim();
    (aiSynthesizeBtn as HTMLButtonElement).disabled = true;
    aiSynthesizeBtn.innerText = _('🧠 Synthesizing...');

    const analysisBox = document.getElementById('tachyon-fuzzer-ai-analysis');
    const analysisText = document.getElementById(
      'tachyon-fuzzer-ai-analysis-text',
    );
    if (analysisBox) analysisBox.style.display = 'none';

    try {
      showToast(_('Consulting DPI Knowledge Base & AI...'), 'success');
      const res = await TachyonShellMethods.fuzzerAiSynthesize(
        selectedEngine,
        selectedTarget,
        customUrl,
        userPrompt,
      );

      if (res.success && res.data) {
        showToast(
          _('AI successfully synthesized custom strategies!'),
          'success',
        );

        if (analysisBox && analysisText && res.data.analysis) {
          analysisText.innerText = res.data.analysis;
          analysisBox.style.display = 'block';
        }

        // Start live fuzzer benchmark immediately on the synthesized strategies
        (startBtn as HTMLButtonElement).disabled = true;
        startBtn.innerText = _('🛑 Stop Benchmark');

        const startRes = await TachyonShellMethods.startFuzzer(
          selectedEngine,
          selectedTarget,
          customUrl,
          selectedRuleSection,
        );

        if (startRes.success) {
          isRunning = true;
          startPolling();
        }
      } else {
        const errMsg = !res.success ? res.error : _('AI synthesis failed');
        showToast(`${_('AI Synthesis Error')}: ${errMsg}`, 'error');
      }
    } catch {
      showToast(_('Failed to communicate with AI provider'), 'error');
    } finally {
      (aiSynthesizeBtn as HTMLButtonElement).disabled = false;
      aiSynthesizeBtn.innerText = _('🧠 Synthesize with AI');
    }
  };

  const handleApplySingle = async (item: Tachyon.FuzzerStrategyResult) => {
    const res = await TachyonShellMethods.applyFuzzerStrategy(
      item.engine,
      item.args,
      selectedRuleSection,
    );
    if (res.success) {
      showToast(
        `${_('Applied')} "${item.name}" -> ${selectedRuleSection || _('Global Default')}`,
        'success',
      );
    } else {
      showToast(_('Failed to apply strategy'), 'error');
    }
  };

  const handleApplyBest = async () => {
    if (!currentState?.best_strategy) return;
    await handleApplySingle(currentState.best_strategy);
  };

  // Build Modal Tree
  modalContainer.append(
    headerEl,
    controlsGrid,
    aiSynthesizerCard,
    progressContainer,
    resultsContainer,
    footerActions,
  );

  // Check initial state
  pollStatus();

  ui.showModal(_('⚡ Strategy Fuzzer & Auto-Tuner'), modalContainer);
}
