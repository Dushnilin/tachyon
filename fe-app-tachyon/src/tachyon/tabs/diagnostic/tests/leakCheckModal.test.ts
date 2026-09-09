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
      querySelectorAll: () => [],
      querySelector: () => null,
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
    body: {} as any,
    createElement: (tag: string) => createDummyElement(tag) as any,
    createElementNS: (_ns: string, tag: string) =>
      createDummyElement(tag) as any,
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

  (globalThis as any).rpc = { declare: vi.fn() };
  (globalThis as any).uci = { sections: vi.fn().mockResolvedValue([]) };
  (globalThis as any).localStorage = { getItem: vi.fn(), setItem: vi.fn() };

  const showModal = vi.fn();
  const hideModal = vi.fn();
  (globalThis as any).ui = {
    showModal,
    hideModal,
    addNotification: vi.fn(),
  };

  return {
    showModal,
    hideModal,
  };
});

import { renderLeakCheckModal } from '../partials/renderLeakCheckModal';
import { TachyonShellMethods } from '../../../methods/shell';

describe('renderLeakCheckModal', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.showModal.mockReset();
    vi.spyOn(TachyonShellMethods, 'leakCheck').mockResolvedValue({
      success: true,
      data: {
        ip_leak: {
          leaked: false,
          direct_ip: '95.173.136.25',
          direct_country: 'Russia',
          direct_isp: 'Rostelecom',
          proxy_ip: '185.220.101.5',
          proxy_country: 'Netherlands',
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
      },
    });
  });

  it('renders and displays the IP & DNS Leak Detection modal', () => {
    renderLeakCheckModal();

    expect(mocks.showModal).toHaveBeenCalledTimes(1);
    expect(mocks.showModal).toHaveBeenCalledWith(
      expect.stringContaining('Tachyon IP & DNS Leak Detection'),
      expect.anything(),
    );
  });

  it('calls TachyonShellMethods.leakCheck on start', async () => {
    const leakCheckSpy = vi.spyOn(TachyonShellMethods, 'leakCheck');
    renderLeakCheckModal();

    expect(leakCheckSpy).toHaveBeenCalledTimes(1);
  });

  it('handles leak detection when IP is leaked', async () => {
    vi.spyOn(TachyonShellMethods, 'leakCheck').mockResolvedValue({
      success: true,
      data: {
        ip_leak: {
          leaked: true,
          direct_ip: '95.173.136.25',
          proxy_ip: '95.173.136.25',
          proxy_online: true,
        },
        dns_leak: {
          dns_leaked: true,
          direct_ip: '95.173.136.25',
          proxy_ip: '95.173.136.25',
          dns_servers: [
            {
              ip: '212.188.4.10',
              country: 'Russia',
              isp: 'Rostelecom',
              is_isp: true,
            },
          ],
          direct_dns_servers: [],
          proxy_online: true,
        },
      },
    });

    renderLeakCheckModal();
    expect(mocks.showModal).toHaveBeenCalledTimes(1);
  });

  it('handles offline proxy gracefully', async () => {
    vi.spyOn(TachyonShellMethods, 'leakCheck').mockResolvedValue({
      success: true,
      data: {
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
      },
    });

    renderLeakCheckModal();
    expect(mocks.showModal).toHaveBeenCalledTimes(1);
  });
});
