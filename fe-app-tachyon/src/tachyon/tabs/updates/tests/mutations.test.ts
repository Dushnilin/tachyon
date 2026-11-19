import { describe, expect, it } from 'vitest';
import { computeSystemInfoMutation } from '../mutations';
import type { StoreType } from '../../../services/store.service';

const initialSystemInfo: StoreType['diagnosticsSystemInfo'] = {
  loading: true,
  loaded: false,
  tachyon_version: '2.0.0',
  tachyon_core_version: '0.1.0',
  tachyon_core_fptn: 1,
  tachyon_core_tailscale: 1,
  tachyon_core_cert_pin: 1,
  torrserver_installed: 0,
  torrserver_version: 'not installed',
  torrserver_running: 0,
  torrserver_direct_available: 0,
  direct_bypass_enabled: 0,
  torrserver_direct_enabled: 0,
  torrserver_direct_active: 0,
  providerInfoLoaded: false,
} as unknown as StoreType['diagnosticsSystemInfo'];

describe('computeSystemInfoMutation', () => {
  it('updates tachyon version on install', () => {
    const { nextSystemInfo } = computeSystemInfoMutation(initialSystemInfo, {
      component: 'tachyon',
      action: 'install',
      latest_version: '2.5.0',
    });

    expect(nextSystemInfo.tachyon_version).toBe('2.5.0');
    expect(nextSystemInfo.loaded).toBe(true);
    expect(nextSystemInfo.loading).toBe(false);
  });

  it('updates tachyon-core version and capability flags on install or install_version', () => {
    const { nextSystemInfo } = computeSystemInfoMutation(initialSystemInfo, {
      component: 'tachyon-core',
      action: 'install',
      current_version: '0.1.4',
      latest_version: '0.1.4',
      release_url:
        'https://github.com/Dushnilin/tachyon-core/releases/tag/v0.1.4',
    });

    expect(nextSystemInfo.tachyon_core_version).toBe('0.1.4');
    expect(nextSystemInfo.tachyon_core_fptn).toBe(1);
    expect(nextSystemInfo.tachyon_core_tailscale).toBe(1);
    expect(nextSystemInfo.tachyon_core_cert_pin).toBe(1);
    expect(nextSystemInfo.loaded).toBe(true);
    expect(nextSystemInfo.loading).toBe(false);
  });

  it('updates tachyon-core version on rollback', () => {
    const { nextSystemInfo } = computeSystemInfoMutation(initialSystemInfo, {
      component: 'tachyon-core',
      action: 'rollback',
      current_version: '0.1.3',
    });

    expect(nextSystemInfo.tachyon_core_version).toBe('0.1.3');
    expect(nextSystemInfo.tachyon_core_fptn).toBe(1);
    expect(nextSystemInfo.tachyon_core_tailscale).toBe(1);
    expect(nextSystemInfo.tachyon_core_cert_pin).toBe(1);
  });

  it('updates torrserver_direct installation and removal', () => {
    const { nextSystemInfo: installed } = computeSystemInfoMutation(
      initialSystemInfo,
      {
        component: 'torrserver_direct',
        action: 'install',
        current_version: 'MatriX.136',
      },
    );

    expect(installed.torrserver_installed).toBe(1);
    expect(installed.torrserver_version).toBe('MatriX.136');
    expect(installed.torrserver_direct_enabled).toBe(1);

    const { nextSystemInfo: removed } = computeSystemInfoMutation(installed, {
      component: 'torrserver_direct',
      action: 'remove',
    });

    expect(removed.torrserver_installed).toBe(0);
    expect(removed.torrserver_version).toBe('not installed');
    expect(removed.torrserver_direct_enabled).toBe(0);
  });
});
