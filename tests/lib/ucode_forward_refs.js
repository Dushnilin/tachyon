#!/usr/bin/env node
'use strict';

// ucode binds call targets when the target is defined, not when the caller is
// defined. A top-level function that calls another top-level function declared
// further down the file therefore fails at runtime with
// "left-hand side is not a function" (see the tachyon self-update regression).
//
// This linter reproduces that resolution rule statically: for every top-level
// function it flags calls to sibling top-level functions that are declared
// later in the same file.

const fs = require('fs');
const path = require('path');

const IDENT = /[A-Za-z_][A-Za-z0-9_]*/;

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
      const afterValue = /[A-Za-z0-9_)%\]]/.test(prev);
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
      const m = /^function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/.exec(line);
      if (m) {
        const name = m[1];
        let end = i;
        let d = 0;
        let seen = false;
        for (let j = i; j < lines.length; j++) {
          const delta = braceDelta(lines[j]);
          if (delta !== 0) seen = true;
          d += delta;
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
// Collect parameter names and let/const/var declarations inside a function body.
function collectLocalNames(bodyText) {
  const names = new Set();
  const param = /^function\s+[A-Za-z_][A-Za-z0-9_]*\s*\(([^)]*)\)/.exec(bodyText);
  if (param) {
    for (const p of param[1].split(',')) {
      const t = p.trim();
      if (IDENT.test(t)) names.add(t.match(IDENT)[0]);
    }
  }
  const declRe = /\b(?:let|const|var)\s+([A-Za-z_][A-Za-z0-9_]*)/g;
  let m;
  while ((m = declRe.exec(bodyText)) !== null) names.add(m[1]);
  return names;
}

function lintSource(fileName, rawSource) {
  const source = stripCommentsAndStrings(rawSource);
  const functions = collectTopLevelFunctions(source);
  const definedAt = new Map();
  functions.forEach((f, idx) => definedAt.set(f.name, idx));

  const violations = [];

  functions.forEach((fn, idx) => {
    const bodyLines = source.split('\n').slice(fn.start, fn.end + 1);
    const bodyText = bodyLines.join('\n');
    const locals = collectLocalNames(bodyText);

    bodyLines.forEach((line, offset) => {
      const callRe = /(?<![A-Za-z0-9_.])([A-Za-z_][A-Za-z0-9_]*)\s*\(/g;
      let m;
      while ((m = callRe.exec(line)) !== null) {
        const callee = m[1];
        if (locals.has(callee)) continue;
        if (!definedAt.has(callee)) continue;
        if (definedAt.get(callee) > idx) {
          violations.push({
            file: fileName,
            line: fn.start + offset + 1,
            caller: fn.name,
            callee,
            calleeLine: functions[definedAt.get(callee)].start + 1,
          });
        }
      }
    });
  });

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

function main() {
  const roots = process.argv.slice(2);
  if (roots.length === 0) {
    console.error('usage: ucode_forward_refs.js <dir-or-file>...');
    process.exit(2);
  }

  const files = [];
  for (const root of roots) {
    const stat = fs.statSync(root);
    if (stat.isDirectory()) walk(root, files);
    else files.push(root);
  }

  let total = 0;
  for (const file of files.sort()) {
    const violations = lintSource(file, fs.readFileSync(file, 'utf8'));
    for (const v of violations) {
      total++;
      console.error(
        `${v.file}:${v.line}: '${v.caller}' calls '${v.callee}' declared later at line ${v.calleeLine} ` +
          `(ucode resolves functions definition-order; move '${v.callee}' above '${v.caller}')`,
      );
    }
  }

  if (total > 0) {
    console.error(`\n${total} forward reference(s) found.`);
    process.exit(1);
  }
}

main();
