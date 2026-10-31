import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parse } from '@babel/parser';
import { describe, expect, it, vi } from 'vitest';

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
const names = [
  'matchDomainInList',
  'matchDomainInRuleset',
  'detectQueryType',
  'readRulesetFile',
  'findCachedRulesetFile',
  'matchCommunityList',
  'performTrace',
];
const functions = names.map((name) => {
  const node = ast.program.body.find(
    (item) => item.type === 'FunctionDeclaration' && item.id.name === name,
  );
  if (!node) throw new Error(`Function ${name} not found`);
  return source.slice(node.start, node.end);
});

function setup(files, exec = async () => ({ code: 0, stdout: '[0] match\n' })) {
  const sections = [
    { '.name': 'proxy', enabled: '1', action: 'connection' },
    {
      '.name': 'zapret',
      enabled: '1',
      action: 'zapret2',
      community_lists: ['youtube'],
    },
  ];
  const mockFs = {
    read: vi.fn(async () => null),
    stat: vi.fn(async (file) =>
      files.includes(file) ? { type: 'file' } : null,
    ),
    exec: vi.fn(async (bin, args) =>
      bin === '/bin/cat' ? { code: 1 } : exec(bin, args),
    ),
  };
  const get = (_pkg, id, key) =>
    sections.find((section) => section['.name'] === id)?.[key];
  const resolve = vi.fn(async () => []);
  const dependencies = {
    fs: mockFs,
    uci: { sections: () => sections, get },
    UCI_PACKAGE: 'tachyon',
    _communityDomainsCache: {},
    getSectionEffectiveOptionValues: (id, key) => get('tachyon', id, key) || [],
    getSectionEffectiveScalar: (id, key) => get('tachyon', id, key),
    getSectionGeoCountries: () => [],
    resolveDomainToIps: resolve,
  };
  const api = new Function(
    ...Object.keys(dependencies),
    `${functions.join('\n')}\nreturn { performTrace, matchCommunityList };`,
  )(...Object.values(dependencies));
  return { ...api, fs: mockFs, resolve };
}

describe('routing section tracer community caches', () => {
  it('finds YouTube in a native TRS cache before falling back to DNS/Direct', async () => {
    const file = '/tmp/tachyon-core/rulesets/community-youtube.trs';
    const tracer = setup([file]);
    await expect(tracer.performTrace('YouTube.com')).resolves.toMatchObject({
      matched: true,
      sectionName: 'zapret',
      action: 'zapret2',
      ruleType: 'Community List (youtube)',
    });
    expect(tracer.fs.exec).toHaveBeenCalledWith('/usr/bin/tachyon-core', [
      'rule-set',
      'match',
      file,
      '--domain',
      'youtube.com',
    ]);
    expect(tracer.resolve).not.toHaveBeenCalled();
  });

  it('uses the persistent native cache if its runtime copy is unavailable', async () => {
    const file = '/etc/tachyon/rulesets/community-youtube.trs';
    const tracer = setup([file]);
    await expect(tracer.performTrace('youtube.com')).resolves.toMatchObject({
      matched: true,
    });
    expect(tracer.fs.exec).toHaveBeenCalledWith(
      '/usr/bin/tachyon-core',
      expect.arrayContaining([file]),
    );
  });

  it('preserves legacy SRS matching when tachyon-core is not installed', async () => {
    const file = '/tmp/sing-box/rulesets/community-youtube.srs';
    const tracer = setup([file], async (bin) => {
      if (bin === '/usr/bin/tachyon-core') throw new Error('not installed');
      return { code: 0, stdout: '[0] match\n' };
    });
    await expect(tracer.performTrace('youtube.com')).resolves.toMatchObject({
      matched: true,
    });
    expect(tracer.fs.exec).toHaveBeenCalledWith(
      '/usr/bin/sing-box',
      expect.arrayContaining([file]),
    );
  });

  it('does not turn a negative binary match into a routing match', async () => {
    const tracer = setup(
      ['/tmp/tachyon-core/rulesets/community-youtube.trs'],
      async () => ({ code: 0, stdout: 'no match\n' }),
    );
    await expect(
      tracer.performTrace('unlisted.example'),
    ).resolves.toMatchObject({ matched: false });
  });

  it('does not replace a valid TRS miss with a match from an older SRS cache', async () => {
    const trs = '/tmp/tachyon-core/rulesets/community-youtube.trs';
    const srs = '/etc/tachyon/rulesets/community-youtube.srs';
    const tracer = setup([trs, srs], async (_bin, args) => ({
      code: 0,
      stdout: args.includes(trs) ? 'no match\n' : '[0] match\n',
    }));
    await expect(
      tracer.performTrace('unlisted.example'),
    ).resolves.toMatchObject({ matched: false });
    expect(tracer.fs.exec).not.toHaveBeenCalledWith(
      expect.anything(),
      expect.arrayContaining([srs]),
    );
  });

  it('falls back to SRS if a leftover TRS cache cannot be read by installed binaries', async () => {
    const trs = '/tmp/tachyon-core/rulesets/community-youtube.trs';
    const srs = '/tmp/sing-box/rulesets/community-youtube.srs';
    const tracer = setup([trs, srs], async (bin, args) => {
      if (bin === '/usr/bin/tachyon-core') throw new Error('not installed');
      return args.includes(trs)
        ? { code: 1, stderr: 'unsupported binary format' }
        : { code: 0, stdout: '[0] match\n' };
    });
    await expect(tracer.performTrace('youtube.com')).resolves.toMatchObject({
      matched: true,
    });
    expect(tracer.fs.exec).toHaveBeenCalledWith(
      '/usr/bin/sing-box',
      expect.arrayContaining([srs]),
    );
  });

  it('does not mistake a failed CLI call for a positive match', async () => {
    const tracer = setup(
      ['/tmp/tachyon-core/rulesets/community-youtube.trs'],
      async () => ({ code: 1, stderr: 'rule-set match failed' }),
    );
    await expect(tracer.performTrace('youtube.com')).resolves.toMatchObject({
      matched: false,
    });
  });

  it('also checks native subnet lists through the IP matching option', async () => {
    const file = '/tmp/tachyon-core/rulesets/community-telegram.trs';
    const tracer = setup([file]);
    await expect(
      tracer.matchCommunityList('zapret', 'telegram', '149.154.160.1', 'ip'),
    ).resolves.toBe(true);
    expect(tracer.fs.exec).toHaveBeenCalledWith('/usr/bin/tachyon-core', [
      'rule-set',
      'match',
      file,
      '--ip',
      '149.154.160.1',
    ]);
  });
});
