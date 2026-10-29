import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import Module from 'node:module';
import ts from 'typescript';
import prettier from 'prettier';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const viewsSrcDir = path.resolve(__dirname, 'src/views');
const viewsOutDir = path.resolve(
  __dirname,
  '../luci-app-tachyon/htdocs/luci-static/resources/view/tachyon',
);

function stripTsTypes(tsCode, fileName) {
  if (typeof Module.stripTypeScriptTypes === 'function') {
    return Module.stripTypeScriptTypes(tsCode, {
      mode: 'strip',
    });
  }
  const transpiled = ts.transpileModule(tsCode, {
    fileName,
    compilerOptions: {
      target: ts.ScriptTarget.ES2022,
      module: ts.ModuleKind.ESNext,
      removeComments: false,
      newLine: ts.NewLineKind.LineFeed,
    },
  });
  return transpiled.outputText;
}

async function buildViews() {
  let entries = [];
  try {
    entries = await fs.readdir(viewsSrcDir);
  } catch {
    return;
  }

  const tsFiles = entries.filter((f) => f.endsWith('.ts')).sort();
  if (tsFiles.length === 0) return;

  await fs.mkdir(viewsOutDir, { recursive: true });

  for (const tsFile of tsFiles) {
    const srcPath = path.join(viewsSrcDir, tsFile);
    const outFile = tsFile.replace(/\.ts$/, '.js');
    const outPath = path.join(viewsOutDir, outFile);

    const rawTs = await fs.readFile(srcPath, 'utf8');
    // Remove leading linter/TS directive comments that belong only to the TS source
    const cleanedTs = rawTs.replace(
      /^(?:\/\*[\s\S]*?\*\/\s*|\/\/[^\n]*\n\s*)*/,
      (lead) => {
        return lead
          .replace(/\/\* eslint-disable[^*]*\*\/\s*/g, '')
          .replace(/\/\/ @ts-nocheck\s*\n?/g, '');
      },
    );

    const strippedJs = stripTsTypes(cleanedTs, tsFile);
    const formattedJs = await prettier.format(strippedJs, {
      parser: 'babel',
      singleQuote: false,
      tabWidth: 2,
      printWidth: 80,
      semi: true,
      trailingComma: 'all',
    });

    const luciJs = formattedJs
      .replace(/\n*\/\/# sourceURL=[^\n]+\n*/g, '\n')
      .replace(/^export default /m, 'return ');

    const existing = await fs.readFile(outPath, 'utf8').catch(() => null);
    if (existing !== luciJs) {
      await fs.writeFile(outPath, luciJs, 'utf8');
    }
  }

  console.log(`✅ Built ${tsFiles.length} TypeScript LuCI views → ${viewsOutDir}`);
}

buildViews().catch((err) => {
  console.error('❌ Failed to build TypeScript LuCI views:', err);
  process.exit(1);
});
