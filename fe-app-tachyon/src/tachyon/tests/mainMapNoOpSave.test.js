import fs from 'node:fs';
import Module from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import { describe, expect, it, vi } from 'vitest';

const testDir = path.dirname(fileURLToPath(import.meta.url));
const tachyonTsPath = path.resolve(testDir, '../../views/tachyon.ts');

function createLuciLikeUci(initial = {}) {
  const values = {};
  for (const [k, v] of Object.entries(initial)) {
    values[k] = { ...v };
  }
  const rpcCalls = [];
  const uci = {
    rpcCalls,
    state: {
      newidx: 0,
      values: { tachyon: values },
      creates: { tachyon: {} },
      changes: { tachyon: {} },
      deletes: { tachyon: {} },
      reorder: {},
    },
    load: vi.fn((pkg) => Promise.resolve([pkg])),
    unload: vi.fn(),
    sections(_pkg, typeName) {
      return Object.entries(uci.state.values.tachyon || {})
        .filter(([, obj]) => obj && obj['.type'] === typeName)
        .map(([name, obj]) => ({ '.name': name, ...obj }));
    },
    get(_pkg, sid, opt) {
      const chg = uci.state.changes.tachyon?.[sid];
      const del = uci.state.deletes.tachyon?.[sid];
      const val = uci.state.values.tachyon?.[sid];
      if (opt != null) {
        if (del === true || del?.[opt]) return null;
        if (chg?.[opt] != null) return chg[opt];
        return val?.[opt] ?? null;
      }
      if (!val || del === true) return null;
      return { ...val, ...(chg || {}) };
    },
    set(_pkg, sid, opt, val) {
      if (sid == null || opt == null || opt.charAt(0) === '.') return;
      if (val != null && val !== '') {
        if (!uci.state.values.tachyon?.[sid]) return;
        uci.state.changes.tachyon ??= {};
        uci.state.changes.tachyon[sid] ??= {};
        if (uci.state.deletes.tachyon?.[sid]) {
          delete uci.state.deletes.tachyon[sid][opt];
          if (Object.keys(uci.state.deletes.tachyon[sid]).length === 0) {
            delete uci.state.deletes.tachyon[sid];
          }
        }
        uci.state.changes.tachyon[sid][opt] = val;
      } else if (
        Object.prototype.hasOwnProperty.call(
          uci.state.values.tachyon?.[sid] || {},
          opt,
        )
      ) {
        uci.state.deletes.tachyon ??= {};
        uci.state.deletes.tachyon[sid] ??= {};
        uci.state.deletes.tachyon[sid][opt] = true;
      }
    },
    unset(_pkg, sid, opt) {
      return uci.set(_pkg, sid, opt, null);
    },
    add(_pkg, type, name) {
      const sid = name || `new${uci.state.newidx++}`;
      uci.state.creates.tachyon[sid] = {
        '.type': type,
        '.name': sid,
      };
      return sid;
    },
    remove(_pkg, sid) {
      if (uci.state.values.tachyon?.[sid]) {
        uci.state.deletes.tachyon[sid] = true;
      }
    },
    resolveSID: (_pkg, sid) => sid,
    save: vi.fn(() => {
      const d = uci.state.deletes.tachyon || {};
      for (const [sid, opts] of Object.entries(d)) {
        rpcCalls.push({
          method: 'delete',
          sid,
          options: opts === true ? null : Object.keys(opts),
        });
      }
      const c = uci.state.changes.tachyon || {};
      for (const [sid, vals] of Object.entries(c)) {
        rpcCalls.push({ method: 'set', sid, values: { ...vals } });
      }
      uci.state.creates.tachyon = {};
      uci.state.changes.tachyon = {};
      uci.state.deletes.tachyon = {};
      return Promise.resolve(['tachyon']);
    }),
  };
  return uci;
}

function createLuciLikeForm(uciMock) {
  function FlagOption(section, optName, defaultVal = '0', opts = {}) {
    this.section = section;
    this.map = section.map;
    this.option = optName;
    this.default = defaultVal;
    this.enabled = '1';
    this.disabled = '0';
    this.rmempty = opts.rmempty !== undefined ? opts.rmempty : true;
    this.optional = opts.optional ?? false;
    this.editable = opts.editable ?? false;
    this.modalonly = opts.modalonly ?? false;
    this.retain = opts.retain ?? false;
    this._formValues = opts.formValues || {};
  }
  FlagOption.prototype.isActive = () => true;
  FlagOption.prototype.isValid = () => true;
  FlagOption.prototype.cfgvalue = function (sid) {
    return uciMock.get('tachyon', sid, this.option);
  };
  FlagOption.prototype.formvalue = function (sid) {
    if (Object.prototype.hasOwnProperty.call(this._formValues, sid)) {
      return this._formValues[sid];
    }
    const cval = this.cfgvalue(sid);
    return cval != null ? cval : this.default;
  };
  FlagOption.prototype.write = function (sid, fval) {
    return uciMock.set('tachyon', sid, this.option, fval);
  };
  FlagOption.prototype.remove = function (sid) {
    return uciMock.unset('tachyon', sid, this.option);
  };
  // Exact LuCI CBIFlag.prototype.parse from /www/luci-static/resources/form.js
  FlagOption.prototype.parse = function (sid) {
    if (this.isActive(sid)) {
      const fval = this.formvalue(sid);
      if (fval == this.default && (this.optional || this.rmempty)) {
        return Promise.resolve(this.remove(sid));
      }
      return Promise.resolve(this.write(sid, fval));
    } else if (!this.retain) {
      return Promise.resolve(this.remove(sid));
    }
    return Promise.resolve();
  };

  function Section(map, sectionType) {
    this.map = map;
    this.sectiontype = sectionType;
    this.children = [];
  }
  Section.prototype.load = () => Promise.resolve();
  Section.prototype.render = () =>
    Promise.resolve({
      querySelector: () => null,
      querySelectorAll: () => [],
      appendChild: () => {},
      insertBefore: () => {},
      classList: { add: () => {}, remove: () => {} },
    });
  Section.prototype.cfgsections = function () {
    return [this.sectiontype];
  };
  Section.prototype.addFlag = function (optName, defaultVal, opts) {
    const o = new FlagOption(this, optName, defaultVal, opts);
    this.children.push(o);
    return o;
  };
  Section.prototype.parse = function () {
    const sids = this.cfgsections();
    const tasks = [];
    for (const sid of sids) {
      for (const child of this.children) {
        if (this.isGrid && (!child.editable || child.modalonly)) continue;
        tasks.push(child.parse(sid));
      }
    }
    return Promise.all(tasks);
  };

  function Map(config) {
    this.config = config;
    this.data = uciMock;
    this.children = [];
  }
  Map.prototype.section = function (cls, sectionType) {
    const s = new cls(this, sectionType);
    this.children.push(s);
    return s;
  };
  Map.prototype.load = function () {
    return uciMock.load(this.config);
  };
  Map.prototype.checkDepends = () => {};
  Map.prototype.parse = function () {
    return Promise.all(this.children.map((c) => c.parse()));
  };
  Map.prototype.renderContents = () =>
    Promise.resolve({
      querySelector: () => null,
      querySelectorAll: () => [],
      appendChild: () => {},
      insertBefore: () => {},
      classList: { add: () => {}, remove: () => {} },
    });
  Map.prototype.render = function () {
    return this.load().then(() => this.renderContents());
  };
  Map.prototype.save = function (cb) {
    this.checkDepends();
    return this.parse()
      .then(cb)
      .then(() => this.data.save())
      .then(() => this.load())
      .then(() => this.renderContents());
  };

  function GridSection(map, sectionType) {
    Section.call(this, map, sectionType);
    this.isGrid = true;
  }
  GridSection.prototype = Object.create(Section.prototype);

  return {
    Map,
    TypedSection: Section,
    GridSection,
    Flag: FlagOption,
    Value: FlagOption,
    ListValue: FlagOption,
    DynamicList: FlagOption,
    TextValue: FlagOption,
    DummyValue: FlagOption,
    SectionValue: FlagOption,
    NamedSection: Section,
    TableSection: GridSection,
  };
}

function loadEntryPoint(
  uciMock,
  formMock,
  sectionHooks = {},
  mainOverrides = {},
) {
  const rawTs = fs.readFileSync(tachyonTsPath, 'utf8');
  const stripped = Module.stripTypeScriptTypes(rawTs, { mode: 'strip' });
  const jsBody = stripped.replace(
    /^export default view\.extend\(([\s\S]*?)\);\s*$/m,
    'return $1;',
  );

  const g = {};
  const sandbox = {
    globalThis: g,
    _: (s) => s,
    E: () => ({ style: {} }),
    L: {
      toArray: (v) => (Array.isArray(v) ? v : []),
      env: { lang: 'en' },
    },
    uci: uciMock,
    fs: {
      exec: () => Promise.resolve({ code: 0, stdout: '{}' }),
      read_direct: () => Promise.resolve('{}'),
    },
    ui: {
      hideModal: vi.fn(),
      addNotification: vi.fn(),
      changes: { init: vi.fn(), setIndicator: vi.fn() },
    },
    network: { getDevices: () => Promise.resolve([]) },
    rpc: { declare: () => () => Promise.resolve({}) },
    dom: { findClassInstance: () => null },
    widgets: {},
    form: formMock,
    baseclass: { extend: (obj) => obj },
    view: { extend: (obj) => obj },
    localDevices: {},
    dnsSpeedTest: {},
    dashboard: { createDashboardContent: () => {} },
    section: {
      configureSectionSection: () => {},
      createSectionContent: () => {},
    },
    conditions: {
      configureConditionsSection: () => {},
      createConditionsContent: () => {},
    },
    outbounds: {
      configureOutboundsSection: () => {},
      createOutboundsContent: () => {},
    },
    balancers: {
      configureBalancersSection: () => {},
      createBalancersContent: () => {},
    },
    server: {
      configureServerSubscription: () => {},
      configureServerSection: () => {},
      applyServerCapabilities: () => {},
      createServerContent: () => {},
    },
    parental: {
      createProfileContent: () => {},
      createParentalContent: () => {},
      createGuestModeContent: () => {},
    },
    monitoring: { createMonitoringContent: () => {} },
    diagnostic: { createDiagnosticContent: () => {} },
    updates: { createUpdatesContent: () => {} },
    settings: {
      createSettingsContent: sectionHooks.createSettingsContent || (() => {}),
      createTelegramContent: sectionHooks.createTelegramContent || (() => {}),
    },
    main: {
      TACHYON_UCI_PACKAGE: 'tachyon',
      TachyonShellMethods: {
        getUiCapabilities: () =>
          Promise.resolve({
            success: true,
            data: { tachyon_core_tailscale: 1 },
          }),
        getUiState: () => Promise.resolve({ success: false }),
        getServerCapabilities: () => Promise.resolve({ success: false }),
        getServerInboundsConfig: () => Promise.resolve({ success: false }),
      },
      mountTachyonAppShell: () => {},
      coreService: () => {},
      injectGlobalStyles: () => {},
      applyAutofillProtection: () => {},
      getSavedActiveNavKey: () => '',
      ...mainOverrides,
    },
    window: {
      location: { hash: '' },
      setTimeout: (fn) => {
        fn();
        return 0;
      },
      requestAnimationFrame: () => 0,
      dispatchEvent: () => true,
    },
    CustomEvent: function (name, init) {
      this.type = name;
      this.detail = init?.detail;
    },
    document: {
      querySelector: () => null,
      querySelectorAll: () => [],
      getElementById: () => null,
    },
    console: globalThis.console,
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
  };

  const fn = new vm.Script(`(function() {\n${jsBody}\n})()`);
  const EntryPoint = fn.runInNewContext(sandbox);
  return { EntryPoint, globalScope: g };
}

describe('tachyonMap main form no-op save guard', () => {
  it('emits 0 uci RPCs and preserves default-valued flags when saving without changes', async () => {
    const uciMock = createLuciLikeUci({
      settings: {
        '.type': 'settings',
        list_update_enabled: '1',
        dns_detour_enabled: '0',
      },
      telegram: { '.type': 'telegram', enabled: '0' },
      guest_mode: { '.type': 'guest_mode', enabled: '0' },
      Main: { '.type': 'section', enabled: '1' },
    });
    const formMock = createLuciLikeForm(uciMock);

    let settingsSection;
    const { EntryPoint, globalScope } = loadEntryPoint(uciMock, formMock, {
      createSettingsContent: (sec) => {
        settingsSection = sec;
        sec.addFlag('list_update_enabled', '1', {
          rmempty: false,
          retain: true,
        });
        sec.addFlag('dns_detour_enabled', '0', { rmempty: true, retain: true });
      },
      createTelegramContent: (sec) => {
        sec.addFlag('enabled', '0', { rmempty: false, retain: true });
      },
    });

    await EntryPoint.render();
    // Simulate grid section having an inline editable enabled flag
    const secGrid = globalScope.__tachyonMapInstance.children.find(
      (c) => c.sectiontype === 'section',
    );
    secGrid.addFlag('enabled', '1', { rmempty: false, editable: true });

    await globalScope.__tachyonMapInstance.save(null, false);

    expect(uciMock.rpcCalls).toEqual([]);
    expect(uciMock.state.changes.tachyon).toEqual({});
    expect(uciMock.state.deletes.tachyon).toEqual({});
    expect(settingsSection).toBeDefined();
  });

  it('still persists real Flag edits (set on rmempty=false, delete on rmempty=true -> default)', async () => {
    const uciMock = createLuciLikeUci({
      settings: {
        '.type': 'settings',
        list_update_enabled: '1',
        dns_detour_enabled: '1',
      },
      Main: { '.type': 'section', enabled: '1' },
    });
    const formMock = createLuciLikeForm(uciMock);

    let listUpdateOpt;
    let dnsDetourOpt;
    const { EntryPoint, globalScope } = loadEntryPoint(uciMock, formMock, {
      createSettingsContent: (sec) => {
        listUpdateOpt = sec.addFlag('list_update_enabled', '1', {
          rmempty: false,
          retain: true,
        });
        dnsDetourOpt = sec.addFlag('dns_detour_enabled', '0', {
          rmempty: true,
          retain: true,
        });
      },
    });

    await EntryPoint.render();
    const secGrid = globalScope.__tachyonMapInstance.children.find(
      (c) => c.sectiontype === 'section',
    );
    secGrid.addFlag('enabled', '1', { rmempty: false, editable: true });

    // User toggles list_update_enabled to '0' and dns_detour_enabled to '0' (default)
    listUpdateOpt._formValues.settings = '0';
    dnsDetourOpt._formValues.settings = '0';

    await globalScope.__tachyonMapInstance.save(null, false);

    expect(uciMock.rpcCalls).toEqual([
      { method: 'delete', sid: 'settings', options: ['dns_detour_enabled'] },
      { method: 'set', sid: 'settings', values: { list_update_enabled: '0' } },
    ]);
  });

  it('keeps shell restoringTab active across renderContents completion until mountTachyonAppShell rAF finishes', async () => {
    const uciMock = createLuciLikeUci({
      settings: { '.type': 'settings' },
      Main: { '.type': 'section', enabled: '1' },
    });
    const formMock = createLuciLikeForm(uciMock);

    const restoringCalls = [];
    let shellMountedAfterRenderContents = false;
    const { EntryPoint, globalScope } = loadEntryPoint(
      uciMock,
      formMock,
      {},
      {
        setShellRestoringTab: (v) => restoringCalls.push(v),
        mountTachyonAppShell: () => {
          shellMountedAfterRenderContents = true;
        },
        getSavedActiveNavKey: () => 'settings:updates',
      },
    );

    await EntryPoint.render();
    restoringCalls.length = 0;
    shellMountedAfterRenderContents = false;

    await globalScope.__tachyonMapInstance.renderContents();

    expect(shellMountedAfterRenderContents).toBe(true);
    expect(restoringCalls).toEqual([true]);
  });
});
