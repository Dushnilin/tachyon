/* eslint-disable @typescript-eslint/no-explicit-any */
import { beforeEach, describe, expect, it, vi } from 'vitest';

const _mocks = vi.hoisted(() => {
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
        el.style.cssText = style;
      }
    }
    if (children) {
      if (Array.isArray(children)) {
        children.forEach((c) => {
          if (c) el.appendChild(typeof c === 'string' ? { textContent: c } : c);
        });
      } else {
        el.appendChild(
          typeof children === 'string' ? { textContent: children } : children,
        );
      }
    }
    return el;
  };

  (globalThis as any)._ = (msg: string) => msg;

  return {};
});

vi.mock('../../../services/tab.service', () => ({
  TabService: {
    getInstance: () => ({ isActive: () => true }),
  },
}));

import {
  FIX_LABELS,
  getAiDoctorHistory,
  getDeviceIcon,
  renderAiDoctorModal,
  saveAiDoctorHistory,
} from '../partials/renderAiDoctorModal';

describe('renderAiDoctorModal helpers', () => {
  let mockStorage: Record<string, string>;

  beforeEach(() => {
    mockStorage = {};
    (globalThis as unknown as { localStorage: unknown }).localStorage = {
      getItem: vi.fn((key: string) => mockStorage[key] ?? null),
      setItem: vi.fn((key: string, value: string) => {
        mockStorage[key] = value;
      }),
      removeItem: vi.fn((key: string) => {
        delete mockStorage[key];
      }),
      clear: vi.fn(() => {
        mockStorage = {};
      }),
    };
  });

  it('saves and reads history capped at 5 entries', () => {
    for (let i = 1; i <= 7; i++) {
      saveAiDoctorHistory({
        timestamp: `10:0${i}`,
        report: `Report ${i}`,
        quickFixes: [`fix_${i}`],
      });
    }

    const history = getAiDoctorHistory();
    expect(history).toHaveLength(5);
    // Most recent is entry 7
    expect(history[0].report).toBe('Report 7');
    expect(history[4].report).toBe('Report 3');
  });

  it('maps device icon based on hostname', () => {
    expect(getDeviceIcon('Samsung-TV-LivingRoom')).toBe('📺');
    expect(getDeviceIcon('iPhone-15-Pro')).toBe('📱');
    expect(getDeviceIcon('MacBook-Pro')).toBe('💻');
    expect(getDeviceIcon('Playstation-5')).toBe('🎮');
    expect(getDeviceIcon('SmartPlug-102')).toBe('📟');
  });

  it('has readable labels for common fixes', () => {
    expect(FIX_LABELS.start_singbox).toBeDefined();
    expect(FIX_LABELS.rebuild_rules).toBeDefined();
    expect(FIX_LABELS.restore_native_internet).toBeDefined();
  });

  it('renders modal with root cause nodes and report', () => {
    const showModalMock = vi.fn();
    (globalThis as unknown as { ui: unknown }).ui = {
      showModal: showModalMock,
      hideModal: vi.fn(),
    };

    renderAiDoctorModal({
      report: 'All subsystems operational. No issues detected.',
      quickFixes: ['start_singbox'],
      backendNodes: [
        { name: 'WAN', status: 'OK' },
        { name: 'DNS', status: 'OK' },
        { name: 'sing-box', status: 'OK' },
        { name: 'nftables', status: 'OK' },
      ],
    });

    expect(showModalMock).toHaveBeenCalled();
  });
});
