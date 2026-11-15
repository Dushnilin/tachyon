export function parseQueryString(query: string): Record<string, string> {
  const clean = query.startsWith('?') ? query.slice(1) : query;
  return Object.fromEntries(new URLSearchParams(clean));
}
