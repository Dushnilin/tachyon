/* eslint-disable @typescript-eslint/no-explicit-any */
import { describe, it, expect, vi, beforeEach, beforeAll } from 'vitest';

class MockMutationObserver {
  observe() {}
  disconnect() {}
  takeRecords() {
    return [];
  }
}
globalThis.MutationObserver = MockMutationObserver as any;

function createDummyElement(tag: string) {
  const children: any[] = [];
  return {
    tagName: tag.toUpperCase(),
    children,
    childNodes: children,
    style: {} as Record<string, string>,
    className: '',
    get textContent(): string {
      let text = '';
      for (const c of children) {
        if (typeof c === 'string' || typeof c === 'number') {
          text += c;
        } else if (c && typeof c.textContent === 'string') {
          text += c.textContent;
        }
      }
      return text;
    },
    set textContent(val: string) {
      children.length = 0;
      if (val) children.push(val);
    },
    setAttribute(name: string, val: string) {
      (this as any)[name] = val;
    },
    getAttribute(name: string) {
      return (this as any)[name] ?? null;
    },
    querySelectorAll(selector: string): any[] {
      const results: any[] = [];
      function traverse(node: any) {
        if (!node || typeof node !== 'object') return;
        if (selector.startsWith('.')) {
          const targetClass = selector.slice(1);
          const classes = (node.class || node.className || '').split(/\s+/);
          if (classes.includes(targetClass)) {
            results.push(node);
          }
        }
        if (selector === 'button' && node.tagName === 'BUTTON') {
          results.push(node);
        }
        if (selector === 'svg' && node.tagName === 'SVG') {
          results.push(node);
        }
        if (Array.isArray(node.children)) {
          for (const child of node.children) {
            traverse(child);
          }
        }
      }
      traverse(this);
      return results;
    },
    querySelector(selector: string): any {
      return this.querySelectorAll(selector)[0] || null;
    },
    appendChild(node: any) {
      children.push(node);
    },
  };
}

globalThis.document = {
  body: createDummyElement('body') as any,
  createElement: (tag: string) => createDummyElement(tag) as any,
  createElementNS: (_ns: string, tag: string) => createDummyElement(tag) as any,
  querySelectorAll: () => [],
  querySelector: () => null,
  getElementById: () => null,
} as any;

(globalThis as any).rpc = { declare: vi.fn() };
(globalThis as any).uci = { sections: vi.fn().mockResolvedValue([]) };
(globalThis as any).localStorage = { getItem: vi.fn(), setItem: vi.fn() };

(globalThis as any).E = (tag: string, attrs?: any, children?: any) => {
  const el = (globalThis as any).document.createElement(tag);
  if (attrs) {
    Object.assign(el, attrs);
  }
  if (children) {
    const list = Array.isArray(children) ? children : [children];
    for (const child of list) {
      if (child !== null && child !== undefined && child !== '') {
        el.appendChild(child);
      }
    }
  }
  return el;
};

let renderSections: any;

describe('renderSections', () => {
  beforeAll(async () => {
    const mod = await import('../renderSections');
    renderSections = mod.renderSections;
  });

  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('renders service section without serviceStatus as a clean service card without latency button', () => {
    const section: any = {
      code: 'discord',
      sectionName: 'discord',
      displayName: 'Discord',
      action: 'zapret2',
      withTagSelect: false,
      serviceStatus: undefined,
      outbounds: [
        {
          code: 'discord',
          displayName: 'Unknown',
          latency: 0,
          type: 'ZAPRET2',
          selected: true,
          canCopyLink: false,
        },
      ],
    };

    const el = renderSections({
      loading: false,
      failed: false,
      section,
      onTestLatency: vi.fn(),
      onChooseOutbound: vi.fn(),
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowPriorityInfo: vi.fn(),
      onUpdateSubscription: vi.fn(),
      latencyFetching: false,
      subscriptionUpdating: false,
    });

    const latencyButtons = el.querySelectorAll(
      '.dashboard-sections-grid-item-test-latency',
    );
    expect(latencyButtons).toHaveLength(0);

    const buttons = el.querySelectorAll('button');
    expect(buttons).toHaveLength(0);

    // Should not render chevron svg
    const svgs = el.querySelectorAll('svg');
    expect(svgs).toHaveLength(0);

    // Should not render outbound grid
    const outboundGrid = el.querySelectorAll(
      '.tachyon_dashboard-page__outbound-grid',
    );
    expect(outboundGrid).toHaveLength(0);
  });

  it('renders service section with serviceStatus as a service card without latency button', () => {
    const section: any = {
      code: 'youtube',
      sectionName: 'youtube',
      displayName: 'Youtube',
      action: 'zapret2',
      withTagSelect: false,
      serviceStatus: {
        serviceType: 'zapret2',
        configured: true,
        ready: true,
        conflict: false,
        runningProcesses: 1,
        expectedProcesses: 1,
        restartCount: 0,
        unstable: false,
        statusMessage: 'zapret2 provider status is normal',
      },
      outbounds: [],
    };

    const el = renderSections({
      loading: false,
      failed: false,
      section,
      onTestLatency: vi.fn(),
      onChooseOutbound: vi.fn(),
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowPriorityInfo: vi.fn(),
      onUpdateSubscription: vi.fn(),
      latencyFetching: false,
      subscriptionUpdating: false,
    });

    const latencyButtons = el.querySelectorAll(
      '.dashboard-sections-grid-item-test-latency',
    );
    expect(latencyButtons).toHaveLength(0);

    const buttons = el.querySelectorAll('button');
    expect(buttons).toHaveLength(0);
  });

  it('renders zapret and byedpi service sections without latency button', () => {
    for (const action of ['zapret', 'byedpi']) {
      const section: any = {
        code: action,
        sectionName: action,
        displayName: action.toUpperCase(),
        action,
        withTagSelect: false,
        outbounds: [],
      };

      const el = renderSections({
        loading: false,
        failed: false,
        section,
        onTestLatency: vi.fn(),
        onChooseOutbound: vi.fn(),
        onCopyOutbound: vi.fn(),
        onShowUrlTestInfo: vi.fn(),
        onShowPriorityInfo: vi.fn(),
        onUpdateSubscription: vi.fn(),
        latencyFetching: false,
        subscriptionUpdating: false,
      });

      const latencyButtons = el.querySelectorAll(
        '.dashboard-sections-grid-item-test-latency',
      );
      expect(latencyButtons).toHaveLength(0);
    }
  });

  it('renders latency test button for proxy outbound sections with outbounds', () => {
    const section: any = {
      code: 'proxy-group',
      sectionName: 'main',
      displayName: 'Main Proxy',
      action: 'connection',
      withTagSelect: true,
      outbounds: [
        {
          code: 'node-1',
          displayName: 'Node 1',
          latency: 120,
          type: 'VLESS',
          selected: true,
        },
      ],
    };

    const el = renderSections({
      loading: false,
      failed: false,
      section,
      onTestLatency: vi.fn(),
      onChooseOutbound: vi.fn(),
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowPriorityInfo: vi.fn(),
      onUpdateSubscription: vi.fn(),
      latencyFetching: false,
      subscriptionUpdating: false,
    });

    const latencyButtons = el.querySelectorAll(
      '.dashboard-sections-grid-item-test-latency',
    );
    expect(latencyButtons).toHaveLength(1);
  });

  it('does not render latency test button for empty proxy section', () => {
    const section: any = {
      code: 'empty-group',
      sectionName: 'empty',
      displayName: 'Empty Group',
      action: 'connection',
      withTagSelect: false,
      outbounds: [],
    };

    const el = renderSections({
      loading: false,
      failed: false,
      section,
      onTestLatency: vi.fn(),
      onChooseOutbound: vi.fn(),
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowPriorityInfo: vi.fn(),
      onUpdateSubscription: vi.fn(),
      latencyFetching: false,
      subscriptionUpdating: false,
    });

    const latencyButtons = el.querySelectorAll(
      '.dashboard-sections-grid-item-test-latency',
    );
    expect(latencyButtons).toHaveLength(0);
  });

  it('renders latency test button and connection node item for Mieru section', () => {
    const section: any = {
      code: 'mieru-out',
      sectionName: 'mieru',
      displayName: 'My Mieru',
      action: 'mieru',
      withTagSelect: false,
      outbounds: [
        {
          code: 'mieru-out',
          displayName: 'My Mieru',
          latency: 65,
          type: 'Mieru',
          selected: true,
          runtimeAvailable: true,
        },
      ],
    };

    const el = renderSections({
      loading: false,
      failed: false,
      section,
      onTestLatency: vi.fn(),
      onChooseOutbound: vi.fn(),
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowPriorityInfo: vi.fn(),
      onUpdateSubscription: vi.fn(),
      latencyFetching: false,
      subscriptionUpdating: false,
    });

    const latencyButtons = el.querySelectorAll(
      '.dashboard-sections-grid-item-test-latency',
    );
    expect(latencyButtons).toHaveLength(1);
    expect(latencyButtons[0].tagName).toBe('BUTTON');
  });

  it('renders clickable latency badge for proxy outbound and calls onTestSingleOutbound when clicked', () => {
    const onTestSingleOutbound = vi.fn();
    const section: any = {
      code: 'proxy',
      sectionName: 'proxy',
      displayName: 'Proxy Section',
      action: 'proxy',
      withTagSelect: true,
      outbounds: [
        {
          code: 'vless-1',
          displayName: 'VLESS Server',
          latency: 120,
          type: 'VLESS',
          selected: false,
        },
      ],
    };

    const el = renderSections({
      loading: false,
      failed: false,
      section,
      onTestLatency: vi.fn(),
      onChooseOutbound: vi.fn(),
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowPriorityInfo: vi.fn(),
      onUpdateSubscription: vi.fn(),
      onTestSingleOutbound,
      latencyFetching: false,
      subscriptionUpdating: false,
    });

    const badge = el.querySelector(
      '.tachyon_dashboard-page__outbound-grid__item__latency--clickable',
    ) as HTMLElement;
    expect(badge).not.toBeNull();
    expect(badge.textContent).toContain('120ms');

    badge.click();
    expect(onTestSingleOutbound).toHaveBeenCalledWith('proxy', 'vless-1');
  });

  it('renders testing state when testingOutboundCodes indicates outbound is being tested', () => {
    const section: any = {
      code: 'proxy',
      sectionName: 'proxy',
      displayName: 'Proxy Section',
      action: 'proxy',
      withTagSelect: true,
      outbounds: [
        {
          code: 'vless-1',
          displayName: 'VLESS Server',
          latency: 120,
          type: 'VLESS',
          selected: false,
        },
      ],
    };

    const el = renderSections({
      loading: false,
      failed: false,
      section,
      onTestLatency: vi.fn(),
      onChooseOutbound: vi.fn(),
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowPriorityInfo: vi.fn(),
      onUpdateSubscription: vi.fn(),
      testingOutboundCodes: { 'vless-1': true },
      latencyFetching: false,
      subscriptionUpdating: false,
    });

    const testingBadge = el.querySelector(
      '.tachyon_dashboard-page__outbound-grid__item__latency--testing',
    );
    expect(testingBadge).not.toBeNull();
    expect(testingBadge?.textContent).toContain('Checking...');
  });

  it('renders -1 latency as red Not responding instead of green -1ms', () => {
    const section: any = {
      code: 'proxy',
      sectionName: 'proxy',
      displayName: 'Proxy Section',
      action: 'proxy',
      withTagSelect: true,
      outbounds: [
        {
          code: 'vless-failed',
          displayName: 'Failed Node',
          latency: -1,
          type: 'VLESS',
          selected: false,
        },
        {
          code: 'vless-ok',
          displayName: 'OK Node',
          latency: 150,
          type: 'VLESS',
          selected: true,
        },
      ],
    };

    const el = renderSections({
      loading: false,
      failed: false,
      section,
      onTestLatency: vi.fn(),
      onChooseOutbound: vi.fn(),
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowPriorityInfo: vi.fn(),
      onUpdateSubscription: vi.fn(),
      latencyFetching: false,
      subscriptionUpdating: false,
    });

    const redBadge = el.querySelector(
      '.tachyon_dashboard-page__outbound-grid__item__latency--red',
    );
    expect(redBadge).not.toBeNull();
    expect(redBadge?.textContent).toBe('Not responding');
    expect(redBadge?.textContent).not.toContain('-1');

    const greenBadge = el.querySelector(
      '.tachyon_dashboard-page__outbound-grid__item__latency--green',
    );
    expect(greenBadge).not.toBeNull();
    expect(greenBadge?.textContent).toBe('150ms');
  });
});
