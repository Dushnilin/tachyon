/// <reference types="vite/client" />
import { describe, expect, it } from 'vitest';
import {
  formatPlatformBadge,
  isEntwarePlatform,
  isIptablesFirewall,
  isOpenWrtOnlyFixCode,
  isOpenWrtOnlyNotice,
  validateEntwareDnsPort,
} from '../platformInfo';
import type { Tachyon } from '../../types';
import settingsSource from '../../../views/settings.ts?raw';
import studioSource from '../../studioDeck.ts?raw';

describe('Entware / Keenetic platform UI guards, badges, DNS settings, and section order', () => {
  const keeneticInfo: Tachyon.PlatformInfo = {
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
    entware_dns_mode: 'redirect',
    entware_dns_port: 1053,
  };

  const openwrtInfo: Tachyon.PlatformInfo = {
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

  it('formats compact Keenetic/Entware environment badge and surfaces storage/tmpfs warnings', () => {
    const cleanBadge = formatPlatformBadge(keeneticInfo);
    expect(cleanBadge.label).toBe('Keenetic Entware · USB ext4 · iptables');
    expect(cleanBadge.warning).toBeNull();

    const genericBadge = formatPlatformBadge({
      ...keeneticInfo,
      platform: 'generic_entware',
      display_name: 'Entware',
      is_keenetic: false,
      storage_kind: 'internal_flash',
      storage_fs: '',
    });
    expect(genericBadge.label).toBe('Entware · iptables');

    const warnedBadge = formatPlatformBadge({
      ...keeneticInfo,
      storage_fs: 'vfat',
      storage_posix: false,
      runtime_tmpfs_ok: false,
    });
    expect(warnedBadge.warning).toBeTruthy();
    expect(warnedBadge.tooltip).toContain('POSIX');
    expect(warnedBadge.tooltip).toContain('tmpfs');
  });

  it('hides OpenWrt-only quick-fixes and notices on Entware while keeping them on OpenWrt', () => {
    expect(isEntwarePlatform(keeneticInfo)).toBe(true);
    expect(isEntwarePlatform(openwrtInfo)).toBe(false);
    expect(isIptablesFirewall(keeneticInfo)).toBe(true);
    expect(isIptablesFirewall(openwrtInfo)).toBe(false);

    expect(isOpenWrtOnlyFixCode('disable_flow_offloading', keeneticInfo)).toBe(
      true,
    );
    expect(isOpenWrtOnlyFixCode('sync_flow_offload_guard', keeneticInfo)).toBe(
      true,
    );
    expect(isOpenWrtOnlyFixCode('fix_dnsmasq', keeneticInfo)).toBe(true);
    expect(isOpenWrtOnlyFixCode('restart_network', keeneticInfo)).toBe(false);
    expect(isOpenWrtOnlyFixCode('disable_flow_offloading', openwrtInfo)).toBe(
      false,
    );

    expect(
      isOpenWrtOnlyNotice('fw4 flow offloading enabled', keeneticInfo),
    ).toBe(true);
    expect(isOpenWrtOnlyNotice('odhcpd lease mismatch', keeneticInfo)).toBe(
      true,
    );
    expect(
      isOpenWrtOnlyNotice('OpenWrt LuCI launcher missing', keeneticInfo),
    ).toBe(true);
    expect(
      isOpenWrtOnlyNotice('fw4 flow offloading enabled', openwrtInfo),
    ).toBe(false);
  });

  it('validates entware_dns_port in 1..65535', () => {
    expect(validateEntwareDnsPort('1053')).toBe(true);
    expect(validateEntwareDnsPort('1')).toBe(true);
    expect(validateEntwareDnsPort('65535')).toBe(true);
    expect(validateEntwareDnsPort('0')).not.toBe(true);
    expect(validateEntwareDnsPort('65536')).not.toBe(true);
    expect(validateEntwareDnsPort('-5')).not.toBe(true);
    expect(validateEntwareDnsPort('abc')).not.toBe(true);
    expect(validateEntwareDnsPort('')).not.toBe(true);
  });

  it('exposes entware_dns_mode and entware_dns_port gated on Entware in settings.ts', () => {
    expect(settingsSource).toContain("'entware_dns_mode'");
    expect(settingsSource).toContain("'redirect'");
    expect(settingsSource).toContain("'override'");
    expect(settingsSource).toContain("'entware_dns_port'");
    expect(settingsSource).toContain("o.default = '1053'");
    expect(settingsSource).toContain('isEntwareRuntime()');
  });

  it('passes after=true when moving UCI sections downward so bypass-before-match_all ordering works reliably', () => {
    expect(studioSource).toContain(
      '(uci as any).move(UCI_PACKAGE, sid, targetSid, direction > 0)',
    );
    expect(studioSource).toContain(
      '(uci as any).move(UCI_PACKAGE, draggedSid, sid, after)',
    );
  });
});
