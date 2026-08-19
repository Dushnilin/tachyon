export function parseValueList(value: string): string[] {
  return value
    .split(/\n/)
    .map((line) => line.split('//')[0].split('#')[0])
    .join(' ')
    .split(/[,\s]+/)
    .map((s) => s.trim())
    .filter(Boolean);
}
