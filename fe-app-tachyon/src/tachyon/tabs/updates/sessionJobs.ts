const HANDLED_JOBS_STORAGE_KEY = 'tachyon_handled_component_jobs';
const LEGACY_JOB_STORAGE_KEY = 'tachyon_post_update_job';
const CACHE_BUST_TIMEOUT_MS = 2500;

let isPageReloading = false;

interface ScriptElementLike {
  src?: unknown;
  getAttribute?: (name: string) => string | null;
}

function getSafeBaseLocation(): { href: string; origin: string } | null {
  if (typeof window === 'undefined' || !window.location) {
    return null;
  }
  const href =
    typeof window.location.href === 'string' ? window.location.href.trim() : '';
  let origin =
    typeof window.location.origin === 'string'
      ? window.location.origin.trim()
      : '';
  if ((!origin || origin === 'null') && href) {
    try {
      origin = new URL(href).origin;
    } catch {
      origin = '';
    }
  }
  return {
    href,
    origin: origin === 'null' ? '' : origin,
  };
}

function isSameOriginAssetUrl(rawUrl: string): boolean {
  const trimmed = rawUrl.trim();
  if (!trimmed) {
    return false;
  }
  if (trimmed.startsWith('/') && !trimmed.startsWith('//')) {
    return true;
  }
  if (!trimmed.includes('://') && !trimmed.startsWith('//')) {
    return !/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(trimmed);
  }
  if (!/^(?:https?:)?\/\//i.test(trimmed)) {
    return false;
  }
  const loc = getSafeBaseLocation();
  if (!loc || !loc.origin) {
    return /^https?:\/\//i.test(trimmed);
  }
  try {
    const resolved = new URL(trimmed, loc.href || loc.origin);
    return resolved.origin === loc.origin;
  } catch {
    return false;
  }
}

export function isCacheBustTargetUrl(rawUrl: string): boolean {
  const trimmed = rawUrl.trim();
  if (!trimmed || !isSameOriginAssetUrl(trimmed)) {
    return false;
  }
  const pathWithoutQuery = trimmed.split(/[?#]/)[0];
  return (
    pathWithoutQuery.includes('view/tachyon') ||
    /(?:^|\/)(?:main|luci)\.js$/i.test(pathWithoutQuery)
  );
}

function addDedupedUrl(
  urlMap: Map<string, string>,
  rawUrl: string,
  loc: { href: string; origin: string } | null,
): void {
  const trimmed = rawUrl.trim();
  if (!trimmed) {
    return;
  }
  let canonicalKey = trimmed;
  if (loc && (loc.href || loc.origin)) {
    try {
      canonicalKey = new URL(trimmed, loc.href || loc.origin).href;
    } catch {
      canonicalKey = trimmed;
    }
  }
  if (!urlMap.has(canonicalKey)) {
    urlMap.set(canonicalKey, trimmed);
  }
}

export function collectCacheBustTargetUrls(): string[] {
  const urlMap = new Map<string, string>();
  const loc = getSafeBaseLocation();

  if (
    typeof document !== 'undefined' &&
    typeof document.querySelectorAll === 'function'
  ) {
    try {
      const scripts = document.querySelectorAll('script[src]');
      for (let i = 0; i < scripts.length; i += 1) {
        const el = scripts[i] as unknown as ScriptElementLike;
        const src =
          typeof el?.src === 'string' && el.src.trim()
            ? el.src.trim()
            : typeof el?.getAttribute === 'function'
              ? (el.getAttribute('src') || '').trim()
              : '';
        if (src && isCacheBustTargetUrl(src)) {
          addDedupedUrl(urlMap, src, loc);
        }
      }
    } catch {
      // Ignore DOM query errors in restricted environments
    }
  }

  if (
    typeof performance !== 'undefined' &&
    typeof performance.getEntriesByType === 'function'
  ) {
    try {
      const entries = performance.getEntriesByType('resource');
      for (let i = 0; i < entries.length; i += 1) {
        const name =
          typeof entries[i]?.name === 'string' ? entries[i].name.trim() : '';
        if (name && isCacheBustTargetUrl(name)) {
          addDedupedUrl(urlMap, name, loc);
        }
      }
    } catch {
      // Ignore Performance API errors
    }
  }

  const docUrl =
    (loc?.href && /^(?:https?:\/\/|\/(?!\/))/i.test(loc.href)
      ? loc.href
      : '') ||
    (typeof document !== 'undefined' &&
    typeof document.URL === 'string' &&
    /^(?:https?:\/\/|\/(?!\/))/i.test(document.URL.trim())
      ? document.URL.trim()
      : '');
  if (docUrl && isSameOriginAssetUrl(docUrl)) {
    addDedupedUrl(urlMap, docUrl, loc);
  }

  return Array.from(urlMap.values());
}

export async function revalidateTachyonAssets(
  urls: string[] = collectCacheBustTargetUrls(),
  timeoutMs: number = CACHE_BUST_TIMEOUT_MS,
): Promise<void> {
  if (typeof fetch !== 'function' || urls.length === 0) {
    return;
  }

  const controller =
    typeof AbortController === 'function' ? new AbortController() : null;
  let timeoutId: ReturnType<typeof setTimeout> | undefined;

  try {
    const requests = Promise.allSettled(
      urls.map(async (url) => {
        try {
          const init: RequestInit = {
            cache: 'reload',
            credentials: 'same-origin',
            ...(controller ? { signal: controller.signal } : {}),
          };
          await fetch(url, init);
        } catch {
          // Ignore network/offline errors so reload always proceeds
        }
      }),
    );

    const timeoutPromise = new Promise<void>((resolve) => {
      timeoutId = setTimeout(() => {
        try {
          controller?.abort();
        } catch {
          // Ignore abort errors
        }
        resolve();
      }, timeoutMs);
    });

    await Promise.race([requests, timeoutPromise]);
  } catch {
    // Cache revalidation must never block page reload
  } finally {
    if (timeoutId !== undefined) {
      clearTimeout(timeoutId);
    }
  }
}

function performLocationReload(): void {
  if (
    typeof window !== 'undefined' &&
    window.location &&
    typeof window.location.reload === 'function'
  ) {
    try {
      window.location.reload();
    } catch {
      // Ignore reload failures in restricted environments
    }
  }
}

export function safeReloadPage(): Promise<void> {
  if (isPageReloading) {
    return Promise.resolve();
  }
  isPageReloading = true;

  const urls = collectCacheBustTargetUrls();
  if (typeof fetch !== 'function' || urls.length === 0) {
    performLocationReload();
    return Promise.resolve();
  }

  return revalidateTachyonAssets(urls).finally(() => {
    performLocationReload();
  });
}

export function isReloadInProgress(): boolean {
  return isPageReloading;
}

export function saveHandledJobToSession(jobId: string): void {
  if (!jobId || typeof sessionStorage === 'undefined') {
    return;
  }
  try {
    const raw = sessionStorage.getItem(HANDLED_JOBS_STORAGE_KEY);
    const list: string[] = raw ? JSON.parse(raw) : [];
    if (!list.includes(jobId)) {
      list.push(jobId);
      if (list.length > 30) {
        list.shift();
      }
      sessionStorage.setItem(HANDLED_JOBS_STORAGE_KEY, JSON.stringify(list));
    }
    sessionStorage.setItem(LEGACY_JOB_STORAGE_KEY, jobId);
  } catch (_e) {
    // Ignore private mode or quota errors
  }
}

export function loadHandledJobsFromSession(): string[] {
  if (typeof sessionStorage === 'undefined') {
    return [];
  }
  const result = new Set<string>();
  try {
    const raw = sessionStorage.getItem(HANDLED_JOBS_STORAGE_KEY);
    if (raw) {
      const parsed = JSON.parse(raw);
      if (Array.isArray(parsed)) {
        for (const id of parsed) {
          if (typeof id === 'string' && id) {
            result.add(id);
          }
        }
      }
    }
    const legacy = sessionStorage.getItem(LEGACY_JOB_STORAGE_KEY);
    if (legacy) {
      result.add(legacy);
    }
  } catch (_e) {
    // Ignore private mode errors
  }
  return Array.from(result);
}
