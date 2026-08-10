import { TachyonShellMethods } from '../../../methods';
import { showToast } from '../../../../helpers/showToast';
import { Tachyon } from '../../../types';
import { getConfigSections } from '../../../methods/custom/getConfigSections';
import { TACHYON_UCI_PACKAGE } from '../../../../constants';

// ─── Types ───────────────────────────────────────────────────────────────────

interface AdvancedSettingsState {
  watchdogRunning: boolean;
  watchdogLoading: boolean;
  smartDetectEnabled: boolean;
  smartDetectSections: string[];
  allSectionNames: string[];
  deviceIpsPerSection: Record<string, string[]>;
  dnsTurboCache: boolean;
  agentApiToken: string;
  enableAiDoctor: boolean;
  aiDoctorProvider: string;
  aiDoctorApiKey: string;
  aiDoctorCustomUrl: string;
  aiWatchdog: {
    proxyHealthEnabled: boolean;
    proxyHealthInterval: string;
    proxyHealthFailThreshold: string;
    proxyHealthUrl: string;
    dnsContinuousEnabled: boolean;
    dnsInterval: string;
    reloadDedupEnabled: boolean;
    metricsEnabled: boolean;
    metricsRetentionHours: string;
    smartCooldownsEnabled: boolean;
    configValidationEnabled: boolean;
    gracefulDegradationEnabled: boolean;
    persistentSmartDetect: boolean;
    adaptiveIntervalsEnabled: boolean;
    anomalyDetectionEnabled: boolean;
    anomalyReconnectThreshold: string;
  };
  saving: boolean;
  loaded: boolean;
}

let _state: AdvancedSettingsState = {
  watchdogRunning: false,
  watchdogLoading: false,
  smartDetectEnabled: false,
  smartDetectSections: [],
  allSectionNames: [],
  deviceIpsPerSection: {},
  dnsTurboCache: false,
  agentApiToken: '',
  enableAiDoctor: false,
  aiDoctorProvider: 'openai',
  aiDoctorApiKey: '',
  aiDoctorCustomUrl: '',
  aiWatchdog: {
    proxyHealthEnabled: true,
    proxyHealthInterval: '30',
    proxyHealthFailThreshold: '3',
    proxyHealthUrl: 'https://cp.cloudflare.com/generate_204',
    dnsContinuousEnabled: true,
    dnsInterval: '60',
    reloadDedupEnabled: true,
    metricsEnabled: true,
    metricsRetentionHours: '24',
    smartCooldownsEnabled: true,
    configValidationEnabled: true,
    gracefulDegradationEnabled: true,
    persistentSmartDetect: true,
    adaptiveIntervalsEnabled: true,
    anomalyDetectionEnabled: true,
    anomalyReconnectThreshold: '10',
  },
  saving: false,
  loaded: false,
};

// ─── Rerender ────────────────────────────────────────────────────────────────

function rerender() {
  const el = document.getElementById('tachyon-advanced-settings');
  if (!el) return;
  const inner = document.getElementById('tachyon-advanced-settings-inner');
  if (!inner) return;
  const next = renderAdvancedSettingsBody(_state);
  inner.replaceChildren(...(Array.isArray(next) ? next : [next]));
}

// ─── Data loading ─────────────────────────────────────────────────────────────

export async function loadAdvancedSettingsState() {
  const sections = await getConfigSections();

  const settingsSec = sections.find((s) => s['.type'] === 'settings');
  const smartDetect = settingsSec?.smart_detect === '1';

  const raw = settingsSec?.smart_detect_sections;
  const smartDetectSections: string[] = Array.isArray(raw)
    ? raw
    : raw && typeof raw === 'string' && raw.trim()
      ? [raw.trim()]
      : [];

  const ruleSections = sections.filter(
    (s) =>
      s['.type'] === 'section' &&
      s.enabled !== '0' &&
      (s.action as string) !== 'bypass' &&
      (s.action as string) !== 'block' &&
      (s.action as string) !== 'dns',
  );
  const allSectionNames = ruleSections.map((s) => s['.name'] as string);

  const deviceIpsPerSection: Record<string, string[]> = {};
  for (const s of ruleSections) {
    const name = s['.name'] as string;
    const ips = s.fully_routed_ips;
    deviceIpsPerSection[name] = Array.isArray(ips)
      ? ips
      : ips && typeof ips === 'string' && ips.trim()
        ? [ips.trim()]
        : [];
  }

  const wdRes = await TachyonShellMethods.getWatchdogStatus();
  const watchdogRunning: boolean = wdRes.success
    ? Boolean((wdRes as { data: { running: boolean } }).data.running)
    : false;

  _state = {
    ..._state,
    watchdogRunning,
    smartDetectEnabled: smartDetect,
    smartDetectSections:
      smartDetectSections.length > 0
        ? smartDetectSections
        : allSectionNames.slice(0, 1),
    allSectionNames,
    deviceIpsPerSection,
    dnsTurboCache: settingsSec?.dns_turbo_cache === '1',
    agentApiToken:
      ((settingsSec as unknown as Record<string, unknown>)
        ?.agent_api_token as string) || '',
    enableAiDoctor:
      (settingsSec as unknown as Record<string, unknown>)?.enable_ai_doctor ===
      '1',
    aiDoctorProvider:
      ((settingsSec as unknown as Record<string, unknown>)
        ?.ai_doctor_provider as string) || 'openai',
    aiDoctorApiKey:
      ((settingsSec as unknown as Record<string, unknown>)
        ?.ai_doctor_api_key as string) || '',
    aiDoctorCustomUrl:
      ((settingsSec as unknown as Record<string, unknown>)
        ?.ai_doctor_custom_url as string) || '',
    aiWatchdog: {
      proxyHealthEnabled: settingsSec?.ai_proxy_health_enabled !== '0',
      proxyHealthInterval:
        (settingsSec?.ai_proxy_health_interval as string) || '30',
      proxyHealthFailThreshold:
        (settingsSec?.ai_proxy_health_fail_threshold as string) || '3',
      proxyHealthUrl:
        (settingsSec?.ai_proxy_health_url as string) ||
        'https://cp.cloudflare.com/generate_204',
      dnsContinuousEnabled: settingsSec?.ai_dns_continuous_enabled !== '0',
      dnsInterval: (settingsSec?.ai_dns_interval as string) || '60',
      reloadDedupEnabled: settingsSec?.ai_reload_dedup_enabled !== '0',
      metricsEnabled: settingsSec?.ai_metrics_enabled !== '0',
      metricsRetentionHours:
        (settingsSec?.ai_metrics_retention_hours as string) || '24',
      smartCooldownsEnabled: settingsSec?.ai_smart_cooldowns_enabled !== '0',
      configValidationEnabled:
        settingsSec?.ai_config_validation_enabled !== '0',
      gracefulDegradationEnabled:
        settingsSec?.ai_graceful_degradation_enabled !== '0',
      persistentSmartDetect: settingsSec?.ai_persistent_smart_detect !== '0',
      adaptiveIntervalsEnabled:
        settingsSec?.ai_adaptive_intervals_enabled !== '0',
      anomalyDetectionEnabled:
        settingsSec?.ai_anomaly_detection_enabled !== '0',
      anomalyReconnectThreshold:
        (settingsSec?.ai_anomaly_reconnect_threshold as string) || '10',
    },
    loaded: true,
  };
  rerender();
}

// ─── Actions ──────────────────────────────────────────────────────────────────

async function toggleWatchdog() {
  _state = { ..._state, watchdogLoading: true };
  rerender();
  if (_state.watchdogRunning) {
    await TachyonShellMethods.watchdogStop();
  } else {
    await TachyonShellMethods.watchdogStart();
  }
  const wdRes = await TachyonShellMethods.getWatchdogStatus();
  const running = wdRes.success
    ? (wdRes as { data: { running: boolean } }).data.running
    : _state.watchdogRunning;
  _state = { ..._state, watchdogRunning: running, watchdogLoading: false };
  rerender();
}

async function saveSmartDetect() {
  _state = { ..._state, saving: true };
  rerender();
  try {
    await TachyonShellMethods.uciRunCommand([
      'set',
      `${TACHYON_UCI_PACKAGE}.settings.smart_detect=${_state.smartDetectEnabled ? '1' : '0'}`,
    ]);
    await TachyonShellMethods.uciRunCommand([
      'delete',
      `${TACHYON_UCI_PACKAGE}.settings.smart_detect_sections`,
    ]);
    for (const sec of _state.smartDetectSections) {
      await TachyonShellMethods.uciRunCommand([
        'add_list',
        `${TACHYON_UCI_PACKAGE}.settings.smart_detect_sections=${sec}`,
      ]);
    }
    await TachyonShellMethods.uciRunCommand(['commit', TACHYON_UCI_PACKAGE]);
    showToast(_('Smart Detect settings saved'), 'success');
  } catch {
    showToast(_('Failed to save Smart Detect settings'), 'error');
  }
  _state = { ..._state, saving: false };
  rerender();
}

async function saveDeviceIps(sectionName: string, ipsText: string) {
  _state = { ..._state, saving: true };
  rerender();
  try {
    const ips = ipsText
      .split('\n')
      .map((l) => l.trim())
      .filter(Boolean);
    await TachyonShellMethods.uciRunCommand([
      'delete',
      `${TACHYON_UCI_PACKAGE}.${sectionName}.fully_routed_ips`,
    ]);
    for (const ip of ips) {
      await TachyonShellMethods.uciRunCommand([
        'add_list',
        `${TACHYON_UCI_PACKAGE}.${sectionName}.fully_routed_ips=${ip}`,
      ]);
    }
    await TachyonShellMethods.uciRunCommand(['commit', TACHYON_UCI_PACKAGE]);
    _state.deviceIpsPerSection[sectionName] = ips;
    showToast(_('Device IPs saved'), 'success');
    // Reload tachyon async so UI stays responsive
    void TachyonShellMethods.uciRunCommand([
      '-q',
      'commit',
      TACHYON_UCI_PACKAGE,
    ]);
  } catch {
    showToast(_('Failed to save device IPs'), 'error');
  }
  _state = { ..._state, saving: false };
  rerender();
}

async function saveDnsTurboCache(enabled: boolean) {
  _state = { ..._state, saving: true };
  rerender();
  try {
    await TachyonShellMethods.uciRunCommand([
      'set',
      `${TACHYON_UCI_PACKAGE}.settings.dns_turbo_cache=${enabled ? '1' : '0'}`,
    ]);
    await TachyonShellMethods.uciRunCommand(['commit', TACHYON_UCI_PACKAGE]);
    _state = { ..._state, dnsTurboCache: enabled };
    showToast(_('DNS Turbo Cache saved'), 'success');
  } catch {
    showToast(_('Failed to save DNS Turbo Cache'), 'error');
  }
  _state = { ..._state, saving: false };
  rerender();
}

async function saveAiWatchdogSettings() {
  _state = { ..._state, saving: true };
  rerender();
  try {
    const ai = _state.aiWatchdog;
    const cmds: string[][] = [
      [
        'set',
        `${TACHYON_UCI_PACKAGE}.settings.agent_api_token=${_state.agentApiToken}`,
      ],
      [
        'set',
        `${TACHYON_UCI_PACKAGE}.settings.enable_ai_doctor=${_state.enableAiDoctor ? '1' : '0'}`,
      ],
      [
        'set',
        `${TACHYON_UCI_PACKAGE}.settings.ai_doctor_provider=${_state.aiDoctorProvider}`,
      ],
      [
        'set',
        `${TACHYON_UCI_PACKAGE}.settings.ai_doctor_api_key=${_state.aiDoctorApiKey}`,
      ],
      [
        'set',
        `${TACHYON_UCI_PACKAGE}.settings.ai_doctor_custom_url=${_state.aiDoctorCustomUrl}`,
      ],
      [
        'set',
        `${TACHYON_UCI_PACKAGE}.settings.ai_proxy_health_enabled=${ai.proxyHealthEnabled ? '1' : '0'}`,
      ],
      [
        'set',
        `${TACHYON_UCI_PACKAGE}.settings.ai_proxy_health_interval=${ai.proxyHealthInterval}`,
      ],
      [
        'set',
        `${TACHYON_UCI_PACKAGE}.settings.ai_proxy_health_fail_threshold=${ai.proxyHealthFailThreshold}`,
      ],
      [
        'set',
        `${TACHYON_UCI_PACKAGE}.settings.ai_proxy_health_url=${ai.proxyHealthUrl}`,
      ],
      [
        'set',
        `${TACHYON_UCI_PACKAGE}.settings.ai_dns_continuous_enabled=${ai.dnsContinuousEnabled ? '1' : '0'}`,
      ],
      [
        'set',
        `${TACHYON_UCI_PACKAGE}.settings.ai_dns_interval=${ai.dnsInterval}`,
      ],
      [
        'set',
        `${TACHYON_UCI_PACKAGE}.settings.ai_reload_dedup_enabled=${ai.reloadDedupEnabled ? '1' : '0'}`,
      ],
      [
        'set',
        `${TACHYON_UCI_PACKAGE}.settings.ai_metrics_enabled=${ai.metricsEnabled ? '1' : '0'}`,
      ],
      [
        'set',
        `${TACHYON_UCI_PACKAGE}.settings.ai_metrics_retention_hours=${ai.metricsRetentionHours}`,
      ],
      [
        'set',
        `${TACHYON_UCI_PACKAGE}.settings.ai_smart_cooldowns_enabled=${ai.smartCooldownsEnabled ? '1' : '0'}`,
      ],
      [
        'set',
        `${TACHYON_UCI_PACKAGE}.settings.ai_config_validation_enabled=${ai.configValidationEnabled ? '1' : '0'}`,
      ],
      [
        'set',
        `${TACHYON_UCI_PACKAGE}.settings.ai_graceful_degradation_enabled=${ai.gracefulDegradationEnabled ? '1' : '0'}`,
      ],
      [
        'set',
        `${TACHYON_UCI_PACKAGE}.settings.ai_persistent_smart_detect=${ai.persistentSmartDetect ? '1' : '0'}`,
      ],
      [
        'set',
        `${TACHYON_UCI_PACKAGE}.settings.ai_adaptive_intervals_enabled=${ai.adaptiveIntervalsEnabled ? '1' : '0'}`,
      ],
      [
        'set',
        `${TACHYON_UCI_PACKAGE}.settings.ai_anomaly_detection_enabled=${ai.anomalyDetectionEnabled ? '1' : '0'}`,
      ],
      [
        'set',
        `${TACHYON_UCI_PACKAGE}.settings.ai_anomaly_reconnect_threshold=${ai.anomalyReconnectThreshold}`,
      ],
    ];
    for (const cmd of cmds) {
      await TachyonShellMethods.uciRunCommand(cmd);
    }
    await TachyonShellMethods.uciRunCommand(['commit', TACHYON_UCI_PACKAGE]);
    showToast(
      _('AI Watchdog settings saved. Restart watchdog to apply.'),
      'success',
    );
  } catch {
    showToast(_('Failed to save AI Watchdog settings'), 'error');
  }
  _state = { ..._state, saving: false };
  rerender();
}

function moveSectionUp(idx: number) {
  if (idx <= 0) return;
  const arr = [..._state.smartDetectSections];
  [arr[idx - 1], arr[idx]] = [arr[idx], arr[idx - 1]];
  _state = { ..._state, smartDetectSections: arr };
  rerender();
}

function moveSectionDown(idx: number) {
  const arr = [..._state.smartDetectSections];
  if (idx >= arr.length - 1) return;
  [arr[idx], arr[idx + 1]] = [arr[idx + 1], arr[idx]];
  _state = { ..._state, smartDetectSections: arr };
  rerender();
}

function toggleSectionInList(sectionName: string, checked: boolean) {
  let arr = [..._state.smartDetectSections];
  if (checked && !arr.includes(sectionName)) {
    arr.push(sectionName);
  } else if (!checked) {
    arr = arr.filter((s) => s !== sectionName);
  }
  _state = { ..._state, smartDetectSections: arr };
  rerender();
}

// ─── Render ───────────────────────────────────────────────────────────────────

function renderWatchdogSection(state: AdvancedSettingsState) {
  const { watchdogRunning, watchdogLoading } = state;

  return E('div', { class: 'tachyon_adv__section' }, [
    E('div', { class: 'tachyon_adv__section-header' }, [
      E('span', { class: 'tachyon_adv__section-icon' }, '🐕'),
      E('h3', { class: 'tachyon_adv__section-title' }, _('Watchdog')),
    ]),
    E('div', { class: 'tachyon_adv__row' }, [
      E('span', { class: 'tachyon_adv__label' }, _('Status')),
      E(
        'span',
        {
          class: watchdogRunning
            ? 'tachyon_adv__badge tachyon_adv__badge--ok'
            : 'tachyon_adv__badge tachyon_adv__badge--err',
        },
        watchdogRunning ? _('✔ Running') : _('✘ Stopped'),
      ),
      E(
        'button',
        {
          class: `btn cbi-button ${watchdogRunning ? 'cbi-button-negative' : 'cbi-button-action'} tachyon_adv__ctrl-btn`,
          type: 'button',
          disabled: watchdogLoading,
          onclick: () => void toggleWatchdog(),
        },
        watchdogLoading ? '…' : watchdogRunning ? _('⏹ Stop') : _('▶ Start'),
      ),
    ]),
  ]);
}

function renderDnsTurboCacheSection(state: AdvancedSettingsState) {
  const { dnsTurboCache, saving } = state;

  return E('div', { class: 'tachyon_adv__section' }, [
    E('div', { class: 'tachyon_adv__section-header' }, [
      E('span', { class: 'tachyon_adv__section-icon' }, '⚡'),
      E('h3', { class: 'tachyon_adv__section-title' }, _('DNS Turbo Cache')),
    ]),
    E(
      'p',
      { class: 'tachyon_adv__hint' },
      _(
        'Keeps FakeIP cache persistent across reboots and pre-resolves popular blocked domains on startup so first-visit latency is 0\u00a0ms.',
      ),
    ),
    E('div', { class: 'tachyon_adv__row' }, [
      E('label', { class: 'tachyon_adv__toggle' }, [
        E('input', {
          type: 'checkbox',
          checked: dnsTurboCache,
          onchange: (e: Event) => {
            const enabled = (e.target as HTMLInputElement).checked;
            void saveDnsTurboCache(enabled);
          },
        }),
        E('span', {}, _('Enable DNS Turbo Cache')),
      ]),
    ]),
    saving
      ? E('span', { class: 'tachyon_adv__hint' }, _('Saving…'))
      : E('span', {}),
  ]);
}

function renderAiWatchdogSection(state: AdvancedSettingsState) {
  const { aiWatchdog, saving, watchdogRunning } = state;

  const toggle = (key: keyof typeof aiWatchdog, label: string) =>
    E('div', { class: 'tachyon_adv__row' }, [
      E('label', { class: 'tachyon_adv__toggle' }, [
        E('input', {
          type: 'checkbox',
          checked: Boolean(aiWatchdog[key]),
          onchange: (e: Event) => {
            const val = (e.target as HTMLInputElement).checked;
            _state = {
              ..._state,
              aiWatchdog: { ..._state.aiWatchdog, [key]: val },
            };
            rerender();
          },
        }),
        E('span', {}, _(label)),
      ]),
    ]);

  const numInput = (
    key: keyof typeof aiWatchdog,
    label: string,
    hint: string,
    min: number,
  ) =>
    E('div', { class: 'tachyon_adv__row' }, [
      E('label', { class: 'tachyon_adv__label' }, _(label)),
      E('input', {
        type: 'number',
        class: 'cbi-input-text',
        value: aiWatchdog[key] as string,
        min: String(min),
        onchange: (e: Event) => {
          const val = (e.target as HTMLInputElement).value;
          _state = {
            ..._state,
            aiWatchdog: { ..._state.aiWatchdog, [key]: val },
          };
        },
      }),
      E('span', { class: 'tachyon_adv__hint' }, _(hint)),
    ]);

  const textInput = (key: keyof typeof aiWatchdog, label: string) =>
    E('div', { class: 'tachyon_adv__row' }, [
      E('label', { class: 'tachyon_adv__label' }, _(label)),
      E('input', {
        type: 'text',
        class: 'cbi-input-text',
        value: aiWatchdog[key] as string,
        style: 'width: 100%;',
        onchange: (e: Event) => {
          const val = (e.target as HTMLInputElement).value;
          _state = {
            ..._state,
            aiWatchdog: { ..._state.aiWatchdog, [key]: val },
          };
        },
      }),
    ]);

  return E('div', { class: 'tachyon_adv__section' }, [
    E('div', { class: 'tachyon_adv__section-header' }, [
      E('span', { class: 'tachyon_adv__section-icon' }, '🤖'),
      E('h3', { class: 'tachyon_adv__section-title' }, _('AI Watchdog')),
    ]),
    E(
      'p',
      { class: 'tachyon_adv__hint' },
      _('Advanced self-healing features. Requires Watchdog to be enabled.'),
    ),

    // Health Checks group
    E('div', { class: 'tachyon_adv__group' }, [
      E('h4', { class: 'tachyon_adv__group-title' }, _('Health Checks')),
      toggle('proxyHealthEnabled', 'Enable Proxy Health Monitor'),
      aiWatchdog.proxyHealthEnabled
        ? E('div', { class: 'tachyon_adv__subrows' }, [
            numInput(
              'proxyHealthInterval',
              'Check interval (s)',
              'Fast tier, 15-120s',
              15,
            ),
            numInput(
              'proxyHealthFailThreshold',
              'Fail threshold',
              'Consecutive fails before restart',
              1,
            ),
            textInput('proxyHealthUrl', 'Health Check URL'),
          ])
        : E('span', {}),
      toggle('dnsContinuousEnabled', 'Enable DNS Continuous Check'),
      aiWatchdog.dnsContinuousEnabled
        ? E('div', { class: 'tachyon_adv__subrows' }, [
            numInput('dnsInterval', 'DNS Check Interval (s)', '30-300s', 30),
          ])
        : E('span', {}),
    ]),

    // Protection group
    E('div', { class: 'tachyon_adv__group' }, [
      E('h4', { class: 'tachyon_adv__group-title' }, _('Protection')),
      toggle(
        'reloadDedupEnabled',
        'Firewall Reload Dedup (prevents connection drops)',
      ),
      toggle(
        'configValidationEnabled',
        'Config Validation (validates before restart)',
      ),
      toggle(
        'gracefulDegradationEnabled',
        'Graceful Degradation (skip failed checks, continue)',
      ),
    ]),

    // Monitoring group
    E('div', { class: 'tachyon_adv__group' }, [
      E(
        'h4',
        { class: 'tachyon_adv__group-title' },
        _('Monitoring & Analytics'),
      ),
      toggle('metricsEnabled', 'Health Metrics'),
      aiWatchdog.metricsEnabled
        ? E('div', { class: 'tachyon_adv__subrows' }, [
            numInput(
              'metricsRetentionHours',
              'Metrics Retention (hours)',
              '1-168h',
              1,
            ),
          ])
        : E('span', {}),
      toggle(
        'anomalyDetectionEnabled',
        'Anomaly Detection (reconnect frequency)',
      ),
      aiWatchdog.anomalyDetectionEnabled
        ? E('div', { class: 'tachyon_adv__subrows' }, [
            numInput(
              'anomalyReconnectThreshold',
              'Reconnect Threshold',
              'Max reconnects/hour',
              1,
            ),
          ])
        : E('span', {}),
    ]),

    // Optimization group
    E('div', { class: 'tachyon_adv__group' }, [
      E('h4', { class: 'tachyon_adv__group-title' }, _('Optimization')),
      toggle(
        'smartCooldownsEnabled',
        'Smart Cooldowns (15s/120s/300s tier intervals)',
      ),
      toggle(
        'adaptiveIntervalsEnabled',
        'Adaptive Intervals (longer when healthy)',
      ),
      toggle(
        'persistentSmartDetect',
        'Persistent Smart Detect (survive reboots)',
      ),
    ]),

    // AI Agent API group
    E('div', { class: 'tachyon_adv__group' }, [
      E(
        'h4',
        { class: 'tachyon_adv__group-title' },
        _('AI Agent REST API (12 Endpoints)'),
      ),
      E(
        'p',
        { class: 'tachyon_adv__hint' },
        _(
          'HTTP REST API for external AI agents (Claude, GPT, Open-WebUI) served at /cgi-bin/tachyon-agent/',
        ),
      ),
      E('div', { class: 'tachyon_adv__row' }, [
        E('label', { class: 'tachyon_adv__label' }, _('Bearer Auth Token')),
        E('div', { style: 'display: flex; gap: 8px; flex: 1;' }, [
          E('input', {
            type: 'text',
            class: 'cbi-input-text',
            value: state.agentApiToken,
            placeholder: _('Secret token for WRITE requests'),
            style: 'flex: 1;',
            onchange: (e: Event) => {
              const val = (e.target as HTMLInputElement).value;
              _state = { ..._state, agentApiToken: val.trim() };
            },
          }),
          E(
            'button',
            {
              class: 'btn cbi-button cbi-button-action',
              type: 'button',
              onclick: () => {
                const randomBytes = new Uint8Array(16);
                crypto.getRandomValues(randomBytes);
                const token = Array.from(randomBytes)
                  .map((b) => b.toString(16).padStart(2, '0'))
                  .join('');
                _state = { ..._state, agentApiToken: token };
                rerender();
              },
            },
            _('🔑 Generate'),
          ),
        ]),
      ]),
      E(
        'span',
        { class: 'tachyon_adv__hint' },
        _(
          'GET endpoints are open on LAN. POST endpoints require Authorization: Bearer <token>.',
        ),
      ),
    ]),

    // AI Doctor (ChatGPT / DeepSeek API) group
    E('div', { class: 'tachyon_adv__group' }, [
      E(
        'h4',
        { class: 'tachyon_adv__group-title' },
        _('AI Doctor (ChatGPT / DeepSeek API)'),
      ),
      E(
        'p',
        { class: 'tachyon_adv__hint' },
        _(
          'Connect ChatGPT, DeepSeek or local LLM to get automated diagnostic reports and intelligent root-cause analysis.',
        ),
      ),
      E('div', { class: 'tachyon_adv__row' }, [
        E('label', { class: 'tachyon_adv__toggle' }, [
          E('input', {
            type: 'checkbox',
            checked: state.enableAiDoctor,
            onchange: (e: Event) => {
              const enabled = (e.target as HTMLInputElement).checked;
              _state = { ..._state, enableAiDoctor: enabled };
              rerender();
            },
          }),
          E('span', {}, _('Enable AI Doctor (LLM Integration)')),
        ]),
      ]),
      state.enableAiDoctor
        ? E('div', { class: 'tachyon_adv__subrows' }, [
            E('div', { class: 'tachyon_adv__row' }, [
              E('label', { class: 'tachyon_adv__label' }, _('AI Provider')),
              E(
                'select',
                {
                  class: 'cbi-input-select',
                  onchange: (e: Event) => {
                    const val = (e.target as HTMLSelectElement).value;
                    _state = { ..._state, aiDoctorProvider: val };
                    rerender();
                  },
                },
                [
                  E(
                    'option',
                    {
                      value: 'openai',
                      selected: state.aiDoctorProvider === 'openai',
                    },
                    'OpenAI (ChatGPT)',
                  ),
                  E(
                    'option',
                    {
                      value: 'anthropic',
                      selected: state.aiDoctorProvider === 'anthropic',
                    },
                    'Anthropic (Claude API)',
                  ),
                  E(
                    'option',
                    {
                      value: 'deepseek',
                      selected: state.aiDoctorProvider === 'deepseek',
                    },
                    'DeepSeek API',
                  ),
                  E(
                    'option',
                    {
                      value: 'custom',
                      selected: state.aiDoctorProvider === 'custom',
                    },
                    'Custom OpenAI-Compatible API',
                  ),
                ],
              ),
            ]),
            E('div', { class: 'tachyon_adv__row' }, [
              E('label', { class: 'tachyon_adv__label' }, _('AI API Key')),
              E('input', {
                type: 'password',
                class: 'cbi-input-text',
                value: state.aiDoctorApiKey,
                placeholder: 'sk-...',
                style: 'width: 100%;',
                onchange: (e: Event) => {
                  const val = (e.target as HTMLInputElement).value;
                  _state = { ..._state, aiDoctorApiKey: val.trim() };
                },
              }),
            ]),
            state.aiDoctorProvider === 'custom'
              ? E('div', { class: 'tachyon_adv__row' }, [
                  E(
                    'label',
                    { class: 'tachyon_adv__label' },
                    _('Custom API Endpoint URL'),
                  ),
                  E('input', {
                    type: 'text',
                    class: 'cbi-input-text',
                    value: state.aiDoctorCustomUrl,
                    placeholder:
                      'https://openrouter.ai/api/v1/chat/completions',
                    style: 'width: 100%;',
                    onchange: (e: Event) => {
                      const val = (e.target as HTMLInputElement).value;
                      _state = { ..._state, aiDoctorCustomUrl: val.trim() };
                    },
                  }),
                ])
              : E('span', {}),
          ])
        : E('span', {}),
    ]),

    E(
      'button',
      {
        class: 'btn cbi-button cbi-button-save tachyon_adv__save-btn',
        type: 'button',
        disabled: saving || !watchdogRunning,
        onclick: () => void saveAiWatchdogSettings(),
      },
      saving
        ? _('Saving…')
        : watchdogRunning
          ? _('Save AI Watchdog Settings')
          : _('Start Watchdog first'),
    ),
  ]);
}

function renderSmartDetectSection(state: AdvancedSettingsState) {
  const { smartDetectEnabled, smartDetectSections, allSectionNames, saving } =
    state;
  const unselected = allSectionNames.filter(
    (s) => !smartDetectSections.includes(s),
  );

  const rows: Element[] = [];

  smartDetectSections.forEach((secName, idx) => {
    rows.push(
      E('div', { class: 'tachyon_adv__priority-row' }, [
        E('label', { class: 'tachyon_adv__priority-label' }, [
          E('input', {
            type: 'checkbox',
            checked: true,
            onchange: (e: Event) =>
              toggleSectionInList(
                secName,
                (e.target as HTMLInputElement).checked,
              ),
          }),
          E(
            'span',
            { class: 'tachyon_adv__priority-name' },
            `${idx + 1}. ${secName}`,
          ),
        ]),
        E('div', { class: 'tachyon_adv__arrows' }, [
          E(
            'button',
            {
              class: 'btn tachyon_adv__arrow',
              type: 'button',
              title: _('Move up'),
              disabled: idx === 0,
              onclick: () => moveSectionUp(idx),
            },
            '△',
          ),
          E(
            'button',
            {
              class: 'btn tachyon_adv__arrow',
              type: 'button',
              title: _('Move down'),
              disabled: idx === smartDetectSections.length - 1,
              onclick: () => moveSectionDown(idx),
            },
            '▽',
          ),
        ]),
      ]),
    );
  });

  unselected.forEach((secName) => {
    rows.push(
      E(
        'div',
        { class: 'tachyon_adv__priority-row tachyon_adv__priority-row--off' },
        [
          E('label', { class: 'tachyon_adv__priority-label' }, [
            E('input', {
              type: 'checkbox',
              checked: false,
              onchange: (e: Event) =>
                toggleSectionInList(
                  secName,
                  (e.target as HTMLInputElement).checked,
                ),
            }),
            E(
              'span',
              {
                class:
                  'tachyon_adv__priority-name tachyon_adv__priority-name--off',
              },
              secName,
            ),
          ]),
        ],
      ),
    );
  });

  return E('div', { class: 'tachyon_adv__section' }, [
    E('div', { class: 'tachyon_adv__section-header' }, [
      E('span', { class: 'tachyon_adv__section-icon' }, '🔍'),
      E('h3', { class: 'tachyon_adv__section-title' }, _('Smart Detect')),
    ]),
    E(
      'p',
      { class: 'tachyon_adv__hint' },
      _(
        'Auto-detects blocked domains from logs and adds them to the first section where they work via proxy.',
      ),
    ),
    E('div', { class: 'tachyon_adv__row' }, [
      E('label', { class: 'tachyon_adv__toggle' }, [
        E('input', {
          type: 'checkbox',
          checked: smartDetectEnabled,
          onchange: (e: Event) => {
            _state = {
              ..._state,
              smartDetectEnabled: (e.target as HTMLInputElement).checked,
            };
            rerender();
          },
        }),
        E('span', {}, _('Enable Smart Detect')),
      ]),
    ]),
    smartDetectEnabled && rows.length > 0
      ? E('div', { class: 'tachyon_adv__priority-list' }, [
          E(
            'p',
            { class: 'tachyon_adv__sub-hint' },
            _('Section test order (checked = active, drag rows with △▽):'),
          ),
          ...rows,
        ])
      : E('span', {}),
    E(
      'button',
      {
        class: 'btn cbi-button cbi-button-save tachyon_adv__save-btn',
        type: 'button',
        disabled: saving,
        onclick: () => void saveSmartDetect(),
      },
      saving ? _('Saving…') : _('Save Smart Detect Settings'),
    ),
  ]);
}

function renderDeviceRoutingSection(state: AdvancedSettingsState) {
  const { allSectionNames, deviceIpsPerSection, saving } = state;

  if (allSectionNames.length === 0) {
    return E('div', { class: 'tachyon_adv__section' }, [
      E('div', { class: 'tachyon_adv__section-header' }, [
        E('span', { class: 'tachyon_adv__section-icon' }, '🖥'),
        E(
          'h3',
          { class: 'tachyon_adv__section-title' },
          _('Per-Device Routing'),
        ),
      ]),
      E(
        'p',
        { class: 'tachyon_adv__hint' },
        _('No active routing sections found.'),
      ),
    ]);
  }

  const editors = allSectionNames.map((secName) => {
    const currentIps = (deviceIpsPerSection[secName] || []).join('\n');
    const taId = `tachyon-device-ips-${secName}`;

    return E('div', { class: 'tachyon_adv__device-block' }, [
      E('div', { class: 'tachyon_adv__device-name' }, secName),
      E(
        'label',
        { class: 'tachyon_adv__device-label' },
        _('Device IPs (one per line):'),
      ),
      E(
        'textarea',
        {
          id: taId,
          class: 'cbi-input-textarea tachyon_adv__device-ta',
          rows: 3,
          placeholder: '192.168.1.100\n192.168.1.105',
        },
        currentIps,
      ),
      E(
        'button',
        {
          class: 'btn cbi-button cbi-button-save tachyon_adv__save-btn',
          type: 'button',
          disabled: saving,
          onclick: () => {
            const ta = document.getElementById(
              taId,
            ) as HTMLTextAreaElement | null;
            void saveDeviceIps(secName, ta ? ta.value : '');
          },
        },
        saving ? _('Saving…') : _('Save'),
      ),
    ]);
  });

  return E('div', { class: 'tachyon_adv__section' }, [
    E('div', { class: 'tachyon_adv__section-header' }, [
      E('span', { class: 'tachyon_adv__section-icon' }, '🖥'),
      E('h3', { class: 'tachyon_adv__section-title' }, _('Per-Device Routing')),
    ]),
    E(
      'p',
      { class: 'tachyon_adv__hint' },
      _(
        'Devices listed here are always routed through the assigned section, regardless of global rules.',
      ),
    ),
    ...editors,
  ]);
}

function renderAdvancedSettingsBody(state: AdvancedSettingsState) {
  if (!state.loaded) {
    return E('div', { class: 'tachyon_adv__loading' }, _('Loading…'));
  }

  return E('div', { class: 'tachyon_adv__body' }, [
    renderWatchdogSection(state),
    E('hr', { class: 'tachyon_adv__divider' }),
    renderAiWatchdogSection(state),
    E('hr', { class: 'tachyon_adv__divider' }),
    renderDnsTurboCacheSection(state),
    E('hr', { class: 'tachyon_adv__divider' }),
    renderSmartDetectSection(state),
    E('hr', { class: 'tachyon_adv__divider' }),
    renderDeviceRoutingSection(state),
  ]);
}

export function renderAdvancedSettingsPanel() {
  return E('div', { id: 'tachyon-advanced-settings', class: 'tachyon_adv' }, [
    E('details', { class: 'tachyon_adv__details' }, [
      E(
        'summary',
        { class: 'tachyon_adv__summary' },
        _('⚙ Advanced Settings'),
      ),
      E(
        'div',
        { id: 'tachyon-advanced-settings-inner', class: 'tachyon_adv__inner' },
        [renderAdvancedSettingsBody(_state)],
      ),
    ]),
  ]);
}
