import { describe, expect, it } from 'vitest';
import {
  WIZARD_QUICK_PRESETS,
  detectQuickConnectionInput,
} from '../connectionWizard';

describe('connectionWizard Quick Start Presets', () => {
  it('provides ready-to-use 1-click presets including ru_all_in_one and dpi_desync_no_vpn', () => {
    const ids = WIZARD_QUICK_PRESETS.map((p) => p.id);
    expect(ids).toEqual([
      'ru_all_in_one',
      'ru_essential',
      'ru_max_adblock',
      'gaming_stream',
      'dpi_desync_no_vpn',
    ]);

    const ruAll = WIZARD_QUICK_PRESETS.find((p) => p.id === 'ru_all_in_one');
    expect(ruAll?.requiresConnection).toBe(true);
    expect(ruAll?.enableDirectGamesBypass).toBe(true);
    expect(ruAll?.enableAutoUrlTest).toBe(true);
    expect(ruAll?.presetIds).toContain('youtube');
    expect(ruAll?.presetIds).toContain('discord');
    expect(ruAll?.presetIds).toContain('ai');

    const desync = WIZARD_QUICK_PRESETS.find(
      (p) => p.id === 'dpi_desync_no_vpn',
    );
    expect(desync?.requiresConnection).toBe(false);
  });

  it('auto-detects subscription URLs, proxy share links, AmneziaWG configs, and FPTN tokens', () => {
    expect(detectQuickConnectionInput('').valid).toBe(false);

    const sub = detectQuickConnectionInput(
      'https://sub.example.com/api/v1/abc',
    );
    expect(sub.valid).toBe(true);
    expect(sub.method).toBe('subscription');
    expect(sub.count).toBe(1);

    for (const input of [
      'happ://crypt5/synthetic',
      'happ://crypt4/synthetic',
      'crypt5/synthetic',
    ]) {
      const encrypted = detectQuickConnectionInput(input);
      expect(encrypted.valid).toBe(true);
      expect(encrypted.method).toBe('subscription');
    }
    expect(detectQuickConnectionInput('happ://crypt6/synthetic').valid).toBe(
      false,
    );

    const links = detectQuickConnectionInput(
      'vless://uuid@example.com:443?security=reality#DE\nhysteria2://pass@example.com:8443#FI',
    );
    expect(links.valid).toBe(true);
    expect(links.method).toBe('proxy_links');
    expect(links.count).toBe(2);

    const awg = detectQuickConnectionInput('vpn://eyJ...');
    expect(awg.valid).toBe(true);
    expect(awg.method).toBe('amnezia_config');

    const wgConf = detectQuickConnectionInput(
      '[Interface]\nPrivateKey = abc\n[Peer]\nPublicKey = def',
    );
    expect(wgConf.valid).toBe(true);
    expect(wgConf.method).toBe('amnezia_config');

    const fptn = detectQuickConnectionInput('fptn://token123');
    expect(fptn.valid).toBe(true);
    expect(fptn.method).toBe('fptn');

    const invalid = detectQuickConnectionInput('not-a-valid-link');
    expect(invalid.valid).toBe(false);
  });
});
