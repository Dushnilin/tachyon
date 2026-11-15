/* eslint-disable @typescript-eslint/no-explicit-any */
import { beforeEach, describe, expect, it, vi } from 'vitest';

const storage = new Map<string, string>();

function createMockElement(tag: string): any {
  const attrs: Record<string, string> = {};
  const dataset: Record<string, string> = {};
  const listeners: Record<string, Array<(ev: any) => void>> = {};
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
    addEventListener(type: string, cb: (ev: any) => void) {
      if (!listeners[type]) listeners[type] = [];
      listeners[type].push(cb);
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
        if (trimmed.startsWith(':scope > ')) {
          if (node.parentElement !== el) return false;
          return matchSingle(node, trimmed.slice(9));
        }
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
});
