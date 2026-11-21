import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parse } from '@babel/parser';
import { describe, expect, it, vi } from 'vitest';

const testDir = path.dirname(fileURLToPath(import.meta.url));
const sectionTsPath = path.resolve(testDir, '../../views/section.ts');

class MockClassList {
  constructor(initial = '') {
    this.set = new Set();
    initial
      .split(/\s+/)
      .filter(Boolean)
      .forEach((c) => this.set.add(c));
  }
  add(...names) {
    names.forEach((n) => this.set.add(n));
  }
  remove(...names) {
    names.forEach((n) => this.set.delete(n));
  }
  contains(name) {
    return this.set.has(name);
  }
  toString() {
    return Array.from(this.set).join(' ');
  }
}

class MockElement {
  constructor(tag, attrs = {}) {
    this.tagName = tag.toUpperCase();
    this.children = [];
    this.parentNode = null;
    this.attrs = {};
    this.disabled = false;
    this.value = '';
    this.listeners = {};
    this.classList = new MockClassList(attrs.class || '');
    for (const [k, v] of Object.entries(attrs)) {
      if (k === 'click') {
        this.addEventListener('click', v);
      } else if (k === 'class') {
        this.attrs.class = v;
      } else {
        this.attrs[k] = v;
        this[k] = v;
      }
    }
  }

  get className() {
    return this.classList.toString();
  }

  set className(val) {
    this.classList = new MockClassList(val);
    this.attrs.class = val;
  }

  get childNodes() {
    return this.children;
  }

  get nextElementSibling() {
    if (!this.parentNode) return null;
    const idx = this.parentNode.children.indexOf(this);
    return idx >= 0 && idx + 1 < this.parentNode.children.length
      ? this.parentNode.children[idx + 1]
      : null;
  }

  setAttribute(name, val) {
    this.attrs[name] = val;
    if (name === 'class') {
      this.classList = new MockClassList(val);
    }
  }

  getAttribute(name) {
    if (name === 'class') return this.classList.toString();
    return this.attrs[name] ?? null;
  }

  addEventListener(type, fn) {
    if (!this.listeners[type]) this.listeners[type] = [];
    this.listeners[type].push(fn);
  }

  click(ev = { preventDefault() {}, stopPropagation() {} }) {
    if (this.disabled) return;
    for (const fn of this.listeners.click || []) {
      fn(ev);
    }
  }

  appendChild(child) {
    if (typeof child === 'string') return child;
    child.parentNode = this;
    this.children.push(child);
    return child;
  }

  append(...items) {
    for (const item of items) {
      if (typeof item !== 'string' && item) {
        this.appendChild(item);
      }
    }
  }

  insertBefore(newNode, refNode) {
    newNode.parentNode = this;
    if (!refNode) {
      this.children.push(newNode);
      return newNode;
    }
    const idx = this.children.indexOf(refNode);
    if (idx >= 0) {
      this.children.splice(idx, 0, newNode);
    } else {
      this.children.push(newNode);
    }
    return newNode;
  }

  removeChild(child) {
    const idx = this.children.indexOf(child);
    if (idx >= 0) {
      this.children.splice(idx, 1);
      child.parentNode = null;
    }
    return child;
  }

  set textContent(val) {
    this.children.forEach((c) => {
      c.parentNode = null;
    });
    this.children = [];
    this.attrs._text = val;
  }

  get textContent() {
    if (this.attrs._text && this.children.length === 0) {
      return this.attrs._text;
    }
    return this.children.map((c) => c.textContent).join('');
  }

  closest(selector) {
    const cls = selector.startsWith('.') ? selector.slice(1) : selector;
    if (this.classList.contains(cls)) return this;
    let cur = this.parentNode;
    while (cur) {
      if (cur.classList.contains(cls)) return cur;
      cur = cur.parentNode;
    }
    return null;
  }

  matchesSimple(sel, root) {
    const trimmed = sel.trim();
    if (!trimmed) return false;
    if (trimmed.startsWith(':scope > ')) {
      if (this.parentNode !== root) return false;
      return this.matchesSimple(trimmed.slice(':scope > '.length), root);
    }
    if (trimmed.includes(' ')) {
      const parts = trimmed.split(/\s+/);
      if (parts[0] === '.cbi-dynlist' && parts[1] === '.add-item') {
        return (
          this.tagName === 'INPUT' &&
          (this.attrs.type || 'text') === 'text' &&
          this.closest('.add-item')?.closest('.cbi-dynlist') != null
        );
      }
    }
    if (trimmed === '.cbi-map:not(.hidden)') {
      return (
        this.classList.contains('cbi-map') && !this.classList.contains('hidden')
      );
    }
    if (trimmed === 'div.button-row' || trimmed === '.button-row') {
      return this.classList.contains('button-row');
    }
    if (trimmed === 'h4') return this.tagName === 'H4';
    if (trimmed === 'h3') return this.tagName === 'H3';
    if (trimmed.startsWith('.')) {
      return this.classList.contains(trimmed.slice(1));
    }
    return false;
  }

  querySelectorAll(selector) {
    const parts = selector.split(',').map((s) => s.trim());
    const results = [];
    const walk = (node) => {
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

  querySelector(selector) {
    return this.querySelectorAll(selector)[0] || null;
  }

  scrollIntoView() {}
  focus() {}
}

function loadStackedModalFn(doc) {
  const source = fs.readFileSync(sectionTsPath, 'utf8');
  const ast = parse(source, {
    allowReturnOutsideFunction: true,
    sourceType: 'module',
    plugins: ['typescript'],
  });
  const fnNames = ['cleanFormSectionData', 'renderStackedJsonSettingsModal'];
  const fnSources = new Map();
  for (const node of ast.program.body) {
    if (
      node.type === 'FunctionDeclaration' &&
      node.id &&
      fnNames.includes(node.id.name)
    ) {
      fnSources.set(node.id.name, source.slice(node.start, node.end));
    }
  }
  const code = fnNames
    .map((n) => {
      const s = fnSources.get(n);
      if (!s) throw new Error(`Function ${n} not found`);
      return s;
    })
    .join('\n');

  const E = (tag, attrs, children) => {
    const isAttrs =
      attrs &&
      typeof attrs === 'object' &&
      !(attrs instanceof MockElement) &&
      !Array.isArray(attrs);
    const el = new MockElement(tag, isAttrs ? attrs : {});
    const kids = isAttrs ? children : attrs;
    const list = Array.isArray(kids) ? kids : [kids];
    for (const k of list) {
      if (k instanceof MockElement) el.appendChild(k);
      else if (typeof k === 'string') el.textContent = k;
    }
    return el;
  };

  const factory = new Function(
    'document',
    'E',
    '_',
    `${code}; return renderStackedJsonSettingsModal;`,
  );
  return factory(doc, E, (s) => s);
}

function buildModalDom() {
  const overlay = new MockElement('div', { id: 'modal_overlay' });
  const modal = new MockElement('div', { class: 'modal cbi-modal' });
  const heading = new MockElement('h4');
  const closeX = new MockElement('button', {
    class: 'tachyon-modal__header-close',
    type: 'button',
  });
  heading.appendChild(closeX);

  const activeMap = new MockElement('div', { class: 'cbi-map' });
  const buttonRow = new MockElement('div', { class: 'button-row' });
  const origSave = new MockElement('button', {
    class: 'btn cbi-button cbi-button-save',
  });
  buttonRow.appendChild(origSave);

  modal.append(heading, activeMap, buttonRow);
  overlay.appendChild(modal);

  const doc = {
    querySelector(sel) {
      if (
        sel === '#modal_overlay > .modal.cbi-modal' ||
        sel === '.modal.cbi-modal'
      ) {
        return modal;
      }
      return null;
    },
  };
  return { modal, heading, closeX, activeMap, buttonRow, origSave, doc };
}

describe('renderStackedJsonSettingsModal (#465)', () => {
  it('flushes pending dynlist input, saves priority levels, closes stacked layer and restores parent controls', async () => {
    const dom = buildModalDom();
    const renderStacked = loadStackedModalFn(dom.doc);

    const dynAddClicked = vi.fn();
    const dynInput = new MockElement('input', { type: 'text' });
    dynInput.value = 'grp_backup';
    const addBtn = new MockElement('div', { class: 'cbi-button-add' });
    addBtn.addEventListener('click', dynAddClicked);
    const addItem = new MockElement('div', { class: 'add-item' });
    addItem.append(dynInput, addBtn);
    const dynlist = new MockElement('div', { class: 'cbi-dynlist' });
    dynlist.appendChild(addItem);
    const nodes = new MockElement('div', { class: 'cbi-map' });
    nodes.appendChild(dynlist);

    const mockMap = {
      config: 'json',
      data: {
        get: () => ({
          '.name': 'settings',
          outbound_group_levels: ['grp_primary', 'grp_backup'],
        }),
      },
      load: vi.fn().mockResolvedValue(undefined),
      render: vi.fn().mockResolvedValue(nodes),
      parse: vi.fn().mockResolvedValue(undefined),
    };
    const onSave = vi.fn();

    await renderStacked('Priority', mockMap, onSave);

    expect(dom.activeMap.classList.contains('hidden')).toBe(true);
    expect(nodes.parentNode).toBe(dom.modal);
    expect(dom.heading.children[dom.heading.children.length - 1]).toBe(
      dom.closeX,
    );

    const buttons = dom.buttonRow.children.filter(
      (c) => c.tagName === 'BUTTON',
    );
    expect(buttons).toHaveLength(2);
    expect(buttons[0].getAttribute('type')).toBe('button');
    expect(buttons[1].getAttribute('type')).toBe('button');

    buttons[1].click();
    await new Promise((r) => globalThis.setTimeout(r, 15));

    expect(dynAddClicked).toHaveBeenCalledTimes(1);
    expect(mockMap.parse).toHaveBeenCalledTimes(1);
    expect(onSave).toHaveBeenCalledWith({
      outbound_group_levels: ['grp_primary', 'grp_backup'],
    });
    expect(nodes.parentNode).toBeNull();
    expect(dom.activeMap.classList.contains('hidden')).toBe(false);
    expect(dom.buttonRow.children).toEqual([dom.origSave]);
  });

  it('keeps modal open, re-enables Save and displays validation summary when map.parse throws synchronously or rejects', async () => {
    const dom = buildModalDom();
    const renderStacked = loadStackedModalFn(dom.doc);
    const nodes = new MockElement('div', { class: 'cbi-map' });

    const mockMap = {
      config: 'json',
      data: { get: () => ({}) },
      load: vi.fn().mockResolvedValue(undefined),
      render: vi.fn().mockResolvedValue(nodes),
      parse: vi.fn().mockImplementationOnce(() => {
        throw new Error('Invalid tier entry');
      }),
    };
    const onSave = vi.fn();

    await renderStacked('Priority', mockMap, onSave);
    const saveBtn = dom.buttonRow.children.filter(
      (c) => c.tagName === 'BUTTON',
    )[1];

    saveBtn.click();
    await new Promise((r) => globalThis.setTimeout(r, 15));

    expect(onSave).not.toHaveBeenCalled();
    expect(nodes.parentNode).toBe(dom.modal);
    expect(dom.activeMap.classList.contains('hidden')).toBe(true);
    expect(saveBtn.disabled).toBe(false);
    const summary = dom.modal.querySelector(
      '.fkp-stacked-settings-validation-summary',
    );
    expect(summary).not.toBeNull();
    expect(summary?.textContent).toContain('Invalid tier entry');
  });
});
