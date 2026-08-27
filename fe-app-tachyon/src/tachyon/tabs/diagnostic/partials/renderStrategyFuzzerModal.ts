import { TachyonShellMethods } from '../../../methods';
import { renderButton } from '../../../../partials';
import { showToast } from '../../../../helpers/showToast';
import { Tachyon } from '../../../types';

export function renderStrategyFuzzerModal(ruleNames: string[] = []) {
  let pollingInterval: ReturnType<typeof setInterval> | null = null;
  let isPolling = false;

  // Modal State
  let activeTab: 'benchmark' | 'patterns' | 'custom' | 'ai' | 'history' =
    'benchmark';
  let selectedEngine: Tachyon.FuzzerEngine = 'zapret2';
  let selectedTarget: Tachyon.FuzzerTarget = 'youtube_suite';
  let customUrl = '';
  let selectedRuleSection = '';
  let selectedMode: Tachyon.FuzzerMode = 'presets';
  let isRunning = false;
  let currentState: Tachyon.FuzzerState | null = null;
  let resultFilter: 'all' | 'success' | 'fast' = 'all';
  let autoApplyEnabled = false;
  let currentDpiDetection: Tachyon.FuzzerDpiDetection | null = null;

  // Patterns Config State
  let patternsConfig: Tachyon.FuzzerPatternsConfig = {
    zapret2: {
      splits: ['1', '2', '3', 'midsld', 'sniext+4', '1,midsld', '1,sniext+2'],
      foolings: ['badseq', 'md5sig', 'badack', 'datanoack', 'fakeddrop'],
      ttls: [2, 3, 4, 5, 6, 8],
      seqovls: ['1', '2'],
      wsizes: ['1'],
      payloads: ['tls_client_hello', 'http_req', 'quic_initial'],
    },
    zapret: {
      splits: ['1', '2', 'midsld', 'sniext+4', '1,midsld'],
      foolings: ['badseq', 'md5sig', 'badack', 'datanoack'],
      ttls: [2, 3, 4, 6, 8],
      split_modes: ['split2', 'disorder2', 'fake,split2', 'fake,disorder2'],
    },
    byedpi: {
      splits: ['1', '2', '1+sniext', 'midsld'],
      disorders: ['1', '2'],
      ttls: [2, 3, 4, 6, 8],
      oobs: ['1', '2'],
      autos: ['t,r,a,s', 'r,s', 't,a'],
      tlsrecs: ['1+sniext'],
      ipfrags: ['24'],
    },
    custom_strategies: [],
  };

  const modalContainer = E('div', {
    class: 'tachyon_fuzzer_modal',
    style:
      'display: flex; flex-direction: column; gap: 14px; width: 100%; max-width: 920px; box-sizing: border-box;',
  });

  // ── Tab Bar Navigation ────────────────────────────────────────────────────
  const tabButtons: Record<string, HTMLElement> = {};

  const createTabButton = (
    id: 'benchmark' | 'patterns' | 'custom' | 'ai' | 'history',
    icon: string,
    label: string,
  ) => {
    const btn = E(
      'button',
      {
        type: 'button',
        class: `cbi-button ${activeTab === id ? 'cbi-button-action' : 'cbi-button-neutral'}`,
        style:
          'display: inline-flex; align-items: center; gap: 6px; padding: 6px 14px; font-size: 12px; font-weight: 500; border-radius: 6px; cursor: pointer;',
      },
      [E('span', {}, icon), E('span', {}, label)],
    );
    btn.addEventListener('click', () => {
      activeTab = id;
      updateTabVisibility();
    });
    tabButtons[id] = btn;
    return btn;
  };

  const tabBar = E(
    'div',
    {
      style:
        'display: flex; gap: 8px; border-bottom: 1px solid var(--border-color, rgba(255,255,255,0.12)); padding-bottom: 10px; flex-wrap: wrap;',
    },
    [
      createTabButton('benchmark', '⚡', _('Benchmark & Test')),
      createTabButton('patterns', '🛠️', _('Pattern Builder')),
      createTabButton('custom', '➕', _('My Strategies')),
      createTabButton('ai', '🧠', _('AI Doctor RAG')),
      createTabButton('history', '📋', _('History')),
    ],
  );

  const tabContentBenchmark = E('div', {
    style: 'display: flex; flex-direction: column; gap: 14px;',
  });
  const tabContentPatterns = E('div', {
    style: 'display: none; flex-direction: column; gap: 14px;',
  });
  const tabContentCustom = E('div', {
    style: 'display: none; flex-direction: column; gap: 14px;',
  });
  const tabContentAi = E('div', {
    style: 'display: none; flex-direction: column; gap: 14px;',
  });
  const tabContentHistory = E('div', {
    style: 'display: none; flex-direction: column; gap: 14px;',
  });

  const updateTabVisibility = () => {
    for (const key in tabButtons) {
      tabButtons[key].className =
        `cbi-button ${activeTab === key ? 'cbi-button-action' : 'cbi-button-neutral'}`;
    }
    tabContentBenchmark.style.display =
      activeTab === 'benchmark' ? 'flex' : 'none';
    tabContentPatterns.style.display =
      activeTab === 'patterns' ? 'flex' : 'none';
    tabContentCustom.style.display = activeTab === 'custom' ? 'flex' : 'none';
    tabContentAi.style.display = activeTab === 'ai' ? 'flex' : 'none';
    tabContentHistory.style.display =
      activeTab === 'history' ? 'flex' : 'none';

    if (activeTab === 'patterns') renderPatternsTab();
    if (activeTab === 'custom') renderCustomTab();
    if (activeTab === 'history') renderHistoryTab();
  };

  // ═════════════════════════════════════════════════════════════════════════════
  // TAB 1: BENCHMARK & RUN
  // ═════════════════════════════════════════════════════════════════════════════

  const controlsGrid = E('div', {
    style:
      'display: grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); gap: 10px; align-items: end;',
  });

  // 1. Engine Select
  const engineSelect = E(
    'select',
    { class: 'cbi-input-select', style: 'width: 100%;' },
    [
      E('option', { value: 'zapret2' }, _('Zapret v2 (nfqws2)')),
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
        { style: 'font-size: 11px; font-weight: 600; opacity: 0.85;' },
        _('DPI Engine'),
      ),
      engineSelect,
    ],
  );

  // 2. Target Preset Select
  const targetSelect = E(
    'select',
    { class: 'cbi-input-select', style: 'width: 100%;' },
    [
      E(
        'option',
        { value: 'youtube_suite', selected: true },
        _('🎬 YouTube Suite (Web + 4K Stream)'),
      ),
      E(
        'option',
        { value: 'discord_suite' },
        _('💬 Discord Suite (API + WSS + CDN)'),
      ),
      E(
        'option',
        { value: 'instagram_suite' },
        _('📸 Instagram / Meta (Web + CDN)'),
      ),
      E(
        'option',
        { value: 'telegram_suite' },
        _('✈️ Telegram Suite (Web + Bot API)'),
      ),
      E('option', { value: 'rutracker_suite' }, _('🏴‍☠️ RuTracker Suite')),
      E('option', { value: 'quic_http3' }, _('⚡ QUIC / HTTP/3 (UDP 443)')),
      E('option', { value: 'custom' }, _('🌐 Custom Target URL...')),
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
    (customUrlInput as HTMLElement).style.display =
      selectedTarget === 'custom' ? 'block' : 'none';
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
        { style: 'font-size: 11px; font-weight: 600; opacity: 0.85;' },
        _('Target Service / Suite'),
      ),
      targetSelect,
      customUrlInput,
    ],
  );

  // 3. Search Mode Select
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
        _('🔍 Combinatorial Deep Fuzzing (~40-80+)'),
      ),
      E('option', { value: 'custom' }, _('🛠️ My Custom Strategies Only')),
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
        { style: 'font-size: 11px; font-weight: 600; opacity: 0.85;' },
        _('Search Mode'),
      ),
      modeSelect,
    ],
  );

  // 4. Rule Apply Target Select
  const ruleSelect = E(
    'select',
    { class: 'cbi-input-select', style: 'width: 100%;' },
    [
      E('option', { value: '', selected: true }, _('Provider Global Default')),
      ...ruleNames.map((r) => E('option', { value: r }, `${_('Rule:')} ${r}`)),
    ],
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
        { style: 'font-size: 11px; font-weight: 600; opacity: 0.85;' },
        _('Apply Strategy To'),
      ),
      ruleSelect,
    ],
  );
  controlsGrid.append(engineGroup, targetGroup, modeGroup, ruleGroup);

  // Auto-Apply Toggle
  const autoApplyCheckbox = E('input', {
    type: 'checkbox',
    id: 'tachyon-fuzzer-auto-apply',
    style: 'margin: 0;',
  });
  autoApplyCheckbox.addEventListener('change', () => {
    autoApplyEnabled = (autoApplyCheckbox as HTMLInputElement).checked;
  });

  const autoApplyGroup = E(
    'div',
    {
      style:
        'display: flex; align-items: end; padding: 4px 0; grid-column: 1 / -1;',
    },
    [
      E(
        'div',
        {
          style: 'font-size: 11px; cursor: pointer; display: flex; align-items: center; gap: 4px;',
        },
        [autoApplyCheckbox, E('span', {}, _('Auto-apply best strategy'))],
      ),
    ],
  );
  controlsGrid.append(autoApplyGroup);

  // DPI Detection Banner
  const dpiDetectionBanner = E('div', {
    id: 'tachyon-fuzzer-dpi-banner',
    style:
      'display: none; padding: 10px 14px; border-radius: 6px; font-size: 12px; line-height: 1.4;',
  });

  // Progress Bar
  const progressContainer = E(
    'div',
    {
      style:
        'display: none; flex-direction: column; gap: 6px; padding: 10px 14px; background: var(--background-color-secondary, rgba(0,0,0,0.18)); border-radius: 6px; border: 1px solid var(--border-color, rgba(255,255,255,0.08));',
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
            'width: 100%; height: 6px; background: rgba(255,255,255,0.1); border-radius: 3px; overflow: hidden;',
        },
        [
          E('div', {
            id: 'tachyon-fuzzer-progress-bar',
            style:
              'height: 100%; width: 0%; background: #007bff; transition: width 0.3s ease;',
          }),
        ],
      ),
      E(
        'div',
        {
          id: 'tachyon-fuzzer-current-strategy',
          style: 'font-size: 11px; opacity: 0.75; font-family: monospace;',
        },
        '',
      ),
    ],
  );

  const applyBestBtn = renderButton({
    text: _('🏆 Apply Best Match'),
    classNames: ['cbi-button-save'],
    disabled: true,
    onClick: () => handleApplyBest(),
  });

  // Results Filter Toolbar
  const filterToolbar = E(
    'div',
    {
      style:
        'display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 8px;',
    },
    [
      E('div', { style: 'display: flex; gap: 6px; align-items: center;' }, [
        E(
          'span',
          { style: 'font-size: 11px; opacity: 0.7; margin-right: 4px;' },
          _('Filter:'),
        ),
        (() => {
          const bAll = E(
            'button',
            {
              type: 'button',
              class: 'cbi-button cbi-button-action',
              style: 'padding: 2px 10px; font-size: 11px;',
            },
            _('All'),
          );
          const bOk = E(
            'button',
            {
              type: 'button',
              class: 'cbi-button cbi-button-neutral',
              style: 'padding: 2px 10px; font-size: 11px;',
            },
            _('✅ Working only'),
          );
          const bFast = E(
            'button',
            {
              type: 'button',
              class: 'cbi-button cbi-button-neutral',
              style: 'padding: 2px 10px; font-size: 11px;',
            },
            _('⚡ Fast (>1MB/s)'),
          );

          const setFilter = (
            f: 'all' | 'success' | 'fast',
            btn: HTMLElement,
          ) => {
            resultFilter = f;
            [bAll, bOk, bFast].forEach(
              (b) => (b.className = 'cbi-button cbi-button-neutral'),
            );
            btn.className = 'cbi-button cbi-button-action';
            if (currentState) renderResults(currentState);
          };

          bAll.addEventListener('click', () => setFilter('all', bAll));
          bOk.addEventListener('click', () => setFilter('success', bOk));
          bFast.addEventListener('click', () => setFilter('fast', bFast));

          return E('div', { style: 'display: flex; gap: 4px;' }, [
            bAll,
            bOk,
            bFast,
          ]);
        })(),
      ]),
      E('div', { style: 'display: flex; gap: 8px;' }, [applyBestBtn]),
    ],
  );

  // Results Table
  const resultsContainer = E('div', {
    style:
      'max-height: 380px; overflow-y: auto; border: 1px solid var(--border-color, rgba(255,255,255,0.1)); border-radius: 6px;',
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
            'background: var(--background-color-secondary, rgba(0,0,0,0.25)); position: sticky; top: 0; z-index: 2;',
        },
        [
          E('tr', {}, [
            E('th', { style: 'padding: 8px 10px; width: 35px;' }, '#'),
            E('th', { style: 'padding: 8px 10px; width: 75px;' }, _('Engine')),
            E(
              'th',
              { style: 'padding: 8px 10px;' },
              _('Strategy & Parameters'),
            ),
            E(
              'th',
              { style: 'padding: 8px 10px; width: 95px;' },
              _('Status / Suite'),
            ),
            E('th', { style: 'padding: 8px 10px; width: 65px;' }, _('TTFB')),
            E('th', { style: 'padding: 8px 10px; width: 75px;' }, _('Speed')),
            E('th', { style: 'padding: 8px 10px; width: 80px;' }, _('Score')),
            E(
              'th',
              { style: 'padding: 8px 10px; width: 85px; text-align: center;' },
              _('Actions'),
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
              'No benchmark results yet. Configure options and click "Start Benchmark".',
            ),
          ),
        ),
      ]),
    ],
  );

  resultsContainer.appendChild(tableEl);

  // Footer Actions for Benchmark
  const startBtn = renderButton({
    text: _('🚀 Start Benchmark'),
    classNames: ['cbi-button-action'],
    onClick: () => handleToggleRun(),
  });

  const footerActions = E(
    'div',
    {
      style:
        'display: flex; justify-content: space-between; align-items: center; padding-top: 6px;',
    },
    [
      startBtn,
      renderButton({
        text: _('Close'),
        classNames: ['cbi-button-neutral'],
        onClick: () => {
          stopPolling();
          ui.hideModal();
        },
      }),
    ],
  );

  tabContentBenchmark.append(
    controlsGrid,
    dpiDetectionBanner,
    progressContainer,
    filterToolbar,
    resultsContainer,
    footerActions,
  );

  // ═════════════════════════════════════════════════════════════════════════════
  // TAB 2: PATTERN BUILDER & MATRIX CONFIG
  // ═════════════════════════════════════════════════════════════════════════════

  const renderChipGroup = (
    title: string,
    items: (string | number)[],
    onAdd: (val: string) => void,
    onRemove: (idx: number) => void,
  ) => {
    const input = E('input', {
      type: 'text',
      class: 'cbi-input-text',
      placeholder: '+ add',
      style: 'width: 80px; padding: 2px 6px; font-size: 11px;',
    });

    input.addEventListener('keydown', (e: KeyboardEvent) => {
      if (e.key === 'Enter') {
        const v = (input as HTMLInputElement).value.trim();
        if (v) {
          onAdd(v);
          (input as HTMLInputElement).value = '';
          renderPatternsTab();
        }
      }
    });

    const chips = items.map((item, idx) => {
      const chip = E(
        'span',
        {
          style:
            'display: inline-flex; align-items: center; gap: 4px; padding: 2px 8px; background: var(--background-color-secondary, rgba(255,255,255,0.08)); border: 1px solid var(--border-color, rgba(255,255,255,0.12)); border-radius: 4px; font-size: 11px; font-family: monospace;',
        },
        [
          E('span', {}, String(item)),
          (() => {
            const del = E(
              'span',
              {
                style:
                  'cursor: pointer; opacity: 0.6; font-size: 12px; margin-left: 2px;',
              },
              '×',
            );
            del.addEventListener('click', () => {
              onRemove(idx);
              renderPatternsTab();
            });
            return del;
          })(),
        ],
      );
      return chip;
    });

    return E(
      'div',
      { style: 'display: flex; flex-direction: column; gap: 4px;' },
      [
        E(
          'span',
          { style: 'font-size: 11px; font-weight: 600; opacity: 0.8;' },
          title,
        ),
        E(
          'div',
          {
            style:
              'display: flex; flex-wrap: wrap; gap: 6px; align-items: center;',
          },
          [...chips, input],
        ),
      ],
    );
  };

  const renderPatternsTab = () => {
    tabContentPatterns.replaceChildren();

    const z2 = patternsConfig.zapret2;
    const z1 = patternsConfig.zapret;
    const bd = patternsConfig.byedpi;

    const z2Card = E(
      'div',
      {
        style:
          'padding: 12px; background: var(--background-color-secondary, rgba(0,0,0,0.15)); border-radius: 6px; border: 1px solid var(--border-color, rgba(255,255,255,0.1)); display: flex; flex-direction: column; gap: 10px;',
      },
      [
        E(
          'div',
          { style: 'font-size: 13px; font-weight: bold;' },
          '⚡ Zapret v2 (nfqws2) Matrix Patterns',
        ),
        renderChipGroup(
          _('Split Positions (pos)'),
          z2.splits,
          (v) => z2.splits.push(v),
          (i) => z2.splits.splice(i, 1),
        ),
        renderChipGroup(
          _('Fooling Methods (fooling)'),
          z2.foolings,
          (v) => z2.foolings.push(v),
          (i) => z2.foolings.splice(i, 1),
        ),
        renderChipGroup(
          _('TTL Values (ttl)'),
          z2.ttls,
          (v) => z2.ttls.push(Number(v) || 4),
          (i) => z2.ttls.splice(i, 1),
        ),
        renderChipGroup(
          _('Sequence Overlaps (seqovl)'),
          z2.seqovls,
          (v) => z2.seqovls.push(v),
          (i) => z2.seqovls.splice(i, 1),
        ),
        renderChipGroup(
          _('TCP Window Sizes (wsize)'),
          z2.wsizes,
          (v) => z2.wsizes.push(v),
          (i) => z2.wsizes.splice(i, 1),
        ),
      ],
    );

    const z1Card = E(
      'div',
      {
        style:
          'padding: 12px; background: var(--background-color-secondary, rgba(0,0,0,0.15)); border-radius: 6px; border: 1px solid var(--border-color, rgba(255,255,255,0.1)); display: flex; flex-direction: column; gap: 10px;',
      },
      [
        E(
          'div',
          { style: 'font-size: 13px; font-weight: bold;' },
          '⚡ Zapret v1 (nfqws) Matrix Patterns',
        ),
        renderChipGroup(
          _('Split Modes (dpi-desync)'),
          z1.split_modes,
          (v) => z1.split_modes.push(v),
          (i) => z1.split_modes.splice(i, 1),
        ),
        renderChipGroup(
          _('Split Positions (dpi-desync-split-pos)'),
          z1.splits,
          (v) => z1.splits.push(v),
          (i) => z1.splits.splice(i, 1),
        ),
        renderChipGroup(
          _('Fooling Methods (dpi-desync-fooling)'),
          z1.foolings,
          (v) => z1.foolings.push(v),
          (i) => z1.foolings.splice(i, 1),
        ),
        renderChipGroup(
          _('TTL Values (dpi-desync-ttl)'),
          z1.ttls,
          (v) => z1.ttls.push(Number(v) || 4),
          (i) => z1.ttls.splice(i, 1),
        ),
      ],
    );

    const bdCard = E(
      'div',
      {
        style:
          'padding: 12px; background: var(--background-color-secondary, rgba(0,0,0,0.15)); border-radius: 6px; border: 1px solid var(--border-color, rgba(255,255,255,0.1)); display: flex; flex-direction: column; gap: 10px;',
      },
      [
        E(
          'div',
          { style: 'font-size: 13px; font-weight: bold;' },
          '⚡ ByeDPI (ciadpi) Matrix Patterns',
        ),
        renderChipGroup(
          _('Split Values (-s)'),
          bd.splits,
          (v) => bd.splits.push(v),
          (i) => bd.splits.splice(i, 1),
        ),
        renderChipGroup(
          _('Disorder Values (-d)'),
          bd.disorders,
          (v) => bd.disorders.push(v),
          (i) => bd.disorders.splice(i, 1),
        ),
        renderChipGroup(
          _('OOB Values (-o)'),
          bd.oobs,
          (v) => bd.oobs.push(v),
          (i) => bd.oobs.splice(i, 1),
        ),
        renderChipGroup(
          _('Auto Modes (--auto)'),
          bd.autos,
          (v) => bd.autos.push(v),
          (i) => bd.autos.splice(i, 1),
        ),
        renderChipGroup(
          _('TLS-Rec Bounds (--tlsrec)'),
          bd.tlsrecs,
          (v) => bd.tlsrecs.push(v),
          (i) => bd.tlsrecs.splice(i, 1),
        ),
        renderChipGroup(
          _('IP Frag Bounds (--ip-frag)'),
          bd.ipfrags,
          (v) => bd.ipfrags.push(v),
          (i) => bd.ipfrags.splice(i, 1),
        ),
      ],
    );

    const patternsFooter = E(
      'div',
      {
        style:
          'display: flex; justify-content: space-between; align-items: center; padding-top: 6px;',
      },
      [
        renderButton({
          text: _('💾 Save Custom Patterns'),
          classNames: ['cbi-button-save'],
          onClick: async () => {
            const res =
              await TachyonShellMethods.saveFuzzerPatterns(patternsConfig);
            if (res.success) {
              showToast(_('Patterns saved successfully!'), 'success');
            } else {
              showToast(_('Failed to save patterns'), 'error');
            }
          },
        }),
        renderButton({
          text: _('🔄 Reset to Factory Defaults'),
          classNames: ['cbi-button-neutral'],
          onClick: async () => {
            const res = await TachyonShellMethods.resetFuzzerPatterns();
            if (res.success && res.data?.patterns) {
              patternsConfig = res.data.patterns;
              renderPatternsTab();
              showToast(_('Patterns reset to defaults!'), 'success');
            }
          },
        }),
      ],
    );

    tabContentPatterns.append(z2Card, z1Card, bdCard, patternsFooter);
  };

  // ═════════════════════════════════════════════════════════════════════════════
  // TAB 3: CUSTOM STRATEGIES
  // ═════════════════════════════════════════════════════════════════════════════

  const renderCustomTab = () => {
    tabContentCustom.replaceChildren();

    const nameInput = E('input', {
      type: 'text',
      class: 'cbi-input-text',
      placeholder: _('Strategy Name'),
      style: 'flex: 1;',
    });
    const engineSel = E(
      'select',
      { class: 'cbi-input-select', style: 'width: 140px;' },
      [
        E('option', { value: 'zapret2' }, 'Zapret v2'),
        E('option', { value: 'zapret' }, 'Zapret v1'),
        E('option', { value: 'byedpi' }, 'ByeDPI'),
      ],
    );
    const argsInput = E('input', {
      type: 'text',
      class: 'cbi-input-text',
      placeholder: _('Command-line arguments string...'),
      style: 'flex: 2; font-family: monospace;',
    });

    const addBtn = renderButton({
      text: _('+ Add Strategy'),
      classNames: ['cbi-button-action'],
      onClick: async () => {
        const name = (nameInput as HTMLInputElement).value.trim();
        const eng = (engineSel as HTMLSelectElement)
          .value as Tachyon.FuzzerEngine;
        const args = (argsInput as HTMLInputElement).value.trim();
        if (!name || !args) {
          showToast(_('Please specify strategy name and arguments'), 'error');
          return;
        }

        patternsConfig.custom_strategies =
          patternsConfig.custom_strategies || [];
        patternsConfig.custom_strategies.push({
          id: `custom_${Date.now()}`,
          name,
          engine: eng as 'zapret2' | 'zapret' | 'byedpi',
          args,
          description: _('User custom strategy'),
        });

        await TachyonShellMethods.saveFuzzerPatterns(patternsConfig);
        showToast(_('Custom strategy added!'), 'success');
        (nameInput as HTMLInputElement).value = '';
        (argsInput as HTMLInputElement).value = '';
        renderCustomTab();
      },
    });

    const addCard = E(
      'div',
      {
        style:
          'padding: 12px; background: var(--background-color-secondary, rgba(0,0,0,0.15)); border-radius: 6px; border: 1px solid var(--border-color, rgba(255,255,255,0.1)); display: flex; flex-direction: column; gap: 8px;',
      },
      [
        E(
          'div',
          { style: 'font-size: 12px; font-weight: 600;' },
          _('Add Custom DPI Strategy'),
        ),
        E(
          'div',
          {
            style:
              'display: flex; gap: 8px; flex-wrap: wrap; align-items: center;',
          },
          [nameInput, engineSel, argsInput, addBtn],
        ),
      ],
    );

    const customList = patternsConfig.custom_strategies || [];
    const listCard = E(
      'div',
      {
        style:
          'border: 1px solid var(--border-color, rgba(255,255,255,0.1)); border-radius: 6px; overflow: hidden;',
      },
      [
        E(
          'table',
          { class: 'table', style: 'width: 100%; margin: 0; font-size: 12px;' },
          [
            E('thead', {}, [
              E('tr', {}, [
                E('th', { style: 'padding: 8px;' }, _('Name')),
                E('th', { style: 'padding: 8px; width: 90px;' }, _('Engine')),
                E('th', { style: 'padding: 8px;' }, _('Arguments')),
                E(
                  'th',
                  {
                    style: 'padding: 8px; width: 80px; text-align: center;',
                  },
                  _('Actions'),
                ),
              ]),
            ]),
            E(
              'tbody',
              {},
              customList.length === 0
                ? [
                    E(
                      'tr',
                      {},
                      E(
                        'td',
                        {
                          colSpan: 4,
                          style:
                            'padding: 20px; text-align: center; opacity: 0.6;',
                        },
                        _('No custom strategies added yet.'),
                      ),
                    ),
                  ]
                : customList.map((cs, idx) => {
                    return E('tr', {}, [
                      E(
                        'td',
                        { style: 'padding: 8px; font-weight: 600;' },
                        cs.name,
                      ),
                      E(
                        'td',
                        {
                          style:
                            'padding: 8px; font-family: monospace; font-size: 11px;',
                        },
                        cs.engine,
                      ),
                      E(
                        'td',
                        {
                          style:
                            'padding: 8px; font-family: monospace; font-size: 11px; word-break: break-all;',
                        },
                        cs.args,
                      ),
                      E(
                        'td',
                        {
                          style: 'padding: 8px; text-align: center;',
                        },
                        [
                          (() => {
                            const delBtn = E(
                              'button',
                              {
                                type: 'button',
                                class: 'cbi-button cbi-button-reset',
                                style: 'padding: 2px 8px; font-size: 11px;',
                              },
                              _('Delete'),
                            );
                            delBtn.addEventListener('click', async () => {
                              patternsConfig.custom_strategies.splice(idx, 1);
                              await TachyonShellMethods.saveFuzzerPatterns(
                                patternsConfig,
                              );
                              showToast(_('Strategy deleted'), 'success');
                              renderCustomTab();
                            });
                            return delBtn;
                          })(),
                        ],
                      ),
                    ]);
                  }),
            ),
          ],
        ),
      ],
    );

    tabContentCustom.append(addCard, listCard);
  };

  // ═════════════════════════════════════════════════════════════════════════════
  // TAB 4: AI DOCTOR RAG
  // ═════════════════════════════════════════════════════════════════════════════

  const aiPromptInput = E('input', {
    type: 'text',
    class: 'cbi-input-text',
    placeholder: _(
      'Optional context (e.g. "Rostelecom, YouTube 4K buffering is slow")...',
    ),
    style: 'flex: 1; font-size: 12px;',
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
        'display: none; padding: 12px; background: rgba(0, 123, 255, 0.08); border-left: 3px solid #007bff; border-radius: 4px; font-size: 12px; line-height: 1.4;',
    },
    [
      E(
        'div',
        {
          style:
            'font-weight: bold; margin-bottom: 6px; display: flex; align-items: center; gap: 6px;',
        },
        [
          E('span', {}, '🧠'),
          E('span', {}, _('AI Diagnostics & Strategy Rationale')),
        ],
      ),
      E(
        'div',
        { id: 'tachyon-fuzzer-ai-analysis-text', style: 'opacity: 0.9;' },
        '',
      ),
    ],
  );

  const aiSynthesizerCard = E(
    'div',
    {
      style:
        'padding: 14px; background: var(--background-color-secondary, rgba(0,0,0,0.15)); border-radius: 6px; border: 1px solid var(--border-color, rgba(255,255,255,0.1)); display: flex; flex-direction: column; gap: 12px;',
    },
    [
      E(
        'div',
        {
          style:
            'font-size: 13px; font-weight: bold; display: flex; align-items: center; justify-content: space-between;',
        },
        [
          E('span', {}, '🧠 ' + _('AI DPI Engineer & Strategy Synthesizer')),
          E(
            'span',
            { style: 'font-size: 11px; opacity: 0.6; font-weight: normal;' },
            _('RAG Knowledge Base + Live ISP Probe Context'),
          ),
        ],
      ),
      E(
        'div',
        { style: 'font-size: 12px; opacity: 0.8;' },
        _(
          'Automatically runs a diagnostic probe against the target service, queries the built-in DPI Knowledge Base, and synthesizes 3-5 custom bypass strategies tailored to your ISP.',
        ),
      ),
      E('div', { style: 'display: flex; gap: 8px; align-items: center;' }, [
        aiPromptInput,
        aiSynthesizeBtn,
      ]),
      aiAnalysisContainer,
    ],
  );

  tabContentAi.append(aiSynthesizerCard);

  // ═════════════════════════════════════════════════════════════════════════════
  // TAB 5: HISTORY
  // ═════════════════════════════════════════════════════════════════════════════

  const renderHistoryTab = async () => {
    tabContentHistory.replaceChildren();

    const historyHeader = E(
      'div',
      {
        style:
          'display: flex; justify-content: space-between; align-items: center;',
      },
      [
        E(
          'div',
          { style: 'font-size: 13px; font-weight: bold;' },
          '📋 ' + _('Benchmark History'),
        ),
        E('div', { style: 'display: flex; gap: 8px;' }, [
          renderButton({
            text: _('🔄 Refresh'),
            classNames: ['cbi-button-neutral'],
            onClick: () => renderHistoryTab(),
          }),
          renderButton({
            text: _('🗑️ Clear History'),
            classNames: ['cbi-button-reset'],
            onClick: async () => {
              await TachyonShellMethods.clearFuzzerHistory();
              showToast(_('History cleared'), 'success');
              renderHistoryTab();
            },
          }),
        ]),
      ],
    );

    const historyContainer = E('div', {
      style:
        'border: 1px solid var(--border-color, rgba(255,255,255,0.1)); border-radius: 6px; overflow: hidden;',
    });

    try {
      const res = await TachyonShellMethods.getFuzzerHistory(20);
      const entries = res.data?.entries || [];

      if (entries.length === 0) {
        historyContainer.appendChild(
          E(
            'div',
            {
              style:
                'padding: 24px; text-align: center; opacity: 0.6; font-size: 12px;',
            },
            _('No benchmark history yet. Run a benchmark to see results here.'),
          ),
        );
      } else {
        const table = E(
          'table',
          {
            class: 'table',
            style: 'width: 100%; margin: 0; font-size: 12px;',
          },
          [
            E('thead', {}, [
              E('tr', {}, [
                E('th', { style: 'padding: 8px;' }, _('Date')),
                E('th', { style: 'padding: 8px;' }, _('Engine')),
                E('th', { style: 'padding: 8px;' }, _('Target')),
                E('th', { style: 'padding: 8px;' }, _('DPI Type')),
                E('th', { style: 'padding: 8px;' }, _('Best Strategy')),
                E('th', { style: 'padding: 8px; width: 60px;' }, _('Score')),
                E('th', { style: 'padding: 8px; width: 70px;' }, _('Working')),
              ]),
            ]),
            E(
              'tbody',
              {},
              entries.reverse().map((entry) => {
                const date = new Date(entry.timestamp * 1000);
                const dateStr = `${date.toLocaleDateString()} ${date.toLocaleTimeString()}`;
                const dpiType = entry.dpi_detection
                  ? `${entry.dpi_detection.type} (${entry.dpi_detection.confidence}%)`
                  : '—';
                const bestName = entry.best_strategy
                  ? entry.best_strategy.name
                  : '—';
                const bestScore = entry.best_strategy
                  ? String(entry.best_strategy.score)
                  : '0';
                const working = `${entry.working_count}/${entry.total_tested}`;

                return E('tr', {}, [
                  E('td', { style: 'padding: 8px;' }, dateStr),
                  E(
                    'td',
                    {
                      style: 'padding: 8px; font-family: monospace;',
                    },
                    entry.engine,
                  ),
                  E('td', { style: 'padding: 8px;' }, entry.target),
                  E('td', { style: 'padding: 8px;' }, dpiType),
                  E(
                    'td',
                    {
                      style:
                        'padding: 8px; font-size: 11px; max-width: 200px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;',
                    },
                    bestName,
                  ),
                  E(
                    'td',
                    { style: 'padding: 8px; font-weight: bold;' },
                    bestScore,
                  ),
                  E('td', { style: 'padding: 8px;' }, working),
                ]);
              }),
            ),
          ],
        );
        historyContainer.appendChild(table);
      }
    } catch {
      historyContainer.appendChild(
        E(
          'div',
          {
            style:
              'padding: 24px; text-align: center; opacity: 0.6; font-size: 12px;',
          },
          _('Failed to load history'),
        ),
      );
    }

    tabContentHistory.append(historyHeader, historyContainer);
  };

  // ── Results Rendering ─────────────────────────────────────────────────────
  const renderResults = (state: Tachyon.FuzzerState) => {
    const tbody = document.getElementById('tachyon-fuzzer-results-tbody');
    if (!tbody) return;
    tbody.replaceChildren();

    let list = state.results || [];
    if (resultFilter === 'success') {
      list = list.filter((r) => r.success);
    } else if (resultFilter === 'fast') {
      list = list.filter((r) => r.success && r.speed_kbps > 1024);
    }

    if (list.length === 0) {
      tbody.appendChild(
        E(
          'tr',
          {},
          E(
            'td',
            {
              colSpan: 8,
              style: 'padding: 24px; text-align: center; opacity: 0.6;',
            },
            state.running
              ? _('Running benchmarks...')
              : _('No strategies match the active filter.'),
          ),
        ),
      );
      return;
    }

    list.forEach((item, idx) => {
      const isBest = state.best_strategy && state.best_strategy.id === item.id;

      let statusBadge = `<span class="label ${item.success ? 'badge-success' : 'badge-danger'}" style="font-size: 10px; padding: 2px 6px; border-radius: 3px;">${item.success ? `HTTP ${item.http_code}` : 'DROP'}</span>`;

      // If suite sub-probes exist, render multi-endpoint summary
      let subProbesHtml = '';
      if (item.sub_probes && item.sub_probes.length > 1) {
        const passedSub = item.sub_probes.filter((p) => p.success).length;
        const totalSub = item.sub_probes.length;
        subProbesHtml = `<div style="font-size: 10px; opacity: 0.75; margin-top: 2px;">${passedSub}/${totalSub} endpoints OK</div>`;
      }

      let badgeHtml = '';
      if (item.badge) {
        badgeHtml = `<span style="font-size: 10px; margin-left: 6px; font-weight: bold; color: ${isBest ? '#28a745' : '#17a2b8'};">${item.badge}</span>`;
      }

      const tr = E(
        'tr',
        {
          style: `border-bottom: 1px solid var(--border-color, rgba(255,255,255,0.06)); ${
            isBest ? 'background: rgba(40, 167, 69, 0.08);' : ''
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
          E(
            'td',
            { style: 'padding: 8px 10px;' },
            E('div', { innerHTML: statusBadge + subProbesHtml }),
          ),
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
          E(
            'td',
            { style: 'padding: 8px 10px; text-align: center;' },
            E(
              'div',
              { style: 'display: flex; gap: 4px; justify-content: center;' },
              [
                renderButton({
                  text: _('Apply'),
                  classNames: ['cbi-button-action'],
                  disabled: !item.success,
                  onClick: () => handleApplySingle(item),
                }),
              ],
            ),
          ),
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
    const applyBestBtn = document.getElementById(
      'tachyon-fuzzer-apply-best-btn',
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
  let lastRenderedCount = 0;
  let lastRenderedFinishedAt = 0;

  const pollStatus = async () => {
    if (isPolling) return;
    isPolling = true;
    try {
      const res = await TachyonShellMethods.getFuzzerStatus();
      if (res.success && res.data) {
        currentState = res.data;
        isRunning = res.data.running;

        updateProgressUI(res.data);

        // Only re-render results when new results arrive or benchmark finishes
        const resultCount = res.data.results?.length || 0;
        const finishedAt = res.data.finished_at || 0;
        if (
          resultCount !== lastRenderedCount ||
          finishedAt !== lastRenderedFinishedAt
        ) {
          renderResults(res.data);
          lastRenderedCount = resultCount;
          lastRenderedFinishedAt = finishedAt;
        }

        if (!isRunning) {
          stopPolling();
          startBtn.innerText = _('🚀 Start Benchmark');
          (startBtn as HTMLButtonElement).disabled = false;

          // Auto-apply best strategy if enabled
          if (autoApplyEnabled && currentState?.best_strategy) {
            try {
              const applyRes =
                await TachyonShellMethods.autoApplyFuzzerStrategy(
                  selectedRuleSection || undefined,
                );
              if (applyRes.success) {
                showToast(
                  `${_('✅ Auto-applied best strategy')}: ${currentState.best_strategy.name}`,
                  'success',
                );
              } else {
                showToast(
                  `${_('Auto-apply failed')}: ${applyRes.error || _('Unknown error')}`,
                  'error',
                );
              }
            } catch {
              showToast(_('Auto-apply failed'), 'error');
            }
          }
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
    pollingInterval = setInterval(pollStatus, 600);
    pollStatus();
  };

  const stopPolling = () => {
    if (pollingInterval) {
      clearInterval(pollingInterval);
      pollingInterval = null;
    }
  };

  const updateDpiBanner = (detection: Tachyon.FuzzerDpiDetection | null) => {
    const banner = document.getElementById('tachyon-fuzzer-dpi-banner');
    if (!banner) return;
    if (!detection) {
      banner.style.display = 'none';
      return;
    }

    const typeColors: Record<string, { bg: string; border: string; icon: string }> = {
      rst: { bg: 'rgba(220, 53, 69, 0.12)', border: '#dc3545', icon: '🔴' },
      throttle: {
        bg: 'rgba(255, 193, 7, 0.12)',
        border: '#ffc107',
        icon: '🟡',
      },
      dns_block: {
        bg: 'rgba(23, 162, 184, 0.12)',
        border: '#17a2b8',
        icon: '🔵',
      },
      unknown: {
        bg: 'rgba(108, 117, 125, 0.12)',
        border: '#6c757d',
        icon: '⚪',
      },
      none: {
        bg: 'rgba(40, 167, 69, 0.12)',
        border: '#28a745',
        icon: '🟢',
      },
    };

    const typeLabels: Record<string, string> = {
      rst: 'TCP Reset Injection',
      throttle: 'Throttling / Deep Inspection',
      dns_block: 'DNS Blocking',
      unknown: 'Unknown DPI Pattern',
      none: 'No Blocking Detected',
    };

    const colors = typeColors[detection.type] || typeColors.unknown;
    const label = typeLabels[detection.type] || detection.type;

    banner.style.display = 'block';
    banner.style.background = colors.bg;
    banner.style.borderLeft = `3px solid ${colors.border}`;
    banner.innerHTML = `
      <div style="display: flex; justify-content: space-between; align-items: start;">
        <div>
          <span style="font-weight: bold;">${colors.icon} ${_('DPI Detected')}: ${label}</span>
          <span style="opacity: 0.7; margin-left: 8px;">${detection.confidence}% ${_('confidence')}</span>
        </div>
        ${detection.recommended_engines.length > 0 ? `<div style="font-size: 11px; opacity: 0.7;">${_('Recommended')}: ${detection.recommended_engines.join(', ')}</div>` : ''}
      </div>
      <div style="margin-top: 4px; opacity: 0.8; font-size: 11px;">${detection.details}</div>
    `;
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

    // Immediate visual feedback
    progressContainer.style.display = 'flex';
    const statusTextEl = document.getElementById('tachyon-fuzzer-status-text');
    const progressBarEl = document.getElementById(
      'tachyon-fuzzer-progress-bar',
    );
    const currentStratEl = document.getElementById(
      'tachyon-fuzzer-current-strategy',
    );
    if (statusTextEl)
      statusTextEl.innerText = _('🚀 Initializing benchmark in sandbox...');
    if (progressBarEl) progressBarEl.style.width = '3%';
    if (currentStratEl)
      currentStratEl.innerText = _(
        'Preparing strategies and isolated nftables queue...',
      );

    // Run DPI detection before starting benchmark
    try {
      const dpiRes = await TachyonShellMethods.detectFuzzerDpi(
        selectedTarget,
        selectedTarget === 'custom' ? customUrl : undefined,
      );
      if (dpiRes.success && dpiRes.data) {
        currentDpiDetection = dpiRes.data;
        updateDpiBanner(dpiRes.data);
      }
    } catch {
      // DPI detection is non-critical, continue with benchmark
    }

    const tbody = document.getElementById('tachyon-fuzzer-results-tbody');
    if (tbody) {
      tbody.replaceChildren(
        E(
          'tr',
          {},
          E(
            'td',
            {
              colSpan: 8,
              style: 'padding: 24px; text-align: center; opacity: 0.85;',
            },
            [
              E('span', { style: 'margin-right: 8px;' }, '⏳'),
              E(
                'span',
                {},
                _('Testing bypass strategies in isolated sandbox...'),
              ),
            ],
          ),
        ),
      );
    }

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
      lastRenderedCount = 0;
      lastRenderedFinishedAt = 0;
      startPolling();
    } else {
      const errMsg = !res.success ? res.error : _('Unknown error');
      showToast(`${_('Failed to start benchmark')}: ${errMsg}`, 'error');
      (startBtn as HTMLButtonElement).disabled = false;
      startBtn.innerText = _('🚀 Start Benchmark');
      progressContainer.style.display = 'none';
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

        // Switch to benchmark tab and start running
        activeTab = 'benchmark';
        updateTabVisibility();

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

  // Initial Data Fetch: available engines & custom patterns
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
      }
    })
    .catch(() => {});

  TachyonShellMethods.getFuzzerPatterns()
    .then((res) => {
      if (res.success && res.data?.patterns) {
        patternsConfig = res.data.patterns;
      }
    })
    .catch(() => {});

  // Build Modal Tree
  modalContainer.append(
    tabBar,
    tabContentBenchmark,
    tabContentPatterns,
    tabContentCustom,
    tabContentAi,
    tabContentHistory,
  );

  // Check initial state
  pollStatus();

  ui.showModal(_('⚡ Strategy Fuzzer & Auto-Tuner'), modalContainer);
}
