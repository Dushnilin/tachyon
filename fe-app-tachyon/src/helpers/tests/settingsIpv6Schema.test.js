import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { cidrsOverlap, validateCidr } from '../../validators/validateSubnet';

const testDir = path.dirname(fileURLToPath(import.meta.url));
const stylesPath = path.resolve(testDir, '../../styles.ts');
const settingsPath = path.resolve(testDir, '../../views/settings.ts');
const wizardPath = path.resolve(testDir, '../../tachyon/connectionWizard.ts');

describe('Settings IPv6 schema, Simple/Advanced parity, and FakeIP/TUN validation', () => {
  const stylesSource = fs.readFileSync(stylesPath, 'utf8');
  const settingsSource = fs.readFileSync(settingsPath, 'utf8');
  const wizardSource = fs.readFileSync(wizardPath, 'utf8');

  it('defines all canonical IPv6, FakeIP, TUN, and Leak Guard options in settings.ts', () => {
    const canonicalFields = [
      'ipv6_mode',
      'ipv6_leak_guard',
      'dns_strategy',
      'fakeip_enabled',
      'fakeip_inet4_range',
      'fakeip_inet6_range',
      'fakeip_exclude',
      'tun_inet4',
      'tun_inet6',
      'webrtc_leak_protect',
    ];

    for (const field of canonicalFields) {
      expect(settingsSource).toContain(`'${field}'`);
    }

    for (const mode of ['auto', 'dual_stack', 'off', 'tunnel_over_v4']) {
      expect(settingsSource).toContain(`'${mode}'`);
    }

    // Unified IPv6 mode labels, alias normalization, & DNS strategy labels
    for (const label of [
      'Только IPv4 (без IPv6 на устройствах)',
      'IPv4 Only (no IPv6 on LAN devices)',
      'IPv4 + IPv6: Авто (рекомендуется)',
      'IPv4 + IPv6: Auto (Recommended)',
      'IPv4 + IPv6: Двойной стек (Dual-Stack)',
      'IPv4 + IPv6: Full Dual-Stack',
      'IPv4 + IPv6: Через IPv4-туннель',
      'IPv4 + IPv6: Over IPv4 Tunnel',
      'Приоритет IPv4',
      'Prefer IPv4',
      'Приоритет IPv6',
      'Prefer IPv6',
      'Только DNS IPv4 (A)',
      'IPv4 only (A)',
      'Только DNS IPv6 (AAAA)',
      'IPv6 only (AAAA)',
      "m === 'ipv4_only'",
      "m === 'ipv4_ipv6'",
      "m === 'v6_over_v4'",
    ]) {
      expect(settingsSource).toContain(label);
    }
    expect(wizardSource).toContain('IPv4 DNS only (A)');
    expect(wizardSource).toContain('IPv6 DNS only (AAAA)');
    expect(wizardSource).toContain('getIPv6ModeLabel');
  });

  it('exposes dns_strategy in Simple mode gated on non-off ipv6_mode and hides expert FakeIP/TUN controls', () => {
    expect(stylesSource).not.toMatch(
      /body\[data-tachyon-ui-mode="simple"\]\s*\[data-name="dns_strategy"\]/,
    );
    expect(settingsSource).toContain("o.depends('ipv6_mode', 'auto')");
    expect(settingsSource).toContain("o.depends('ipv6_mode', 'dual_stack')");
    expect(settingsSource).toContain(
      "o.depends('ipv6_mode', 'tunnel_over_v4')",
    );
    expect(settingsSource).toContain("'_dns_strategy_ipv4_locked'");
    expect(settingsSource).toContain(
      "dnsStrategyLockedOpt.depends('ipv6_mode', 'off')",
    );

    const hiddenInSimpleMode = [
      'fakeip_enabled',
      'fakeip_inet4_range',
      'fakeip_inet6_range',
      'fakeip_exclude',
      'tun_inet4',
      'tun_inet6',
    ];

    for (const field of hiddenInSimpleMode) {
      expect(stylesSource).toMatch(
        new RegExp(
          `body\\[data-tachyon-ui-mode="simple"\\][^}]*\\[data-name="${field}"\\][\\s\\S]*?display:\\s*none\\s*!important`,
        ),
      );
    }
  });

  it('validates canonical FakeIP & TUN CIDR ranges and rejects overlapping subnets', () => {
    expect(validateCidr('198.18.0.0/15', 4).valid).toBe(true);
    expect(validateCidr('fc00::/18', 6).valid).toBe(true);
    expect(validateCidr('172.19.0.1/30', 4).valid).toBe(true);
    expect(validateCidr('fdfe:dcba:9876::1/126', 6).valid).toBe(true);

    // Family mismatches
    expect(validateCidr('fc00::/18', 4).valid).toBe(false);
    expect(validateCidr('198.18.0.0/15', 6).valid).toBe(false);

    // Canonical defaults do not overlap
    expect(cidrsOverlap('198.18.0.0/15', '172.19.0.1/30')).toBe(false);
    expect(cidrsOverlap('fc00::/18', 'fdfe:dcba:9876::1/126')).toBe(false);

    // Overlapping subnets are caught
    expect(cidrsOverlap('fc00::/18', 'fc00::/64')).toBe(true);
    expect(cidrsOverlap('198.18.0.0/15', '198.19.0.0/24')).toBe(true);
  });
});
