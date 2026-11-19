import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import ts from 'typescript';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

function stripIllegalReturn(code) {
    return code.replace(/^\s*return\s+[^;]+;\s*$/gm, (match, offset, input) => {
        const after = input.slice(offset + match.length).trim();
        return after === '' ? '' : match;
    });
}

// ponytail: stdlib recursive readdir + typescript AST instead of fast-glob + @babel/{parser,traverse,types}
const srcDir = path.join(__dirname, 'src');
const entries = await fs.readdir(srcDir, { recursive: true });
const files = entries
    .filter((rel) => (rel.endsWith('.ts') || rel.endsWith('.tsx')) && !rel.endsWith('.test.ts'))
    .map((rel) => rel.replaceAll('\\', '/'))
    .sort((a, b) => (a < b ? -1 : a > b ? 1 : 0))
    .map((rel) => path.join(srcDir, rel));

console.log('Found files:', files.length);

const results = {};

for (const file of files) {
    const contentRaw = await fs.readFile(file, 'utf8');
    const content = stripIllegalReturn(contentRaw);
    const relativePath = path.relative(__dirname, file).replaceAll('\\', '/');

    const sourceFile = ts.createSourceFile(
        relativePath,
        content,
        ts.ScriptTarget.Latest,
        true,
        file.endsWith('.tsx') ? ts.ScriptKind.TSX : ts.ScriptKind.TS,
    );

    function visit(node) {
        if (ts.isCallExpression(node) && ts.isIdentifier(node.expression)) {
            const fnName = node.expression.text;
            if (fnName === '_' || fnName === 'translate') {
                const arg = node.arguments[0];
                if (arg && ts.isStringLiteral(arg)) {
                    const key = arg.text.trim();
                    if (key) {
                        const line =
                            sourceFile.getLineAndCharacterOfPosition(node.getStart(sourceFile))
                                .line + 1;
                        const location = `${relativePath}:${line}`;
                        if (!results[key]) {
                            results[key] = { call: key, key, places: [] };
                        }
                        results[key].places.push(location);
                    }
                }
            } else if (fnName === 'tr') {
                const ruArg = node.arguments[0];
                const enArg = node.arguments[1];
                if (ruArg && enArg && ts.isStringLiteral(ruArg) && ts.isStringLiteral(enArg)) {
                    const ru = ruArg.text.trim();
                    const key = enArg.text.trim();
                    if (key) {
                        const line =
                            sourceFile.getLineAndCharacterOfPosition(node.getStart(sourceFile))
                                .line + 1;
                        const location = `${relativePath}:${line}`;
                        if (!results[key]) {
                            results[key] = { call: key, key, places: [] };
                        }
                        if (ru && !results[key].ru) {
                            results[key].ru = ru;
                        }
                        results[key].places.push(location);
                    }
                }
            }
        }
        ts.forEachChild(node, visit);
    }

    visit(sourceFile);
}

const outFile = path.resolve(__dirname, 'locales/calls.json');
const sorted = Object.values(results)
    .map((item) => ({
        ...item,
        places: Array.from(new Set(item.places)).sort(),
    }))
    .sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));

await fs.mkdir(path.dirname(outFile), { recursive: true });
await fs.writeFile(outFile, JSON.stringify(sorted, null, 2), 'utf8');
console.log(`Extracted ${sorted.length} translations to ${outFile}`);
