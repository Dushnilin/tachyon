/* eslint-disable @typescript-eslint/no-explicit-any */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

function createMockElement(tag: string): any {
  const attrs: Record<string, string> = {};
  const listeners: Record<string, Array<(ev: any) => void>> = {};
  const el: any = {
    _listeners: listeners,
    tagName: tag.toUpperCase(),
    parentElement: null as any,
    children: [] as any[],
    style: { cssText: '' },
    className: '',
    classList: {
      add() {},
      remove() {},
      toggle() {},
      contains: () => false,
    },
    disabled: false,
    checked: false,
    type: tag === 'input' ? 'text' : '',
    _value: '',
    _text: '',
    get value() {
      return el._value;
    },
    set value(v: string) {
      el._value = String(v);
    },
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
      if (k === 'value') el._value = String(v);
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
      const ev = {
        target: el,
        currentTarget: el,
        preventDefault() {},
        stopPropagation() {},
      };
      for (const fn of listeners.click || []) fn(ev);
    },
    triggerChange(nextChecked?: boolean) {
      if (typeof nextChecked === 'boolean') el.checked = nextChecked;
      for (const fn of listeners.change || []) fn({ target: el });
    },
    dispatchEvent(ev: any) {
      let stopped = false;
      const evType = ev?.type || '';
      const wrapped: any = {
        type: evType,
        bubbles: ev?.bubbles !== false,
        target: el,
        currentTarget: el,
        preventDefault() {
          ev?.preventDefault?.();
        },
        stopPropagation() {
          stopped = true;
          ev?.stopPropagation?.();
        },
      };
      let cur: any = el;
      while (cur) {
        wrapped.currentTarget = cur;
        for (const fn of cur._listeners?.[evType] || []) {
          fn(wrapped);
        }
        if (stopped || !wrapped.bubbles) break;
        cur = cur.parentElement;
      }
      return true;
    },
    appendChild(child: any) {
      if (child != null) {
        child.parentElement = el;
        el.children.push(child);
      }
      return child;
    },
    replaceChildren(...nodes: any[]) {
      el._text = '';
      el.children = [];
      for (const n of nodes) el.appendChild(n);
    },
    querySelectorAll(sel: string) {
      const out: any[] = [];
      const visit = (node: any) => {
        for (const ch of node.children || []) {
          if (matchesSelector(ch, sel)) out.push(ch);
          visit(ch);
        }
      };
      visit(el);
      return out;
    },
    querySelector(sel: string) {
      return el.querySelectorAll(sel)[0] || null;
    },
  };
  return el;
}

function matchesSelector(el: any, sel: string): boolean {
  if (sel.startsWith('#')) return el.getAttribute?.('id') === sel.slice(1);
  if (sel.startsWith('.')) {
    return String(el.className || '')
      .split(/\s+/)
      .includes(sel.slice(1));
  }
  const attrMatch = sel.match(/^\[([^=]+)="([^"]+)"\]$/);
  if (attrMatch) {
    return el.getAttribute?.(attrMatch[1]) === attrMatch[2];
  }
  return el.tagName?.toLowerCase() === sel.toLowerCase();
}

function flushPromises(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

describe('panelAuthCard', () => {
  const dispatchedEvents: any[] = [];
  let reloadMock: ReturnType<typeof vi.fn>;
  let fetchMock: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    vi.resetModules();
    dispatchedEvents.length = 0;
    reloadMock = vi.fn();
    fetchMock = vi.fn();

    const doc: any = {
      documentElement: { lang: 'ru' },
      body: createMockElement('body'),
      createElement: (tag: string) => createMockElement(tag),
      createTextNode: (txt: string) => ({
        tagName: '#TEXT',
        textContent: String(txt),
        children: [],
      }),
      querySelector: () => null,
    };

    (globalThis as any).document = doc;
    (globalThis as any).fetch = fetchMock;
    (globalThis as any).CustomEvent = class {
      type: string;
      detail: any;
      constructor(type: string, init?: { detail?: any }) {
        this.type = type;
        this.detail = init?.detail;
      }
    };
    (globalThis as any).window = {
      fetch: fetchMock,
      location: { origin: 'http://192.168.1.1:1680', reload: reloadMock },
      dispatchEvent: (ev: any) => {
        dispatchedEvents.push(ev);
        return true;
      },
    };
  });

  afterEach(() => {
    vi.useRealTimers();
    delete (globalThis as any).document;
    delete (globalThis as any).window;
    delete (globalThis as any).fetch;
  });

  it('renders luci mode initially, switches to custom, validates, and posts credentials', async () => {
    fetchMock
      .mockResolvedValueOnce({
        ok: true,
        status: 200,
        json: async () => ({
          ok: true,
          authenticated: true,
          auth_enabled: true,
          auth_mode: 'luci',
          username: 'root',
        }),
      })
      .mockResolvedValueOnce({
        ok: true,
        status: 200,
        json: async () => ({
          ok: true,
          auth_enabled: true,
          auth_mode: 'custom',
          username: 'operator',
        }),
      });

    const { renderPanelAuthSettingsCard, PANEL_AUTH_CHANGED_EVENT } =
      await import('../panelAuthCard');
    const card: any = renderPanelAuthSettingsCard();
    await flushPromises();

    expect(card.textContent).toContain('Пароль роутера (LuCI)');

    const customBtn = card.querySelector('[data-auth-mode="custom"]');
    expect(customBtn).toBeTruthy();
    customBtn.click();

    const userInput = card.querySelector('#tachyon-auth-username');
    const newPwInput = card.querySelector('#tachyon-auth-new-password');
    const confirmPwInput = card.querySelector('#tachyon-auth-confirm-password');
    const curPwInput = card.querySelector('#tachyon-auth-current-password');

    userInput.value = 'operator';
    newPwInput.value = 'secret123';
    confirmPwInput.value = 'mismatch';
    curPwInput.value = 'luci-pass';

    card.querySelector('.tachyon-auth-save-btn').click();
    await flushPromises();
    expect(card.textContent).toContain('не совпадают');
    expect(fetchMock).toHaveBeenCalledTimes(1);

    // Fix confirmation and submit again
    card.querySelector('#tachyon-auth-username').value = 'operator';
    card.querySelector('#tachyon-auth-new-password').value = 'secret123';
    card.querySelector('#tachyon-auth-confirm-password').value = 'secret123';
    card.querySelector('#tachyon-auth-current-password').value = 'luci-pass';

    card.querySelector('.tachyon-auth-save-btn').click();
    await flushPromises();

    expect(fetchMock).toHaveBeenCalledTimes(2);
    const [url, reqInit] = fetchMock.mock.calls[1];
    expect(url).toBe('/api/auth/credentials');
    expect(reqInit.method).toBe('POST');
    expect(JSON.parse(reqInit.body)).toEqual({
      auth_enabled: true,
      mode: 'custom',
      username: 'operator',
      new_password: 'secret123',
      current_password: 'luci-pass',
    });
    expect(card.textContent).toContain('Отдельный пароль (operator)');
    expect(
      dispatchedEvents.some((e) => e.type === PANEL_AUTH_CHANGED_EVENT),
    ).toBe(true);
  });

  it('stops change and input events from bubbling into parent LuCI CBI form', async () => {
    fetchMock.mockResolvedValueOnce({
      ok: true,
      status: 200,
      json: async () => ({
        ok: true,
        authenticated: true,
        auth_enabled: true,
        auth_mode: 'luci',
        username: 'root',
      }),
    });

    const { renderPanelAuthSettingsCard } = await import('../panelAuthCard');
    const hostForm = document.createElement('div');
    const parentChanges = vi.fn();
    const parentInputs = vi.fn();
    hostForm.addEventListener('change', parentChanges);
    hostForm.addEventListener('input', parentInputs);

    const card: any = renderPanelAuthSettingsCard();
    hostForm.appendChild(card);
    await flushPromises();

    const chk = card.querySelector('#tachyon-auth-enabled-chk') as any;
    expect(chk).toBeTruthy();
    chk.checked = false;
    chk.dispatchEvent({ type: 'change', bubbles: true });
    chk.triggerChange(false);
    expect(parentChanges).not.toHaveBeenCalled();

    const pwInput = card.querySelector('#tachyon-auth-current-password') as any;
    expect(pwInput).toBeTruthy();
    pwInput.value = 'secret';
    pwInput.dispatchEvent({ type: 'input', bubbles: true });
    expect(parentInputs).not.toHaveBeenCalled();
    expect(card.textContent).toContain('Сохранить настройки входа');
    expect(card.textContent).toContain('общая кнопка сохранения');
  });

  it('reloads once on 401 from /api/ routes while ignoring /api/auth/status and /api/login', async () => {
    vi.useFakeTimers();
    const { installPanelAuth401Interceptor, _resetPanelAuthStateForTests } =
      await import('../panelAuthCard');
    _resetPanelAuthStateForTests();

    fetchMock
      .mockResolvedValueOnce({ status: 401 })
      .mockResolvedValueOnce({ status: 401 })
      .mockResolvedValueOnce({ status: 401 })
      .mockResolvedValueOnce({ status: 401 });

    installPanelAuth401Interceptor();

    await (globalThis as any).window.fetch('/api/auth/status');
    await (globalThis as any).window.fetch('/api/login');
    vi.advanceTimersByTime(100);
    expect(reloadMock).not.toHaveBeenCalled();

    await (globalThis as any).window.fetch('/api/runtime_state');
    await (globalThis as any).window.fetch('/ubus');
    vi.advanceTimersByTime(100);
    expect(reloadMock).toHaveBeenCalledTimes(1);
  });
});
