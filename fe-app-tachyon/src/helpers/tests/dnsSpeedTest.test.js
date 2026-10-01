import { describe, expect, it } from 'vitest';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const source = fs.readFileSync(
  path.resolve(
    path.dirname(fileURLToPath(import.meta.url)),
    '../../../../luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/dns_speed_test.js',
  ),
  'utf8',
);
const module = new Function('baseclass', '_', source)(
  { extend: (value) => value },
  (value) => value,
);

describe('DNS speed test host settings', () => {
  it('normalizes URLs, IDNs and repeated hostnames', () => {
    expect(
      module.normalizeDomains(
        'https://Example.com/games\nexample.com\nhttps://пример.рф/',
      ),
    ).toEqual(['example.com', 'xn--e1afmkfd.xn--p1ai']);
  });
  it.each([
    '',
    'https://user:pass@example.com/',
    'a..example',
    '-a.example',
    '1.1.1.1',
    'localhost',
    'a'.repeat(64) + '.example',
  ])('rejects invalid domain input: %s', (value) => {
    expect(() => module.normalizeDomains(value)).toThrow();
  });
  it('limits the host list to 32 entries', () => {
    expect(() =>
      module.normalizeDomains(
        Array.from({ length: 33 }, (_, i) => `host${i}.example`).join('\n'),
      ),
    ).toThrow();
  });
  it('never displays failure or missing data as a fast response', () => {
    expect(module.formatMs(null)).toBe('Unavailable');
    expect(module.formatMs(NaN)).toBe('Unavailable');
    expect(module.formatMs(48.701)).toBe('48.70 ms');
  });
});
