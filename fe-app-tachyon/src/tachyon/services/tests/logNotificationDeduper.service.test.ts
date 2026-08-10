import { describe, expect, it } from 'vitest';

import {
  getLogNotificationKey,
  getTachyonLogNotification,
  isErrorLogLine,
  LogNotificationDeduper,
} from '../logNotificationDeduper.service';

class MemoryStorage implements Storage {
  private values = new Map<string, string>();

  get length() {
    return this.values.size;
  }

  clear() {
    this.values.clear();
  }

  getItem(key: string) {
    return this.values.get(key) ?? null;
  }

  key(index: number) {
    return Array.from(this.values.keys())[index] ?? null;
  }

  removeItem(key: string) {
    this.values.delete(key);
  }

  setItem(key: string, value: string) {
    this.values.set(key, value);
  }
}

describe('LogNotificationDeduper', () => {
  it('accepts error, fatal, and component update log lines', () => {
    expect(isErrorLogLine('tachyon: [info] ok')).toBe(false);
    expect(isErrorLogLine('tachyon: [error] failed')).toBe(true);
    expect(isErrorLogLine('tachyon: [fatal] failed')).toBe(true);
    expect(
      getTachyonLogNotification(
        'tachyon: [info] [component-update] zapret2 v1.2.3',
      ),
    ).toEqual({
      kind: 'component-update',
      line: 'tachyon: [info] [component-update] zapret2 v1.2.3',
      component: 'zapret2',
      version: 'v1.2.3',
    });
    expect(getTachyonLogNotification('tachyon: [info] ok')).toBeNull();
  });

  it('suppresses transient/expected error patterns', () => {
    // Lock contention is expected — user just clicked while action was running
    expect(
      isErrorLogLine(
        'Mon Aug 10 20:56:09 2026 user.notice tachyon: [error] Updates: Another component action is already running',
      ),
    ).toBe(false);
    expect(
      isErrorLogLine('tachyon: [error] another component action is already running'),
    ).toBe(false);
    // DNS retry during sing-box restart is transient
    expect(
      isErrorLogLine(
        'tachyon: [debug] Subscription DNS resolution failed for rule; retrying in 5s (attempt 1/3)',
      ),
    ).toBe(false);
    // Other real errors must still fire
    expect(isErrorLogLine('tachyon: [error] sing-box crashed unexpectedly')).toBe(true);
  });


  it('dedupes already shown log lines through session storage', () => {
    const storage = new MemoryStorage();
    const first = new LogNotificationDeduper(storage);

    expect(first.shouldNotify('tachyon: [error] failed')).toBe(true);
    expect(first.shouldNotify('tachyon: [error] failed')).toBe(false);
    expect(first.shouldNotify('tachyon: [error] another failure')).toBe(true);
    expect(
      first.shouldNotify('tachyon: [info] [component-update] tachyon 1.2.3'),
    ).toBe(true);

    const afterReload = new LogNotificationDeduper(storage);

    expect(afterReload.shouldNotify('tachyon: [error] failed')).toBe(false);
    expect(afterReload.shouldNotify('tachyon: [fatal] fatal failure')).toBe(
      true,
    );
  });

  it('keeps the full log line as the replay key', () => {
    expect(getLogNotificationKey('  Jun 06 tachyon: [error] failed  ')).toBe(
      'Jun 06 tachyon: [error] failed',
    );
  });
});
