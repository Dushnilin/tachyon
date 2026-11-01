export function parseValueList(value: unknown): string[] {
  if (!value) return [];
  const lines: string[] = [];
  if (Array.isArray(value)) {
    for (const item of value) {
      if (item != null) {
        lines.push(...String(item).split(/\r?\n/));
      }
    }
  } else {
    lines.push(...String(value).split(/\r?\n/));
  }

  const result: string[] = [];
  for (const rawLine of lines) {
    const stripped = rawLine
      .replace(/^(full|keyword|regex):[ \t]*(\/\/|#).*$/, '')
      .replace(/(^|\s+)\/\/.*$/, '')
      .replace(/(^|\s+)#.*$/, '')
      .trim();
    if (!stripped) continue;

    const tokens = stripped
      .split(/[,\s]+/)
      .map((s) => s.trim())
      .filter(Boolean);
    for (const tok of tokens) {
      if (
        tok.startsWith('//') ||
        tok.startsWith('#') ||
        /^[-=_*~]{2,}$/.test(tok)
      ) {
        continue;
      }
      result.push(tok);
    }
  }

  return result;
}
