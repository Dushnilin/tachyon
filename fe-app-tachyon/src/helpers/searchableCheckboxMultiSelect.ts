/* eslint-disable @typescript-eslint/no-explicit-any */
import { tr } from '../tachyon/helpers/i18n';

export interface MultiSelectChoice {
  value: string;
  label: string;
  badge?: string;
  secondaryBadge?: string;
}

export interface SearchableCheckboxMultiSelectOptions {
  choices?:
    | Record<string, string>
    | Array<MultiSelectChoice | [string, string] | string>;
  values?: string[];
  placeholder?: string;
  searchPlaceholder?: string;
  disabled?: boolean;
  allowCustom?: boolean;
  showChips?: boolean;
  batchSize?: number;
  selectVisibleLimit?: number;
  maxVisibleChips?: number;
  validateItem?: (value: string) => true | string;
  onBeforeOpen?: () => void | Promise<void>;
  onChange?: (
    nextValues: string[],
    meta: { source: 'user' | 'external' },
  ) => void;
}

export interface SearchableCheckboxMultiSelectHandle {
  element: HTMLElement;
  trigger: HTMLButtonElement;
  panel: HTMLElement;
  searchInput: HTMLInputElement;
  listElement: HTMLElement;
  chipsElement: HTMLElement;
  isOpen: () => boolean;
  open: () => void;
  close: (opts?: { focusTrigger?: boolean }) => void;
  getValues: () => string[];
  setValues: (nextValues: string[], opts?: { silent?: boolean }) => void;
  refreshChoices: (
    nextChoices: SearchableCheckboxMultiSelectOptions['choices'],
  ) => void;
  updateChoices: (
    nextChoices: SearchableCheckboxMultiSelectOptions['choices'],
  ) => void;
  setDisabled: (disabled: boolean) => void;
  destroy: () => void;
}

export interface AttachSearchableMultiSelectOptions {
  choices?: SearchableCheckboxMultiSelectOptions['choices'];
  placeholder?: string;
  searchPlaceholder?: string;
  disabled?: boolean;
  allowCustom?: boolean;
  showChips?: boolean;
  batchSize?: number;
  selectVisibleLimit?: number;
  validateItem?: (value: string) => true | string;
  onBeforeOpen?: () => void | Promise<void>;
  option?: any;
  sectionId?: string;
  inputName?: string;
}

export interface AttachedDynamicListHandle
  extends SearchableCheckboxMultiSelectHandle {
  syncFromWidget: () => void;
}

const DEFAULT_BATCH_SIZE = 120;
const DEFAULT_SELECT_VISIBLE_LIMIT = 300;
const DEFAULT_MAX_VISIBLE_CHIPS = 40;
const FALLBACK_STYLE_ID = 'tachyon-ms-fallback-styles';

const FALLBACK_STYLES = `
.tachyon-dynlist-has-ms > .item,
.tachyon-dynlist-has-ms > .add-item,
.tachyon-dynlist-has-ms > .cbi-dropdown,
.tachyon-dynlist-has-ms-items-visible > .add-item {
  display: none !important;
}
.tachyon-ms {
  position: relative;
  display: flex;
  flex-direction: column;
  gap: 8px;
  width: 100%;
  min-width: 0;
  max-width: 100%;
  box-sizing: border-box;
}
.tachyon-ms__chips {
  display: flex;
  flex-wrap: wrap;
  gap: 4px;
  align-items: center;
  min-width: 0;
  max-width: 100%;
}
.tachyon-ms__chips[hidden] {
  display: none !important;
}
.tachyon-ms__chip {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  min-width: 0;
  max-width: 100%;
  padding: 2px 6px 2px 8px;
  border-radius: 6px;
  border: 1px solid color-mix(in srgb, var(--accent, #0a84ff) 32%, var(--border-strong, rgba(128, 128, 128, 0.25)));
  background: color-mix(in srgb, var(--accent, #0a84ff) 12%, transparent);
  color: var(--text, inherit);
  font-size: 12px;
  line-height: 1.35;
  box-sizing: border-box;
}
.tachyon-ms__chip-label {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.tachyon-ms__chip-remove {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 16px;
  height: 16px;
  padding: 0;
  border: 0;
  border-radius: 4px;
  background: transparent;
  color: inherit;
  opacity: 0.72;
  cursor: pointer;
  font-size: 14px;
  line-height: 1;
}
.tachyon-ms__chip-remove:hover {
  opacity: 1;
  background: color-mix(in srgb, var(--danger, #ff453a) 16%, transparent);
  color: var(--danger, #ff453a);
}
.tachyon-ms__trigger {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  width: 100%;
  min-height: 36px;
  padding: 6px 10px;
  border-radius: var(--r-btn, 8px);
  border: 1px solid var(--border-strong, rgba(128, 128, 128, 0.28));
  background: var(--surface, var(--background-color-high, #141416));
  color: var(--text, var(--text-color-high, inherit));
  font-size: 13px;
  line-height: 1.35;
  text-align: left;
  cursor: pointer;
  box-sizing: border-box;
}
.tachyon-ms.is-open > .tachyon-ms__trigger {
  border-color: var(--accent, #0a84ff);
}
.tachyon-ms__trigger-text {
  flex: 1 1 auto;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.tachyon-ms__trigger-text.is-placeholder {
  color: var(--text2, var(--text-color-medium, #888));
}
.tachyon-ms__trigger-meta {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  flex: 0 0 auto;
}
.tachyon-ms__count-badge {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-width: 20px;
  height: 20px;
  padding: 0 6px;
  border-radius: 6px;
  background: color-mix(in srgb, var(--accent, #0a84ff) 16%, transparent);
  color: var(--accent, #0a84ff);
  font-size: 11px;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
}
.tachyon-ms__panel {
  position: absolute;
  top: calc(100% + 4px);
  left: 0;
  right: 0;
  z-index: 3200;
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding: 8px;
  border-radius: var(--r-btn, 8px);
  border: 1px solid var(--border-strong, rgba(128, 128, 128, 0.28));
  background: var(--elevated, var(--surface, var(--background-color-high, #1c1c1f)));
  color: var(--text, var(--text-color-high, inherit));
  box-shadow: 0 10px 28px rgba(0, 0, 0, 0.28);
  box-sizing: border-box;
}
.tachyon-ms__panel[hidden] {
  display: none !important;
}
.tachyon-ms.is-dropup > .tachyon-ms__panel {
  top: auto;
  bottom: calc(100% + 4px);
}
.tachyon-ms__search-row {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 4px 8px;
  border-radius: var(--r-xs, 6px);
  border: 1px solid var(--border-strong, rgba(128, 128, 128, 0.25));
  background: var(--bg, var(--background-color-medium, rgba(0, 0, 0, 0.12)));
}
.tachyon-ms__search-input {
  flex: 1 1 auto;
  min-width: 0;
  border: 0 !important;
  background: transparent !important;
  color: inherit !important;
  padding: 4px 0 !important;
  margin: 0 !important;
  font-size: 13px !important;
  outline: none !important;
  box-shadow: none !important;
}
.tachyon-ms__stats {
  flex: 0 0 auto;
  font-size: 11px;
  color: var(--text2, var(--text-color-medium, #888));
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}
.tachyon-ms__actions {
  display: flex;
  align-items: center;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 6px;
}
.tachyon-ms__actions-left {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 6px;
}
.tachyon-ms__list {
  max-height: min(260px, 42vh);
  overflow-x: hidden;
  overflow-y: auto;
  display: flex;
  flex-direction: column;
  gap: 2px;
  overscroll-behavior: contain;
}
.tachyon-ms__option {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 6px 8px;
  border-radius: var(--r-xs, 6px);
  border: 1px solid transparent;
  cursor: pointer;
  user-select: none;
  font-size: 12.5px;
  line-height: 1.35;
}
.tachyon-ms__option:hover,
.tachyon-ms__option:focus-visible {
  background: var(--hover, rgba(128, 128, 128, 0.12));
  outline: none;
}
.tachyon-ms__option.is-selected {
  background: color-mix(in srgb, var(--accent, #0a84ff) 12%, transparent);
  border-color: color-mix(in srgb, var(--accent, #0a84ff) 30%, transparent);
}
`;

function ensureMultiSelectFallbackStyles(): void {
  if (typeof document === 'undefined' || !document.head) {
    return;
  }
  if (
    document.getElementById('tachyon-global-styles') ||
    document.getElementById(FALLBACK_STYLE_ID)
  ) {
    return;
  }
  if (typeof document.createElement === 'function') {
    const style = document.createElement('style');
    style.id = FALLBACK_STYLE_ID;
    style.textContent = FALLBACK_STYLES;
    document.head.appendChild(style);
  }
}

function createDomEl<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  attrs?: Record<string, string | boolean | null | undefined>,
  children?: Array<Node | string | null | undefined> | string,
): HTMLElementTagNameMap[K] {
  let node: HTMLElementTagNameMap[K];
  if (typeof E === 'function') {
    const cleanAttrs: Record<string, any> = {};
    if (attrs) {
      for (const [k, v] of Object.entries(attrs)) {
        if (v !== undefined && v !== null && v !== false) {
          cleanAttrs[k] = v === true ? '' : v;
        }
      }
    }
    node = E(tag, cleanAttrs as any);
  } else {
    node = document.createElement(tag);
    if (attrs) {
      for (const [k, v] of Object.entries(attrs)) {
        if (v !== undefined && v !== null && v !== false) {
          node.setAttribute(k, v === true ? '' : String(v));
        }
      }
    }
  }

  if (attrs) {
    if ('disabled' in attrs) {
      (node as any).disabled = Boolean(attrs.disabled);
    }
    if ('hidden' in attrs) {
      (node as any).hidden = Boolean(attrs.hidden);
    }
    if ('type' in attrs && typeof attrs.type === 'string') {
      (node as any).type = attrs.type;
    }
    if ('value' in attrs && typeof attrs.value === 'string') {
      (node as any).value = attrs.value;
    }
  }

  if (children !== undefined) {
    if (typeof children === 'string') {
      node.textContent = children;
    } else if (Array.isArray(children)) {
      for (const ch of children) {
        if (ch == null || ch === '') continue;
        if (typeof ch === 'string') {
          if (typeof document !== 'undefined' && document.createTextNode) {
            node.appendChild(document.createTextNode(ch));
          } else {
            node.textContent += ch;
          }
        } else {
          node.appendChild(ch);
        }
      }
    }
  }

  return node;
}

function createSvgIcon(
  paths: Array<{
    tag: 'path' | 'circle' | 'line';
    attrs: Record<string, string>;
  }>,
  size = 14,
  fallbackText = '',
): Node {
  if (
    typeof document !== 'undefined' &&
    typeof document.createElementNS === 'function'
  ) {
    const ns = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(ns, 'svg');
    svg.setAttribute('xmlns', ns);
    svg.setAttribute('width', String(size));
    svg.setAttribute('height', String(size));
    svg.setAttribute('viewBox', '0 0 24 24');
    svg.setAttribute('fill', 'none');
    svg.setAttribute('stroke', 'currentColor');
    svg.setAttribute('stroke-width', '2');
    svg.setAttribute('stroke-linecap', 'round');
    svg.setAttribute('stroke-linejoin', 'round');
    svg.setAttribute('aria-hidden', 'true');
    for (const p of paths) {
      const child = document.createElementNS(ns, p.tag);
      for (const [k, v] of Object.entries(p.attrs)) {
        child.setAttribute(k, v);
      }
      svg.appendChild(child);
    }
    return svg;
  }
  return createDomEl('span', { 'aria-hidden': 'true' }, fallbackText);
}

function createChevronIcon(): Node {
  return createSvgIcon(
    [{ tag: 'path', attrs: { d: 'm6 9 6 6 6-6' } }],
    14,
    '▾',
  );
}

function createSearchIcon(): Node {
  return createSvgIcon(
    [
      { tag: 'circle', attrs: { cx: '11', cy: '11', r: '8' } },
      { tag: 'path', attrs: { d: 'm21 21-4.3-4.3' } },
    ],
    14,
    '',
  );
}

function createCloseIcon(size = 12): Node {
  return createSvgIcon(
    [
      { tag: 'line', attrs: { x1: '18', y1: '6', x2: '6', y2: '18' } },
      { tag: 'line', attrs: { x1: '6', y1: '6', x2: '18', y2: '18' } },
    ],
    size,
    '×',
  );
}

function clearElement(el: HTMLElement): void {
  if (typeof el.replaceChildren === 'function') {
    el.replaceChildren();
    return;
  }
  while (el.firstChild) {
    el.removeChild(el.firstChild);
  }
  if (Array.isArray((el as any).children)) {
    (el as any).children.length = 0;
  }
  el.textContent = '';
}

function dedupeValues(values: unknown): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  const rawList = Array.isArray(values)
    ? values
    : values != null && `${values}`.trim()
      ? [`${values}`]
      : [];
  for (const item of rawList) {
    const s = `${item ?? ''}`.trim();
    if (!s || seen.has(s)) continue;
    seen.add(s);
    out.push(s);
  }
  return out;
}

export function normalizeMultiSelectChoices(
  rawChoices?: SearchableCheckboxMultiSelectOptions['choices'],
): MultiSelectChoice[] {
  if (!rawChoices) return [];
  const seen = new Set<string>();
  const result: MultiSelectChoice[] = [];

  const pushChoice = (
    valueRaw: unknown,
    labelRaw?: unknown,
    badge?: string,
    secondaryBadge?: string,
  ) => {
    const value = `${valueRaw ?? ''}`.trim();
    if (!value || seen.has(value)) return;
    seen.add(value);
    const labelStr = `${labelRaw ?? ''}`.trim();
    result.push({
      value,
      label: labelStr || value,
      ...(badge ? { badge } : {}),
      ...(secondaryBadge ? { secondaryBadge } : {}),
    });
  };

  if (Array.isArray(rawChoices)) {
    for (const item of rawChoices) {
      if (item == null) continue;
      if (typeof item === 'string') {
        pushChoice(item, item);
      } else if (Array.isArray(item)) {
        pushChoice(item[0], item[1] ?? item[0]);
      } else if (typeof item === 'object') {
        pushChoice(
          item.value,
          item.label ?? item.value,
          item.badge,
          item.secondaryBadge,
        );
      }
    }
  } else if (typeof rawChoices === 'object') {
    for (const [val, lbl] of Object.entries(rawChoices)) {
      pushChoice(val, lbl);
    }
  }

  return result;
}

function extractOptionChoices(option: any): MultiSelectChoice[] {
  const keys: any[] = Array.isArray(option?.keylist) ? option.keylist : [];
  const vals: any[] = Array.isArray(option?.vallist) ? option.vallist : [];
  if (keys.length > 0) {
    return normalizeMultiSelectChoices(
      keys.map((k, idx) => ({
        value: `${k ?? ''}`,
        label: `${vals[idx] ?? k ?? ''}`,
      })),
    );
  }
  if (option && typeof option.transformChoices === 'function') {
    try {
      const transformed = option.transformChoices();
      if (transformed && typeof transformed === 'object') {
        return normalizeMultiSelectChoices(transformed);
      }
    } catch {
      /* ignore */
    }
  }
  return [];
}

function extractWidgetChoices(widget: any, option?: any): MultiSelectChoice[] {
  const fromOption = option ? extractOptionChoices(option) : [];
  const rawChoices =
    widget && widget.choices && typeof widget.choices === 'object'
      ? widget.choices
      : null;

  if (rawChoices && Array.isArray(widget?.options?.sort)) {
    const sortKeys: string[] = widget.options.sort;
    const ordered: MultiSelectChoice[] = [];
    const used = new Set<string>();
    for (const k of sortKeys) {
      const key = `${k ?? ''}`.trim();
      if (!key || used.has(key)) continue;
      if (Object.prototype.hasOwnProperty.call(rawChoices, key)) {
        used.add(key);
        ordered.push({ value: key, label: `${rawChoices[key] || key}` });
      }
    }
    for (const [k, v] of Object.entries(rawChoices)) {
      const key = `${k ?? ''}`.trim();
      if (!key || used.has(key)) continue;
      used.add(key);
      ordered.push({ value: key, label: `${v || key}` });
    }
    if (ordered.length > 0) return ordered;
  }

  if (rawChoices && Object.keys(rawChoices).length > 0) {
    if (fromOption.length > 0) {
      const map = new Map<string, MultiSelectChoice>();
      for (const c of fromOption) map.set(c.value, c);
      for (const [k, v] of Object.entries(rawChoices)) {
        if (!map.has(k)) {
          map.set(k, { value: k, label: `${v || k}` });
        } else if (v) {
          map.get(k)!.label = `${v}`;
        }
      }
      return Array.from(map.values());
    }
    return normalizeMultiSelectChoices(rawChoices as Record<string, string>);
  }

  return fromOption;
}

export function createSearchableCheckboxMultiSelect(
  options: SearchableCheckboxMultiSelectOptions = {},
): SearchableCheckboxMultiSelectHandle {
  ensureMultiSelectFallbackStyles();

  const batchSize =
    typeof options.batchSize === 'number' && options.batchSize > 0
      ? Math.floor(options.batchSize)
      : DEFAULT_BATCH_SIZE;
  const selectVisibleLimit =
    typeof options.selectVisibleLimit === 'number' &&
    options.selectVisibleLimit > 0
      ? Math.floor(options.selectVisibleLimit)
      : DEFAULT_SELECT_VISIBLE_LIMIT;
  const maxVisibleChips =
    typeof options.maxVisibleChips === 'number' && options.maxVisibleChips > 0
      ? Math.floor(options.maxVisibleChips)
      : DEFAULT_MAX_VISIBLE_CHIPS;
  const allowCustom = Boolean(options.allowCustom);
  const showChips = options.showChips !== false;

  let choices = normalizeMultiSelectChoices(options.choices);
  let labelByValue = new Map<string, string>(
    choices.map((c) => [c.value, c.label]),
  );
  let selectedValues = dedupeValues(options.values);
  let selectedSet = new Set<string>(selectedValues);
  let isOpenState = false;
  let isDisabled = Boolean(options.disabled);
  let searchQuery = '';
  let visibleLimit = batchSize;
  let chipsExpanded = false;
  let panelBuilt = false;
  let lastFilteredChoices: MultiSelectChoice[] = [];
  const optionRowsByValue = new Map<
    string,
    { row: HTMLElement; checkbox: HTMLInputElement }
  >();

  const root = createDomEl('div', {
    class: `tachyon-ms${isDisabled ? ' is-disabled' : ''}`,
  });

  const chipsEl = createDomEl('div', {
    class: 'tachyon-ms__chips',
    hidden: true,
  });

  const triggerTextEl = createDomEl(
    'span',
    { class: 'tachyon-ms__trigger-text is-placeholder' },
    options.placeholder || tr('-- Выбрать --', '-- Select --'),
  );
  const countBadgeEl = createDomEl(
    'span',
    { class: 'tachyon-ms__count-badge', hidden: true },
    '0',
  );
  const chevronEl = createDomEl('span', { class: 'tachyon-ms__chevron' }, [
    createChevronIcon(),
  ]);
  const triggerBtn = createDomEl(
    'button',
    {
      type: 'button',
      class: 'tachyon-ms__trigger',
      'aria-haspopup': 'listbox',
      'aria-expanded': 'false',
      disabled: isDisabled,
    },
    [
      triggerTextEl,
      createDomEl('span', { class: 'tachyon-ms__trigger-meta' }, [
        countBadgeEl,
        chevronEl,
      ]),
    ],
  ) as HTMLButtonElement;

  const searchInput = createDomEl('input', {
    type: 'text',
    class: 'tachyon-ms__search-input',
    placeholder: options.searchPlaceholder || tr('Поиск...', 'Search...'),
    'aria-label': options.searchPlaceholder || tr('Поиск...', 'Search...'),
  }) as HTMLInputElement;

  const searchClearBtn = createDomEl(
    'button',
    {
      type: 'button',
      class: 'tachyon-ms__search-clear',
      title: tr('Очистить поиск', 'Clear search'),
      'aria-label': tr('Очистить поиск', 'Clear search'),
      hidden: true,
    },
    [createCloseIcon(12)],
  ) as HTMLButtonElement;

  const statsEl = createDomEl('span', { class: 'tachyon-ms__stats' }, '0 / 0');

  const selectVisibleBtn = createDomEl(
    'button',
    {
      type: 'button',
      class: 'tachyon-ms__action-btn',
      'data-action': 'select-visible',
    },
    tr('Выбрать видимые', 'Select visible'),
  ) as HTMLButtonElement;

  const clearAllBtn = createDomEl(
    'button',
    {
      type: 'button',
      class: 'tachyon-ms__action-btn is-clear',
      'data-action': 'clear-all',
    },
    tr('Снять все', 'Clear all'),
  ) as HTMLButtonElement;

  const doneBtn = createDomEl(
    'button',
    {
      type: 'button',
      class: 'tachyon-ms__action-btn is-done',
      'data-action': 'done',
    },
    tr('Готово', 'Done'),
  ) as HTMLButtonElement;

  const errorEl = createDomEl('div', {
    class: 'tachyon-ms__error',
    role: 'alert',
    hidden: true,
  });

  const customAddWrap = createDomEl('div', {
    class: 'tachyon-ms__custom-add',
    hidden: true,
  });
  const customAddBtn = createDomEl(
    'button',
    {
      type: 'button',
      class: 'tachyon-ms__custom-add-btn',
    },
    '',
  ) as HTMLButtonElement;
  customAddWrap.appendChild(customAddBtn);

  const listEl = createDomEl('div', {
    class: 'tachyon-ms__list',
    role: 'listbox',
    'aria-multiselectable': 'true',
  });

  const panelEl = createDomEl(
    'div',
    {
      class: 'tachyon-ms__panel',
      role: 'dialog',
      hidden: true,
    },
    [
      createDomEl('div', { class: 'tachyon-ms__search-row' }, [
        createDomEl('span', { class: 'tachyon-ms__search-icon' }, [
          createSearchIcon(),
        ]),
        searchInput,
        searchClearBtn,
        statsEl,
      ]),
      createDomEl('div', { class: 'tachyon-ms__actions' }, [
        createDomEl('div', { class: 'tachyon-ms__actions-left' }, [
          selectVisibleBtn,
          clearAllBtn,
        ]),
        doneBtn,
      ]),
      errorEl,
      customAddWrap,
      listEl,
    ],
  );

  root.appendChild(chipsEl);
  root.appendChild(triggerBtn);
  root.appendChild(panelEl);

  function showError(message: string | null): void {
    if (!message) {
      errorEl.textContent = '';
      errorEl.hidden = true;
      errorEl.setAttribute('hidden', '');
      return;
    }
    errorEl.textContent = message;
    errorEl.hidden = false;
    errorEl.removeAttribute('hidden');
  }

  function labelForValue(value: string): string {
    return labelByValue.get(value) || value;
  }

  function getMergedChoices(): MultiSelectChoice[] {
    const merged = choices.slice();
    for (const val of selectedValues) {
      if (!labelByValue.has(val)) {
        merged.unshift({ value: val, label: val });
      }
    }
    return merged;
  }

  function computeFilteredChoices(): MultiSelectChoice[] {
    const merged = getMergedChoices();
    const q = searchQuery.trim().toLowerCase();
    if (!q) return merged;
    return merged.filter(
      (c) =>
        c.label.toLowerCase().includes(q) || c.value.toLowerCase().includes(q),
    );
  }

  function renderTriggerSummary(): void {
    const count = selectedValues.length;
    const basePlaceholder =
      options.placeholder || tr('-- Выбрать --', '-- Select --');
    if (count === 0) {
      triggerTextEl.textContent = basePlaceholder;
      triggerTextEl.classList.add('is-placeholder');
      countBadgeEl.hidden = true;
      countBadgeEl.setAttribute('hidden', '');
      countBadgeEl.textContent = '0';
    } else {
      const preview = selectedValues.slice(0, 2).map(labelForValue).join(', ');
      const suffix = count > 2 ? `, +${count - 2}` : '';
      triggerTextEl.textContent = `${tr('Выбрано', 'Selected')}: ${count} (${preview}${suffix})`;
      triggerTextEl.classList.remove('is-placeholder');
      countBadgeEl.textContent = String(count);
      countBadgeEl.hidden = false;
      countBadgeEl.removeAttribute('hidden');
    }
  }

  function renderChips(): void {
    clearElement(chipsEl);
    if (!showChips || selectedValues.length === 0) {
      chipsEl.hidden = true;
      chipsEl.setAttribute('hidden', '');
      return;
    }
    chipsEl.hidden = false;
    chipsEl.removeAttribute('hidden');

    const limit = chipsExpanded
      ? selectedValues.length
      : Math.min(selectedValues.length, maxVisibleChips);
    const frag =
      typeof document !== 'undefined' &&
      typeof document.createDocumentFragment === 'function'
        ? document.createDocumentFragment()
        : null;
    const target: Node = frag || chipsEl;

    for (let i = 0; i < limit; i += 1) {
      const val = selectedValues[i];
      const lbl = labelForValue(val);
      const chipLabel = createDomEl(
        'span',
        { class: 'tachyon-ms__chip-label' },
        lbl,
      );
      const removeBtn = createDomEl(
        'button',
        {
          type: 'button',
          class: 'tachyon-ms__chip-remove',
          'aria-label': `${tr('Убрать', 'Remove')}: ${lbl}`,
          title: `${tr('Убрать', 'Remove')}: ${lbl}`,
          disabled: isDisabled,
          hidden: isDisabled,
        },
        [createCloseIcon(11)],
      ) as HTMLButtonElement;
      removeBtn.addEventListener('click', (ev) => {
        ev.preventDefault();
        ev.stopPropagation();
        if (isDisabled) return;
        removeValue(val);
      });

      const chip = createDomEl(
        'span',
        {
          class: 'tachyon-ms__chip',
          'data-value': val,
          title: lbl !== val ? `${lbl} (${val})` : lbl,
        },
        [chipLabel, removeBtn],
      );
      target.appendChild(chip);
    }

    if (selectedValues.length > maxVisibleChips) {
      const hiddenCount = selectedValues.length - maxVisibleChips;
      const toggleChipsBtn = createDomEl(
        'button',
        {
          type: 'button',
          class: 'tachyon-ms__chips-toggle',
        },
        chipsExpanded
          ? tr('Свернуть', 'Show less')
          : `+${hiddenCount} ${tr('ещё', 'more')}`,
      ) as HTMLButtonElement;
      toggleChipsBtn.addEventListener('click', (ev) => {
        ev.preventDefault();
        ev.stopPropagation();
        chipsExpanded = !chipsExpanded;
        renderChips();
      });
      target.appendChild(toggleChipsBtn);
    }

    if (frag) {
      chipsEl.appendChild(frag);
    }
  }

  function createOptionRow(choice: MultiSelectChoice): HTMLElement {
    const active = selectedSet.has(choice.value);
    const checkbox = createDomEl('input', {
      type: 'checkbox',
      class: 'tachyon-ms__checkbox',
      tabindex: '-1',
    }) as HTMLInputElement;
    checkbox.checked = active;

    const labelEl = createDomEl(
      'span',
      { class: 'tachyon-ms__option-label' },
      choice.label,
    );

    const rowChildren: Node[] = [checkbox, labelEl];
    if (choice.badge) {
      rowChildren.push(
        createDomEl(
          'span',
          { class: 'tachyon-ms__option-badge' },
          choice.badge,
        ),
      );
    }
    if (choice.secondaryBadge) {
      rowChildren.push(
        createDomEl(
          'span',
          { class: 'tachyon-ms__option-badge is-secondary' },
          choice.secondaryBadge,
        ),
      );
    }

    const row = createDomEl(
      'div',
      {
        class: `tachyon-ms__option${active ? ' is-selected' : ''}`,
        role: 'option',
        tabindex: '-1',
        'data-value': choice.value,
        'aria-selected': active ? 'true' : 'false',
      },
      rowChildren,
    );

    const handleRowClick = (ev: Event) => {
      if (ev.target === checkbox) return;
      ev.preventDefault();
      ev.stopPropagation();
      if (!isDisabled) {
        toggleValue(choice.value);
      }
      checkbox.checked = selectedSet.has(choice.value);
    };

    checkbox.addEventListener('click', (ev: Event) => {
      ev.stopPropagation();
      if (!isDisabled) {
        toggleValue(choice.value);
      }
      checkbox.checked = selectedSet.has(choice.value);
    });
    checkbox.addEventListener('change', (ev: Event) => {
      ev.stopPropagation();
    });
    row.addEventListener('click', handleRowClick);
    row.addEventListener('keydown', (ev: KeyboardEvent) => {
      if (ev.key === 'Enter' || ev.key === ' ') {
        ev.preventDefault();
        ev.stopPropagation();
        if (!isDisabled) toggleValue(choice.value);
      } else if (ev.key === 'ArrowDown') {
        ev.preventDefault();
        const next = row.nextElementSibling as HTMLElement | null;
        if (next && next.classList.contains('tachyon-ms__option')) {
          next.focus?.();
        }
      } else if (ev.key === 'ArrowUp') {
        ev.preventDefault();
        const prev = row.previousElementSibling as HTMLElement | null;
        if (prev && prev.classList.contains('tachyon-ms__option')) {
          prev.focus?.();
        } else {
          searchInput.focus?.();
        }
      }
    });

    optionRowsByValue.set(choice.value, { row, checkbox });
    return row;
  }

  function appendMoreWrapIfNeeded(
    filteredLength: number,
    renderedCount: number,
  ): void {
    const existingMore = listEl.querySelector?.('.tachyon-ms__more-wrap');
    if (existingMore && existingMore.parentNode === listEl) {
      listEl.removeChild(existingMore);
    }
    if (renderedCount >= filteredLength) return;

    const remaining = filteredLength - renderedCount;
    const nextStep = Math.min(batchSize, remaining);
    const moreBtn = createDomEl(
      'button',
      {
        type: 'button',
        class: 'tachyon-ms__more-btn',
      },
      `${tr('Показать ещё', 'Show more')} ${nextStep} (${tr('осталось', 'remaining')}: ${remaining})`,
    ) as HTMLButtonElement;
    moreBtn.addEventListener('click', (ev) => {
      ev.preventDefault();
      ev.stopPropagation();
      loadNextBatch();
    });
    const moreWrap = createDomEl('div', { class: 'tachyon-ms__more-wrap' }, [
      moreBtn,
    ]);
    listEl.appendChild(moreWrap);
  }

  function updatePanelChrome(
    filtered: MultiSelectChoice[],
    renderedCount: number,
  ): void {
    const totalCount = getMergedChoices().length;
    const trimmed = searchQuery.trim();
    const hasQuery = trimmed.length > 0;

    searchClearBtn.hidden = !hasQuery;
    if (hasQuery) searchClearBtn.removeAttribute('hidden');
    else searchClearBtn.setAttribute('hidden', '');

    statsEl.textContent = hasQuery
      ? `${filtered.length} / ${totalCount}`
      : `${renderedCount < filtered.length ? `${renderedCount} / ` : ''}${totalCount}`;

    const canSelectVisible = hasQuery || filtered.length <= selectVisibleLimit;
    selectVisibleBtn.hidden = !canSelectVisible;
    selectVisibleBtn.disabled = !canSelectVisible || filtered.length === 0;
    if (canSelectVisible) selectVisibleBtn.removeAttribute('hidden');
    else selectVisibleBtn.setAttribute('hidden', '');

    clearAllBtn.disabled = selectedValues.length === 0;

    if (
      allowCustom &&
      trimmed &&
      !selectedSet.has(trimmed) &&
      !choices.some((c) => c.value === trimmed)
    ) {
      customAddBtn.textContent = `+ ${tr('Добавить', 'Add')} "${trimmed}"`;
      customAddWrap.hidden = false;
      customAddWrap.removeAttribute('hidden');
    } else {
      customAddWrap.hidden = true;
      customAddWrap.setAttribute('hidden', '');
    }
  }

  function renderPanelList(): void {
    if (!isOpenState) return;
    panelBuilt = true;
    const filtered = computeFilteredChoices();
    lastFilteredChoices = filtered;

    clearElement(listEl);
    optionRowsByValue.clear();

    const sliceEnd = Math.min(filtered.length, visibleLimit);
    const frag =
      typeof document !== 'undefined' &&
      typeof document.createDocumentFragment === 'function'
        ? document.createDocumentFragment()
        : null;
    const target: Node = frag || listEl;

    if (filtered.length === 0) {
      const hasQuery = searchQuery.trim().length > 0;
      target.appendChild(
        createDomEl(
          'div',
          { class: 'tachyon-ms__empty' },
          hasQuery
            ? tr('Ничего не найдено', 'No matches found')
            : tr('Нет доступных вариантов', 'No options available'),
        ),
      );
    } else {
      for (let i = 0; i < sliceEnd; i += 1) {
        target.appendChild(createOptionRow(filtered[i]));
      }
    }

    if (frag) {
      listEl.appendChild(frag);
    }

    appendMoreWrapIfNeeded(filtered.length, sliceEnd);
    updatePanelChrome(filtered, sliceEnd);
  }

  function loadNextBatch(): void {
    if (!isOpenState) return;
    const filtered = lastFilteredChoices;
    const prevEnd = Math.min(filtered.length, visibleLimit);
    if (prevEnd >= filtered.length) return;
    visibleLimit += batchSize;
    const nextEnd = Math.min(filtered.length, visibleLimit);

    const existingMore = listEl.querySelector?.('.tachyon-ms__more-wrap');
    if (existingMore && existingMore.parentNode === listEl) {
      listEl.removeChild(existingMore);
    }

    const frag =
      typeof document !== 'undefined' &&
      typeof document.createDocumentFragment === 'function'
        ? document.createDocumentFragment()
        : null;
    const target: Node = frag || listEl;
    for (let i = prevEnd; i < nextEnd; i += 1) {
      target.appendChild(createOptionRow(filtered[i]));
    }
    if (frag) {
      listEl.appendChild(frag);
    }

    appendMoreWrapIfNeeded(filtered.length, nextEnd);
    updatePanelChrome(filtered, nextEnd);
  }

  function syncRowStatesInPlace(): void {
    for (const [val, entry] of optionRowsByValue.entries()) {
      const active = selectedSet.has(val);
      entry.checkbox.checked = active;
      entry.row.classList.toggle('is-selected', active);
      entry.row.setAttribute('aria-selected', active ? 'true' : 'false');
    }
    clearAllBtn.disabled = selectedValues.length === 0;
  }

  function commitValues(
    nextRaw: string[],
    source: 'user' | 'external',
    silent = false,
  ): void {
    selectedValues = dedupeValues(nextRaw);
    selectedSet = new Set(selectedValues);
    renderTriggerSummary();
    renderChips();
    if (isOpenState && panelBuilt) {
      // If a newly added custom value isn't in the rendered rows, re-render list; otherwise fast in-place update
      const needsListRebuild = selectedValues.some(
        (v) => !labelByValue.has(v) && !optionRowsByValue.has(v),
      );
      if (needsListRebuild) {
        renderPanelList();
      } else {
        syncRowStatesInPlace();
      }
    }
    if (!silent && typeof options.onChange === 'function') {
      options.onChange(selectedValues.slice(), { source });
    }
  }

  function addValidatedValue(value: string): boolean {
    const trimmed = `${value || ''}`.trim();
    if (!trimmed) return false;
    if (selectedSet.has(trimmed)) {
      showError(null);
      return true;
    }
    if (typeof options.validateItem === 'function') {
      const verdict = options.validateItem(trimmed);
      if (verdict !== true) {
        showError(
          typeof verdict === 'string' && verdict
            ? verdict
            : tr('Некорректное значение', 'Invalid value'),
        );
        return false;
      }
    }
    showError(null);
    commitValues([...selectedValues, trimmed], 'user');
    return true;
  }

  function removeValue(value: string): void {
    showError(null);
    commitValues(
      selectedValues.filter((v) => v !== value),
      'user',
    );
  }

  function toggleValue(value: string): void {
    if (selectedSet.has(value)) {
      removeValue(value);
    } else {
      addValidatedValue(value);
    }
  }

  function updatePanelDirection(): void {
    if (
      typeof triggerBtn.getBoundingClientRect !== 'function' ||
      typeof window === 'undefined'
    ) {
      return;
    }
    const rect = triggerBtn.getBoundingClientRect();
    const spaceBelow = (window.innerHeight || 800) - rect.bottom;
    const spaceAbove = rect.top;
    const shouldFlip = spaceBelow < 240 && spaceAbove > spaceBelow;
    root.classList.toggle('is-dropup', shouldFlip);
  }

  const onDocumentPointerDown = (ev: Event) => {
    if (!isOpenState) return;
    const target = ev.target as Node | null;
    if (
      target &&
      typeof root.contains === 'function' &&
      root.contains(target)
    ) {
      return;
    }
    close();
  };

  function bindOutsideListener(): void {
    if (typeof document === 'undefined' || !document.addEventListener) return;
    document.addEventListener('pointerdown', onDocumentPointerDown, true);
    document.addEventListener('mousedown', onDocumentPointerDown, true);
  }

  function unbindOutsideListener(): void {
    if (typeof document === 'undefined' || !document.removeEventListener)
      return;
    document.removeEventListener('pointerdown', onDocumentPointerDown, true);
    document.removeEventListener('mousedown', onDocumentPointerDown, true);
  }

  function open(): void {
    if (isDisabled || isOpenState) return;
    if (typeof options.onBeforeOpen === 'function') {
      try {
        const res = options.onBeforeOpen();
        if (res && typeof (res as Promise<void>).then === 'function') {
          (res as Promise<void>).then(() => {
            if (isOpenState) renderPanelList();
          });
        }
      } catch {
        /* ignore pre-open hook errors */
      }
    }
    isOpenState = true;
    visibleLimit = batchSize;
    root.classList.add('is-open');
    triggerBtn.setAttribute('aria-expanded', 'true');
    panelEl.hidden = false;
    panelEl.removeAttribute('hidden');
    updatePanelDirection();
    renderPanelList();
    bindOutsideListener();
    searchInput.focus?.();
  }

  function close(opts?: { focusTrigger?: boolean }): void {
    if (!isOpenState) return;
    isOpenState = false;
    root.classList.remove('is-open');
    root.classList.remove('is-dropup');
    triggerBtn.setAttribute('aria-expanded', 'false');
    panelEl.hidden = true;
    panelEl.setAttribute('hidden', '');
    showError(null);
    unbindOutsideListener();
    if (opts?.focusTrigger) {
      triggerBtn.focus?.();
    }
  }

  triggerBtn.addEventListener('click', (ev) => {
    ev.preventDefault();
    ev.stopPropagation();
    if (isDisabled) return;
    if (isOpenState) close();
    else open();
  });

  triggerBtn.addEventListener('keydown', (ev: KeyboardEvent) => {
    if (isDisabled) return;
    if (
      !isOpenState &&
      (ev.key === 'ArrowDown' || ev.key === 'Enter' || ev.key === ' ')
    ) {
      ev.preventDefault();
      ev.stopPropagation();
      open();
    } else if (isOpenState && ev.key === 'Escape') {
      ev.preventDefault();
      ev.stopPropagation();
      close({ focusTrigger: true });
    }
  });

  searchInput.addEventListener('input', () => {
    searchQuery = searchInput.value || '';
    visibleLimit = batchSize;
    showError(null);
    renderPanelList();
  });

  searchInput.addEventListener('keydown', (ev: KeyboardEvent) => {
    if (ev.key === 'Escape') {
      ev.preventDefault();
      ev.stopPropagation();
      close({ focusTrigger: true });
      return;
    }
    if (ev.key === 'Enter') {
      ev.preventDefault();
      ev.stopPropagation();
      if (lastFilteredChoices.length === 1) {
        toggleValue(lastFilteredChoices[0].value);
        return;
      }
      const trimmed = searchQuery.trim();
      if (lastFilteredChoices.length === 0 && allowCustom && trimmed) {
        if (addValidatedValue(trimmed)) {
          searchQuery = '';
          searchInput.value = '';
          visibleLimit = batchSize;
          renderPanelList();
        }
        return;
      }
      const firstRow = listEl.querySelector?.(
        '.tachyon-ms__option',
      ) as HTMLElement | null;
      firstRow?.focus?.();
      return;
    }
    if (ev.key === 'ArrowDown') {
      ev.preventDefault();
      const firstRow = listEl.querySelector?.(
        '.tachyon-ms__option',
      ) as HTMLElement | null;
      firstRow?.focus?.();
    }
  });

  panelEl.addEventListener('keydown', (ev: KeyboardEvent) => {
    if (ev.key === 'Escape') {
      ev.preventDefault();
      ev.stopPropagation();
      close({ focusTrigger: true });
    }
  });

  searchClearBtn.addEventListener('click', (ev) => {
    ev.preventDefault();
    ev.stopPropagation();
    searchQuery = '';
    searchInput.value = '';
    visibleLimit = batchSize;
    showError(null);
    renderPanelList();
    searchInput.focus?.();
  });

  selectVisibleBtn.addEventListener('click', (ev) => {
    ev.preventDefault();
    ev.stopPropagation();
    if (isDisabled) return;
    const next = selectedValues.slice();
    let errorMsg: string | null = null;
    for (const item of lastFilteredChoices) {
      if (selectedSet.has(item.value)) continue;
      if (typeof options.validateItem === 'function') {
        const verdict = options.validateItem(item.value);
        if (verdict !== true) {
          errorMsg =
            typeof verdict === 'string' && verdict
              ? verdict
              : tr('Некорректное значение', 'Invalid value');
          continue;
        }
      }
      next.push(item.value);
    }
    showError(errorMsg);
    commitValues(next, 'user');
  });

  clearAllBtn.addEventListener('click', (ev) => {
    ev.preventDefault();
    ev.stopPropagation();
    if (isDisabled) return;
    showError(null);
    commitValues([], 'user');
  });

  doneBtn.addEventListener('click', (ev) => {
    ev.preventDefault();
    ev.stopPropagation();
    close({ focusTrigger: true });
  });

  customAddBtn.addEventListener('click', (ev) => {
    ev.preventDefault();
    ev.stopPropagation();
    if (isDisabled) return;
    const trimmed = searchQuery.trim();
    if (!trimmed) return;
    if (addValidatedValue(trimmed)) {
      searchQuery = '';
      searchInput.value = '';
      visibleLimit = batchSize;
      renderPanelList();
      searchInput.focus?.();
    }
  });

  listEl.addEventListener('scroll', () => {
    if (!isOpenState) return;
    if (visibleLimit >= lastFilteredChoices.length) return;
    const scrollTop = (listEl as any).scrollTop || 0;
    const clientHeight = (listEl as any).clientHeight || 0;
    const scrollHeight = (listEl as any).scrollHeight || 0;
    if (scrollHeight > 0 && scrollTop + clientHeight >= scrollHeight - 48) {
      loadNextBatch();
    }
  });

  renderTriggerSummary();
  renderChips();

  const refreshChoicesFn = (
    nextChoices: SearchableCheckboxMultiSelectOptions['choices'],
  ) => {
    choices = normalizeMultiSelectChoices(nextChoices);
    labelByValue = new Map(choices.map((c) => [c.value, c.label]));
    renderTriggerSummary();
    renderChips();
    if (isOpenState) {
      renderPanelList();
    }
  };

  return {
    element: root,
    trigger: triggerBtn,
    panel: panelEl,
    searchInput,
    listElement: listEl,
    chipsElement: chipsEl,
    isOpen: () => isOpenState,
    open,
    close,
    getValues: () => selectedValues.slice(),
    setValues: (nextValues: string[], opts?: { silent?: boolean }) => {
      commitValues(nextValues, 'external', Boolean(opts?.silent));
    },
    refreshChoices: refreshChoicesFn,
    updateChoices: refreshChoicesFn,
    setDisabled: (disabled: boolean) => {
      isDisabled = Boolean(disabled);
      root.classList.toggle('is-disabled', isDisabled);
      triggerBtn.disabled = isDisabled;
      if (isDisabled && isOpenState) close();
      renderChips();
    },
    destroy: () => {
      close();
      unbindOutsideListener();
      if (root.parentNode) {
        root.parentNode.removeChild(root);
      }
    },
  };
}

function readDomDynListHiddenValues(node: HTMLElement): string[] {
  if (!node || typeof node.querySelectorAll !== 'function') return [];
  const inputs = Array.from(
    node.querySelectorAll('.item > input[type="hidden"]'),
  ) as HTMLInputElement[];
  return dedupeValues(inputs.map((inp) => inp.value));
}

function readDynListValues(widget: any, node: HTMLElement): string[] {
  const domValues = readDomDynListHiddenValues(node);
  if (widget && typeof widget.getValue === 'function') {
    try {
      const val = widget.getValue();
      const widgetValues = dedupeValues(val);
      if (widgetValues.length > 0 || domValues.length === 0) {
        return widgetValues;
      }
    } catch {
      /* fallback to DOM */
    }
  }
  return domValues;
}

function ensureDynListDomItems(
  node: HTMLElement,
  values: string[],
  labelMap: Record<string, string>,
  inputName: string,
  widget?: any,
): void {
  if (!node || typeof node.querySelectorAll !== 'function') return;
  const anchor =
    node.querySelector?.('.tachyon-ms') ||
    node.querySelector?.('.add-item') ||
    null;
  const existingItems = Array.from(
    node.querySelectorAll('.item'),
  ) as HTMLElement[];
  const hasMisplacedItem =
    Boolean(anchor) &&
    existingItems.some(
      (el) =>
        typeof el.compareDocumentPosition === 'function' &&
        (el.compareDocumentPosition(anchor as Node) & 2) !== 0,
    );
  const currentDom = readDomDynListHiddenValues(node);
  if (
    !hasMisplacedItem &&
    currentDom.length === values.length &&
    currentDom.every((v, idx) => v === values[idx])
  ) {
    return;
  }

  const desiredSet = new Set(values);
  const existingByValue = new Map<string, HTMLElement>();

  for (const item of existingItems) {
    const hidden = item.querySelector?.(
      'input[type="hidden"]',
    ) as HTMLInputElement | null;
    const itemVal = hidden ? `${hidden.value || ''}`.trim() : '';
    if (!itemVal || !desiredSet.has(itemVal) || existingByValue.has(itemVal)) {
      if (item.parentNode === node) {
        node.removeChild(item);
      }
    } else {
      existingByValue.set(itemVal, item);
    }
  }

  const insertBeforeAnchor = (el: HTMLElement) => {
    if (anchor && typeof node.insertBefore === 'function') {
      node.insertBefore(el, anchor);
    } else {
      node.appendChild(el);
    }
  };

  for (let i = 0; i < values.length; i += 1) {
    const val = values[i];
    let itemEl = existingByValue.get(val);
    if (!itemEl) {
      if (widget && typeof widget.addItem === 'function') {
        try {
          widget.addItem(node, val, labelMap[val] || val, false);
          const refreshedItems = Array.from(
            node.querySelectorAll('.item'),
          ) as HTMLElement[];
          itemEl = refreshedItems.find((el) => {
            const h = el.querySelector?.(
              'input[type="hidden"]',
            ) as HTMLInputElement | null;
            return h && h.value === val;
          });
        } catch {
          itemEl = undefined;
        }
      }
      if (!itemEl) {
        const hidden = createDomEl('input', {
          type: 'hidden',
          name: inputName,
          value: val,
        }) as HTMLInputElement;
        hidden.value = val;
        const textSpan = createDomEl('span', {}, labelMap[val] || val);
        itemEl = createDomEl(
          'div',
          {
            class: 'item',
            'data-index': String(i),
          },
          [hidden, textSpan],
        );
      }
    }
    itemEl.setAttribute?.('data-index', String(i));
    insertBeforeAnchor(itemEl);
  }
}

function dispatchDynListEvents(node: HTMLElement): void {
  if (!node || typeof node.dispatchEvent !== 'function') return;
  try {
    if (typeof CustomEvent === 'function') {
      node.dispatchEvent(
        new CustomEvent('cbi-dynlist-change', { bubbles: true }),
      );
      node.dispatchEvent(new CustomEvent('widget-change', { bubbles: true }));
    } else if (typeof Event === 'function') {
      node.dispatchEvent(new Event('cbi-dynlist-change', { bubbles: true }));
      node.dispatchEvent(new Event('widget-change', { bubbles: true }));
    }
    if (typeof Event === 'function') {
      node.dispatchEvent(new Event('change', { bubbles: true }));
    }
  } catch {
    /* ignore in minimal mock DOMs */
  }
}

export function attachSearchableCheckboxMultiSelect(
  widget: any,
  node: HTMLElement,
  config: AttachSearchableMultiSelectOptions = {},
): AttachedDynamicListHandle | null {
  if (!node || typeof node.querySelector !== 'function') {
    return null;
  }
  const existing = (node as any).__tachyonMultiSelectHandle as
    | AttachedDynamicListHandle
    | undefined;
  if (existing) {
    if (config.choices !== undefined) {
      existing.refreshChoices(config.choices);
    }
    existing.syncFromWidget();
    return existing;
  }

  let activeWidget: any = widget || null;
  let internalSync = false;

  const showChips = config.showChips !== false;
  node.classList.add(
    showChips
      ? 'tachyon-dynlist-has-ms'
      : 'tachyon-dynlist-has-ms-items-visible',
  );

  let initialChoices =
    config.choices !== undefined
      ? normalizeMultiSelectChoices(config.choices)
      : extractWidgetChoices(activeWidget, config.option);

  let currentLabelMap: Record<string, string> = {};
  for (const c of initialChoices) {
    currentLabelMap[c.value] = c.label;
  }

  const inputName =
    config.inputName ||
    config.option?.cbid?.(config.sectionId) ||
    activeWidget?.options?.id ||
    node.id ||
    '';
  const initialValues = readDynListValues(activeWidget, node);

  const syncFromWidget = () => {
    if (internalSync) return;
    const w = activeWidget;
    const latest = readDynListValues(w, node);
    const cur = ms.getValues();
    if (
      latest.length !== cur.length ||
      latest.some((v, idx) => v !== cur[idx])
    ) {
      ms.setValues(latest, { silent: true });
    }
  };

  const wrapWidgetSetValue = (w: any) => {
    if (
      w &&
      typeof w.setValue === 'function' &&
      !w.__tachyonMsWrappedSetValue
    ) {
      w.__tachyonMsWrappedSetValue = true;
      const origSetValue = w.setValue.bind(w);
      w.setValue = function (vals: any) {
        const res = origSetValue(vals);
        if (!internalSync) {
          syncFromWidget();
        }
        return res;
      };
    }
  };

  const resolveWidget = (): any => {
    if (!activeWidget) {
      if (
        typeof dom !== 'undefined' &&
        dom &&
        typeof dom.findClassInstance === 'function'
      ) {
        try {
          activeWidget = dom.findClassInstance(node) || null;
        } catch {
          activeWidget = null;
        }
      }
      if (
        !activeWidget &&
        config.option &&
        typeof config.option.getUIElement === 'function'
      ) {
        try {
          activeWidget = config.option.getUIElement(config.sectionId) || null;
        } catch {
          activeWidget = null;
        }
      }
    }
    wrapWidgetSetValue(activeWidget);
    return activeWidget;
  };

  const validateItem =
    config.validateItem ||
    (typeof activeWidget?.options?.validate === 'function'
      ? (val: string) => activeWidget.options.validate(val)
      : undefined);

  const ms = createSearchableCheckboxMultiSelect({
    choices: initialChoices,
    values: initialValues,
    placeholder:
      config.placeholder ||
      activeWidget?.options?.placeholder ||
      config.option?.placeholder ||
      tr('-- Выбрать --', '-- Select --'),
    searchPlaceholder: config.searchPlaceholder,
    disabled:
      config.disabled != null
        ? Boolean(config.disabled)
        : Boolean(activeWidget?.options?.disabled),
    allowCustom: Boolean(config.allowCustom),
    showChips,
    batchSize: config.batchSize,
    selectVisibleLimit: config.selectVisibleLimit,
    validateItem,
    onBeforeOpen: config.onBeforeOpen,
    onChange: (nextValues, meta) => {
      if (meta.source !== 'user') return;
      internalSync = true;
      try {
        const w = resolveWidget();
        if (w) {
          w.choices = currentLabelMap;
        }
        if (w && typeof w.setValue === 'function') {
          w.setValue(nextValues);
        }
        ensureDynListDomItems(node, nextValues, currentLabelMap, inputName, w);
        dispatchDynListEvents(node);
        if (
          config.option &&
          typeof config.option.onchange === 'function' &&
          config.sectionId !== undefined
        ) {
          config.option.onchange(
            typeof Event === 'function'
              ? new Event('change')
              : ({ type: 'change' } as any),
            config.sectionId,
            nextValues,
          );
        }
      } finally {
        observer?.takeRecords?.();
        internalSync = false;
      }
    },
  });

  wrapWidgetSetValue(activeWidget);

  const addItemEl =
    node.querySelector(':scope > .add-item') || node.querySelector('.add-item');
  if (addItemEl && typeof node.insertBefore === 'function') {
    node.insertBefore(ms.element, addItemEl);
  } else {
    node.appendChild(ms.element);
  }

  const origRefreshChoices = ms.refreshChoices;
  const wrappedRefreshChoices = (
    nextChoices: SearchableCheckboxMultiSelectOptions['choices'],
  ) => {
    const normalized = normalizeMultiSelectChoices(nextChoices);
    initialChoices = normalized;
    currentLabelMap = {};
    for (const c of normalized) {
      currentLabelMap[c.value] = c.label;
    }
    const w = resolveWidget();
    if (w) {
      w.choices = currentLabelMap;
    }
    origRefreshChoices(normalized);
    syncFromWidget();
  };

  const onExternalDynlistChange = () => {
    if (!internalSync) {
      syncFromWidget();
    }
  };
  node.addEventListener?.('cbi-dynlist-change', onExternalDynlistChange);
  node.addEventListener?.('change', onExternalDynlistChange);

  const observer =
    typeof MutationObserver === 'function'
      ? new MutationObserver(() => {
          if (!internalSync) {
            syncFromWidget();
          }
        })
      : null;
  try {
    observer?.observe(node, { childList: true });
  } catch {
    /* ignore in minimal mock DOMs */
  }

  const handle: AttachedDynamicListHandle = {
    ...ms,
    refreshChoices: wrappedRefreshChoices,
    updateChoices: wrappedRefreshChoices,
    syncFromWidget,
    destroy: () => {
      observer?.disconnect();
      node.removeEventListener?.('cbi-dynlist-change', onExternalDynlistChange);
      node.removeEventListener?.('change', onExternalDynlistChange);
      node.classList.remove(
        'tachyon-dynlist-has-ms',
        'tachyon-dynlist-has-ms-items-visible',
      );
      delete (node as any).__tachyonMultiSelectHandle;
      ms.destroy();
    },
  };

  (node as any).__tachyonMultiSelectHandle = handle;
  return handle;
}

export function attachSearchableMultiSelectToOption(
  option: any,
  config: Omit<AttachSearchableMultiSelectOptions, 'option' | 'sectionId'> = {},
): void {
  if (!option || option.__tachyonMultiSelectAttached) {
    return;
  }
  option.__tachyonMultiSelectAttached = true;

  const origRenderWidget = option.renderWidget;
  if (typeof origRenderWidget !== 'function') {
    return;
  }

  option.renderWidget = function (
    section_id: string,
    option_index: number,
    cfgvalue: any,
  ) {
    const node = origRenderWidget.call(
      this,
      section_id,
      option_index,
      cfgvalue,
    );
    if (!node || typeof node.querySelector !== 'function') {
      return node;
    }

    let uiEl: any = null;
    try {
      if (typeof this.getUIElement === 'function') {
        uiEl = this.getUIElement(section_id);
      }
    } catch {
      uiEl = null;
    }
    if (
      !uiEl &&
      typeof dom !== 'undefined' &&
      dom &&
      typeof dom.findClassInstance === 'function'
    ) {
      try {
        uiEl = dom.findClassInstance(node);
      } catch {
        uiEl = null;
      }
    }

    const choices =
      config.choices !== undefined
        ? config.choices
        : extractWidgetChoices(uiEl, this);
    const hasCustomProp = Boolean(this.custom);
    const isDisabled =
      config.disabled != null
        ? Boolean(config.disabled)
        : Boolean(
            this.readonly != null
              ? this.readonly
              : this.map && this.map.readonly,
          );

    const handle = attachSearchableCheckboxMultiSelect(uiEl, node, {
      ...config,
      choices,
      allowCustom:
        config.allowCustom != null ? config.allowCustom : hasCustomProp,
      disabled: isDisabled,
      placeholder: config.placeholder || this.placeholder,
      option: this,
      sectionId: section_id,
      validateItem:
        config.validateItem ||
        (typeof this.validate === 'function'
          ? (val: string) => this.validate(section_id, val)
          : undefined),
    });

    if (handle) {
      this.__tachyonMultiSelectBySection =
        this.__tachyonMultiSelectBySection || new Map();
      this.__tachyonMultiSelectBySection.set(section_id, handle);
    }

    return node;
  };
}
