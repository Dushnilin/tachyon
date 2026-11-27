import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  checkFakeIP: vi.fn(),
  getFakeIpCheck: vi.fn(),
  getIpCheck: vi.fn(),
  getDashboardSections: vi.fn(),
  updateCheckStore: vi.fn(),
}));

vi.mock('../../../../methods', () => ({
  TachyonShellMethods: {
    checkFakeIP: mocks.checkFakeIP,
  },
  RemoteFakeIPMethods: {
    getFakeIpCheck: mocks.getFakeIpCheck,
    getIpCheck: mocks.getIpCheck,
  },
}));

vi.mock('../../../../methods/custom/getDashboardSections', () => ({
  getDashboardSections: mocks.getDashboardSections,
}));

vi.mock('../updateCheckStore', () => ({
  updateCheckStore: mocks.updateCheckStore,
}));

vi.mock('../../../../services', () => ({
  store: {
    get: () => ({
      sectionsWidget: {
        data: [],
      },
    }),
  },
}));

import { runFakeIPCheck } from '../runFakeIPCheck';

describe('runFakeIPCheck', () => {
  beforeEach(() => {
    mocks.checkFakeIP.mockReset();
    mocks.getFakeIpCheck.mockReset();
    mocks.getIpCheck.mockReset();
    mocks.getDashboardSections.mockReset();
    mocks.updateCheckStore.mockReset();
  });

  it('marks check as success when proxy is present and public IPs differ', async () => {
    mocks.checkFakeIP.mockResolvedValue({
      success: true,
      data: { fakeip: true, IP: '198.18.1.1' },
    });
    mocks.getFakeIpCheck.mockResolvedValue({
      success: true,
      data: { fakeip: true, IP: '1.2.3.4' },
    });
    mocks.getIpCheck.mockResolvedValue({
      success: true,
      data: { fakeip: false, IP: '5.6.7.8' },
    });
    mocks.getDashboardSections.mockResolvedValue({
      success: true,
      data: [
        { sectionName: 'Discord', action: 'desync' },
        { sectionName: 'Main', action: 'connection' },
      ],
    });

    await runFakeIPCheck();

    expect(mocks.updateCheckStore).toHaveBeenLastCalledWith(
      expect.objectContaining({
        state: 'success',
        items: expect.arrayContaining([
          expect.objectContaining({
            state: 'success',
            key: 'FakeIP and control checks use different public IPs',
          }),
        ]),
      }),
    );
  });

  it('marks check as warning when proxy is present but public IPs are identical', async () => {
    mocks.checkFakeIP.mockResolvedValue({
      success: true,
      data: { fakeip: true, IP: '198.18.1.1' },
    });
    mocks.getFakeIpCheck.mockResolvedValue({
      success: true,
      data: { fakeip: true, IP: '1.2.3.4' },
    });
    mocks.getIpCheck.mockResolvedValue({
      success: true,
      data: { fakeip: false, IP: '1.2.3.4' },
    });
    mocks.getDashboardSections.mockResolvedValue({
      success: true,
      data: [{ sectionName: 'Main', action: 'connection' }],
    });

    await runFakeIPCheck();

    expect(mocks.updateCheckStore).toHaveBeenLastCalledWith(
      expect.objectContaining({
        state: 'warning',
        description: 'FakeIP works; public IP comparison is inconclusive',
        items: expect.arrayContaining([
          expect.objectContaining({
            state: 'warning',
            key: 'FakeIP and control checks use the same public IP',
          }),
        ]),
      }),
    );
  });

  it('marks check as success when only packet desync sections exist and public IPs match', async () => {
    mocks.checkFakeIP.mockResolvedValue({
      success: true,
      data: { fakeip: true, IP: '198.18.1.1' },
    });
    mocks.getFakeIpCheck.mockResolvedValue({
      success: true,
      data: { fakeip: true, IP: '1.2.3.4' },
    });
    mocks.getIpCheck.mockResolvedValue({
      success: true,
      data: { fakeip: false, IP: '1.2.3.4' },
    });
    mocks.getDashboardSections.mockResolvedValue({
      success: true,
      data: [
        { sectionName: 'Discord', action: 'desync' },
        { sectionName: 'YouTube', action: 'desync' },
      ],
    });

    await runFakeIPCheck();

    expect(mocks.updateCheckStore).toHaveBeenLastCalledWith(
      expect.objectContaining({
        state: 'success',
        description: 'Checks passed',
        items: expect.arrayContaining([
          expect.objectContaining({
            state: 'success',
            key: 'FakeIP and control checks use the same public IP',
            value: 'Direct connection via ISP',
          }),
        ]),
      }),
    );
  });

  it('formats both IPv4 and IPv6 FakeIP router results when available', async () => {
    mocks.checkFakeIP.mockResolvedValue({
      success: true,
      data: {
        fakeip: true,
        IP: '198.18.0.5',
        IPv4: '198.18.0.5',
        IPv6: 'fc00::5',
      },
    });
    mocks.getFakeIpCheck.mockResolvedValue({
      success: true,
      data: { fakeip: true, IP: '203.0.113.10' },
    });
    mocks.getIpCheck.mockResolvedValue({
      success: true,
      data: { IP: '198.51.100.20' },
    });

    await runFakeIPCheck();

    expect(mocks.updateCheckStore).toHaveBeenLastCalledWith(
      expect.objectContaining({
        state: 'success',
        items: expect.arrayContaining([
          expect.objectContaining({
            state: 'success',
            key: 'FakeIP DNS works',
            value: 'IPv4: 198.18.0.5 · IPv6: fc00::5',
          }),
        ]),
      }),
    );
  });

  it('reports inconclusive when public IP strings are empty', async () => {
    mocks.checkFakeIP.mockResolvedValue({
      success: true,
      data: { fakeip: true, IP: '198.18.0.5' },
    });
    mocks.getFakeIpCheck.mockResolvedValue({
      success: true,
      data: { fakeip: true, IP: '' },
    });
    mocks.getIpCheck.mockResolvedValue({
      success: true,
      data: { fakeip: false, IP: '' },
    });
    mocks.getDashboardSections.mockResolvedValue({
      success: true,
      data: [{ sectionName: 'Main', action: 'connection' }],
    });

    await runFakeIPCheck();

    expect(mocks.updateCheckStore).toHaveBeenLastCalledWith(
      expect.objectContaining({
        state: 'warning',
        items: expect.arrayContaining([
          expect.objectContaining({
            state: 'warning',
            key: 'Could not compare FakeIP and control public IPs',
          }),
        ]),
      }),
    );
  });

  it('marks check as success when selective_tproxy is enabled and public IPs match', async () => {
    mocks.checkFakeIP.mockResolvedValue({
      success: true,
      data: { fakeip: true, selective_tproxy: true, IP: '198.18.0.5' },
    });
    mocks.getFakeIpCheck.mockResolvedValue({
      success: true,
      data: { fakeip: true, selective_tproxy: true, IP: '1.2.3.4' },
    });
    mocks.getIpCheck.mockResolvedValue({
      success: true,
      data: { fakeip: false, selective_tproxy: true, IP: '1.2.3.4' },
    });
    mocks.getDashboardSections.mockResolvedValue({
      success: true,
      data: [{ sectionName: 'Main', action: 'connection' }],
    });

    await runFakeIPCheck();

    expect(mocks.updateCheckStore).toHaveBeenLastCalledWith(
      expect.objectContaining({
        state: 'success',
        description: 'Checks passed',
        items: expect.arrayContaining([
          expect.objectContaining({
            state: 'success',
            value: 'Selective TProxy: test domain uses direct path',
          }),
        ]),
      }),
    );
  });
});
