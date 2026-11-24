export type DnsBlockPeriod = '1h' | '24h' | '7d' | 'all';

export interface DnsBlockDomainStat {
  domain: string;
  count: number;
  matched_rule: string;
  list_source: string;
  last_seen: number;
}

export interface DnsBlockClientStat {
  client_ip: string;
  client_name: string;
  blocked_count: number;
  unique_domains: number;
  last_seen: number;
  top_domains: DnsBlockDomainStat[];
}

export interface DnsBlockRuleStat {
  matched_rule: string;
  list_source: string;
  count: number;
}

export interface DnsBlockListStat {
  list_source: string;
  count: number;
}

export interface DnsBlockEventItem {
  timestamp_unix: number;
  client_ip: string;
  client_name: string;
  domain: string;
  matched_rule: string;
  list_source: string;
}

export interface DnsBlockStatsResponse {
  ok: boolean;
  period: DnsBlockPeriod;
  generated_at: number;
  total_blocked: number;
  unique_clients: number;
  unique_domains: number;
  clients: DnsBlockClientStat[];
  top_domains: DnsBlockDomainStat[];
  top_rules: DnsBlockRuleStat[];
  top_lists: DnsBlockListStat[];
  recent_events: DnsBlockEventItem[];
  error?: string;
}

export const DNS_BLOCK_PERIODS: readonly DnsBlockPeriod[] = [
  '1h',
  '24h',
  '7d',
  'all',
];

export function parseDnsBlockPeriod(raw: string): DnsBlockPeriod {
  const norm = (raw || '').trim().toLowerCase();
  if (norm === '1h' || norm === '24h' || norm === '7d' || norm === 'all') {
    return norm;
  }
  return '24h';
}

export function createEmptyDnsBlockStats(
  period: DnsBlockPeriod = '24h',
  error?: string,
): DnsBlockStatsResponse {
  return {
    ok: !error,
    period,
    generated_at: 0,
    total_blocked: 0,
    unique_clients: 0,
    unique_domains: 0,
    clients: [],
    top_domains: [],
    top_rules: [],
    top_lists: [],
    recent_events: [],
    ...(error ? { error } : {}),
  };
}

function asString(v: unknown): string {
  return typeof v === 'string' ? v : '';
}

function asNumber(v: unknown): number {
  return typeof v === 'number' && Number.isFinite(v) ? v : 0;
}

function normalizeDomainStat(raw: unknown): DnsBlockDomainStat | null {
  if (!raw || typeof raw !== 'object') return null;
  const r = raw as Record<string, unknown>;
  const domain = asString(r.domain);
  if (!domain) return null;
  return {
    domain,
    count: asNumber(r.count),
    matched_rule: asString(r.matched_rule) || `||${domain}^`,
    list_source: asString(r.list_source),
    last_seen: asNumber(r.last_seen),
  };
}

export function normalizeDnsBlockStatsResponse(
  raw: unknown,
  fallbackPeriod: DnsBlockPeriod = '24h',
): DnsBlockStatsResponse {
  if (!raw || typeof raw !== 'object') {
    return createEmptyDnsBlockStats(fallbackPeriod, 'Invalid response');
  }
  const obj = raw as Record<string, unknown>;
  const period = parseDnsBlockPeriod(asString(obj.period) || fallbackPeriod);
  const clientsRaw = Array.isArray(obj.clients) ? obj.clients : [];
  const topDomainsRaw = Array.isArray(obj.top_domains) ? obj.top_domains : [];
  const topRulesRaw = Array.isArray(obj.top_rules) ? obj.top_rules : [];
  const topListsRaw = Array.isArray(obj.top_lists) ? obj.top_lists : [];
  const recentRaw = Array.isArray(obj.recent_events) ? obj.recent_events : [];

  const clients: DnsBlockClientStat[] = clientsRaw
    .map((item) => {
      if (!item || typeof item !== 'object') return null;
      const c = item as Record<string, unknown>;
      const client_ip = asString(c.client_ip);
      if (!client_ip) return null;
      const topDoms = Array.isArray(c.top_domains)
        ? c.top_domains
            .map(normalizeDomainStat)
            .filter((x): x is DnsBlockDomainStat => x !== null)
        : [];
      return {
        client_ip,
        client_name: asString(c.client_name),
        blocked_count: asNumber(c.blocked_count),
        unique_domains: asNumber(c.unique_domains),
        last_seen: asNumber(c.last_seen),
        top_domains: topDoms,
      };
    })
    .filter((x): x is DnsBlockClientStat => x !== null);

  const top_domains = topDomainsRaw
    .map(normalizeDomainStat)
    .filter((x): x is DnsBlockDomainStat => x !== null);

  const top_rules: DnsBlockRuleStat[] = topRulesRaw
    .map((item) => {
      if (!item || typeof item !== 'object') return null;
      const r = item as Record<string, unknown>;
      const matched_rule = asString(r.matched_rule);
      if (!matched_rule) return null;
      return {
        matched_rule,
        list_source: asString(r.list_source),
        count: asNumber(r.count),
      };
    })
    .filter((x): x is DnsBlockRuleStat => x !== null);

  const top_lists: DnsBlockListStat[] = topListsRaw
    .map((item) => {
      if (!item || typeof item !== 'object') return null;
      const r = item as Record<string, unknown>;
      const list_source = asString(r.list_source);
      if (!list_source) return null;
      return {
        list_source,
        count: asNumber(r.count),
      };
    })
    .filter((x): x is DnsBlockListStat => x !== null);

  const recent_events: DnsBlockEventItem[] = recentRaw
    .map((item) => {
      if (!item || typeof item !== 'object') return null;
      const e = item as Record<string, unknown>;
      const domain = asString(e.domain);
      if (!domain) return null;
      return {
        timestamp_unix: asNumber(e.timestamp_unix),
        client_ip: asString(e.client_ip),
        client_name: asString(e.client_name),
        domain,
        matched_rule: asString(e.matched_rule) || `||${domain}^`,
        list_source: asString(e.list_source),
      };
    })
    .filter((x): x is DnsBlockEventItem => x !== null);

  const errMsg = asString(obj.error);
  return {
    ok: obj.ok !== false && !errMsg,
    period,
    generated_at: asNumber(obj.generated_at),
    total_blocked: asNumber(obj.total_blocked),
    unique_clients: asNumber(obj.unique_clients),
    unique_domains: asNumber(obj.unique_domains),
    clients,
    top_domains,
    top_rules,
    top_lists,
    recent_events,
    ...(errMsg ? { error: errMsg } : {}),
  };
}

export async function fetchDnsBlockStats(
  period: DnsBlockPeriod,
  fetchImpl: typeof fetch | undefined = typeof fetch === 'function'
    ? fetch
    : undefined,
): Promise<DnsBlockStatsResponse> {
  const normPeriod = parseDnsBlockPeriod(period);
  if (!fetchImpl) {
    return createEmptyDnsBlockStats(normPeriod, 'Fetch unavailable');
  }
  try {
    const res = await fetchImpl(
      `/api/dns/block-stats?period=${encodeURIComponent(normPeriod)}`,
      {
        method: 'GET',
        credentials: 'same-origin',
        cache: 'no-store',
      },
    );
    const payload = await res.json().catch(() => null);
    if (!res.ok) {
      const errText =
        payload && typeof payload === 'object' && 'error' in payload
          ? asString((payload as Record<string, unknown>).error)
          : `HTTP ${res.status}`;
      return createEmptyDnsBlockStats(
        normPeriod,
        errText || `HTTP ${res.status}`,
      );
    }
    return normalizeDnsBlockStatsResponse(payload, normPeriod);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err || 'Error');
    return createEmptyDnsBlockStats(normPeriod, msg);
  }
}

export async function clearDnsBlockStats(
  fetchImpl: typeof fetch | undefined = typeof fetch === 'function'
    ? fetch
    : undefined,
): Promise<{ ok: boolean; error?: string }> {
  if (!fetchImpl) {
    return { ok: false, error: 'Fetch unavailable' };
  }
  try {
    const res = await fetchImpl('/api/dns/block-stats/clear', {
      method: 'POST',
      credentials: 'same-origin',
      cache: 'no-store',
    });
    const payload = await res.json().catch(() => null);
    if (!res.ok) {
      const errText =
        payload && typeof payload === 'object' && 'error' in payload
          ? asString((payload as Record<string, unknown>).error)
          : `HTTP ${res.status}`;
      return { ok: false, error: errText || `HTTP ${res.status}` };
    }
    return { ok: payload?.ok !== false };
  } catch (err) {
    return {
      ok: false,
      error: err instanceof Error ? err.message : String(err || 'Error'),
    };
  }
}

export function formatListSourceLabel(source: string): string {
  const s = (source || '').trim();
  if (!s) return '-';
  if (s.startsWith('inline:')) {
    return s.slice('inline:'.length) || 'inline';
  }
  try {
    const u = new URL(s);
    const segs = u.pathname.split('/').filter(Boolean);
    const tail = segs.length > 0 ? segs[segs.length - 1] : '';
    return tail ? `${u.hostname}/${tail}` : u.hostname;
  } catch {
    return s;
  }
}

export function formatBlockTimestamp(unixSecs: number): string {
  if (!unixSecs || !Number.isFinite(unixSecs)) return '-';
  const d = new Date(unixSecs * 1000);
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}

function isSimpleIp(tok: string): boolean {
  const s = tok.trim();
  if (!s) return false;
  if (/^(\d{1,3}\.){3}\d{1,3}$/.test(s)) {
    return s.split('.').every((p) => {
      const n = Number(p);
      return n >= 0 && n <= 255;
    });
  }
  return s.includes(':') && /^[0-9a-fA-F:]+$/.test(s);
}

function isValidRuleDomainToken(raw: string): boolean {
  const clean = raw.trim().replace(/\.+$/, '').toLowerCase();
  if (!clean || clean.length > 253 || !clean.includes('.')) return false;
  const labels = clean.split('.');
  return labels.every(
    (lbl) =>
      lbl.length >= 1 &&
      lbl.length <= 63 &&
      /^[a-z0-9_][a-z0-9_-]*[a-z0-9_]$|^[a-z0-9_]$/.test(lbl),
  );
}

export function validateHostsOrAdguardLine(rawLine: string): {
  valid: boolean;
  kind?: 'comment' | 'hosts' | 'adguard';
} {
  const trimmed = (rawLine || '').trim();
  if (
    !trimmed ||
    trimmed.startsWith('#') ||
    trimmed.startsWith('!') ||
    trimmed.startsWith('[')
  ) {
    return { valid: true, kind: 'comment' };
  }

  // Hosts format (`IP domain...` or `domain IP`), ignoring inline `#` comments.
  if (
    !trimmed.startsWith('@@') &&
    !trimmed.startsWith('||') &&
    !trimmed.startsWith('|') &&
    /\s/.test(trimmed)
  ) {
    const noComment = trimmed.replace(/\s+#.*$/, '').trim();
    const parts = noComment.split(/\s+/);
    if (parts.length >= 2) {
      if (
        isSimpleIp(parts[0]) &&
        parts
          .slice(1)
          .every((d) => isValidRuleDomainToken(d) || d === 'localhost')
      ) {
        return { valid: true, kind: 'hosts' };
      }
      if (
        parts.length === 2 &&
        isSimpleIp(parts[1]) &&
        isValidRuleDomainToken(parts[0])
      ) {
        return { valid: true, kind: 'hosts' };
      }
    }
    return { valid: false };
  }

  if (/\s/.test(trimmed)) {
    return { valid: false };
  }

  const dollarIdx = trimmed.indexOf('$');
  let body = trimmed;
  if (dollarIdx !== -1) {
    body = trimmed.slice(0, dollarIdx);
    const modsRaw = trimmed.slice(dollarIdx + 1).trim();
    if (!modsRaw) return { valid: false };
    const mods = modsRaw.split(',').map((m) => m.trim());
    for (const m of mods) {
      if (!m) return { valid: false };
      const lower = m.toLowerCase();
      const okMod =
        lower === 'important' ||
        /^dnstype=[a-z]+(\|[a-z]+)*$/i.test(m) ||
        /^client=[^~|\s]+(\|[^~|\s]+)*$/i.test(m) ||
        /^dnsrewrite=(nxdomain|[0-9a-fA-F:.]+|noerror;(a|aaaa);[0-9a-fA-F:.]+)$/i.test(
          m,
        );
      if (!okMod) return { valid: false };
    }
  }

  if (body.startsWith('@@')) {
    body = body.slice(2);
  }
  if (!body || body.includes('://') || body.includes('/')) {
    return { valid: false };
  }

  let dom = body;
  if (dom.startsWith('||')) {
    dom = dom.slice(2);
  } else if (dom.startsWith('|')) {
    dom = dom.slice(1);
  }
  if (dom.endsWith('^')) {
    dom = dom.slice(0, -1);
  }
  if (dom.startsWith('*.')) {
    dom = dom.slice(2);
  }

  if (!isValidRuleDomainToken(dom)) {
    return { valid: false };
  }
  return { valid: true, kind: 'adguard' };
}
