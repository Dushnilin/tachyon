import { beforeEach, describe, expect, it, vi } from 'vitest';

const getConfigSectionsMock = vi.fn();
const getClashApiProxiesMock = vi.fn();

vi.mock('../methods/custom/getConfigSections', () => ({
  getConfigSections: (...args: unknown[]) => getConfigSectionsMock(...args),
}));

vi.mock('../methods/shell', () => ({
  TachyonShellMethods: {
    getClashApiProxies: (...args: unknown[]) => getClashApiProxiesMock(...args),
    setClashApiGroupProxy: vi.fn(),
  },
}));

import { formatGroupSwitchError } from '../tabs/dashboard/initController';
import { getDashboardSections } from '../methods/custom/getDashboardSections';
import { getOutboundTagBySection } from '../runtimeTags';

const EXPECTED_NOT_ACTIVE_MSG =
  'Section is not active in the routing core yet — click Save & Apply first, or check section configuration.';

describe('dashboard group switch error formatting & selector tags', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    (globalThis as Record<string, unknown>).fs = {
      read: vi.fn().mockRejectedValue(new Error('ENOENT')),
    };
  });

  it('formats group_not_found and "does not exist" payloads into a localized message', () => {
    const rawJson = JSON.stringify({
      success: false,
      error: 'group_not_found',
      message: 'test1211_1 does not exist',
    });

    expect(formatGroupSwitchError(rawJson)).toBe(EXPECTED_NOT_ACTIVE_MSG);
    expect(
      formatGroupSwitchError({
        success: false,
        error: rawJson,
      }),
    ).toBe(EXPECTED_NOT_ACTIVE_MSG);
    expect(
      formatGroupSwitchError({
        success: true,
        data: {
          success: false,
          error: 'group_not_found',
          message: 'test1211_1 does not exist',
        },
      }),
    ).toBe(EXPECTED_NOT_ACTIVE_MSG);
    expect(
      formatGroupSwitchError({
        success: false,
        error: 'group_not_found',
      }),
    ).toBe(EXPECTED_NOT_ACTIVE_MSG);
    expect(
      formatGroupSwitchError(new Error("group 'test1211_1' does not exist")),
    ).toBe(EXPECTED_NOT_ACTIVE_MSG);
    expect(formatGroupSwitchError('{"success": false}')).toBe(
      EXPECTED_NOT_ACTIVE_MSG,
    );
  });

  it('preserves meaningful non-group_not_found messages without leaking raw JSON', () => {
    expect(
      formatGroupSwitchError(
        '{"success":false,"error":"timeout","message":"Core request timed out"}',
      ),
    ).toBe('Core request timed out');
    expect(
      formatGroupSwitchError({
        success: false,
        error: 'Connection refused',
      }),
    ).toBe('Connection refused');
    expect(formatGroupSwitchError(null)).toBe('Failed to switch proxy');
  });

  it('uses <section>-out fallback code when selector is missing from runtime cache', async () => {
    expect(getOutboundTagBySection('test1211_1')).toBe('test1211_1-out');

    getConfigSectionsMock.mockResolvedValue([
      {
        '.name': 'test1211_1',
        '.type': 'section',
        enabled: '1',
        action: 'proxy',
        selector_proxy_links: [
          'vless://11111111-1111-1111-1111-111111111111@198.51.100.1:443#Node1',
        ],
      },
      {
        '.name': 'single_awg_1',
        '.type': 'section',
        enabled: '1',
        action: 'awg',
      },
    ]);
    getClashApiProxiesMock.mockResolvedValue({
      success: true,
      data: { proxies: {} },
    });

    const result = await getDashboardSections({
      includeSubscriptionCopyState: false,
    });
    expect(result.success).toBe(true);

    const proxySection = result.data.find(
      (s) => s.sectionName === 'test1211_1',
    );
    expect(proxySection).toBeDefined();
    expect(proxySection?.code).toBe('test1211_1-out');

    const singleSection = result.data.find(
      (s) => s.sectionName === 'single_awg_1',
    );
    expect(singleSection).toBeDefined();
    expect(singleSection?.code).toBe('single_awg_1-out');
    expect(singleSection?.outbounds[0]?.code).toBe('single_awg_1-out');
  });
});
