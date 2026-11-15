const HANDLED_JOBS_STORAGE_KEY = 'tachyon_handled_component_jobs';
const LEGACY_JOB_STORAGE_KEY = 'tachyon_post_update_job';

let isPageReloading = false;

export function safeReloadPage(): void {
  if (isPageReloading) {
    return;
  }
  isPageReloading = true;
  if (typeof window !== 'undefined' && window.location) {
    window.location.reload();
  }
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
