import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { Tachyon } from '../../../../types';

const mocks = vi.hoisted(() => ({
  checkNftRules: vi.fn(),
  getFakeIpCheck: vi.fn(),
  getIpCheck: vi.fn(),
  updateCheckStore: vi.fn(),
  platformInfo: null as Tachyon.PlatformInfo | null,
}));

vi.mock('../../../../methods', () => ({
  TachyonShellMethods: {
    checkNftRules: mocks.checkNftRules,
  },
  RemoteFakeIPMethods: {
    getFakeIpCheck: mocks.getFakeIpCheck,
    getIpCheck: mocks.getIpCheck,
  },
}));

vi.mock('../updateCheckStore', () => ({
  updateCheckStore: mocks.updateCheckStore,
}));

vi.mock('../../../../services/store.service', () => ({
  store: {
    get: () => ({
      servicesInfoWidget: {
        data: {
          platformInfo: mocks.platformInfo,
        },
      },
      diagnosticsSystemInfo: {
        platform_info: mocks.platformInfo,
      },
    }),
  },
}));

import { runNftCheck } from '../runNftCheck';

describe('runNftCheck', () => {
  beforeEach(() => {
    mocks.checkNftRules.mockReset();
    mocks.getFakeIpCheck.mockReset();
    mocks.getIpCheck.mockReset();
    mocks.updateCheckStore.mockReset();
    mocks.platformInfo = null;
    mocks.getFakeIpCheck.mockResolvedValue({ success: true, data: {} });
    mocks.getIpCheck.mockResolvedValue({ success: true, data: {} });
  });

  it('uses iptables title and chain label when checkNftRules returns iptables table_name', async () => {
    mocks.platformInfo = {
      platform: 'keenetic_entware',
      display_name: 'Keenetic Entware',
      is_entware: true,
      is_keenetic: true,
      firewall: 'iptables',
      storage_kind: 'usb_external',
      storage_fs: 'ext4',
      storage_mount: '/opt',
      storage_posix: true,
      runtime_tmpfs_ok: true,
    };
    mocks.checkNftRules.mockResolvedValue({
      success: true,
      data: {
        table_exist: 1,
        table_name: 'iptables (TACHYON_*)',
        rules_mangle_exist: 1,
        rules_mangle_counters: 1,
        rules_mangle_output_exist: 1,
        rules_mangle_output_counters: 1,
        rules_proxy_exist: 1,
        rules_proxy_counters: 1,
        rules_other_mark_exist: 0,
      },
    });

    await runNftCheck();

    expect(mocks.updateCheckStore).toHaveBeenLastCalledWith(
      expect.objectContaining({
        code: 'NFT',
        title: expect.stringContaining('iptables'),
        state: 'success',
        items: expect.arrayContaining([
          expect.objectContaining({
            state: 'success',
            key: expect.stringMatching(/Цепочки iptables|iptables chains/),
            value: 'iptables (TACHYON_*)',
          }),
        ]),
      }),
    );
    const calls = mocks.updateCheckStore.mock.calls;
    const lastCall = calls[calls.length - 1]?.[0];
    expect(lastCall?.title).not.toContain('Nftables');
  });

  it('keeps Nftables title and Table exist label on OpenWrt', async () => {
    mocks.platformInfo = {
      platform: 'openwrt',
      display_name: 'OpenWrt',
      is_entware: false,
      is_keenetic: false,
      firewall: 'nftables',
      storage_kind: 'internal_flash',
      storage_fs: 'overlay',
      storage_mount: '/',
      storage_posix: true,
      runtime_tmpfs_ok: true,
    };
    mocks.checkNftRules.mockResolvedValue({
      success: true,
      data: {
        table_exist: 1,
        table_name: 'inet TachyonTable',
        rules_mangle_exist: 1,
        rules_mangle_counters: 1,
        rules_mangle_output_exist: 1,
        rules_mangle_output_counters: 1,
        rules_proxy_exist: 1,
        rules_proxy_counters: 1,
        rules_other_mark_exist: 0,
      },
    });

    await runNftCheck();

    expect(mocks.updateCheckStore).toHaveBeenLastCalledWith(
      expect.objectContaining({
        code: 'NFT',
        title: expect.stringContaining('Nftables'),
        state: 'success',
        items: expect.arrayContaining([
          expect.objectContaining({
            state: 'success',
            key: 'Table exist',
            value: 'inet TachyonTable',
          }),
        ]),
      }),
    );
  });
});
