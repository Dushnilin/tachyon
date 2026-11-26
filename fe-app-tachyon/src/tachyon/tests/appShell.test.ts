/* eslint-disable @typescript-eslint/no-explicit-any */
import { beforeEach, describe, expect, it, vi } from 'vitest';

const storage = new Map<string, string>();

function createMockElement(tag: string): any {
  const attrs: Record<string, string> = {};
  const dataset: Record<string, string> = {};
  const listeners: Record<string, Array<(ev: any) => void>> = {};
  const captureListeners: Record<string, Array<(ev: any) => void>> = {};
  const styleObj: Record<string, any> = {
    setProperty(k: string, v: string, priority?: string) {
      styleObj[k] = priority ? `${v} !${priority}` : String(v);
    },
    removeProperty(k: string) {
      delete styleObj[k];
    },
    getPropertyValue(k: string) {
      return styleObj[k] || '';
    },
  };
  const el: any = {
    tagName: tag.toUpperCase(),
    parentElement: null as any,
    children: [] as any[],
    style: styleObj,
    className: '',
    textContent: '',
    dataset,
    get id() {
      return attrs.id || '';
    },
    set id(v: string) {
      attrs.id = String(v);
    },
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
    hasAttribute(k: string) {
      if (k === 'class') return Boolean(el.className || attrs.class);
      return k in attrs;
    },
    addEventListener(
      type: string,
      cb: (ev: any) => void,
      opts?: boolean | { capture?: boolean },
    ) {
      const isCapture =
        opts === true ||
        Boolean(opts && typeof opts === 'object' && opts.capture);
      const bucket = isCapture ? captureListeners : listeners;
      if (!bucket[type]) bucket[type] = [];
      bucket[type].push(cb);
    },
    dispatchEvent(ev: any) {
      const eventObj = Object.assign({ target: el, bubbles: false }, ev || {});
      const ancestors: any[] = [];
      let cur = el.parentElement;
      while (cur) {
        ancestors.unshift(cur);
        cur = cur.parentElement;
      }
      for (const anc of ancestors) {
        for (const fn of anc._getCaptureListeners?.(eventObj.type) || []) {
          fn(eventObj);
        }
      }
      for (const fn of listeners[eventObj.type] || []) {
        fn(eventObj);
      }
      if (eventObj.bubbles) {
        for (let i = ancestors.length - 1; i >= 0; i--) {
          for (const fn of ancestors[i]._getListeners?.(eventObj.type) || []) {
            fn(eventObj);
          }
        }
      }
      return true;
    },
    contains(other: any): boolean {
      let cur = other;
      while (cur) {
        if (cur === el) return true;
        cur = cur.parentElement;
      }
      return false;
    },
    closest(sel: string): any {
      let cur: any = el;
      while (cur) {
        if (sel === '.cbi-tabmenu > li[data-tab]') {
          if (
            cur.tagName === 'LI' &&
            cur.hasAttribute?.('data-tab') &&
            cur.parentElement?.classList?.contains('cbi-tabmenu')
          ) {
            return cur;
          }
        } else if (sel.startsWith('#')) {
          if (cur.getAttribute?.('id') === sel.slice(1)) return cur;
        } else if (sel.startsWith('.')) {
          if (cur.classList?.contains(sel.slice(1))) return cur;
        }
        cur = cur.parentElement;
      }
      return null;
    },
    click() {
      const ev = {
        target: el,
        preventDefault() {},
        stopPropagation() {},
      };
      const path: any[] = [];
      let cur: any = el;
      while (cur) {
        path.push(cur);
        cur = cur.parentElement;
      }
      for (const node of path) {
        const cbs = node._getListeners?.('click') || [];
        cbs.forEach((fn: any) => fn(ev));
      }
    },
    _getListeners(type: string) {
      return listeners[type] || [];
    },
    _getCaptureListeners(type: string) {
      return captureListeners[type] || [];
    },
    appendChild(child: any) {
      if (child != null && child !== '') {
        if (typeof child === 'object') child.parentElement = el;
        el.children.push(child);
      }
      return child;
    },
    replaceChildren(...nodes: any[]) {
      el.children = nodes.filter((n) => n != null && n !== '');
      el.children.forEach((n: any) => {
        if (typeof n === 'object') n.parentElement = el;
      });
    },
    insertBefore(newNode: any, refNode: any) {
      if (newNode && typeof newNode === 'object') newNode.parentElement = el;
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
        const trimmed = s.trim();
        if (trimmed.includes(' > ')) {
          const parts = trimmed.split(/\s*>\s*/);
          const last = parts[parts.length - 1];
          if (!matchSingle(node, last)) return false;
          let parent = node.parentElement;
          for (let i = parts.length - 2; i >= 0; i--) {
            if (!parent) return false;
            if (parts[i] === ':scope') {
              if (parent !== el) return false;
            } else if (!matchSingle(parent, parts[i])) {
              return false;
            }
            parent = parent.parentElement;
          }
          return true;
        }
        if (trimmed.startsWith('#')) {
          return node.getAttribute?.('id') === trimmed.slice(1);
        }
        if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
          const inner = trimmed.slice(1, -1);
          const eqIdx = inner.indexOf('=');
          if (eqIdx < 0) return node.hasAttribute?.(inner);
          const rawKey = inner.slice(0, eqIdx);
          const val = inner.slice(eqIdx + 1).replace(/^["']|["']$/g, '');
          if (rawKey.endsWith('^')) {
            const attrKey = rawKey.slice(0, -1);
            return (node.getAttribute?.(attrKey) || '').startsWith(val);
          }
          return node.getAttribute?.(rawKey) === val;
        }
        const bracketIdx = trimmed.indexOf('[');
        if (bracketIdx > 0 && trimmed.endsWith(']')) {
          const base = trimmed.slice(0, bracketIdx);
          const attrPart = trimmed.slice(bracketIdx);
          return matchSingle(node, base) && matchSingle(node, attrPart);
        }
        if (trimmed.startsWith('.')) {
          const cls = trimmed.slice(1);
          return (node.className || '').split(/\s+/).includes(cls);
        }
        return (node.tagName || '').toLowerCase() === trimmed.toLowerCase();
      };
      const selectors = sel.split(',').map((s) => s.trim());
      const walk = (node: any) => {
        if (!node || !Array.isArray(node.children)) return;
        for (const child of node.children) {
          if (child && typeof child === 'object') {
            if (selectors.some((sub) => matchSingle(child, sub))) {
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
import { GlobalStyles } from '../../styles';
import {
  collectAvailableComponentUpdates,
  getSavedActiveNavKey,
  getSidebarCollapsed,
  getSidebarPos,
  getTopbarCollapsed,
  getUiMode,
  mountTachyonAppShell,
  setShellRestoringTab,
  setSidebarCollapsed,
  setSidebarPos,
  setTopbarCollapsed,
  setUiMode,
} from '../appShell';
import { openConnectionWizardModal } from '../connectionWizard';
import { store } from '../services/store.service';
import { switchToServersTab } from '../tabs/dashboard/inboundServers';

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

    expect(getSidebarPos()).toBe('top');
    setSidebarPos('left');
    expect(getSidebarPos()).toBe('left');
    setSidebarPos('top');
    expect(getSidebarPos()).toBe('top');

    expect(getSidebarCollapsed()).toBe(false);
    setSidebarCollapsed(true);
    expect(getSidebarCollapsed()).toBe(true);

    expect(getTopbarCollapsed()).toBe(false);
    setTopbarCollapsed(true);
    expect(getTopbarCollapsed()).toBe(true);
  });

  it('mounts sidebar + topbar shell and switches between simple and advanced navigation', () => {
    setSidebarPos('left');
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
    expect(advancedSubItems.length).toBeGreaterThan(7);

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

  it('activates custom defaultNavKey on initial mount', () => {
    setSidebarPos('left');
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

    const navItems = mapEl.querySelectorAll('[data-nav-key]');
    const monitoringItem = navItems.find(
      (el: any) => el.getAttribute('data-nav-key') === 'monitoring',
    );
    expect(monitoringItem).toBeTruthy();
    expect(monitoringItem.className).toContain('is-active');
  });

  it('preserves active tab and sub-tab across remounts even when defaultNavKey is dashboard', () => {
    setSidebarPos('left');
    setUiMode('advanced');
    const E = (globalThis as any).E;
    const mapEl = E('div', { id: 'cbi-tachyon' }, [
      E('ul', { class: 'cbi-tabmenu' }, [
        E('li', { class: 'cbi-tab', 'data-tab': 'dashboard' }, [
          E('a', { href: '#' }, 'Dashboard'),
        ]),
        E('li', { class: 'cbi-tab-disabled', 'data-tab': 'section' }, [
          E('a', { href: '#' }, 'Sections'),
        ]),
        E('li', { class: 'cbi-tab-disabled', 'data-tab': 'settings' }, [
          E('a', { href: '#' }, 'Settings'),
        ]),
      ]),
      E('div', { id: 'cbi-tachyon-dashboard', class: 'cbi-section cbi-tab' }),
      E('div', {
        id: 'cbi-tachyon-section',
        class: 'cbi-section cbi-tab-disabled',
      }),
      E(
        'div',
        { id: 'cbi-tachyon-settings', class: 'cbi-section cbi-tab-disabled' },
        [
          E('ul', { class: 'cbi-tabmenu' }, [
            E('li', { class: 'cbi-tab', 'data-tab': 'dns' }, [
              E('a', { href: '#' }, 'DNS'),
            ]),
            E('li', { class: 'cbi-tab-disabled', 'data-tab': 'network' }, [
              E('a', { href: '#' }, 'Network'),
            ]),
          ]),
        ],
      ),
    ]);
    (globalThis as any).document.body.appendChild(mapEl);

    let currentSubTab = 'sections';
    mountTachyonAppShell({
      mapEl,
      defaultNavKey: 'dashboard',
      onSelectSectionSubTab: (sub) => {
        currentSubTab = sub;
      },
      getActiveSectionSubTab: () => currentSubTab,
    });

    // Click on "Узлы и подписки" (section:outbounds)
    let navItems = mapEl.querySelectorAll('[data-nav-key]');
    const outboundsItem = navItems.find(
      (el: any) => el.getAttribute('data-nav-key') === 'section:outbounds',
    );
    expect(outboundsItem).toBeTruthy();
    outboundsItem.click();
    expect(currentSubTab).toBe('outbounds');

    // Simulate LuCI Save / Save & Apply re-render where mountTachyonAppShell is called again with defaultNavKey: 'dashboard'
    mountTachyonAppShell({
      mapEl,
      defaultNavKey: 'dashboard',
      onSelectSectionSubTab: (sub) => {
        currentSubTab = sub;
      },
      getActiveSectionSubTab: () => currentSubTab,
    });

    navItems = mapEl.querySelectorAll('[data-nav-key]');
    const outboundsAfterSave = navItems.find(
      (el: any) => el.getAttribute('data-nav-key') === 'section:outbounds',
    );
    expect(outboundsAfterSave.className).toContain('is-active');
    expect(currentSubTab).toBe('outbounds');
  });

  it('renders flat top-bar tabs without dropdowns, mounts language selector at top, and renders global sub-tab pills across all categories including updates', () => {
    setUiMode('advanced');
    setSidebarCollapsed(true);
    setTopbarCollapsed(true);
    setSidebarPos('top');
    const E = (globalThis as any).E;

    const settingsNavPane = E('div', {
      'data-tab': 'navigation',
      class: 'cbi-tab',
    });
    const settingsDnsPane = E('div', {
      'data-tab': 'dns',
      class: 'cbi-tab-disabled',
    });
    const settingsNode = E(
      'div',
      { class: 'cbi-section-node cbi-section-node-tabbed' },
      [settingsNavPane, settingsDnsPane],
    );
    const settingsDnsLink = E('a', { href: '#' }, 'DNS');

    const mapEl = E('div', { id: 'cbi-tachyon' }, [
      E('ul', { class: 'cbi-tabmenu' }, [
        E('li', { class: 'cbi-tab', 'data-tab': 'dashboard' }, [
          E('a', { href: '#' }, 'Dashboard'),
        ]),
        E('li', { class: 'cbi-tab-disabled', 'data-tab': 'profile' }, [
          E('a', { href: '#' }, 'Profile'),
        ]),
        E('li', { class: 'cbi-tab-disabled', 'data-tab': 'schedule' }, [
          E('a', { href: '#' }, 'Schedule'),
        ]),
        E('li', { class: 'cbi-tab-disabled', 'data-tab': 'diagnostic' }, [
          E('a', { href: '#' }, 'Diagnostic'),
        ]),
        E('li', { class: 'cbi-tab-disabled', 'data-tab': 'updates' }, [
          E('a', { href: '#' }, 'Updates'),
        ]),
        E('li', { class: 'cbi-tab-disabled', 'data-tab': 'settings' }, [
          E('a', { href: '#' }, 'Settings'),
        ]),
      ]),
      E('div', { id: 'cbi-tachyon-dashboard', class: 'cbi-section cbi-tab' }),
      E('div', {
        id: 'cbi-tachyon-profile',
        class: 'cbi-section cbi-tab-disabled',
      }),
      E('div', {
        id: 'cbi-tachyon-schedule',
        class: 'cbi-section cbi-tab-disabled',
      }),
      E('div', {
        id: 'cbi-tachyon-diagnostic',
        class: 'cbi-section cbi-tab-disabled',
      }),
      E('div', {
        id: 'cbi-tachyon-updates',
        class: 'cbi-section cbi-tab-disabled',
      }),
      E(
        'div',
        { id: 'cbi-tachyon-settings', class: 'cbi-section cbi-tab-disabled' },
        [
          E('ul', { class: 'cbi-tabmenu' }, [
            E('li', { class: 'cbi-tab', 'data-tab': 'navigation' }, [
              E('a', { href: '#' }, 'Nav'),
            ]),
            E('li', { class: 'cbi-tab-disabled', 'data-tab': 'dns' }, [
              settingsDnsLink,
            ]),
          ]),
          settingsNode,
        ],
      ),
    ]);
    (globalThis as any).document.body.appendChild(mapEl);

    mountTachyonAppShell({
      mapEl,
      defaultNavKey: 'dashboard',
    });

    // Top bar forces data-sidebar-collapsed="false" and data-topbar-collapsed="false" even when true in localStorage
    expect(mapEl.getAttribute('data-sidebar-pos')).toBe('top');
    expect(mapEl.getAttribute('data-sidebar-collapsed')).toBe('false');
    expect(mapEl.getAttribute('data-topbar-collapsed')).toBe('false');

    // Language selector slot is mounted directly inside the top bar (.tachyon-sidebar)
    const sidebarEl = mapEl.querySelector('.tachyon-sidebar');
    expect(sidebarEl.querySelector('.tachyon-topbar__lang-slot')).toBeTruthy();

    // No dropdown submenus or chevrons in top-bar mode
    expect(mapEl.querySelectorAll('.tachyon-sidebar__submenu').length).toBe(0);
    expect(mapEl.querySelectorAll('.tachyon-sidebar__chevron').length).toBe(0);

    // On Dashboard, the 2nd strip (.tachyon-topbar--subnav) is completely hidden
    const topbarEl = mapEl.querySelector('.tachyon-topbar');
    expect(topbarEl.className).toContain('tachyon-topbar--subnav');
    expect(topbarEl.style.display).toBe('none');

    // Inactive sections (including diagnostic) must have inline display: none !important
    const diagSec = mapEl.querySelector('#cbi-tachyon-diagnostic');
    expect(diagSec.style.display).toBe('none !important');
    expect(diagSec.getAttribute('data-tab-active')).toBe('false');

    // Clicking "Клиенты и сеть" activates profile directly WITHOUT any dropdown and renders global sub-tab pills
    const menuParents = mapEl.querySelectorAll('.tachyon-sidebar__nav-parent');
    const clientsParent = menuParents.find(
      (btn: any) => btn.getAttribute('data-parent-menu') === 'clients',
    );
    expect(clientsParent).toBeTruthy();
    clientsParent.click();

    expect(mapEl.querySelectorAll('.tachyon-sidebar__submenu').length).toBe(0);
    expect(topbarEl.style.display).toBe('');
    const profileSec = mapEl.querySelector('#cbi-tachyon-profile');
    expect(profileSec.getAttribute('data-tab-active')).toBe('true');
    expect(profileSec.style.display).toBeUndefined();
    expect(diagSec.style.display).toBe('none !important');

    // Clicking global sub-tab ("Родительский контроль" -> schedule) switches active section
    const scheduleSubLi = topbarEl
      .querySelectorAll('.tachyon-global-subtabs > li')
      .find((li: any) => li.getAttribute('data-nav-key') === 'schedule');
    expect(scheduleSubLi).toBeTruthy();
    scheduleSubLi.querySelector('a').click();
    const scheduleSec = mapEl.querySelector('#cbi-tachyon-schedule');
    expect(scheduleSec.getAttribute('data-tab-active')).toBe('true');
    expect(profileSec.style.display).toBe('none !important');

    // Clicking "Настройки" renders global sub-tabs including "Компоненты и ядро" (updates) and settings:* tabs
    const settingsParent = mapEl
      .querySelectorAll('.tachyon-sidebar__nav-parent')
      .find((btn: any) => btn.getAttribute('data-parent-menu') === 'system');
    settingsParent.click();

    const systemSubLis = topbarEl.querySelectorAll(
      '.tachyon-global-subtabs > li',
    );
    const updatesSubLi = systemSubLis.find(
      (li: any) => li.getAttribute('data-nav-key') === 'updates',
    );
    const dnsSubLi = systemSubLis.find(
      (li: any) => li.getAttribute('data-nav-key') === 'settings:dns',
    );
    expect(updatesSubLi).toBeTruthy();
    expect(dnsSubLi).toBeTruthy();

    // Clicking settings:dns in global sub-tabs switches internal settings pane
    dnsSubLi.querySelector('a').click();
    expect(settingsDnsPane.getAttribute('data-tab-active')).toBe('true');
    expect(settingsNavPane.getAttribute('data-tab-active')).toBe('false');

    // Clicking updates ("Компоненты и ядро") switches away from #cbi-tachyon-settings to #cbi-tachyon-updates
    updatesSubLi.querySelector('a').click();
    const updatesSec = mapEl.querySelector('#cbi-tachyon-updates');
    const settingsSec = mapEl.querySelector('#cbi-tachyon-settings');
    expect(updatesSec.getAttribute('data-tab-active')).toBe('true');
    expect(settingsSec.style.display).toBe('none !important');
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

  it('renders mobile hamburger toggle and expandable submenus when top-bar mode is viewed on mobile', () => {
    setUiMode('advanced');
    setSidebarPos('top');
    const E = (globalThis as any).E;
    const prevMatchMedia = (globalThis.window as any)?.matchMedia;
    (globalThis.window as any).matchMedia = (query: string) => ({
      matches: query.includes('860px'),
      media: query,
      addEventListener: () => {},
      removeEventListener: () => {},
    });

    try {
      const mapEl = E('div', { id: 'cbi-tachyon' }, [
        E('ul', { class: 'cbi-tabmenu' }, [
          E('li', { class: 'cbi-tab', 'data-tab': 'dashboard' }, [
            E('a', { href: '#' }, 'Dashboard'),
          ]),
          E('li', { class: 'cbi-tab-disabled', 'data-tab': 'section' }, [
            E('a', { href: '#' }, 'Sections'),
          ]),
          E('li', { class: 'cbi-tab-disabled', 'data-tab': 'sources' }, [
            E('a', { href: '#' }, 'Sources'),
          ]),
        ]),
        E('div', {
          id: 'cbi-tachyon-dashboard',
          class: 'cbi-section cbi-tab',
        }),
        E('div', {
          id: 'cbi-tachyon-section',
          class: 'cbi-section cbi-tab-disabled',
        }),
        E('div', {
          id: 'cbi-tachyon-sources',
          class: 'cbi-section cbi-tab-disabled',
        }),
      ]);
      (globalThis as any).document.body.appendChild(mapEl);
      mountTachyonAppShell({
        mapEl,
        defaultNavKey: 'dashboard',
      });

      const sidebarEl = mapEl.querySelector('.tachyon-sidebar');
      const mobileToggle = mapEl.querySelector(
        '.tachyon-sidebar__mobile-toggle',
      );
      expect(mobileToggle).toBeTruthy();
      expect(mobileToggle.getAttribute('aria-expanded')).toBe('false');

      // Submenus ARE rendered on compact mobile viewport even in top-bar mode
      expect(
        mapEl.querySelectorAll('.tachyon-sidebar__submenu').length,
      ).toBeGreaterThan(0);

      // Opening hamburger menu sets is-mobile-open, data-mobile-menu-open="true", and flips aria-expanded
      mobileToggle.click();
      expect(sidebarEl.className).toContain('is-mobile-open');
      expect(mapEl.getAttribute('data-mobile-menu-open')).toBe('true');

      const openedToggle = mapEl.querySelector(
        '.tachyon-sidebar__mobile-toggle',
      );
      expect(openedToggle.getAttribute('aria-expanded')).toBe('true');

      // Clicking a parent menu expands its submenu instead of leaving the drawer immediately
      const routingParent = mapEl
        .querySelectorAll('.tachyon-sidebar__nav-parent')
        .find((btn: any) => btn.getAttribute('data-parent-menu') === 'routing');
      expect(routingParent).toBeTruthy();
      routingParent.click();
      expect(sidebarEl.className).toContain('is-mobile-open');

      // Clicking a leaf subitem navigates and closes mobile drawer
      const sectionSubItem = mapEl
        .querySelectorAll('.tachyon-sidebar__subitem')
        .find(
          (btn: any) => btn.getAttribute('data-nav-key') === 'section:sections',
        );
      expect(sectionSubItem).toBeTruthy();
      sectionSubItem.click();
      expect(sidebarEl.className).not.toContain('is-mobile-open');
      expect(mapEl.getAttribute('data-mobile-menu-open')).toBe('false');
    } finally {
      if (prevMatchMedia === undefined) {
        delete (globalThis.window as any).matchMedia;
      } else {
        (globalThis.window as any).matchMedia = prevMatchMedia;
      }
    }
  });

  it('reveals #cbi-tachyon-server via switchToServersTab even when show_tab_servers is off', () => {
    const E = (globalThis as any).E;
    let tabLinkClicked = false;
    const serverLi = E(
      'li',
      { class: 'cbi-tab-disabled', 'data-tab': 'server' },
      [
        E(
          'a',
          {
            href: '#',
            click: () => {
              tabLinkClicked = true;
            },
          },
          'Servers',
        ),
      ],
    );
    const dashboardSec = E('div', {
      id: 'cbi-tachyon-dashboard',
      class: 'cbi-section cbi-tab',
    });
    const serverSec = E('div', {
      id: 'cbi-tachyon-server',
      class: 'cbi-section cbi-tab-disabled',
    });
    const mapEl = E('div', { id: 'cbi-tachyon' }, [
      E('ul', { class: 'cbi-tabmenu' }, [
        E('li', { class: 'cbi-tab', 'data-tab': 'dashboard' }, [
          E('a', { href: '#' }, 'Dashboard'),
        ]),
        serverLi,
      ]),
      dashboardSec,
      serverSec,
    ]);
    (globalThis as any).uci = {
      sections: () => [],
      get: () => undefined,
    };

    mountTachyonAppShell({
      mapEl,
      defaultNavKey: 'dashboard',
      isTabVisible: (id) => id !== 'server',
    });

    // Server item must not be rendered in sidebar while show_tab_servers is off
    expect(
      mapEl
        .querySelectorAll('.tachyon-sidebar__subitem')
        .find((el: any) => el.getAttribute('data-nav-key') === 'server'),
    ).toBeUndefined();
    expect(serverSec.style.display).toBe('none !important');
    expect(dashboardSec.style.display || '').toBe('');

    const switched = switchToServersTab();
    expect(switched).toBe(true);
    expect(tabLinkClicked).toBe(true);
    expect(serverSec.style.display || '').toBe('');
    expect(serverSec.getAttribute('data-tab-active')).toBe('true');
    expect(dashboardSec.style.display).toBe('none !important');
    expect(dashboardSec.getAttribute('data-tab-active')).toBe('false');
  });

  it('handles non-bubbling cbi-tab-active events in capture phase in top navbar mode', () => {
    setSidebarPos('top');
    setUiMode('advanced');
    const E = (globalThis as any).E;
    const dashboardSec = E('div', {
      id: 'cbi-tachyon-dashboard',
      class: 'cbi-section cbi-tab',
    });
    const sectionSec = E('div', {
      id: 'cbi-tachyon-section',
      class: 'cbi-section cbi-tab-disabled',
    });
    const mapEl = E('div', { id: 'cbi-tachyon' }, [
      E('ul', { class: 'cbi-tabmenu' }, [
        E('li', { class: 'cbi-tab', 'data-tab': 'dashboard' }, [
          E('a', { href: '#' }, 'Dashboard'),
        ]),
        E('li', { class: 'cbi-tab-disabled', 'data-tab': 'section' }, [
          E('a', { href: '#' }, 'Sections'),
        ]),
      ]),
      dashboardSec,
      sectionSec,
    ]);
    (globalThis as any).document.body.appendChild(mapEl);

    mountTachyonAppShell({
      mapEl,
      defaultNavKey: 'dashboard',
    });

    expect(dashboardSec.style.display || '').toBe('');
    expect(sectionSec.style.display).toBe('none !important');

    // Simulate OpenWrt ui.js tab activation: updates DOM state and dispatches
    // CustomEvent('cbi-tab-active', { detail: { tab: 'section' }, bubbles: false })
    sectionSec.dispatchEvent({
      type: 'cbi-tab-active',
      detail: { tab: 'section' },
      bubbles: false,
    });

    expect(sectionSec.style.display || '').toBe('');
    expect(sectionSec.getAttribute('data-tab-active')).toBe('true');
    expect(dashboardSec.style.display).toBe('none !important');
    expect(dashboardSec.getAttribute('data-tab-active')).toBe('false');
  });

  it('shows update badge and dismissible banner when component updates exist and hides them on dismissal or when latest', () => {
    expect(
      collectAvailableComponentUpdates(
        {
          tachyon_version: '2.0.0-beta.20',
          tachyon_latest_version: '2.0.0-rc.1',
          tachyon_update_available: 1,
          tachyon_core_version: '0.6.3',
          tachyon_core_latest_version: '0.6.4',
          tachyon_core_update_available: 1,
        },
        {},
      ),
    ).toHaveLength(2);

    expect(
      collectAvailableComponentUpdates(
        {
          tachyon_update_available: 1,
          tachyon_latest_version: '2.0.0-rc.1',
        },
        {
          tachyon: {
            status: 'latest',
            latest_version: '2.0.0-rc.1',
            release_url: '',
          },
        },
      ),
    ).toEqual([]);

    setSidebarPos('left');
    setUiMode('advanced');
    const E = (globalThis as any).E;
    const dashboardSec = E('div', {
      id: 'cbi-tachyon-dashboard',
      class: 'cbi-section cbi-tab',
    });
    const updatesSec = E('div', {
      id: 'cbi-tachyon-updates',
      class: 'cbi-section cbi-tab-disabled',
    });
    const mapEl = E('div', { id: 'cbi-tachyon' }, [
      E('ul', { class: 'cbi-tabmenu' }, [
        E('li', { class: 'cbi-tab', 'data-tab': 'dashboard' }, [
          E('a', { href: '#' }, 'Dashboard'),
        ]),
        E('li', { class: 'cbi-tab-disabled', 'data-tab': 'updates' }, [
          E('a', { href: '#' }, 'Updates'),
        ]),
      ]),
      dashboardSec,
      updatesSec,
    ]);
    (globalThis as any).document.body.appendChild(mapEl);

    const prevSys = store.get().diagnosticsSystemInfo;
    store.set({
      diagnosticsSystemInfo: {
        ...prevSys,
        tachyon_version: '2.0.0-beta.20',
        tachyon_latest_version: '2.0.0-rc.1',
        tachyon_update_available: 1,
        tachyon_core_version: '0.6.3',
        tachyon_core_latest_version: '0.6.3',
        tachyon_core_update_available: 0,
      },
    });

    mountTachyonAppShell({
      mapEl,
      defaultNavKey: 'dashboard',
    });

    const banner = mapEl.querySelector('.tachyon-update-banner');
    expect(banner).toBeTruthy();
    expect(banner.classList.contains('is-hidden')).toBe(false);
    const badge = mapEl.querySelector(
      '.tachyon-sidebar__update-badge[data-update-target="updates"]',
    );
    expect(badge?.textContent).toBe('1');
    expect(badge?.classList.contains('is-hidden')).toBe(false);

    const dismissBtn = banner.querySelector('.tachyon-update-banner__dismiss');
    dismissBtn.click();
    expect(banner.classList.contains('is-hidden')).toBe(true);
    expect(storage.get('tachyon_dismissed_update_sig_v1')).toBe(
      'tachyon@2.0.0-rc.1',
    );

    // A newer version re-opens the banner even after previous signature dismissal
    store.set({
      diagnosticsSystemInfo: {
        ...store.get().diagnosticsSystemInfo,
        tachyon_latest_version: '2.0.0',
      },
    });
    expect(banner.classList.contains('is-hidden')).toBe(false);

    // Clicking Open Updates navigates directly to updates tab and hides banner there
    const openBtn = banner.querySelector('.tachyon-update-banner__action');
    openBtn.click();
    expect(updatesSec.getAttribute('data-tab-active')).toBe('true');
    expect(banner.classList.contains('is-hidden')).toBe(true);
  });

  it('uses a two-row header layout and theme CSS variables in desktop top-bar mode', () => {
    const desktopMediaStart = GlobalStyles.indexOf('@media (min-width: 861px)');
    expect(desktopMediaStart).toBeGreaterThan(-1);
    const desktopSection = GlobalStyles.slice(
      desktopMediaStart,
      desktopMediaStart + 2500,
    );
    expect(desktopSection).toContain('.tachyon-sidebar');
    expect(desktopSection).toContain('flex-wrap: wrap !important;');
    expect(desktopSection).toContain('.tachyon-sidebar__nav');
    expect(desktopSection).toContain('order: 3;');
    expect(desktopSection).toContain('flex: 1 0 100% !important;');

    const topNavActiveStart = GlobalStyles.indexOf(
      '.tachyon-shell-layout[data-sidebar-pos="top"] .tachyon-sidebar__nav-item.is-active',
    );
    expect(topNavActiveStart).toBeGreaterThan(-1);
    const topNavActiveBlock = GlobalStyles.slice(
      topNavActiveStart,
      topNavActiveStart + 420,
    );
    expect(topNavActiveBlock).toContain('var(--text');
    expect(topNavActiveBlock).toContain('var(--elevated');
    expect(topNavActiveBlock).not.toContain('background: #222227');

    // Guard against OpenWrt Bootstrap sticky header (z-index: 800) leaking onto inner card <header> tags
    const headerOverrideStart = GlobalStyles.indexOf(
      '/* Keep LuCI top navigation bar and its dropdown menus above Tachyon stacking contexts */',
    );
    expect(headerOverrideStart).toBeGreaterThan(-1);
    const headerOverrideBlock = GlobalStyles.slice(
      headerOverrideStart,
      headerOverrideStart + 650,
    );
    expect(headerOverrideBlock).not.toMatch(/^\s*header,\s*$/m);
    expect(headerOverrideBlock).toContain('#cbi-tachyon header');
    expect(headerOverrideBlock).toContain('position: static !important;');
    expect(headerOverrideBlock).toContain('z-index: auto !important;');

    // Guard against modal overflow clipping Priority Tiers / DynamicList dropdowns (#493)
    expect(GlobalStyles).toContain(
      '#modal_overlay > .modal:has(.cbi-dropdown[open])',
    );
    expect(GlobalStyles).toContain('overflow: visible !important;');
    const dynDropdownLiStart = GlobalStyles.indexOf(
      '#modal_overlay .cbi-dropdown[open] > ul > li',
    );
    expect(dynDropdownLiStart).toBeGreaterThan(-1);
    const dynDropdownLiBlock = GlobalStyles.slice(
      dynDropdownLiStart,
      dynDropdownLiStart + 280,
    );
    expect(dynDropdownLiBlock).toContain('white-space: normal !important;');
    expect(dynDropdownLiBlock).toContain('overflow-wrap: anywhere !important;');
  });

  it('always displays the exact clicked submenu item even when LuCI tabLink.click() synchronously dispatches cbi-tab-active', () => {
    setUiMode('advanced');
    setSidebarPos('top');
    const E = (globalThis as any).E;

    const sectionSec = E('div', {
      id: 'cbi-tachyon-section',
      class: 'cbi-section cbi-tab-disabled',
    });
    const dashboardSec = E('div', {
      id: 'cbi-tachyon-dashboard',
      class: 'cbi-section cbi-tab',
    });
    const updatesSec = E('div', {
      id: 'cbi-tachyon-updates',
      class: 'cbi-section cbi-tab-disabled',
    });

    const settingsSubKeys = [
      'navigation',
      'dns',
      'network',
      'services',
      'updates',
      'ai',
      'advanced',
    ];
    const settingsPanes = settingsSubKeys.map((k, idx) =>
      E('div', {
        'data-tab': k,
        class: idx === 0 ? 'cbi-tab' : 'cbi-tab-disabled',
      }),
    );
    const settingsSec = E(
      'div',
      { id: 'cbi-tachyon-settings', class: 'cbi-section cbi-tab-disabled' },
      [
        E(
          'ul',
          { class: 'cbi-tabmenu' },
          settingsSubKeys.map((k, idx) =>
            E(
              'li',
              {
                class: idx === 0 ? 'cbi-tab' : 'cbi-tab-disabled',
                'data-tab': k,
              },
              [E('a', { href: '#' }, k)],
            ),
          ),
        ),
        E('div', { class: 'cbi-section-node' }, settingsPanes),
      ],
    );

    const makeTopTabLi = (tabId: string, secEl: any, active = false): any =>
      E(
        'li',
        {
          class: active ? 'cbi-tab' : 'cbi-tab-disabled',
          'data-tab': tabId,
        },
        [
          E(
            'a',
            {
              href: '#',
              // Simulate real OpenWrt LuCI ui.tabs.switchTab: synchronously
              // dispatches non-bubbling cbi-tab-active on the target section.
              click: () => {
                secEl.dispatchEvent({
                  type: 'cbi-tab-active',
                  detail: { tab: tabId },
                  bubbles: false,
                });
              },
            },
            tabId,
          ),
        ],
      );

    const mapEl = E('div', { id: 'cbi-tachyon' }, [
      E('ul', { class: 'cbi-tabmenu' }, [
        makeTopTabLi('dashboard', dashboardSec, true),
        makeTopTabLi('section', sectionSec, false),
        makeTopTabLi('updates', updatesSec, false),
        makeTopTabLi('settings', settingsSec, false),
      ]),
      dashboardSec,
      sectionSec,
      updatesSec,
      settingsSec,
    ]);
    (globalThis as any).document.body.appendChild(mapEl);

    let activeSubTab = 'sections';
    mountTachyonAppShell({
      mapEl,
      defaultNavKey: 'dashboard',
      onSelectSectionSubTab: (sub) => {
        activeSubTab = sub;
      },
      getActiveSectionSubTab: () => activeSubTab,
    });

    const topbarEl = mapEl.querySelector('.tachyon-topbar');
    const routingParent = mapEl
      .querySelectorAll('.tachyon-sidebar__nav-parent')
      .find((b: any) => b.getAttribute('data-parent-menu') === 'routing');
    routingParent.click();

    // Switch through every routing submenu item sequentially: each click MUST
    // immediately highlight the newly clicked item (not the previous one).
    const routingOrder = [
      'section:outbounds',
      'section:conditions',
      'section:balancers',
      'section:sections',
    ];
    for (const targetKey of routingOrder) {
      const subLi = topbarEl
        .querySelectorAll('.tachyon-global-subtabs > li')
        .find((li: any) => li.getAttribute('data-nav-key') === targetKey);
      expect(subLi).toBeTruthy();
      subLi.querySelector('a').click();

      const activeSubLi = topbarEl
        .querySelectorAll('.tachyon-global-subtabs > li')
        .find((li: any) => li.classList.contains('cbi-tab'));
      expect(activeSubLi?.getAttribute('data-nav-key')).toBe(targetKey);
      expect(activeSubTab).toBe(targetKey.replace('section:', ''));
      expect(sectionSec.getAttribute('data-tab-active')).toBe('true');
    }

    // Switch to Settings parent and step through every settings:* sub-tab + updates
    const systemParent = mapEl
      .querySelectorAll('.tachyon-sidebar__nav-parent')
      .find((b: any) => b.getAttribute('data-parent-menu') === 'system');
    systemParent.click();

    const systemSequence = [
      'settings:dns',
      'settings:network',
      'settings:services',
      'updates',
      'settings:ai',
      'settings:advanced',
      'settings:navigation',
    ];
    for (const targetKey of systemSequence) {
      const subLi = topbarEl
        .querySelectorAll('.tachyon-global-subtabs > li')
        .find((li: any) => li.getAttribute('data-nav-key') === targetKey);
      expect(subLi).toBeTruthy();
      subLi.querySelector('a').click();

      const activeSubLi = topbarEl
        .querySelectorAll('.tachyon-global-subtabs > li')
        .find((li: any) => li.classList.contains('cbi-tab'));
      expect(activeSubLi?.getAttribute('data-nav-key')).toBe(targetKey);

      if (targetKey.startsWith('settings:')) {
        const expectedPane = targetKey.replace('settings:', '');
        expect(settingsSec.getAttribute('data-tab-active')).toBe('true');
        const activePane = settingsPanes.find(
          (p) => p.getAttribute('data-tab-active') === 'true',
        );
        expect(activePane?.getAttribute('data-tab')).toBe(expectedPane);
      } else {
        expect(updatesSec.getAttribute('data-tab-active')).toBe('true');
        expect(settingsSec.getAttribute('data-tab-active')).toBe('false');
      }
    }
  });

  it('preserves settings:updates sub-tab after renderContents when LuCI initTabGroup fires deferred rAF cbi-tab-active on navigation', async () => {
    setUiMode('advanced');
    setSidebarPos('top');
    const E = (globalThis as any).E;

    const rafQueue: Array<() => void> = [];
    const origRaf = (globalThis as any).window.requestAnimationFrame;
    (globalThis as any).window.requestAnimationFrame = (cb: () => void) => {
      rafQueue.push(cb);
      return rafQueue.length;
    };

    try {
      const buildDom = () => {
        const dashboardSec = E('div', {
          id: 'cbi-tachyon-dashboard',
          class: 'cbi-section cbi-tab',
        });
        const settingsSubKeys = [
          'navigation',
          'dns',
          'network',
          'services',
          'updates',
          'ai',
          'advanced',
        ];
        const panes = settingsSubKeys.map((k, idx) =>
          E('div', {
            'data-tab': k,
            class: idx === 0 ? 'cbi-tab' : 'cbi-tab-disabled',
            'data-tab-active': idx === 0 ? 'true' : 'false',
          }),
        );
        const secSettings = E(
          'div',
          { id: 'cbi-tachyon-settings', class: 'cbi-section cbi-tab-disabled' },
          [
            E(
              'ul',
              { class: 'cbi-tabmenu' },
              settingsSubKeys.map((k, idx) =>
                E(
                  'li',
                  {
                    class: idx === 0 ? 'cbi-tab' : 'cbi-tab-disabled',
                    'data-tab': k,
                  },
                  [E('a', { href: '#' }, k)],
                ),
              ),
            ),
            E('div', { class: 'cbi-section-node' }, panes),
          ],
        );
        const makeTopTabLi = (tabId: string, active = false): any =>
          E(
            'li',
            {
              class: active ? 'cbi-tab' : 'cbi-tab-disabled',
              'data-tab': tabId,
            },
            [E('a', { href: '#' }, tabId)],
          );
        const el = E('div', { id: 'cbi-tachyon' }, [
          E('ul', { class: 'cbi-tabmenu' }, [
            makeTopTabLi('dashboard', true),
            makeTopTabLi('settings', false),
          ]),
          dashboardSec,
          secSettings,
        ]);
        return { mapEl: el, settingsSec: secSettings, settingsPanes: panes };
      };

      const first = buildDom();
      (globalThis as any).document.body.appendChild(first.mapEl);
      mountTachyonAppShell({ mapEl: first.mapEl, defaultNavKey: 'dashboard' });

      // Navigate to Settings -> Lists Updates (`settings:updates`) and flush mount rAFs
      const topbarEl = first.mapEl.querySelector('.tachyon-topbar');
      const systemParent = first.mapEl
        .querySelectorAll('.tachyon-sidebar__nav-parent')
        .find((b: any) => b.getAttribute('data-parent-menu') === 'system');
      systemParent.click();
      const updatesSubLi = topbarEl
        .querySelectorAll('.tachyon-global-subtabs > li')
        .find(
          (li: any) => li.getAttribute('data-nav-key') === 'settings:updates',
        );
      updatesSubLi.querySelector('a').click();
      while (rafQueue.length > 0) rafQueue.shift()!();
      expect(getSavedActiveNavKey()).toBe('settings:updates');

      // Simulate map.renderContents() after Save & Apply:
      // LuCI re-creates DOM with navigation selected by default and queues an async rAF
      // dispatching `cbi-tab-active` on `navigation` pane BEFORE mountTachyonAppShell runs.
      const rerendered = buildDom();
      first.mapEl.replaceChildren(
        ...Array.from(rerendered.mapEl.children || []),
      );
      (globalThis as any).window.requestAnimationFrame(() => {
        rerendered.settingsPanes[0].dispatchEvent({
          type: 'cbi-tab-active',
          detail: { tab: 'navigation' },
          bubbles: false,
        });
      });

      setShellRestoringTab(true);
      mountTachyonAppShell({
        mapEl: first.mapEl,
        defaultNavKey: 'dashboard',
      });
      while (rafQueue.length > 0) rafQueue.shift()!();

      expect(getSavedActiveNavKey()).toBe('settings:updates');
      const activePane = rerendered.settingsPanes.find(
        (p: any) => p.getAttribute('data-tab-active') === 'true',
      );
      expect(activePane?.getAttribute('data-tab')).toBe('updates');
    } finally {
      (globalThis as any).window.requestAnimationFrame = origRaf;
    }
  });
});
