/* eslint-disable @typescript-eslint/no-explicit-any */
import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => {
  function createEl(tag: string) {
    const el: any = {
      tagName: tag.toUpperCase(),
      children: [] as any[],
      style: {} as Record<string, string>,
      textContent: '',
      innerHTML: '',
      class: '',
      value: '',
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
    documentElement: { lang: 'en' },
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

import { renderRouteExplainModal } from '../partials/renderRouteExplainModal';
import {
  runtimeClient,
  type RouteExplainResult,
} from '../../../services/runtimeClient';

function collectText(node: any): string {
  if (!node || typeof node !== 'object') return String(node ?? '');
  let text = node.textContent || '';
  for (const child of node.children || []) {
    text += collectText(child);
  }
  return text;
}

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

function getModalContent(): any {
  const calls = mocks.showModal.mock.calls;
  return calls[calls.length - 1]?.[1];
}

function makeMockRouteReport(
  overrides: Partial<RouteExplainResult> = {},
): RouteExplainResult {
  return {
    success: true,
    query: {
      client: '192.168.1.100',
      target: 'instagram.com',
      port: 443,
      proto: 'tcp',
    },
    verdict: 'proxied',
    matched_section: 'main_proxy',
    matched_rule: {
      type: 'community',
      value: 'meta',
      section: 'main_proxy',
      action: 'outbound',
    },
    stages: {
      '1_client_classification': {
        stage: 1,
        name: 'client_classification',
        client: '192.168.1.100',
        is_excluded: false,
        details: 'Client is an active LAN host (prerouting chain).',
      },
      '2_target_classification': {
        stage: 2,
        name: 'target_classification',
        target: 'instagram.com',
        target_type: 'domain',
        port: 443,
        proto: 'tcp',
        is_private_ip: false,
        details: 'Target is a public domain.',
      },
      '3_section_matching': {
        stage: 3,
        name: 'section_matching',
        matched_section: 'main_proxy',
        section_label: 'Main Proxy',
        action: 'outbound',
        rule_type: 'community',
        rule_value: 'meta',
        details: "Matched section 'main_proxy' by community 'meta'.",
      },
      '4_dns_decision': {
        stage: 4,
        name: 'dns_decision',
        mode: 'fakeip',
        resolver: 'sing-box FakeIP (127.0.0.1:5353)',
        details: 'Domain resolved by sing-box FakeIP resolver.',
      },
      '5_nftables_interception': {
        stage: 5,
        name: 'nftables_interception',
        table: 'TachyonTable',
        chain: 'prerouting',
        intercepted: true,
        fwmark: '0x1010000',
        action: 'meta mark set 0x1010000 tproxy to :1602 accept',
        details: 'Diverted via TProxy on port 1602.',
      },
      '6_policy_routing': {
        stage: 6,
        name: 'policy_routing',
        table: 'tachyon (100)',
        ip_rule: 'from all fwmark 0x1010000/0x1010000 lookup tachyon',
        route: 'local default dev lo table tachyon',
        details: 'Packet diverted to loopback.',
      },
      '7_engine_outbound': {
        stage: 7,
        name: 'engine_outbound',
        engine: 'sing-box',
        group_tag: 'main_proxy-out',
        selected_node: 'NL-Reality-1',
        node_type: 'vless',
        details: 'Engine routes packet to NL-Reality-1.',
      },
    },
    explanation: {
      en: "Traffic from 192.168.1.100 to instagram.com:443 matches section 'main_proxy'.",
      ru: 'Трафик от 192.168.1.100 к instagram.com:443 совпадает с секцией «Main Proxy».',
    },
    ...overrides,
  };
}

describe('renderRouteExplainModal', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.showModal.mockReset();
    vi.spyOn(runtimeClient, 'explainRoute').mockResolvedValue(
      makeMockRouteReport(),
    );
  });

  it('opens the modal with the Route Decision Explainer title and auto-runs trace', async () => {
    renderRouteExplainModal('instagram.com');

    expect(mocks.showModal).toHaveBeenCalledTimes(1);
    expect(mocks.showModal).toHaveBeenCalledWith(
      'Route Decision Explainer',
      expect.anything(),
    );
    expect(runtimeClient.explainRoute).toHaveBeenCalledWith(
      '192.168.1.100',
      'instagram.com',
      443,
      'tcp',
    );

    await vi.waitFor(() => {
      const text = collectText(getModalContent());
      expect(text).toContain('PROXIED');
      expect(text).toContain('NL-Reality-1');
      expect(text).toContain('Client Classification');
      expect(text).toContain('Engine Outbound');
    });
  });

  it('renders BLOCKED verdict and warning alert when target is blocked', async () => {
    vi.spyOn(runtimeClient, 'explainRoute').mockResolvedValueOnce(
      makeMockRouteReport({
        verdict: 'blocked',
        matched_rule: {
          type: 'domain_suffix',
          value: 'ads.example.com',
          section: 'adblock',
          action: 'block',
        },
      }),
    );

    renderRouteExplainModal('ads.example.com');

    await vi.waitFor(() => {
      const content = getModalContent();
      const text = collectText(content);
      expect(text).toContain('BLOCKED');
      const warnings = findByClass(content, 'alert-message warning');
      expect(warnings.length).toBeGreaterThan(0);
    });
  });

  it('shows warning alert when explainRoute returns null', async () => {
    vi.spyOn(runtimeClient, 'explainRoute').mockResolvedValueOnce(null);

    renderRouteExplainModal('unknown.example.com');

    await vi.waitFor(() => {
      const content = getModalContent();
      const text = collectText(content);
      expect(text).toContain('Could not execute route explain command');
    });
  });
});
