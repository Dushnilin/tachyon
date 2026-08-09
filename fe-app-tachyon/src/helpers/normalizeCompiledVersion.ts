export function normalizeCompiledVersion(version: string, commitSha?: string) {
  if (!version || version.includes('COMPILED')) {
    return 'dev';
  }

  if (commitSha && commitSha !== 'unknown' && !commitSha.includes('COMPILED')) {
    const shortSha = commitSha.substring(0, 8);
    if (shortSha && !version.includes(shortSha)) {
      return `${version} (${shortSha})`;
    }
  }

  return version;
}
