import fs from 'fs/promises';
import path from 'path';
import glob from 'fast-glob';
import { parse } from '@babel/parser';
import traverse from '@babel/traverse';
import * as t from '@babel/types';
import { fileURLToPath } from 'url';
import { dirname } from 'path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

function stripIllegalReturn(code) {
    return code.replace(/^\s*return\s+[^;]+;\s*$/gm, (match, offset, input) => {
        const after = input.slice(offset + match.length).trim();
        return after === '' ? '' : match;
    });
}

const rawFiles = await glob([
    'src/**/*.ts',
    'src/**/*.tsx',
    '../luci-app-tachyon/htdocs/luci-static/resources/view/tachyon/**/*.js',
], {
    cwd: __dirname,
    ignore: [
        '**/*.test.ts',
        '**/main.js',
    ],
    absolute: true,
});
const files = rawFiles.sort();
console.log('Found files:', files.length);

const results = {};

for (const file of files) {
    const contentRaw = await fs.readFile(file, 'utf8');
    const content = stripIllegalReturn(contentRaw);
    const relativePath = path.relative(__dirname, file).replaceAll('\\', '/');

    let ast;
    try {
        ast = parse(content, {
            sourceType: 'module',
            allowReturnOutsideFunction: true,
            plugins: file.endsWith('.ts') ? ['typescript'] : [],
        });
    } catch (e) {
        console.warn(`⚠️ Parse error in ${relativePath}, skipping:`, e.message);
        continue;
    }

    traverse.default(ast, {
        CallExpression(path) {
            if (
                t.isIdentifier(path.node.callee, { name: '_' }) ||
                t.isIdentifier(path.node.callee, { name: 'translate' })
            ) {
                const arg = path.node.arguments[0];
                if (t.isStringLiteral(arg)) {
                    const key = arg.value.trim();
                    if (!key) return; // ❌ пропустить пустые ключи
                    const location = `${relativePath}:${path.node.loc?.start.line ?? '?'}`;

                    if (!results[key]) {
                        results[key] = { call: key, key, places: [] };
                    }

                    results[key].places.push(location);
                }
            }
        },
    });
}

const outFile = path.resolve(__dirname, 'locales/calls.json');
const sorted = Object.values(results)
    .map((item) => ({
        ...item,
        places: Array.from(new Set(item.places)).sort(),
    }))
    // Sorted by code unit, not localeCompare.
    //
    // localeCompare uses the collation of the machine's locale, so the order of
    // locales/*.pot and *.po depended on whose machine ran the generator. The
    // pre-push hook regenerates the locales and fails when that leaves the tree
    // dirty, so a contributor on a machine with a different locale could not
    // push at all - their regeneration reshuffled entries that were already
    // committed, and the hook read that as drift. Comparing code units is
    // locale-independent, so everyone produces byte-identical output.
    .sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));

await fs.mkdir(path.dirname(outFile), { recursive: true });
await fs.writeFile(outFile, JSON.stringify(sorted, null, 2), 'utf8');
console.log(`✅ Extracted ${sorted.length} translations to ${outFile}`);
