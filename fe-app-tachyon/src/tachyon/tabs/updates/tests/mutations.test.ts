import { describe, expect, it } from 'vitest';
import { computeSystemInfoMutation } from '../mutations';
import type { StoreType } from '../../../services/store.service';

const initialSystemInfo: StoreType['diagnosticsSystemInfo'] = {
  loading: true,
  loaded: false,
  tachyon_version: '2.0.0',
  sing_box_version: '1.10.0',
  sing_box_extended: 0,
  sing_box_tiny: 0,
  sing_box_compressed: 0,
  sing_box_lx: 0,
  sing_box_tailscale: 0,
  sing_box_cert_pin: 0,
  zapret_installed: 0,
  zapret_version: 'not installed',
  zapret2_installed: 0,
  zapret2_version: 'not installed',
  byedpi_installed: 0,
  byedpi_version: 'not installed',
  wdtt_installed: 0,
  wdtt_version: 'not installed',
  olcrtc_installed: 0,
  olcrtc_version: 'not installed',
  fptn_installed: 0,
  fptn_version: 'not installed',
  tailscale_version: 'not installed',
  steer_installed: 0,
  steer_version: 'not installed',
  steer_extended: 0,
  direct_bypass_enabled: 0,
  torrserver_direct_enabled: 0,
  torrserver_direct_active: 0,
  providerInfoLoaded: false,
} as unknown as StoreType['diagnosticsSystemInfo'];

describe('computeSystemInfoMutation', () => {
  it('updates tachyon version on install', () => {
    const { nextSystemInfo, notifyActionProviders } = computeSystemInfoMutation(
      initialSystemInfo,
      {
        component: 'tachyon',
        action: 'install',
        latest_version: '2.5.0',
      },
    );

    expect(nextSystemInfo.tachyon_version).toBe('2.5.0');
    expect(nextSystemInfo.loaded).toBe(true);
    expect(nextSystemInfo.loading).toBe(false);
    expect(notifyActionProviders).toBe(false);
  });

  it('updates sing-box variant flags for install_extended', () => {
    const { nextSystemInfo } = computeSystemInfoMutation(initialSystemInfo, {
      component: 'sing_box',
      action: 'install_extended',
      current_version: '1.11.5',
    });

    expect(nextSystemInfo.sing_box_version).toBe('1.11.5');
    expect(nextSystemInfo.sing_box_extended).toBe(1);
    expect(nextSystemInfo.sing_box_tiny).toBe(0);
    expect(nextSystemInfo.sing_box_tailscale).toBe(1);
    expect(nextSystemInfo.sing_box_cert_pin).toBe(1);
  });

  it('updates provider installation and flags notification', () => {
    const { nextSystemInfo, notifyActionProviders } = computeSystemInfoMutation(
      initialSystemInfo,
      {
        component: 'zapret2',
        action: 'install',
        current_version: 'v2.1',
      },
    );

    expect(nextSystemInfo.zapret2_installed).toBe(1);
    expect(nextSystemInfo.zapret2_version).toBe('v2.1');
    expect(nextSystemInfo.providerInfoLoaded).toBe(true);
    expect(notifyActionProviders).toBe(true);
  });

  it('handles provider removal correctly', () => {
    const installed = {
      ...initialSystemInfo,
      byedpi_installed: 1,
      byedpi_version: '0.14.0',
    };

    const { nextSystemInfo, notifyActionProviders } = computeSystemInfoMutation(
      installed,
      {
        component: 'byedpi',
        action: 'remove',
      },
    );

    expect(nextSystemInfo.byedpi_installed).toBe(0);
    expect(nextSystemInfo.byedpi_version).toBe('not installed');
    expect(notifyActionProviders).toBe(true);
  });

  it('updates steer extended status', () => {
    const { nextSystemInfo, notifyActionProviders } = computeSystemInfoMutation(
      initialSystemInfo,
      {
        component: 'steer-extended',
        action: 'install',
        current_version: '1.5.7',
      },
    );

    expect(nextSystemInfo.steer_installed).toBe(1);
    expect(nextSystemInfo.steer_version).toBe('1.5.7');
    expect(nextSystemInfo.steer_extended).toBe(1);
    expect(notifyActionProviders).toBe(false);
  });
});
