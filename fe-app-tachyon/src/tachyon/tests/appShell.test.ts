/* eslint-disable @typescript-eslint/no-explicit-any */
import { beforeEach, describe, expect, it, vi } from 'vitest';

const storage = new Map<string, string>();

function createMockElement(tag: string): any {
  const attrs: Record<string, string> = {};
  const dataset: Record<string, string> = {};
  const listeners: Record<string, Array<(ev: any) => void>> = {};
  const el: any = {
    tagName: tag.toUpperCase(),
    children: [] as any[],
    style: {} as Record<string, string>,
    className: '',
    textContent: '',
    dataset,
    setAttribute(k: string, v: string) {
      attrs[k] = String(v);
      if (k === 'class') el.className = String(v);
      if (k.startsWith('data-')) {
        const camel = k
          .slice(5)
          .replace(/-([a-z])/g, (_, c: string) => c.toUpperCase());
        dataset[camel] = String(v);
      }
    },
    getAttribute(k: string) {
      if (k === 'class') return el.className || attrs.class || null;
      return k in attrs ? attrs[k] : null;
    },
    addEventListener(type: string, cb: (ev: any) => void) {
      if (!listeners[type]) listeners[type] = [];
      listeners[type].push(cb);
    },
    click() {
      const cbs = listeners.click || [];
      cbs.forEach((fn) => fn({ preventDefault() {}, stopPropagation() {} }));
    },
    appendChild(child: any) {
      if (child != null && child !== '') {
        el.children.push(child);
      }
      return child;
    },
    replaceChildren(...nodes: any[]) {
      el.children = nodes.filter((n) => n != null && n !== '');
    },
    insertBefore(newNode: any, refNode: any) {
      const idx = el.children.indexOf(refNode);
      if (idx >= 0) {
        el.children.splice(idx, 0, newNode);
      } else {
        el.children.push(newNode);
      }
      return newNode;
    },
    get firstChild() {
      return el.children[0] || null;
    },
    classList: {
      add(c: string) {
        const set = new Set((el.className || '').split(/\s+/).filter(Boolean));
        set.add(c);
        el.className = Array.from(set).join(' ');
      },
      remove(c: string) {
        const set = new Set((el.className || '').split(/\s+/).filter(Boolean));
        set.delete(c);
        el.className = Array.from(set).join(' ');
      },
      contains(c: string) {
        return (el.className || '').split(/\s+/).includes(c);
      },
      toggle(c: string, force?: boolean) {
        const has = (el.className || '').split(/\s+/).includes(c);
        const shouldHave = force !== undefined ? force : !has;
        if (shouldHave) el.classList.add(c);
        else el.classList.remove(c);
        return shouldHave;
      },
    },
    querySelector(sel: string): any {
      return el.querySelectorAll(sel)[0] || null;
    },
    querySelectorAll(sel: string): any[] {
      const results: any[] = [];
      const matchSingle = (node: any, s: string): boolean => {
        if (!node || typeof node !== 'object') return false;
        if (s.startsWith('#')) {
          return node.getAttribute?.('id') === s.slice(1);
        }
        if (s.startsWith('.')) {
          const cls = s.slice(1);
          return (node.className || '').split(/\s+/).includes(cls);
        }
        return (node.tagName || '').toLowerCase() === s.toLowerCase();
      };
      const walk = (node: any) => {
        if (!node || !Array.isArray(node.children)) return;
        for (const child of node.children) {
          if (child && typeof child === 'object') {
            if (matchSingle(child, sel)) {
              results.push(child);
            }
            walk(child);
          }
        }
      };
      walk(el);
      return results;
    },
  };
  return el;
}

vi.hoisted(() => {
  (globalThis as any).localStorage = {
    getItem: (k: string) => (storage.has(k) ? storage.get(k)! : null),
    setItem: (k: string, v: string) => storage.set(k, String(v)),
    clear: () => storage.clear(),
  };
  const body = createMockElement('body');
  (globalThis as any).document = {
    body,
    documentElement: { lang: 'ru' },
    createElement: (tag: string) => createMockElement(tag),
    createElementNS: (_ns: string, tag: string) => createMockElement(tag),
    createTextNode: (t: string) => ({ textContent: String(t) }),
    getElementById: (id: string) => body.querySelector(`#${id}`),
    querySelector: (s: string) => body.querySelector(s),
    querySelectorAll: (s: string) => body.querySelectorAll(s),
    addEventListener: () => {},
  };
  (globalThis as any).window = {
    localStorage: (globalThis as any).localStorage,
    addEventListener: () => {},
    dispatchEvent: () => true,
  };
  (globalThis as any).CustomEvent = class {
    type: string;
    detail: any;
    constructor(type: string, opts?: any) {
      this.type = type;
      this.detail = opts?.detail;
    }
  };
  (globalThis as any).E = (tag: string, attrs?: any, children?: any) => {
    const el = createMockElement(tag);
    if (attrs && typeof attrs === 'object') {
      for (const [k, v] of Object.entries(attrs)) {
        if (v === undefined || v === null) continue;
        if (k === 'click' && typeof v === 'function') {
          el.addEventListener('click', v as any);
        } else {
          el.setAttribute(k, String(v));
        }
      }
    }
    const append = (c: any) => {
      if (c === null || c === undefined || c === '') return;
      if (Array.isArray(c)) c.forEach(append);
      else if (typeof c === 'object') el.appendChild(c);
      else {
        const tn = createMockElement('#text');
        tn.textContent = String(c);
        el.appendChild(tn);
      }
    };
    append(children);
    return el;
  };
  (globalThis as any)._ = (s: string) => s;
});

import { renderTachyonDuckMascotSvg } from '../../icons/duckMascot';
import {
  getSidebarCollapsed,
  getSidebarPos,
  getTopbarCollapsed,
  getUiMode,
  mountTachyonAppShell,
  setSidebarCollapsed,
  setSidebarPos,
  setTopbarCollapsed,
  setUiMode,
} from '../appShell';
import { openConnectionWizardModal } from '../connectionWizard';
import { store } from '../services/store.service';

describe('Tachyon App Shell & SVG Developer Duck Mascot', () => {
  beforeEach(() => {
    storage.clear();
    (globalThis as any).document.body = createMockElement('body');
  });

  it('renders the custom vector SVG Developer Duck mascot', () => {
    const svg = renderTachyonDuckMascotSvg(64) as any;
    expect(svg.tagName).toBe('SVG');
    expect(svg.getAttribute('width')).toBe('64');
    expect(svg.getAttribute('height')).toBe('64');
    expect(svg.children.length).toBeGreaterThan(2);
  });

  it('persists UI mode (simple / advanced) and sidebar docking position', () => {
    expect(getUiMode()).toBe('simple');
    setUiMode('advanced');
    expect(getUiMode()).toBe('advanced');
    expect((globalThis as any).document.body.dataset.tachyonUiMode).toBe(
      'advanced',
    );

    expect(getSidebarPos()).toBe('left');
    setSidebarPos('right');
    expect(getSidebarPos()).toBe('right');

    expect(getSidebarCollapsed()).toBe(false);
    setSidebarCollapsed(true);
    expect(getSidebarCollapsed()).toBe(true);

    expect(getTopbarCollapsed()).toBe(false);
    setTopbarCollapsed(true);
    expect(getTopbarCollapsed()).toBe(true);
  });

  it('mounts sidebar + topbar shell and switches between simple and advanced navigation', () => {
    const E = (globalThis as any).E;
    const mapEl = E('div', { id: 'cbi-tachyon' }, [
      E('h2', {}, 'Tachyon Settings'),
      E('ul', { class: 'cbi-tabmenu' }, [
        E('li', { class: 'cbi-tab', 'data-tab': 'dashboard' }, [
          E('a', { href: '#' }, 'Dashboard'),
        ]),
        E('li', { class: 'cbi-tab-disabled', 'data-tab': 'section' }, [
          E('a', { href: '#' }, 'Sections'),
        ]),
        E('li', { class: 'cbi-tab-disabled', 'data-tab': 'server' }, [
          E('a', { href: '#' }, 'Servers'),
        ]),
      ]),
      E('div', { id: 'cbi-tachyon-dashboard', class: 'cbi-tab' }),
      E('div', { id: 'cbi-tachyon-section', class: 'cbi-tab-disabled' }),
      E('div', { id: 'cbi-tachyon-server', class: 'cbi-tab-disabled' }),
      E('div', { id: 'cbi-tachyon-profile', class: 'cbi-tab-disabled' }),
      E('div', { id: 'cbi-tachyon-schedule', class: 'cbi-tab-disabled' }),
      E('div', { id: 'cbi-tachyon-guest_mode', class: 'cbi-tab-disabled' }),
      E('div', { id: 'cbi-tachyon-monitoring', class: 'cbi-tab-disabled' }),
      E('div', { id: 'cbi-tachyon-diagnostic', class: 'cbi-tab-disabled' }),
      E('div', { id: 'cbi-tachyon-updates', class: 'cbi-tab-disabled' }),
      E('div', { id: 'cbi-tachyon-settings', class: 'cbi-tab-disabled' }),
      E('div', { id: 'cbi-tachyon-telegram', class: 'cbi-tab-disabled' }),
    ]);
    (globalThis as any).document.body.appendChild(mapEl);

    const onSelectSectionSubTab = vi.fn();
    mountTachyonAppShell({
      mapEl,
      onSelectSectionSubTab,
      getActiveSectionSubTab: () => 'sections',
    });

    const shell = mapEl.querySelector('#tachyon-app-shell');
    expect(shell).toBeTruthy();

    // Simple mode has 5 core navigation items
    const simpleNavButtons = mapEl.querySelectorAll(
      '.tachyon-sidebar__nav-item',
    );
    expect(simpleNavButtons.length).toBe(5);

    // Switch to Advanced mode via mode switcher button
    const modeBtns = mapEl.querySelectorAll('.tachyon-mode-switcher__btn');
    expect(modeBtns.length).toBe(2);
    modeBtns[1].click();

    expect(getUiMode()).toBe('advanced');
    const advancedSubItems = mapEl.querySelectorAll(
      '.tachyon-sidebar__subitem',
    );
    expect(advancedSubItems.length).toBeGreaterThan(10);

    // Verify .cbi-tabmenu and .cbi-section stay inside .tachyon-workspace-body as direct siblings
    const workspaceBody = mapEl.querySelector('.tachyon-workspace-body');
    expect(workspaceBody).toBeTruthy();
    expect(workspaceBody.querySelector('.cbi-tabmenu')).toBeTruthy();
    expect(workspaceBody.querySelector('#cbi-tachyon-dashboard')).toBeTruthy();

    // Verify both mobile and footer sidebar status dots update when servicesInfoWidget transitions to running
    store.set({
      servicesInfoWidget: {
        loading: false,
        failed: false,
        data: {
          tachyonRunning: true,
          tachyonStatus: 'running',
        } as any,
      },
    });
    const statusDots = mapEl.querySelectorAll('.tachyon-sidebar__status-dot');
    expect(statusDots.length).toBe(2);
    for (const dot of statusDots) {
      expect(dot.className).toContain('tachyon-sidebar__status-dot--ok');
      expect(dot.className).not.toContain('tachyon-sidebar__status-dot--err');
    }

    // Verify topbar collapse button toggles topbar collapsed state
    const topbarCollapseBtn = mapEl.querySelector(
      '.tachyon-topbar__collapse-btn',
    );
    expect(topbarCollapseBtn).toBeTruthy();
    expect(getTopbarCollapsed()).toBe(false);
    topbarCollapseBtn.click();
    expect(getTopbarCollapsed()).toBe(true);
    expect(mapEl.getAttribute('data-topbar-collapsed')).toBe('true');
  });

  it('activates custom defaultNavKey and expands parent menu on initial mount', () => {
    setUiMode('advanced');
    const E = (globalThis as any).E;
    const mapEl = E('div', { id: 'cbi-tachyon' }, [
      E('ul', { class: 'cbi-tabmenu' }, [
        E('li', { class: 'cbi-tab-disabled', 'data-tab': 'dashboard' }, [
          E('a', { href: '#' }, 'Dashboard'),
        ]),
        E('li', { class: 'cbi-tab-disabled', 'data-tab': 'monitoring' }, [
          E('a', { href: '#' }, 'Monitoring'),
        ]),
      ]),
      E('div', { id: 'cbi-tachyon-dashboard', class: 'cbi-tab-disabled' }),
      E('div', { id: 'cbi-tachyon-monitoring', class: 'cbi-tab-disabled' }),
    ]);
    (globalThis as any).document.body.appendChild(mapEl);

    mountTachyonAppShell({
      mapEl,
      defaultNavKey: 'monitoring',
    });

    const subItems = mapEl.querySelectorAll('.tachyon-sidebar__subitem');
    const monitoringItem = subItems.find(
      (el: any) => el.getAttribute('data-nav-key') === 'monitoring',
    );
    expect(monitoringItem).toBeTruthy();
    expect(monitoringItem.className).toContain('is-active');
  });

  it('opens Connection Wizard modal and saves UCI entities via uci.save()', async () => {
    let modalRoot: any = null;
    const uciStore: Record<string, Record<string, any>> = {};
    const saveMock = vi.fn().mockResolvedValue(undefined);
    const changesInitMock = vi.fn().mockResolvedValue(undefined);

    (globalThis as any).ui = {
      showModal(_title: any, children: any[]) {
        modalRoot = children[0];
      },
      hideModal: vi.fn(),
      changes: {
        init: changesInitMock,
        apply: vi.fn().mockResolvedValue(undefined),
      },
    };
    (globalThis as any).uci = {
      sections: () => [],
      get: (_pkg: string, sec: string, opt?: string) => {
        if (!opt) return uciStore[sec];
        return uciStore[sec]?.[opt];
      },
      add: (_pkg: string, type: string, sec: string) => {
        uciStore[sec] = { '.type': type, '.name': sec };
        return sec;
      },
      set: (_pkg: string, sec: string, opt: string, val: any) => {
        if (!uciStore[sec]) uciStore[sec] = { '.name': sec };
        uciStore[sec][opt] = val;
      },
      save: saveMock,
    };

    const onComplete = vi.fn();
    openConnectionWizardModal({
      initialDirection: 'outbound',
      onComplete,
    });

    expect(modalRoot).toBeTruthy();
    // Switch to Desync method (index 3) so no URL input is required
    const methodCards = modalRoot.querySelectorAll(
      '.tachyon-wizard__method-card',
    );
    expect(methodCards.length).toBeGreaterThan(3);
    methodCards[3].click();

    // Advance from Step 2 to Step 3 (Traffic & Lists)
    const footerBtnsStep2 = modalRoot.querySelectorAll('.btn');
    const nextBtnStep2 = footerBtnsStep2[footerBtnsStep2.length - 1];
    nextBtnStep2.click();

    // Advance from Step 3 to Step 4 (DNS & Protection)
    const footerBtnsStep3 = modalRoot.querySelectorAll('.btn');
    const nextBtnStep3 = footerBtnsStep3[footerBtnsStep3.length - 1];
    nextBtnStep3.click();

    // Click Create (Draft) button in Step 4
    const footerBtnsStep4 = modalRoot.querySelectorAll('.btn');
    const createDraftBtn = footerBtnsStep4[footerBtnsStep4.length - 2];
    createDraftBtn.click();

    await new Promise((r) => setTimeout(r, 10));
    expect(saveMock).toHaveBeenCalled();
    expect(changesInitMock).toHaveBeenCalled();
    expect(onComplete).toHaveBeenCalledWith(
      expect.objectContaining({ direction: 'outbound' }),
    );
  });
});
