import { afterEach, describe, expect, it } from 'vitest';
import {
  getIPv6ModeLabel,
  getIPv6RuntimeSnapshot,
  normalizeIpv6Mode,
} from '../ipv6Summary';
import type { StoreType } from '../../services/store.service';

type GlobalWithUci = typeof globalThis & {
  uci?: {
    get?: (pkg: string, sec: string, opt: string) => unknown;
  };
};

function makeSysInfo(
  overrides: Partial<StoreType['diagnosticsSystemInfo']> = {},
): StoreType['diagnosticsSystemInfo'] {
  return {
    loading: false,
    loaded: true,
    providerInfoLoaded: true,
    tachyon_version: '1.0.0',
    tachyon_commit_sha: 'abc',
    tachyon_latest_version: '1.0.0',
    luci_app_version: '1.0.0',
    tachyon_core_version: '0.3.10',
    tachyon_core_tailscale: 1,
    server_inbounds_enabled_count: 0,
    openwrt_version: '24.10',
    device_model: 'TestRouter',
    ...overrides,
  };
}

describe('getIPv6RuntimeSnapshot', () => {
  afterEach(() => {
    delete (globalThis as GlobalWithUci).uci;
  });

  it('derives leak_guard in auto mode without WAN6 when Leak Guard is active', () => {
    const snap = getIPv6RuntimeSnapshot(
      makeSysInfo({
        ipv6_mode: 'auto',
        ipv6_leak_guard: 1,
        fakeip_enabled: 1,
      }),
    );

    expect(snap.effectiveState).toBe('leak_guard');
    expect(snap.leakGuardActive).toBe(true);
    expect(snap.fakeIp6Range).toBe('fc00::/18');
    expect(snap.hasWan6).toBe(false);
    expect(snap.isWarning).toBe(false);
  });

  it('derives full Dual-Stack in auto mode when WAN6 prefix is present', () => {
    const snap = getIPv6RuntimeSnapshot(
      makeSysInfo({
        ipv6_mode: 'auto',
        wan6_prefix: '2001:db8:42::/48',
        ipv6_leak_guard: 1,
      }),
    );

    expect(snap.effectiveState).toBe('full');
    expect(snap.hasWan6).toBe(true);
    expect(snap.wan6Label).toBe('2001:db8:42::/48');
    expect(snap.modeLabel).toContain('Dual-Stack');
    expect(snap.isWarning).toBe(false);
  });

  it('prefers UCI settings over stale systemInfo and warns on ipv6_only without IPv6 transport', () => {
    const values: Record<string, string> = {
      ipv6_mode: 'off',
      ipv6_leak_guard: '1',
      dns_strategy: 'ipv6_only',
      fakeip_inet6_range: 'fd12:3456::/48',
    };
    (globalThis as GlobalWithUci).uci = {
      get: (_pkg, _sec, opt) => values[opt] ?? '',
    };

    const snap = getIPv6RuntimeSnapshot(
      makeSysInfo({
        ipv6_mode: 'auto',
        dns_strategy: 'prefer_ipv4',
      }),
    );

    expect(snap.ipv6Mode).toBe('off');
    expect(snap.effectiveState).toBe('leak_guard');
    expect(snap.fakeIp6Range).toBe('fd12:3456::/48');
    expect(snap.isWarning).toBe(true);
    expect(snap.warningText).toContain('ipv6_only');
  });

  it('warns when IPv6 routing and Leak Guard are both disabled', () => {
    const snap = getIPv6RuntimeSnapshot(
      makeSysInfo({
        ipv6_mode: 'off',
        ipv6_leak_guard: 0,
      }),
    );

    expect(snap.effectiveState).toBe('disabled');
    expect(snap.leakGuardActive).toBe(false);
    expect(snap.isWarning).toBe(true);
  });

  it('handles tunnel_over_v4 mode cleanly', () => {
    const snap = getIPv6RuntimeSnapshot(
      makeSysInfo({
        ipv6_mode: 'tunnel_over_v4',
        ipv6_leak_guard: 1,
      }),
    );

    expect(snap.effectiveState).toBe('tunnel_over_v4');
    expect(snap.isWarning).toBe(false);
  });

  it('uses wan6_pd fallback and warns when ipv6_only fell back to ipv4_only at runtime', () => {
    const snap = getIPv6RuntimeSnapshot(
      makeSysInfo({
        ipv6_mode: 'auto',
        wan6_pd: ['2001:db8:77::/56'],
        wan6_available: 1,
        dns_strategy: 'ipv6_only',
        runtime_dns_strategy: 'ipv4_only',
      }),
    );

    expect(snap.hasWan6).toBe(true);
    expect(snap.wan6Label).toBe('2001:db8:77::/56');
    expect(snap.isWarning).toBe(true);
    expect(snap.warningText).toContain('ipv4_only');
  });

  it('normalizes ipv6_mode aliases and exposes unified mode labels', () => {
    expect(normalizeIpv6Mode('ipv4_only')).toBe('off');
    expect(normalizeIpv6Mode('ipv4')).toBe('off');
    expect(normalizeIpv6Mode('ipv4_ipv6')).toBe('dual_stack');
    expect(normalizeIpv6Mode('on')).toBe('dual_stack');
    expect(normalizeIpv6Mode('full')).toBe('dual_stack');
    expect(normalizeIpv6Mode('v6_over_v4')).toBe('tunnel_over_v4');
    expect(normalizeIpv6Mode('unknown')).toBe('auto');

    expect(getIPv6ModeLabel('off')).toBe('IPv4 Only (no IPv6 on LAN devices)');
    expect(getIPv6ModeLabel('auto')).toBe('IPv4 + IPv6: Auto (Recommended)');
    expect(getIPv6ModeLabel('dual_stack')).toBe('IPv4 + IPv6: Full Dual-Stack');
    expect(getIPv6ModeLabel('tunnel_over_v4')).toBe(
      'IPv4 + IPv6: Over IPv4 Tunnel',
    );
  });
});
