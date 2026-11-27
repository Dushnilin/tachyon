/// <reference types="vite/client" />
/* eslint-disable @typescript-eslint/no-explicit-any */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  attachSearchableCheckboxMultiSelect,
  attachSearchableMultiSelectToOption,
  createSearchableCheckboxMultiSelect,
  normalizeMultiSelectChoices,
} from '../searchableCheckboxMultiSelect';
import balancersSource from '../../views/balancers.ts?raw';
import conditionsSource from '../../views/conditions.ts?raw';
import localDevicesSource from '../../views/local_devices.ts?raw';
import outboundsSource from '../../views/outbounds.ts?raw';
import parentalSource from '../../views/parental.ts?raw';
import sectionSource from '../../views/section.ts?raw';
import settingsSource from '../../views/settings.ts?raw';

function createTestDom() {
  class MockClassList {
    private set = new Set<string>();
    constructor(initial = '') {
      for (const token of initial.split(/\s+/).filter(Boolean)) {
        this.set.add(token);
      }
    }
    add(...tokens: string[]) {
      tokens.forEach((t) => this.set.add(t));
    }
    remove(...tokens: string[]) {
      tokens.forEach((t) => this.set.delete(t));
    }
    toggle(token: string, force?: boolean) {
      if (force === undefined) {
        if (this.set.has(token)) {
          this.set.delete(token);
          return false;
        }
        this.set.add(token);
        return true;
      }
      if (force) this.set.add(token);
      else this.set.delete(token);
      return force;
    }
    contains(token: string) {
      return this.set.has(token);
    }
    toString() {
      return Array.from(this.set).join(' ');
    }
  }

  let activeEl: any = null;
  const setActiveEl = (node: any) => {
    activeEl = node;
  };
  const bubbleEvent = (startNode: any, eventObj: any) => {
    let cur: any = startNode;
    let stopped = false;
    const origStop = eventObj.stopPropagation?.bind(eventObj);
    eventObj.stopPropagation = () => {
      stopped = true;
      origStop?.();
    };
    while (cur) {
      const list = (cur.listeners[eventObj.type] || []).slice();
      for (const fn of list) {
        fn(eventObj);
      }
      if (stopped || !eventObj.bubbles) break;
      cur = cur.parentNode;
    }
  };

  class MockNode {
    tagName = '';
    nodeType = 1;
    children: any[] = [];
    parentNode: any = null;
    attrs: Record<string, string> = {};
    listeners: Record<string, Array<(ev: any) => void>> = {};
    classList = new MockClassList();
    style: Record<string, string> = {};
    hidden = false;
    disabled = false;
    checked = false;
    value = '';
    scrollTop = 0;
    clientHeight = 200;
    scrollHeight = 200;
    private _text = '';

    constructor(tag: string) {
      this.tagName = tag.toUpperCase();
    }

    get id() {
      return this.attrs.id || '';
    }
    set id(val: string) {
      this.attrs.id = String(val || '');
    }

    get className() {
      return this.classList.toString();
    }
    set className(val: string) {
      this.classList = new MockClassList(val);
      this.attrs.class = val;
    }

    get textContent(): string {
      if (this.children.length === 0) return this._text;
      return this.children.map((c) => c.textContent ?? '').join('');
    }
    set textContent(val: string) {
      this.children.forEach((c) => {
        c.parentNode = null;
      });
      this.children = [];
      this._text = String(val ?? '');
    }

    get nextElementSibling() {
      if (!this.parentNode) return null;
      const idx = this.parentNode.children.indexOf(this);
      return idx >= 0 && idx + 1 < this.parentNode.children.length
        ? this.parentNode.children[idx + 1]
        : null;
    }

    get previousElementSibling() {
      if (!this.parentNode) return null;
      const idx = this.parentNode.children.indexOf(this);
      return idx > 0 ? this.parentNode.children[idx - 1] : null;
    }

    get firstChild() {
      return this.children[0] || null;
    }

    setAttribute(name: string, val: string) {
      this.attrs[name] = String(val);
      if (name === 'class') {
        this.classList = new MockClassList(String(val));
      } else if (name === 'hidden') {
        this.hidden = true;
      } else if (name === 'disabled') {
        this.disabled = true;
      } else if (name === 'value') {
        this.value = String(val);
      }
    }

    removeAttribute(name: string) {
      delete this.attrs[name];
      if (name === 'hidden') this.hidden = false;
      if (name === 'disabled') this.disabled = false;
    }

    getAttribute(name: string) {
      if (name === 'class') return this.classList.toString();
      if (name === 'value') return this.value;
      return this.attrs[name] ?? null;
    }

    appendChild(child: any) {
      if (!child) return child;
      if (child.nodeType === 11) {
        const list = child.children.slice();
        for (const sub of list) {
          this.appendChild(sub);
        }
        child.children = [];
        return child;
      }
      if (child.parentNode && child.parentNode !== this) {
        child.parentNode.removeChild(child);
      }
      child.parentNode = this;
      this.children.push(child);
      return child;
    }

    insertBefore(newNode: any, refNode: any) {
      if (!refNode) return this.appendChild(newNode);
      if (newNode.nodeType === 11) {
        const list = newNode.children.slice();
        for (const sub of list) {
          this.insertBefore(sub, refNode);
        }
        newNode.children = [];
        return newNode;
      }
      if (newNode.parentNode && newNode.parentNode !== this) {
        newNode.parentNode.removeChild(newNode);
      }
      newNode.parentNode = this;
      const idx = this.children.indexOf(refNode);
      if (idx >= 0) this.children.splice(idx, 0, newNode);
      else this.children.push(newNode);
      return newNode;
    }

    removeChild(child: any) {
      const idx = this.children.indexOf(child);
      if (idx >= 0) {
        this.children.splice(idx, 1);
        child.parentNode = null;
      }
      return child;
    }

    replaceChildren(...nodes: any[]) {
      this.children.forEach((c) => {
        c.parentNode = null;
      });
      this.children = [];
      this._text = '';
      for (const n of nodes) {
        if (n) this.appendChild(n);
      }
    }

    contains(target: any): boolean {
      if (!target) return false;
      let cur: any = target;
      while (cur) {
        if (cur === this) return true;
        cur = cur.parentNode;
      }
      return false;
    }

    addEventListener(type: string, fn: (ev: any) => void) {
      if (!this.listeners[type]) this.listeners[type] = [];
      this.listeners[type].push(fn);
    }

    removeEventListener(type: string, fn: (ev: any) => void) {
      if (!this.listeners[type]) return;
      this.listeners[type] = this.listeners[type].filter((f) => f !== fn);
    }

    dispatchEvent(ev: any) {
      const eventObj =
        typeof ev === 'string' ? { type: ev, bubbles: true } : ev;
      if (!eventObj.target) {
        Object.defineProperty(eventObj, 'target', {
          value: this,
          configurable: true,
        });
      }
      bubbleEvent(this, eventObj);
      return true;
    }

    click() {
      if (this.disabled) return;
      if (this.tagName === 'INPUT' && this.attrs.type === 'checkbox') {
        this.checked = !this.checked;
      }
      this.dispatchEvent({
        type: 'click',
        bubbles: true,
        preventDefault() {},
        stopPropagation() {},
      });
    }

    focus() {
      setActiveEl(this);
    }

    matchesSimple(sel: string, root: any): boolean {
      const trimmed = sel.trim();
      if (!trimmed) return false;
      if (trimmed.startsWith(':scope > ')) {
        if (this.parentNode !== root) return false;
        return this.matchesSimple(trimmed.slice(':scope > '.length), root);
      }
      if (trimmed.includes(' > ')) {
        const [parentSel, childSel] = trimmed.split(' > ');
        return (
          this.matchesSimple(childSel, root) &&
          this.parentNode != null &&
          this.parentNode.matchesSimple(parentSel, root)
        );
      }
      if (trimmed.includes(' ')) {
        const parts = trimmed.split(/\s+/);
        const lastSel = parts[parts.length - 1];
        if (!this.matchesSimple(lastSel, root)) return false;
        let cur: any = this.parentNode;
        let idx = parts.length - 2;
        while (cur && idx >= 0) {
          if (cur.matchesSimple(parts[idx], root)) {
            idx -= 1;
          }
          cur = cur.parentNode;
        }
        return idx < 0;
      }
      if (trimmed.startsWith('input[type="') && trimmed.endsWith('"]')) {
        const expected = trimmed.slice('input[type="'.length, -2);
        return this.tagName === 'INPUT' && this.attrs.type === expected;
      }
      if (trimmed.startsWith('[data-value="') && trimmed.endsWith('"]')) {
        const expected = trimmed.slice('[data-value="'.length, -2);
        return this.attrs['data-value'] === expected;
      }
      if (trimmed.startsWith('[data-action="') && trimmed.endsWith('"]')) {
        const expected = trimmed.slice('[data-action="'.length, -2);
        return this.attrs['data-action'] === expected;
      }
      if (trimmed.startsWith('.')) {
        return this.classList.contains(trimmed.slice(1));
      }
      return this.tagName === trimmed.toUpperCase();
    }

    querySelectorAll(selector: string): any[] {
      const parts = selector.split(',').map((s) => s.trim());
      const results: any[] = [];
      const walk = (node: any) => {
        for (const child of node.children) {
          if (parts.some((p) => child.matchesSimple(p, this))) {
            results.push(child);
          }
          walk(child);
        }
      };
      walk(this);
      return results;
    }

    querySelector(selector: string): any {
      return this.querySelectorAll(selector)[0] || null;
    }
  }

  const docListeners: Record<string, Array<(ev: any) => void>> = {};
  const body = new MockNode('body');
  const head = new MockNode('head');
  const documentMock: any = {
    documentElement: { lang: 'ru' },
    head,
    body,
    get activeElement() {
      return activeEl;
    },
    createElement: (tag: string) => new MockNode(tag),
    createElementNS: (_ns: string, tag: string) => new MockNode(tag),
    createTextNode: (text: string) => {
      const n = new MockNode('#text');
      n.nodeType = 3;
      n.textContent = text;
      return n;
    },
    createDocumentFragment: () => {
      const f = new MockNode('#fragment');
      f.nodeType = 11;
      return f;
    },
    getElementById: (id: string) => {
      const walk = (node: any): any => {
        if (node.attrs?.id === id) return node;
        for (const ch of node.children || []) {
          const hit = walk(ch);
          if (hit) return hit;
        }
        return null;
      };
      return walk(head) || walk(body);
    },
    addEventListener: (type: string, fn: (ev: any) => void) => {
      if (!docListeners[type]) docListeners[type] = [];
      docListeners[type].push(fn);
    },
    removeEventListener: (type: string, fn: (ev: any) => void) => {
      if (!docListeners[type]) return;
      docListeners[type] = docListeners[type].filter((f) => f !== fn);
    },
    dispatchEvent: (ev: any) => {
      for (const fn of (docListeners[ev.type] || []).slice()) {
        fn(ev);
      }
    },
  };

  return {
    documentMock,
    MockNode,
    getActiveElement: () => activeEl,
    clearActiveElement: () => {
      activeEl = null;
    },
  };
}

describe('searchableCheckboxMultiSelect', () => {
  let domEnv: ReturnType<typeof createTestDom>;

  beforeEach(() => {
    domEnv = createTestDom();
    (globalThis as any).document = domEnv.documentMock;
    (globalThis as any).window = { innerHeight: 900 };
    (globalThis as any).E = undefined;
  });

  afterEach(() => {
    delete (globalThis as any).document;
    delete (globalThis as any).window;
    delete (globalThis as any).E;
  });

  it('normalizes array, object, and tuple choices cleanly without duplicates', () => {
    expect(
      normalizeMultiSelectChoices({
        ru: 'Russia (ru)',
        us: 'United States (us)',
      }),
    ).toEqual([
      { value: 'ru', label: 'Russia (ru)' },
      { value: 'us', label: 'United States (us)' },
    ]);
    expect(
      normalizeMultiSelectChoices([
        ['de', 'Germany'],
        'fr',
        { value: 'de', label: 'Duplicate' },
      ]),
    ).toEqual([
      { value: 'de', label: 'Germany' },
      { value: 'fr', label: 'fr' },
    ]);
  });

  it('renders chips with remove buttons, opens on trigger click, toggles checkboxes without closing, and closes on Escape/outside click', () => {
    const onChange = vi.fn();
    const modal = domEnv.documentMock.createElement('div');
    const modalEscSpy = vi.fn();
    modal.addEventListener('keydown', modalEscSpy);
    domEnv.documentMock.body.appendChild(modal);

    const ms = createSearchableCheckboxMultiSelect({
      choices: [
        { value: 'ru', label: 'Russia (ru)' },
        { value: 'de', label: 'Germany (de)' },
        { value: 'nl', label: 'Netherlands (nl)' },
      ],
      values: ['ru'],
      placeholder: '-- Select countries --',
      onChange,
    });
    modal.appendChild(ms.element);

    // Initially closed: 0 option rows rendered lazily, 1 chip rendered
    expect(ms.isOpen()).toBe(false);
    expect(ms.listElement.querySelectorAll('.tachyon-ms__option').length).toBe(
      0,
    );
    expect(ms.chipsElement.querySelectorAll('.tachyon-ms__chip').length).toBe(
      1,
    );
    expect(ms.trigger.textContent).toContain('Russia (ru)');

    // Open dropdown -> autofocuses search input
    ms.trigger.click();
    expect(ms.isOpen()).toBe(true);
    expect(domEnv.getActiveElement()).toBe(ms.searchInput);
    expect(ms.listElement.querySelectorAll('.tachyon-ms__option').length).toBe(
      3,
    );

    // Click row for Germany -> stays OPEN, updates chips and selected values
    const deRow = ms.listElement.querySelector('[data-value="de"]') as any;
    deRow.click();
    expect(ms.isOpen()).toBe(true);
    expect(ms.getValues()).toEqual(['ru', 'de']);
    expect(ms.chipsElement.querySelectorAll('.tachyon-ms__chip').length).toBe(
      2,
    );
    expect(onChange).toHaveBeenLastCalledWith(['ru', 'de'], { source: 'user' });

    // Remove Russia via chip × button -> stays open and updates values
    const ruChipRemove = ms.chipsElement.querySelector(
      '[data-value="ru"] .tachyon-ms__chip-remove',
    ) as any;
    ruChipRemove.click();
    expect(ms.getValues()).toEqual(['de']);
    expect(ms.isOpen()).toBe(true);
    expect(
      (
        ms.listElement.querySelector(
          '[data-value="ru"] input[type="checkbox"]',
        ) as any
      ).checked,
    ).toBe(false);

    // Escape inside search input closes panel and stops propagation (modal does not receive Escape)
    let escPropagated = true;
    ms.searchInput.dispatchEvent({
      type: 'keydown',
      key: 'Escape',
      bubbles: true,
      preventDefault() {},
      stopPropagation() {
        escPropagated = false;
      },
    } as any);
    expect(ms.isOpen()).toBe(false);
    expect(escPropagated).toBe(false);
    expect(modalEscSpy).not.toHaveBeenCalled();

    // Open again and click outside -> closes
    ms.trigger.click();
    expect(ms.isOpen()).toBe(true);
    const outside = domEnv.documentMock.createElement('div');
    domEnv.documentMock.body.appendChild(outside);
    domEnv.documentMock.dispatchEvent({
      type: 'pointerdown',
      target: outside,
    } as any);
    expect(ms.isOpen()).toBe(false);
  });

  it('filters by label and value, clears search with ×, and handles Enter on single match', () => {
    const ms = createSearchableCheckboxMultiSelect({
      choices: [
        { value: 'srv_de_01', label: 'Frankfurt Node [VLESS]' },
        { value: 'srv_nl_02', label: 'Amsterdam Edge [HY2]' },
        { value: 'srv_us_03', label: 'New York Core [TUIC]' },
      ],
    });
    domEnv.documentMock.body.appendChild(ms.element);
    ms.open();

    // Search by value substring
    ms.searchInput.value = 'nl_02';
    ms.searchInput.dispatchEvent({ type: 'input', bubbles: true } as any);
    let rows = ms.listElement.querySelectorAll('.tachyon-ms__option');
    expect(rows.length).toBe(1);
    expect(rows[0].getAttribute('data-value')).toBe('srv_nl_02');

    // Enter when 1 match toggles it without closing
    ms.searchInput.dispatchEvent({
      type: 'keydown',
      key: 'Enter',
      bubbles: true,
      preventDefault() {},
      stopPropagation() {},
    } as any);
    expect(ms.getValues()).toEqual(['srv_nl_02']);
    expect(ms.isOpen()).toBe(true);

    // Clear search button restores all 3 items
    const clearBtn = ms.panel.querySelector('.tachyon-ms__search-clear') as any;
    expect(clearBtn.hidden).toBe(false);
    clearBtn.click();
    expect(ms.searchInput.value).toBe('');
    rows = ms.listElement.querySelectorAll('.tachyon-ms__option');
    expect(rows.length).toBe(3);
  });

  it('renders 1500+ servers in batches (120 initially + Show more / scroll + full search)', () => {
    const hugeChoices = Array.from({ length: 1500 }, (_, i) => ({
      value: `srv_${i + 1}`,
      label:
        i === 1449 ? 'Tokyo Premium 1450 [VLESS]' : `Server #${i + 1} [VLESS]`,
    }));

    const ms = createSearchableCheckboxMultiSelect({
      choices: hugeChoices,
      batchSize: 120,
      selectVisibleLimit: 300,
    });
    domEnv.documentMock.body.appendChild(ms.element);

    // Closed: 0 option rows in DOM
    expect(ms.listElement.querySelectorAll('.tachyon-ms__option').length).toBe(
      0,
    );

    // Open: only first 120 rendered, "Select visible" hidden because 1500 > 300 without search
    ms.open();
    expect(ms.listElement.querySelectorAll('.tachyon-ms__option').length).toBe(
      120,
    );
    const selectVisibleBtn = ms.panel.querySelector(
      '[data-action="select-visible"]',
    ) as any;
    expect(selectVisibleBtn.hidden).toBe(true);

    // Click "Show more" -> renders 240 rows
    const moreBtn = ms.listElement.querySelector(
      '.tachyon-ms__more-btn',
    ) as any;
    expect(moreBtn).toBeTruthy();
    expect(moreBtn.textContent).toContain('1380');
    moreBtn.click();
    expect(ms.listElement.querySelectorAll('.tachyon-ms__option').length).toBe(
      240,
    );

    // Scroll near bottom -> loads next batch (360 rows)
    const listAny = ms.listElement as any;
    listAny.scrollTop = 950;
    listAny.clientHeight = 200;
    listAny.scrollHeight = 1000;
    ms.listElement.dispatchEvent({ type: 'scroll' } as any);
    expect(ms.listElement.querySelectorAll('.tachyon-ms__option').length).toBe(
      360,
    );

    // Search matches item #1450 across all 1500 choices AND enables "Select visible"
    ms.searchInput.value = 'Tokyo Premium';
    ms.searchInput.dispatchEvent({ type: 'input', bubbles: true } as any);
    const matched = ms.listElement.querySelectorAll('.tachyon-ms__option');
    expect(matched.length).toBe(1);
    expect(matched[0].getAttribute('data-value')).toBe('srv_1450');
    expect(selectVisibleBtn.hidden).toBe(false);

    // "Select visible" checks Tokyo Premium 1450
    selectVisibleBtn.click();
    expect(ms.getValues()).toEqual(['srv_1450']);

    // Clear all resets selection
    const clearAllBtn = ms.panel.querySelector(
      '[data-action="clear-all"]',
    ) as any;
    clearAllBtn.click();
    expect(ms.getValues()).toEqual([]);
  });

  it('supports allowCustom with validateItem and preserves selected values across refreshChoices()', () => {
    const ms = createSearchableCheckboxMultiSelect({
      choices: [
        { value: '1.1.1.1', label: 'Cloudflare (1.1.1.1)' },
        { value: '8.8.8.8', label: 'Google (8.8.8.8)' },
      ],
      values: ['9.9.9.9'],
      allowCustom: true,
      validateItem: (val) =>
        /^\d+\.\d+\.\d+\.\d+$/.test(val) ? true : 'Invalid IP',
    });
    domEnv.documentMock.body.appendChild(ms.element);
    ms.open();

    // Invalid custom value shows error and is not added
    ms.searchInput.value = 'not-an-ip';
    ms.searchInput.dispatchEvent({ type: 'input', bubbles: true } as any);
    const addBtn = ms.panel.querySelector('.tachyon-ms__custom-add-btn') as any;
    addBtn.click();
    expect(ms.getValues()).toEqual(['9.9.9.9']);
    expect((ms.panel.querySelector('.tachyon-ms__error') as any).hidden).toBe(
      false,
    );

    // Valid custom IP is added
    ms.searchInput.value = '77.88.8.8';
    ms.searchInput.dispatchEvent({ type: 'input', bubbles: true } as any);
    addBtn.click();
    expect(ms.getValues()).toEqual(['9.9.9.9', '77.88.8.8']);

    // refreshChoices updates labels without losing existing/custom selection
    ms.refreshChoices([
      { value: '77.88.8.8', label: 'Yandex DNS (77.88.8.8)' },
      { value: '1.1.1.1', label: 'Cloudflare DoH' },
    ]);
    expect(ms.getValues()).toEqual(['9.9.9.9', '77.88.8.8']);
    expect(
      (ms.chipsElement.querySelector('[data-value="77.88.8.8"]') as any)
        .textContent,
    ).toContain('Yandex DNS (77.88.8.8)');
  });

  it('syncs cleanly with LuCI ui.DynamicList & form.DynamicList (hidden inputs, getValue, setValue, events, and non-DOM stubs)', () => {
    const doc = domEnv.documentMock;
    const dlNode = doc.createElement('div');
    dlNode.className = 'cbi-dynlist';
    dlNode.id = 'cbid.tachyon.Main.include_countries';
    const addItem = doc.createElement('div');
    addItem.className = 'add-item';
    dlNode.appendChild(addItem);

    let currentVals = ['ru'];
    const renderHiddenItems = (vals: string[]) => {
      for (const el of dlNode.querySelectorAll('.item')) {
        dlNode.removeChild(el);
      }
      vals.forEach((v, idx) => {
        const item = doc.createElement('div');
        item.className = 'item';
        item.setAttribute('data-index', String(idx));
        const hid = doc.createElement('input');
        hid.setAttribute('type', 'hidden');
        hid.setAttribute('name', dlNode.id);
        hid.value = v;
        item.appendChild(hid);
        dlNode.insertBefore(item, addItem);
      });
    };
    renderHiddenItems(currentVals);

    const mockWidget: any = {
      node: dlNode,
      choices: { ru: 'Russia (ru)', de: 'Germany (de)', fi: 'Finland (fi)' },
      options: { id: dlNode.id, disabled: false },
      render: () => dlNode,
      getValue: () => currentVals.slice(),
      setValue: (vals: string[]) => {
        currentVals = vals.slice();
        renderHiddenItems(currentVals);
      },
    };

    const onchangeSpy = vi.fn();
    const dynChangeEvents: any[] = [];
    dlNode.addEventListener('cbi-dynlist-change', (ev: any) =>
      dynChangeEvents.push(ev),
    );

    const mockOption: any = {
      cbid: () => dlNode.id,
      keylist: ['ru', 'de', 'fi'],
      vallist: ['Russia (ru)', 'Germany (de)', 'Finland (fi)'],
      placeholder: '-- Select --',
      onchange: onchangeSpy,
      getUIElement: () => mockWidget,
      renderWidget: () => dlNode,
      formvalue: () => mockWidget.getValue(),
    };

    attachSearchableMultiSelectToOption(mockOption);
    const rendered = mockOption.renderWidget('Main', 0, ['ru']);
    doc.body.appendChild(rendered);

    const handle = (rendered as any).__tachyonMultiSelectHandle;
    expect(handle).toBeTruthy();
    expect(rendered.classList.contains('tachyon-dynlist-has-ms')).toBe(true);

    // Toggle Finland inside dropdown -> updates widget.getValue(), formvalue(), hidden inputs, and dispatches cbi-dynlist-change
    handle.open();
    (handle.listElement.querySelector('[data-value="fi"]') as any).click();
    expect(mockWidget.getValue()).toEqual(['ru', 'fi']);
    expect(mockOption.formvalue('Main')).toEqual(['ru', 'fi']);
    expect(
      Array.from(dlNode.querySelectorAll('.item > input[type="hidden"]')).map(
        (i: any) => i.value,
      ),
    ).toEqual(['ru', 'fi']);
    expect(dynChangeEvents.length).toBe(1);
    expect(onchangeSpy).toHaveBeenCalledTimes(1);

    // External widget.setValue(['de']) updates multiselect chips & checkboxes
    mockWidget.setValue(['de']);
    expect(handle.getValues()).toEqual(['de']);
    expect(
      handle.chipsElement.querySelectorAll('.tachyon-ms__chip').length,
    ).toBe(1);
    expect(
      (
        handle.listElement.querySelector(
          '[data-value="de"] input[type="checkbox"]',
        ) as any
      ).checked,
    ).toBe(true);
    expect(
      (
        handle.listElement.querySelector(
          '[data-value="fi"] input[type="checkbox"]',
        ) as any
      ).checked,
    ).toBe(false);

    // showChips: false keeps .item elements visible for SettingsDynamicList / DNS speed test
    const settingsNode = doc.createElement('div');
    settingsNode.className = 'cbi-dynlist';
    const settingsHandle = attachSearchableCheckboxMultiSelect(
      { getValue: () => [], setValue: () => {} },
      settingsNode,
      { choices: [{ value: 'bal1', label: 'Balancer 1' }], showChips: false },
    );
    expect(
      settingsNode.classList.contains('tachyon-dynlist-has-ms-items-visible'),
    ).toBe(true);
    expect(settingsHandle?.chipsElement.hidden).toBe(true);

    // Minimal non-DOM stub (e.g. VM test sandbox) safely returns stub untouched
    const stubOpt: any = { renderWidget: () => ({ style: {} }) };
    attachSearchableMultiSelectToOption(stubOpt);
    expect(stubOpt.renderWidget('s', 0, [])).toEqual({ style: {} });
  });

  it('wires searchable checkbox multiselect across all targeted choice-backed DynamicList views without breaking communityListPicker', () => {
    expect(sectionSource).toContain('attachSearchableCheckboxMultiSelect');
    expect(sectionSource).toContain('attachSearchableMultiSelectToOption');
    expect(sectionSource).toContain('attachCommunityListPicker');
    expect(balancersSource).toContain('attachSearchableMultiSelectToOption');
    expect(conditionsSource).toContain('attachSearchableMultiSelectToOption');
    expect(conditionsSource).toContain('attachCommunityListPicker');
    expect(parentalSource).toContain('attachSearchableMultiSelectToOption');
    expect(localDevicesSource).toContain('attachSearchableCheckboxMultiSelect');
    expect(settingsSource).toContain('attachSearchableCheckboxMultiSelect');
    expect(settingsSource).toContain('attachSearchableMultiSelectToOption');

    // outbounds.ts server pool checklist picker uses batched rendering (120) instead of hard 200 cap
    expect(outboundsSource).toContain('attachSearchableMultiSelectToOption');
    expect(outboundsSource).toContain('BATCH_SIZE = 120');
    expect(outboundsSource).not.toContain('filtered.slice(0, 200)');
  });
});
