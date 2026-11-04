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
  'traceRulesetFileEntry',
  'readRulesetFile',
  'readSubnetListFile',
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
    read: vi.fn(options.read || (async () => null)),
    stat: vi.fn(async (file) =>
      files.includes(file) ? { type: 'file' } : null,
    ),
    exec: vi.fn(async (bin, args) =>
      bin === '/bin/cat' ? { code: 1 } : exec(bin, args),
    ),
  };
  if (options.list) mockFs.list = vi.fn(options.list);
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
    `let _subnetListCache = {};\n${functions.join('\n')}\nreturn { performTrace, matchCommunityList, readRulesetFile, readSubnetListFile, findCachedRulesetFile };`,
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
    expect(
      tracer.fs.exec.mock.calls.filter(([bin]) =>
        [
          '/usr/bin/tachyon-core',
          '/usr/bin/sing-box',
          '/usr/sbin/sing-box',
        ].includes(bin),
      ),
    ).toHaveLength(1);
  });

  it('reads missing JSON ruleset locations only once per trace', async () => {
    const tracer = setup([], undefined, { resolvedIps: ['192.0.2.42'] });
    await tracer.performTrace('unlisted.example');

    for (const section of ['proxy', 'zapret']) {
      for (const file of [
        `${section}-lists-ruleset.json`,
        `${section}-remote-domain-ruleset.json`,
        `${section}-remote-subnet-ruleset.json`,
      ]) {
        const reads = tracer.fs.read.mock.calls.filter(([path]) =>
          path.endsWith(`/${file}`),
        );
        expect(reads).toHaveLength(3);
        expect(reads.map(([path]) => path)).toEqual([
          `/tmp/tachyon-core/rulesets/${file}`,
          `/etc/tachyon/rulesets/${file}`,
          `/tmp/sing-box/rulesets/${file}`,
        ]);
      }
    }
  });

  it('uses directory inventories to skip absent JSON and subnet files', async () => {
    const tracer = setup([], undefined, { list: async () => [] });
    const snapshots = {
      directoryEntries: new Map(),
      rulesetFiles: new Map(),
    };

    await expect(
      tracer.readRulesetFile(
        '/tmp/tachyon-core/rulesets/proxy-lists-ruleset.json',
        snapshots,
      ),
    ).resolves.toBeNull();
    await expect(
      tracer.readSubnetListFile('youtube', snapshots),
    ).resolves.toEqual([]);

    expect(tracer.fs.read).not.toHaveBeenCalled();
    expect(tracer.fs.exec).not.toHaveBeenCalledWith(
      '/bin/cat',
      expect.anything(),
    );
    expect(tracer.fs.list).toHaveBeenCalledTimes(4);
  });

  it('reads a listed alternate JSON path and falls back to stat when list is denied', async () => {
    const contents = '{"rules":[]}';
    const tracer = setup(
      ['/tmp/tachyon-core/rulesets/community-youtube.trs'],
      undefined,
      {
        list: async (directory) =>
          directory === '/tmp/sing-box/rulesets'
            ? [{ name: 'listed.json', type: 'file' }]
            : [],
        read: async (file) =>
          file === '/tmp/sing-box/rulesets/listed.json' ? contents : null,
      },
    );
    const snapshots = {
      directoryEntries: new Map(),
      rulesetFiles: new Map(),
    };

    await expect(
      tracer.readRulesetFile(
        '/tmp/tachyon-core/rulesets/listed.json',
        snapshots,
      ),
    ).resolves.toEqual({ rules: [] });
    expect(tracer.fs.read).toHaveBeenCalledTimes(1);
    expect(tracer.fs.read).toHaveBeenCalledWith(
      '/tmp/sing-box/rulesets/listed.json',
    );

    const denied = setup(
      ['/tmp/tachyon-core/rulesets/community-youtube.trs'],
      undefined,
      {
        list: async () => {
          throw new Error('Permission denied');
        },
      },
    );
    await expect(
      denied.findCachedRulesetFile('zapret', 'youtube', [], {
        directoryEntries: new Map(),
      }),
    ).resolves.toBe('/tmp/tachyon-core/rulesets/community-youtube.trs');
    expect(denied.fs.stat).toHaveBeenCalledTimes(1);

    const symlink = setup(
      ['/tmp/tachyon-core/rulesets/community-youtube.trs'],
      undefined,
      {
        list: async (directory) =>
          directory === '/tmp/tachyon-core/rulesets'
            ? [{ name: 'community-youtube.trs', type: 'symlink' }]
            : [],
      },
    );
    await expect(
      symlink.findCachedRulesetFile('zapret', 'youtube', [], {
        directoryEntries: new Map(),
      }),
    ).resolves.toBe('/tmp/tachyon-core/rulesets/community-youtube.trs');
    expect(symlink.fs.stat).toHaveBeenCalledTimes(1);
  });

  it('treats a missing inventory directory as empty without probing files', async () => {
    const tracer = setup([], undefined, {
      list: async () => {
        const error = new Error('missing directory');
        error.name = 'NotFoundError';
        throw error;
      },
    });
    const snapshots = { directoryEntries: new Map() };

    await expect(
      tracer.findCachedRulesetFile('zapret', 'youtube', [], snapshots),
    ).resolves.toBeNull();
    expect(tracer.fs.stat).not.toHaveBeenCalled();
  });

  it('refreshes directory inventories between traces', async () => {
    let hasCommunity = false;
    const directory = '/tmp/tachyon-core/rulesets';
    const tracer = setup([], undefined, {
      list: async (path) =>
        path === directory && hasCommunity
          ? [{ name: 'community-youtube.trs', type: 'file' }]
          : [],
    });

    await expect(tracer.performTrace('youtube.com')).resolves.toMatchObject({
      matched: false,
    });
    hasCommunity = true;
    await expect(tracer.performTrace('youtube.com')).resolves.toMatchObject({
      matched: true,
      ruleType: 'Community List (youtube)',
    });
    expect(
      tracer.fs.list.mock.calls.filter(([path]) => path === directory),
    ).toHaveLength(2);
  });

  it('caches missing community paths only for one trace', async () => {
    const tracer = setup([], undefined, { references: ['youtube'] });

    await tracer.performTrace('unlisted.example');
    expect(
      tracer.fs.stat.mock.calls.filter(([file]) =>
        file.endsWith('/community-youtube.trs'),
      ),
    ).toHaveLength(3);

    await tracer.performTrace('unlisted.example');
    expect(
      tracer.fs.stat.mock.calls.filter(([file]) =>
        file.endsWith('/community-youtube.trs'),
      ),
    ).toHaveLength(6);
  });

  it('keeps community match results separate for domain and resolved IP queries', async () => {
    const file = '/tmp/tachyon-core/rulesets/community-youtube.trs';
    const tracer = setup(
      [file],
      async (_bin, args) =>
        args.includes('--ip')
          ? { code: 0, stdout: '[0] match\n' }
          : { code: 0, stdout: 'no match\n' },
      { resolvedIps: ['192.0.2.42'] },
    );

    await expect(
      tracer.performTrace('unlisted.example'),
    ).resolves.toMatchObject({
      matched: true,
      ruleType: 'Resolved IP -> Community List (youtube)',
      matchedIp: '192.0.2.42',
    });
    expect(tracer.fs.stat).toHaveBeenCalledTimes(1);
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
