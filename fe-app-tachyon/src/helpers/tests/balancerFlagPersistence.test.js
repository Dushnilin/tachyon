import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

const testsDir = path.dirname(fileURLToPath(import.meta.url));
const viewsDir = path.resolve(testsDir, '../../views');
const tachyonDir = path.resolve(testsDir, '../../tachyon');

function readFile(dir, name) {
  return fs.readFileSync(path.join(dir, name), 'utf8');
}

function findOptionBlock(source, optionName) {
  const escaped = optionName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const startRe = new RegExp(
    `section\\.option\\([^;]*['"]${escaped}['"][\\s\\S]*?\\);`,
  );
  const startMatch = startRe.exec(source);
  if (!startMatch) {
    throw new Error(`Option ${optionName} not found`);
  }
  const rest = source.slice(startMatch.index);
  const nextIdx = rest
    .slice(startMatch[0].length)
    .search(/\n\s*(?:let\s+)?o\s*=\s*section\.option\(/);
  return nextIdx >= 0 ? rest.slice(0, startMatch[0].length + nextIdx) : rest;
}

describe('balancer boolean flags persistence', () => {
  it('sets rmempty = false for balancer Flag options so enabled flags serialize explicitly as 1', () => {
    const src = readFile(viewsDir, 'balancers.ts');
    for (const opt of [
      'pick_fastest',
      'switch_to_faster_same_priority',
      'interrupt_exist_connections',
    ]) {
      const block = findOptionBlock(src, opt);
      expect(block, `${opt} block must exist`).toContain('form.Flag');
      expect(block, `${opt} must disable rmempty`).toMatch(
        /o\.rmempty\s*=\s*false\s*;/,
      );
    }
  });

  it('interrupt_exist_connections.cfgvalue honors explicit 1/0 and falls back to mode defaults', () => {
    const src = readFile(viewsDir, 'balancers.ts');
    const block = findOptionBlock(src, 'interrupt_exist_connections');
    const match =
      /o\.cfgvalue\s*=\s*(function\s*\(sectionId\)\s*\{[\s\S]*?\n\s*\};)/.exec(
        block,
      );
    expect(match).toBeTruthy();
    const fnBody = match[1].replace(/;$/, '');

    const makeCfgValue = (values) =>
      new Function('uci', 'UCI_PACKAGE', `return (${fnBody});`)(
        {
          get: (_pkg, sid, opt) => values[sid]?.[opt],
        },
        'tachyon',
      );

    const cfg = makeCfgValue({
      bal_explicit_on: {
        balancer_type: 'urltest',
        mode: 'stability',
        interrupt_exist_connections: '1',
      },
      bal_explicit_off: {
        balancer_type: 'urltest',
        mode: 'least_test',
        interrupt_exist_connections: '0',
      },
      bal_stability_default: {
        balancer_type: 'urltest',
        mode: 'stability',
      },
      bal_least_test_default: {
        balancer_type: 'urltest',
        mode: 'least_test',
      },
      bal_priority_default: {
        balancer_type: 'priority',
      },
    });

    expect(cfg('bal_explicit_on')).toBe('1');
    expect(cfg('bal_explicit_off')).toBe('0');
    expect(cfg('bal_stability_default')).toBe('0');
    expect(cfg('bal_least_test_default')).toBe('1');
    expect(cfg('bal_priority_default')).toBe('1');
  });

  it('studioDeck balancer templates and card state set explicit interrupt_exist_connections', () => {
    const deckSrc = readFile(tachyonDir, 'studioDeck.ts');
    for (const mode of [
      'stability',
      'sticky',
      'least_load',
      'weighted',
      'hedged',
      'throughput',
      'round_robin',
    ]) {
      const m = new RegExp(`mode:\\s*'${mode}'[^}]*\\}`, 'm').exec(deckSrc);
      expect(m, `template for ${mode}`).toBeTruthy();
      expect(m[0]).toContain("interrupt_exist_connections: '0'");
    }
    for (const mode of ['least_test', 'passive', 'quota', 'failover']) {
      const m = new RegExp(`mode:\\s*'${mode}'[^}]*\\}`, 'm').exec(deckSrc);
      expect(m, `template for ${mode}`).toBeTruthy();
      expect(m[0]).toContain("interrupt_exist_connections: '1'");
    }
    const prioM = /balancer_type:\s*'priority'[^}]*\}/m.exec(deckSrc);
    expect(prioM).toBeTruthy();
    expect(prioM[0]).toContain("interrupt_exist_connections: '1'");

    expect(deckSrc).toContain(
      "const explicitInterrupt = String(\n        raw.interrupt_exist_connections ?? '',\n      ).trim();",
    );
  });
});
