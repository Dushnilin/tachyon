/// <reference types="vite/client" />
import { describe, expect, it } from 'vitest';

/**
 * The frontend reaches the router only by running a binary. Every one of those
 * runs has to name a binary this project ships, or the surface is wider than
 * the contract describes and nothing downstream notices.
 *
 * This is a source-level guard on purpose: the compiler cannot catch
 * `executeShellCommand({ command: someString })`, and the RPC contract only
 * describes the tachyon subcommands, not which executable receives them.
 *
 * Sources are pulled in through Vite's raw glob rather than node's fs, so the
 * browser tsconfig stays free of @types/node.
 */
const SOURCES = import.meta.glob('/src/**/*.ts', {
  query: '?raw',
  import: 'default',
  eager: true,
}) as Record<string, string>;

const ALLOWED_COMMANDS = new Set([
  '/usr/bin/tachyon',
  // Read-only LuCI accounts are denied the main binary by rpcd, so the frontend
  // falls back to this one. It carries the read commands only and refuses the
  // rest itself.
  '/usr/bin/tachyon-read',
  '/sbin/uci',
  '/sbin/logread',
]);

/** Test files are excluded: their fixtures mention commands on purpose. */
const productionSources = Object.entries(SOURCES).filter(
  ([path]) => !path.includes('/tests/') && !path.endsWith('.test.ts'),
);

type Found = { file: string; command: string };

/** Only looks inside an executeShellCommand({...}) argument object. */
function allCommandLiterals(): Found[] {
  const found: Found[] = [];
  const call = /executeShellCommand\(\s*\{/g;
  const command = /command:\s*'([^']+)'/;

  for (const [path, text] of productionSources) {
    for (const match of text.matchAll(call)) {
      const window = text.slice(match.index, match.index + 300);
      const literal = window.match(command);

      if (literal) {
        found.push({ file: path, command: literal[1] });
      }
    }
  }
  return found;
}

function enumMemberNames(source: string, enumName: string): Set<string> {
  const start = source.indexOf(`enum ${enumName}`);
  const names = new Set<string>();
  const member = /^\s*([A-Z0-9_]+)\s*=/gm;
  let match: RegExpExecArray | null;

  while ((match = member.exec(source.slice(start)))) {
    names.add(match[1]);
  }
  return names;
}

function sourceEnding(path: string): string {
  const entry = Object.entries(SOURCES).find(([key]) => key.endsWith(path));

  if (!entry) {
    throw new Error(`source not found: ${path}`);
  }
  return entry[1];
}

describe('shell command surface', () => {
  it('never runs a binary this project does not ship', () => {
    const foreign = allCommandLiterals().filter(
      ({ command }) => !ALLOWED_COMMANDS.has(command),
    );

    expect(foreign.map(({ file, command }) => `${file}: ${command}`)).toEqual(
      [],
    );
  });

  it('keeps at least one call site, so the guard is not vacuous', () => {
    expect(allCommandLiterals().length).toBeGreaterThan(0);
  });

  it('has no command parameter on callBaseMethod', () => {
    const source = sourceEnding('/methods/shell/callBaseMethod.ts');
    const head = source.indexOf('export async function callBaseMethod');
    const signature = source.slice(head, source.indexOf('{', head));

    expect(head).toBeGreaterThan(-1);
    expect(signature).not.toMatch(/command\s*[:?]/);
  });

  it('only calls RPC methods that exist in the enum', () => {
    const known = enumMemberNames(
      sourceEnding('/tachyon/types.ts'),
      'AvailableMethods',
    );
    const shell = sourceEnding('/methods/shell/index.ts');
    const used = new Set(
      [...shell.matchAll(/Tachyon\.AvailableMethods\.([A-Z0-9_]+)/g)].map(
        (match) => match[1],
      ),
    );

    expect(known.size).toBeGreaterThan(0);
    expect(used.size).toBeGreaterThan(0);
    expect([...used].filter((name) => !known.has(name))).toEqual([]);
  });
});
