import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parse } from '@babel/parser';
import { describe, expect, it } from 'vitest';

const source = fs.readFileSync(
  path.resolve(
    path.dirname(fileURLToPath(import.meta.url)),
    '../../../../luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/section.js',
  ),
  'utf8',
);
const ast = parse(source, {
  allowReturnOutsideFunction: true,
  sourceType: 'script',
});

function extractFunction(name) {
  const node = ast.program.body.find(
    (item) => item.type === 'FunctionDeclaration' && item.id.name === name,
  );
  if (!node) throw new Error(`Function ${name} not found`);
  return source.slice(node.start, node.end);
}

const getSectionOrLinkedConditionOptionCode = extractFunction(
  'getSectionOrLinkedConditionOption',
);

describe('Smart Detect user_domains with linked condition (Issue #295)', () => {
  function createEnvironment(mockUci) {
    const fn = new Function(
      'uci',
      'UCI_PACKAGE',
      'LINKED_CONDITION_OPTION_KEYS',
      'getLinkedSectionConditionId',
      `
      ${getSectionOrLinkedConditionOptionCode}
      return getSectionOrLinkedConditionOption;
      `,
    );

    const linkedKeys = new Set(['user_domains', 'user_domains_text']);
    const getLinkedId = (secId) => {
      const sec = mockUci.get('tachyon', secId);
      return sec?.condition_ref || null;
    };

    return fn(mockUci, 'tachyon', linkedKeys, getLinkedId);
  }

  it('unites user_domains from both section and linked condition without duplicates', () => {
    const store = {
      tachyon: {
        demo_sec: {
          '.name': 'demo_sec',
          condition_ref: 'cond1',
          user_domains: ['auto-blocked.example', 'shared.example'],
        },
        cond1: {
          '.name': 'cond1',
          user_domains: ['existing.example', 'shared.example'],
        },
      },
    };

    const mockUci = {
      get: (pkg, sec, opt) => {
        if (!store[pkg] || !store[pkg][sec]) return null;
        if (!opt) return store[pkg][sec];
        return store[pkg][sec][opt] ?? null;
      },
    };

    const getOption = createEnvironment(mockUci);
    const result = getOption('demo_sec', 'user_domains');

    expect(result).toEqual([
      'existing.example',
      'shared.example',
      'auto-blocked.example',
    ]);
  });

  it('unites multiline user_domains_text correctly', () => {
    const store = {
      tachyon: {
        demo_sec: {
          '.name': 'demo_sec',
          condition_ref: 'cond1',
          user_domains_text: 'detected1.test\ndetected2.test',
        },
        cond1: {
          '.name': 'cond1',
          user_domains_text: 'existing.test\ndetected1.test',
        },
      },
    };

    const mockUci = {
      get: (pkg, sec, opt) => {
        if (!store[pkg] || !store[pkg][sec]) return null;
        if (!opt) return store[pkg][sec];
        return store[pkg][sec][opt] ?? null;
      },
    };

    const getOption = createEnvironment(mockUci);
    const result = getOption('demo_sec', 'user_domains_text');

    expect(result).toBe('existing.test\ndetected1.test\ndetected2.test');
  });

  it('falls back cleanly when only section has user_domains', () => {
    const store = {
      tachyon: {
        demo_sec: {
          '.name': 'demo_sec',
          condition_ref: 'cond1',
          user_domains: ['detected-only.test'],
        },
        cond1: {
          '.name': 'cond1',
        },
      },
    };

    const mockUci = {
      get: (pkg, sec, opt) => {
        if (!store[pkg] || !store[pkg][sec]) return null;
        if (!opt) return store[pkg][sec];
        return store[pkg][sec][opt] ?? null;
      },
    };

    const getOption = createEnvironment(mockUci);
    const result = getOption('demo_sec', 'user_domains');

    expect(result).toEqual(['detected-only.test']);
  });
});
