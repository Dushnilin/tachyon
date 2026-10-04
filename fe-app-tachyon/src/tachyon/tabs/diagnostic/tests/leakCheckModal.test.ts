/* eslint-disable @typescript-eslint/no-explicit-any */
import { beforeEach, describe, expect, it, vi } from 'vitest';

// ---------------------------------------------------------------------------
// Hoisted mocks — must come before any imports that transitively use globals
// ---------------------------------------------------------------------------
const mocks = vi.hoisted(() => {
  // Minimal DOM mock that tracks tree structure for inspection
  function createEl(tag: string) {
    const el: any = {
      tagName: tag.toUpperCase(),
      children: [] as any[],
      style: {} as Record<string, string>,
      textContent: '',
      innerHTML: '',
      class: '',
      colSpan: 0,
      setAttribute() {},
      getAttribute() {
        return null;
      },
      addEventListener() {},
      querySelectorAll: () => [],
      querySelector: () => null,
      replaceChildren(...nodes: any[]) {
        (this as any).children = nodes;
      },
      appendChild(node: any) {
        if (node && typeof node === 'object') {
          (this as any).children.push(node);
        } else if (node) {
          (this as any).textContent += String(node);
        }
      },
      append(...nodes: any[]) {
        nodes.forEach((n) => (this as any).appendChild(n));
      },
      classList: { add() {}, remove() {} },
    };
    return el;
  }

  (globalThis as any).document = {
    body: {} as any,
    createElement: (tag: string) => createEl(tag),
    createElementNS: (_ns: string, tag: string) => createEl(tag),
    getElementById: () => null,
    querySelector: () => null,
    querySelectorAll: () => [],
  };

  (globalThis as any).E = (tag: string, attrs?: any, children?: any) => {
    const el = (globalThis as any).document.createElement(tag);
    if (attrs) {
      const { style, ...rest } = attrs;
      Object.assign(el, rest);
      if (style && typeof style === 'string') {
        style.split(';').forEach((rule: string) => {
          const [k, v] = rule.split(':').map((s: string) => s.trim());
          if (k && v) el.style[k] = v;
        });
      } else if (style && typeof style === 'object') {
        Object.assign(el.style, style);
      }
    }
    if (children !== undefined && children !== null) {
      if (Array.isArray(children)) {
        children.forEach((c) => {
          if (c != null) el.appendChild(c);
        });
      } else {
        el.appendChild(children);
      }
    }
    return el;
  };

  (globalThis as any)._ = (str: string) => str;
  (globalThis as any).rpc = { declare: vi.fn() };
  (globalThis as any).uci = { sections: vi.fn().mockResolvedValue([]) };
  (globalThis as any).localStorage = { getItem: vi.fn(), setItem: vi.fn() };

  class MockMutationObserver {
    observe() {}
    disconnect() {}
    takeRecords() {
      return [];
    }
  }
  (globalThis as any).MutationObserver = MockMutationObserver;

  const showModal = vi.fn();
  const hideModal = vi.fn();
  (globalThis as any).ui = { showModal, hideModal, addNotification: vi.fn() };

  return { showModal, hideModal };
});

// ---------------------------------------------------------------------------
// Imports after mocks
// ---------------------------------------------------------------------------
import { renderLeakCheckModal } from '../partials/renderLeakCheckModal';
import { TachyonShellMethods } from '../../../methods/shell';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Recursively collect all text content from a mock element tree. */
function collectText(node: any): string {
  if (!node || typeof node !== 'object') return String(node ?? '');
  let text = node.textContent || '';
  for (const child of node.children || []) {
    text += collectText(child);
  }
  return text;
}

/** Find all elements matching a class attribute value anywhere in the tree. */
function findByClass(node: any, cls: string): any[] {
  const results: any[] = [];
  if (!node || typeof node !== 'object') return results;
  if (typeof node.class === 'string' && node.class.includes(cls)) {
    results.push(node);
  }
  for (const child of node.children || []) {
    results.push(...findByClass(child, cls));
  }
  return results;
}

/** Extract text from the second argument of the last showModal call. */
function getModalContent(): any {
  const calls = mocks.showModal.mock.calls;
  return calls[calls.length - 1]?.[1];
}

// Default "happy path" leak result
function makeSuccessResult(overrides: Record<string, any> = {}) {
  return {
    success: true as const,
    data: {
      ip_leak: {
        leaked: false,
        direct_ip: '95.173.136.25',
        direct_country: 'Russia',
        direct_city: 'Moscow',
        direct_isp: 'Rostelecom',
        proxy_ip: '185.220.101.5',
        proxy_country: 'Netherlands',
        proxy_city: 'Amsterdam',
        proxy_org: 'Mullvad',
        proxy_online: true,
      },
      dns_leak: {
        dns_leaked: false,
        direct_ip: '95.173.136.25',
        proxy_ip: '185.220.101.5',
        dns_servers: [
          {
            ip: '1.1.1.1',
            country: 'United States',
            isp: 'Cloudflare',
            is_isp: false,
          },
        ],
        direct_dns_servers: [
          {
            ip: '212.188.4.10',
            country: 'Russia',
            isp: 'Rostelecom',
            is_isp: true,
          },
        ],
        proxy_online: true,
      },
      ...overrides,
    },
  };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
describe('renderLeakCheckModal', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.showModal.mockReset();
    vi.spyOn(TachyonShellMethods, 'leakCheck').mockResolvedValue(
      makeSuccessResult(),
    );
  });

  // ── Modal lifecycle ────────────────────────────────────────────────────────

  it('renders the modal with correct title', () => {
    renderLeakCheckModal();
    expect(mocks.showModal).toHaveBeenCalledTimes(1);
    expect(mocks.showModal).toHaveBeenCalledWith(
      expect.stringContaining('Tachyon IP & DNS Leak Detection'),
      expect.anything(),
    );
  });

  it('auto-starts the leak check on open', () => {
    const spy = vi.spyOn(TachyonShellMethods, 'leakCheck');
    renderLeakCheckModal();
    expect(spy).toHaveBeenCalledTimes(1);
  });

  // ── IP section — SECURE path ───────────────────────────────────────────────

  it('shows SECURE alert when proxy is online and IPs differ', async () => {
    renderLeakCheckModal();
    await vi.waitFor(() => {
      const content = getModalContent();
      const text = collectText(content);
      expect(text).toContain('SECURE');
      expect(text).toContain('185.220.101.5');
    });
  });

  it('shows SECURE badge (not DIRECT or INACTIVE) when IPs differ', async () => {
    renderLeakCheckModal();
    await vi.waitFor(() => {
      const content = getModalContent();
      const badges = findByClass(content, 'badge');
      const badgeTexts = badges.map((b) => collectText(b)).join(' ');
      expect(badgeTexts).toContain('SECURE');
      expect(badgeTexts).not.toContain('DIRECT');
      expect(badgeTexts).not.toContain('INACTIVE');
    });
  });

  it('alert class is success when proxy is online and IPs differ', async () => {
    renderLeakCheckModal();
    await vi.waitFor(() => {
      const content = getModalContent();
      // Find the IP alert div
      const alertDivs = findByClass(content, 'alert-message');
      const successAlerts = alertDivs.filter((d) =>
        d.class?.includes('success'),
      );
      expect(successAlerts.length).toBeGreaterThan(0);
    });
  });

  // ── IP section — DIRECT / leaked path ─────────────────────────────────────

  it('shows DIRECT badge when proxy_ip equals direct_ip', async () => {
    vi.spyOn(TachyonShellMethods, 'leakCheck').mockResolvedValue(
      makeSuccessResult({
        ip_leak: {
          leaked: true,
          direct_ip: '95.173.136.25',
          proxy_ip: '95.173.136.25',
          proxy_online: true,
        },
      }),
    );
    renderLeakCheckModal();
    await vi.waitFor(() => {
      const content = getModalContent();
      const badges = findByClass(content, 'badge');
      const badgeTexts = badges.map((b) => collectText(b)).join(' ');
      expect(badgeTexts).toContain('DIRECT');
    });
  });

  it('shows warning alert class when IP is leaked', async () => {
    vi.spyOn(TachyonShellMethods, 'leakCheck').mockResolvedValue(
      makeSuccessResult({
        ip_leak: {
          leaked: true,
          direct_ip: '95.173.136.25',
          proxy_ip: '95.173.136.25',
          proxy_online: true,
        },
      }),
    );
    renderLeakCheckModal();
    await vi.waitFor(() => {
      const content = getModalContent();
      const alertDivs = findByClass(content, 'alert-message');
      const warningAlerts = alertDivs.filter((d) =>
        d.class?.includes('warning'),
      );
      expect(warningAlerts.length).toBeGreaterThan(0);
    });
  });

  // ── IP section — proxy offline ─────────────────────────────────────────────

  it('shows INACTIVE badge when proxy_online=false', async () => {
    vi.spyOn(TachyonShellMethods, 'leakCheck').mockResolvedValue(
      makeSuccessResult({
        ip_leak: {
          leaked: false,
          direct_ip: '95.173.136.25',
          proxy_ip: '—',
          proxy_online: false,
        },
      }),
    );
    renderLeakCheckModal();
    await vi.waitFor(() => {
      const content = getModalContent();
      const badges = findByClass(content, 'badge');
      const badgeTexts = badges.map((b) => collectText(b)).join(' ');
      expect(badgeTexts).toContain('INACTIVE');
    });
  });

  it('shows info alert class when proxy offline', async () => {
    vi.spyOn(TachyonShellMethods, 'leakCheck').mockResolvedValue(
      makeSuccessResult({
        ip_leak: {
          leaked: false,
          direct_ip: '95.173.136.25',
          proxy_ip: '—',
          proxy_online: false,
        },
        dns_leak: {
          dns_leaked: false,
          direct_ip: '95.173.136.25',
          proxy_ip: '—',
          dns_servers: [],
          direct_dns_servers: [],
          proxy_online: false,
        },
      }),
    );
    renderLeakCheckModal();
    await vi.waitFor(() => {
      const content = getModalContent();
      const alertDivs = findByClass(content, 'alert-message');
      const infoAlerts = alertDivs.filter((d) => d.class?.includes('info'));
      expect(infoAlerts.length).toBeGreaterThan(0);
    });
  });

  // ── DNS section ────────────────────────────────────────────────────────────

  it('renders proxy DNS resolvers with "via Proxy" path label', async () => {
    renderLeakCheckModal();
    await vi.waitFor(() => {
      const content = getModalContent();
      const text = collectText(content);
      expect(text).toContain('1.1.1.1');
      expect(text).toContain('via Proxy');
    });
  });

  it('renders direct_dns_servers with "via WAN" path label', async () => {
    renderLeakCheckModal();
    await vi.waitFor(() => {
      const content = getModalContent();
      const text = collectText(content);
      // direct_dns_servers IP from default mock
      expect(text).toContain('212.188.4.10');
      expect(text).toContain('via WAN');
    });
  });

  it('marks ISP DNS servers with ISP DNS badge', async () => {
    renderLeakCheckModal();
    await vi.waitFor(() => {
      const content = getModalContent();
      const badges = findByClass(content, 'badge');
      const badgeTexts = badges.map((b) => collectText(b)).join(' ');
      expect(badgeTexts).toContain('ISP DNS');
    });
  });

  it('marks non-ISP DNS servers with SAFE badge', async () => {
    renderLeakCheckModal();
    await vi.waitFor(() => {
      const content = getModalContent();
      const badges = findByClass(content, 'badge');
      const badgeTexts = badges.map((b) => collectText(b)).join(' ');
      expect(badgeTexts).toContain('SAFE');
    });
  });

  it('shows direct DNS servers even when proxy offline', async () => {
    vi.spyOn(TachyonShellMethods, 'leakCheck').mockResolvedValue(
      makeSuccessResult({
        ip_leak: {
          leaked: false,
          direct_ip: '95.173.136.25',
          proxy_ip: '—',
          proxy_online: false,
        },
        dns_leak: {
          dns_leaked: false,
          direct_ip: '95.173.136.25',
          proxy_ip: '—',
          dns_servers: [],
          direct_dns_servers: [
            { ip: '8.8.8.8', country: 'US', isp: 'Google', is_isp: false },
          ],
          proxy_online: false,
        },
      }),
    );
    renderLeakCheckModal();
    await vi.waitFor(() => {
      const content = getModalContent();
      const text = collectText(content);
      expect(text).toContain('8.8.8.8');
      expect(text).toContain('via WAN');
    });
  });

  it('shows "No DNS resolvers recorded" when both lists are empty', async () => {
    vi.spyOn(TachyonShellMethods, 'leakCheck').mockResolvedValue(
      makeSuccessResult({
        dns_leak: {
          dns_leaked: false,
          direct_ip: '95.173.136.25',
          proxy_ip: '185.220.101.5',
          dns_servers: [],
          direct_dns_servers: [],
          proxy_online: true,
        },
      }),
    );
    renderLeakCheckModal();
    await vi.waitFor(() => {
      const content = getModalContent();
      const text = collectText(content);
      expect(text).toContain('No DNS resolvers recorded');
    });
  });

  // ── Error handling ─────────────────────────────────────────────────────────

  it('shows error alert when leakCheck returns success=false', async () => {
    vi.spyOn(TachyonShellMethods, 'leakCheck').mockResolvedValue({
      success: false,
      error: 'Connection timeout',
    } as any);
    renderLeakCheckModal();
    await vi.waitFor(() => {
      const content = getModalContent();
      const text = collectText(content);
      expect(text).toContain('Connection timeout');
    });
  });

  it('shows error alert on unexpected exception from leakCheck', async () => {
    vi.spyOn(TachyonShellMethods, 'leakCheck').mockRejectedValue(
      new Error('Network error'),
    );
    renderLeakCheckModal();
    await vi.waitFor(() => {
      const content = getModalContent();
      const text = collectText(content);
      expect(text).toContain('Network error');
    });
  });

  // ── Re-run button ──────────────────────────────────────────────────────────

  it('renders Re-run Leak Test button', () => {
    renderLeakCheckModal();
    const content = getModalContent();
    const text = collectText(content);
    expect(text).toContain('Re-run Leak Test');
  });

  it('renders Close button', () => {
    renderLeakCheckModal();
    const content = getModalContent();
    const text = collectText(content);
    expect(text).toContain('Close');
  });
});

describe('DNS Leak Plus', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    (localStorage.getItem as any).mockReset();
    vi.spyOn(TachyonShellMethods, 'leakCheck').mockResolvedValue(
      makeSuccessResult(),
    );
  });

  it('warns about observed plaintext even when the proxy probe is unavailable', async () => {
    const result = makeSuccessResult({ mode: 'plus' });
    Object.assign(result.data.dns_leak, {
      verdict: 'plaintext_observed',
      dns_leaked: true,
      dns_servers: [],
      wan_dns_capture: {
        status: 'plaintext_observed',
        interface: 'eth1',
        queries: 2,
      },
    });
    vi.spyOn(TachyonShellMethods, 'leakCheck').mockResolvedValue(result);
    renderLeakCheckModal();
    await vi.waitFor(() => {
      expect(collectText(getModalContent())).toContain(
        'Test DNS queries were observed unencrypted',
      );
      expect(
        findByClass(getModalContent(), 'alert-message warning').length,
      ).toBeGreaterThan(0);
    });
  });

  it('does not present absent plaintext traffic as proof of encryption', async () => {
    const result = makeSuccessResult({ mode: 'plus' });
    Object.assign(result.data.dns_leak, {
      wan_dns_capture: {
        status: 'not_observed',
        interface: 'eth1',
        queries: 0,
      },
    });
    vi.spyOn(TachyonShellMethods, 'leakCheck').mockResolvedValue(result);
    renderLeakCheckModal();
    await vi.waitFor(() =>
      expect(collectText(getModalContent())).toContain(
        'This alone does not prove encryption or absence of other leaks.',
      ),
    );
  });

  it('reports the independent TLS probe and warns about insecure engine configuration', async () => {
    const result = makeSuccessResult({ mode: 'plus' });
    Object.assign(result.data.dns_leak, {
      doh_tls_probe: {
        status: 'verified',
        server: 'dns.example.com',
        tls_verified: true,
        dns_answer_valid: true,
        router_verification_disabled: true,
      },
    });
    vi.spyOn(TachyonShellMethods, 'leakCheck').mockResolvedValue(result);
    renderLeakCheckModal();
    await vi.waitFor(() => {
      const text = collectText(getModalContent());
      expect(text).toContain(
        'A real DNS answer was received over HTTPS with certificate validation.',
      );
      expect(text).toContain(
        'TLS verification is disabled in the router DNS configuration.',
      );
    });
  });

  it('restores Plus preference and passes it to the worker', () => {
    (localStorage.getItem as any).mockReturnValue('1');
    renderLeakCheckModal();
    expect(TachyonShellMethods.leakCheck).toHaveBeenCalledWith(
      expect.any(Function),
      true,
    );
  });

  it('keeps unknown resolvers unconfirmed instead of marking them safe', async () => {
    const result = makeSuccessResult();
    Object.assign(result.data.dns_leak, {
      verdict: 'inconclusive',
      dns_servers: [
        {
          ip: '2001:db8::53',
          country: '',
          isp: 'Example',
          is_isp: false,
          verdict: 'unknown',
        },
      ],
    });
    vi.spyOn(TachyonShellMethods, 'leakCheck').mockResolvedValue(result);
    renderLeakCheckModal();
    await vi.waitFor(() => {
      const badges = findByClass(getModalContent(), 'badge').map(collectText);
      expect(badges).toContain('UNCONFIRMED');
      expect(badges).not.toContain('SAFE');
    });
  });

  it('shows router observations separately and does not claim verified encryption', async () => {
    const result = makeSuccessResult({ mode: 'plus' });
    Object.assign(result.data.dns_leak, {
      router_dns_status: 'observed',
      router_dns_servers: [
        {
          ip: '2001:db8::53',
          country: '',
          isp: 'Example',
          is_isp: false,
          verdict: 'shared',
        },
      ],
      configured_dns: [
        {
          tag: 'dns-server',
          protocol: 'https',
          server: 'dns.example.com',
          encrypted: true,
          detour: '',
        },
      ],
    });
    vi.spyOn(TachyonShellMethods, 'leakCheck').mockResolvedValue(result);
    renderLeakCheckModal();
    await vi.waitFor(() => {
      const text = collectText(getModalContent());
      expect(text).toContain('Router DNS (127.0.0.1)');
      expect(text).toContain('Encrypted protocol configured');
      expect(text).toContain('encryption on the wire is not verified');
    });
  });

  it('shows missing router observations as unavailable', async () => {
    const result = makeSuccessResult({ mode: 'plus' });
    Object.assign(result.data.dns_leak, {
      router_dns_status: 'no_data',
      router_dns_servers: [],
    });
    vi.spyOn(TachyonShellMethods, 'leakCheck').mockResolvedValue(result);
    renderLeakCheckModal();
    await vi.waitFor(() =>
      expect(collectText(getModalContent())).toContain(
        'This does not mean the connection is safe.',
      ),
    );
  });
});
