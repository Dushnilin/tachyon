import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

type SessionJobsModule = typeof import('../sessionJobs');

describe('sessionJobs', () => {
  let storage: Record<string, string> = {};
  let sessionJobs: SessionJobsModule;

  beforeEach(async () => {
    vi.resetModules();
    storage = {};
    vi.stubGlobal('sessionStorage', {
      getItem: vi.fn((key: string) => storage[key] || null),
      setItem: vi.fn((key: string, value: string) => {
        storage[key] = value;
      }),
      removeItem: vi.fn((key: string) => {
        delete storage[key];
      }),
    });
    sessionJobs = await import('../sessionJobs');
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it('saves and loads handled jobs from session storage', () => {
    sessionJobs.saveHandledJobToSession('job-1');
    sessionJobs.saveHandledJobToSession('job-2');

    const loaded = sessionJobs.loadHandledJobsFromSession();
    expect(loaded).toContain('job-1');
    expect(loaded).toContain('job-2');
  });

  it('loads legacy tachyon_post_update_job if present', () => {
    storage['tachyon_post_update_job'] = 'legacy-job-99';

    const loaded = sessionJobs.loadHandledJobsFromSession();
    expect(loaded).toContain('legacy-job-99');
  });

  it('does not duplicate job IDs in session storage', () => {
    sessionJobs.saveHandledJobToSession('job-dup');
    sessionJobs.saveHandledJobToSession('job-dup');

    const loaded = sessionJobs.loadHandledJobsFromSession();
    expect(loaded.filter((id) => id === 'job-dup').length).toBe(1);
  });

  it('safeReloadPage calls window.location.reload only once', () => {
    const reloadMock = vi.fn();
    vi.stubGlobal('window', {
      location: {
        reload: reloadMock,
      },
    });
    vi.stubGlobal('performance', {
      getEntriesByType: vi.fn(() => []),
    });

    void sessionJobs.safeReloadPage();
    expect(reloadMock).toHaveBeenCalledTimes(1);
    expect(sessionJobs.isReloadInProgress()).toBe(true);

    // Second call should be a no-op
    void sessionJobs.safeReloadPage();
    expect(reloadMock).toHaveBeenCalledTimes(1);
  });

  it('revalidates matching LuCI/Tachyon scripts and document URL before reloading', async () => {
    const events: string[] = [];
    const reloadMock = vi.fn(() => {
      events.push('reload');
    });
    const fetchMock = vi.fn(async (url: string, _init?: RequestInit) => {
      events.push(`fetch:${url}`);
      return { ok: true };
    });

    vi.stubGlobal('fetch', fetchMock);
    vi.stubGlobal('window', {
      location: {
        href: 'https://192.168.1.1/cgi-bin/luci/admin/services/tachyon',
        origin: 'https://192.168.1.1',
        reload: reloadMock,
      },
    });
    vi.stubGlobal('document', {
      querySelectorAll: vi.fn(() => [
        {
          src: 'https://192.168.1.1/luci-static/resources/luci.js?v=git-24',
        },
        {
          getAttribute: (name: string) =>
            name === 'src'
              ? '/luci-static/resources/view/tachyon/main.js?v=1.7.33'
              : null,
        },
        {
          src: 'https://192.168.1.1/luci-static/resources/other.js',
        },
        {
          src: 'https://cdn.example.com/luci-static/resources/view/tachyon/main.js',
        },
      ]),
    });
    vi.stubGlobal('performance', {
      getEntriesByType: vi.fn(() => [
        {
          name: 'https://192.168.1.1/luci-static/resources/view/tachyon/main.js?v=1.7.33',
        },
        {
          name: 'https://192.168.1.1/luci-static/resources/view/tachyon/updates.js',
        },
        {
          name: 'https://192.168.1.1/luci-static/resources/view/other/domain.js',
        },
      ]),
    });

    await sessionJobs.safeReloadPage();

    expect(fetchMock).toHaveBeenCalledTimes(4);
    const fetchedUrls = fetchMock.mock.calls.map((call) => call[0]);
    expect(fetchedUrls).toEqual([
      'https://192.168.1.1/luci-static/resources/luci.js?v=git-24',
      '/luci-static/resources/view/tachyon/main.js?v=1.7.33',
      'https://192.168.1.1/luci-static/resources/view/tachyon/updates.js',
      'https://192.168.1.1/cgi-bin/luci/admin/services/tachyon',
    ]);

    for (const call of fetchMock.mock.calls) {
      expect(call[1]).toEqual(
        expect.objectContaining({
          cache: 'reload',
          credentials: 'same-origin',
        }),
      );
    }

    expect(reloadMock).toHaveBeenCalledTimes(1);
    expect(events[events.length - 1]).toBe('reload');
  });

  it('reloads cleanly when cache-busting fetch rejects or throws synchronously', async () => {
    const reloadMock = vi.fn();
    let callCount = 0;
    const fetchMock = vi.fn((url: string) => {
      callCount += 1;
      if (url.includes('luci.js')) {
        throw new Error('sync offline failure');
      }
      return Promise.reject(new Error('network error'));
    });

    vi.stubGlobal('fetch', fetchMock);
    vi.stubGlobal('window', {
      location: {
        href: 'https://192.168.1.1/cgi-bin/luci/admin/services/tachyon',
        origin: 'https://192.168.1.1',
        reload: reloadMock,
      },
    });
    vi.stubGlobal('document', {
      querySelectorAll: vi.fn(() => [
        { src: 'https://192.168.1.1/luci-static/resources/luci.js' },
        {
          src: 'https://192.168.1.1/luci-static/resources/view/tachyon/main.js',
        },
      ]),
    });
    vi.stubGlobal('performance', {
      getEntriesByType: vi.fn(() => []),
    });

    await sessionJobs.safeReloadPage();

    expect(callCount).toBe(3);
    expect(reloadMock).toHaveBeenCalledTimes(1);
  });

  it('aborts stalled fetches after timeout so reload is never blocked', async () => {
    vi.useFakeTimers();
    const reloadMock = vi.fn();
    const observedSignals: AbortSignal[] = [];
    const fetchMock = vi.fn((_url: string, init?: RequestInit) => {
      if (init?.signal) {
        observedSignals.push(init.signal);
      }
      return new Promise<void>(() => {
        // Never resolves
      });
    });

    vi.stubGlobal('fetch', fetchMock);
    vi.stubGlobal('window', {
      location: {
        reload: reloadMock,
      },
    });
    vi.stubGlobal('document', {
      querySelectorAll: vi.fn(() => [
        { src: '/luci-static/resources/view/tachyon/main.js' },
      ]),
    });
    vi.stubGlobal('performance', {
      getEntriesByType: vi.fn(() => []),
    });

    const reloadPromise = sessionJobs.safeReloadPage();
    expect(reloadMock).not.toHaveBeenCalled();

    await vi.advanceTimersByTimeAsync(2500);
    await reloadPromise;

    expect(observedSignals.length).toBe(1);
    expect(observedSignals[0].aborted).toBe(true);
    expect(reloadMock).toHaveBeenCalledTimes(1);
  });

  it('prevents duplicate revalidation and reload while in flight', async () => {
    const reloadMock = vi.fn();
    let resolveFetch: (() => void) | undefined;
    const fetchMock = vi.fn(
      () =>
        new Promise<{ ok: boolean }>((resolve) => {
          resolveFetch = () => resolve({ ok: true });
        }),
    );

    vi.stubGlobal('fetch', fetchMock);
    vi.stubGlobal('window', {
      location: {
        reload: reloadMock,
      },
    });
    vi.stubGlobal('document', {
      querySelectorAll: vi.fn(() => [
        { src: '/luci-static/resources/view/tachyon/main.js' },
      ]),
    });
    vi.stubGlobal('performance', {
      getEntriesByType: vi.fn(() => []),
    });

    const firstCall = sessionJobs.safeReloadPage();
    const secondCall = sessionJobs.safeReloadPage();

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(reloadMock).not.toHaveBeenCalled();

    resolveFetch?.();
    await Promise.all([firstCall, secondCall]);

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(reloadMock).toHaveBeenCalledTimes(1);
  });

  it('falls back cleanly when fetch or window.location is absent', async () => {
    const reloadMock = vi.fn();
    vi.stubGlobal('fetch', undefined);
    vi.stubGlobal('window', {
      location: {
        reload: reloadMock,
      },
    });
    vi.stubGlobal('document', {
      querySelectorAll: vi.fn(() => [
        { src: '/luci-static/resources/luci.js' },
      ]),
    });
    vi.stubGlobal('performance', {
      getEntriesByType: vi.fn(() => []),
    });

    await expect(sessionJobs.safeReloadPage()).resolves.toBeUndefined();
    expect(reloadMock).toHaveBeenCalledTimes(1);

    vi.resetModules();
    sessionJobs = await import('../sessionJobs');
    vi.stubGlobal('window', undefined);
    vi.stubGlobal('document', undefined);
    vi.stubGlobal('performance', undefined);

    await expect(sessionJobs.safeReloadPage()).resolves.toBeUndefined();
  });
});
