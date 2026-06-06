import { describe, expect, it } from 'vitest';

import {
  getLogNotificationKey,
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
  it('only accepts error and fatal log lines', () => {
    expect(isErrorLogLine('podkop-plus: [info] ok')).toBe(false);
    expect(isErrorLogLine('podkop-plus: [error] failed')).toBe(true);
    expect(isErrorLogLine('podkop-plus: [fatal] failed')).toBe(true);
  });

  it('dedupes already shown log lines through session storage', () => {
    const storage = new MemoryStorage();
    const first = new LogNotificationDeduper(storage);

    expect(first.shouldNotify('podkop-plus: [error] failed')).toBe(true);
    expect(first.shouldNotify('podkop-plus: [error] failed')).toBe(false);
    expect(first.shouldNotify('podkop-plus: [error] another failure')).toBe(
      true,
    );

    const afterReload = new LogNotificationDeduper(storage);

    expect(afterReload.shouldNotify('podkop-plus: [error] failed')).toBe(false);
    expect(afterReload.shouldNotify('podkop-plus: [fatal] fatal failure')).toBe(
      true,
    );
  });

  it('keeps the full log line as the replay key', () => {
    expect(
      getLogNotificationKey('  Jun 06 podkop-plus: [error] failed  '),
    ).toBe('Jun 06 podkop-plus: [error] failed');
  });
});
