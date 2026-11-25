import fs from 'node:fs';
import Module from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import { describe, expect, it, vi } from 'vitest';

const testDir = path.dirname(fileURLToPath(import.meta.url));
const sectionTsPath = path.resolve(testDir, '../../views/section.ts');
const tachyonTsPath = path.resolve(testDir, '../../views/tachyon.ts');

function createMockUci(initial = {}) {
  const store = {};
  for (const [k, v] of Object.entries(initial)) {
    store[k] = { ...v };
  }
  return {
    store,
    state: {
      values: { tachyon: store },
      creates: { tachyon: {} },
      changes: { tachyon: {} },
      deletes: { tachyon: {} },
    },
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
    resolveSID: (_pkg, sid) => sid,
    remove: vi.fn(),
  };
}

function createFormMock(baseLoadImpl) {
  const baseLoad = baseLoadImpl || vi.fn(() => Promise.resolve([]));
  const formPrototype = {
    write: () => {},
    cfgvalue: () => '',
    load: baseLoad,
    value: () => {},
  };
  const makeOptionClass = (typeName, baseProto = formPrototype) => {
    const cls = function () {};
    cls.prototype = { ...baseProto, _type: typeName };
    cls.extend = (ext) => {
      const sub = makeOptionClass(typeName, {
        ...cls.prototype,
        ...(ext || {}),
      });
      sub.prototype.super = function (method, ...args) {
        const fn = cls.prototype[method];
        return typeof fn === 'function' ? fn.apply(this, args) : undefined;
      };
      return sub;
    };
    return cls;
  };
  return {
    Value: makeOptionClass('Value'),
    ListValue: makeOptionClass('ListValue'),
    DynamicList: makeOptionClass('DynamicList'),
    Flag: makeOptionClass('Flag'),
    TextValue: makeOptionClass('TextValue'),
    DummyValue: makeOptionClass('DummyValue'),
    SectionValue: makeOptionClass('SectionValue'),
    GridSection: makeOptionClass('GridSection', {
      ...formPrototype,
      addModalOptions: vi.fn(),
      renderMoreOptionsModal: vi.fn(() => Promise.resolve()),
      handleModalCancel: vi.fn(),
    }),
    TableSection: makeOptionClass('TableSection', {
      ...formPrototype,
      renderRowActions: vi.fn(() => ({})),
    }),
    NamedSection: makeOptionClass('NamedSection'),
    Map: function () {},
    JSONMap: function () {},
  };
}

function loadViewModule(tsPath, overrides = {}, extraExports = []) {
  const rawTs = fs.readFileSync(tsPath, 'utf8');
  const stripped = Module.stripTypeScriptTypes(rawTs, { mode: 'strip' });
  const extraObj = extraExports.length
    ? `const __extra = { ${extraExports.join(', ')} };`
    : 'const __extra = {};';
  const jsBody = stripped.replace(
    /^export default (?:baseclass|view)\.extend\([\s\S]*?\);\s*$/m,
    `${extraObj}\nreturn { __extra };`,
  );

  const formMock = overrides.form || createFormMock();
  const sandbox = {
    _: (s) => s,
    E: () => ({ style: {} }),
    L: {
      toArray: (v) =>
        Array.isArray(v)
          ? v
          : v
            ? String(v).trim().split(/\s+/).filter(Boolean)
            : [],
      bind: (fn, ctx) => fn.bind(ctx),
      resource: (p) => p,
      env: { lang: 'en' },
    },
    uci: overrides.uci || createMockUci(),
    fs: {
      stat: () => Promise.reject(new Error('no fs')),
      read: () => Promise.resolve('{}'),
      read_direct: () => Promise.resolve('{}'),
      exec_direct: () => Promise.resolve('{}'),
      exec: () => Promise.resolve({ stdout: '{}' }),
    },
    ui: {
      DynamicList: formMock.DynamicList,
      hideModal: vi.fn(),
      addNotification: vi.fn(),
      changes: { init: vi.fn(), setIndicator: vi.fn() },
    },
    network: overrides.network || {
      getDevices: () => Promise.resolve([]),
      getNetworks: () => Promise.resolve([]),
    },
    rpc: { declare: () => () => Promise.resolve({}) },
    dom: { findClassInstance: () => null },
    widgets: {},
    form: formMock,
    baseclass: { extend: (obj) => obj },
    view: { extend: (obj) => obj },
    localDevices: {},
    dnsSpeedTest: {},
    settings: {},
    section: {},
    conditions: {},
    outbounds: {},
    balancers: {},
    server: {},
    parental: {},
    dashboard: {},
    monitoring: {},
    diagnostic: {},
    updates: {},
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
      validateInterfaceName: () => ({ valid: true }),
      urlTestUrlChoices: () => ['https://www.gstatic.com/generate_204'],
      formatDnsServerDisplay: (v) => v,
      injectGlobalStyles: () => {},
      applyAutofillProtection: () => {},
    },
    window: {
      setTimeout: () => 0,
      addEventListener: () => {},
      removeEventListener: () => {},
      dispatchEvent: () => true,
    },
    document: { querySelector: () => null, getElementById: () => null },
    console: overrides.console || globalThis.console,
    fetch: () => Promise.resolve({ ok: true, text: () => Promise.resolve('') }),
    Promise,
    Set,
    Map,
    Array,
    Object,
    String,
    Number,
    Boolean,
    RegExp,
    JSON,
    Error,
    TypeError,
    ReferenceError,
    SyntaxError,
    parseInt,
    decodeURIComponent,
    encodeURIComponent,
    Math,
  };

  const fn = new vm.Script(
    `(function() {\nString.prototype.format = function() { const args = arguments; let i = 0; return this.replace(/%s/g, () => String(args[i++] ?? '')); };\n${jsBody}\n})()`,
  );
  return fn.runInNewContext(sandbox);
}

describe('PR #506: Priority group nodes with mixed direct + group sources', () => {
  it('keeps explicit group sources (source_refs, primary_refs, backup_refs) when direct source is attached', () => {
    const uciMock = createMockUci({
      sn: {
        '.type': 'outbound_source',
        enabled: '1',
        source_type: 'proxy_links',
        proxy_links: ['vless://1@198.51.100.1:443#DirectNode1'],
      },
      ps1: {
        '.type': 'outbound_source',
        enabled: '1',
        source_type: 'subscription',
        proxy_links: ['vless://2@198.51.100.2:443#GroupNode1'],
      },
      ps2: {
        '.type': 'outbound_source',
        enabled: '1',
        source_type: 'subscription',
        proxy_links: ['vless://3@198.51.100.3:443#PrimaryNode1'],
      },
      ps3: {
        '.type': 'outbound_source',
        enabled: '1',
        source_type: 'subscription',
        proxy_links: ['vless://4@198.51.100.4:443#BackupNode1'],
      },
      ps_disabled_grp: {
        '.type': 'outbound_source',
        enabled: '1',
        source_type: 'subscription',
        proxy_links: ['vless://5@198.51.100.5:443#DisabledGroupNode'],
      },
      grp_mix: {
        '.type': 'outbound_group',
        enabled: '1',
        source_refs: ['ps1'],
        primary_refs: ['ps2'],
        backup_refs: ['ps3'],
      },
      grp_off: {
        '.type': 'outbound_group',
        enabled: '0',
        source_refs: ['ps_disabled_grp'],
      },
      Main: {
        '.type': 'section',
        enabled: '1',
        action: 'proxy',
        outbound_source_refs: ['sn'],
        outbound_group_refs: ['grp_mix', 'grp_off'],
      },
    });

    const mod = loadViewModule(sectionTsPath, { uci: uciMock }, [
      'resolveEffectiveSectionOutboundSourceIds',
      'currentSectionPriorityTierChoices',
    ]);

    const resolved =
      mod.__extra.resolveEffectiveSectionOutboundSourceIds('Main');
    expect(resolved.effectiveSourceIds).toEqual(['sn', 'ps2', 'ps3', 'ps1']);

    const choices = mod.__extra.currentSectionPriorityTierChoices('Main', []);
    const values = choices.map((c) => c.value);
    expect(values).toEqual(
      expect.arrayContaining([
        'sn',
        'ps1',
        'ps2',
        'ps3',
        'srv:DirectNode1',
        'srv:GroupNode1',
        'srv:PrimaryNode1',
        'srv:BackupNode1',
      ]),
    );
    expect(values).not.toContain('srv:DisabledGroupNode');
  });

  it('includes all enabled non-DPI sources for wildcard/empty group even with direct source and singular outbound_group_ref', () => {
    const uciMock = createMockUci({
      sn: {
        '.type': 'outbound_source',
        enabled: '1',
        source_type: 'proxy_links',
        proxy_links: ['vless://1@198.51.100.1:443#DirectNode'],
      },
      ps_sub: {
        '.type': 'outbound_source',
        enabled: '1',
        source_type: 'subscription',
        proxy_links: ['vless://2@198.51.100.2:443#SubNode'],
      },
      dpi_src: {
        '.type': 'outbound_source',
        enabled: '1',
        source_type: 'desync',
      },
      grp_all: {
        '.type': 'outbound_group',
        enabled: '1',
        source_refs: ['*'],
      },
      Main: {
        '.type': 'section',
        enabled: '1',
        action: 'proxy',
        outbound_source_refs: ['sn'],
        outbound_group_ref: 'grp_all',
      },
    });

    const mod = loadViewModule(sectionTsPath, { uci: uciMock }, [
      'resolveEffectiveSectionOutboundSourceIds',
    ]);

    const resolved =
      mod.__extra.resolveEffectiveSectionOutboundSourceIds('Main');
    expect(resolved.effectiveSourceIds).toEqual(['sn', 'ps_sub']);
  });
});

describe('PR #509: InterfaceSettingsDynamicList RPC failure resilience', () => {
  it('resolves load() with fallback devices=[] when network.getDevices rejects with No related RPC reply', async () => {
    const superLoad = vi.fn(() => Promise.resolve(['wg0']));
    const formMock = createFormMock(superLoad);
    const uciMock = createMockUci({
      lan: { '.type': 'interface', device: 'br-lan' },
    });
    const mod = loadViewModule(
      sectionTsPath,
      {
        uci: uciMock,
        form: formMock,
        network: {
          getDevices: () => Promise.reject(new Error('No related RPC reply')),
          getNetworks: () => Promise.resolve([]),
        },
      },
      ['InterfaceSettingsDynamicList'],
    );

    const opt = new mod.__extra.InterfaceSettingsDynamicList();
    opt.value = vi.fn();
    const res = await opt.load('sec1');

    expect(res).toEqual(['wg0']);
    expect(opt.devices).toEqual([]);
    expect(superLoad).toHaveBeenCalledWith('sec1');
    expect(opt.value).toHaveBeenCalled();
  });

  it('populates devices normally when network.getDevices succeeds', async () => {
    const superLoad = vi.fn(() => Promise.resolve(['eth0']));
    const formMock = createFormMock(superLoad);
    const fakeDevice = {
      getName: () => 'eth0',
      getType: () => 'ethernet',
      isUp: () => true,
      getI18n: () => 'Ethernet',
    };
    const mod = loadViewModule(
      sectionTsPath,
      {
        form: formMock,
        network: {
          getDevices: () => Promise.resolve([fakeDevice]),
          getNetworks: () => Promise.resolve([]),
        },
      },
      ['InterfaceSettingsDynamicList'],
    );

    const opt = new mod.__extra.InterfaceSettingsDynamicList();
    opt.value = vi.fn();
    const res = await opt.load('sec1');

    expect(res).toEqual(['eth0']);
    expect(opt.devices).toEqual([fakeDevice]);
    expect(superLoad).toHaveBeenCalledWith('sec1');
  });
});

describe('PR #509: configureGridSection addModalOptions load guards', () => {
  function setupModalSection(origMapLoadImpl) {
    const warnSpy = vi.fn();
    const formMock = createFormMock();
    const mod = loadViewModule(
      tachyonTsPath,
      {
        form: formMock,
        console: { warn: warnSpy, error: vi.fn(), log: vi.fn() },
      },
      ['configureGridSection'],
    );

    const sectionRef = {};
    mod.__extra.configureGridSection(sectionRef, 'section', 'Section', 'Add');

    const childOkCfg = vi.fn((_sid, val) => val ?? 'saved_ok');
    const childOkLoad = vi.fn(() => Promise.resolve('loaded_ok'));
    const childOk = {
      option: 'ok_opt',
      disable: false,
      load: childOkLoad,
      cfgvalue: childOkCfg,
    };

    const childFailCfg = vi.fn((_sid, val) =>
      val !== undefined ? val : 'fallback_cfg',
    );
    const childFailLoad = vi.fn(() =>
      Promise.reject(new Error('No related RPC reply')),
    );
    const childFail = {
      option: 'fail_opt',
      disable: false,
      load: childFailLoad,
      cfgvalue: childFailCfg,
    };

    const modalSection = {
      children: [childOk, childFail],
      loadChildren(section_id) {
        const tasks = this.children
          .filter((c) => c && !c.disable)
          .map((c) =>
            Promise.resolve(c.load(section_id)).then((val) =>
              c.cfgvalue(section_id, val),
            ),
          );
        return Promise.all(tasks);
      },
      map: {
        load: origMapLoadImpl,
      },
    };

    sectionRef.addModalOptions(modalSection, 'sec1', {});
    return {
      modalSection,
      childOk,
      childOkCfg,
      childOkLoad,
      childFail,
      childFailCfg,
      childFailLoad,
      warnSpy,
    };
  }

  it('passes normal resolved values through origLoadChildren and falls back only on child load failure', async () => {
    const {
      modalSection,
      childOk,
      childOkCfg,
      childOkLoad,
      childFail,
      childFailCfg,
      childFailLoad,
      warnSpy,
    } = setupModalSection(() => Promise.resolve());

    const results = await modalSection.loadChildren('sec1');

    expect(results).toEqual(['loaded_ok', 'fallback_cfg']);
    expect(childOkCfg).toHaveBeenCalledWith('sec1', 'loaded_ok');
    expect(childFailCfg).toHaveBeenCalledWith('sec1');
    expect(childFailCfg).toHaveBeenCalledWith('sec1', 'fallback_cfg');
    expect(warnSpy).toHaveBeenCalledTimes(1);
    expect(childOk.load).toBe(childOkLoad);
    expect(childFail.load).toBe(childFailLoad);
  });

  it('recovers modalMap.load on transient RPC reply failure via modalSection.loadChildren', async () => {
    const { modalSection, childOkCfg, warnSpy } = setupModalSection(() =>
      Promise.reject(new Error('RPC call failed: No related RPC reply')),
    );

    const res = await modalSection.map.load('sec1');

    expect(res).toEqual(['loaded_ok', 'fallback_cfg']);
    expect(childOkCfg).toHaveBeenCalledWith('sec1', 'loaded_ok');
    expect(warnSpy).toHaveBeenCalled();
  });

  it('never swallows real UCI save/commit or permission errors in modalMap.load', async () => {
    const uciErr = new Error('uci.commit failed: permission denied');
    const { modalSection } = setupModalSection(() => Promise.reject(uciErr));

    await expect(modalSection.map.load('sec1')).rejects.toThrow(
      'uci.commit failed: permission denied',
    );
  });

  it('never swallows modalMap.load errors while a modal save is in progress', async () => {
    const rpcErr = new Error('No related RPC reply');
    const { modalSection } = setupModalSection(() => Promise.reject(rpcErr));
    modalSection.map.__tachyonSaving = true;

    await expect(modalSection.map.load('sec1')).rejects.toThrow(
      'No related RPC reply',
    );
  });
});
