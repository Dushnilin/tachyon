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
    get classList() {
      const self = this as any;
      return {
        contains(c: string) {
          const list = (self.class || self.className || '').split(/\s+/);
          return list.includes(c);
        },
      };
    },
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
          const targetClasses = selector.split('.').filter(Boolean);
          const classes = (node.class || node.className || '').split(/\s+/);
          if (targetClasses.every((tc: string) => classes.includes(tc))) {
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
let renderGlobalConfigErrorsBanner: any;

describe('renderSections', () => {
  beforeAll(async () => {
    const mod = await import('../renderSections');
    renderSections = mod.renderSections;
    renderGlobalConfigErrorsBanner = mod.renderGlobalConfigErrorsBanner;
  });

  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('renders service section without serviceStatus as a clean service card without latency button', () => {
    const section: any = {
      code: 'discord',
      sectionName: 'discord',
      displayName: 'Discord',
      action: 'desync',
      withTagSelect: false,
      serviceStatus: undefined,
      outbounds: [
        {
          code: 'discord',
          displayName: 'Unknown',
          latency: 0,
          type: 'DESYNC',
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
      action: 'desync',
      withTagSelect: false,
      serviceStatus: {
        serviceType: 'desync',
        configured: true,
        ready: true,
        conflict: false,
        runningProcesses: 1,
        expectedProcesses: 1,
        restartCount: 0,
        unstable: false,
        statusMessage: 'desync status is normal',
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

  it('renders desync and fptn service sections without latency button', () => {
    for (const action of ['desync', 'fptn']) {
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

  it('renders prefix badge when outbound.prefix is present', () => {
    const section: any = {
      sectionName: 'proxy',
      displayName: 'Proxy',
      action: 'proxy',
      withTagSelect: true,
      outbounds: [
        {
          code: 'vless-1',
          displayName: 'France',
          prefix: 'Geodema Network',
          latency: 158,
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
      latencyFetching: false,
      subscriptionUpdating: false,
    });

    const prefixBadge = el.querySelector(
      '.tachyon_dashboard-page__outbound-grid__item__prefix-badge',
    );
    expect(prefixBadge).not.toBeNull();
    expect(prefixBadge?.textContent).toBe('Geodema Network');
  });

  it('renders connection node (AWG) with collapsible header and check connection action', () => {
    const section: any = {
      sectionName: 'AWG',
      displayName: 'AMNEZIA',
      action: 'awg',
      outbounds: [
        {
          code: 'awg-out',
          displayName: 'AmneziaWG 3.0',
          latency: 155,
          runtimeAvailable: true,
          selected: true,
        },
      ],
    };

    // 1. Collapsed state
    const collapsedEl = renderSections({
      loading: false,
      failed: false,
      section,
      isCollapsed: true,
      onTestLatency: vi.fn(),
      onChooseOutbound: vi.fn(),
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowPriorityInfo: vi.fn(),
      onUpdateSubscription: vi.fn(),
      latencyFetching: false,
      subscriptionUpdating: false,
    });

    const titleSec = collapsedEl.querySelector(
      '.tachyon_dashboard-page__outbound-section__title-section',
    );
    expect(titleSec).not.toBeNull();
    expect(titleSec?.textContent).toContain('AMNEZIA');
    expect(titleSec?.textContent).toContain('AmneziaWG');
    expect(titleSec?.textContent).toContain('155ms');
    expect(titleSec?.textContent).toContain('Check Connection');
    expect(
      collapsedEl.querySelector('.tachyon_dashboard-page__outbound-grid'),
    ).toBeNull();

    // 2. Expanded state
    const expandedEl = renderSections({
      loading: false,
      failed: false,
      section,
      isCollapsed: false,
      onTestLatency: vi.fn(),
      onChooseOutbound: vi.fn(),
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowPriorityInfo: vi.fn(),
      onUpdateSubscription: vi.fn(),
      latencyFetching: false,
      subscriptionUpdating: false,
    });

    const expandedTitleSec = expandedEl.querySelector(
      '.tachyon_dashboard-page__outbound-section__title-section',
    );
    expect(expandedTitleSec).not.toBeNull();
    expect(expandedTitleSec?.textContent).toContain('AMNEZIA');
    expect(expandedTitleSec?.textContent).toContain('AmneziaWG');
    expect(expandedTitleSec?.textContent).toContain('Check Connection');

    const grid = expandedEl.querySelector(
      '.tachyon_dashboard-page__outbound-grid',
    );
    expect(grid).not.toBeNull();
    expect(grid?.textContent).toContain('Connected');
    expect(grid?.textContent).toContain('AmneziaWG 3.0');
    expect(grid?.textContent).toContain('155 ms');
  });

  it('frames a quarantined section in red with a Has errors badge next to its name', () => {
    const base: any = {
      code: 'proxy',
      sectionName: 'proxy',
      displayName: 'Proxy Section',
      action: 'connection',
      withTagSelect: true,
      outbounds: [
        {
          code: 'vless-1',
          displayName: 'VLESS Server',
          latency: 120,
          type: 'VLESS',
          selected: true,
        },
      ],
    };
    const props = {
      loading: false,
      failed: false,
      onTestLatency: vi.fn(),
      onChooseOutbound: vi.fn(),
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowPriorityInfo: vi.fn(),
      onUpdateSubscription: vi.fn(),
      latencyFetching: false,
      subscriptionUpdating: false,
    };

    const broken = renderSections({
      ...props,
      section: {
        ...base,
        configError: 'outbounds[1]: missing required field',
      },
    });
    expect(
      broken.querySelector('.tachyon_dashboard-page__outbound-section--error'),
    ).not.toBeNull();
    const badge = broken.querySelector(
      '.tachyon_dashboard-page__outbound-section__config-error-badge',
    );
    expect(badge).not.toBeNull();
    expect(badge.textContent).toBe('Has errors');
    expect(badge.title).toBe('outbounds[1]: missing required field');

    const healthy = renderSections({ ...props, section: base });
    expect(
      healthy.querySelector('.tachyon_dashboard-page__outbound-section--error'),
    ).toBeNull();
    expect(
      healthy.querySelector(
        '.tachyon_dashboard-page__outbound-section__config-error-badge',
      ),
    ).toBeNull();
  });

  it('groups subscription outbounds and standalone outbounds under collapsible headers', () => {
    const onToggleSourceGroupCollapse = vi.fn();
    const section: any = {
      code: 'proxy-out',
      sectionName: 'proxy',
      displayName: 'Multi-Source Proxy',
      action: 'connection',
      withTagSelect: true,
      subscriptionSourceCount: 2,
      subscriptionMetadata: [
        {
          title: 'Provider Alpha',
          sourceIndex: 1,
          traffic: { used: 1024, total: 2048 },
        },
        {
          title: 'Provider Beta',
          sourceIndex: 2,
          traffic: { used: 512, total: 4096 },
        },
      ],
      outbounds: [
        {
          code: 'proxy-urltest-out',
          displayName: 'Fastest',
          latency: 40,
          type: 'URLTest',
          selected: true,
          urlTestInfo: {
            code: 'proxy-urltest-out',
            displayName: 'Fastest',
            outbounds: [],
          },
        },
        {
          code: 'sub1-node1',
          displayName: 'Alpha DE',
          latency: 40,
          type: 'VLESS',
          selected: false,
          sourceGroup: 'sub:1',
        },
        {
          code: 'sub2-node1',
          displayName: 'Beta NL',
          latency: 60,
          type: 'VLESS',
          selected: false,
          sourceGroup: 'sub:2',
        },
        {
          code: 'manual-1',
          displayName: 'My Personal VPS',
          latency: 25,
          type: 'VLESS',
          selected: false,
          sourceGroup: 'manual',
        },
      ],
    };

    const expanded = renderSections({
      loading: false,
      failed: false,
      section,
      collapsedSourceGroups: new Set(),
      onToggleSourceGroupCollapse,
      onTestLatency: vi.fn(),
      onChooseOutbound: vi.fn(),
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowPriorityInfo: vi.fn(),
      onUpdateSubscription: vi.fn(),
      latencyFetching: false,
      subscriptionUpdating: false,
    });

    const headers = expanded.querySelectorAll(
      '.tachyon_dashboard-page__subscription-meta--collapsible',
    );
    expect(headers).toHaveLength(3);
    expect(headers[0].textContent).toContain('Provider Alpha');
    expect(headers[1].textContent).toContain('Provider Beta');
    expect(headers[2].textContent).toContain('Standalone servers');

    // Must not duplicate subscription metadata headers at the top of the section
    const allMetaBanners = expanded.querySelectorAll(
      '.tachyon_dashboard-page__subscription-meta',
    );
    expect(allMetaBanners).toHaveLength(3);

    const items = expanded.querySelectorAll(
      '.tachyon_dashboard-page__outbound-grid__item',
    );
    expect(items).toHaveLength(4);

    // Collapsing sub:1 hides its server card while keeping URLTest, sub:2, and manual visible
    const collapsedSub1 = renderSections({
      loading: false,
      failed: false,
      section,
      collapsedSourceGroups: new Set(['subgrp:proxy-out:sub:1']),
      onToggleSourceGroupCollapse,
      onTestLatency: vi.fn(),
      onChooseOutbound: vi.fn(),
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowPriorityInfo: vi.fn(),
      onUpdateSubscription: vi.fn(),
      latencyFetching: false,
      subscriptionUpdating: false,
    });

    const visibleItems = collapsedSub1.querySelectorAll(
      '.tachyon_dashboard-page__outbound-grid__item',
    );
    expect(visibleItems).toHaveLength(3);
  });

  it('renders multi-config AWG section (withTagSelect=true) as selectable server cards rather than single connection node', () => {
    const section: any = {
      code: 'awg-out',
      sectionName: 'awg',
      displayName: 'AWG Pool',
      action: 'awg',
      withTagSelect: true,
      outbounds: [
        {
          code: 'awg-urltest-out',
          displayName: 'AWG Pool',
          latency: 35,
          type: 'URLTest',
          selected: true,
          urlTestInfo: {
            code: 'awg-urltest-out',
            displayName: 'AWG Pool',
            selectedName: 'AWG-DE-1',
            outbounds: [],
          },
        },
        {
          code: 'awg-out/AWG-DE-1',
          displayName: 'AWG-DE-1',
          latency: 35,
          type: 'AmneziaWG',
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
      latencyFetching: false,
      subscriptionUpdating: false,
    });

    const selectable = el.querySelectorAll(
      '.tachyon_dashboard-page__outbound-grid__item--selectable',
    );
    expect(selectable).toHaveLength(1);
    expect(selectable[0].textContent).toContain('AWG-DE-1');
  });

  it('renders country chips with localized names, flag emojis, count pill badges and colored latency badges', () => {
    const section: any = {
      code: 'proxy-out',
      sectionName: 'proxy',
      displayName: 'Proxy',
      withTagSelect: true,
      countryGrouping: 'chips',
      outbounds: [
        {
          code: 'node-de-1',
          displayName: '🇩🇪 Германия 01',
          latency: 42,
          selected: true,
          country: 'DE',
        },
        {
          code: 'node-de-2',
          displayName: '🇩🇪 Германия 02',
          latency: 85,
          selected: false,
          country: 'DE',
        },
        {
          code: 'node-us-1',
          displayName: '🇺🇸 США Miami',
          latency: 180,
          selected: false,
          country: 'US',
        },
      ],
    };

    const el = renderSections({
      loading: false,
      failed: false,
      section,
      countryGrouping: 'chips',
      onTestLatency: vi.fn(),
      onChooseOutbound: vi.fn(),
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowPriorityInfo: vi.fn(),
      onUpdateSubscription: vi.fn(),
      latencyFetching: false,
      subscriptionUpdating: false,
    });

    const chipsContainer = el.querySelector(
      '.tachyon_dashboard-page__country-chips',
    );
    expect(chipsContainer).toBeTruthy();

    const chips = chipsContainer!.querySelectorAll(
      '.tachyon_dashboard-page__country-chip',
    );
    // "Все" + "Германия" + "США"
    expect(chips).toHaveLength(3);

    // "Все" chip
    const allChip = chips[0];
    expect(
      allChip.classList.contains(
        'tachyon_dashboard-page__country-chip--active',
      ),
    ).toBe(true);
    expect(
      allChip.querySelector('.tachyon_dashboard-page__country-chip__name')
        ?.textContent,
    ).toMatch(/Все|All/);
    expect(
      allChip.querySelector('.tachyon_dashboard-page__country-chip__count')
        ?.textContent,
    ).toBe('3');

    // Country chips have flag emoji with Twemoji class, localized country name, count badge and latency badge
    const names = Array.from(
      chipsContainer!.querySelectorAll(
        '.tachyon_dashboard-page__country-chip__name',
      ),
    ).map((n: any) => n.textContent);
    expect(names).toContain('Германия');
    expect(names).toContain('США');

    const flags = chipsContainer!.querySelectorAll(
      '.tachyon_dashboard-page__country-chip__flag.tachyon_dashboard-page__flag-emoji',
    );
    expect(flags.length).toBeGreaterThanOrEqual(2);

    const counts = Array.from(
      chipsContainer!.querySelectorAll(
        '.tachyon_dashboard-page__country-chip__count',
      ),
    ).map((c: any) => c.textContent);
    expect(counts).toEqual(['3', '2', '1']);

    const fastLatency = chipsContainer!.querySelector(
      '.tachyon_dashboard-page__country-chip__latency--fast',
    );
    expect(fastLatency).toBeTruthy();
    expect(fastLatency?.textContent).toBe('42ms');

    const mediumLatency = chipsContainer!.querySelector(
      '.tachyon_dashboard-page__country-chip__latency--medium',
    );
    expect(mediumLatency).toBeTruthy();
    expect(mediumLatency?.textContent).toBe('180ms');
  });

  it('renders selected-badge on active outbounds (both auto-groups and regular nodes)', () => {
    const section: any = {
      code: 'proxy-out',
      sectionName: 'proxy',
      displayName: 'Proxy',
      withTagSelect: true,
      countryGrouping: 'none',
      outbounds: [
        {
          code: 'fastest-auto',
          displayName: '⚡ Fastest',
          latency: 28,
          selected: true,
          urlTestInfo: {
            code: 'fastest-auto',
            displayName: 'Fastest',
            selectedName: 'DE-01',
            outbounds: [],
          },
        },
        {
          code: 'node-de-1',
          displayName: '🇩🇪 Server 1',
          latency: 42,
          selected: false,
        },
      ],
    };

    const el = renderSections({
      loading: false,
      failed: false,
      section,
      countryGrouping: 'none',
      onTestLatency: vi.fn(),
      onChooseOutbound: vi.fn(),
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowPriorityInfo: vi.fn(),
      onUpdateSubscription: vi.fn(),
      latencyFetching: false,
      subscriptionUpdating: false,
    });

    const activeItem = el.querySelector(
      '.tachyon_dashboard-page__outbound-grid__item--active',
    );
    expect(activeItem).toBeTruthy();

    const selectedBadge = activeItem!.querySelector(
      '.tachyon_dashboard-page__outbound-grid__item__selected-badge',
    );
    expect(selectedBadge?.querySelector('svg')).toBeTruthy();
    expect(selectedBadge?.textContent).toMatch(/(Активен|Active)/);
  });

  it('renders region tabs bar when configured with regions mode', () => {
    const section: any = {
      code: 'proxy-multi-reg',
      sectionName: 'proxy',
      displayName: 'Proxy',
      withTagSelect: true,
      dashboardSettings: {
        countryGrouping: 'chips',
        chipsGrouping: 'regions',
      },
      outbounds: [
        { code: 'de-1', displayName: '🇩🇪 Germany', latency: 40, country: 'DE' },
        { code: 'us-1', displayName: '🇺🇸 Miami', latency: 150, country: 'US' },
        { code: 'ae-1', displayName: '🇦🇪 Dubai', latency: 110, country: 'AE' },
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

    // Check region tabs bar
    const regionBar = el.querySelector('.tachyon_dashboard-page__region-bar');
    expect(regionBar).toBeTruthy();
    const regionTabs = el.querySelectorAll(
      '.tachyon_dashboard-page__region-tab',
    );
    // All + Europe + Asia + Americas = 4
    expect(regionTabs.length).toBe(4);
  });

  it('renders smart_top mode with active country, top locations and divider', () => {
    const section: any = {
      code: 'proxy-smart',
      sectionName: 'proxy',
      displayName: 'Proxy',
      withTagSelect: true,
      dashboardSettings: {
        countryGrouping: 'chips',
        chipsGrouping: 'smart_top',
      },
      outbounds: [
        {
          code: 'de-1',
          displayName: '🇩🇪 Germany 1',
          latency: 40,
          country: 'DE',
        },
        {
          code: 'de-2',
          displayName: '🇩🇪 Germany 2',
          latency: 40,
          country: 'DE',
        },
        { code: 'us-1', displayName: '🇺🇸 US 1', latency: 140, country: 'US' },
        { code: 'us-2', displayName: '🇺🇸 US 2', latency: 140, country: 'US' },
        { code: 'us-3', displayName: '🇺🇸 US 3', latency: 140, country: 'US' },
        {
          code: 'nl-1',
          displayName: '🇳🇱 Netherlands 1',
          latency: 50,
          country: 'NL',
        },
        {
          code: 'cy-1',
          displayName: '🇨🇾 Cyprus 1',
          latency: 80,
          country: 'CY',
          selected: true,
        },
        {
          code: 'fr-1',
          displayName: '🇫🇷 France 1',
          latency: 45,
          country: 'FR',
        },
        {
          code: 'at-1',
          displayName: '🇦🇹 Austria 1',
          latency: 60,
          country: 'AT',
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

    const divider = el.querySelector(
      '.tachyon_dashboard-page__country-chip-divider',
    );
    expect(divider).toBeTruthy();
  });

  it('renders active badge in section header when collapsed with auto selection mode', () => {
    const section = {
      code: 'main',
      sectionName: 'main',
      displayName: 'main',
      withTagSelect: true,
      outbounds: [
        {
          code: 'priority-tag',
          displayName: 'priority',
          selected: true,
          latency: 27,
          priorityInfo: {
            code: 'priority-tag',
            displayName: 'priority',
            selectedName: '🇩🇪 ⚡ Германия',
            outbounds: [
              {
                code: 'de-1',
                displayName: '🇩🇪 ⚡ Германия',
                selected: true,
                latency: 27,
              },
            ],
          },
        },
        {
          code: 'de-1',
          displayName: '🇩🇪 ⚡ Германия',
          selected: false,
          latency: 27,
        },
      ],
    };

    const el = renderSections({
      loading: false,
      failed: false,
      section,
      isCollapsed: true,
      onTestLatency: vi.fn(),
      onChooseOutbound: vi.fn(),
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowPriorityInfo: vi.fn(),
      onUpdateSubscription: vi.fn(),
      latencyFetching: false,
      subscriptionUpdating: false,
    });

    const titleSec = el.querySelector(
      '.tachyon_dashboard-page__outbound-section__title-section',
    );
    expect(titleSec).not.toBeNull();

    const activeBadge = titleSec?.querySelector(
      '.tachyon_dashboard-page__source-group__active-badge',
    );
    expect(activeBadge).not.toBeNull();
    expect(activeBadge?.textContent).toContain('priority');
    expect(activeBadge?.textContent).toContain('Германия');
    expect(activeBadge?.textContent).toContain('27ms');
  });

  it('renders active badge with fallback to member displayName when selectedName is not set', () => {
    const section = {
      code: 'main',
      sectionName: 'main',
      displayName: 'main',
      withTagSelect: true,
      outbounds: [
        {
          code: 'urltest-tag',
          displayName: 'urltest',
          selected: true,
          latency: 0,
          urlTestInfo: {
            code: 'urltest-tag',
            displayName: 'urltest',
            selectedCode: 'us-1',
            outbounds: [
              {
                code: 'us-1',
                displayName: '🇺🇸 US East',
                selected: true,
                latency: 142,
              },
            ],
          },
        },
      ],
    };

    const el = renderSections({
      loading: false,
      failed: false,
      section,
      isCollapsed: true,
      onTestLatency: vi.fn(),
      onChooseOutbound: vi.fn(),
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowPriorityInfo: vi.fn(),
      onUpdateSubscription: vi.fn(),
      latencyFetching: false,
      subscriptionUpdating: false,
    });

    const activeBadge = el.querySelector(
      '.tachyon_dashboard-page__source-group__active-badge',
    );
    expect(activeBadge).not.toBeNull();
    expect(activeBadge?.textContent).toContain('urltest');
    expect(activeBadge?.textContent).toContain('US East');
    expect(activeBadge?.textContent).toContain('142ms');
  });

  it('renders active badge with latency in auto-groups block when collapsed', () => {
    const section: any = {
      code: 'main',
      sectionName: 'main',
      displayName: 'main',
      withTagSelect: true,
      dashboardSettings: {
        countryGrouping: 'chips',
      },
      outbounds: [
        {
          code: 'priority-tag',
          displayName: 'priority',
          selected: true,
          latency: 51,
          priorityInfo: {
            code: 'priority-tag',
            displayName: 'priority',
            selectedName: '🇳🇱 Hysteria 2 | Нидерланды',
            outbounds: [
              {
                code: 'nl-1',
                displayName: '🇳🇱 Hysteria 2 | Нидерланды',
                selected: true,
                latency: 51,
              },
            ],
          },
        },
        {
          code: 'nl-1',
          displayName: '🇳🇱 Hysteria 2 | Нидерланды',
          country: 'NL',
          selected: false,
          latency: 51,
        },
      ],
    };

    const el = renderSections({
      loading: false,
      failed: false,
      section,
      isCollapsed: false,
      collapsedSourceGroups: new Set(['autogrp:main']),
      onTestLatency: vi.fn(),
      onChooseOutbound: vi.fn(),
      onCopyOutbound: vi.fn(),
      onShowUrlTestInfo: vi.fn(),
      onShowPriorityInfo: vi.fn(),
      onUpdateSubscription: vi.fn(),
      latencyFetching: false,
      subscriptionUpdating: false,
    });

    const autoGroups = el.querySelector('.tachyon_dashboard-page__auto-groups');
    expect(autoGroups).not.toBeNull();
    const autoBadge = autoGroups?.querySelector(
      '.tachyon_dashboard-page__source-group__active-badge',
    );
    expect(autoBadge).not.toBeNull();
    expect(autoBadge?.textContent).toContain('priority');
    expect(autoBadge?.textContent).toContain('Нидерланды');
    expect(autoBadge?.textContent).toContain('51ms');
  });

  it('formats subscription traffic quota in binary GiB matching outbounds pool (#383)', () => {
    const section: any = {
      code: 'main',
      sectionName: 'main',
      displayName: 'main',
      withTagSelect: true,
      subscriptionMetadata: [
        {
          title: 'subscribeRiot',
          traffic: {
            used: Math.round(164.3 * 1024 * 1024 * 1024),
            total: 800 * 1024 * 1024 * 1024,
            isUnlimited: false,
          },
        },
      ],
      outbounds: [
        {
          code: 'nl-1',
          displayName: '🇳🇱 Node 1',
          selected: true,
          latency: 40,
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

    expect(el.textContent).toContain('164.3 GB / 800.0 GB');
    expect(el.textContent).not.toContain('176 GB / 859 GB');
  });

  it('hides hidden outbounds and metadata by default and reveals them when showHidden is true (#405)', () => {
    const section: any = {
      code: 'main',
      sectionName: 'main',
      displayName: 'main',
      withTagSelect: true,
      subscriptionSourceCount: 2,
      subscriptionMetadata: [
        {
          title: 'VisibleSub',
          sourceIndex: 1,
          sourceSection: 'main',
        },
        {
          title: 'SecretSub',
          sourceIndex: 2,
          sourceSection: 'main',
          hidden: true,
        },
      ],
      outbounds: [
        {
          code: 'vis-1',
          displayName: 'Visible Node',
          selected: true,
          latency: 20,
          sourceGroup: 'sub:1',
        },
        {
          code: 'hid-sub-1',
          displayName: 'Hidden Sub Node',
          selected: false,
          latency: 35,
          sourceGroup: 'sub:2',
          hidden: true,
        },
        {
          code: 'hid-manual-1',
          displayName: 'Hidden Manual Server',
          selected: false,
          latency: 50,
          sourceGroup: 'manual',
          hidden: true,
        },
      ],
    };

    const baseProps = {
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
    };

    const defaultEl = renderSections(baseProps);
    expect(defaultEl.textContent).toContain('Visible Node');
    expect(defaultEl.textContent).not.toContain('SecretSub');
    expect(defaultEl.textContent).not.toContain('Hidden Sub Node');
    expect(defaultEl.textContent).not.toContain('Hidden Manual Server');

    const revealedEl = renderSections({ ...baseProps, showHidden: true });
    expect(revealedEl.textContent).toContain('Visible Node');
    expect(revealedEl.textContent).toContain('SecretSub');
    expect(revealedEl.textContent).toContain('Hidden Sub Node');
    expect(revealedEl.textContent).toContain('Hidden Manual Server');
    expect(revealedEl.textContent).toContain('Hidden');
  });

  it('passes sourceIndex and sourceId when updating an individual subscription card, vs section-only on header button', () => {
    const onUpdateSubscription = vi.fn();
    const section: any = {
      code: 'Main',
      sectionName: 'Main',
      displayName: 'Main',
      withTagSelect: true,
      subscriptionSourceCount: 2,
      subscriptionMetadata: [
        {
          title: 'Sub A',
          sourceIndex: 1,
          sourceSection: 'Main-subscription-1',
          sourceId: 'src_a',
        },
        {
          title: 'Sub B',
          sourceIndex: 2,
          sourceSection: 'Main-subscription-2',
          sourceId: 'src_b',
        },
      ],
      outbounds: [
        {
          code: 'n1',
          displayName: 'Node 1',
          type: 'VLESS',
          sourceGroup: 'sub:1',
          sourceId: 'src_a',
          selected: true,
        },
        {
          code: 'n2',
          displayName: 'Node 2',
          type: 'VLESS',
          sourceGroup: 'sub:2',
          sourceId: 'src_b',
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
      onUpdateSubscription,
      latencyFetching: false,
      subscriptionUpdating: false,
    });

    const cardBtns = Array.from(
      el.querySelectorAll('.tachyon_dashboard-page__subscription-meta__action'),
    ) as HTMLButtonElement[];
    expect(cardBtns.length).toBeGreaterThanOrEqual(2);
    cardBtns[1].click();
    expect(onUpdateSubscription).toHaveBeenCalledWith(section, 2, 'src_b');

    onUpdateSubscription.mockClear();
    const headerBtn = el.querySelector(
      '.tachyon_dashboard-page__outbound-section__subscription-update',
    ) as HTMLButtonElement | null;
    if (headerBtn) {
      headerBtn.click();
      expect(onUpdateSubscription).toHaveBeenCalledWith(section);
    }
  });

  it('isolates updating spinner and disabled state to the targeted subscription card', () => {
    const section: any = {
      code: 'Main',
      sectionName: 'Main',
      displayName: 'Main',
      withTagSelect: true,
      subscriptionSourceCount: 2,
      subscriptionMetadata: [
        {
          title: 'Sub A',
          sourceIndex: 1,
          sourceSection: 'Main-subscription-1',
          sourceId: 'src_a',
        },
        {
          title: 'Sub B',
          sourceIndex: 2,
          sourceSection: 'Main-subscription-2',
          sourceId: 'src_b',
        },
      ],
      outbounds: [
        {
          code: 'n1',
          displayName: 'Node 1',
          type: 'VLESS',
          sourceGroup: 'sub:1',
          sourceId: 'src_a',
          selected: true,
        },
        {
          code: 'n2',
          displayName: 'Node 2',
          type: 'VLESS',
          sourceGroup: 'sub:2',
          sourceId: 'src_b',
        },
      ],
    };

    const singleTargetEl = renderSections({
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
      subscriptionUpdatingTargets: { 'Main::src_b': true },
    });

    const singleCardBtns = Array.from(
      singleTargetEl.querySelectorAll(
        '.tachyon_dashboard-page__subscription-meta__action',
      ),
    ) as HTMLButtonElement[];
    expect(singleCardBtns).toHaveLength(2);
    expect(singleCardBtns[0].disabled).toBeFalsy();
    expect(singleCardBtns[0].querySelector('.lucide-loader-circle')).toBeNull();
    expect(singleCardBtns[1].disabled).toBe(true);
    expect(
      singleCardBtns[1].querySelector('.lucide-loader-circle'),
    ).not.toBeNull();

    const singleHeaderBtn = singleTargetEl.querySelector(
      '.tachyon_dashboard-page__outbound-section__subscription-update',
    ) as HTMLButtonElement | null;
    if (singleHeaderBtn) {
      expect(singleHeaderBtn.disabled).toBeFalsy();
      expect(singleHeaderBtn.querySelector('.lucide-loader-circle')).toBeNull();
    }

    const wholeSectionEl = renderSections({
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
      subscriptionUpdating: true,
      subscriptionUpdatingTargets: {},
    });

    const wholeCardBtns = Array.from(
      wholeSectionEl.querySelectorAll(
        '.tachyon_dashboard-page__subscription-meta__action',
      ),
    ) as HTMLButtonElement[];
    expect(wholeCardBtns).toHaveLength(2);
    expect(wholeCardBtns[0].disabled).toBe(true);
    expect(wholeCardBtns[1].disabled).toBe(true);
    const wholeHeaderBtn = wholeSectionEl.querySelector(
      '.tachyon_dashboard-page__outbound-section__subscription-update',
    ) as HTMLButtonElement | null;
    if (wholeHeaderBtn) {
      expect(wholeHeaderBtn.disabled).toBe(true);
      expect(
        wholeHeaderBtn.querySelector('.lucide-loader-circle'),
      ).not.toBeNull();
    }
  });

  it('renders distinct icons, classes, and data-action attrs for URLTest details and Priority details (#466)', () => {
    const onShowUrlTestInfo = vi.fn();
    const onShowPriorityInfo = vi.fn();
    const section: any = {
      code: 'Main',
      sectionName: 'Main',
      displayName: 'Main',
      withTagSelect: false,
      outbounds: [
        {
          code: 'main-urltest-out',
          displayName: 'Fastest',
          type: 'URLTest',
          selected: false,
          urlTestInfo: {
            code: 'main-urltest-out',
            displayName: 'Fastest',
            outbounds: [],
          },
        },
        {
          code: 'main-priority-out',
          displayName: 'Priority Balanced',
          type: 'Priority',
          selected: true,
          priorityInfo: {
            code: 'main-priority-out',
            displayName: 'Priority Balanced',
            tiers: [],
          },
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
      onShowUrlTestInfo,
      onShowPriorityInfo,
      onUpdateSubscription: vi.fn(),
      latencyFetching: false,
      subscriptionUpdating: false,
    });

    const urltestBtn = el.querySelector(
      '.tachyon_dashboard-page__outbound-grid__item__urltest-button',
    ) as HTMLButtonElement | null;
    const priorityBtn = el.querySelector(
      '.tachyon_dashboard-page__outbound-grid__item__priority-button',
    ) as HTMLButtonElement | null;

    expect(urltestBtn).not.toBeNull();
    expect(priorityBtn).not.toBeNull();
    expect(urltestBtn?.getAttribute('data-action')).toBe('urltest-details');
    expect(priorityBtn?.getAttribute('data-action')).toBe('priority-details');
    expect(
      urltestBtn?.classList.contains(
        'tachyon_dashboard-page__outbound-grid__item__copy-button',
      ),
    ).toBe(true);
    expect(
      priorityBtn?.classList.contains(
        'tachyon_dashboard-page__outbound-grid__item__copy-button',
      ),
    ).toBe(true);

    const urlSvg = urltestBtn?.querySelector('svg');
    const prioSvg = priorityBtn?.querySelector('svg');
    expect(urlSvg).not.toBeNull();
    expect(prioSvg).not.toBeNull();
    expect(
      Array.from(urlSvg?.children || []).map((c: any) => c.tagName),
    ).not.toEqual(
      Array.from(prioSvg?.children || []).map((c: any) => c.tagName),
    );

    (urltestBtn as any)?.click({ stopPropagation() {} });
    (priorityBtn as any)?.click({ stopPropagation() {} });
    expect(onShowUrlTestInfo).toHaveBeenCalledTimes(1);
    expect(onShowPriorityInfo).toHaveBeenCalledTimes(1);
  });

  it('renders only Priority details button if an outbound ever carries both priorityInfo and urlTestInfo (#478)', () => {
    const onShowUrlTestInfo = vi.fn();
    const onShowPriorityInfo = vi.fn();
    const section: any = {
      code: 'Main',
      sectionName: 'Main',
      displayName: 'Main',
      withTagSelect: false,
      outbounds: [
        {
          code: 'main-priority-out',
          displayName: 'Auto',
          type: 'Priority',
          selected: true,
          urlTestInfo: {
            code: 'main-priority-out',
            displayName: 'Auto',
            outbounds: [],
          },
          priorityInfo: {
            code: 'main-priority-out',
            displayName: 'Auto',
            tiers: [],
          },
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
      onShowUrlTestInfo,
      onShowPriorityInfo,
      onUpdateSubscription: vi.fn(),
      latencyFetching: false,
      subscriptionUpdating: false,
    });

    const urltestBtn = el.querySelector(
      '.tachyon_dashboard-page__outbound-grid__item__urltest-button',
    ) as HTMLButtonElement | null;
    const priorityBtn = el.querySelector(
      '.tachyon_dashboard-page__outbound-grid__item__priority-button',
    ) as HTMLButtonElement | null;

    expect(urltestBtn).toBeNull();
    expect(priorityBtn).not.toBeNull();

    (priorityBtn as any)?.click({ stopPropagation() {} });
    expect(onShowPriorityInfo).toHaveBeenCalledTimes(1);
    expect(onShowUrlTestInfo).not.toHaveBeenCalled();
  });

  it('renderGlobalConfigErrorsBanner hides section-owned errors and renders global/system faults', () => {
    const sections: any[] = [
      {
        code: 'youtube',
        sectionName: 'youtube',
        displayName: 'YouTube',
        outbounds: [],
        withTagSelect: false,
      },
    ];

    expect(
      renderGlobalConfigErrorsBanner(sections, {
        youtube: 'Section error already shown on card',
      }),
    ).toBeNull();

    const banner = renderGlobalConfigErrorsBanner(sections, {
      youtube: 'Section error already shown on card',
      _dns: 'DoH upstream failed; UDP fallback active',
      _core_runtime: 'Minimal mode started',
    });
    expect(banner).not.toBeNull();
    const text = banner.textContent;
    expect(text).toContain('DNS: ');
    expect(text).toContain('DoH upstream failed; UDP fallback active');
    expect(text).toContain('Minimal mode started');
    expect(text).not.toContain('Section error already shown on card');

    const emptySecBanner = renderGlobalConfigErrorsBanner([], {
      _rules: 'Broken custom ruleset',
    });
    expect(emptySecBanner).not.toBeNull();
    expect(emptySecBanner.textContent).toContain('Broken custom ruleset');
  });
});
