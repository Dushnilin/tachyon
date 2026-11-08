const RESERVED_RUNTIME_TAGS = new Set([
  'dns-server',
  'fakeip-server',
  'bootstrap-dns-server',
  'fakeip-dns-rule-tag',
  'fakeip-ruleset-dns-rule-tag',
  'service-fakeip-dns-rule-tag',
  'tproxy-in',
  'tproxy6-in',
  'dns-in',
  'service-mixed-in',
  'direct-out',
  'bypass-out',
]);

function allocateRuntimeTag(base: string, postfix: string): string {
  let suffix = 1;
  let candidate = `${base}-${postfix}`;

  while (RESERVED_RUNTIME_TAGS.has(candidate)) {
    candidate = `${base}-${postfix}-${suffix}`;
    suffix += 1;
  }

  return candidate;
}

export function getOutboundTagBySection(sectionName: string): string {
  return allocateRuntimeTag(sectionName, 'out');
}

export function cleanBalancerTagId(sectionName: string, id: string): string {
  if (!id || id === 'urltest' || !sectionName) {
    return id;
  }
  let s = id;
  if (s.startsWith('bal_prio_')) {
    s = s.slice(9);
  } else if (s.startsWith('bal_')) {
    s = s.slice(4);
  } else {
    return id;
  }
  const prefix = `${sectionName}_`;
  const suffix = `_${sectionName}`;
  const lower = s.toLowerCase();
  if (lower.startsWith(prefix.toLowerCase())) {
    const trimmed = s.slice(prefix.length);
    return trimmed || id;
  }
  if (s.length > suffix.length && lower.endsWith(suffix.toLowerCase())) {
    const trimmed = s.slice(0, s.length - suffix.length);
    return trimmed || id;
  }
  return id;
}
