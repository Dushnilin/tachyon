import fs from 'node:fs';
import Module from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import { describe, expect, it } from 'vitest';

const testDir = path.dirname(fileURLToPath(import.meta.url));
const sectionTsPath = path.resolve(testDir, '../../views/section.ts');
const outboundsTsPath = path.resolve(testDir, '../../views/outbounds.ts');
const wizardTsPath = path.resolve(testDir, '../connectionWizard.ts');

function createMockUci(initial = {}) {
  const store = {};
  for (const [k, v] of Object.entries(initial)) {
    store[k] = { ...v };
  }
  return {
    store,
    sections(_pkg, typeName) {
      return Object.entries(store)
        .filter(([, obj]) => obj['.type'] === typeName)
        .map(([name, obj]) => ({ '.name': name, ...obj }));
    },
    get(_pkg, sid, opt) {
      const obj = store[sid];
      if (!obj) return null;
      return opt ? (obj[opt] ?? null) : obj;
    },
    set(_pkg, sid, opt, val) {
      if (!store[sid]) store[sid] = { '.name': sid };
      store[sid][opt] = val;
    },
    unset(_pkg, sid, opt) {
      if (store[sid]) delete store[sid][opt];
    },
  };
}

function loadLuciView(tsPath, uciMock, extraExports = []) {
  const rawTs = fs.readFileSync(tsPath, 'utf8');
  const stripped = Module.stripTypeScriptTypes(rawTs, { mode: 'strip' });

  const extraObj = extraExports.length
    ? `const __extra = { ${extraExports.join(', ')} };`
    : 'const __extra = {};';
  const jsBody = stripped.replace(
    /^export default baseclass\.extend\([\s\S]*?\);\s*$/m,
    `${extraObj}\nreturn { __default: baseclass, __extra };`,
  );

  const formPrototype = {
    write: () => {},
    cfgvalue: () => '',
  };
  const makeOptionClass = (typeName, baseProto = formPrototype) => {
    const cls = function () {};
    cls.prototype = { ...baseProto, _type: typeName };
    cls.extend = (ext) =>
      makeOptionClass(typeName, { ...cls.prototype, ...(ext || {}) });
    return cls;
  };
  const formMock = {
    Value: makeOptionClass('Value'),
    ListValue: makeOptionClass('ListValue'),
    DynamicList: makeOptionClass('DynamicList'),
    Flag: makeOptionClass('Flag'),
    TextValue: makeOptionClass('TextValue'),
    DummyValue: makeOptionClass('DummyValue'),
    SectionValue: makeOptionClass('SectionValue'),
    GridSection: makeOptionClass('GridSection'),
    TableSection: makeOptionClass('TableSection'),
    NamedSection: makeOptionClass('NamedSection'),
    Map: function () {},
    JSONMap: function () {},
  };

  const sandbox = {
    _: (s) => s,
    E: () => ({}),
    L: {
      toArray: (v) =>
        Array.isArray(v)
          ? v
          : v
            ? String(v).trim().split(/\s+/).filter(Boolean)
            : [],
      env: { lang: 'en' },
    },
    uci: uciMock,
    fs: {
      stat: () => Promise.reject(new Error('no fs')),
      read: () => Promise.resolve('{}'),
      read_direct: () => Promise.resolve('{}'),
      exec_direct: () => Promise.resolve('{}'),
      exec: () => Promise.resolve({ stdout: '{}' }),
    },
    ui: {
      DynamicList: makeOptionClass('UIDynamicList'),
    },
    network: {
      getNetworks: () => Promise.resolve([]),
    },
    form: formMock,
    baseclass: {
      extend: (obj) => obj,
    },
    localDevices: {},
    main: {
      TACHYON_UCI_PACKAGE: 'tachyon',
      TACHYON_ACTION_PROVIDERS_AVAILABILITY_EVENT:
        'tachyon:action-providers-availability',
      TachyonShellMethods: {},
      getProxyUrlName: (l) => (l.includes('#') ? l.split('#')[1] : ''),
      DNS_SERVERS_BY_PROTOCOL: { udp: { '1.1.1.1': 'Cloudflare' } },
      validateUrlTestUrl: () => true,
      validateRequiredCoreDuration: () => true,
      validateOptionalCoreDuration: () => true,
      validateUrlTestTolerance: () => true,
      urlTestUrlChoices: () => ['https://www.gstatic.com/generate_204'],
      formatDnsServerDisplay: (v) => v,
    },
    window: {
      setTimeout: () => 0,
      addEventListener: () => {},
      removeEventListener: () => {},
      dispatchEvent: () => true,
    },
    document: { querySelector: () => null, getElementById: () => null },
    Promise,
    Set,
    Map,
    Array,
    Object,
    String,
    RegExp,
    JSON,
    Error,
    TypeError,
    parseInt,
    decodeURIComponent,
    encodeURIComponent,
    Math,
  };

  const fn = new vm.Script(`(function() {\n${jsBody}\n})()`);
  return fn.runInNewContext(sandbox);
}

function createOptionRecorder(formValues = {}) {
  const options = [];
  const sectionMock = {
    tab: () => {},
    formvalue: (sid, key) => formValues[sid]?.[key],
    taboption: (_tab, cls, name, title = '', description = '') => {
      const opt = {
        name,
        title,
        description,
        type: cls?.prototype?._type || 'Unknown',
        deps: [],
        values: [],
        section: {
          formvalue: (sid, key) => formValues[sid]?.[key],
        },
      };
      opt.depends = (a, b) => {
        opt.deps.push(b !== undefined ? { [a]: b } : a);
      };
      opt.value = (val, label) => {
        opt.values.push([val, label ?? val]);
      };
      options.push(opt);
      return opt;
    },
  };
  return { options, sectionMock };
}

describe('WDTT / CSQTT frontend schema & pool visibility', () => {
  it('exposes detour, all csqtt fields, pool choices, and ordering hints in section.ts', () => {
    const sectionSrc = fs.readFileSync(sectionTsPath, 'utf8');
    // Duplicate case 'csqtt' must be removed (1 in getSourceTypeLabel, 1 in getActionOptionLabel)
    expect(sectionSrc.match(/case 'csqtt':/g)?.length).toBe(2);

    const uciMock = createMockUci({
      Main_Route: {
        '.type': 'section',
        enabled: '1',
        action: 'connection',
        outbound_source_refs: ['src_csqtt', 'src_wdtt', 'src_tt'],
      },
      src_csqtt: {
        '.type': 'outbound_source',
        enabled: '1',
        name: 'CSQTT Node',
        source_type: 'csqtt',
      },
      src_wdtt: {
        '.type': 'outbound_source',
        enabled: '1',
        name: 'WDTT Node',
        source_type: 'wdtt',
      },
      src_tt: {
        '.type': 'outbound_source',
        enabled: '1',
        name: 'TrustTunnel Node',
        source_type: 'trusttunnel',
      },
      src_desync: {
        '.type': 'outbound_source',
        enabled: '1',
        name: 'Adaptive Desync',
        source_type: 'desync',
      },
    });

    const loaded = loadLuciView(sectionTsPath, uciMock, [
      'resolveEffectiveSectionOutboundSourceIds',
      'currentSectionPriorityTierChoices',
      'configureSectionSection',
      'createSectionContent',
    ]);

    const eff =
      loaded.__extra.resolveEffectiveSectionOutboundSourceIds('Main_Route');
    expect(eff.effectiveSourceIds).toEqual(['src_csqtt', 'src_wdtt', 'src_tt']);

    const tierChoices = loaded.__extra.currentSectionPriorityTierChoices(
      'Main_Route',
      [],
    );
    const tierValues = tierChoices.map((c) => c.value);
    expect(tierValues).toContain('src_csqtt');
    expect(tierValues).toContain('src_wdtt');
    expect(tierValues).toContain('src_tt');
    expect(tierValues).not.toContain('src_desync');

    const { options, sectionMock } = createOptionRecorder();
    loaded.__extra.createSectionContent(sectionMock, {}, { save: () => {} });

    const byName = (n) => options.find((o) => o.name === n);
    const detourEnabled = byName('outbound_detour_enabled');
    const detourSection = byName('outbound_detour_section');
    expect(detourEnabled?.deps).toContainEqual({ action: 'csqtt' });
    expect(detourSection?.deps).toContainEqual({
      action: 'csqtt',
      outbound_detour_enabled: '1',
    });

    const requiredCsqttFields = [
      'csqtt_vk_cookie',
      'csqtt_vk_client_ids',
      'csqtt_turn_urls',
      'csqtt_turn_username',
      'csqtt_turn_password',
      'csqtt_chunk1',
      'csqtt_wg_port',
      'csqtt_local_port',
      'csqtt_wg_private_key',
      'csqtt_wg_peer_public_key',
      'csqtt_wg_address',
    ];
    for (const field of requiredCsqttFields) {
      const opt = byName(field);
      expect(opt, `missing section.ts option ${field}`).toBeDefined();
      expect(opt?.deps).toContainEqual({ action: 'csqtt' });
    }

    const vkAuth = byName('csqtt_vk_auth_mode');
    expect(vkAuth?.description).toMatch(/TURN/i);
    expect(vkAuth?.description).toMatch(/wg/i);

    const poolRefs = byName('outbound_source_refs');
    expect(poolRefs?.description).toMatch(/first-match-wins/i);
    expect(poolRefs?.description).toMatch(/Main_Route/);
  });

  it('fixes csqtt host/port/password bindings, replaces bogus wdtt fields, and cleans up on source_type change in outbounds.ts', () => {
    const uciMock = createMockUci({
      src_migrated_csqtt: {
        '.type': 'outbound_source',
        enabled: '1',
        source_type: 'csqtt',
        csqtt_server: 'migrated.example.com',
        csqtt_password: 'secret-migrated',
      },
      src_wizard_csqtt: {
        '.type': 'outbound_source',
        enabled: '1',
        source_type: 'csqtt',
        server: 'wizard.example.com',
        server_port: '46123',
        password: 'secret-wizard',
      },
      src_wdtt: {
        '.type': 'outbound_source',
        enabled: '1',
        source_type: 'wdtt',
        warp_flow_uri: 'wdtt://example',
        wdtt_workers: '4',
        password: 'pw',
      },
    });

    const formValues = {
      src_migrated_csqtt: { source_type: 'csqtt' },
      src_wizard_csqtt: { source_type: 'csqtt' },
      src_wdtt: { source_type: 'wdtt' },
    };

    const loaded = loadLuciView(outboundsTsPath, uciMock, [
      'PROTOCOL_CHOICES',
      'configureOutboundsSection',
      'createOutboundsContent',
    ]);

    expect(loaded.__extra.PROTOCOL_CHOICES).toContain('csqtt');
    expect(loaded.__extra.PROTOCOL_CHOICES).toContain('wdtt');

    const { options, sectionMock } = createOptionRecorder(formValues);
    loaded.__extra.createOutboundsContent(sectionMock, {}, { save: () => {} });
    const byName = (n) => options.find((o) => o.name === n);

    const srvOpt = byName('server');
    const portOpt = byName('server_port');
    const passOpt = byName('password');

    expect(srvOpt.load?.('src_migrated_csqtt')).toBe('migrated.example.com');
    expect(portOpt.load?.('src_migrated_csqtt')).toBe('46000');
    expect(passOpt.load?.('src_migrated_csqtt')).toBe('secret-migrated');

    expect(srvOpt.load?.('src_wizard_csqtt')).toBe('wizard.example.com');
    expect(portOpt.load?.('src_wizard_csqtt')).toBe('46123');
    expect(passOpt.load?.('src_wizard_csqtt')).toBe('secret-wizard');

    srvOpt.write?.('src_migrated_csqtt', 'updated.example.com');
    portOpt.write?.('src_migrated_csqtt', '47000');
    passOpt.write?.('src_migrated_csqtt', 'new-secret');
    expect(uciMock.store.src_migrated_csqtt.server).toBe('updated.example.com');
    expect(uciMock.store.src_migrated_csqtt.csqtt_server).toBe(
      'updated.example.com',
    );
    expect(uciMock.store.src_migrated_csqtt.server_port).toBe('47000');
    expect(uciMock.store.src_migrated_csqtt.csqtt_server_port).toBe('47000');
    expect(uciMock.store.src_migrated_csqtt.password).toBe('new-secret');
    expect(uciMock.store.src_migrated_csqtt.csqtt_password).toBe('new-secret');

    srvOpt.remove?.('src_migrated_csqtt');
    expect(uciMock.store.src_migrated_csqtt.server).toBeUndefined();
    expect(uciMock.store.src_migrated_csqtt.csqtt_server).toBeUndefined();

    for (const field of [
      'csqtt_vk_cookie',
      'csqtt_vk_client_ids',
      'csqtt_turn_urls',
      'csqtt_turn_username',
      'csqtt_turn_password',
      'csqtt_chunk1',
      'csqtt_wg_port',
      'csqtt_local_port',
      'csqtt_wg_private_key',
      'csqtt_wg_peer_public_key',
      'csqtt_wg_address',
    ]) {
      const opt = byName(field);
      expect(opt, `missing outbounds.ts option ${field}`).toBeDefined();
      expect(opt?.deps).toContainEqual({ source_type: 'csqtt' });
    }

    expect(byName('nfqws2_opt')).toBeUndefined();
    expect(byName('direct_nfqws')).toBeUndefined();
    expect(byName('wdtt_native')).toBeUndefined();
    expect(byName('peer')).toBeUndefined();
    expect(byName('qwdtt_mode')).toBeUndefined();

    for (const wdttField of ['warp_flow_uri', 'password']) {
      const opt = byName(wdttField);
      expect(opt, `missing wdtt option ${wdttField}`).toBeDefined();
      expect(opt?.deps).toContainEqual({ source_type: 'wdtt' });
    }

    const sourceTypeOpt = byName('source_type');
    uciMock.store.src_migrated_csqtt.csqtt_vk_cookie = 'remixsid=abc';
    uciMock.store.src_migrated_csqtt.csqtt_wg_private_key = 'priv';
    sourceTypeOpt.write?.('src_migrated_csqtt', 'subscription');
    expect(uciMock.store.src_migrated_csqtt.csqtt_vk_cookie).toBeUndefined();
    expect(
      uciMock.store.src_migrated_csqtt.csqtt_wg_private_key,
    ).toBeUndefined();
    expect(uciMock.store.src_migrated_csqtt.csqtt_server_port).toBeUndefined();

    sourceTypeOpt.write?.('src_wdtt', 'subscription');
    expect(uciMock.store.src_wdtt.warp_flow_uri).toBeUndefined();
    expect(uciMock.store.src_wdtt.wdtt_workers).toBeUndefined();
  });

  it('exposes csqtt_vk_cookie, TURN, and WG fields in connectionWizard.ts', () => {
    const wizardSrc = fs.readFileSync(wizardTsPath, 'utf8');
    for (const key of [
      'csqtt_vk_cookie',
      'csqtt_vk_client_ids',
      'csqtt_turn_urls',
      'csqtt_turn_username',
      'csqtt_turn_password',
      'csqtt_chunk1',
      'csqtt_wg_port',
      'csqtt_local_port',
      'csqtt_wg_private_key',
      'csqtt_wg_peer_public_key',
      'csqtt_wg_address',
    ]) {
      expect(wizardSrc).toContain(`'${key}'`);
    }
  });
});
