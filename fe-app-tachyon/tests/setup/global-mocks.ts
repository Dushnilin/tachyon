// tests/setup/global-mocks.ts
globalThis._ = (key: string) => key;
(globalThis as any).rpc = { declare: () => () => Promise.resolve({}) };
if (typeof (globalThis as any).localStorage === 'undefined') {
  const storage = new Map<string, string>();
  (globalThis as any).localStorage = {
    getItem: (key: string) => storage.get(key) ?? null,
    setItem: (key: string, val: string) => storage.set(key, `${val}`),
    removeItem: (key: string) => storage.delete(key),
    clear: () => storage.clear(),
  };
}

