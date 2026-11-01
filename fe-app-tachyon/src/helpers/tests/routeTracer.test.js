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
  'matchConfiguredRulesets',
  'performTrace',
  'performTraceRules',
];
const functions = names.map((name) => {
  const node = ast.program.body.find(
    (item) => item.type === 'FunctionDeclaration' && item.id.name === name,
  );
  if (!node) throw new Error(`Function ${name} not found`);
  return source.slice(node.start, node.end);
});

function setup(
  files,
  exec = async () => ({ code: 0, stdout: '[0] match\n' }),
  options = {},
) {
  const sections = [
    { '.name': 'proxy', enabled: '1', action: 'connection' },
    {
      '.name': 'zapret',
      enabled: '1',
      action: 'zapret2',
      community_lists: ['youtube'],
      rule_set: options.references || [],
      rule_set_with_subnets: options.subnetReferences || [],
      domain: options.domains || [],
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
  if (options.proxyReferences) sections[0].rule_set = options.proxyReferences;
  const resolve = vi.fn(async () => options.resolvedIps || []);
  const dependencies = {
    fs: mockFs,
    _: (text) => ({ format: (value) => text.replace('%s', value) }),
    matchIpInCidrs: () => null,
    readSubnetListFile: async () => [],
    matchIpInRuleset: () => null,
    getSharedCdnWarning: () => '',
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

describe('routing section tracer configured rule sets', () => {
  const url = 'https://lists.example/zapret.srs?rev=2';
  const snapshot = '/tmp/tachyon-core/rulesets/trace-custom.srs';
  const matchingExec = async (bin) =>
    bin === '/usr/bin/tachyon-read'
      ? { code: 0, stdout: `${snapshot}\n` }
      : { code: 0, stdout: '[0] match\n' };

  it('finds a remote SRS domain at its section priority without DNS', async () => {
    const tracer = setup([], matchingExec, { references: [url] });
    await expect(
      tracer.performTrace('R2.Cloudflarestorage.com'),
    ).resolves.toMatchObject({
      matched: true,
      sectionName: 'zapret',
      action: 'zapret2',
      ruleType: 'Rule Set',
      sourceUrls: [url],
      priority: 2,
    });
    expect(tracer.fs.exec).toHaveBeenCalledWith('/usr/bin/tachyon-read', [
      'extract_ruleset',
      url,
    ]);
    expect(tracer.fs.exec).toHaveBeenCalledWith('/usr/bin/tachyon-core', [
      'rule-set',
      'match',
      snapshot,
      '--domain',
      'r2.cloudflarestorage.com',
    ]);
    expect(tracer.resolve).not.toHaveBeenCalled();
  });

  it('preserves section ordering when two rule sets match', async () => {
    const tracer = setup([], matchingExec, {
      references: [url],
      proxyReferences: ['https://lists.example/vpn.srs'],
    });
    await expect(
      tracer.performTrace('r2.cloudflarestorage.com'),
    ).resolves.toMatchObject({
      sectionName: 'proxy',
      action: 'connection',
      priority: 1,
    });
    expect(tracer.fs.exec).not.toHaveBeenCalledWith('/usr/bin/tachyon-read', [
      'extract_ruleset',
      url,
    ]);
  });

  it.each(['192.0.2.42', '2001:db8::42'])(
    'checks remote subnet rule sets for %s',
    async (ip) => {
      const tracer = setup([], matchingExec, { subnetReferences: [url] });
      await expect(tracer.performTrace(ip)).resolves.toMatchObject({
        matched: true,
        sectionName: 'zapret',
      });
      expect(tracer.fs.exec).toHaveBeenCalledWith('/usr/bin/tachyon-core', [
        'rule-set',
        'match',
        snapshot,
        '--ip',
        ip,
      ]);
    },
  );

  it('checks a custom subnet set after DNS and reuses one snapshot per trace', async () => {
    const tracer = setup(
      [],
      async (bin, args) =>
        bin === '/usr/bin/tachyon-read'
          ? { code: 0, stdout: snapshot }
          : {
              code: 0,
              stdout: args.includes('--ip') ? '[0] match' : 'no match',
            },
      { references: [url], resolvedIps: ['192.0.2.42'] },
    );
    await expect(tracer.performTrace('cdn.example')).resolves.toMatchObject({
      matched: true,
      sectionName: 'zapret',
      ruleType: 'Resolved IP -> Rule Set',
      matchedIp: '192.0.2.42',
    });
    expect(
      tracer.fs.exec.mock.calls.filter(
        ([bin]) => bin === '/usr/bin/tachyon-read',
      ),
    ).toHaveLength(1);
  });

  it('reads a fresh snapshot for every trace after a list update', async () => {
    let version = 0;
    const tracer = setup(
      [],
      async (bin) =>
        bin === '/usr/bin/tachyon-read'
          ? { code: 0, stdout: `${snapshot}.${++version}` }
          : { code: 0, stdout: version === 1 ? 'no match' : '[0] match' },
      { references: [url] },
    );
    await expect(tracer.performTrace('cdn.example')).resolves.toMatchObject({
      matched: false,
    });
    await expect(tracer.performTrace('cdn.example')).resolves.toMatchObject({
      matched: true,
    });
    expect(version).toBe(2);
  });

  it('reports a missing loaded cache instead of silently claiming Direct', async () => {
    const tracer = setup(
      [],
      async () => ({ code: 1, stderr: 'cache unavailable' }),
      { references: [url] },
    );
    await expect(tracer.performTrace('cdn.example')).rejects.toThrow(
      'Cannot read the loaded rule-set',
    );
    expect(tracer.resolve).not.toHaveBeenCalled();
  });

  it('keeps an explicit domain match when another list in the same section is unavailable', async () => {
    const tracer = setup([], async () => ({ code: 1 }), {
      references: [url],
      domains: ['r2.cloudflarestorage.com'],
    });
    await expect(
      tracer.performTrace('r2.cloudflarestorage.com'),
    ).resolves.toMatchObject({
      matched: true,
      sectionName: 'zapret',
      ruleType: 'Domains (UCI)',
    });
    expect(tracer.fs.exec).not.toHaveBeenCalledWith(
      '/usr/bin/tachyon-read',
      expect.anything(),
    );
  });

  it('reports an unreadable binary instead of silently claiming Direct', async () => {
    const tracer = setup(
      [],
      async (bin) =>
        bin === '/usr/bin/tachyon-read'
          ? { code: 0, stdout: snapshot }
          : { code: 1 },
      { references: [url] },
    );
    await expect(tracer.performTrace('cdn.example')).rejects.toThrow(
      'Cannot match the loaded rule-set',
    );
  });

  it('matches configured local JSON through the installed core', async () => {
    const file = '/etc/tachyon/custom.json';
    const tracer = setup(
      [],
      async (bin) =>
        bin === '/usr/bin/tachyon-read'
          ? { code: 0, stdout: file }
          : { code: 0, stdout: '[0] match' },
      { references: [file] },
    );
    await expect(tracer.performTrace('cdn.example')).resolves.toMatchObject({
      matched: true,
      sourceUrls: [file],
    });
  });

  it('shows a source-version warning even when the result would otherwise be Direct', async () => {
    const tracer = setup(
      [],
      async (bin) =>
        bin === '/usr/bin/tachyon-read'
          ? {
              code: 0,
              stdout: snapshot,
              stderr:
                'Checked current remote source; active version may differ.',
            }
          : { code: 0, stdout: 'no match' },
      { references: [url] },
    );
    await expect(tracer.performTrace('cdn.example')).resolves.toMatchObject({
      matched: false,
      rulesetWarnings: [
        'Checked current remote source; active version may differ.',
      ],
    });
  });
});
