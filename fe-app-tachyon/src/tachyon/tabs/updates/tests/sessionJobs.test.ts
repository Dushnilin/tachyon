import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  isReloadInProgress,
  loadHandledJobsFromSession,
  safeReloadPage,
  saveHandledJobToSession,
} from '../sessionJobs';

describe('sessionJobs', () => {
  let storage: Record<string, string> = {};

  beforeEach(() => {
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
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('saves and loads handled jobs from session storage', () => {
    saveHandledJobToSession('job-1');
    saveHandledJobToSession('job-2');

    const loaded = loadHandledJobsFromSession();
    expect(loaded).toContain('job-1');
    expect(loaded).toContain('job-2');
  });

  it('loads legacy tachyon_post_update_job if present', () => {
    storage['tachyon_post_update_job'] = 'legacy-job-99';

    const loaded = loadHandledJobsFromSession();
    expect(loaded).toContain('legacy-job-99');
  });

  it('does not duplicate job IDs in session storage', () => {
    saveHandledJobToSession('job-dup');
    saveHandledJobToSession('job-dup');

    const loaded = loadHandledJobsFromSession();
    expect(loaded.filter((id) => id === 'job-dup').length).toBe(1);
  });

  it('safeReloadPage calls window.location.reload only once', () => {
    const reloadMock = vi.fn();
    vi.stubGlobal('window', {
      location: {
        reload: reloadMock,
      },
    });

    safeReloadPage();
    expect(reloadMock).toHaveBeenCalledTimes(1);
    expect(isReloadInProgress()).toBe(true);

    // Second call should be a no-op
    safeReloadPage();
    expect(reloadMock).toHaveBeenCalledTimes(1);
  });
});
