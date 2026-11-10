export function canUseDirectClashApi(): boolean {
  const loc = typeof window !== 'undefined' ? window.location : undefined;

  return Boolean(loc?.hostname && loc.protocol !== 'https:');
}

export function getClashWsUrl(): string {
  const { hostname } = window.location;

  return `ws://${hostname}:9090`;
}

export function getClashHttpUrl(): string {
  const { hostname } = window.location;

  return `http://${hostname}:9090`;
}

export function getClashUIUrl(secret?: string): string {
  const { hostname } = window.location;
  const uciGlobal = (globalThis as Record<string, unknown>).uci as
    | { get?: (pkg: string, sec: string, opt: string) => unknown }
    | undefined;
  const resolvedSecret = String(
    secret !== undefined
      ? secret
      : (uciGlobal?.get?.('tachyon', 'settings', 'yacd_secret_key') ?? ''),
  ).trim();
  if (resolvedSecret) {
    return `http://${hostname}:9090/ui/?hostname=${encodeURIComponent(hostname)}&port=9090&secret=${encodeURIComponent(resolvedSecret)}`;
  }

  return `http://${hostname}:9090/ui`;
}
