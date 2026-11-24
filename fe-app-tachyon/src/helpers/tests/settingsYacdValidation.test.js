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
    const block = settingsSource.slice(start, start + 900);

    expect(block).toContain("formvalue(section_id, 'enable_yacd') === '1'");
    expect(block).toContain(
      "formvalue(section_id, 'enable_yacd_wan_access') === '1'",
    );
    expect(block).toContain("data-tachyon-ui-mode') === 'simple'");
    expect(block).toContain(
      'Secret key is required when YACD WAN access is enabled',
    );
    expect(settingsSource).not.toContain(
      'Secret key is required when YACD is enabled',
    );
  });

  it('skips validation in simple mode and enforces secret only when WAN access is active in advanced mode', () => {
    const start = settingsSource.indexOf("'yacd_secret_key'");
    const fnStart = settingsSource.indexOf('o.validate = function', start);
    const fnEnd = settingsSource.indexOf('};', fnStart);
    const fnBody = settingsSource.slice(fnStart, fnEnd + 2);
    const validateFn = new Function(
      'document',
      '_',
      `const o = {}; ${fnBody} return o.validate;`,
    );
    const makeCtx = (yacd, wan) => ({
      section: {
        formvalue(_sid, key) {
          if (key === 'enable_yacd') return yacd;
          if (key === 'enable_yacd_wan_access') return wan;
          return '';
        },
      },
    });
    const tr = (s) => s;

    const simpleDoc = {
      body: {
        getAttribute: (k) => (k === 'data-tachyon-ui-mode' ? 'simple' : null),
      },
    };
    const advDoc = {
      body: {
        getAttribute: (k) => (k === 'data-tachyon-ui-mode' ? 'advanced' : null),
      },
    };

    const runSimple = validateFn(simpleDoc, tr).bind(makeCtx('1', '1'));
    expect(runSimple('settings', '')).toBe(true);

    const runAdvWan = validateFn(advDoc, tr).bind(makeCtx('1', '1'));
    expect(runAdvWan('settings', '')).toBe(
      'Secret key is required when YACD WAN access is enabled',
    );
    expect(runAdvWan('settings', 'my-secret')).toBe(true);

    const runAdvLan = validateFn(advDoc, tr).bind(makeCtx('1', '0'));
    expect(runAdvLan('settings', '')).toBe(true);
  });
});
