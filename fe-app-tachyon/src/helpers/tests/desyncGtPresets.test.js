import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

const testDir = path.dirname(fileURLToPath(import.meta.url));
const outboundsPath = path.resolve(testDir, '../../views/outbounds.ts');
const studioDeckPath = path.resolve(testDir, '../../tachyon/studioDeck.ts');

describe('GT1-GT4 UDP desync presets and CS2/Faceit templates', () => {
  const outboundsSource = fs.readFileSync(outboundsPath, 'utf8');
  const studioSource = fs.readFileSync(studioDeckPath, 'utf8');

  it('exposes gt1-gt4 presets, none mode, and single UDP override fields in outbounds.ts', () => {
    for (const preset of ['gt1', 'gt2', 'gt3', 'gt4']) {
      expect(outboundsSource).toContain(`o.value('${preset}'`);
      expect(outboundsSource).toContain(`desync_preset: '${preset}'`);
    }
    expect(outboundsSource).toContain("o.value('none'");

    const payloadMatches =
      outboundsSource.match(/'desync_udp_fake_payload'/g) || [];
    const rangeMatches = outboundsSource.match(/'desync_udp_out_range'/g) || [];
    expect(payloadMatches.length).toBe(1);
    expect(rangeMatches.length).toBe(1);
  });

  it('defines cs2_faceit and cs2_udp_desync templates with ports, move-to-top, and neutral text', () => {
    expect(studioSource).toContain("id: 'cs2_faceit'");
    expect(studioSource).toContain("title: 'CS2 / Faceit / Community Servers'");
    expect(studioSource).toContain("id: 'cs2_udp_desync'");
    expect(studioSource).toContain("'50101-65535'");
    expect(studioSource).toContain('tachyon-studio-card__order-warn');

    const forbidden = /ТСПУ|РКН|Роскомнадзор|обход блокировок|пробив|🎮/u;
    const cs2Start = studioSource.indexOf("id: 'cs2_faceit'");
    const cs2Block = studioSource.slice(cs2Start, cs2Start + 700);
    expect(cs2Block).not.toMatch(forbidden);
  });
});
