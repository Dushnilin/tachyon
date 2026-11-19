import { TachyonShellMethods } from '../../../methods';
import { renderButton } from '../../../../partials';
import {
  renderZapIcon,
  renderWrenchIcon,
  renderPlusIcon,
  renderBrainIcon,
  renderFileTextIcon,
  renderCheckIcon,
  renderAlertTriangleIcon,
  renderXIcon,
  renderHourglassIcon,
  renderCircleStopIcon,
  renderShieldIcon,
  renderGlobeIcon,
} from '../../../../icons';
import { showToast } from '../../../../helpers/showToast';
import { Tachyon } from '../../../types';

export interface FuzzerRuleSection {
  id: string;
  label: string;
  action?: string;
  isGlobal?: boolean;
  domains?: string[];
}

export interface FuzzerModalOptions {
  initialEngine?: Tachyon.FuzzerEngine;
  initialRuleSection?: string;
  initialCustomDomains?: string[];
  availableEngines?: Partial<Record<Tachyon.FuzzerEngine, boolean>>;
  nestedModal?: boolean;
  onApplyStrategy?: (
    engine: Tachyon.FuzzerEngine,
    args: string,
    strategy: Tachyon.FuzzerStrategyResult,
  ) => void | Promise<void>;
}

function normalizeCustomTargetsInput(
  raw: string,
):
  | { ok: true; normalized: string; count: number }
  | { ok: false; error: string } {
  const parts = String(raw || '')
    .split(/[\r\n,;\t ]+/)
    .map((s) => s.trim())
    .filter(Boolean);

  if (parts.length === 0) {
    return { ok: false, error: _('Please enter at least one domain or URL') };
  }

  const normalizedList: string[] = [];
  const seen = new Set<string>();
  const forbiddenCharsRe = /[\s'"\\`$;&|<>()[\]{}]/;
  const hostRe =
    /^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$|^([0-9]{1,3}\.){3}[0-9]{1,3}$/;

  for (const rawTok of parts) {
    const cleaned = rawTok.replace(/^\*\./, '').replace(/^\.+/, '');
    if (!cleaned || forbiddenCharsRe.test(cleaned)) {
      return {
        ok: false,
        error: `${_('Invalid target domain or URL')}: ${rawTok}`,
      };
    }

    let candidate = '';
    const protoMatch = cleaned.match(/^(https?|udp):\/\/(.+)$/i);
    if (protoMatch) {
      const scheme = protoMatch[1].toLowerCase();
      const rest = protoMatch[2];
      const hp = rest.match(/^([^/:]+)(?::([0-9]{1,5}))?(\/.*)?$/);
      if (!hp || !hostRe.test(hp[1])) {
        return {
          ok: false,
          error: `${_('Invalid target domain or URL')}: ${rawTok}`,
        };
      }
      if (hp[2]) {
        const port = Number(hp[2]);
        if (!Number.isInteger(port) || port < 1 || port > 65535) {
          return {
            ok: false,
            error: `${_('Invalid target domain or URL')}: ${rawTok}`,
          };
        }
      }
      candidate = `${scheme}://${rest}`;
    } else {
      if (cleaned.includes('://')) {
        return {
          ok: false,
          error: `${_('Invalid target domain or URL')}: ${rawTok}`,
        };
      }
      const bare = cleaned.match(/^([^/:]+)(?::([0-9]{1,5}))?(\/.*)?$/);
      if (!bare || !hostRe.test(bare[1])) {
        return {
          ok: false,
          error: `${_('Invalid target domain or URL')}: ${rawTok}`,
        };
      }
      const portStr = bare[2] || '';
      if (portStr) {
        const port = Number(portStr);
        if (!Number.isInteger(port) || port < 1 || port > 65535) {
          return {
            ok: false,
            error: `${_('Invalid target domain or URL')}: ${rawTok}`,
          };
        }
      }
      const pathPart = bare[3] || '';
      candidate = `https://${bare[1]}${portStr ? `:${portStr}` : ''}${pathPart}`;
    }

    if (!seen.has(candidate)) {
      seen.add(candidate);
      normalizedList.push(candidate);
    }
  }

  return {
    ok: true,
    normalized: normalizedList.join('\n'),
    count: normalizedList.length,
  };
}

export function renderStrategyFuzzerModal(
  ruleNames: Array<string | FuzzerRuleSection> = [],
  options: FuzzerModalOptions = {},
) {
  const normalizedRules: FuzzerRuleSection[] = ruleNames.map((r) =>
    typeof r === 'string' ? { id: r, label: r } : r,
  );
  let pollingInterval: ReturnType<typeof setInterval> | null = null;
  let isPolling = false;
  let availableEngines: Record<Tachyon.FuzzerEngine, boolean> = {
    desync:
      typeof options.availableEngines?.desync === 'boolean'
        ? options.availableEngines.desync
        : true,
  };
  const isEngineAvailable = (): boolean => Boolean(availableEngines.desync);

  // Modal State
  let activeTab: 'benchmark' | 'patterns' | 'custom' | 'ai' | 'history' =
    'benchmark';
  const selectedEngine: Tachyon.FuzzerEngine = 'desync';
  const initialCustomList = (options.initialCustomDomains || [])
    .map((d) => String(d || '').trim())
    .filter(Boolean);
  let selectedTarget: Tachyon.FuzzerTarget =
    initialCustomList.length > 0 ? 'custom' : 'youtube_suite';
  let customUrl = initialCustomList.join('\n');
  let selectedRuleSection = options.initialRuleSection || '';
  let userChangedRuleSection = Boolean(options.initialRuleSection);
  let selectedMode: Tachyon.FuzzerMode = 'presets';
  let selectedTimeout = 2700;
  let isRunning = false;
  let currentState: Tachyon.FuzzerState | null = null;
  let resultFilter: 'all' | 'success' | 'fast' = 'all';
  let autoApplyEnabled = false;
  let autoAppliedJobId: string | null = null;
  let stoppedManually = false;
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  let currentDpiDetection: Tachyon.FuzzerDpiDetection | null = null;
  let startBtnRef: HTMLElement | null = null;
  let updateUseSectionDomainsBtnFn: (() => void) | null = null;

  // Patterns Config State
  let patternsConfig: Tachyon.FuzzerPatternsConfig = {
    desync: {
      modes: ['fake_split', 'tlsrec', 'disorder', 'split', 'fake', 'oob'],
      split_poses: ['midsld', 'sni', 1, 2],
      fake_ttls: [3, 4, 5, 6, 8],
      fake_snis: ['www.google.com', 'dl.google.com', 'ya.ru'],
      repeats: [1, 2, 3, 4],
      split_delays: [1, 2, 3],
      udp_fakes: [true, false],
    },
    custom_strategies: [],
  };

  const modalContainer = E('div', {
    class: 'tachyon_fuzzer_modal tachyon-strategy-fuzzer-modal',
    style:
      'display: flex; flex-direction: column; gap: 14px; width: 100%; box-sizing: border-box;',
  });

  // ── Tab Bar Navigation ────────────────────────────────────────────────────
  const tabButtons: Record<string, HTMLElement> = {};

  const createTabButton = (
    id: 'benchmark' | 'patterns' | 'custom' | 'ai' | 'history',
    iconRenderer: (size?: number) => SVGElement,
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
      [iconRenderer(14), E('span', {}, label)],
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
        'display: flex; gap: 8px; border-bottom: 1px solid var(--tachyon-border-subtle, var(--border-color-medium, rgba(128,128,128,0.2))); padding-bottom: 10px; flex-wrap: wrap;',
    },
    [
      createTabButton('benchmark', renderZapIcon, _('Benchmark & Test')),
      createTabButton('patterns', renderWrenchIcon, _('Pattern Builder')),
      createTabButton('custom', renderPlusIcon, _('My Strategies')),
      createTabButton('ai', renderBrainIcon, _('AI Doctor RAG')),
      createTabButton('history', renderFileTextIcon, _('History')),
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
    tabContentHistory.style.display = activeTab === 'history' ? 'flex' : 'none';

    if (activeTab === 'patterns') renderPatternsTab();
    if (activeTab === 'custom') renderCustomTab();
    if (activeTab === 'history') renderHistoryTab();
  };

  // ═════════════════════════════════════════════════════════════════════════════
  // TAB 1: BENCHMARK & RUN
  // ═════════════════════════════════════════════════════════════════════════════

  const controlsGrid = E('div', {
    style:
      'display: grid; grid-template-columns: 1fr 1fr; gap: 12px 16px; align-items: start;',
  });

  const selectStyle = 'width: 100%; height: 36px; font-size: 13px;';
  const labelStyle =
    'font-size: 11px; font-weight: 600; color: var(--tachyon-text-secondary, var(--text-color-medium, #52525b)); letter-spacing: 0.02em;';
  const groupStyle = 'display: flex; flex-direction: column; gap: 5px;';

  // Rule Apply Target Select & Dynamic Filter
  const ruleSelect = E('select', {
    class: 'cbi-input-select',
    style: selectStyle,
  });

  const dpiActions = ['desync'];

  const getApplicableRules = (engine: Tachyon.FuzzerEngine) => {
    const eligible = normalizedRules.filter((r) => {
      if (!r.id || r.id === 'global' || r.id === 'default' || r.isGlobal) {
        return false;
      }
      if (r.action !== undefined) {
        return dpiActions.includes(r.action);
      }
      return true;
    });
    const exact = eligible.filter((r) => r.action === engine);
    const otherDpi = eligible.filter(
      (r) => r.action !== undefined && r.action !== engine,
    );
    const untyped = eligible.filter((r) => r.action === undefined);
    return [...exact, ...otherDpi, ...untyped];
  };

  const selectedTargetSet = new Set<string>(
    initialCustomList.length > 0 ? ['custom'] : ['youtube_suite'],
  );
  const targetCheckboxes = new Map<string, HTMLInputElement>();

  const populateRuleSelect = (autoMatchTarget = false) => {
    const applicable = getApplicableRules(selectedEngine);
    (ruleSelect as HTMLSelectElement).replaceChildren();

    if (applicable.length === 0) {
      const emptyOpt = E(
        'option',
        { value: '', disabled: true, selected: true },
        _('No applicable rule sections found'),
      );
      ruleSelect.appendChild(emptyOpt);
      selectedRuleSection = '';
      (ruleSelect as HTMLSelectElement).value = '';
    } else {
      if (autoMatchTarget && !userChangedRuleSection) {
        const targetKeywords = Array.from(selectedTargetSet)
          .map((t) => t.replace(/_suite$/, '').toLowerCase())
          .filter((k) => k && k !== 'custom');
        for (const kw of targetKeywords) {
          const found = applicable.find(
            (r) =>
              r.id.toLowerCase().includes(kw) ||
              r.label.toLowerCase().includes(kw),
          );
          if (found) {
            selectedRuleSection = found.id;
            break;
          }
        }
      }
      let matchedCurrent = false;
      applicable.forEach((r, idx) => {
        const actionTag = r.action ? ` [${r.action}]` : '';
        const isSelected = selectedRuleSection
          ? r.id === selectedRuleSection
          : idx === 0;
        if (isSelected) {
          matchedCurrent = true;
          selectedRuleSection = r.id;
        }
        const opt = E(
          'option',
          isSelected ? { value: r.id, selected: true } : { value: r.id },
          `${r.label}${actionTag}`,
        );
        ruleSelect.appendChild(opt);
      });
      if (!matchedCurrent && applicable.length > 0) {
        selectedRuleSection = applicable[0].id;
      }
      (ruleSelect as HTMLSelectElement).value = selectedRuleSection;
    }
    if (updateUseSectionDomainsBtnFn) {
      updateUseSectionDomainsBtnFn();
    }
  };

  populateRuleSelect(true);

  ruleSelect.addEventListener('change', () => {
    userChangedRuleSection = true;
    selectedRuleSection = (ruleSelect as HTMLSelectElement).value;
    if (updateUseSectionDomainsBtnFn) {
      updateUseSectionDomainsBtnFn();
    }
  });

  const syncEngineAvailability = () => {
    if (startBtnRef && !isRunning) {
      (startBtnRef as HTMLButtonElement).disabled = !isEngineAvailable();
    }
    populateRuleSelect();
  };

  syncEngineAvailability();

  // 2. Target Multi-Select Checkboxes (allows selecting multiple suites at once, e.g. YouTube + Discord + CS2)
  const targetSuiteOptions: Array<{ value: string; label: string }> = [
    {
      value: 'youtube_suite',
      label: _('YouTube (Web + 4K Stream + CDN)'),
    },
    {
      value: 'discord_suite',
      label: _('Discord (Gateway + Voice + CDN)'),
    },
    {
      value: 'cs2_faceit_suite',
      label: _('CS2 / Faceit / Cybershoke (Web + API + UDP)'),
    },
    {
      value: 'gaming_udp_suite',
      label: _('Gaming & Voice UDP (STUN + Source)'),
    },
    {
      value: 'twitch_suite',
      label: _('Twitch (Live Stream + HLS CDN)'),
    },
    {
      value: 'twitter_suite',
      label: _('X / Twitter (API + Media CDN)'),
    },
    {
      value: 'chatgpt_suite',
      label: _('ChatGPT / OpenAI Suite'),
    },
    {
      value: 'instagram_suite',
      label: _('Instagram / Meta (Web + CDN)'),
    },
    {
      value: 'telegram_suite',
      label: _('Telegram (Web + Bot API)'),
    },
    {
      value: 'rutracker_suite',
      label: _('RuTracker Suite'),
    },
    {
      value: 'quic_http3',
      label: _('QUIC / HTTP/3 (UDP 443)'),
    },
    {
      value: 'custom',
      label: _('Custom Target URL(s)...'),
    },
  ];

  const customUrlInput = E(
    'textarea',
    {
      class: 'cbi-input-text',
      placeholder:
        'youtube.com\ndiscord.com, example.org:8443/path\nhttps://www.faceit.com\nudp://stun.l.google.com:19302',
      rows: 3,
      style: `width: 100%; display: ${
        selectedTargetSet.has('custom') ? 'block' : 'none'
      }; margin-top: 4px; resize: vertical; min-height: 64px; padding: 8px 10px; font-size: 12px; font-family: monospace; line-height: 1.5; border-radius: 4px; box-sizing: border-box; background: var(--tachyon-bg-card-elevated, var(--background-color-low, rgba(128,128,128,0.08))); border: 1px solid var(--tachyon-border-subtle, var(--border-color-medium, rgba(128,128,128,0.2))); color: var(--tachyon-text-main, var(--text-color-high, inherit));`,
    },
    customUrl,
  );
  if (customUrl) {
    (customUrlInput as HTMLTextAreaElement).value = customUrl;
  }

  const syncSelectedTargets = () => {
    if (selectedTargetSet.size === 0) {
      selectedTargetSet.add('youtube_suite');
      const ytCb = targetCheckboxes.get('youtube_suite');
      if (ytCb) ytCb.checked = true;
    }
    selectedTarget = Array.from(selectedTargetSet).join(
      ',',
    ) as Tachyon.FuzzerTarget;
    (customUrlInput as HTMLElement).style.display = selectedTargetSet.has(
      'custom',
    )
      ? 'block'
      : 'none';
    if (!userChangedRuleSection) {
      populateRuleSelect(true);
    }
  };

  const applyQuickTargetPreset = (keys: string[]) => {
    selectedTargetSet.clear();
    keys.forEach((k) => selectedTargetSet.add(k));
    targetCheckboxes.forEach((cb, key) => {
      cb.checked = selectedTargetSet.has(key);
    });
    syncSelectedTargets();
  };

  const quickTargetBar = E(
    'div',
    {
      style:
        'display: flex; flex-wrap: wrap; gap: 6px; align-items: center; margin-bottom: 2px;',
    },
    [
      E('span', { style: 'font-size: 11px; opacity: 0.7;' }, _('Quick combo:')),
      (() => {
        const btn = E(
          'button',
          {
            type: 'button',
            class: 'cbi-button cbi-button-neutral',
            style: 'padding: 2px 8px; font-size: 11px; border-radius: 4px;',
          },
          _('YouTube + Discord + CS2'),
        );
        btn.addEventListener('click', () =>
          applyQuickTargetPreset([
            'youtube_suite',
            'discord_suite',
            'cs2_faceit_suite',
          ]),
        );
        return btn;
      })(),
      (() => {
        const btn = E(
          'button',
          {
            type: 'button',
            class: 'cbi-button cbi-button-neutral',
            style: 'padding: 2px 8px; font-size: 11px; border-radius: 4px;',
          },
          _('CS2 / Faceit + Discord (Games + UDP)'),
        );
        btn.addEventListener('click', () =>
          applyQuickTargetPreset(['cs2_faceit_suite', 'discord_suite']),
        );
        return btn;
      })(),
      (() => {
        const btn = E(
          'button',
          {
            type: 'button',
            class: 'cbi-button cbi-button-neutral',
            style: 'padding: 2px 8px; font-size: 11px; border-radius: 4px;',
          },
          _('YouTube Only'),
        );
        btn.addEventListener('click', () =>
          applyQuickTargetPreset(['youtube_suite']),
        );
        return btn;
      })(),
    ],
  );

  const targetCheckboxGrid = E(
    'div',
    {
      style:
        'display: grid; grid-template-columns: repeat(auto-fill, minmax(230px, 1fr)); gap: 6px 10px; padding: 8px 10px; border-radius: 6px; background: var(--tachyon-bg-card-elevated, var(--background-color-low, rgba(128,128,128,0.06))); border: 1px solid var(--tachyon-border-subtle, var(--border-color-medium, rgba(128,128,128,0.18)));',
    },
    targetSuiteOptions.map((opt) => {
      const cb = E('input', {
        type: 'checkbox',
        checked: selectedTargetSet.has(opt.value) || undefined,
        style: 'margin: 0; cursor: pointer;',
      }) as HTMLInputElement;
      cb.checked = selectedTargetSet.has(opt.value);
      targetCheckboxes.set(opt.value, cb);
      cb.addEventListener('change', () => {
        if (cb.checked) {
          if (
            opt.value === 'custom' &&
            selectedTargetSet.has('youtube_suite')
          ) {
            selectedTargetSet.delete('youtube_suite');
            const ytCb = targetCheckboxes.get('youtube_suite');
            if (ytCb) ytCb.checked = false;
          }
          selectedTargetSet.add(opt.value);
        } else {
          selectedTargetSet.delete(opt.value);
        }
        syncSelectedTargets();
      });
      return E(
        'label',
        {
          style:
            'display: flex; align-items: center; gap: 7px; font-size: 12px; cursor: pointer; user-select: none; line-height: 1.3;',
        },
        [cb, E('span', {}, opt.label)],
      );
    }),
  );

  customUrlInput.addEventListener('input', () => {
    customUrl = (customUrlInput as HTMLTextAreaElement).value.trim();
  });

  const useSectionDomainsBtn = E(
    'button',
    {
      type: 'button',
      class: 'cbi-button cbi-button-neutral',
      style:
        'display: none; align-self: flex-start; margin-top: 4px; padding: 3px 10px; font-size: 11px; border-radius: 4px;',
    },
    _('Use domains from section'),
  );

  updateUseSectionDomainsBtnFn = () => {
    const activeRule = normalizedRules.find(
      (r) => r.id === selectedRuleSection,
    );
    const hasDomains = Boolean(
      activeRule?.domains && activeRule.domains.length > 0,
    );
    (useSectionDomainsBtn as HTMLElement).style.display = hasDomains
      ? 'inline-flex'
      : 'none';
  };
  updateUseSectionDomainsBtnFn();

  useSectionDomainsBtn.addEventListener('click', () => {
    const activeRule = normalizedRules.find(
      (r) => r.id === selectedRuleSection,
    );
    if (!activeRule?.domains || activeRule.domains.length === 0) return;
    const joined = activeRule.domains.join('\n');
    (customUrlInput as HTMLTextAreaElement).value = joined;
    customUrl = joined;
    selectedTargetSet.delete('youtube_suite');
    const ytCb = targetCheckboxes.get('youtube_suite');
    if (ytCb) ytCb.checked = false;
    selectedTargetSet.add('custom');
    const customCb = targetCheckboxes.get('custom');
    if (customCb) customCb.checked = true;
    syncSelectedTargets();
  });

  const targetGroup = E(
    'div',
    { style: `${groupStyle} grid-column: 1 / -1;` },
    [
      E(
        'div',
        {
          style:
            'display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 6px;',
        },
        [
          E(
            'label',
            { style: labelStyle },
            _(
              'Target Services / Suites (select one or multiple for unified strategy)',
            ),
          ),
          quickTargetBar,
        ],
      ),
      targetCheckboxGrid,
      useSectionDomainsBtn,
      customUrlInput,
    ],
  );

  // 3. Search Mode Select
  const modeSelect = E(
    'select',
    { class: 'cbi-input-select', style: selectStyle },
    [
      E(
        'option',
        { value: 'presets', selected: true },
        _('Quick Benchmark (Presets ~30+)'),
      ),
      E(
        'option',
        { value: 'adaptive' },
        _('Adaptive Smart Fuzzing (Genetic / Prior Seeds)'),
      ),
      E(
        'option',
        { value: 'combinatorial' },
        _('Combinatorial Deep Fuzzing (~150-300+)'),
      ),
      E('option', { value: 'custom' }, _('My Custom Strategies Only')),
    ],
  );
  modeSelect.addEventListener('change', () => {
    selectedMode = (modeSelect as HTMLSelectElement)
      .value as Tachyon.FuzzerMode;
  });

  const modeGroup = E('div', { style: groupStyle }, [
    E('label', { style: labelStyle }, _('Search Mode')),
    modeSelect,
  ]);

  // 4. Timeout Select
  const timeoutSelect = E(
    'select',
    { class: 'cbi-input-select', style: selectStyle },
    [
      E('option', { value: '900' }, _('15 min — Quick')),
      E('option', { value: '1800' }, _('30 min — Standard')),
      E(
        'option',
        { value: '2700', selected: true },
        _('45 min — Deep (Recommended)'),
      ),
      E('option', { value: '3600' }, _('60 min — Exhaustive')),
      E('option', { value: '0' }, _('Unlimited — Wait for all tests')),
    ],
  );
  timeoutSelect.addEventListener('change', () => {
    selectedTimeout = parseInt((timeoutSelect as HTMLSelectElement).value, 10);
  });

  const timeoutGroup = E('div', { style: groupStyle }, [
    E('label', { style: labelStyle }, _('Benchmark Timeout')),
    timeoutSelect,
  ]);

  // 5. Rule Apply Target Group
  const hideSectionPicker =
    Boolean(options.onApplyStrategy) && normalizedRules.length === 0;

  const ruleGroup = E(
    'div',
    {
      style: hideSectionPicker
        ? `${groupStyle} display: none;`
        : `${groupStyle} grid-column: 1 / -1;`,
    },
    [E('label', { style: labelStyle }, _('Apply Strategy To')), ruleSelect],
  );

  controlsGrid.append(modeGroup, timeoutGroup, ruleGroup, targetGroup);

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
      style: hideSectionPicker
        ? 'display: none;'
        : 'display: flex; align-items: center; padding: 6px 0 2px 0; grid-column: 1 / -1; gap: 8px;',
    },
    [
      E(
        'div',
        {
          style:
            'font-size: 12px; cursor: pointer; display: flex; align-items: center; gap: 6px; color: var(--tachyon-text-secondary, var(--text-color-medium, #52525b));',
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
      'display: none; padding: 10px 14px; border-radius: 6px; font-size: 12px; line-height: 1.4; box-sizing: border-box;',
  });

  // Progress Bar
  const progressContainer = E(
    'div',
    {
      style:
        'display: none; flex-direction: column; gap: 6px; padding: 10px 14px; background: var(--tachyon-bg-card-elevated, var(--background-color-low, rgba(128,128,128,0.08))); border-radius: 6px; border: 1px solid var(--tachyon-border-subtle, var(--border-color-medium, rgba(128,128,128,0.18))); min-height: 62px; box-sizing: border-box;',
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
            {
              id: 'tachyon-fuzzer-status-text',
              style: 'display: inline-flex; align-items: center; gap: 6px;',
            },
            _('Benchmarking in progress...'),
          ),
          E('span', { id: 'tachyon-fuzzer-progress-pct' }, '0%'),
        ],
      ),
      E(
        'div',
        {
          style:
            'width: 100%; height: 6px; background: rgba(128,128,128,0.2); border-radius: 3px; overflow: hidden;',
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
    text: _('Apply Best Match'),
    classNames: ['cbi-button-save'],
    disabled: true,
    onClick: () => handleApplyBest(),
  });
  applyBestBtn.id = 'tachyon-fuzzer-apply-best-btn';

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
              style:
                'padding: 2px 10px; font-size: 11px; display: inline-flex; align-items: center; gap: 4px;',
            },
            [renderCheckIcon(12), E('span', {}, _('Working only'))],
          );
          const bFast = E(
            'button',
            {
              type: 'button',
              class: 'cbi-button cbi-button-neutral',
              style:
                'padding: 2px 10px; font-size: 11px; display: inline-flex; align-items: center; gap: 4px;',
            },
            [renderZapIcon(12), E('span', {}, _('Fast (>1MB/s)'))],
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
      'max-height: 380px; overflow-y: auto; overflow-x: hidden; border: 1px solid rgba(255, 255, 255, 0.08); border-radius: 6px; width: 100%; box-sizing: border-box; background: #121215;',
  });

  const tableEl = E(
    'table',
    {
      class: 'table cbi-section-table',
      style:
        'width: 100%; table-layout: fixed; word-break: break-word; margin: 0; font-size: 12px; text-align: left; border-collapse: collapse;',
    },
    [
      E(
        'thead',
        {
          class: 'cbi-section-table-titles',
          style:
            'background: #16161a; color: #a1a1aa; position: sticky; top: 0; z-index: 2; border-bottom: 1px solid rgba(255, 255, 255, 0.08);',
        },
        [
          E('tr', { class: 'cbi-section-table-titles' }, [
            E(
              'th',
              {
                class: 'cbi-section-table-cell',
                style: 'padding: 8px 6px; width: 5%;',
              },
              '#',
            ),
            E(
              'th',
              { class: 'cbi-section-table-cell', style: 'padding: 8px 10px;' },
              _('Strategy & Parameters'),
            ),
            E(
              'th',
              {
                class: 'cbi-section-table-cell',
                style: 'padding: 8px 6px; width: 18%;',
              },
              _('Status / Suite'),
            ),
            E(
              'th',
              {
                class: 'cbi-section-table-cell',
                style: 'padding: 8px 6px; width: 9%;',
              },
              _('TTFB'),
            ),
            E(
              'th',
              {
                class: 'cbi-section-table-cell',
                style: 'padding: 8px 6px; width: 9%;',
              },
              _('Speed'),
            ),
            E(
              'th',
              {
                class: 'cbi-section-table-cell',
                style: 'padding: 8px 6px; width: 7%;',
              },
              _('Score'),
            ),
            E(
              'th',
              {
                class: 'cbi-section-table-cell',
                style: 'padding: 8px 6px; width: 10%; text-align: center;',
              },
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
              colSpan: 7,
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

  let nestedOverlayEl: HTMLElement | null = null;
  let onEscKey: ((e: KeyboardEvent) => void) | null = null;

  const closeModal = () => {
    isDisposed = true;
    stopPolling();
    if (onEscKey && typeof document !== 'undefined') {
      document.removeEventListener('keydown', onEscKey);
      onEscKey = null;
    }
    if (options.nestedModal) {
      if (nestedOverlayEl) {
        nestedOverlayEl.remove();
        nestedOverlayEl = null;
      }
    } else if (typeof ui?.hideModal === 'function') {
      ui.hideModal();
    }
  };

  // Footer Actions for Benchmark
  const startBtn = renderButton({
    icon: () => renderZapIcon(14),
    text: _('Start Benchmark'),
    classNames: ['cbi-button-action'],
    disabled: !isEngineAvailable(),
    onClick: () => handleToggleRun(),
  });
  startBtnRef = startBtn;

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
        onClick: () => closeModal(),
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
      placeholder: _('+ add'),
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
            'display: inline-flex; align-items: center; gap: 4px; padding: 2px 8px; background: var(--tachyon-bg-card-elevated, var(--background-color-low, rgba(128,128,128,0.1))); border: 1px solid var(--tachyon-border-subtle, var(--border-color-medium, rgba(128,128,128,0.2))); border-radius: 4px; font-size: 11px; font-family: monospace;',
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

    const cardsToShow: HTMLElement[] = [];
    const patternCardStyle =
      'padding: 12px; background: #121215; border-radius: 6px; border: 1px solid rgba(255, 255, 255, 0.08); display: flex; flex-direction: column; gap: 10px;';

    if (availableEngines.desync) {
      if (!patternsConfig.desync) {
        patternsConfig.desync = {
          modes: ['fake_split', 'tlsrec', 'disorder', 'split', 'fake', 'oob'],
          split_poses: ['midsld', 'sni', 1, 2],
          fake_ttls: [3, 4, 5, 6, 8],
          fake_snis: ['www.google.com', 'dl.google.com', 'ya.ru'],
          repeats: [1, 2, 3, 4],
          split_delays: [1, 2, 3],
          udp_fakes: [true, false],
        };
      }
      const ds = patternsConfig.desync;
      cardsToShow.push(
        E('div', { style: patternCardStyle }, [
          E(
            'div',
            {
              style:
                'font-size: 13px; font-weight: 600; display: flex; align-items: center; gap: 6px;',
            },
            [
              renderZapIcon(14),
              _('Native Desync (tachyon-core) Matrix Patterns'),
            ],
          ),
          renderChipGroup(
            _('Desync Modes (--mode)'),
            ds.modes,
            (v) => ds.modes.push(v),
            (i) => ds.modes.splice(i, 1),
          ),
          renderChipGroup(
            _('Split Positions (--split-pos)'),
            ds.split_poses,
            (v) =>
              ds.split_poses.push(
                v === 'midsld' || v === 'sni' ? v : Number(v) || 1,
              ),
            (i) => ds.split_poses.splice(i, 1),
          ),
          renderChipGroup(
            _('Fake TTLs (--fake-ttl)'),
            ds.fake_ttls,
            (v) => ds.fake_ttls.push(Number(v) || 3),
            (i) => ds.fake_ttls.splice(i, 1),
          ),
          renderChipGroup(
            _('Fake SNI Hosts (--fake-sni)'),
            ds.fake_snis,
            (v) => ds.fake_snis.push(v),
            (i) => ds.fake_snis.splice(i, 1),
          ),
          renderChipGroup(
            _('Fake Repeats (--repeats)'),
            ds.repeats,
            (v) => ds.repeats.push(Number(v) || 2),
            (i) => ds.repeats.splice(i, 1),
          ),
          renderChipGroup(
            _('Split Delays ms (--split-delay)'),
            ds.split_delays,
            (v) => ds.split_delays.push(Number(v) || 1),
            (i) => ds.split_delays.splice(i, 1),
          ),
        ]),
      );
    }

    const patternsFooter = E(
      'div',
      {
        style:
          'display: flex; justify-content: space-between; align-items: center; padding-top: 6px;',
      },
      [
        renderButton({
          text: _('Save Custom Patterns'),
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
          text: _('Reset to Factory Defaults'),
          classNames: ['cbi-button-neutral'],
          onClick: async () => {
            const res = await TachyonShellMethods.resetFuzzerPatterns();
            if (res.success && res.data?.patterns) {
              patternsConfig = {
                ...patternsConfig,
                ...res.data.patterns,
              };
              renderPatternsTab();
              showToast(_('Patterns reset to defaults!'), 'success');
            }
          },
        }),
      ],
    );

    if (cardsToShow.length === 0) {
      tabContentPatterns.append(
        E(
          'div',
          {
            style:
              'padding: 20px; text-align: center; opacity: 0.7; font-size: 12px;',
          },
          _('tachyon-core binary is not installed on the router'),
        ),
      );
      return;
    }

    tabContentPatterns.append(...cardsToShow, patternsFooter);
  };

  // ═════════════════════════════════════════════════════════════════════════════
  // TAB 3: CUSTOM STRATEGIES
  // ═════════════════════════════════════════════════════════════════════════════

  const renderCustomTab = () => {
    tabContentCustom.replaceChildren();

    const coreInstalled = isEngineAvailable();

    const nameInput = E('input', {
      type: 'text',
      class: 'cbi-input-text',
      placeholder: _('Strategy Name'),
      style: 'flex: 1 1 180px; min-width: 140px;',
    });
    const argsInput = E('input', {
      type: 'text',
      class: 'cbi-input-text',
      placeholder: '--mode=fake_split --split-pos=midsld --fake-ttl=4',
      style: 'flex: 2 1 240px; min-width: 180px; font-family: monospace;',
    });

    const addBtn = renderButton({
      text: _('+ Add Strategy'),
      classNames: ['cbi-button-action'],
      disabled: !coreInstalled,
      onClick: async () => {
        const name = (nameInput as HTMLInputElement).value.trim();
        const args = (argsInput as HTMLInputElement).value.trim();
        if (!coreInstalled) {
          showToast(
            _('tachyon-core binary is not installed on the router'),
            'error',
          );
          return;
        }
        if (!name || !args) {
          showToast(_('Please specify strategy name and arguments'), 'error');
          return;
        }

        patternsConfig.custom_strategies =
          patternsConfig.custom_strategies || [];
        patternsConfig.custom_strategies.push({
          id: `custom_${Date.now()}`,
          name,
          engine: selectedEngine,
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
          'padding: 12px; background: var(--tachyon-bg-card-elevated, var(--background-color-low, rgba(128,128,128,0.06))); border-radius: 6px; border: 1px solid var(--tachyon-border-subtle, var(--border-color-medium, rgba(128,128,128,0.18))); display: flex; flex-direction: column; gap: 8px;',
      },
      [
        E(
          'div',
          { style: 'font-size: 12px; font-weight: 600;' },
          _('Add Custom Strategy'),
        ),
        E(
          'div',
          {
            style:
              'display: flex; gap: 8px; flex-wrap: wrap; align-items: center;',
          },
          [nameInput, argsInput, addBtn],
        ),
      ],
    );

    const customList = patternsConfig.custom_strategies || [];
    const listCard = E(
      'div',
      {
        style:
          'border: 1px solid rgba(255, 255, 255, 0.08); border-radius: 6px; overflow: hidden; background: #121215;',
      },
      [
        E(
          'table',
          {
            class: 'table',
            style:
              'width: 100%; margin: 0; font-size: 12px; table-layout: fixed; word-break: break-word;',
          },
          [
            E('thead', {}, [
              E('tr', {}, [
                E('th', { style: 'padding: 8px;' }, _('Name')),
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
                          colSpan: 3,
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
    style: 'flex: 1 1 240px; min-width: 180px; font-size: 12px;',
  });

  const aiSynthesizeBtn = renderButton({
    icon: () => renderBrainIcon(14),
    text: _('Synthesize with AI'),
    classNames: ['cbi-button-action'],
    onClick: () => handleAiSynthesize(),
  });

  const aiAnalysisContainer = E(
    'div',
    {
      id: 'tachyon-fuzzer-ai-analysis',
      style:
        'display: none; padding: 12px; background: #141418; border: 1px solid rgba(59, 130, 246, 0.25); border-radius: 4px; font-size: 12px; line-height: 1.4;',
    },
    [
      E(
        'div',
        {
          style:
            'font-weight: 600; margin-bottom: 6px; display: flex; align-items: center; gap: 6px;',
        },
        [
          renderBrainIcon(16),
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
        'padding: 14px; background: #121215; border-radius: 6px; border: 1px solid rgba(255, 255, 255, 0.08); display: flex; flex-direction: column; gap: 12px;',
    },
    [
      E(
        'div',
        {
          style:
            'font-size: 13px; font-weight: 600; display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap; gap: 6px;',
        },
        [
          E(
            'span',
            { style: 'display: inline-flex; align-items: center; gap: 6px;' },
            [renderBrainIcon(16), E('span', {}, _('AI Strategy Synthesizer'))],
          ),
          E(
            'span',
            { style: 'font-size: 11px; opacity: 0.6; font-weight: normal;' },
            _('RAG Knowledge Base + Live Route Probe Context'),
          ),
        ],
      ),
      E(
        'div',
        { style: 'font-size: 12px; opacity: 0.8;' },
        _(
          'Automatically runs a diagnostic probe against the target service, evaluates transit packet filtering behavior, and synthesizes 3-5 custom desync profiles.',
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
          {
            style:
              'font-size: 13px; font-weight: 600; display: flex; align-items: center; gap: 6px;',
          },
          [renderFileTextIcon(14), _('Benchmark History')],
        ),
        E('div', { style: 'display: flex; gap: 8px;' }, [
          renderButton({
            text: _('Refresh'),
            classNames: ['cbi-button-neutral'],
            onClick: () => renderHistoryTab(),
          }),
          renderButton({
            text: _('Clear History'),
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
        'border: 1px solid rgba(255, 255, 255, 0.08); border-radius: 6px; overflow: hidden; background: #121215;',
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
            class: 'table cbi-section-table',
            style:
              'width: 100%; margin: 0; font-size: 12px; table-layout: fixed; word-break: break-word;',
          },
          [
            E('thead', { class: 'cbi-section-table-titles' }, [
              E('tr', { class: 'cbi-section-table-titles' }, [
                E(
                  'th',
                  { class: 'cbi-section-table-cell', style: 'padding: 8px;' },
                  _('Date'),
                ),
                E(
                  'th',
                  { class: 'cbi-section-table-cell', style: 'padding: 8px;' },
                  _('Target'),
                ),
                E(
                  'th',
                  { class: 'cbi-section-table-cell', style: 'padding: 8px;' },
                  _('DPI Type'),
                ),
                E(
                  'th',
                  { class: 'cbi-section-table-cell', style: 'padding: 8px;' },
                  _('Best Strategy'),
                ),
                E(
                  'th',
                  {
                    class: 'cbi-section-table-cell',
                    style: 'padding: 8px; width: 60px;',
                  },
                  _('Score'),
                ),
                E(
                  'th',
                  {
                    class: 'cbi-section-table-cell',
                    style: 'padding: 8px; width: 70px;',
                  },
                  _('Working'),
                ),
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

                return E('tr', { class: 'cbi-section-table-row' }, [
                  E(
                    'td',
                    { class: 'cbi-section-table-cell', style: 'padding: 8px;' },
                    dateStr,
                  ),
                  E(
                    'td',
                    { class: 'cbi-section-table-cell', style: 'padding: 8px;' },
                    entry.target,
                  ),
                  E(
                    'td',
                    { class: 'cbi-section-table-cell', style: 'padding: 8px;' },
                    dpiType,
                  ),
                  E(
                    'td',
                    {
                      class: 'cbi-section-table-cell',
                      style:
                        'padding: 8px; font-size: 11px; max-width: 200px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;',
                    },
                    bestName,
                  ),
                  E(
                    'td',
                    {
                      class: 'cbi-section-table-cell',
                      style: 'padding: 8px; font-weight: 600;',
                    },
                    bestScore,
                  ),
                  E(
                    'td',
                    { class: 'cbi-section-table-cell', style: 'padding: 8px;' },
                    working,
                  ),
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
      const emptyMsg = state.running
        ? _('Running benchmarks...')
        : state.error
          ? E(
              'span',
              {
                style:
                  'display: inline-flex; align-items: center; justify-content: center; gap: 6px;',
              },
              [renderAlertTriangleIcon(14), state.error],
            )
          : _('No strategies match the active filter.');
      tbody.appendChild(
        E(
          'tr',
          {},
          E(
            'td',
            {
              colSpan: 7,
              style: 'padding: 24px; text-align: center; opacity: 0.75;',
            },
            emptyMsg,
          ),
        ),
      );
      return;
    }

    list.forEach((item, idx) => {
      const isBest = state.best_strategy && state.best_strategy.id === item.id;

      const nameChildren: (HTMLElement | string)[] = [E('span', {}, item.name)];
      if (item.source && item.source !== 'tachyon') {
        nameChildren.push(
          E(
            'span',
            {
              style:
                'font-size: 9px; margin-left: 6px; padding: 1px 5px; border-radius: 3px; ' +
                'background: rgba(128,128,128,0.12); opacity: 0.75; font-family: monospace;',
              title: _('Strategy preset source'),
            },
            item.source,
          ),
        );
      }
      if (item.badge) {
        nameChildren.push(
          E(
            'span',
            {
              style: `font-size: 10px; margin-left: 6px; font-weight: 600; color: ${
                isBest ? '#28a745' : '#17a2b8'
              };`,
            },
            item.badge,
          ),
        );
      }

      const statusChildren: (HTMLElement | string)[] = [
        E(
          'span',
          {
            class: `badge ${item.success ? 'badge-success' : 'badge-danger'}`,
            style: 'font-size: 10px; padding: 2px 6px; display: inline-block;',
          },
          item.success ? `HTTP ${item.http_code}` : 'DROP',
        ),
      ];

      if (item.data_verified) {
        statusChildren.push(
          E(
            'span',
            {
              class: 'badge badge-success',
              style:
                'font-size: 9px; padding: 2px 5px; margin-left: 4px; display: inline-flex; align-items: center; gap: 3px; font-weight: 500;',
              title: _(
                'Data transfer verified: streamed >= 32KB without throttling or disconnect',
              ),
            },
            [renderCheckIcon(10), _('32KB Streamed')],
          ),
        );
      } else if (item.dpi_verdict === 'throttled_16k') {
        statusChildren.push(
          E(
            'span',
            {
              class: 'badge badge-danger',
              style:
                'font-size: 9px; padding: 2px 5px; margin-left: 4px; display: inline-flex; align-items: center; gap: 3px; font-weight: 500;',
              title: _(
                'Transit throttling: stream cut off after ~16KB payload transfer',
              ),
            },
            [renderXIcon(10), _('Throttled at 16KB')],
          ),
        );
      } else if (item.dpi_verdict === 'server_fakes') {
        statusChildren.push(
          E(
            'span',
            {
              class: 'badge badge-warning',
              style:
                'font-size: 9px; padding: 2px 5px; margin-left: 4px; display: inline-flex; align-items: center; gap: 3px; font-weight: 500;',
              title: _(
                'Fake packets reached remote server (HTTP 400 Bad Request)',
              ),
            },
            [renderAlertTriangleIcon(10), _('Server received fakes')],
          ),
        );
      }

      if (item.verified) {
        statusChildren.push(
          E(
            'div',
            { style: 'font-size: 10px; opacity: 0.85; margin-top: 2px;' },
            [
              E(
                'span',
                {
                  class: `badge ${
                    item.confidence === 'high'
                      ? 'badge-success'
                      : item.confidence === 'medium'
                        ? 'badge-warning'
                        : 'badge-neutral'
                  }`,
                  style: 'font-size: 9px; padding: 1px 4px; margin-right: 4px;',
                },
                item.confidence ? item.confidence.toUpperCase() : 'VERIFIED',
              ),
              E(
                'span',
                {},
                `${item.stability_pct ?? 100}% ` + _('stability (3x)'),
              ),
            ],
          ),
        );
      }

      const passedEp =
        item.passed_endpoints !== undefined
          ? item.passed_endpoints
          : item.sub_probes
            ? item.sub_probes.filter((p) => p.success).length
            : undefined;
      const totalEp =
        item.total_endpoints !== undefined
          ? item.total_endpoints
          : item.sub_probes?.length;

      if (totalEp !== undefined && totalEp > 1) {
        statusChildren.push(
          E(
            'div',
            { style: 'font-size: 10px; opacity: 0.78; margin-top: 2px;' },
            `${passedEp ?? 0}/${totalEp} ` + _('endpoints OK'),
          ),
        );
      }
      if (item.sub_probes && item.sub_probes.length > 1) {
        statusChildren.push(
          E(
            'div',
            {
              style:
                'display: flex; flex-wrap: wrap; gap: 3px; margin-top: 3px; max-width: 240px;',
            },
            item.sub_probes.map((sp, spIdx) => {
              const namePart = sp.target_name || `#${spIdx + 1}`;
              const ttfbPart =
                sp.success && sp.ttfb_ms ? ` ${sp.ttfb_ms}ms` : '';
              return E(
                'span',
                {
                  style: `font-size: 9px; padding: 1px 4px; border-radius: 3px; font-family: monospace; background: ${
                    sp.success
                      ? 'rgba(40, 167, 69, 0.14)'
                      : 'rgba(220, 53, 69, 0.14)'
                  }; color: ${
                    sp.success
                      ? 'var(--success-color-medium, #218838)'
                      : 'var(--error-color-medium, #c82333)'
                  };`,
                  title: sp.error || '',
                },
                `${namePart}: ${sp.success ? `OK${ttfbPart}` : 'DROP'}`,
              );
            }),
          ),
        );
      }

      if (!item.success && item.error) {
        statusChildren.push(
          E(
            'div',
            {
              style:
                'font-size: 10px; color: var(--error-color-medium, #dc3545); opacity: 0.85; margin-top: 2px; max-width: 220px; word-break: break-word;',
              title: item.error,
            },
            item.error,
          ),
        );
      }

      const tr = E(
        'tr',
        {
          class: `cbi-section-table-row ${isBest ? 'cbi-rowstyle-1' : 'cbi-rowstyle-2'}`,
          style: `border-bottom: 1px solid var(--tachyon-border-subtle, var(--border-color-low, rgba(128,128,128,0.12))); ${
            isBest
              ? 'background: var(--background-color-high, rgba(40, 167, 69, 0.08));'
              : ''
          }`,
        },
        [
          E(
            'td',
            { class: 'cbi-section-table-cell', style: 'padding: 8px 10px;' },
            String(idx + 1),
          ),
          E(
            'td',
            { class: 'cbi-section-table-cell', style: 'padding: 8px 10px;' },
            [
              E('div', { style: 'font-weight: 600;' }, nameChildren),
              E(
                'div',
                {
                  style:
                    'font-size: 10px; opacity: 0.7; font-family: monospace; word-break: break-all; margin-top: 2px;',
                },
                item.args,
              ),
            ],
          ),
          E(
            'td',
            { class: 'cbi-section-table-cell', style: 'padding: 8px 10px;' },
            E('div', {}, statusChildren),
          ),
          E(
            'td',
            { class: 'cbi-section-table-cell', style: 'padding: 8px 10px;' },
            item.success
              ? [
                  E('div', {}, `${item.ttfb_ms}ms`),
                  item.jitter_ms !== undefined &&
                  item.jitter_ms !== null &&
                  item.jitter_ms > 0
                    ? E(
                        'div',
                        { style: 'font-size: 10px; opacity: 0.65;' },
                        `±${item.jitter_ms}ms jitter`,
                      )
                    : '',
                ]
              : '—',
          ),
          E(
            'td',
            { class: 'cbi-section-table-cell', style: 'padding: 8px 10px;' },
            item.success
              ? [
                  E('div', {}, `${(item.speed_kbps / 1024).toFixed(1)}MB/s`),
                  item.data_bytes && item.data_bytes > 0
                    ? E(
                        'div',
                        { style: 'font-size: 10px; opacity: 0.65;' },
                        `${(item.data_bytes / 1024).toFixed(1)} KB`,
                      )
                    : '',
                ]
              : '—',
          ),
          E(
            'td',
            {
              class: 'cbi-section-table-cell',
              style: 'padding: 8px 10px; font-weight: 600;',
            },
            item.success ? String(item.score) : '0',
          ),
          E(
            'td',
            {
              class: 'cbi-section-table-cell',
              style: 'padding: 8px 10px; text-align: center;',
            },
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
    const applyBestBtnEl =
      document.getElementById('tachyon-fuzzer-apply-best-btn') || applyBestBtn;

    if (progressContainer) {
      const showProgress = Boolean(
        state.running ||
          state.results?.length ||
          state.error ||
          state.finished_at > 0,
      );
      progressContainer.style.display = showProgress ? 'flex' : 'none';
      if (showProgress) {
        progressContainer.style.minHeight = '62px';
      }
    }

    if (pctText) pctText.innerText = `${state.progress_pct}%`;
    if (progressBar) progressBar.style.width = `${state.progress_pct}%`;

    const workingResults = state.results?.filter((r) => r.success) || [];
    const bestStrategy = state.best_strategy || workingResults[0] || null;

    if (statusText) {
      if (state.running) {
        if (state.phase === 'detecting_dpi') {
          statusText.replaceChildren(
            renderHourglassIcon(14),
            document.createTextNode(
              ' ' + _('Analyzing transit route behavior...'),
            ),
          );
        } else if (state.stage === 2 || state.phase === 'verification') {
          statusText.replaceChildren(
            renderShieldIcon(14),
            document.createTextNode(
              ` ${_('Stage 2: Stability Verification')} (${state.progress_pct}%)...`,
            ),
          );
        } else {
          statusText.replaceChildren(
            renderZapIcon(14),
            document.createTextNode(
              ` ${_('Stage 1: Exploration Scan')} (${state.current_index} / ${state.total_strategies})...`,
            ),
          );
        }
      } else if (
        state.finished_at > 0 ||
        state.results?.length ||
        state.error
      ) {
        if (bestStrategy || workingResults.length > 0) {
          if (state.error) {
            statusText.replaceChildren(
              renderCircleStopIcon(14),
              document.createTextNode(
                ` ${_('Benchmark stopped')}. ${_('Found')} ${workingResults.length} ${_('working strategies')}.`,
              ),
            );
          } else {
            statusText.replaceChildren(
              renderCheckIcon(14),
              document.createTextNode(
                ' ' + _('Benchmark completed! Optimal strategy identified.'),
              ),
            );
          }
        } else {
          statusText.replaceChildren(
            renderAlertTriangleIcon(14),
            document.createTextNode(
              state.error
                ? ` ${_('Benchmark stopped')}: ${state.error}`
                : ' ' +
                    _(
                      'Benchmark completed. No working desync profile found for this target.',
                    ),
            ),
          );
        }
      }
    }

    if (currentStratEl) {
      if (state.running && state.current_strategy) {
        currentStratEl.innerText = `${_('Testing:')} [${state.current_strategy.name}] -> ${state.current_strategy.args}`;
      } else {
        currentStratEl.innerText = '';
      }
    }

    if (applyBestBtnEl) {
      (applyBestBtnEl as HTMLButtonElement).disabled = !bestStrategy;
      applyBestBtnEl.classList.toggle(
        'tachyon-partial-button--disabled',
        !bestStrategy,
      );
    }
  };

  // ── Polling & Execution Logic ─────────────────────────────────────────────
  let lastRenderedCount = 0;
  let lastRenderedFinishedAt = 0;
  let lastRenderedError = '';
  let pollEpoch = 0;
  let activeJobId: string | null = null;
  let isDisposed = false;
  let hasMounted = false;

  const pollStatus = async () => {
    if (modalContainer.isConnected) {
      hasMounted = true;
    }
    if (isDisposed || (hasMounted && !modalContainer.isConnected)) {
      stopPolling();
      return;
    }
    if (isPolling) return;
    isPolling = true;
    const myEpoch = pollEpoch;
    try {
      const res = await TachyonShellMethods.getFuzzerStatus();
      if (myEpoch !== pollEpoch) {
        return;
      }
      if (isDisposed || (hasMounted && !modalContainer.isConnected)) {
        stopPolling();
        return;
      }
      if (res.success && res.data) {
        if (
          activeJobId &&
          res.data.job_id &&
          res.data.job_id !== activeJobId &&
          !res.data.running
        ) {
          return;
        }
        if (res.data.running && res.data.job_id) {
          activeJobId = res.data.job_id;
        }
        currentState = res.data;
        isRunning = res.data.running;

        if (isRunning) {
          startBtn.replaceChildren(
            renderCircleStopIcon(14),
            document.createTextNode(' ' + _('Stop Benchmark')),
          );
          startBtn.className = 'cbi-button cbi-button-reset';
          (startBtn as HTMLButtonElement).disabled = false;
          if (!pollingInterval) {
            pollingInterval = setInterval(pollStatus, 1200);
          }
        } else {
          stopPolling();
          startBtn.replaceChildren(
            renderZapIcon(14),
            document.createTextNode(' ' + _('Start Benchmark')),
          );
          startBtn.className = 'cbi-button cbi-button-action';
          (startBtn as HTMLButtonElement).disabled = false;
        }

        updateProgressUI(res.data);

        if (res.data.dpi_detection) {
          currentDpiDetection = res.data.dpi_detection;
          updateDpiBanner(res.data.dpi_detection);
        }

        // Re-render results when new results arrive, benchmark finishes, or error state changes
        const resultCount = res.data.results?.length || 0;
        const finishedAt = res.data.finished_at || 0;
        const errStr = res.data.error || '';
        if (
          resultCount !== lastRenderedCount ||
          finishedAt !== lastRenderedFinishedAt ||
          errStr !== lastRenderedError
        ) {
          renderResults(res.data);
          lastRenderedCount = resultCount;
          lastRenderedFinishedAt = finishedAt;
          lastRenderedError = errStr;
        }

        if (!isRunning && !stoppedManually) {
          // Auto-apply best strategy only if benchmark completed 100%, without abort, and not already applied for this job
          if (
            !options.onApplyStrategy &&
            autoApplyEnabled &&
            Boolean(selectedRuleSection) &&
            currentState?.progress_pct === 100 &&
            !currentState?.aborted &&
            !currentState?.error &&
            currentState?.best_strategy &&
            currentState.job_id &&
            autoAppliedJobId !== currentState.job_id
          ) {
            autoAppliedJobId = currentState.job_id;
            try {
              const applyRes =
                await TachyonShellMethods.autoApplyFuzzerStrategy(
                  selectedRuleSection,
                );
              if (applyRes.success) {
                showToast(
                  `${_('Auto-applied best strategy')}: ${currentState.best_strategy.name}`,
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
      if (myEpoch === pollEpoch) {
        isPolling = false;
      }
    }
  };

  const startPolling = () => {
    stopPolling();
    pollingInterval = setInterval(pollStatus, 1200);
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

    const typeMeta: Record<
      string,
      { alertClass: string; iconRenderer: (size?: number) => SVGElement }
    > = {
      rst: {
        alertClass: 'danger',
        iconRenderer: (s = 14) => renderAlertTriangleIcon(s),
      },
      throttle: {
        alertClass: 'warning',
        iconRenderer: (s = 14) => renderAlertTriangleIcon(s),
      },
      dns_block: {
        alertClass: 'info',
        iconRenderer: (s = 14) => renderGlobeIcon(s),
      },
      ip_block: {
        alertClass: 'danger',
        iconRenderer: (s = 14) => renderXIcon(s),
      },
      unknown: {
        alertClass: 'notice',
        iconRenderer: (s = 14) => renderAlertTriangleIcon(s),
      },
      none: {
        alertClass: 'success',
        iconRenderer: (s = 14) => renderCheckIcon(s),
      },
    };

    const typeLabels: Record<string, string> = {
      rst: _('TCP Reset on Transit Node'),
      throttle: _('Stream Degradation / Throttling'),
      dns_block: _('DNS Resolution Filtering'),
      ip_block: _('IP Unreachable (TCP SYN Timeout)'),
      unknown: _('Unclassified Transit Filtering'),
      none: _('Direct Connectivity Verified'),
    };

    const getLocalizedDpiDetails = (
      det: Tachyon.FuzzerDpiDetection | null | undefined,
    ) => {
      if (!det) return '';
      switch (det.type) {
        case 'ip_block':
          return _(
            'TCP connect timed out before TLS handshake — endpoint is unreachable at the IP layer. Packet desync does not apply; route this domain via a proxy/tunnel outbound.',
          );
        case 'rst':
          return _(
            'Active TCP RST received on transit path during TLS ClientHello.',
          );
        case 'dns_block':
          return _(
            'DNS resolution failed or returned an invalid address on the upstream path.',
          );
        case 'throttle':
          return _(
            'Stream throughput degradation detected during payload transfer.',
          );
        case 'none':
          return _('Target endpoint reachable directly without packet desync.');
        default:
          return det.details || _('Analysis inconclusive.');
      }
    };

    const meta = typeMeta[detection.type] || typeMeta.unknown;
    const label = typeLabels[detection.type] || detection.type;

    banner.className = `alert-message ${meta.alertClass}`;
    banner.style.display = 'block';

    const headerLeft = E(
      'div',
      { style: 'display: inline-flex; align-items: center; gap: 6px;' },
      [
        meta.iconRenderer(14),
        E(
          'span',
          { style: 'font-weight: 600;' },
          `${_('Transit Path Diagnostics')}: ${label}`,
        ),
        E(
          'span',
          { style: 'opacity: 0.7; margin-left: 8px;' },
          `${detection.confidence}% ${_('confidence')}`,
        ),
      ],
    );

    const topRow = E(
      'div',
      {
        style:
          'display: flex; justify-content: space-between; align-items: start; flex-wrap: wrap; gap: 6px;',
      },
      [headerLeft],
    );

    const detailsEl = E(
      'div',
      { style: 'margin-top: 4px; opacity: 0.9; font-size: 11px;' },
      getLocalizedDpiDetails(detection),
    );

    const bannerChildren: HTMLElement[] = [topRow, detailsEl];

    if (detection.type === 'ip_block') {
      const ipNotice = E(
        'div',
        {
          class: 'alert-message danger',
          style:
            'margin-top: 8px; display: inline-flex; align-items: center; gap: 6px;',
        },
        [
          renderAlertTriangleIcon(14),
          E(
            'span',
            {},
            _(
              'IP-level filtering detected! The resource is unreachable at the network layer (no TCP SYN response). Packet desynchronization (Native Desync) cannot traverse an IP-level limit — configure proxy/VPN routing for this domain.',
            ),
          ),
        ],
      );
      bannerChildren.push(ipNotice);
    }

    banner.replaceChildren(...bannerChildren);
  };

  const handleToggleRun = async () => {
    if (isRunning) {
      stoppedManually = true;
      pollEpoch++;
      isPolling = false;
      stopPolling();
      (startBtn as HTMLButtonElement).disabled = true;
      startBtn.replaceChildren(
        renderHourglassIcon(14),
        document.createTextNode(' ' + _('Stopping...')),
      );
      await TachyonShellMethods.stopFuzzer();
      showToast(_('Benchmark stopped'), 'success');
      isRunning = false;
      activeJobId = null;
      await pollStatus();
      return;
    }

    if (!isEngineAvailable()) {
      showToast(
        _('tachyon-core binary is not installed on the router'),
        'error',
      );
      return;
    }

    if (selectedTargetSet.has('custom')) {
      const parsedTargets = normalizeCustomTargetsInput(
        (customUrlInput as HTMLTextAreaElement).value,
      );
      if (!parsedTargets.ok) {
        showToast(parsedTargets.error, 'error');
        return;
      }
      customUrl = parsedTargets.normalized;
      (customUrlInput as HTMLTextAreaElement).value = parsedTargets.normalized;
    }

    stoppedManually = false;
    pollEpoch++;
    isPolling = false;
    stopPolling();
    (startBtn as HTMLButtonElement).disabled = true;
    startBtn.replaceChildren(
      renderCircleStopIcon(14),
      document.createTextNode(' ' + _('Stop Benchmark')),
    );
    startBtn.className = 'cbi-button cbi-button-reset';

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
      statusTextEl.replaceChildren(
        renderZapIcon(14),
        document.createTextNode(
          ' ' + _('Initializing benchmark in sandbox...'),
        ),
      );
    if (progressBarEl) progressBarEl.style.width = '3%';
    if (currentStratEl)
      currentStratEl.innerText = _(
        'Preparing desync profiles and isolated tachyon-core sandbox...',
      );

    const tbody = document.getElementById('tachyon-fuzzer-results-tbody');
    if (tbody) {
      tbody.replaceChildren(
        E(
          'tr',
          {},
          E(
            'td',
            {
              colSpan: 7,
              style: 'padding: 24px; text-align: center; opacity: 0.85;',
            },
            [
              renderHourglassIcon(16),
              E(
                'span',
                { style: 'margin-left: 8px;' },
                _('Benchmarking desync profiles in isolated sandbox...'),
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
      selectedTimeout,
    );

    if (res.success) {
      showToast(_('Strategy benchmark started'), 'success');
      (startBtn as HTMLButtonElement).disabled = false;
      isRunning = true;
      activeJobId = res.data?.job_id || null;
      lastRenderedCount = -1;
      lastRenderedFinishedAt = -1;
      lastRenderedError = '';
      pollEpoch++;
      isPolling = false;
      startPolling();
    } else {
      // If the RPC/XHR call timed out, check if the benchmark actually started in the background
      const statusRes = await TachyonShellMethods.getFuzzerStatus().catch(
        () => null,
      );
      if (statusRes?.success && statusRes.data?.running) {
        showToast(_('Strategy benchmark started'), 'success');
        (startBtn as HTMLButtonElement).disabled = false;
        isRunning = true;
        activeJobId = statusRes.data.job_id || null;
        lastRenderedCount = -1;
        lastRenderedFinishedAt = -1;
        lastRenderedError = '';
        pollEpoch++;
        isPolling = false;
        startPolling();
        return;
      }
      const errMsg = !res.success ? res.error : _('Unknown error');
      showToast(`${_('Failed to start benchmark')}: ${errMsg}`, 'error');
      (startBtn as HTMLButtonElement).disabled = false;
      startBtn.replaceChildren(
        renderZapIcon(14),
        document.createTextNode(' ' + _('Start Benchmark')),
      );
      startBtn.className = 'cbi-button cbi-button-action';
      progressContainer.style.display = 'none';
    }
  };

  const handleAiSynthesize = async () => {
    if (!isEngineAvailable()) {
      showToast(
        _('tachyon-core binary is not installed on the router'),
        'error',
      );
      return;
    }
    if (selectedTargetSet.has('custom')) {
      const parsedTargets = normalizeCustomTargetsInput(
        (customUrlInput as HTMLTextAreaElement).value,
      );
      if (!parsedTargets.ok) {
        showToast(parsedTargets.error, 'error');
        return;
      }
      customUrl = parsedTargets.normalized;
      (customUrlInput as HTMLTextAreaElement).value = parsedTargets.normalized;
    }
    const userPrompt = (aiPromptInput as HTMLInputElement).value.trim();
    (aiSynthesizeBtn as HTMLButtonElement).disabled = true;
    aiSynthesizeBtn.replaceChildren(
      renderHourglassIcon(14),
      document.createTextNode(' ' + _('Synthesizing...')),
    );

    const analysisBox = document.getElementById('tachyon-fuzzer-ai-analysis');
    const analysisText = document.getElementById(
      'tachyon-fuzzer-ai-analysis-text',
    );
    if (analysisBox) analysisBox.style.display = 'none';

    try {
      showToast(_('Synthesizing custom desync profiles...'), 'success');
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

        stoppedManually = false;
        (startBtn as HTMLButtonElement).disabled = true;
        startBtn.replaceChildren(
          renderCircleStopIcon(14),
          document.createTextNode(' ' + _('Stop Benchmark')),
        );
        startBtn.className = 'cbi-button cbi-button-reset';

        const startRes = await TachyonShellMethods.startFuzzer(
          selectedEngine,
          selectedTarget,
          customUrl,
          selectedRuleSection,
          res.data.custom_file,
          'ai_custom',
          selectedTimeout,
        );

        if (startRes.success) {
          isRunning = true;
          activeJobId = startRes.data?.job_id || null;
          lastRenderedCount = -1;
          lastRenderedFinishedAt = -1;
          lastRenderedError = '';
          pollEpoch++;
          isPolling = false;
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
      aiSynthesizeBtn.replaceChildren(
        renderBrainIcon(14),
        document.createTextNode(' ' + _('Synthesize with AI')),
      );
    }
  };

  const handleApplySingle = async (item: Tachyon.FuzzerStrategyResult) => {
    if (options.onApplyStrategy) {
      await options.onApplyStrategy(item.engine, item.args, item);
      closeModal();
      return;
    }

    if (!selectedRuleSection && (ruleSelect as HTMLSelectElement).value) {
      selectedRuleSection = (ruleSelect as HTMLSelectElement).value;
    }
    if (!selectedRuleSection) {
      showToast(
        _('Please select an applicable rule section to apply this strategy'),
        'error',
      );
      return;
    }

    const targetRule = normalizedRules.find(
      (r) => r.id === selectedRuleSection,
    );
    if (
      targetRule &&
      targetRule.action &&
      targetRule.action !== item.engine &&
      !dpiActions.includes(targetRule.action)
    ) {
      showToast(
        `${_('Cannot apply')} ${item.engine} ${_('strategy to section configured for')} ${targetRule.action}`,
        'error',
      );
      return;
    }

    const res = await TachyonShellMethods.applyFuzzerStrategy(
      item.engine,
      item.args,
      selectedRuleSection,
    );
    if (res.success) {
      const targetLabel = targetRule?.label || selectedRuleSection;
      if (typeof ui?.addNotification === 'function') {
        ui.addNotification(
          _('Tachyon'),
          E(
            'p',
            {},
            `${_('Strategy applied successfully and service reloaded!')} (${item.name} -> ${targetLabel})`,
          ),
          'info',
        );
      } else {
        showToast(
          `${_('Applied')} "${item.name}" -> ${targetLabel}`,
          'success',
        );
      }
      closeModal();
      if (
        typeof window !== 'undefined' &&
        typeof window.location?.reload === 'function'
      ) {
        window.location.reload();
      }
    } else {
      const errMsg = !res.success && res.error ? `: ${res.error}` : '';
      showToast(`${_('Failed to apply strategy')}${errMsg}`, 'error');
    }
  };

  const handleApplyBest = async () => {
    const best =
      currentState?.best_strategy ||
      currentState?.results?.find((r) => r.success);
    if (!best) {
      showToast(_('No working strategy to apply'), 'error');
      return;
    }
    await handleApplySingle(best);
  };

  // Initial Data Fetch: verify installed engines & custom patterns
  TachyonShellMethods.getFuzzerStrategies()
    .then((res) => {
      if (res.success && res.data?.available_engines) {
        const av = res.data.available_engines;
        availableEngines = {
          desync: Boolean(av.desync ?? true),
        };
        syncEngineAvailability();
        if (activeTab === 'patterns') renderPatternsTab();
        if (activeTab === 'custom') renderCustomTab();
      }
    })
    .catch(() => {});

  TachyonShellMethods.getFuzzerPatterns()
    .then((res) => {
      if (res.success && res.data?.patterns) {
        patternsConfig = {
          ...patternsConfig,
          ...res.data.patterns,
        };
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

  if (options.nestedModal && typeof document !== 'undefined' && document.body) {
    const closeIconBtn = E(
      'button',
      {
        type: 'button',
        class: 'cbi-button cbi-button-neutral',
        style:
          'padding: 2px 10px; font-size: 16px; line-height: 1.2; cursor: pointer;',
      },
      '×',
    );
    closeIconBtn.addEventListener('click', () => closeModal());

    const dialogCard = E(
      'div',
      {
        style:
          'max-width: 980px; width: 100%; background: var(--tachyon-bg-card, var(--background-color-high, #fff)); color: var(--tachyon-text-main, var(--text-color-high, inherit)); border-radius: 10px; padding: 18px 20px; border: 1px solid var(--tachyon-border-subtle, var(--border-color-medium, rgba(128,128,128,0.22))); box-shadow: 0 16px 40px rgba(0, 0, 0, 0.35); box-sizing: border-box; display: flex; flex-direction: column; gap: 12px;',
      },
      [
        E(
          'div',
          {
            style:
              'display: flex; justify-content: space-between; align-items: center; padding-bottom: 10px; border-bottom: 1px solid var(--tachyon-border-subtle, var(--border-color-medium, rgba(128,128,128,0.2)));',
          },
          [
            E(
              'h4',
              { style: 'margin: 0; font-size: 16px; font-weight: 600;' },
              _('Strategy Fuzzer & Auto-Tuner'),
            ),
            closeIconBtn,
          ],
        ),
        modalContainer,
      ],
    );

    nestedOverlayEl = E(
      'div',
      {
        class: 'tachyon-nested-fuzzer-overlay',
        style:
          'position: fixed; inset: 0; z-index: 10050; background: rgba(0, 0, 0, 0.62); display: flex; align-items: flex-start; justify-content: center; padding: 24px 16px; overflow-y: auto; box-sizing: border-box;',
      },
      [dialogCard],
    );

    nestedOverlayEl.addEventListener('click', (ev: Event) => {
      if (ev.target === nestedOverlayEl) {
        closeModal();
      }
    });

    onEscKey = (ev: KeyboardEvent) => {
      if (ev.key === 'Escape') {
        closeModal();
      }
    };
    document.addEventListener('keydown', onEscKey);
    document.body.appendChild(nestedOverlayEl);
    pollStatus();
  } else {
    pollStatus();
    ui.showModal(_('Strategy Fuzzer & Auto-Tuner'), modalContainer);
  }
}
