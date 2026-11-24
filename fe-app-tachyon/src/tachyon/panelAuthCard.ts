/* eslint-disable @typescript-eslint/no-explicit-any */
import { showToast } from '../helpers/showToast';
import { tr } from './helpers/i18n';

export type PanelAuthMode = 'luci' | 'custom';

export interface PanelAuthStatus {
  supported: boolean;
  authenticated: boolean;
  auth_enabled: boolean;
  auth_mode: PanelAuthMode;
  username: string | null;
}

export const PANEL_AUTH_CHANGED_EVENT = 'tachyon:auth-changed';

let interceptorInstalled = false;
let reloadScheduled = false;

export function _resetPanelAuthStateForTests(): void {
  interceptorInstalled = false;
  reloadScheduled = false;
}

function getRequestUrl(input: RequestInfo | URL): string {
  if (typeof input === 'string') return input;
  if (input instanceof URL) return input.pathname + input.search;
  if (input && typeof (input as Request).url === 'string') {
    return (input as Request).url;
  }
  return '';
}

function shouldReloadOn401(rawUrl: string): boolean {
  if (!rawUrl) return false;
  let path = rawUrl;
  try {
    if (
      rawUrl.startsWith('http://') ||
      rawUrl.startsWith('https://') ||
      rawUrl.startsWith('//')
    ) {
      const origin =
        typeof window !== 'undefined' && window.location?.origin
          ? window.location.origin
          : 'http://localhost';
      const parsed = new URL(rawUrl, origin);
      if (
        typeof window !== 'undefined' &&
        window.location?.origin &&
        parsed.origin !== window.location.origin
      ) {
        return false;
      }
      path = parsed.pathname;
    }
  } catch {
    return false;
  }

  if (
    path === '/api/login' ||
    path === '/login' ||
    path === '/api/logout' ||
    path === '/logout' ||
    path === '/api/auth/status'
  ) {
    return false;
  }

  return (
    path.startsWith('/api/') ||
    path === '/ubus' ||
    path.startsWith('/ubus/') ||
    path.startsWith('/cgi-bin/luci/admin/')
  );
}

export function installPanelAuth401Interceptor(): void {
  if (
    interceptorInstalled ||
    typeof window === 'undefined' ||
    typeof window.fetch !== 'function'
  ) {
    return;
  }
  interceptorInstalled = true;
  const origFetch = window.fetch.bind(window);

  window.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
    const response = await origFetch(input, init);
    if (
      response &&
      response.status === 401 &&
      !reloadScheduled &&
      shouldReloadOn401(getRequestUrl(input))
    ) {
      reloadScheduled = true;
      setTimeout(() => {
        try {
          window.location?.reload?.();
        } catch {
          // ignore in headless test runners
        }
      }, 60);
    }
    return response;
  };
}

export async function fetchPanelAuthStatus(): Promise<PanelAuthStatus> {
  if (typeof fetch !== 'function') {
    return {
      supported: false,
      authenticated: true,
      auth_enabled: false,
      auth_mode: 'luci',
      username: null,
    };
  }
  try {
    const res = await fetch('/api/auth/status', {
      method: 'GET',
      credentials: 'same-origin',
      headers: { Accept: 'application/json' },
    });
    if (!res.ok) {
      return {
        supported: false,
        authenticated: true,
        auth_enabled: false,
        auth_mode: 'luci',
        username: null,
      };
    }
    const data = (await res.json()) as Record<string, any>;
    const mode: PanelAuthMode =
      String(data?.auth_mode || '').toLowerCase() === 'custom'
        ? 'custom'
        : 'luci';
    return {
      supported: true,
      authenticated: Boolean(data?.authenticated),
      auth_enabled: data?.auth_enabled !== false,
      auth_mode: mode,
      username: typeof data?.username === 'string' ? data.username : null,
    };
  } catch {
    return {
      supported: false,
      authenticated: true,
      auth_enabled: false,
      auth_mode: 'luci',
      username: null,
    };
  }
}

export async function logoutPanelSession(): Promise<boolean> {
  try {
    if (typeof fetch === 'function') {
      await fetch('/api/logout', {
        method: 'POST',
        credentials: 'same-origin',
        headers: { 'Content-Type': 'application/json' },
        body: '{}',
      });
    }
  } catch {
    // ignore network errors during logout
  }
  if (typeof window !== 'undefined') {
    try {
      window.dispatchEvent(
        new CustomEvent(PANEL_AUTH_CHANGED_EVENT, {
          detail: { authenticated: false },
        }),
      );
    } catch {
      // ignore
    }
    try {
      window.location?.reload?.();
    } catch {
      // ignore
    }
  }
  return true;
}

function createEl(
  tag: string,
  attrs: Record<string, any> = {},
  children: Array<HTMLElement | Text | string | null | undefined> = [],
): HTMLElement {
  const node = document.createElement(tag) as any;
  for (const [k, v] of Object.entries(attrs)) {
    if (v == null || v === false) continue;
    if (k === 'class') {
      node.className = String(v);
    } else if (k === 'style') {
      node.setAttribute?.('style', String(v));
      if (typeof node.style === 'object') {
        node.style.cssText = String(v);
      }
    } else if (k === 'value') {
      node.value = String(v);
      node.setAttribute?.('value', String(v));
    } else if (k === 'checked') {
      node.checked = Boolean(v);
    } else if (k === 'disabled') {
      node.disabled = Boolean(v);
    } else if (
      ['click', 'change', 'input', 'submit'].includes(k) &&
      typeof v === 'function'
    ) {
      node.addEventListener?.(k, v);
    } else {
      node.setAttribute?.(k, v === true ? '' : String(v));
    }
  }
  for (const child of children) {
    if (child == null) continue;
    if (typeof child === 'string') {
      node.appendChild(document.createTextNode(child));
    } else {
      node.appendChild(child);
    }
  }
  return node;
}

function createPasswordField(
  id: string,
  placeholder: string,
  autocomplete: string,
): { wrap: HTMLElement; input: HTMLInputElement } {
  const input = createEl('input', {
    id,
    type: 'password',
    class: 'tachyon-auth-input cbi-input-text',
    placeholder,
    autocomplete,
  }) as HTMLInputElement;

  const toggleBtn = createEl(
    'button',
    {
      type: 'button',
      class: 'btn tachyon-auth-eye-btn',
      title: tr('Показать или скрыть пароль', 'Show or hide password'),
      click: (ev: MouseEvent) => {
        ev.preventDefault();
        const isPw = input.type !== 'text';
        input.type = isPw ? 'text' : 'password';
        toggleBtn.textContent = isPw
          ? tr('Скрыть', 'Hide')
          : tr('Показать', 'Show');
      },
    },
    [tr('Показать', 'Show')],
  );

  const wrap = createEl('div', { class: 'tachyon-auth-pw-wrap' }, [
    input,
    toggleBtn,
  ]);
  return { wrap, input };
}

export function renderPanelAuthSettingsCard(): HTMLElement {
  const root = createEl('div', { class: 'tachyon-auth-card' });

  const state: {
    loaded: boolean;
    supported: boolean;
    serverEnabled: boolean;
    serverMode: PanelAuthMode;
    serverUsername: string;
    draftEnabled: boolean;
    draftMode: PanelAuthMode;
    draftUsername: string;
    saving: boolean;
    errorText: string;
    statusMessage: string;
  } = {
    loaded: false,
    supported: true,
    serverEnabled: true,
    serverMode: 'luci',
    serverUsername: 'root',
    draftEnabled: true,
    draftMode: 'luci',
    draftUsername: 'root',
    saving: false,
    errorText: '',
    statusMessage: '',
  };

  let curPwInput: HTMLInputElement | null = null;
  let newPwInput: HTMLInputElement | null = null;
  let confirmPwInput: HTMLInputElement | null = null;
  let usernameInput: HTMLInputElement | null = null;

  const render = () => {
    const children: HTMLElement[] = [];

    const badgeText = !state.loaded
      ? tr('Загрузка...', 'Loading...')
      : !state.supported
        ? tr('Встроен в LuCI', 'Managed by LuCI')
        : state.serverEnabled
          ? state.serverMode === 'custom'
            ? `${tr('Отдельный пароль', 'Separate password')} (${state.serverUsername || 'admin'})`
            : `${tr('Пароль роутера (LuCI)', 'Router (LuCI) credentials')} (${state.serverUsername || 'root'})`
          : tr('Защита отключена', 'Protection disabled');

    const badgeClass = !state.loaded
      ? 'tachyon-auth-badge'
      : !state.supported
        ? 'tachyon-auth-badge'
        : state.serverEnabled
          ? 'tachyon-auth-badge is-ok'
          : 'tachyon-auth-badge is-warn';

    children.push(
      createEl('div', { class: 'tachyon-auth-header' }, [
        createEl('div', { class: 'tachyon-auth-title-group' }, [
          createEl('div', { class: 'tachyon-auth-title' }, [
            tr('Авторизация и пароль панели', 'Panel Login & Password'),
          ]),
          createEl('div', { class: 'tachyon-auth-sub' }, [
            tr(
              'По умолчанию используются логин и пароль роутера (LuCI). Вы можете задать отдельные учётные данные только для панели Tachyon.',
              'Router (LuCI) username and password are used by default. You can switch to separate credentials for the Tachyon panel only.',
            ),
          ]),
        ]),
        createEl('span', { class: badgeClass }, [badgeText]),
      ]),
    );

    if (!state.loaded) {
      children.push(
        createEl('div', { class: 'tachyon-auth-note' }, [
          tr(
            'Проверка параметров авторизации...',
            'Checking authentication settings...',
          ),
        ]),
      );
      root.replaceChildren(...children);
      return;
    }

    if (!state.supported) {
      children.push(
        createEl('div', { class: 'tachyon-auth-note' }, [
          tr(
            'Панель открыта через внешний веб-сервер LuCI (uhttpd) и использует его встроенную сессию. Управление отдельным паролем доступно при входе напрямую во встроенный веб-сервер Tachyon.',
            'This session is served through LuCI (uhttpd) and uses its built-in authentication. Separate panel credentials are available when opening the standalone Tachyon web server.',
          ),
        ]),
      );
      root.replaceChildren(...children);
      return;
    }

    const enabledToggle = createEl('input', {
      type: 'checkbox',
      id: 'tachyon-auth-enabled-chk',
      checked: state.draftEnabled,
      change: () => {
        state.draftEnabled = Boolean(enabledToggle.checked);
        state.errorText = '';
        render();
      },
    }) as HTMLInputElement;

    children.push(
      createEl('label', { class: 'tachyon-auth-switch-row' }, [
        enabledToggle,
        createEl('span', { class: 'tachyon-auth-switch-text' }, [
          tr(
            'Требовать вход по логину и паролю',
            'Require sign-in with username and password',
          ),
        ]),
      ]),
    );

    if (!state.draftEnabled) {
      children.push(
        createEl('div', { class: 'tachyon-auth-warn' }, [
          tr(
            'При отключённой защите любой клиент в локальной сети сможет открывать панель без ввода пароля.',
            'When disabled, any client on the local network can open the panel without entering a password.',
          ),
        ]),
      );
    }

    if (state.draftEnabled) {
      const modeSwitch = createEl('div', { class: 'tachyon-auth-mode-tabs' }, [
        createEl(
          'button',
          {
            type: 'button',
            class: `tachyon-auth-mode-btn${state.draftMode === 'luci' ? ' is-active' : ''}`,
            'data-auth-mode': 'luci',
            click: (ev: MouseEvent) => {
              ev.preventDefault();
              state.draftMode = 'luci';
              state.errorText = '';
              render();
            },
          },
          [tr('Как в LuCI (по умолчанию)', 'Same as LuCI (default)')],
        ),
        createEl(
          'button',
          {
            type: 'button',
            class: `tachyon-auth-mode-btn${state.draftMode === 'custom' ? ' is-active' : ''}`,
            'data-auth-mode': 'custom',
            click: (ev: MouseEvent) => {
              ev.preventDefault();
              state.draftMode = 'custom';
              if (!state.draftUsername.trim()) {
                state.draftUsername = state.serverUsername || 'admin';
              }
              state.errorText = '';
              render();
            },
          },
          [tr('Отдельный логин и пароль', 'Separate username & password')],
        ),
      ]);
      children.push(modeSwitch);
    }

    const fieldsGrid = createEl('div', { class: 'tachyon-auth-fields' });

    if (state.draftEnabled && state.draftMode === 'luci') {
      fieldsGrid.appendChild(
        createEl('div', { class: 'tachyon-auth-note' }, [
          tr(
            'Используются системные логин и пароль роутера (проверяются через OpenWrt ubus session). Смена пароля роутера в «Система → Администрирование» автоматически действует и здесь.',
            'Uses router system credentials (verified via OpenWrt ubus session). Changing the router password in System -> Administration applies here automatically.',
          ),
        ]),
      );
    }

    const needsCustomCreds = state.draftEnabled && state.draftMode === 'custom';
    const switchingToCustom = needsCustomCreds && state.serverMode !== 'custom';

    if (needsCustomCreds) {
      usernameInput = createEl('input', {
        id: 'tachyon-auth-username',
        type: 'text',
        class: 'tachyon-auth-input cbi-input-text',
        value: state.draftUsername,
        placeholder: 'admin',
        autocomplete: 'username',
        input: () => {
          state.draftUsername = usernameInput?.value || '';
        },
      }) as HTMLInputElement;

      const newPwField = createPasswordField(
        'tachyon-auth-new-password',
        switchingToCustom
          ? tr('Минимум 4 символа', 'At least 4 characters')
          : tr(
              'Оставьте пустым, чтобы не менять',
              'Leave blank to keep current',
            ),
        'new-password',
      );
      newPwInput = newPwField.input;

      const confirmPwField = createPasswordField(
        'tachyon-auth-confirm-password',
        tr('Повторите новый пароль', 'Repeat new password'),
        'new-password',
      );
      confirmPwInput = confirmPwField.input;

      fieldsGrid.appendChild(
        createEl('div', { class: 'tachyon-auth-field' }, [
          createEl(
            'label',
            { class: 'tachyon-auth-label', for: 'tachyon-auth-username' },
            [tr('Логин панели', 'Panel username')],
          ),
          usernameInput,
        ]),
      );
      fieldsGrid.appendChild(
        createEl('div', { class: 'tachyon-auth-field' }, [
          createEl(
            'label',
            {
              class: 'tachyon-auth-label',
              for: 'tachyon-auth-new-password',
            },
            [tr('Новый пароль панели', 'New panel password')],
          ),
          newPwField.wrap,
        ]),
      );
      fieldsGrid.appendChild(
        createEl('div', { class: 'tachyon-auth-field' }, [
          createEl(
            'label',
            {
              class: 'tachyon-auth-label',
              for: 'tachyon-auth-confirm-password',
            },
            [tr('Подтверждение пароля', 'Confirm password')],
          ),
          confirmPwField.wrap,
        ]),
      );
    } else {
      usernameInput = null;
      newPwInput = null;
      confirmPwInput = null;
    }

    if (state.serverEnabled) {
      const curPwField = createPasswordField(
        'tachyon-auth-current-password',
        state.serverMode === 'luci'
          ? tr(
              'Текущий пароль роутера (LuCI)',
              'Current router (LuCI) password',
            )
          : tr('Текущий пароль панели', 'Current panel password'),
        'current-password',
      );
      curPwInput = curPwField.input;
      fieldsGrid.appendChild(
        createEl('div', { class: 'tachyon-auth-field' }, [
          createEl(
            'label',
            {
              class: 'tachyon-auth-label',
              for: 'tachyon-auth-current-password',
            },
            [
              tr(
                'Текущий пароль (для подтверждения изменений)',
                'Current password (to confirm changes)',
              ),
            ],
          ),
          curPwField.wrap,
        ]),
      );
    } else {
      curPwInput = null;
    }

    if (fieldsGrid.children.length > 0) {
      children.push(fieldsGrid);
    }

    if (state.errorText) {
      children.push(
        createEl('div', { class: 'tachyon-auth-error' }, [state.errorText]),
      );
    } else if (state.statusMessage) {
      children.push(
        createEl('div', { class: 'tachyon-auth-success' }, [
          state.statusMessage,
        ]),
      );
    }

    const saveBtn = createEl(
      'button',
      {
        type: 'button',
        class: 'btn cbi-button cbi-button-apply tachyon-auth-save-btn',
        disabled: state.saving,
        click: async (ev: MouseEvent) => {
          ev.preventDefault();
          await handleSave();
        },
      },
      [
        state.saving
          ? tr('Сохранение...', 'Saving...')
          : tr('Сохранить настройки входа', 'Save login settings'),
      ],
    );

    const actionsRow = createEl('div', { class: 'tachyon-auth-actions' }, [
      saveBtn,
      ...(state.serverEnabled
        ? [
            createEl(
              'button',
              {
                type: 'button',
                class: 'btn cbi-button tachyon-auth-logout-btn',
                click: (ev: MouseEvent) => {
                  ev.preventDefault();
                  void logoutPanelSession();
                },
              },
              [tr('Выйти из панели', 'Sign out')],
            ),
          ]
        : []),
    ]);
    children.push(actionsRow);

    root.replaceChildren(...children);
  };

  async function handleSave(): Promise<void> {
    state.errorText = '';
    state.statusMessage = '';

    const curPw = curPwInput?.value || '';
    const nextUser = (usernameInput?.value || state.draftUsername || '').trim();
    const newPw = newPwInput?.value || '';
    const confirmPw = confirmPwInput?.value || '';

    const disablesAuth = state.serverEnabled && !state.draftEnabled;
    const switchesMode =
      state.draftEnabled && state.draftMode !== state.serverMode;
    const changesCreds =
      state.draftEnabled &&
      state.draftMode === 'custom' &&
      (nextUser !== state.serverUsername || Boolean(newPw));

    if (
      !disablesAuth &&
      !switchesMode &&
      !changesCreds &&
      state.draftEnabled === state.serverEnabled
    ) {
      state.statusMessage = tr(
        'Изменений в параметрах входа нет.',
        'No authentication changes to apply.',
      );
      render();
      return;
    }

    if (state.draftEnabled && state.draftMode === 'custom') {
      if (!nextUser) {
        state.errorText = tr(
          'Укажите логин для отдельного входа в панель.',
          'Enter a username for separate panel login.',
        );
        render();
        return;
      }
      if (state.serverMode !== 'custom' && !newPw) {
        state.errorText = tr(
          'При переходе на отдельный вход необходимо задать пароль.',
          'Set a password when switching to separate panel login.',
        );
        render();
        return;
      }
      if (newPw) {
        if (newPw.length < 4) {
          state.errorText = tr(
            'Пароль должен содержать минимум 4 символа.',
            'Password must be at least 4 characters.',
          );
          render();
          return;
        }
        if (newPw !== confirmPw) {
          state.errorText = tr(
            'Пароль и подтверждение не совпадают.',
            'Password and confirmation do not match.',
          );
          render();
          return;
        }
      }
    }

    const needsCurrentPassword =
      state.serverEnabled && (disablesAuth || switchesMode || changesCreds);
    if (needsCurrentPassword && !curPw) {
      state.errorText = tr(
        'Введите текущий пароль для подтверждения изменения.',
        'Enter your current password to confirm the change.',
      );
      render();
      return;
    }

    const payload: Record<string, any> = {
      auth_enabled: state.draftEnabled,
      mode: state.draftMode,
    };
    if (state.draftEnabled && state.draftMode === 'custom') {
      if (nextUser) payload.username = nextUser;
      if (newPw) payload.new_password = newPw;
    }
    if (curPw) {
      payload.current_password = curPw;
    }

    state.saving = true;
    render();
    try {
      const res = await fetch('/api/auth/credentials', {
        method: 'POST',
        credentials: 'same-origin',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });
      const data = (await res.json().catch(() => ({}))) as Record<string, any>;
      if (!res.ok || data?.ok === false) {
        const msg = String(data?.error || '').trim();
        if (msg === 'Invalid current password') {
          state.errorText = tr(
            'Неверный текущий пароль.',
            'Current password is incorrect.',
          );
        } else if (msg === 'Current password is required') {
          state.errorText = tr(
            'Требуется текущий пароль.',
            'Current password is required.',
          );
        } else {
          state.errorText =
            msg ||
            tr(
              'Не удалось обновить настройки входа.',
              'Failed to update login settings.',
            );
        }
        return;
      }

      state.serverEnabled = data?.auth_enabled !== false;
      state.serverMode =
        String(data?.auth_mode || '').toLowerCase() === 'custom'
          ? 'custom'
          : 'luci';
      state.serverUsername =
        typeof data?.username === 'string' && data.username.trim()
          ? data.username.trim()
          : state.serverMode === 'luci'
            ? 'root'
            : nextUser || 'admin';
      state.draftEnabled = state.serverEnabled;
      state.draftMode = state.serverMode;
      state.draftUsername = state.serverUsername;
      state.statusMessage = tr(
        'Настройки авторизации сохранены.',
        'Authentication settings saved.',
      );
      try {
        showToast(state.statusMessage, 'success');
      } catch {
        // ignore in headless test runners
      }
      if (typeof window !== 'undefined') {
        try {
          window.dispatchEvent(
            new CustomEvent(PANEL_AUTH_CHANGED_EVENT, {
              detail: {
                auth_enabled: state.serverEnabled,
                auth_mode: state.serverMode,
                username: state.serverUsername,
              },
            }),
          );
        } catch {
          // ignore
        }
      }
    } catch {
      state.errorText = tr(
        'Ошибка соединения при сохранении настроек входа.',
        'Connection error while saving login settings.',
      );
    } finally {
      state.saving = false;
      render();
    }
  }

  render();

  void fetchPanelAuthStatus().then((st) => {
    state.loaded = true;
    state.supported = st.supported;
    state.serverEnabled = st.auth_enabled;
    state.serverMode = st.auth_mode;
    state.serverUsername =
      st.username || (st.auth_mode === 'custom' ? 'admin' : 'root');
    state.draftEnabled = state.serverEnabled;
    state.draftMode = state.serverMode;
    state.draftUsername = state.serverUsername;
    render();
  });

  return root;
}
