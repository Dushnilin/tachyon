import { getOutboundTagBySection } from '../../../runtimeTags';
import { Tachyon } from '../../../types';

function refs(value: string | string[] | undefined): string[] {
  return Array.isArray(value)
    ? value
    : (value || '').split(/\s+/).filter(Boolean);
}

function customOutboundTag(source: Tachyon.ConfigSection): string | undefined {
  try {
    const config: unknown = JSON.parse(source.custom_json || '');
    if (!config || typeof config !== 'object' || Array.isArray(config)) return;
    return 'tag' in config && typeof config.tag === 'string'
      ? config.tag
      : `custom-${source['.name']}`;
  } catch {
    return;
  }
}

export function buildCoreTelemetryRouteLabels(
  config: Tachyon.ConfigSection[],
): ReadonlyMap<string, string> {
  const enabled = config.filter((entry) => entry.enabled !== '0');
  const balancers = new Map(
    enabled
      .filter((entry) => entry['.type'] === 'balancer')
      .map((entry) => [
        entry['.name'],
        entry.name?.trim() || entry.label?.trim(),
      ]),
  );
  const labels = new Map<string, string>();
  const sourceRoutes = new Map<string, string | null>();

  for (const section of enabled) {
    if (section['.type'] !== 'section') continue;
    const id = section['.name'];
    const label = section.label?.trim() || section.name?.trim();
    if (label) {
      labels.set(`sel-${id}`, label);
      labels.set(getOutboundTagBySection(id), label);
      labels.set(`desync-sec-${id}`, label);
      labels.set(`tailscale-sec-${id}`, label);
    }
    for (const source of new Set(refs(section.outbound_source_refs))) {
      sourceRoutes.set(source, sourceRoutes.has(source) ? null : label || null);
    }
    for (const balancer of refs(section.balancer_refs)) {
      const name = balancers.get(balancer);
      if (name) labels.set(`bal-${id}-${balancer}`, name);
    }
  }

  for (const source of enabled) {
    if (source['.type'] !== 'outbound_source') continue;
    const id = source['.name'];
    const isDesync = source.source_type === 'desync';
    const tag = isDesync
      ? `desync-${id}`
      : source.source_type === 'custom_json'
        ? customOutboundTag(source)
        : undefined;
    const label =
      (isDesync && sourceRoutes.get(id)) ||
      source.name?.trim() ||
      source.label?.trim();
    if (tag && label && !labels.has(tag)) labels.set(tag, label);
  }

  return labels;
}
