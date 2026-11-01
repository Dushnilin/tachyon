import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { describe, expect, it, vi } from 'vitest';

const source = readFileSync(
  new URL(
    '../../../../luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/conditions.js',
    import.meta.url,
  ),
  'utf8',
);
const referenceKeys = ['rule_set', 'rule_set_with_subnets', 'domain_ip_lists'];
const youtubeUrl =
  'https://github.com/MetaCubeX/meta-rules-dat/raw/refs/heads/sing/geo/geosite/youtube.srs';
const signedUrl =
  'https://example.com/lists//custom.json?names=one,two&token=a%2Fb#version';

// Run the shipped LuCI module and its actual option callbacks. Only the form
// registry and UCI storage are replaced; no parsing or save logic is copied.
function createEditor() {
  const db = {
    condition: { '.name': 'condition', '.type': 'condition' },
    linked: {
      '.name': 'linked',
      '.type': 'section',
      condition_refs: ['condition'],
    },
    composite: {
      '.name': 'composite',
      '.type': 'section',
      condition_refs: ['condition', 'other'],
    },
  };
  const uci = {
    get: (_pkg, id, key) => db[id]?.[key],
    set: vi.fn((_pkg, id, key, value) => {
      db[id][key] = value;
    }),
    unset: vi.fn((_pkg, id, key) => {
      delete db[id][key];
    }),
    sections: (_pkg, type) =>
      Object.values(db).filter((entry) => entry['.type'] === type),
  };
  const options = {};
  const pending = {};
  const context = {
    uci,
    _: (text) => text,
    main: {},
    localDevices: {},
    baseclass: { extend: (exports) => exports },
    form: {
      DynamicList: {
        prototype: { formvalue: () => [] },
      },
    },
    document: {
      getElementById: (key) => ({
        querySelectorAll: () => [{ value: pending[key] || '' }],
      }),
    },
  };
  const module = vm.runInNewContext(`(function () {\n${source}\n})()`, context);
  module.createConditionsContent({
    tab() {},
    taboption(_tab, _type, key) {
      options[key] = {
        depends() {},
        value() {},
        cbid: () => key,
      };
      return options[key];
    },
  });
  return { db, uci, options, pending };
}

describe.each(referenceKeys)('Traffic Conditions %s references', (key) => {
  it('saves complete URLs, trims empty entries and deduplicates exact values', () => {
    const { db, options } = createEditor();
    const refs = [youtubeUrl, signedUrl, 'http://example.com/list.txt'];
    options[key].write('condition', [' ', ...refs, ` ${youtubeUrl} `]);
    expect(db.condition[key]).toEqual(refs);
    expect(db.linked[key]).toEqual(refs);
    expect(db.composite[key]).toBeUndefined();
  });

  it('does not rewrite unchanged references in the condition or linked section', () => {
    const { db, uci, options } = createEditor();
    db.condition[key] = [signedUrl];
    db.linked[key] = [signedUrl];
    options[key].write('condition', [signedUrl]);
    expect(uci.set).not.toHaveBeenCalled();
    expect(uci.unset).not.toHaveBeenCalled();
  });

  it('replaces an already truncated URL when the complete URL is entered again', () => {
    const { db, options } = createEditor();
    db.condition[key] = ['https:'];
    db.linked[key] = ['https:'];
    options[key].write('condition', [youtubeUrl]);
    expect(db.condition[key]).toEqual([youtubeUrl]);
    expect(db.linked[key]).toEqual([youtubeUrl]);
  });

  it('preserves local paths and named rule sets', () => {
    const { db, options } = createEditor();
    const refs = ['/etc/tachyon/rulesets/local.srs', 'youtube'];
    options[key].write('condition', refs);
    expect(db.condition[key]).toEqual(refs);
  });

  it('accepts whitespace-separated scalar references without splitting URL punctuation', () => {
    const { db, options } = createEditor();
    options[key].write('condition', ` ${youtubeUrl}\r\n${signedUrl} `);
    expect(db.condition[key]).toEqual([youtubeUrl, signedUrl]);
  });

  it('saves a pending URL that has not been added with the plus button', () => {
    const { db, options, pending } = createEditor();
    pending[key] = signedUrl;
    options[key].write('condition', options[key].formvalue('condition'));
    expect(db.condition[key]).toEqual([signedUrl]);
    expect(db.linked[key]).toEqual([signedUrl]);
  });

  it('synchronizes an automatically named child condition to its parent', () => {
    const { db, options } = createEditor();
    db.cond_parent = { '.name': 'cond_parent', '.type': 'condition' };
    db.parent = { '.name': 'parent', '.type': 'section' };
    options[key].write('cond_parent', [signedUrl]);
    expect(db.cond_parent[key]).toEqual([signedUrl]);
    expect(db.parent[key]).toEqual([signedUrl]);
  });

  it.each(['write', 'remove'])(
    'clears condition and linked references through %s',
    (action) => {
      const { db, options } = createEditor();
      db.condition[key] = [youtubeUrl];
      db.linked[key] = [youtubeUrl];
      options[key][action]('condition', []);
      expect(db.condition[key]).toBeUndefined();
      expect(db.linked[key]).toBeUndefined();
    },
  );
});

describe('Traffic Conditions list parsing boundaries', () => {
  it('counts a URL containing commas as one reference in the summary', () => {
    const { db, options } = createEditor();
    db.condition.rule_set = [signedUrl];
    expect(options._summary.cfgvalue('condition')).toContain('Lists: 1');
  });

  it('keeps comment parsing for auto-detected domains and service identifiers', () => {
    const { db, options } = createEditor();
    options.user_domains.write(
      'condition',
      'example.com // comment\n# ignored\nother.example, third.example # note',
    );
    expect(db.condition.user_domains).toEqual([
      'example.com',
      'other.example',
      'third.example',
    ]);
    options.community_lists.write('condition', 'youtube, telegram // note');
    expect(db.condition.community_lists).toEqual(['youtube', 'telegram']);
  });
});
