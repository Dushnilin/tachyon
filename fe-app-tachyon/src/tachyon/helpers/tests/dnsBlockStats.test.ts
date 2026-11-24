import { describe, expect, it, vi } from 'vitest';
import {
  clearDnsBlockStats,
  fetchDnsBlockStats,
  formatListSourceLabel,
  parseDnsBlockPeriod,
  validateHostsOrAdguardLine,
} from '../dnsBlockStats';
import {
  createDnsBlockStatsController,
  renderDnsBlockStatsBody,
} from '../../tabs/monitoring/dnsBlockStatsPanel';

function stubDomTree() {
  const elements = new Map<string, ReturnType<typeof makeEl>>();
  function makeEl(
    tag: string,
    attrs: Record<string, unknown> = {},
    children: unknown = [],
  ) {
    const el: Record<string, unknown> = {
      tagName: tag.toUpperCase(),
      className: typeof attrs.class === 'string' ? attrs.class : '',
      id: typeof attrs.id === 'string' ? attrs.id : '',
      attrs,
      children: Array.isArray(children)
        ? children
        : children != null
          ? [children]
          : [],
      textContent:
        typeof children === 'string' || typeof children === 'number'
          ? String(children)
          : '',
      onclick: null as (() => void) | null,
      replaceChildren: (...next: unknown[]) => {
        el.children = next;
      },
    };
    if (typeof el.id === 'string' && el.id) {
      elements.set(el.id, el);
    }
    return el;
  }

  return {
    elements,
    E: (tag: string, attrs?: Record<string, unknown>, children?: unknown) =>
      makeEl(tag, attrs || {}, children),
  };
}

describe('validateHostsOrAdguardLine', () => {
  it('accepts comments, hosts mappings, and AdGuard rules', () => {
    expect(validateHostsOrAdguardLine('')).toEqual({
      valid: true,
      kind: 'comment',
    });
    expect(validateHostsOrAdguardLine('! AdGuard comment')).toEqual({
      valid: true,
      kind: 'comment',
    });
    expect(validateHostsOrAdguardLine('# Hosts comment')).toEqual({
      valid: true,
      kind: 'comment',
    });
    expect(
      validateHostsOrAdguardLine('0.0.0.0 ads.example.com # comment'),
    ).toEqual({ valid: true, kind: 'hosts' });
    expect(validateHostsOrAdguardLine('nas.lan 192.168.1.50')).toEqual({
      valid: true,
      kind: 'hosts',
    });
    expect(validateHostsOrAdguardLine('||tracker.example.org^')).toEqual({
      valid: true,
      kind: 'adguard',
    });
    expect(
      validateHostsOrAdguardLine('@@||safe.tracker.example.org^$important'),
    ).toEqual({ valid: true, kind: 'adguard' });
    expect(
      validateHostsOrAdguardLine(
        '||ipv6-ad.example.org^$dnstype=AAAA,client=192.168.1.50',
      ),
    ).toEqual({ valid: true, kind: 'adguard' });
  });

  it('rejects malformed tokens and unsupported modifiers', () => {
    expect(validateHostsOrAdguardLine('not-a-valid-single-word').valid).toBe(
      false,
    );
    expect(validateHostsOrAdguardLine('||example.org/ads.js').valid).toBe(
      false,
    );
    expect(validateHostsOrAdguardLine('||example.org^$third-party').valid).toBe(
      false,
    );
  });
});

describe('dnsBlockStats helper & controller', () => {
  it('parses period tokens and shortens list source labels cleanly', () => {
    expect(parseDnsBlockPeriod('1h')).toBe('1h');
    expect(parseDnsBlockPeriod('7D')).toBe('7d');
    expect(parseDnsBlockPeriod('all')).toBe('all');
    expect(parseDnsBlockPeriod('unknown')).toBe('24h');

    expect(
      formatListSourceLabel(
        'https://raw.githubusercontent.com/Dushnilin/lists/main/adguard.txt',
      ),
    ).toBe('raw.githubusercontent.com/adguard.txt');
    expect(formatListSourceLabel('inline:HostsBlock')).toBe('HostsBlock');
  });

  it('fetches authenticated stats by period and updates UI on period filter change', async () => {
    const dom = stubDomTree();
    const prevE = (globalThis as Record<string, unknown>).E;
    const prev_ = (globalThis as Record<string, unknown>)._;
    const prevDoc = (globalThis as Record<string, unknown>).document;

    (globalThis as Record<string, unknown>).E = dom.E;
    (globalThis as Record<string, unknown>)._ = (s: string) => s;

    const mockBody = dom.E('div', { id: 'monitoring-dns-block-stats-body' });
    const periodBtns: Record<string, ReturnType<typeof dom.E>> = {
      '1h': dom.E('button', { id: 'monitoring-dns-period-1h' }),
      '24h': dom.E('button', { id: 'monitoring-dns-period-24h' }),
      '7d': dom.E('button', { id: 'monitoring-dns-period-7d' }),
      all: dom.E('button', { id: 'monitoring-dns-period-all' }),
    };
    const refreshBtn = dom.E('button', { id: 'monitoring-dns-refresh' });

    (globalThis as Record<string, unknown>).document = {
      hidden: false,
      documentElement: { lang: 'en' },
      getElementById: (id: string) => {
        if (id === 'monitoring-dns-block-stats-body') return mockBody;
        if (id === 'monitoring-dns-refresh') return refreshBtn;
        const m = id.match(/^monitoring-dns-period-(.+)$/);
        return m ? periodBtns[m[1]] || null : null;
      },
    };

    try {
      const fetchMock = vi.fn(async (url: string | URL | Request) => {
        const u = String(url);
        const period = u.includes('period=7d') ? '7d' : '24h';
        return {
          ok: true,
          status: 200,
          json: async () => ({
            ok: true,
            period,
            generated_at: 1700000100,
            total_blocked: period === '7d' ? 42 : 5,
            unique_clients: 1,
            unique_domains: 1,
            clients: [
              {
                client_ip: '192.168.1.50',
                client_name: 'laptop',
                blocked_count: period === '7d' ? 42 : 5,
                unique_domains: 1,
                last_seen: 1700000100,
                top_domains: [
                  {
                    domain: 'ads.example.org',
                    count: period === '7d' ? 42 : 5,
                    matched_rule: '||ads.example.org^',
                    list_source: 'https://example.org/adguard.txt',
                    last_seen: 1700000100,
                  },
                ],
              },
            ],
            top_domains: [
              {
                domain: 'ads.example.org',
                count: period === '7d' ? 42 : 5,
                matched_rule: '||ads.example.org^',
                list_source: 'https://example.org/adguard.txt',
                last_seen: 1700000100,
              },
            ],
            top_rules: [
              {
                matched_rule: '||ads.example.org^',
                list_source: 'https://example.org/adguard.txt',
                count: period === '7d' ? 42 : 5,
              },
            ],
            top_lists: [
              {
                list_source: 'https://example.org/adguard.txt',
                count: period === '7d' ? 42 : 5,
              },
            ],
            recent_events: [
              {
                timestamp_unix: 1700000100,
                client_ip: '192.168.1.50',
                client_name: 'laptop',
                domain: 'ads.example.org',
                matched_rule: '||ads.example.org^',
                list_source: 'https://example.org/adguard.txt',
              },
            ],
          }),
        } as unknown as Response;
      });

      const direct = await fetchDnsBlockStats('7d', fetchMock);
      expect(direct.ok).toBe(true);
      expect(direct.total_blocked).toBe(42);
      expect(direct.clients[0].client_ip).toBe('192.168.1.50');
      expect(fetchMock).toHaveBeenCalledWith(
        '/api/dns/block-stats?period=7d',
        expect.objectContaining({ method: 'GET', credentials: 'same-origin' }),
      );

      const rendered = renderDnsBlockStatsBody(direct, false) as unknown as {
        children: unknown[];
      };
      expect(JSON.stringify(rendered)).toContain('||ads.example.org^');
      expect(JSON.stringify(rendered)).toContain('laptop (192.168.1.50)');

      const ctrl = createDnsBlockStatsController(fetchMock);
      ctrl.mount();
      await Promise.resolve();
      await Promise.resolve();
      expect(ctrl.getPeriod()).toBe('24h');

      await ctrl.setPeriod('7d');
      expect(ctrl.getPeriod()).toBe('7d');
      expect(periodBtns['7d'].className).toContain('--active');
      expect(JSON.stringify(mockBody.children)).toContain('42');
      ctrl.unmount();

      const filteredBody = renderDnsBlockStatsBody(direct, false, {
        searchQuery: '192.168.1.50',
        selectedClientIp: '192.168.1.50',
      }) as unknown as { children: unknown[] };
      expect(JSON.stringify(filteredBody)).toContain('ads.example.org');

      const emptyFiltered = renderDnsBlockStatsBody(direct, false, {
        searchQuery: 'nonexistent.invalid',
      }) as unknown as { children: unknown[] };
      expect(JSON.stringify(emptyFiltered)).toContain(
        'No blocked requests match the current filter.',
      );

      const clearRes = await clearDnsBlockStats(fetchMock);
      expect(clearRes.ok).toBe(true);
      expect(fetchMock).toHaveBeenCalledWith(
        '/api/dns/block-stats/clear',
        expect.objectContaining({ method: 'POST', credentials: 'same-origin' }),
      );
    } finally {
      (globalThis as Record<string, unknown>).E = prevE;
      (globalThis as Record<string, unknown>)._ = prev_;
      (globalThis as Record<string, unknown>).document = prevDoc;
    }
  });
});
