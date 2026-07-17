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

  const settingsSec = sections.find(s => s['.type'] === 'settings');
  const smartDetect = settingsSec?.smart_detect === '1';

  const raw = settingsSec?.smart_detect_sections;
  const smartDetectSections: string[] = Array.isArray(raw)
    ? raw
    : raw && typeof raw === 'string' && raw.trim()
      ? [raw.trim()]
      : [];

  const ruleSections = sections.filter(
    s => s['.type'] === 'rule' && s.enabled !== '0',
  );
  const allSectionNames = ruleSections.map(s => s['.name'] as string);

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
  const watchdogRunning: boolean =
    wdRes.success
      ? Boolean((wdRes as { data: { running: boolean } }).data.running)
      : false;

  _state = {
    ..._state,
    watchdogRunning,
    smartDetectEnabled: smartDetect,
    smartDetectSections:
      smartDetectSections.length > 0 ? smartDetectSections : allSectionNames.slice(0, 1),
    allSectionNames,
    deviceIpsPerSection,
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
  const running =
    wdRes.success ? (wdRes as { data: { running: boolean } }).data.running : _state.watchdogRunning;
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
      .map(l => l.trim())
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
    void TachyonShellMethods.uciRunCommand(['-q', 'commit', TACHYON_UCI_PACKAGE]);
  } catch {
    showToast(_('Failed to save device IPs'), 'error');
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
    arr = arr.filter(s => s !== sectionName);
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

function renderSmartDetectSection(state: AdvancedSettingsState) {
  const { smartDetectEnabled, smartDetectSections, allSectionNames, saving } = state;
  const unselected = allSectionNames.filter(s => !smartDetectSections.includes(s));

  const rows: Element[] = [];

  smartDetectSections.forEach((secName, idx) => {
    rows.push(
      E('div', { class: 'tachyon_adv__priority-row' }, [
        E('label', { class: 'tachyon_adv__priority-label' }, [
          E('input', {
            type: 'checkbox',
            checked: true,
            onchange: (e: Event) =>
              toggleSectionInList(secName, (e.target as HTMLInputElement).checked),
          }),
          E('span', { class: 'tachyon_adv__priority-name' }, `${idx + 1}. ${secName}`),
        ]),
        E('div', { class: 'tachyon_adv__arrows' }, [
          E('button', {
            class: 'btn tachyon_adv__arrow',
            type: 'button',
            title: _('Move up'),
            disabled: idx === 0,
            onclick: () => moveSectionUp(idx),
          }, '△'),
          E('button', {
            class: 'btn tachyon_adv__arrow',
            type: 'button',
            title: _('Move down'),
            disabled: idx === smartDetectSections.length - 1,
            onclick: () => moveSectionDown(idx),
          }, '▽'),
        ]),
      ]),
    );
  });

  unselected.forEach(secName => {
    rows.push(
      E('div', { class: 'tachyon_adv__priority-row tachyon_adv__priority-row--off' }, [
        E('label', { class: 'tachyon_adv__priority-label' }, [
          E('input', {
            type: 'checkbox',
            checked: false,
            onchange: (e: Event) =>
              toggleSectionInList(secName, (e.target as HTMLInputElement).checked),
          }),
          E('span', { class: 'tachyon_adv__priority-name tachyon_adv__priority-name--off' }, secName),
        ]),
      ]),
    );
  });

  return E('div', { class: 'tachyon_adv__section' }, [
    E('div', { class: 'tachyon_adv__section-header' }, [
      E('span', { class: 'tachyon_adv__section-icon' }, '🔍'),
      E('h3', { class: 'tachyon_adv__section-title' }, _('Smart Detect')),
    ]),
    E('p', { class: 'tachyon_adv__hint' }, _(
      'Auto-detects blocked domains from logs and adds them to the first section where they work via proxy.',
    )),
    E('div', { class: 'tachyon_adv__row' }, [
      E('label', { class: 'tachyon_adv__toggle' }, [
        E('input', {
          type: 'checkbox',
          checked: smartDetectEnabled,
          onchange: (e: Event) => {
            _state = { ..._state, smartDetectEnabled: (e.target as HTMLInputElement).checked };
            rerender();
          },
        }),
        E('span', {}, _('Enable Smart Detect')),
      ]),
    ]),
    smartDetectEnabled && rows.length > 0
      ? E('div', { class: 'tachyon_adv__priority-list' }, [
          E('p', { class: 'tachyon_adv__sub-hint' }, _(
            'Section test order (checked = active, drag rows with △▽):',
          )),
          ...rows,
        ])
      : E('span', {}),
    E('button', {
      class: 'btn cbi-button cbi-button-save tachyon_adv__save-btn',
      type: 'button',
      disabled: saving,
      onclick: () => void saveSmartDetect(),
    }, saving ? _('Saving…') : _('Save Smart Detect Settings')),
  ]);
}

function renderDeviceRoutingSection(state: AdvancedSettingsState) {
  const { allSectionNames, deviceIpsPerSection, saving } = state;

  if (allSectionNames.length === 0) {
    return E('div', { class: 'tachyon_adv__section' }, [
      E('div', { class: 'tachyon_adv__section-header' }, [
        E('span', { class: 'tachyon_adv__section-icon' }, '🖥'),
        E('h3', { class: 'tachyon_adv__section-title' }, _('Per-Device Routing')),
      ]),
      E('p', { class: 'tachyon_adv__hint' }, _('No active routing sections found.')),
    ]);
  }

  const editors = allSectionNames.map(secName => {
    const currentIps = (deviceIpsPerSection[secName] || []).join('\n');
    const taId = `tachyon-device-ips-${secName}`;

    return E('div', { class: 'tachyon_adv__device-block' }, [
      E('div', { class: 'tachyon_adv__device-name' }, secName),
      E('label', { class: 'tachyon_adv__device-label' }, _('Device IPs (one per line):')),
      E('textarea', {
        id: taId,
        class: 'cbi-input-textarea tachyon_adv__device-ta',
        rows: 3,
        placeholder: '192.168.1.100\n192.168.1.105',
      }, currentIps),
      E('button', {
        class: 'btn cbi-button cbi-button-save tachyon_adv__save-btn',
        type: 'button',
        disabled: saving,
        onclick: () => {
          const ta = document.getElementById(taId) as HTMLTextAreaElement | null;
          void saveDeviceIps(secName, ta ? ta.value : '');
        },
      }, saving ? _('Saving…') : _('Save')),
    ]);
  });

  return E('div', { class: 'tachyon_adv__section' }, [
    E('div', { class: 'tachyon_adv__section-header' }, [
      E('span', { class: 'tachyon_adv__section-icon' }, '🖥'),
      E('h3', { class: 'tachyon_adv__section-title' }, _('Per-Device Routing')),
    ]),
    E('p', { class: 'tachyon_adv__hint' }, _(
      'Devices listed here are always routed through the assigned section, regardless of global rules.',
    )),
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
    renderSmartDetectSection(state),
    E('hr', { class: 'tachyon_adv__divider' }),
    renderDeviceRoutingSection(state),
  ]);
}

export function renderAdvancedSettingsPanel() {
  return E('div', { id: 'tachyon-advanced-settings', class: 'tachyon_adv' }, [
    E('details', { class: 'tachyon_adv__details' }, [
      E('summary', { class: 'tachyon_adv__summary' }, _('⚙ Advanced Settings')),
      E('div', { id: 'tachyon-advanced-settings-inner', class: 'tachyon_adv__inner' }, [
        renderAdvancedSettingsBody(_state),
      ]),
    ]),
  ]);
}
