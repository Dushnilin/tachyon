export function parseValueList(value: string): string[] {
  return value
    .split(/\r?\n/)
    .map((line) => {
      const stripped = line.replace(
        /^(full|keyword|regex):[ \t]*(\/\/|#).*$/,
        '',
      );
      return stripped.split('//')[0].split('#')[0];
    })
    .join(' ')
    .split(/[,\s]+/)
    .map((s) => s.trim())
    .filter(Boolean);
}
