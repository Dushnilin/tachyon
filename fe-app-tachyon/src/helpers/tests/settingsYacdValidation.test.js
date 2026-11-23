import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

const testDir = path.dirname(fileURLToPath(import.meta.url));
const settingsPath = path.resolve(testDir, '../../views/settings.ts');

describe('YACD secret key validation rules', () => {
  const settingsSource = fs.readFileSync(settingsPath, 'utf8');

  it('requires yacd_secret_key only when WAN access is enabled', () => {
    const start = settingsSource.indexOf("'yacd_secret_key'");
    expect(start).toBeGreaterThan(-1);
    const block = settingsSource.slice(start, start + 650);

    expect(block).toContain("formvalue(section_id, 'enable_yacd') === '1'");
    expect(block).toContain(
      "formvalue(section_id, 'enable_yacd_wan_access') === '1'",
    );
    expect(block).toContain(
      'Secret key is required when YACD WAN access is enabled',
    );
    expect(settingsSource).not.toContain(
      'Secret key is required when YACD is enabled',
    );
  });
});
