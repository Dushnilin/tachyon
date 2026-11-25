/* eslint-disable @typescript-eslint/no-explicit-any */
import { svgEl } from '../../../helpers';
import { countryCodeToFlagEmoji, getCountryName } from '../../helpers/country';
import { tr } from '../../helpers/i18n';
import type { Tachyon } from '../../types';

const PRIVACY_MODE_STORAGE_KEY = 'tachyon_privacy_mode_v1';
export const PRIVACY_MODE_CHANGED_EVENT = 'tachyon:privacy-mode-changed';

let privacyHotkeyBound = false;

export function isPrivacyModeEnabled(): boolean {
  try {
    if (typeof document !== 'undefined' && document.body) {
      if (
        document.body.dataset?.tachyonPrivacy === 'true' ||
        document.body.classList?.contains('tachyon-privacy-mode')
      ) {
        return true;
      }
      if (document.body.dataset?.tachyonPrivacy === 'false') {
        return false;
      }
    }
    if (typeof localStorage !== 'undefined') {
      return localStorage.getItem(PRIVACY_MODE_STORAGE_KEY) === 'true';
    }
  } catch {
    // ignore storage/DOM errors
  }
  return false;
}

export function setPrivacyModeEnabled(enabled: boolean): void {
  const next = Boolean(enabled);
  try {
    if (typeof localStorage !== 'undefined') {
      localStorage.setItem(PRIVACY_MODE_STORAGE_KEY, next ? 'true' : 'false');
    }
  } catch {
    // ignore
  }
  try {
    if (typeof document !== 'undefined' && document.body) {
      document.body.dataset.tachyonPrivacy = next ? 'true' : 'false';
      document.body.classList?.toggle('tachyon-privacy-mode', next);
    }
  } catch {
    // ignore
  }
  try {
    if (
      typeof window !== 'undefined' &&
      typeof window.dispatchEvent === 'function' &&
      typeof CustomEvent !== 'undefined'
    ) {
      window.dispatchEvent(
        new CustomEvent(PRIVACY_MODE_CHANGED_EVENT, {
          detail: { enabled: next },
        }),
      );
    }
  } catch {
    // ignore
  }
}

export function togglePrivacyMode(): boolean {
  const next = !isPrivacyModeEnabled();
  setPrivacyModeEnabled(next);
  return next;
}

export function installPrivacyModeHotkey(): void {
  if (
    privacyHotkeyBound ||
    typeof document === 'undefined' ||
    typeof document.addEventListener !== 'function'
  ) {
    return;
  }
  privacyHotkeyBound = true;
  if (isPrivacyModeEnabled() && document.body) {
    document.body.dataset.tachyonPrivacy = 'true';
    document.body.classList?.add('tachyon-privacy-mode');
  }
  document.addEventListener('keydown', (ev: KeyboardEvent) => {
    if (!ev.altKey || ev.ctrlKey || ev.metaKey) return;
    const keyLower = String(ev.key || '').toLowerCase();
    const isP = ev.code === 'KeyP' || keyLower === 'p' || keyLower === 'з';
    if (!isP) return;
    const target = ev.target as HTMLElement | null;
    const tag = String(target?.tagName || '').toUpperCase();
    if (
      tag === 'INPUT' ||
      tag === 'TEXTAREA' ||
      tag === 'SELECT' ||
      target?.isContentEditable
    ) {
      return;
    }
    ev.preventDefault();
    togglePrivacyMode();
  });
}

export function maskPublicIp(ip: string, privacyEnabled: boolean): string {
  const trimmed = String(ip || '').trim();
  if (!trimmed) return '';
  if (!privacyEnabled) return trimmed;
  return trimmed.includes(':') ? '••••:••••:••••' : '•••.•••.•••.•••';
}

export interface ExitCountryState {
  loading: boolean;
  data: Tachyon.ExitCountryResult | null;
  error: string;
  activeNode: string;
}

export function formatExitCountryTooltip(
  state: ExitCountryState,
  privacyEnabled = isPrivacyModeEnabled(),
): string {
  if (state.loading && !state.data) {
    return tr(
      'Определение страны фактического выхода...',
      'Checking actual exit country...',
    );
  }
  const d = state.data;
  if (!d || !d.ok) {
    const errText = d?.error || state.error;
    return [
      tr(
        'Не удалось определить фактическую страну выхода',
        'Failed to detect actual exit country',
      ),
      errText ? `${tr('Ошибка', 'Error')}: ${errText}` : '',
      tr('Нажмите, чтобы проверить снова', 'Click to retry'),
    ]
      .filter(Boolean)
      .join('\n');
  }

  const code = String(d.country_code || '')
    .trim()
    .toUpperCase();
  const countryName = code ? getCountryName(code) : '';
  const maskedIp = maskPublicIp(d.ip, privacyEnabled);
  const lines: string[] = [];
  if (code) {
    lines.push(
      `${tr('Фактический выход', 'Actual exit')}: ${countryName ? `${countryName} (${code})` : code}`,
    );
  }
  if (maskedIp) {
    lines.push(
      `${tr('Публичный IP', 'Public IP')}: ${maskedIp}${privacyEnabled ? ` (${tr('скрыт Alt+P', 'masked Alt+P')})` : ''}`,
    );
  }
  if (d.source) {
    lines.push(`${tr('Источник', 'Source')}: ${d.source}`);
  }
  if (d.active_node || state.activeNode) {
    lines.push(
      `${tr('Активный узел', 'Active node')}: ${d.active_node || state.activeNode}`,
    );
  }
  lines.push(tr('Нажмите для обновления', 'Click to refresh'));
  return lines.join('\n');
}

export function renderExitCountryIndicator(
  state: ExitCountryState,
  onRefresh: () => void,
  privacyEnabled = isPrivacyModeEnabled(),
): HTMLElement {
  const d = state.data;
  const code =
    d && d.ok
      ? String(d.country_code || '')
          .trim()
          .toUpperCase()
      : '';
  const flag = code ? countryCodeToFlagEmoji(code) : '';
  const tooltip = formatExitCountryTooltip(state, privacyEnabled);

  const labelText =
    state.loading && !code
      ? tr('Проверка...', 'Checking...')
      : code
        ? `${flag ? `${flag} ` : ''}${code}`
        : '—';

  const refreshIcon =
    typeof document !== 'undefined' &&
    typeof document.createElementNS === 'function'
      ? svgEl(
          'svg',
          {
            viewBox: '0 0 24 24',
            width: '11',
            height: '11',
            fill: 'none',
            stroke: 'currentColor',
            'stroke-width': '2',
            'stroke-linecap': 'round',
            'stroke-linejoin': 'round',
            class: `tachyon-exit-country-pill__icon${state.loading ? ' is-spinning' : ''}`,
            'aria-hidden': 'true',
          },
          [
            svgEl('path', { d: 'M21 12a9 9 0 1 1-2.64-6.36' }),
            svgEl('polyline', { points: '21 3 21 9 15 9' }),
          ],
        )
      : null;

  return E(
    'button',
    {
      type: 'button',
      class: [
        'tachyon-stat-pill',
        'tachyon-stat-pill--conns',
        'tachyon-exit-country-pill',
        state.loading ? 'is-loading' : '',
        d && d.ok && code ? 'is-ready' : '',
      ]
        .filter(Boolean)
        .join(' '),
      'data-exit-country-indicator': '1',
      'data-country-code': code,
      'data-privacy-masked': privacyEnabled ? 'true' : 'false',
      title: tooltip,
      'aria-label': tooltip,
      style:
        'cursor: pointer; display: inline-flex; align-items: center; gap: 5px; font-variant-numeric: tabular-nums;',
      click: (ev: MouseEvent) => {
        ev.preventDefault();
        ev.stopPropagation();
        onRefresh();
      },
    } as any,
    [
      E('span', { class: 'tachyon-exit-country-pill__label' }, labelText),
      ...(refreshIcon ? [refreshIcon] : []),
    ],
  );
}

export interface ExitCountryController {
  getState: () => ExitCountryState;
  fetchExitCountry: (opts?: {
    refresh?: boolean;
    node?: string;
  }) => Promise<ExitCountryState>;
  syncActiveNode: (activeNode: string) => void;
  reset: () => void;
}

export function createExitCountryController(deps: {
  fetcher: (opts?: {
    refresh?: boolean;
    node?: string;
  }) => Promise<Tachyon.MethodResponse<Tachyon.ExitCountryResult>>;
  onUpdate: (state: ExitCountryState) => void;
  isActive?: () => boolean;
}): ExitCountryController {
  let state: ExitCountryState = {
    loading: false,
    data: null,
    error: '',
    activeNode: '',
  };
  let requestSeq = 0;
  let lastTrackedNode = '';

  const emit = () => {
    deps.onUpdate({ ...state });
  };

  const fetchExitCountry = async (
    opts: { refresh?: boolean; node?: string } = {},
  ): Promise<ExitCountryState> => {
    if (deps.isActive && !deps.isActive()) {
      return { ...state };
    }
    const seq = ++requestSeq;
    const targetNode =
      opts.node !== undefined
        ? String(opts.node || '').trim()
        : state.activeNode;
    state = {
      ...state,
      loading: true,
      error: '',
      activeNode: targetNode,
    };
    emit();

    try {
      const res = await deps.fetcher({
        refresh: Boolean(opts.refresh),
        node: targetNode || undefined,
      });
      if (seq !== requestSeq || (deps.isActive && !deps.isActive())) {
        return { ...state };
      }
      if (res.success && res.data) {
        state = {
          loading: false,
          data: res.data,
          error: res.data.ok ? '' : res.data.error || '',
          activeNode: res.data.active_node || targetNode,
        };
      } else {
        state = {
          ...state,
          loading: false,
          error: !res.success ? res.error || '' : '',
        };
      }
    } catch (err: any) {
      if (seq !== requestSeq || (deps.isActive && !deps.isActive())) {
        return { ...state };
      }
      state = {
        ...state,
        loading: false,
        error: err?.message || String(err || ''),
      };
    }
    emit();
    return { ...state };
  };

  const syncActiveNode = (activeNode: string) => {
    const normalized = String(activeNode || '').trim();
    if (!normalized || normalized === lastTrackedNode) {
      return;
    }
    const hadPrevious = lastTrackedNode !== '';
    lastTrackedNode = normalized;
    void fetchExitCountry({
      refresh: hadPrevious,
      node: normalized,
    });
  };

  const reset = () => {
    requestSeq += 1;
    lastTrackedNode = '';
    state = {
      loading: false,
      data: null,
      error: '',
      activeNode: '',
    };
  };

  return {
    getState: () => ({ ...state }),
    fetchExitCountry,
    syncActiveNode,
    reset,
  };
}
