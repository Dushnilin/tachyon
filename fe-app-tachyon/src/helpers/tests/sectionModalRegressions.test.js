import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parse } from '@babel/parser';
import traverseModule from '@babel/traverse';
import ts from 'typescript';
import { describe, expect, it, vi } from 'vitest';

const traverse =
  typeof traverseModule?.default === 'function'
    ? traverseModule.default
    : traverseModule;

const testsDir = path.dirname(fileURLToPath(import.meta.url));
const viewsDir = path.resolve(testsDir, '../../views');

function readViewSource(name) {
  return fs.readFileSync(path.join(viewsDir, name), 'utf8');
}

function parseTsAst(source) {
  return parse(source, {
    sourceType: 'module',
    plugins: ['typescript'],
    allowReturnOutsideFunction: true,
  });
}

function transpileSnippet(code) {
  return ts.transpileModule(code, {
    compilerOptions: {
      target: ts.ScriptTarget.ES2022,
      module: ts.ModuleKind.None,
    },
  }).outputText;
}

function extractFunctionDecl(ast, source, name) {
  let slice = '';
  traverse(ast, {
    FunctionDeclaration(p) {
      if (
        p.node.id?.name === name &&
        p.node.start != null &&
        p.node.end != null
      ) {
        slice = source.slice(p.node.start, p.node.end);
        p.stop();
      }
    },
  });
  if (!slice) {
    throw new Error(`FunctionDeclaration ${name} not found`);
  }
  return slice;
}

function extractVarInit(ast, source, name) {
  let slice = '';
  traverse(ast, {
    VariableDeclarator(p) {
      if (
        p.node.id?.type === 'Identifier' &&
        p.node.id.name === name &&
        p.node.init &&
        p.node.init.start != null &&
        p.node.init.end != null
      ) {
        slice = source.slice(p.node.init.start, p.node.init.end);
        p.stop();
      }
    },
  });
  if (!slice) {
    throw new Error(`VariableDeclarator ${name} not found`);
  }
  return slice;
}

function extractAssignedPropRhs(ast, source, objName, propName, predicate) {
  let slice = '';
  traverse(ast, {
    AssignmentExpression(p) {
      const left = p.node.left;
      if (
        left?.type === 'MemberExpression' &&
        left.object?.type === 'Identifier' &&
        left.object.name === objName &&
        left.property?.type === 'Identifier' &&
        left.property.name === propName &&
        p.node.right.start != null &&
        p.node.right.end != null
      ) {
        const candidate = source.slice(p.node.right.start, p.node.right.end);
        if (!predicate || predicate(candidate)) {
          slice = candidate;
          p.stop();
        }
      }
    },
  });
  if (!slice) {
    throw new Error(`Assignment ${objName}.${propName} not found`);
  }
  return slice;
}

const sectionSource = readViewSource('section.ts');
const sectionAst = parseTsAst(sectionSource);
const tachyonSource = readViewSource('tachyon.ts');
const tachyonAst = parseTsAst(tachyonSource);
const outboundsSource = readViewSource('outbounds.ts');
const outboundsAst = parseTsAst(outboundsSource);
const conditionsSource = readViewSource('conditions.ts');
const conditionsAst = parseTsAst(conditionsSource);

describe('Tachyon 2.0 beta.16 section & modal regressions', () => {
  it('getLinkedSectionConditionIds returns [] for composite condition types, children, members, and expressions', () => {
    const normalizeFn = extractFunctionDecl(
      sectionAst,
      sectionSource,
      'normalizeOptionValues',
    );
    const parseRefsFn = extractFunctionDecl(
      sectionAst,
      sectionSource,
      'parseConditionRefs',
    );
    const isCompositeFn = extractFunctionDecl(
      sectionAst,
      sectionSource,
      'isCompositeConditionRecord',
    );
    const getLinkedFn = extractFunctionDecl(
      sectionAst,
      sectionSource,
      'getLinkedSectionConditionIds',
    );

    const store = {
      sec_all: { '.type': 'section', condition_refs: ['cond_all'] },
      cond_all: { '.type': 'condition', condition_type: 'all' },
      sec_any: { '.type': 'section', condition_refs: ['cond_any'] },
      cond_any: { '.type': 'condition', condition_type: 'any' },
      sec_not: { '.type': 'section', condition_refs: ['cond_not'] },
      cond_not: { '.type': 'condition', condition_type: 'not' },
      sec_comp: { '.type': 'section', condition_refs: ['cond_comp'] },
      cond_comp: { '.type': 'condition', condition_type: 'composite' },
      sec_and: { '.type': 'section', condition_refs: ['cond_and'] },
      cond_and: { '.type': 'condition', condition_type: 'and' },
      sec_or: { '.type': 'section', condition_refs: ['cond_or'] },
      cond_or: { '.type': 'condition', condition_type: 'or' },
      sec_children: { '.type': 'section', condition_refs: ['cond_children'] },
      cond_children: {
        '.type': 'condition',
        condition_type: 'atomic',
        children: ['c1', 'c2'],
      },
      sec_members: { '.type': 'section', condition_refs: ['cond_members'] },
      cond_members: {
        '.type': 'condition',
        condition_type: 'atomic',
        members: ['c1'],
      },
      sec_expr: { '.type': 'section', condition_refs: ['cond_expr'] },
      cond_expr: {
        '.type': 'condition',
        condition_type: 'atomic',
        expression: 'c1 AND c2',
      },
      sec_implicit: { '.type': 'section' },
      cond_sec_implicit: { '.type': 'condition', condition_type: 'all' },
      sec_atomic: { '.type': 'section', condition_refs: ['cond_atomic'] },
      cond_atomic: { '.type': 'condition', condition_type: 'atomic' },
    };

    const uciMock = {
      get: (_pkg, sid, opt) => {
        const rec = store[sid];
        if (!rec) return null;
        return opt ? (rec[opt] ?? null) : rec;
      },
    };

    const factory = new Function(
      'uci',
      'UCI_PACKAGE',
      transpileSnippet(`
        ${normalizeFn}
        ${parseRefsFn}
        ${isCompositeFn}
        ${getLinkedFn}
        return getLinkedSectionConditionIds;
      `),
    );
    const getLinked = factory(uciMock, 'tachyon');

    for (const sid of [
      'sec_all',
      'sec_any',
      'sec_not',
      'sec_comp',
      'sec_and',
      'sec_or',
      'sec_children',
      'sec_members',
      'sec_expr',
      'sec_implicit',
    ]) {
      expect(getLinked(sid), `${sid} must not link as editable`).toEqual([]);
    }

    expect(getLinked('sec_atomic')).toEqual(['cond_atomic']);
  });

  it('outbound_source_refs.write handles subscription_urls arrays without ReferenceError: asArray', () => {
    let writeSnippet = '';
    traverse(sectionAst, {
      CallExpression(p) {
        const callee = p.node.callee;
        const args = p.node.arguments || [];
        if (
          callee?.type === 'MemberExpression' &&
          callee.property?.type === 'Identifier' &&
          callee.property.name === 'taboption' &&
          args[2]?.type === 'StringLiteral' &&
          args[2].value === 'outbound_source_refs'
        ) {
          const stmtParent = p.findParent((par) => par.isBlockStatement?.());
          if (
            stmtParent?.node?.start != null &&
            stmtParent?.node?.end != null
          ) {
            const blockCode = sectionSource.slice(
              stmtParent.node.start,
              stmtParent.node.end,
            );
            const blockAst = parseTsAst(blockCode);
            writeSnippet = extractAssignedPropRhs(
              blockAst,
              blockCode,
              'o',
              'write',
              (code) =>
                code.includes('outbound_source_refs') &&
                code.includes('subscription_urls'),
            );
            p.stop();
          }
        }
      },
    });
    expect(writeSnippet).toBeTruthy();

    const checkNoUndefinedAsArray = (ast, fileLabel) => {
      const hits = [];
      traverse(ast, {
        CallExpression(p) {
          if (
            p.node.callee?.type === 'Identifier' &&
            p.node.callee.name === 'asArray'
          ) {
            hits.push(p.node.loc?.start?.line ?? 0);
          }
        },
      });
      expect(hits, `undefined asArray() calls in ${fileLabel}`).toEqual([]);
    };
    checkNoUndefinedAsArray(sectionAst, 'section.ts');
    checkNoUndefinedAsArray(tachyonAst, 'tachyon.ts');

    const normalizeFn = extractFunctionDecl(
      sectionAst,
      sectionSource,
      'normalizeOptionValues',
    );
    const records = {
      Main: { '.type': 'section', outbound_source_refs: ['src_sub_1'] },
      src_sub_1: {
        '.type': 'outbound_source',
        url: 'https://keep-single.example/sub',
        source_type: 'subscription',
      },
      qwe: {
        '.type': 'outbound_source',
        subscription_urls: ['https://futurefast.ru/api/sub/-Vv7GccuQjydvZDz'],
        source_type: 'subscription',
      },
      old_unused: {
        '.type': 'outbound_source',
        subscription_urls: ['https://removed.example/sub'],
        source_type: 'subscription',
      },
      sub_keep_qwe: {
        '.type': 'subscription_url',
        section: 'Main',
        url: 'https://futurefast.ru/api/sub/-Vv7GccuQjydvZDz',
      },
      sub_orphan: {
        '.type': 'subscription_url',
        section: 'Main',
        url: 'https://removed.example/sub',
      },
    };
    const removed = [];
    const uciMock = {
      get: (_pkg, sid, opt) =>
        opt ? (records[sid]?.[opt] ?? null) : (records[sid] ?? null),
      set: (_pkg, sid, opt, val) => {
        records[sid] = records[sid] || {};
        records[sid][opt] = val;
      },
      unset: (_pkg, sid, opt) => {
        if (records[sid]) delete records[sid][opt];
      },
      remove: (_pkg, sid) => {
        removed.push(sid);
        delete records[sid];
      },
      sections: (_pkg, type) =>
        Object.entries(records)
          .filter(([, v]) => v['.type'] === type)
          .map(([k, v]) => ({ '.name': k, ...v })),
    };

    const writeFn = new Function(
      'uci',
      'UCI_PACKAGE',
      'unsetIfPresent',
      transpileSnippet(`
        ${normalizeFn}
        return (${writeSnippet});
      `),
    )(uciMock, 'tachyon', (sid, opt) => uciMock.unset('tachyon', sid, opt));

    expect(() => writeFn('Main', ['src_sub_1', 'qwe'])).not.toThrow();
    expect(records.Main.outbound_source_refs).toEqual(['src_sub_1', 'qwe']);
    expect(removed).toEqual(['sub_orphan']);
    expect(records.sub_keep_qwe).toBeTruthy();
  });

  it('registers hidden and match_all options only once via section.taboption', () => {
    const counts = { hidden: 0, match_all: 0 };
    traverse(sectionAst, {
      CallExpression(p) {
        const callee = p.node.callee;
        if (
          callee?.type === 'MemberExpression' &&
          callee.object?.type === 'Identifier' &&
          callee.object.name === 'section' &&
          callee.property?.type === 'Identifier' &&
          callee.property.name === 'taboption'
        ) {
          const optName = p.node.arguments?.[2];
          if (
            optName?.type === 'StringLiteral' &&
            Object.prototype.hasOwnProperty.call(counts, optName.value)
          ) {
            counts[optName.value] += 1;
          }
        }
      },
    });
    expect(counts.hidden).toBe(1);
    expect(counts.match_all).toBe(1);
  });

  it('handleModalSave catches synchronous errors and inserts error banner before .button-row', async () => {
    const modalSaveSnippet = extractAssignedPropRhs(
      tachyonAst,
      tachyonSource,
      'sectionRef',
      'handleModalSave',
      (code) => code.includes('showModalSaveError'),
    );

    const makeMockNode = (cls = '') => {
      const children = [];
      const listeners = {};
      const node = {
        className: cls,
        parentNode: null,
        children,
        isConnected: true,
        scrollIntoView: vi.fn(),
        remove: vi.fn(() => {
          if (node.parentNode) {
            const idx = node.parentNode.children.indexOf(node);
            if (idx >= 0) node.parentNode.children.splice(idx, 1);
            node.parentNode = null;
          }
          node.isConnected = false;
        }),
        appendChild(ch) {
          if (ch && typeof ch === 'object') ch.parentNode = node;
          children.push(ch);
          return ch;
        },
        insertBefore(newNode, refNode) {
          if (newNode && typeof newNode === 'object') newNode.parentNode = node;
          const idx = children.indexOf(refNode);
          if (idx >= 0) children.splice(idx, 0, newNode);
          else children.push(newNode);
          return newNode;
        },
        addEventListener(t, cb) {
          (listeners[t] ||= []).push(cb);
        },
        removeEventListener(t, cb) {
          listeners[t] = (listeners[t] || []).filter((f) => f !== cb);
        },
        querySelector(sel) {
          if (sel.includes(':scope >')) {
            throw new SyntaxError('mock DOM does not parse :scope');
          }
          const tokens = sel.split(',').map((s) => s.trim());
          const match = (n) =>
            tokens.some((tok) => {
              if (tok.startsWith('.')) {
                return (n.className || '').split(/\s+/).includes(tok.slice(1));
              }
              return false;
            });
          const walk = (root) => {
            for (const c of root.children || []) {
              if (c && typeof c === 'object') {
                if (match(c)) return c;
                const deep = walk(c);
                if (deep) return deep;
              }
            }
            return null;
          };
          return walk(node);
        },
        querySelectorAll: () => [],
      };
      return node;
    };

    const modalEl = makeMockNode('cbi-modal');
    const bodyEl = makeMockNode('cbi-section');
    const buttonRow = makeMockNode('button-row');
    modalEl.appendChild(bodyEl);
    modalEl.appendChild(buttonRow);

    const EMock = (tag, attrs, children) => {
      const n = makeMockNode(attrs?.class || tag);
      n.children = Array.isArray(children) ? children : [children];
      return n;
    };

    const prevDoc = globalThis.document;
    const prevE = globalThis.E;
    const prevConsoleError = globalThis.console.error;
    globalThis.console.error = vi.fn();
    globalThis.document = {
      querySelector: (sel) => (sel.includes('.cbi-modal') ? modalEl : null),
    };
    globalThis.E = EMock;

    try {
      const sectionRef = {
        handleModalCancel: vi.fn(),
        _refreshStudioDeck: vi.fn(),
      };
      const fn = new Function(
        'sectionRef',
        'origModalSave',
        'UCI_PACKAGE',
        'sanitizeUciDeletes',
        'persistSavedGridChanges',
        'uci',
        'ui',
        'dom',
        '_',
        'E',
        transpileSnippet(`
          return (${modalSaveSnippet});
        `),
      );
      const handleModalSave = fn(
        sectionRef,
        null,
        'tachyon',
        () => {},
        () => {},
        {},
        { addNotification: vi.fn() },
        {},
        (s) => s,
        EMock,
      );

      const failingMap = {
        section: 'Main',
        save: () => {
          throw new ReferenceError('boom');
        },
      };

      await expect(
        handleModalSave.call(sectionRef, failingMap, {}),
      ).resolves.toBeUndefined();
      const idxBanner = modalEl.children.findIndex((c) =>
        (c.className || '').includes('tachyon-modal-save-error'),
      );
      const idxBtnRow = modalEl.children.indexOf(buttonRow);
      expect(idxBanner).toBeGreaterThanOrEqual(0);
      expect(idxBanner).toBeLessThan(idxBtnRow);
      expect(sectionRef.handleModalCancel).not.toHaveBeenCalled();
    } finally {
      globalThis.console.error = prevConsoleError;
      globalThis.document = prevDoc;
      globalThis.E = prevE;
    }
  });

  it('openEntityModalDirect with targetSid opens modal directly without leaving Dashboard tab', () => {
    const openFnSnippet = extractVarInit(
      tachyonAst,
      tachyonSource,
      'openEntityModalDirect',
    );
    const subTabMap = extractVarInit(
      tachyonAst,
      tachyonSource,
      'subTabToEntityType',
    );
    const entityMap = extractVarInit(
      tachyonAst,
      tachyonSource,
      'entityTypeToSubTab',
    );

    const topTabClick = vi.fn();
    const sidebarSubClick = vi.fn();
    const renderMoreOptionsModal = vi.fn();
    const activateAppShellNavKey = vi.fn(() => true);

    const prevDoc = globalThis.document;
    const prevWin = globalThis.window;
    globalThis.document = {
      querySelector: (sel) => {
        if (sel.includes('.tachyon-sidebar__subitem')) {
          return { click: sidebarSubClick };
        }
        if (sel.includes('.cbi-tabmenu')) {
          return { click: topTabClick };
        }
        if (sel.includes('.tachyon-studio-card')) {
          return { offsetParent: null, scrollIntoView: vi.fn() };
        }
        return null;
      },
    };
    globalThis.window = {};

    try {
      const openEntityModalDirect = new Function(
        'gridSectionRegistry',
        'main',
        'ui',
        'selectSectionSubTabFn',
        'activeSectionSubTab',
        transpileSnippet(`
          const subTabToEntityType = ${subTabMap};
          const entityTypeToSubTab = ${entityMap};
          return (${openFnSnippet});
        `),
      )(
        { section: { renderMoreOptionsModal } },
        { activateAppShellNavKey },
        { hideModal: vi.fn() },
        vi.fn(),
        'sections',
      );

      openEntityModalDirect('section', 'Main', 'sections');

      expect(renderMoreOptionsModal).toHaveBeenCalledWith('Main');
      expect(topTabClick).not.toHaveBeenCalled();
      expect(sidebarSubClick).not.toHaveBeenCalled();
      expect(activateAppShellNavKey).not.toHaveBeenCalled();
    } finally {
      globalThis.document = prevDoc;
      globalThis.window = prevWin;
    }
  });

  it('outbounds.ts removes unbound grp typo in Clone handler and cleans subscription_urls in _target_sections.write', () => {
    const grpHits = [];
    traverse(outboundsAst, {
      Identifier(p) {
        if (
          p.node.name === 'grp' &&
          p.isReferencedIdentifier?.() &&
          !p.scope.hasBinding('grp')
        ) {
          grpHits.push(p.node.loc?.start?.line ?? 0);
        }
      },
    });
    expect(grpHits).toEqual([]);

    let writeSnippet = '';
    traverse(outboundsAst, {
      CallExpression(p) {
        const args = p.node.arguments || [];
        if (
          args[2]?.type === 'StringLiteral' &&
          args[2].value === '_target_sections'
        ) {
          const stmtParent = p.findParent((par) => par.isBlockStatement?.());
          if (
            stmtParent?.node?.start != null &&
            stmtParent?.node?.end != null
          ) {
            const blockCode = outboundsSource.slice(
              stmtParent.node.start,
              stmtParent.node.end,
            );
            const blockAst = parseTsAst(blockCode);
            writeSnippet = extractAssignedPropRhs(
              blockAst,
              blockCode,
              'o',
              'write',
            );
            p.stop();
          }
        }
      },
    });
    expect(writeSnippet).toContain('subscription_urls');
  });

  it('persistSavedGridChanges surfaces apply_unchecked HTTP/JSON errors instead of swallowing them', async () => {
    const extractErrFn = extractFunctionDecl(
      tachyonAst,
      tachyonSource,
      'extractApplyErrorText',
    );
    const persistFn = extractFunctionDecl(
      tachyonAst,
      tachyonSource,
      'persistSavedGridChanges',
    );

    const addNotification = vi.fn();
    const setIndicator = vi.fn();
    const refreshStudioDeck = vi.fn();
    const uiMock = {
      addNotification,
      changes: {
        changes: { tachyon: [['set', 'Main', 'enabled', '1']] },
        setIndicator,
      },
    };
    const uciMock = {
      save: vi.fn().mockResolvedValue(undefined),
    };
    const fetchMock = vi.fn().mockResolvedValue({
      ok: false,
      status: 400,
      text: () =>
        Promise.resolve(
          JSON.stringify({
            success: false,
            error: 'tachyon-core check failed: unknown field',
          }),
        ),
    });

    const compiled = transpileSnippet(`
      ${extractErrFn}
      ${persistFn}
      return persistSavedGridChanges;
    `);
    const runPersist = new Function(
      'sanitizeUciDeletes',
      'hasPendingUciStateChanges',
      'uci',
      'fetch',
      'ui',
      'E',
      '_',
      compiled,
    )(
      () => {},
      () => true,
      uciMock,
      fetchMock,
      uiMock,
      (_tag, _attrs, text) => ({ text }),
      (s) => s,
    );

    await expect(
      runPersist({ _refreshStudioDeck: refreshStudioDeck }, 'Main'),
    ).rejects.toThrow('tachyon-core check failed: unknown field');

    expect(addNotification).toHaveBeenCalledTimes(1);
    expect(addNotification.mock.calls[0][1]).toEqual({
      text: 'tachyon-core check failed: unknown field',
    });
    expect(addNotification.mock.calls[0][2]).toBe('danger');
    expect(setIndicator).not.toHaveBeenCalled();
    expect(Object.keys(uiMock.changes.changes)).toHaveLength(1);
    expect(refreshStudioDeck).toHaveBeenCalledTimes(1);
  });

  it('conditions.ts setArrayIfChanged unsets user_domains when cleared even if raw value was empty array or string', () => {
    const asArrayFn = extractFunctionDecl(
      conditionsAst,
      conditionsSource,
      'asArray',
    );
    const asRefFn = extractFunctionDecl(
      conditionsAst,
      conditionsSource,
      'asReferenceArray',
    );
    const unsetFn = extractFunctionDecl(
      conditionsAst,
      conditionsSource,
      'unsetIfPresent',
    );
    const setArrFn = extractFunctionDecl(
      conditionsAst,
      conditionsSource,
      'setArrayIfChanged',
    );

    const compiled = transpileSnippet(`
      ${asArrayFn}
      ${asRefFn}
      ${unsetFn}
      ${setArrFn}
      return setArrayIfChanged;
    `);

    for (const initial of [['example.com'], [], '']) {
      const store = {
        values: {
          tachyon: {
            cond_1: {
              user_domains: initial,
            },
          },
        },
        deletes: {},
      };
      const unsetMock = vi.fn((_pkg, sid, key) => {
        delete store.values.tachyon[sid][key];
      });
      const setMock = vi.fn((_pkg, sid, key, val) => {
        store.values.tachyon[sid][key] = val;
      });
      const uciMock = {
        state: store,
        get: (_pkg, sid, key) => store.values.tachyon[sid]?.[key],
        unset: unsetMock,
        set: setMock,
      };
      const setArrayIfChanged = new Function('UCI_PACKAGE', 'uci', compiled)(
        'tachyon',
        uciMock,
      );

      setArrayIfChanged('cond_1', 'user_domains', []);
      expect(unsetMock).toHaveBeenCalledWith(
        'tachyon',
        'cond_1',
        'user_domains',
      );
      expect(
        Object.prototype.hasOwnProperty.call(
          store.values.tachyon.cond_1,
          'user_domains',
        ),
      ).toBe(false);
    }
  });
});
