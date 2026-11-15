/* eslint-disable @typescript-eslint/no-explicit-any */
import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => {
  class MockMutationObserver {
    observe() {}
    disconnect() {}
    takeRecords() {
      return [];
    }
  }
  (globalThis as any).MutationObserver = MockMutationObserver;

  function createDummyElement(tag: string) {
    return {
      tagName: tag.toUpperCase(),
      children: [] as any[],
      style: {} as Record<string, string>,
      textContent: '',
      innerHTML: '',
      setAttribute() {},
      getAttribute() {
        return null;
      },
      addEventListener() {},
      querySelectorAll: function () {
        return [];
      },
      querySelector: function () {
        return null;
      },
      replaceChildren: function (...nodes: any[]) {
        (this as any).children = nodes;
      },
      appendChild: function (node: any) {
        (this as any).children.push(node);
      },
      append: function (...nodes: any[]) {
        nodes.forEach((node) => (this as any).children.push(node));
      },
      classList: {
        add() {},
        remove() {},
      },
    };
  }

  (globalThis as any).document = {
    body: createDummyElement('body') as any,
    createElement: (tag: string) => createDummyElement(tag) as any,
    createElementNS: (_ns: string, tag: string) =>
      createDummyElement(tag) as any,
    createTextNode: (text: string) => ({ textContent: text }),
    getElementById: () => null,
    querySelector: () => null,
    querySelectorAll: () => [],
    execCommand: vi.fn().mockReturnValue(true),
  };

  (globalThis as any).E = (tag: string, attrs?: any, children?: any) => {
    const el = (globalThis as any).document.createElement(tag);
    if (attrs) {
      const { style, ...rest } = attrs;
      Object.assign(el, rest);
      if (style && typeof style === 'string') {
        style.split(';').forEach((rule: string) => {
          const [k, v] = rule.split(':').map((s: string) => s.trim());
          if (k && v) {
            el.style[k] = v;
          }
        });
      } else if (style && typeof style === 'object') {
        Object.assign(el.style, style);
      }
    }
    if (children) {
      if (Array.isArray(children)) {
        children.forEach((c) => {
          if (c) el.appendChild(c);
        });
      } else {
        el.appendChild(children);
      }
    }
    return el;
  };

  (globalThis as any)._ = (str: string) => str;

  const showModal = vi.fn();
  const hideModal = vi.fn();
  (globalThis as any).ui = {
    showModal,
    hideModal,
  };

  return {
    showModal,
    hideModal,
  };
});

vi.mock('../../../services/stabilityClient', () => ({
  stabilityClient: {
    getReport: vi.fn().mockResolvedValue({
      timestamp: 1790544910,
      health: {
        score: 95,
        grade: 'optimal',
        penalties: [],
      },
      uptimes: {
        system: { seconds: 344625, pretty: '3d 23h 43m' },
        daemons: {
          'sing-box': {
            running: true,
            pid: 8914,
            uptime_seconds: 2053,
            pretty: '34m 13s',
          },
          watchdog: {
            running: true,
            pid: 4759,
            uptime_seconds: 16598,
            pretty: '4h 36m',
          },
        },
      },
      restarts_and_flaps: {
        wan_flaps: 0,
        watchdog_restarts: 0,
        engine_crashes: 0,
        dnsmasq_restarts: 0,
        dns_failovers: 0,
        config_rollbacks: 0,
      },
      resources: {
        memory: {
          total_kb: 744040,
          free_kb: 428884,
          available_kb: 529876,
          used_kb: 214164,
          used_pct: 28,
          pressure_level: 'normal',
          swap_total_kb: 0,
          swap_free_kb: 0,
          swap_used_kb: 0,
          daemons_rss_kb: { 'sing-box': 104416, watchdog: 3944 },
        },
        file_descriptors: {
          system_allocated: 736,
          system_max: 70768,
          system_used_pct: 1,
          daemons: { 'sing-box': 113, watchdog: 27 },
        },
        orphans: { count: 0, orphans: [] },
      },
      jobs: {
        total_jobs: 0,
        running_jobs: 0,
        failed_jobs: 0,
        cancelled_jobs: 0,
        last_failed_job: null,
      },
      server_fleet: {
        total_servers: 131,
        healthy_count: 61,
        unhealthy_count: 0,
        untested_count: 70,
        avg_latency_ms: 144,
        best_server: {
          tag: 'SP 🇩🇪 GERMANY GRPC #7',
          latency_ms: 144,
          section: 'Main',
          type: 'VLESS',
        },
        sections: { Main: 131 },
      },
      recent_incidents: [],
    }),
  },
}));

vi.mock('../../../services/serverStatsClient', () => ({
  serverStatsClient: {
    getSummary: vi.fn().mockResolvedValue({
      total_servers: 131,
      healthy_count: 61,
      unhealthy_count: 0,
      untested_count: 70,
      avg_latency_ms: 144,
      best_server: {
        tag: 'SP 🇩🇪 GERMANY GRPC #7',
        latency_ms: 144,
        section: 'Main',
        type: 'VLESS',
      },
      worst_server: null,
      sections: { Main: 131 },
      protocols: { VLESS: 131 },
      last_updated: 1790544299,
      servers: [],
    }),
    getBestCandidates: vi.fn().mockResolvedValue([
      {
        tag: 'SP 🇩🇪 GERMANY GRPC #7',
        name: 'SP 🇩🇪 GERMANY GRPC #7',
        type: 'VLESS',
        section: 'Main',
        last_status: 'ok',
        last_latency: 144,
        last_checked: 1790544299,
        last_error: '',
        total_probes: 2,
        successful_probes: 2,
        failed_probes: 0,
        consecutive_failures: 0,
        avg_latency: 144,
        min_latency: 144,
        max_latency: 144,
        jitter: 0,
        success_rate: 100,
      },
    ]),
    probe: vi.fn().mockResolvedValue({
      tag: 'SP 🇩🇪 GERMANY GRPC #7',
      status: 'ok',
      latency_ms: 144,
      avg_latency_ms: 144,
      success_rate: 100,
      error: '',
    }),
    probeAll: vi.fn().mockResolvedValue({
      total_probed: 131,
      successful: 61,
      failed: 0,
      results: [],
    }),
    reset: vi.fn().mockResolvedValue(true),
  },
}));

import { renderStabilityModal } from '../partials/renderStabilityModal';

describe('renderStabilityModal', () => {
  beforeEach(() => {
    mocks.showModal.mockReset();
    mocks.hideModal.mockReset();
  });

  it('opens stability report modal and fetches report data', async () => {
    await renderStabilityModal();

    expect(mocks.showModal).toHaveBeenCalled();
    const title = mocks.showModal.mock.calls[0][0];
    expect(title).toContain('System Stability & Server Fleet Report');

    const modalContent = mocks.showModal.mock.calls[0][1];
    expect(modalContent).toBeDefined();
    expect(modalContent.classList).toBeDefined();
  });
});
