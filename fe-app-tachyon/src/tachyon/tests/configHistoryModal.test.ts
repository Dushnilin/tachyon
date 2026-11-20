/* eslint-disable @typescript-eslint/no-explicit-any */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

function createMockElement(tag: string): any {
  const attrs: Record<string, string> = {};
  const listeners: Record<string, Array<(ev: any) => void>> = {};
  const el: any = {
    tagName: tag.toUpperCase(),
    parentElement: null as any,
    children: [] as any[],
    style: {},
    className: '',
    disabled: false,
    _text: '',
    get textContent(): string {
      if (el._text) return el._text;
      return el.children.map((c: any) => c.textContent || '').join('');
    },
    set textContent(v: string) {
      el._text = String(v);
    },
    setAttribute(k: string, v: string) {
      attrs[k] = String(v);
      if (k === 'class') el.className = String(v);
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
        for (const fn of node._getListeners?.('click') || []) {
          fn(ev);
        }
      }
    },
    _getListeners(type: string) {
      return listeners[type] || [];
    },
    appendChild(child: any) {
      if (child != null && child !== '') {
        if (typeof child === 'object') {
          child.parentElement = el;
          el.children.push(child);
        } else {
          const tn = createMockElement('#text');
          tn.textContent = String(child);
          tn.parentElement = el;
          el.children.push(tn);
        }
      }
      return child;
    },
    replaceChildren(...nodes: any[]) {
      el._text = '';
      el.children = [];
      for (const n of nodes) {
        el.appendChild(n);
      }
    },
    remove() {
      if (el.parentElement) {
        el.parentElement.children = el.parentElement.children.filter(
          (c: any) => c !== el,
        );
      }
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
        const has = el.classList.contains(c);
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
      const selectors = sel.split(',').map((s) => s.trim());
      const matchSingle = (node: any, s: string): boolean => {
        if (!node || typeof node !== 'object') return false;
        if (s.startsWith('.')) {
          return (node.className || '').split(/\s+/).includes(s.slice(1));
        }
        if (s.startsWith('#')) {
          return node.getAttribute?.('id') === s.slice(1);
        }
        return (node.tagName || '').toLowerCase() === s.toLowerCase();
      };
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
  const body = createMockElement('body');
  (globalThis as any).document = {
    body,
    documentElement: { lang: 'ru' },
    createElement: (tag: string) => createMockElement(tag),
    querySelector: (s: string) => body.querySelector(s),
    querySelectorAll: (s: string) => body.querySelectorAll(s),
  };
  (globalThis as any).window = {
    location: { reload: vi.fn() },
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
      else el.appendChild(c);
    };
    append(children);
    return el;
  };
  (globalThis as any)._ = (s: string) => s;
});

import {
  collectUnsavedUciChanges,
  openConfigHistoryModal,
} from '../configHistoryModal';

const flushAsync = async () => {
  await Promise.resolve();
  await new Promise((resolve) => setTimeout(resolve, 0));
  await Promise.resolve();
};

describe('configHistoryModal', () => {
  const origFetch = (globalThis as any).fetch;

  beforeEach(() => {
    (globalThis as any).document.body = createMockElement('body');
    (globalThis as any).__tachyonMapInstance = null;
    (globalThis as any).L = undefined;
    (globalThis as any).uci = undefined;
    (globalThis as any).ui = undefined;
  });

  afterEach(() => {
    (globalThis as any).fetch = origFetch;
    vi.restoreAllMocks();
  });

  it('collects unsaved changes across form.Map, uci.state, and L.ui.changes while masking secrets', () => {
    (globalThis as any).__tachyonMapInstance = {
      children: [
        {
          section: 'settings',
          children: [
            {
              option: 'tun_mtu',
              title: 'MTU',
              cfgvalue: () => '1500',
              formvalue: () => '1420',
              write: () => {},
            },
            {
              option: 'fakeip_enabled',
              disabled: '0',
              cfgvalue: () => null,
              formvalue: () => '0',
              write: () => {},
            },
            {
              option: 'inactive_opt',
              cfgvalue: () => 'a',
              formvalue: () => 'b',
              isActive: () => false,
              write: () => {},
            },
            {
              option: 'modal_opt',
              modalonly: true,
              cfgvalue: () => 'a',
              formvalue: () => 'b',
              write: () => {},
            },
          ],
        },
        {
          section: 'telegram',
          children: [
            {
              option: 'bot_token',
              title: 'Токен бота',
              cfgvalue: () => '111:old-secret',
              formvalue: () => '222:new-secret',
              write: () => {},
            },
          ],
        },
      ],
    };

    (globalThis as any).uci = {
      state: {
        values: {
          tachyon: {
            src_1: { password: 'old-password', host: '1.1.1.1' },
          },
        },
        changes: {
          tachyon: {
            src_1: { password: 'new-password' },
          },
        },
        creates: {
          tachyon: { sec_added: 'section' },
        },
        deletes: {
          tachyon: { sec_removed: true },
        },
      },
      changes: () => ({
        tachyon: [
          ['set', 'src_1', 'uuid', '11111111-1111-1111-1111-111111111111'],
          ['set', 'src_1', 'password', 'duplicate-ignored'],
        ],
      }),
    };

    (globalThis as any).ui = {
      changes: {
        changes: {
          tachyon: [['set', 'settings', 'dns_type', 'doh']],
        },
      },
    };

    const items = collectUnsavedUciChanges();
    const serialized = JSON.stringify(items);

    expect(serialized).not.toContain('old-secret');
    expect(serialized).not.toContain('new-secret');
    expect(serialized).not.toContain('old-password');
    expect(serialized).not.toContain('new-password');
    expect(serialized).not.toContain('11111111-1111');

    expect(
      items.some(
        (i) =>
          i.section === 'settings' &&
          i.option === 'tun_mtu' &&
          i.before === '1500' &&
          i.after === '1420',
      ),
    ).toBe(true);
    expect(
      items.some(
        (i) =>
          i.section === 'telegram' &&
          i.option === 'bot_token' &&
          i.before === '***' &&
          i.after === '***',
      ),
    ).toBe(true);
    expect(
      items.some(
        (i) =>
          i.section === 'src_1' &&
          i.option === 'password' &&
          i.before === '***' &&
          i.after === '***',
      ),
    ).toBe(true);
    expect(
      items.some(
        (i) =>
          i.section === 'src_1' && i.option === 'uuid' && i.after === '***',
      ),
    ).toBe(true);
    expect(
      items.some((i) => i.section === 'sec_added' && i.action === 'add'),
    ).toBe(true);
    expect(
      items.some((i) => i.section === 'sec_removed' && i.action === 'remove'),
    ).toBe(true);
    expect(
      items.some(
        (i) =>
          i.section === 'settings' &&
          i.option === 'dns_type' &&
          i.after === 'doh',
      ),
    ).toBe(true);

    // No false positives for untouched Flag default, inactive, or modalonly fields
    expect(items.some((i) => i.option === 'fakeip_enabled')).toBe(false);
    expect(items.some((i) => i.option === 'inactive_opt')).toBe(false);
    expect(items.some((i) => i.option === 'modal_opt')).toBe(false);
  });

  it('renders statuses, auto-rollback banner, confirms LKG, and performs 2-step rollbacks', async () => {
    let modalContent: any = null;
    const hideModal = vi.fn();
    const showModal = vi.fn((_title: string, children: any[]) => {
      modalContent = children[0];
      (globalThis as any).document.body.appendChild(modalContent);
    });
    const uciUnload = vi.fn().mockResolvedValue(undefined);
    const onReloadMap = vi.fn().mockResolvedValue(undefined);
    const onChangesUpdated = vi.fn();

    (globalThis as any).ui = {
      showModal,
      hideModal,
      changes: {
        changes: { tachyon: [['set', 'settings', 'tun_mtu', '1380']] },
        setIndicator: vi.fn(),
      },
    };
    (globalThis as any).uci = {
      unload: uciUnload,
      state: { changes: { tachyon: { settings: { tun_mtu: '1380' } } } },
    };

    const historyPayload = {
      ok: true,
      lkg_available: true,
      lkg_observing: true,
      lkg_remaining_secs: 145,
      active_revision_id: 'rev-checking',
      auto_rollback_enabled: true,
      watchdog_enabled: true,
      last_auto_rollback_reason: 'Сбой DNS после изменения конфига',
      last_auto_rollback_ts: 1700000100,
      revisions: [
        {
          id: 'rev-checking',
          timestamp: 1700000200,
          source: 'save',
          status: 'checking',
          status_reason: '',
          added: 0,
          changed: 1,
          removed: 0,
          total_changes: 1,
          truncated: 0,
          changes: [
            {
              scope: 'settings',
              target: 'settings',
              field: 'tun_mtu',
              kind: 'changed',
              before: '1420',
              after: '1380',
            },
          ],
        },
        {
          id: 'rev-failed',
          timestamp: 1700000150,
          source: 'save',
          status: 'failed',
          status_reason: 'tachyon-core check failed',
          added: 0,
          changed: 1,
          removed: 0,
          total_changes: 1,
          truncated: 0,
          changes: [
            {
              scope: 'settings',
              target: 'settings',
              field: 'dns_type',
              kind: 'changed',
              before: 'udp',
              after: 'bad',
            },
          ],
        },
        {
          id: 'rev-working',
          timestamp: 1700000050,
          source: 'save',
          status: 'working',
          status_reason: 'Проверен и подтверждён (LKG)',
          added: 1,
          changed: 0,
          removed: 0,
          total_changes: 1,
          truncated: 0,
          changes: [
            {
              scope: 'section',
              target: 'Main',
              field: 'enabled',
              kind: 'changed',
              before: 'false',
              after: 'true',
            },
          ],
        },
      ],
    };

    const fetchMock = vi.fn(async (url: string, init?: any) => {
      if (url === '/api/config/history') {
        return {
          ok: true,
          status: 200,
          json: async () => historyPayload,
        };
      }
      if (url === '/api/lkg/confirm') {
        return {
          ok: true,
          status: 200,
          json: async () => ({ ok: true }),
        };
      }
      if (url === '/api/config/history/rollback') {
        const parsed = JSON.parse(String(init?.body || '{}'));
        return {
          ok: true,
          status: 200,
          json: async () => ({
            ok: true,
            success: true,
            restored_id: parsed.id || parsed.target,
          }),
        };
      }
      return { ok: false, status: 404, json: async () => ({ ok: false }) };
    });
    (globalThis as any).fetch = fetchMock;

    openConfigHistoryModal({ onReloadMap, onChangesUpdated });
    await flushAsync();

    expect(showModal).toHaveBeenCalledTimes(1);
    expect(fetchMock).toHaveBeenCalledWith(
      '/api/config/history',
      expect.objectContaining({ method: 'GET' }),
    );
    expect(modalContent).toBeTruthy();

    // Auto-rollback alert banner and status tags
    const alertEl = modalContent.querySelector('.tachyon-history-alert');
    expect(alertEl).toBeTruthy();
    expect(alertEl.textContent).toContain('Сбой DNS после изменения конфига');

    const statusBadges = modalContent.querySelectorAll(
      '.tachyon-history-status',
    );
    expect(statusBadges.map((b: any) => b.textContent)).toEqual([
      'Проверяется (145с)',
      'Нерабочий',
      'Рабочий',
    ]);

    const reasonBanner = modalContent.querySelector(
      '.tachyon-history-rev__reason',
    );
    expect(reasonBanner?.textContent).toContain('tachyon-core check failed');

    // Confirm current config button calls POST /api/lkg/confirm
    const confirmWorkingBtn = modalContent
      .querySelectorAll('.tachyon-history-action-btn')
      .find((b: any) => b.textContent === 'Подтвердить рабочий');
    expect(confirmWorkingBtn).toBeTruthy();
    confirmWorkingBtn.click();
    await flushAsync();

    expect(fetchMock).toHaveBeenCalledWith(
      '/api/lkg/confirm',
      expect.objectContaining({ method: 'POST' }),
    );

    // Clicking "Вернуть рабочий" on the old working revision requires 2 clicks and sends mode: 'after'
    const restoreWorkingBtn = modalContent
      .querySelectorAll('.tachyon-history-action-btn')
      .find((b: any) => b.textContent === 'Вернуть рабочий');
    expect(restoreWorkingBtn).toBeTruthy();
    restoreWorkingBtn.click();
    expect(restoreWorkingBtn.textContent).toBe('Подтвердить?');
    restoreWorkingBtn.click();
    await flushAsync();

    expect(fetchMock).toHaveBeenCalledWith(
      '/api/config/history/rollback',
      expect.objectContaining({
        method: 'POST',
        body: JSON.stringify({ id: 'rev-working', mode: 'after' }),
      }),
    );
    expect(uciUnload).toHaveBeenCalledWith('tachyon');
    expect(hideModal).toHaveBeenCalled();
    expect(onChangesUpdated).toHaveBeenCalled();
    expect(onReloadMap).toHaveBeenCalled();

    // Verify LKG rollback 2-step click sends { target: 'lkg' }
    openConfigHistoryModal({ onReloadMap, onChangesUpdated });
    await flushAsync();
    const lkgBtn = modalContent
      .querySelectorAll('.tachyon-history-action-btn')
      .find((b: any) => b.textContent === 'Откатить к рабочему (LKG)');
    expect(lkgBtn).toBeTruthy();
    lkgBtn.click();
    expect(lkgBtn.textContent).toBe('Подтвердить откат?');
    lkgBtn.click();
    await flushAsync();

    expect(fetchMock).toHaveBeenCalledWith(
      '/api/config/history/rollback',
      expect.objectContaining({
        method: 'POST',
        body: JSON.stringify({ target: 'lkg' }),
      }),
    );

    // Verify Undo on newest revision sends mode: 'before'
    openConfigHistoryModal({ onReloadMap, onChangesUpdated });
    await flushAsync();
    const undoBtn = modalContent
      .querySelectorAll('.tachyon-history-action-btn')
      .find((b: any) => b.textContent === 'Отменить');
    expect(undoBtn).toBeTruthy();
    undoBtn.click();
    undoBtn.click();
    await flushAsync();

    expect(fetchMock).toHaveBeenCalledWith(
      '/api/config/history/rollback',
      expect.objectContaining({
        method: 'POST',
        body: JSON.stringify({ id: 'rev-checking', mode: 'before' }),
      }),
    );

    // Verify "Сбросить черновик" discards unsaved changes and reloads map
    (globalThis as any).uci.state = {
      changes: { tachyon: { settings: { tun_mtu: '1399' } } },
    };
    openConfigHistoryModal({ onReloadMap, onChangesUpdated });
    await flushAsync();
    const discardBtn = modalContent
      .querySelectorAll('.tachyon-history-action-btn')
      .find((b: any) => b.textContent === 'Сбросить черновик');
    expect(discardBtn).toBeTruthy();
    const callsBeforeDiscard = onReloadMap.mock.calls.length;
    discardBtn.click();
    await flushAsync();

    expect((globalThis as any).uci.state.changes.tachyon).toBeUndefined();
    expect(onReloadMap.mock.calls.length).toBeGreaterThan(callsBeforeDiscard);
  });
});
