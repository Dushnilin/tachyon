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
});
