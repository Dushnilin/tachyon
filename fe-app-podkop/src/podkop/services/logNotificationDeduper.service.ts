const LOG_NOTIFICATION_STORAGE_KEY =
  'podkop-plus:shown-log-error-notifications:v1';
const MAX_STORED_LOG_NOTIFICATIONS = 500;

function getSessionStorage(): Storage | null {
  if (typeof window === 'undefined') {
    return null;
  }

  try {
    return window.sessionStorage;
  } catch {
    return null;
  }
}

function readStoredKeys(storage: Storage | null): string[] {
  if (!storage) {
    return [];
  }

  try {
    const parsed = JSON.parse(
      storage.getItem(LOG_NOTIFICATION_STORAGE_KEY) || '[]',
    );

    return Array.isArray(parsed)
      ? parsed.filter((item): item is string => typeof item === 'string')
      : [];
  } catch {
    return [];
  }
}

function writeStoredKeys(storage: Storage | null, keys: string[]) {
  if (!storage) {
    return;
  }

  try {
    storage.setItem(
      LOG_NOTIFICATION_STORAGE_KEY,
      JSON.stringify(keys.slice(-MAX_STORED_LOG_NOTIFICATIONS)),
    );
  } catch {
    // Notifications are still deduped in-memory when sessionStorage is blocked.
  }
}

export function isErrorLogLine(line: string) {
  const lower = line.toLowerCase();
  return lower.includes('[error]') || lower.includes('[fatal]');
}

export function getLogNotificationKey(line: string) {
  return line.trim();
}

export class LogNotificationDeduper {
  private readonly storage: Storage | null;
  private readonly seenKeys: Set<string>;

  constructor(storage: Storage | null = getSessionStorage()) {
    this.storage = storage;
    this.seenKeys = new Set(readStoredKeys(storage));
  }

  shouldNotify(line: string) {
    if (!isErrorLogLine(line)) {
      return false;
    }

    const key = getLogNotificationKey(line);

    if (!key || this.seenKeys.has(key)) {
      return false;
    }

    this.seenKeys.add(key);
    writeStoredKeys(this.storage, Array.from(this.seenKeys));
    return true;
  }
}
