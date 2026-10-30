#!/usr/bin/env node
'use strict';

// Static ucode analyzer:
// 1. Same-file forward references: ucode binds call targets when the target is
//    defined, not when the caller is defined. Calling a top-level function
//    declared further down the file fails at runtime with
//    "Type error: left-hand side is not a function".
// 2. Cross-module missing exports: calling or reading a non-existent export on
//    a `require("...")` module (`mod.missing_fn()` or `let fn = mod.missing_fn`)
//    fails at runtime with "Type error: left-hand side is not a function" or
//    evaluates to `null`.
// 3. Requiring a non-existent internal `.uc` module.
// 4. Calling JavaScript prototype methods (`.forEach()`, `.indexOf()`,
//    `.includes()`, `.substring()`, `.toLowerCase()`, `.toUpperCase()`,
//    `.startsWith()`, `.endsWith()`, `.replaceAll()`) which do not exist in
//    ucode and fail at runtime with "Type error: left-hand side is not a function".

const fs = require('fs');
const path = require('path');

const IDENT = /[A-Za-z_][A-Za-z0-9_]*/;

const BUILTIN_FUNCTIONS = new Set([
  'print',
  'warn',
  'exit',
  'length',
  'push',
  'pop',
  'shift',
  'unshift',
  'index',
  'rindex',
  'require',
  'include',
  'json',
  'match',
  'replace',
  'split',
  'join',
  'substr',
  'trim',
  'ltrim',
  'rtrim',
  'sprintf',
  'printf',
  'lc',
  'uc',
  'type',
  'keys',
  'values',
  'sort',
  'reverse',
  'filter',
  'map',
  'int',
  'getenv',
  'system',
  'clock',
  'sleep',
  'exists',
  'die',
  'assert',
  'uchr',
  'ord',
  'chr',
  'hex',
  'hexenc',
  'hexdec',
  'b64enc',
  'b64dec',
  'min',
  'max',
  'abs',
  'slice',
  'splice',
  'uniq',
  'localtime',
  'gmtime',
  'timelocal',
  'timegm',
  'arrtoip',
  'iptoarr',
  'wildcard',
  'regexp',
  'call',
  'loadstring',
  'loadfile',
  'gc',
  'sourcepath',
  'render',
  'signal',
  'uloop',
  'time',
  'double',
  'isnan',
]);

const CONTROL_KEYWORDS = new Set([
  'if',
  'for',
  'while',
  'switch',
  'catch',
  'return',
  'function',
  'delete',
  'in',
  'typeof',
  'new',
  'else',
  'do',
  'try',
  'throw',
]);

const BUILTIN_MODULES = new Set([
  'fs',
  'uci',
  'ubus',
  'uloop',
  'math',
  'struct',
  'socket',
  'resolv',
  'nl80211',
  'rtnl',
  'digest',
  'zlib',
  'debug',
  'log',
]);

const FORBIDDEN_JS_METHODS = new Set([
  'forEach',
  'indexOf',
  'lastIndexOf',
  'includes',
  'substring',
  'toLowerCase',
  'toUpperCase',
  'startsWith',
  'endsWith',
  'replaceAll',
  'padStart',
  'padEnd',
  'flatMap',
]);

// Replace comment and string bytes with spaces while preserving length and
// newlines so that line numbers stay accurate and identifiers inside literals
// never look like calls.
function stripCommentsAndStrings(source) {
  const out = source.split('');
  let i = 0;
  const n = source.length;
  const blank = (start, end) => {
    for (let k = start; k < end && k < n; k++) {
      if (out[k] !== '\n') out[k] = ' ';
    }
  };

  while (i < n) {
    const c = source[i];
    const next = source[i + 1];

    if (c === '/' && next === '/') {
      let j = i;
      while (j < n && source[j] !== '\n') j++;
      blank(i, j);
      i = j;
      continue;
    }

    if (c === '/' && next === '*') {
      let j = i + 2;
      while (j < n && !(source[j] === '*' && source[j + 1] === '/')) j++;
      blank(i, j + 2);
      i = j + 2;
      continue;
    }

    if (c === '"' || c === "'" || c === '`') {
      const quote = c;
      let j = i + 1;
      while (j < n) {
        if (source[j] === '\\') {
          j += 2;
          continue;
        }
        if (source[j] === quote) {
          j++;
          break;
        }
        j++;
      }
      blank(i, j);
      i = j;
      continue;
    }

    // Regex literals: a '/' that is not a comment opener and not preceded by
    // a value (identifier/number/closing bracket) starts a regex. Regexes may
    // contain unbalanced braces ({4,}), which would break brace tracking.
    if (c === '/') {
      let p = i - 1;
      while (p >= 0 && /\s/.test(source[p])) p--;
      const prev = p >= 0 ? source[p] : '';
      let prevWord = '';
      if (/[A-Za-z0-9_]/.test(prev)) {
        let wp = p;
        while (wp >= 0 && /[A-Za-z0-9_]/.test(source[wp])) wp--;
        prevWord = source.slice(wp + 1, p + 1);
      }
      const afterKeyword =
        prevWord === 'return' ||
        prevWord === 'case' ||
        prevWord === 'in' ||
        prevWord === 'typeof' ||
        prevWord === 'delete' ||
        prevWord === 'throw' ||
        prevWord === 'else';
      const afterValue = !afterKeyword && /[A-Za-z0-9_)%\]]/.test(prev);
      if (!afterValue) {
        let j = i + 1;
        let inClass = false;
        while (j < n && source[j] !== '\n') {
          if (source[j] === '\\') {
            j += 2;
            continue;
          }
          if (source[j] === '[') inClass = true;
          else if (source[j] === ']') inClass = false;
          else if (source[j] === '/' && !inClass) break;
          j++;
        }
        if (j < n && source[j] === '/') {
          blank(i, j + 1);
          i = j + 1;
          continue;
        }
      }
    }

    i++;
  }

  return out.join('');
}

function braceDelta(line) {
  let delta = 0;
  for (const ch of line) {
    if (ch === '{') delta++;
    else if (ch === '}') delta--;
  }
  return delta;
}

function hasAnyBraces(line) {
  for (const ch of line) {
    if (ch === '{' || ch === '}') return true;
  }
  return false;
}

// Collect top-level function declarations. Only declarations starting at column
// zero count: nested helpers are scoped and resolved differently.
function collectTopLevelFunctions(source) {
  const lines = source.split('\n');
  const functions = [];
  let depth = 0;
  let started = false;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!started && depth === 0) {
      const m = /^\s*function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/.exec(line);
      if (m) {
        const name = m[1];
        let end = i;
        let d = 0;
        let seen = false;
        for (let j = i; j < lines.length; j++) {
          if (hasAnyBraces(lines[j])) seen = true;
          d += braceDelta(lines[j]);
          if (seen && d === 0) {
            end = j;
            break;
          }
        }
        functions.push({ name, start: i, end });
        depth = 0;
        started = false;
        i = end;
        continue;
      }
    }
    const delta = braceDelta(line);
    if (delta !== 0) started = true;
    depth += delta;
    // Back at top level (e.g. after a top-level object literal like
    // `const X = { ... };`): allow collecting the next function declaration.
    if (depth <= 0) {
      depth = 0;
      started = false;
    }
  }

  return functions;
}

// Locals that shadow a top-level name make a bare call resolve to the local.
// Collect parameter names, nested functions, and let/const/var declarations inside a function body.
function collectLocalNames(bodyText) {
  const names = new Set();
  const fnRe = /\bfunction(?:\s+([A-Za-z_][A-Za-z0-9_]*))?\s*\(([^)]*)\)/g;
  let fm;
  while ((fm = fnRe.exec(bodyText)) !== null) {
    if (fm[1]) names.add(fm[1]);
    for (const p of fm[2].split(',')) {
      const t = p.trim();
      if (IDENT.test(t)) names.add(t.match(IDENT)[0]);
    }
  }
  const arrowMultiRe = /\(([^)]*)\)\s*=>/g;
  while ((fm = arrowMultiRe.exec(bodyText)) !== null) {
    for (const p of fm[1].split(',')) {
      const t = p.trim();
      if (IDENT.test(t)) names.add(t.match(IDENT)[0]);
    }
  }
  const arrowSingleRe = /\b([A-Za-z_][A-Za-z0-9_]*)\s*=>/g;
  while ((fm = arrowSingleRe.exec(bodyText)) !== null) {
    names.add(fm[1]);
  }
  const declRe = /\b(?:let|const|var)\s+([A-Za-z_][A-Za-z0-9_]*)/g;
  let m;
  while ((m = declRe.exec(bodyText)) !== null) names.add(m[1]);
  return names;
}

function collectTopLevelVars(strippedLines) {
  const vars = new Map();
  let depth = 0;
  for (let i = 0; i < strippedLines.length; i++) {
    const line = strippedLines[i];
    if (depth === 0) {
      const declRe = /\b(?:let|const|var)\s+([A-Za-z_][A-Za-z0-9_]*)/g;
      let m;
      while ((m = declRe.exec(line)) !== null) {
        if (!vars.has(m[1])) vars.set(m[1], i);
      }
    }
    depth += braceDelta(line);
    if (depth < 0) depth = 0;
  }
  return vars;
}

function extractBalancedObject(stripped, openBraceIdx) {
  let depth = 0;
  for (let i = openBraceIdx; i < stripped.length; i++) {
    if (stripped[i] === '{') depth++;
    else if (stripped[i] === '}') {
      depth--;
      if (depth === 0) return stripped.slice(openBraceIdx + 1, i);
    }
  }
  return null;
}

function parseObjectKeys(body) {
  const keys = new Set();
  let d = 0;
  let cur = '';
  const items = [];
  for (let i = 0; i < body.length; i++) {
    const ch = body[i];
    if (ch === '{' || ch === '(' || ch === '[') d++;
    else if (ch === '}' || ch === ')' || ch === ']') d--;
    if (ch === ',' && d === 0) {
      items.push(cur.trim());
      cur = '';
    } else {
      cur += ch;
    }
  }
  if (cur.trim()) items.push(cur.trim());

  for (const item of items) {
    const mColon = /^([A-Za-z_][A-Za-z0-9_]*)\s*:/.exec(item);
    if (mColon) {
      keys.add(mColon[1]);
      continue;
    }
    const mIdent = /^([A-Za-z_][A-Za-z0-9_]*)$/.exec(item);
    if (mIdent) {
      keys.add(mIdent[1]);
    }
  }
  return keys;
}

function parseModuleExports(stripped) {
  // 1. Check if `function module_exports()` exists
  const meMatch = /\bfunction\s+module_exports\s*\(\s*\)\s*\{/.exec(stripped);
  if (meMatch) {
    const fnBody = extractBalancedObject(stripped, meMatch.index + meMatch[0].length - 1);
    if (fnBody) {
      const retMatch = /\breturn\s*\{/.exec(fnBody);
      if (retMatch) {
        const objBody = extractBalancedObject(fnBody, retMatch.index + retMatch[0].length - 1);
        if (objBody) return parseObjectKeys(objBody);
      }
      if (/\breturn\s+constants_map\s*\(/.test(fnBody)) {
        const keys = new Set();
        for (const m of stripped.matchAll(/\bc\.([A-Za-z_][A-Za-z0-9_]*)\s*=/g)) {
          keys.add(m[1]);
        }
        return keys;
      }
    }
  }

  // 2. Otherwise find top-level `return { ... }`
  const retRe = /\breturn\s*\{/g;
  const returnLocations = [];
  let m;
  while ((m = retRe.exec(stripped)) !== null) {
    returnLocations.push({ index: m.index, braceIdx: m.index + m[0].length - 1 });
  }
  if (returnLocations.length > 0) {
    let curDepth = 0;
    let locIdx = 0;
    let lastTopLevelReturnBrace = -1;
    for (let i = 0; i < stripped.length && locIdx < returnLocations.length; i++) {
      if (i === returnLocations[locIdx].index) {
        if (curDepth === 0) {
          lastTopLevelReturnBrace = returnLocations[locIdx].braceIdx;
        }
        locIdx++;
      }
      if (stripped[i] === '{') curDepth++;
      else if (stripped[i] === '}') curDepth = Math.max(0, curDepth - 1);
    }
    if (lastTopLevelReturnBrace >= 0) {
      const objBody = extractBalancedObject(stripped, lastTopLevelReturnBrace);
      if (objBody) return parseObjectKeys(objBody);
    }
  }
  return null;
}

function lintSource(fileName, rawSource, moduleIndex) {
  const source = stripCommentsAndStrings(rawSource);
  const functions = collectTopLevelFunctions(source);
  const definedAt = new Map();
  functions.forEach((f, idx) => definedAt.set(f.name, idx));

  const violations = [];
  const rawLines = rawSource.split('\n');
  const strippedLines = source.split('\n');

  // 1. Same-file forward reference & undeclared function call check
  const topLevelVars = collectTopLevelVars(strippedLines);
  const localShadowsByLine = new Map();
  functions.forEach((fn, idx) => {
    const bodyLines = strippedLines.slice(fn.start, fn.end + 1);
    const bodyText = bodyLines.join('\n');
    const locals = collectLocalNames(bodyText);
    for (let l = fn.start; l <= fn.end; l++) {
      localShadowsByLine.set(l, locals);
    }

    bodyLines.forEach((line, offset) => {
      const lineIdx = fn.start + offset;
      const callRe = /(?<![A-Za-z0-9_.])([A-Za-z_][A-Za-z0-9_]*)\s*\(/g;
      let m;
      while ((m = callRe.exec(line)) !== null) {
        const callee = m[1];
        if (offset === 0 && callee === fn.name) continue;
        // Skip `function foo(` declaration syntax
        const before = line.slice(0, m.index);
        if (/\bfunction\s+$/.test(before)) continue;
        if (CONTROL_KEYWORDS.has(callee) || BUILTIN_FUNCTIONS.has(callee)) continue;
        if (locals.has(callee)) continue;
        if (topLevelVars.has(callee)) {
          if (topLevelVars.get(callee) > lineIdx) {
            violations.push({
              kind: 'forward_ref',
              file: fileName,
              line: lineIdx + 1,
              message:
                `'${fn.name}' calls variable '${callee}' declared later at line ${topLevelVars.get(callee) + 1}`,
            });
          }
          continue;
        }
        if (!definedAt.has(callee)) {
          violations.push({
            kind: 'undefined_call',
            file: fileName,
            line: lineIdx + 1,
            message:
              `'${fn.name}' calls undeclared function '${callee}()' ` +
              `(will fail at runtime with 'left-hand side is not a function')`,
          });
          continue;
        }
        if (definedAt.get(callee) > idx) {
          violations.push({
            kind: 'forward_ref',
            file: fileName,
            line: lineIdx + 1,
            message:
              `'${fn.name}' calls '${callee}' declared later at line ${functions[definedAt.get(callee)].start + 1} ` +
              `(ucode resolves functions definition-order; move '${callee}' above '${fn.name}')`,
          });
        }
      }
    });
  });

  // 1b. Top-level bare function calls (outside any function body)
  strippedLines.forEach((line, lineIdx) => {
    if (localShadowsByLine.has(lineIdx)) return;
    const callRe = /(?<![A-Za-z0-9_.])([A-Za-z_][A-Za-z0-9_]*)\s*\(/g;
    let m;
    while ((m = callRe.exec(line)) !== null) {
      const callee = m[1];
      const before = line.slice(0, m.index);
      if (/\bfunction\s+$/.test(before)) continue;
      if (CONTROL_KEYWORDS.has(callee) || BUILTIN_FUNCTIONS.has(callee)) continue;
      if (topLevelVars.has(callee)) {
        if (topLevelVars.get(callee) > lineIdx) {
          violations.push({
            kind: 'forward_ref',
            file: fileName,
            line: lineIdx + 1,
            message: `top-level call to '${callee}()' declared later at line ${topLevelVars.get(callee) + 1}`,
          });
        }
        continue;
      }
      if (!definedAt.has(callee)) {
        violations.push({
          kind: 'undefined_call',
          file: fileName,
          line: lineIdx + 1,
          message: `top-level call to undeclared function '${callee}()' (will fail at runtime with 'left-hand side is not a function')`,
        });
        continue;
      }
      const targetFn = functions[definedAt.get(callee)];
      if (targetFn.start > lineIdx) {
        violations.push({
          kind: 'forward_ref',
          file: fileName,
          line: lineIdx + 1,
          message: `top-level call to '${callee}()' declared later at line ${targetFn.start + 1}`,
        });
      }
    }
  });

  // 2. Forbidden JavaScript prototype methods check
  strippedLines.forEach((line, lineIdx) => {
    const methodRe = /\.([A-Za-z_][A-Za-z0-9_]*)\s*\(/g;
    let m;
    while ((m = methodRe.exec(line)) !== null) {
      const method = m[1];
      if (FORBIDDEN_JS_METHODS.has(method)) {
        violations.push({
          kind: 'js_method',
          file: fileName,
          line: lineIdx + 1,
          message: `calls JavaScript method '.${method}()' which does not exist in ucode`,
        });
      }
    }
  });

  // 3. Cross-module `require(...)` and export verification (when a moduleIndex is available)
  if (moduleIndex && moduleIndex.hasRoot) {
    const topLevelVarToMod = new Map();
    let curDepth = 0;

    for (let li = 0; li < rawLines.length; li++) {
      const sLine = strippedLines[li];
      const rLine = rawLines[li];

      // Check all `require("...")` on this line for module existence
      if (sLine.includes('require')) {
        const reqAllRe = /\brequire\(\s*["']([^"']+)["']\s*\)/g;
        let rm;
        while ((rm = reqAllRe.exec(rLine)) !== null) {
          const modId = rm[1];
          if (!BUILTIN_MODULES.has(modId) && !moduleIndex.allModules.has(modId)) {
            violations.push({
              kind: 'missing_module',
              file: fileName,
              line: li + 1,
              message: `requires non-existent module '${modId}'`,
            });
          }
        }
      }

      if (curDepth === 0 && sLine.includes('require')) {
        const bindMatch =
          /^\s*(?:let|const|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*require\(\s*["']([^"']+)["']\s*\)\s*;/.exec(
            rLine,
          );
        if (bindMatch) {
          topLevelVarToMod.set(bindMatch[1], bindMatch[2]);
        }
      }

      curDepth += braceDelta(sLine);
      if (curDepth < 0) curDepth = 0;
    }

    // Check `alias.prop` accesses and `alias.prop()` calls against moduleIndex.exports
    strippedLines.forEach((sLine, li) => {
      const locals = localShadowsByLine.get(li);
      const propRe = /\b([A-Za-z_][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)(\s*\()?/g;
      let m;
      while ((m = propRe.exec(sLine)) !== null) {
        const objName = m[1];
        const propName = m[2];
        const isCall = Boolean(m[3]);
        if (!topLevelVarToMod.has(objName)) continue;
        if (locals && locals.has(objName)) continue;

        const modId = topLevelVarToMod.get(objName);
        if (!moduleIndex.exports.has(modId)) continue;
        const exportedKeys = moduleIndex.exports.get(modId);
        if (!exportedKeys.has(propName)) {
          violations.push({
            kind: 'missing_export',
            file: fileName,
            line: li + 1,
            message:
              `'${objName}.${propName}${isCall ? '()' : ''}' references '${propName}', ` +
              `which is not exported by '${modId}'`,
          });
        }
      }
    });
  }

  return violations;
}

function walk(dir, acc) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full, acc);
    else if (entry.name.endsWith('.uc')) acc.push(full);
  }
  return acc;
}

function buildModuleIndex(rootDir, files) {
  const allModules = new Set();
  const exportsMap = new Map();

  for (const file of files) {
    const rel = path.relative(rootDir, file).replace(/\\/g, '/');
    if (rel.startsWith('..')) continue;
    const modId = rel.replace(/\.uc$/, '').replace(/\//g, '.');
    allModules.add(modId);
    const raw = fs.readFileSync(file, 'utf8');
    const stripped = stripCommentsAndStrings(raw);
    const exp = parseModuleExports(stripped);
    if (exp) {
      exportsMap.set(modId, exp);
    }
  }

  return {
    hasRoot: allModules.size > 1,
    allModules,
    exports: exportsMap,
  };
}

function main() {
  const roots = process.argv.slice(2);
  if (roots.length === 0) {
    console.error('usage: ucode_forward_refs.js <dir-or-file>...');
    process.exit(2);
  }

  const files = [];
  let primaryRootDir = null;
  for (const root of roots) {
    const stat = fs.statSync(root);
    if (stat.isDirectory()) {
      if (!primaryRootDir) primaryRootDir = root;
      walk(root, files);
    } else {
      files.push(root);
    }
  }

  const moduleIndex = primaryRootDir ? buildModuleIndex(primaryRootDir, files) : null;

  let total = 0;
  for (const file of files.sort()) {
    const violations = lintSource(file, fs.readFileSync(file, 'utf8'), moduleIndex);
    for (const v of violations) {
      total++;
      console.error(`${v.file}:${v.line}: ${v.message}`);
    }
  }

  if (total > 0) {
    console.error(`\n${total} ucode static error(s) found.`);
    process.exit(1);
  }
}

main();
