/* eslint-disable @typescript-eslint/no-explicit-any */

export interface RouterUiPrefs {
  dashboard_layout?: any;
  studio_views?: Record<string, 'cards' | 'pipeline'>;
  ui_mode?: 'simple' | 'advanced';
  sidebar_pos?: 'left' | 'right';
  sidebar_collapsed?: boolean;
  topbar_collapsed?: boolean;
  [key: string]: any;
}

let pendingPatch: RouterUiPrefs = {};
let saveTimer: ReturnType<typeof setTimeout> | null = null;

export function getRouterUiPrefs(): RouterUiPrefs {
  const g = globalThis as any;
  if (g.__tachyonUiPrefs && typeof g.__tachyonUiPrefs === 'object') {
    return g.__tachyonUiPrefs;
  }
  try {
    const uciObj = g.uci;
    if (uciObj && typeof uciObj.get === 'function') {
      const raw = uciObj.get('tachyon', 'settings', 'ui_prefs_json');
      if (raw && typeof raw === 'string') {
        const parsed = JSON.parse(raw);
        if (parsed && typeof parsed === 'object') {
          g.__tachyonUiPrefs = parsed;
          return parsed;
        }
      }
    }
  } catch {
    // ignore parse errors
  }
  return {};
}

export function hydrateRouterUiPrefs(incoming: any): void {
  if (!incoming || typeof incoming !== 'object') return;
  const g = globalThis as any;
  const current =
    g.__tachyonUiPrefs && typeof g.__tachyonUiPrefs === 'object'
      ? g.__tachyonUiPrefs
      : {};
  g.__tachyonUiPrefs = {
    ...incoming,
    ...current,
    studio_views: {
      ...(incoming.studio_views || {}),
      ...(current.studio_views || {}),
    },
  };
}

export function setRouterUiPrefs(patch: RouterUiPrefs): void {
  if (!patch || typeof patch !== 'object') return;
  const g = globalThis as any;
  const hasRouterBackend =
    Boolean(g.__tachyonUiPrefs) ||
    typeof g.fs?.exec === 'function' ||
    typeof g.uci?.get === 'function';
  if (hasRouterBackend) {
    const current = getRouterUiPrefs();
    const next: RouterUiPrefs = {
      ...current,
      ...patch,
    };
    if (patch.studio_views && typeof patch.studio_views === 'object') {
      next.studio_views = {
        ...(current.studio_views || {}),
        ...patch.studio_views,
      };
    }
    g.__tachyonUiPrefs = next;
  }

  pendingPatch = {
    ...pendingPatch,
    ...patch,
  };
  if (patch.studio_views && typeof patch.studio_views === 'object') {
    pendingPatch.studio_views = {
      ...(pendingPatch.studio_views || {}),
      ...patch.studio_views,
    };
  }

  if (saveTimer) {
    clearTimeout(saveTimer);
  }
  saveTimer = setTimeout(() => {
    saveTimer = null;
    const toSend = pendingPatch;
    pendingPatch = {};
    try {
      const fsObj = g.fs;
      if (fsObj && typeof fsObj.exec === 'function') {
        void Promise.resolve(
          fsObj.exec('/usr/bin/tachyon', [
            'set_ui_prefs',
            JSON.stringify(toSend),
          ]),
        ).catch(() => null);
      }
    } catch {
      // ignore exec errors
    }
  }, 150);
}
