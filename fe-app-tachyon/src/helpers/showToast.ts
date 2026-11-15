export function showToast(
  message: string,
  type: 'success' | 'error' | 'warning' | 'info' = 'success',
  duration: number = 3200,
) {
  let container = document.querySelector(
    '.toast-container',
  ) as HTMLElement | null;
  if (!container) {
    container = document.createElement('div');
    container.className = 'toast-container';
    document.body.appendChild(container);
  } else if (
    container.parentElement !== document.body ||
    container.nextElementSibling
  ) {
    // Keep toast container as the very last child of body so it sits above all modal overlays
    document.body.appendChild(container);
  }

  const toast = document.createElement('div');
  toast.className = `toast toast-${type}`;

  const dot = document.createElement('span');
  dot.className = `toast-dot toast-dot-${type}`;

  const textSpan = document.createElement('span');
  textSpan.className = 'toast-text';
  textSpan.textContent = message;

  toast.appendChild(dot);
  toast.appendChild(textSpan);

  let dismissed = false;
  const dismiss = () => {
    if (dismissed) return;
    dismissed = true;
    toast.classList.remove('visible');
    setTimeout(() => toast.remove(), 220);
  };

  toast.addEventListener('click', dismiss);

  container.appendChild(toast);
  setTimeout(() => toast.classList.add('visible'), 16);

  if (duration > 0) {
    setTimeout(dismiss, duration);
  }
}

let interceptorInstalled = false;

/**
 * Intercepts all LuCI notification calls (`ui.addNotification`, `ui.addTimeLimitedNotification`)
 * and suppresses LuCI's top-banner DOM nodes so every notification flows through Tachyon's native toast system.
 */
export function installLuciNotificationInterceptor(): void {
  if (interceptorInstalled || typeof window === 'undefined') return;
  interceptorInstalled = true;

  const extractText = (content: unknown): string => {
    if (!content) return '';
    if (typeof content === 'string') return content.trim();
    if (Array.isArray(content)) {
      return content.map(extractText).filter(Boolean).join(' ').trim();
    }
    if (typeof content === 'object' && 'textContent' in (content as Node)) {
      return String((content as Node).textContent || '').trim();
    }
    return String(content).trim();
  };

  const mapType = (
    classes?: string,
  ): 'success' | 'error' | 'warning' | 'info' => {
    const c = String(classes || '').toLowerCase();
    if (c.includes('error') || c.includes('danger') || c.includes('alert')) {
      return 'error';
    }
    if (c.includes('warn')) return 'warning';
    if (c.includes('info') || c.includes('notice')) return 'info';
    return 'success';
  };

  const hookUi = (uiObj: Record<string, unknown> | undefined) => {
    if (!uiObj || typeof uiObj !== 'object') return;
    uiObj.addNotification = (
      title: unknown,
      children?: unknown,
      classes?: string,
    ) => {
      const t = extractText(title);
      const body = extractText(children);
      const msg = [t, body].filter(Boolean).join(': ') || _('Notification');
      showToast(msg, mapType(classes), 3600);
      return [];
    };
    uiObj.addTimeLimitedNotification = (
      title: unknown,
      children?: unknown,
      timeout?: number,
      classes?: string,
    ) => {
      const t = extractText(title);
      const body = extractText(children);
      const msg = [t, body].filter(Boolean).join(': ') || _('Notification');
      const dur =
        typeof timeout === 'number' && timeout > 0
          ? Math.min(Math.max(timeout, 1800), 6000)
          : 3200;
      showToast(msg, mapType(classes), dur);
      return [];
    };
  };

  const win = window as unknown as Record<string, unknown>;
  if (win.ui && typeof win.ui === 'object') {
    hookUi(win.ui as Record<string, unknown>);
  }
  if (win.L && typeof win.L === 'object') {
    const lObj = win.L as Record<string, unknown>;
    if (lObj.ui && typeof lObj.ui === 'object') {
      hookUi(lObj.ui as Record<string, unknown>);
    }
  }
}
