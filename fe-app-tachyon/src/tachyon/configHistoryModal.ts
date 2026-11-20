/* eslint-disable @typescript-eslint/no-explicit-any */
import { showToast } from '../helpers/showToast';
import { tr } from './helpers/i18n';

export interface UnsavedChangeItem {
  section: string;
  option: string;
  label?: string;
  action: 'set' | 'add' | 'remove';
  before: string;
  after: string;
}

export interface ConfigDiffEntry {
  scope: string;
  target: string;
  field: string;
  kind: 'added' | 'changed' | 'removed' | string;
  before: string;
  after: string;
}

export interface ConfigRevisionSummary {
  id: string;
  timestamp: number;
  source: string;
  status?: string;
  status_reason?: string;
  added: number;
  changed: number;
  removed: number;
  total_changes: number;
  truncated: number;
  changes: ConfigDiffEntry[];
}

export interface ConfigHistoryResponse {
  ok?: boolean;
  revisions?: ConfigRevisionSummary[];
  lkg_available?: boolean;
  lkg_observing?: boolean;
  lkg_remaining_secs?: number;
  active_revision_id?: string;
  auto_rollback_enabled?: boolean;
  watchdog_enabled?: boolean;
  last_auto_rollback_reason?: string;
  last_auto_rollback_ts?: number;
  error?: string;
}

export interface ConfigHistoryModalOptions {
  onReloadMap?: () => void | Promise<unknown>;
  onChangesUpdated?: () => void;
}

const UCI_PACKAGE = 'tachyon';
const MAX_VALUE_CHARS = 140;
const CONFIRM_TIMEOUT_MS = 4000;

function getLuciUi(): any {
  const g = globalThis as any;
  if (typeof ui !== 'undefined' && ui) return ui;
  return g.ui || g.L?.ui || null;
}

function getLuciUci(): any {
  const g = globalThis as any;
  if (typeof uci !== 'undefined' && uci) return uci;
  return g.uci || g.L?.uci || null;
}

function hideActiveModal(): void {
  const uiObj = getLuciUi();
  if (uiObj && typeof uiObj.hideModal === 'function') {
    uiObj.hideModal();
    return;
  }
  const g = globalThis as any;
  if (g.L && typeof g.L.hideModal === 'function') {
    g.L.hideModal();
  }
}

export function isSensitiveFieldName(field: string): boolean {
  const k = String(field || '')
    .trim()
    .toLowerCase();
  if (!k) return false;
  return (
    k === 'key' ||
    k.includes('password') ||
    k.includes('secret') ||
    k.includes('token') ||
    k.includes('private_key') ||
    k.includes('preshared_key') ||
    k.includes('psk') ||
    k.includes('uuid') ||
    k.includes('auth_key') ||
    k.includes('api_key') ||
    k.includes('cookie') ||
    k.includes('short_id')
  );
}

function truncateValue(input: string, maxChars = MAX_VALUE_CHARS): string {
  if (input.length <= maxChars) return input;
  return `${input.slice(0, maxChars)}...`;
}

function isEmptyRawValue(raw: unknown): boolean {
  if (raw === null || raw === undefined) return true;
  if (typeof raw === 'string') return raw.length === 0;
  if (Array.isArray(raw)) return raw.length === 0;
  return false;
}

export function formatDiffFieldValue(field: string, raw: unknown): string {
  if (isSensitiveFieldName(field)) {
    return isEmptyRawValue(raw) ? '' : '***';
  }
  if (raw === null || raw === undefined) return '';
  if (Array.isArray(raw)) {
    if (raw.length === 0) return '[]';
    const joined = raw.map((item) => String(item ?? '')).join(', ');
    return truncateValue(
      raw.length > 4 ? `[${raw.length}]: ${joined}` : `[${joined}]`,
    );
  }
  if (typeof raw === 'object') {
    try {
      return truncateValue(JSON.stringify(raw));
    } catch {
      return '[object]';
    }
  }
  return truncateValue(String(raw));
}

function normalizeFormValue(val: unknown): string | string[] {
  if (Array.isArray(val)) {
    return val.map((v) => String(v ?? ''));
  }
  if (val === null || val === undefined) {
    return '';
  }
  return String(val);
}

function areFormValuesEqual(a: unknown, b: unknown): boolean {
  const normA = normalizeFormValue(a);
  const normB = normalizeFormValue(b);
  if (Array.isArray(normA) && Array.isArray(normB)) {
    return (
      normA.length === normB.length && normA.every((v, i) => v === normB[i])
    );
  }
  if (Array.isArray(normA)) {
    return normA.length === 0 && normB === '';
  }
  if (Array.isArray(normB)) {
    return normB.length === 0 && normA === '';
  }
  return normA === normB;
}

function collectFromLiveForm(
  out: UnsavedChangeItem[],
  seen: Set<string>,
): void {
  const g = globalThis as any;
  const mapInst = g.__tachyonMapInstance;
  if (!mapInst || !Array.isArray(mapInst.children)) return;

  for (const sec of mapInst.children) {
    if (!sec || sec.addremove || !Array.isArray(sec.children)) continue;
    const sids: string[] =
      typeof sec.cfgsections === 'function'
        ? (sec.cfgsections() || []).filter(
            (s: unknown) => typeof s === 'string' && Boolean(s),
          )
        : typeof sec.section === 'string' && sec.section
          ? [sec.section]
          : [];
    if (sids.length === 0) continue;

    for (const sid of sids) {
      for (const opt of sec.children) {
        if (!opt || opt.disable || opt.readonly || opt.modalonly) continue;
        if (typeof opt.option !== 'string' || !opt.option) continue;
        if (
          typeof opt.formvalue !== 'function' ||
          typeof opt.cfgvalue !== 'function' ||
          typeof opt.write !== 'function'
        ) {
          continue;
        }
        if (typeof opt.isActive === 'function' && !opt.isActive(sid)) {
          continue;
        }

        const formVal = opt.formvalue(sid);
        if (formVal === undefined) continue;

        let savedRaw = opt.cfgvalue(sid);
        if (savedRaw === null || savedRaw === undefined) {
          if (opt.default !== null && opt.default !== undefined) {
            savedRaw = opt.default;
          } else if (typeof opt.disabled !== 'undefined') {
            savedRaw = opt.disabled;
          } else {
            savedRaw = '';
          }
        }

        if (areFormValuesEqual(formVal, savedRaw)) continue;

        const key = `${sid}:${opt.option}`;
        if (seen.has(key)) continue;
        seen.add(key);

        out.push({
          section: sid,
          option: opt.option,
          label:
            typeof opt.title === 'string' && opt.title.trim()
              ? opt.title.trim()
              : undefined,
          action: 'set',
          before: formatDiffFieldValue(opt.option, savedRaw),
          after: formatDiffFieldValue(opt.option, formVal),
        });
      }
    }
  }
}

function collectFromUciState(
  uciObj: any,
  out: UnsavedChangeItem[],
  seen: Set<string>,
): void {
  const st = uciObj?.state;
  if (!st || typeof st !== 'object') return;

  const pkgChanges = st.changes?.[UCI_PACKAGE];
  const pkgValues = st.values?.[UCI_PACKAGE];
  if (pkgChanges && typeof pkgChanges === 'object') {
    for (const [sid, opts] of Object.entries(pkgChanges)) {
      if (!opts || typeof opts !== 'object') continue;
      for (const [optName, newVal] of Object.entries(
        opts as Record<string, unknown>,
      )) {
        const key = `${sid}:${optName}`;
        if (seen.has(key)) continue;
        seen.add(key);
        const oldVal = pkgValues?.[sid]?.[optName];
        out.push({
          section: sid,
          option: optName,
          action: 'set',
          before: formatDiffFieldValue(optName, oldVal),
          after: formatDiffFieldValue(optName, newVal),
        });
      }
    }
  }

  const pkgCreates = st.creates?.[UCI_PACKAGE];
  if (pkgCreates && typeof pkgCreates === 'object') {
    for (const [sid, secType] of Object.entries(pkgCreates)) {
      const optName = typeof secType === 'string' ? secType : '';
      const key = `${sid}:${optName}`;
      if (seen.has(key)) continue;
      seen.add(key);
      out.push({
        section: sid,
        option: optName,
        action: 'add',
        before: '',
        after: optName || sid,
      });
    }
  }

  const pkgDeletes = st.deletes?.[UCI_PACKAGE];
  if (pkgDeletes && typeof pkgDeletes === 'object') {
    for (const [sid, delVal] of Object.entries(pkgDeletes)) {
      if (delVal === true) {
        const key = `${sid}:`;
        if (seen.has(key)) continue;
        seen.add(key);
        out.push({
          section: sid,
          option: '',
          action: 'remove',
          before: sid,
          after: '',
        });
      } else if (delVal && typeof delVal === 'object') {
        for (const optName of Object.keys(delVal as Record<string, unknown>)) {
          const key = `${sid}:${optName}`;
          if (seen.has(key)) continue;
          seen.add(key);
          const oldVal = pkgValues?.[sid]?.[optName];
          out.push({
            section: sid,
            option: optName,
            action: 'remove',
            before: formatDiffFieldValue(optName, oldVal),
            after: '',
          });
        }
      }
    }
  }
}

function appendClassicChangeTuples(
  rawList: unknown,
  out: UnsavedChangeItem[],
  seen: Set<string>,
): void {
  let tuples: unknown[] = [];
  if (Array.isArray(rawList)) {
    tuples = rawList;
  } else if (
    rawList &&
    typeof rawList === 'object' &&
    Array.isArray((rawList as Record<string, unknown>)[UCI_PACKAGE])
  ) {
    tuples = (rawList as Record<string, unknown[]>)[UCI_PACKAGE];
  }

  for (const item of tuples) {
    if (!Array.isArray(item) || item.length < 2) continue;
    const rawOp = String(item[0] ?? '').toLowerCase();
    if (rawOp === 'set' && item.length >= 3) {
      const sid = String(item[1] ?? '');
      const optName = String(item[2] ?? '');
      if (!sid || !optName) continue;
      const key = `${sid}:${optName}`;
      if (seen.has(key)) continue;
      seen.add(key);
      out.push({
        section: sid,
        option: optName,
        action: 'set',
        before: '',
        after: formatDiffFieldValue(optName, item[3]),
      });
    } else if (rawOp === 'add') {
      const secType = String(item[1] ?? '');
      const sid = String(item[2] ?? secType);
      if (!sid) continue;
      const optName = item[2] ? secType : '';
      const key = `${sid}:${optName}`;
      if (seen.has(key)) continue;
      seen.add(key);
      out.push({
        section: sid,
        option: optName,
        action: 'add',
        before: '',
        after: optName || sid,
      });
    } else if (rawOp === 'remove') {
      const sid = String(item[1] ?? '');
      const optName =
        item.length >= 3 && item[2] != null ? String(item[2]) : '';
      if (!sid) continue;
      const key = `${sid}:${optName}`;
      if (seen.has(key)) continue;
      seen.add(key);
      out.push({
        section: sid,
        option: optName,
        action: 'remove',
        before: optName || sid,
        after: '',
      });
    }
  }
}

export function collectUnsavedUciChanges(): UnsavedChangeItem[] {
  const out: UnsavedChangeItem[] = [];
  const seen = new Set<string>();

  collectFromLiveForm(out, seen);

  const uciObj = getLuciUci();
  if (uciObj) {
    collectFromUciState(uciObj, out, seen);
    if (typeof uciObj.changes === 'function') {
      try {
        const res = uciObj.changes(UCI_PACKAGE);
        if (res && typeof (res as PromiseLike<unknown>).then !== 'function') {
          appendClassicChangeTuples(res, out, seen);
        }
      } catch {
        // Ignore synchronous uci.changes lookup errors
      }
    }
  }

  const uiObj = getLuciUi();
  const uiPkgChanges = uiObj?.changes?.changes?.[UCI_PACKAGE];
  if (uiPkgChanges) {
    appendClassicChangeTuples(uiPkgChanges, out, seen);
  }

  return out;
}

export function countUnsavedChanges(): number {
  return collectUnsavedUciChanges().length;
}

function clearLocalUciUiState(): void {
  const g = globalThis as any;
  const uciObj = getLuciUci();
  if (uciObj?.state) {
    for (const bucket of ['creates', 'changes', 'deletes', 'reorder']) {
      if (uciObj.state[bucket] && typeof uciObj.state[bucket] === 'object') {
        delete uciObj.state[bucket][UCI_PACKAGE];
      }
    }
  }
  const uiCandidates = [g.ui, g.L?.ui].filter(Boolean);
  for (const cand of uiCandidates) {
    if (cand.changes && typeof cand.changes === 'object') {
      cand.changes.changes = {};
      if (typeof cand.changes.setIndicator === 'function') {
        cand.changes.setIndicator(0);
      }
    }
  }
}

export async function resetUnsavedDraftChanges(
  options?: ConfigHistoryModalOptions,
): Promise<void> {
  const uciObj = getLuciUci();
  if (uciObj && typeof uciObj.unload === 'function') {
    await Promise.resolve(uciObj.unload(UCI_PACKAGE)).catch(() => null);
  }
  clearLocalUciUiState();
  hideActiveModal();
  options?.onChangesUpdated?.();
  showToast(
    tr('Несохранённые правки сброшены', 'Unsaved draft changes discarded'),
    'info',
  );
  if (options?.onReloadMap) {
    await Promise.resolve(options.onReloadMap()).catch(() => null);
  } else if (
    typeof window !== 'undefined' &&
    typeof window.location?.reload === 'function'
  ) {
    window.location.reload();
  }
}

function formatRevisionTime(tsSeconds: number): string {
  if (!tsSeconds || !Number.isFinite(tsSeconds)) return '--:--:--';
  const d = new Date(tsSeconds * 1000);
  const now = new Date();
  const hh = String(d.getHours()).padStart(2, '0');
  const mm = String(d.getMinutes()).padStart(2, '0');
  const ss = String(d.getSeconds()).padStart(2, '0');
  const timeStr = `${hh}:${mm}:${ss}`;
  const sameDay =
    d.getFullYear() === now.getFullYear() &&
    d.getMonth() === now.getMonth() &&
    d.getDate() === now.getDate();
  if (sameDay) return timeStr;
  const day = String(d.getDate()).padStart(2, '0');
  const mon = String(d.getMonth() + 1).padStart(2, '0');
  return `${day}.${mon} ${timeStr}`;
}

function formatScopeLabel(scope: string): string {
  switch (scope) {
    case 'settings':
      return tr('Настройки', 'Settings');
    case 'section':
      return tr('Секция', 'Section');
    case 'outbound_source':
      return tr('Источник', 'Source');
    case 'outbound_group':
      return tr('Группа', 'Group');
    case 'condition':
      return tr('Условие', 'Condition');
    case 'balancer':
      return tr('Балансировщик', 'Balancer');
    case 'server':
      return tr('Сервер', 'Server');
    case 'profile':
      return tr('Профиль', 'Profile');
    case 'schedule':
      return tr('Расписание', 'Schedule');
    case 'guest_mode':
      return tr('Гостевой режим', 'Guest mode');
    case 'telegram':
      return 'Telegram';
    case 'device':
      return tr('Устройство', 'Device');
    default:
      return scope || tr('Конфиг', 'Config');
  }
}

function formatSourceTag(source: string): string {
  if (source === 'auto_rollback') return tr('Автооткат', 'Auto-rollback');
  if (source === 'rollback') return tr('Откат', 'Rollback');
  return tr('Сохранение', 'Save');
}

function resolveRevisionStatus(
  rev: ConfigRevisionSummary,
  idx: number,
  activeRevId: string,
  lkgObserving: boolean,
  lkgRemainingSecs: number,
): { cls: string; modifier: string; label: string } {
  const st = String(rev.status || '').toLowerCase();
  if (st === 'working') {
    return {
      cls: 'is-working',
      modifier: 'working',
      label: tr('Рабочий', 'Working'),
    };
  }
  if (st === 'failed') {
    return {
      cls: 'is-failed',
      modifier: 'failed',
      label: tr('Нерабочий', 'Failed'),
    };
  }
  const isCurrentChecking =
    (Boolean(activeRevId) && rev.id === activeRevId) ||
    (idx === 0 && lkgObserving);
  if (st === 'checking' && isCurrentChecking) {
    return {
      cls: 'is-checking',
      modifier: 'checking',
      label:
        lkgObserving && lkgRemainingSecs > 0
          ? tr(
              `Проверяется (${lkgRemainingSecs}с)`,
              `Verifying (${lkgRemainingSecs}s)`,
            )
          : tr('Проверяется', 'Verifying'),
    };
  }
  return {
    cls: 'is-unverified',
    modifier: 'unverified',
    label: tr('Не проверен', 'Unverified'),
  };
}

function setButtonText(btn: HTMLElement, text: string): void {
  if (typeof btn.replaceChildren === 'function') {
    btn.replaceChildren(text as any);
  }
  btn.textContent = text;
}

function attachTwoStepConfirm(
  btn: HTMLButtonElement,
  idleLabel: string,
  confirmLabel: string,
  onConfirmed: () => Promise<void>,
): void {
  let confirming = false;
  let timerId: ReturnType<typeof setTimeout> | null = null;

  const resetState = () => {
    confirming = false;
    btn.classList?.remove('is-confirming');
    setButtonText(btn, idleLabel);
    if (timerId !== null) {
      clearTimeout(timerId);
      timerId = null;
    }
  };

  btn.addEventListener('click', (ev: MouseEvent) => {
    ev.preventDefault();
    ev.stopPropagation();
    if (btn.disabled) return;

    if (!confirming) {
      confirming = true;
      btn.classList?.add('is-confirming');
      setButtonText(btn, confirmLabel);
      timerId = setTimeout(resetState, CONFIRM_TIMEOUT_MS);
      return;
    }

    resetState();
    void onConfirmed();
  });
}

function renderUnsavedBlock(
  unsaved: UnsavedChangeItem[],
  options?: ConfigHistoryModalOptions,
): HTMLElement {
  let discardBtnRef: HTMLButtonElement | null = null;
  const discardBtn = E(
    'button',
    {
      type: 'button',
      class: 'tachyon-history-action-btn',
      click: async (ev: MouseEvent) => {
        ev.preventDefault();
        if (discardBtnRef) discardBtnRef.disabled = true;
        try {
          await resetUnsavedDraftChanges(options);
        } finally {
          if (discardBtnRef) discardBtnRef.disabled = false;
        }
      },
    } as any,
    tr('Сбросить черновик', 'Discard draft'),
  ) as HTMLButtonElement;
  discardBtnRef = discardBtn;

  const listEl = E(
    'div',
    { class: 'tachyon-history-diff-list' },
    unsaved.map((item) => {
      const targetText = item.label
        ? `${item.section} · ${item.label}`
        : item.option
          ? `${item.section} · ${item.option}`
          : item.section;
      const beforeText =
        item.action === 'add'
          ? tr('отсутствовало', 'absent')
          : item.before || '""';
      const afterText =
        item.action === 'remove'
          ? tr('удалено', 'removed')
          : item.after || '""';

      return E('div', { class: 'tachyon-history-diff-row' }, [
        E('div', { class: 'tachyon-history-diff-path' }, [
          E(
            'span',
            { class: 'tachyon-history-diff-scope' },
            item.action === 'add'
              ? tr('Добавлено', 'Added')
              : item.action === 'remove'
                ? tr('Удалено', 'Removed')
                : tr('Черновик', 'Draft'),
          ),
          E('span', { class: 'tachyon-history-diff-target' }, targetText),
        ]),
        E('div', { class: 'tachyon-history-diff-vals' }, [
          E(
            'span',
            { class: 'tachyon-history-val--before', title: beforeText },
            beforeText,
          ),
          E('span', { class: 'tachyon-history-diff-arrow' }, '->'),
          E(
            'span',
            { class: 'tachyon-history-val--after', title: afterText },
            afterText,
          ),
        ]),
      ]);
    }),
  );

  return E('div', { class: 'tachyon-history-section tachyon-history-banner' }, [
    E('div', { class: 'tachyon-history-section__head' }, [
      E(
        'div',
        { class: 'tachyon-history-section__title' },
        `${tr('Несохранённые правки', 'Unsaved draft changes')} (${unsaved.length})`,
      ),
      discardBtn,
    ]),
    listEl,
  ]);
}

function renderDiffRows(rev: ConfigRevisionSummary): HTMLElement {
  const rows: HTMLElement[] = (rev.changes || []).map((entry) => {
    const scopeText = formatScopeLabel(entry.scope);
    const pathText = entry.field
      ? `${entry.target} · ${entry.field}`
      : entry.target;
    const beforeText =
      entry.kind === 'added'
        ? tr('отсутствовало', 'absent')
        : entry.before || '""';
    const afterText =
      entry.kind === 'removed' ? tr('удалено', 'removed') : entry.after || '""';

    return E('div', { class: 'tachyon-history-diff-row' }, [
      E('div', { class: 'tachyon-history-diff-path' }, [
        E('span', { class: 'tachyon-history-diff-scope' }, scopeText),
        E('span', { class: 'tachyon-history-diff-target' }, pathText),
      ]),
      E('div', { class: 'tachyon-history-diff-vals' }, [
        E(
          'span',
          { class: 'tachyon-history-val--before', title: beforeText },
          beforeText,
        ),
        E('span', { class: 'tachyon-history-diff-arrow' }, '->'),
        E(
          'span',
          { class: 'tachyon-history-val--after', title: afterText },
          afterText,
        ),
      ]),
    ]);
  });

  if (rev.truncated > 0) {
    rows.push(
      E(
        'div',
        { class: 'tachyon-history-diff-more' },
        tr(
          `Ещё ${rev.truncated} изменений скрыто`,
          `${rev.truncated} more changes hidden`,
        ),
      ),
    );
  }

  return E('div', { class: 'tachyon-history-diff-list' }, rows);
}

export function openConfigHistoryModal(
  options?: ConfigHistoryModalOptions,
): void {
  const uiObj = getLuciUi();
  if (!uiObj || typeof uiObj.showModal !== 'function') return;

  const unsaved = collectUnsavedUciChanges();
  const root = E('div', { class: 'tachyon-history-modal' }) as HTMLElement;

  if (unsaved.length > 0) {
    root.appendChild(renderUnsavedBlock(unsaved, options));
  }

  const actionsEl = E('div', {
    class: 'tachyon-history-actions',
  }) as HTMLElement;
  const statusHostEl = E('div', {
    class: 'tachyon-history-status-host',
  }) as HTMLElement;
  const listHostEl = E('div', { class: 'tachyon-history-list-host' }, [
    E(
      'div',
      { class: 'tachyon-history-empty' },
      tr('Загрузка истории изменений...', 'Loading change history...'),
    ),
  ]) as HTMLElement;

  const historySection = E('div', { class: 'tachyon-history-section' }, [
    E('div', { class: 'tachyon-history-section__head' }, [
      E(
        'div',
        { class: 'tachyon-history-section__title' },
        tr('Сохранённые изменения (RAM)', 'Saved revisions (RAM)'),
      ),
      actionsEl,
    ]),
    statusHostEl,
    listHostEl,
  ]) as HTMLElement;

  root.appendChild(historySection);

  let rollbackInFlight = false;
  const actionButtons: HTMLButtonElement[] = [];

  const setButtonsDisabled = (disabled: boolean) => {
    for (const btn of actionButtons) {
      btn.disabled = disabled;
    }
  };

  const executeRollback = async (payload: {
    id?: string;
    target?: 'lkg';
    mode?: 'before' | 'after';
  }) => {
    if (rollbackInFlight) return;
    rollbackInFlight = true;
    setButtonsDisabled(true);
    try {
      const res = await fetch('/api/config/history/rollback', {
        method: 'POST',
        credentials: 'same-origin',
        headers: {
          'Content-Type': 'application/json',
          Accept: 'application/json',
        },
        body: JSON.stringify(payload),
      });
      const data = (await res.json().catch(() => ({}))) as {
        ok?: boolean;
        success?: boolean;
        error?: string;
      };
      if (!res.ok || data.ok === false || data.success === false) {
        throw new Error(
          data.error ||
            tr(
              `Ошибка отката (HTTP ${res.status})`,
              `Rollback failed (HTTP ${res.status})`,
            ),
        );
      }

      const uciObj = getLuciUci();
      if (uciObj && typeof uciObj.unload === 'function') {
        await Promise.resolve(uciObj.unload(UCI_PACKAGE)).catch(() => null);
      }
      clearLocalUciUiState();
      hideActiveModal();
      showToast(
        tr(
          'Настройки откачены и применены',
          'Configuration rolled back and applied',
        ),
        'success',
      );
      options?.onChangesUpdated?.();

      if (options?.onReloadMap) {
        await Promise.resolve(options.onReloadMap()).catch(() => null);
      } else if (
        typeof window !== 'undefined' &&
        typeof window.location?.reload === 'function'
      ) {
        window.location.reload();
      }
    } catch (err: any) {
      showToast(
        err?.message ||
          tr(
            'Не удалось выполнить откат настроек',
            'Failed to rollback config',
          ),
        'error',
      );
      setButtonsDisabled(false);
    } finally {
      rollbackInFlight = false;
    }
  };

  const confirmCurrentWorking = async (btn: HTMLButtonElement) => {
    btn.disabled = true;
    try {
      const res = await fetch('/api/lkg/confirm', {
        method: 'POST',
        credentials: 'same-origin',
        headers: {
          'Content-Type': 'application/json',
          Accept: 'application/json',
        },
        body: '{}',
      });
      const data = (await res.json().catch(() => ({}))) as {
        ok?: boolean;
        error?: string;
      };
      if (!res.ok || data.ok === false) {
        throw new Error(data.error || `HTTP ${res.status}`);
      }
      showToast(
        tr(
          'Текущий конфиг подтверждён как рабочий',
          'Current config confirmed as working',
        ),
        'success',
      );
      await loadHistory();
    } catch (err: any) {
      showToast(
        err?.message ||
          tr(
            'Не удалось подтвердить конфиг',
            'Failed to confirm working config',
          ),
        'error',
      );
      btn.disabled = false;
    }
  };

  const loadHistory = async () => {
    actionButtons.length = 0;
    actionsEl.replaceChildren();
    statusHostEl.replaceChildren();
    listHostEl.replaceChildren(
      E(
        'div',
        { class: 'tachyon-history-empty' },
        tr('Загрузка истории изменений...', 'Loading change history...'),
      ),
    );

    try {
      const res = await fetch('/api/config/history', {
        method: 'GET',
        credentials: 'same-origin',
        cache: 'no-store',
        headers: { Accept: 'application/json' },
      });
      const data = (await res
        .json()
        .catch(() => ({}))) as ConfigHistoryResponse;
      if (!res.ok || data.ok === false) {
        throw new Error(data.error || `HTTP ${res.status}`);
      }

      const revisions = Array.isArray(data.revisions) ? data.revisions : [];
      const lkgAvailable = Boolean(data.lkg_available);
      const lkgObserving = Boolean(data.lkg_observing);
      const lkgRemainingSecs =
        typeof data.lkg_remaining_secs === 'number'
          ? data.lkg_remaining_secs
          : 0;
      const activeRevId = String(data.active_revision_id || '');
      const lastAutoReason = String(
        data.last_auto_rollback_reason || '',
      ).trim();
      const lastAutoTs =
        typeof data.last_auto_rollback_ts === 'number'
          ? data.last_auto_rollback_ts
          : 0;

      const statusBanners: HTMLElement[] = [];
      if (lastAutoReason) {
        const titleText =
          lastAutoTs > 0
            ? `${tr('Выполнен автооткат на рабочий конфиг', 'Automatic rollback to working config triggered')} (${formatRevisionTime(lastAutoTs)})`
            : tr(
                'Выполнен автооткат на рабочий конфиг',
                'Automatic rollback to working config triggered',
              );
        statusBanners.push(
          E('div', { class: 'tachyon-history-alert' }, [
            E('div', { class: 'tachyon-history-alert__title' }, titleText),
            E(
              'div',
              { class: 'tachyon-history-alert__reason' },
              lastAutoReason,
            ),
          ]),
        );
      }

      if (lkgObserving) {
        let confirmBtnRef: HTMLButtonElement | null = null;
        const confirmBtn = E(
          'button',
          {
            type: 'button',
            class:
              'tachyon-history-action-btn tachyon-history-action-btn--primary',
            click: (ev: MouseEvent) => {
              ev.preventDefault();
              if (confirmBtnRef) void confirmCurrentWorking(confirmBtnRef);
            },
          } as any,
          tr('Подтвердить рабочий', 'Confirm working'),
        ) as HTMLButtonElement;
        confirmBtnRef = confirmBtn;
        actionButtons.push(confirmBtn);
        statusBanners.push(
          E('div', { class: 'tachyon-history-guard is-observing' }, [
            E(
              'div',
              { class: 'tachyon-history-guard__text' },
              tr(
                `Идёт проверка нового конфига (осталось ${lkgRemainingSecs} с). При сбое ядра или DNS сработает автооткат на рабочий конфиг.`,
                `Verifying new config (${lkgRemainingSecs}s left). Auto-rollback to working config triggers on core or DNS failure.`,
              ),
            ),
            confirmBtn,
          ]),
        );
      } else if (lkgAvailable) {
        statusBanners.push(
          E('div', { class: 'tachyon-history-guard' }, [
            E(
              'div',
              { class: 'tachyon-history-guard__text' },
              tr(
                'Автоматический откат на последний рабочий конфиг активен.',
                'Automatic rollback to last working config is active.',
              ),
            ),
          ]),
        );
      }

      if (statusBanners.length > 0) {
        statusHostEl.replaceChildren(...statusBanners);
      }

      if (lkgAvailable) {
        const lkgIdle = tr(
          'Откатить к рабочему (LKG)',
          'Rollback to working (LKG)',
        );
        const lkgBtn = E(
          'button',
          {
            type: 'button',
            class:
              'tachyon-history-action-btn tachyon-history-action-btn--primary',
          },
          lkgIdle,
        ) as HTMLButtonElement;
        actionButtons.push(lkgBtn);
        attachTwoStepConfirm(
          lkgBtn,
          lkgIdle,
          tr('Подтвердить откат?', 'Confirm rollback?'),
          () => executeRollback({ target: 'lkg' }),
        );
        actionsEl.appendChild(lkgBtn);
      }

      if (revisions.length > 0) {
        const undoIdle = tr('Отменить последнее', 'Undo last change');
        const latestBtn = E(
          'button',
          {
            type: 'button',
            class: 'tachyon-history-action-btn',
          },
          undoIdle,
        ) as HTMLButtonElement;
        actionButtons.push(latestBtn);
        attachTwoStepConfirm(
          latestBtn,
          undoIdle,
          tr('Подтвердить откат?', 'Confirm rollback?'),
          () => executeRollback({ id: revisions[0].id, mode: 'before' }),
        );
        actionsEl.appendChild(latestBtn);
      }

      if (revisions.length === 0) {
        listHostEl.replaceChildren(
          E(
            'div',
            { class: 'tachyon-history-empty' },
            tr(
              'За текущую сессию сохранённых изменений пока нет. История хранится в RAM (/tmp) без износа flash-памяти.',
              'No saved changes recorded in the current session yet. History is stored in RAM (/tmp) with zero flash wear.',
            ),
          ),
        );
        return;
      }

      const cards = revisions.map((rev, idx) => {
        const expanded = idx === 0;
        const revCard = E('div', {
          class: `tachyon-history-rev${expanded ? ' is-expanded' : ''}`,
        }) as HTMLElement;

        const counts: string[] = [];
        if (rev.added > 0) counts.push(`+${rev.added}`);
        if (rev.changed > 0) counts.push(`~${rev.changed}`);
        if (rev.removed > 0) counts.push(`-${rev.removed}`);

        const stInfo = resolveRevisionStatus(
          rev,
          idx,
          activeRevId,
          lkgObserving,
          lkgRemainingSecs,
        );

        const rollbackMode: 'before' | 'after' =
          idx > 0 && rev.status === 'working' ? 'after' : 'before';
        const btnIdleLabel =
          idx === 0
            ? tr('Отменить', 'Undo')
            : rev.status === 'working'
              ? tr('Вернуть рабочий', 'Restore working')
              : tr('Откатить до', 'Revert before');

        const revRollbackBtn = E(
          'button',
          {
            type: 'button',
            class: `tachyon-history-action-btn${rev.status === 'working' && idx > 0 ? ' tachyon-history-action-btn--primary' : ''}`,
          },
          btnIdleLabel,
        ) as HTMLButtonElement;
        actionButtons.push(revRollbackBtn);
        attachTwoStepConfirm(
          revRollbackBtn,
          btnIdleLabel,
          tr('Подтвердить?', 'Confirm?'),
          () => executeRollback({ id: rev.id, mode: rollbackMode }),
        );

        const bodyChildren: HTMLElement[] = [];
        if (rev.status === 'failed' && rev.status_reason) {
          bodyChildren.push(
            E(
              'div',
              { class: 'tachyon-history-rev__reason' },
              `${tr('Причина сбоя', 'Failure reason')}: ${rev.status_reason}`,
            ),
          );
        }
        bodyChildren.push(renderDiffRows(rev));

        const bodyEl = E(
          'div',
          { class: 'tachyon-history-rev__body' },
          bodyChildren,
        ) as HTMLElement;
        if (!expanded) {
          bodyEl.style.display = 'none';
        }

        const isRbSource =
          rev.source === 'rollback' || rev.source === 'auto_rollback';

        const headEl = E(
          'div',
          {
            class: 'tachyon-history-rev__head',
            click: () => {
              const nextOpen = !revCard.classList.contains('is-expanded');
              revCard.classList.toggle('is-expanded', nextOpen);
              bodyEl.style.display = nextOpen ? '' : 'none';
            },
          },
          [
            E('div', { class: 'tachyon-history-rev__meta' }, [
              E(
                'span',
                { class: 'tachyon-history-rev__time' },
                formatRevisionTime(rev.timestamp),
              ),
              E(
                'span',
                {
                  class: `tachyon-history-status tachyon-history-status--${stInfo.modifier} ${stInfo.cls}`,
                },
                stInfo.label,
              ),
              E(
                'span',
                {
                  class: `tachyon-history-rev__tag${isRbSource ? ' is-rollback' : ''}`,
                },
                formatSourceTag(rev.source),
              ),
              E(
                'span',
                { class: 'tachyon-history-rev__counts' },
                counts.join(' '),
              ),
            ]),
            revRollbackBtn,
          ],
        );

        revCard.appendChild(headEl);
        revCard.appendChild(bodyEl);
        return revCard;
      });

      listHostEl.replaceChildren(...cards);
    } catch (err: any) {
      const retryBtn = E(
        'button',
        {
          type: 'button',
          class: 'tachyon-history-action-btn',
          click: () => void loadHistory(),
        },
        tr('Повторить', 'Retry'),
      );
      listHostEl.replaceChildren(
        E('div', { class: 'tachyon-history-empty is-error' }, [
          E(
            'div',
            {},
            err?.message ||
              tr(
                'Не удалось загрузить историю изменений',
                'Failed to load change history',
              ),
          ),
          retryBtn,
        ]),
      );
    }
  };

  uiObj.showModal(
    tr('История изменений и откат', 'Change History & Rollback'),
    [root],
    'cbi-modal',
  );
  void loadHistory();
}
