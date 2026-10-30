import { Tachyon } from '../../types';
import { tr } from '../../helpers/i18n';
import { resolveSectionEngineMeta } from './partials/renderOverviewRow';

export interface ActiveRouteInfo {
  sectionName?: string;
  sectionDisplayName?: string;
  name: string;
  selector: string;
  latency: number;
  type: string;
}

const SERVICE_ACTIONS = new Set([
  'zapret',
  'zapret2',
  'byedpi',
  'desync',
  'wdtt',
  'olcrtc',
  'block',
  'reject',
  'bypass',
  'direct',
  'dns',
]);
export const SERVICE_OUTBOUND_TYPES = new Set([
  'SING_BOX',
  'ZAPRET',
  'ZAPRET2',
  'BYEDPI',
  'DESYNC',
  'WDTT',
  'OLCRTC',
  'BLOCK',
  'REJECT',
  'BYPASS',
  'DIRECT',
  'DNS',
]);

export function isNonTestableOutboundType(type?: string): boolean {
  if (!type) return false;
  return SERVICE_OUTBOUND_TYPES.has(String(type).trim().toUpperCase());
}

export function isServiceGroup(group: Tachyon.OutboundGroup): boolean {
  if (group.serviceStatus) return true;
  if (group.action && SERVICE_ACTIONS.has(group.action.toLowerCase())) {
    return true;
  }
  if (
    group.outbounds?.length > 0 &&
    group.outbounds.every((o) => isNonTestableOutboundType(o.type))
  ) {
    return true;
  }
  try {
    if (resolveSectionEngineMeta(group).isDpiOnly) {
      return true;
    }
  } catch {
    // ignore engine meta lookup error
  }
  return false;
}

export function getGroupActiveRoute(
  group: Tachyon.OutboundGroup,
): ActiveRouteInfo | null {
  if (!group || !group.outbounds || group.outbounds.length === 0) return null;

  const sectionName = group.sectionName || '';
  const sectionDisplayName = group.displayName || group.sectionName || 'Main';

  const selected =
    group.outbounds.find((o) => o.selected) || group.outbounds[0];
  if (!selected) return null;

  if (selected.priorityInfo) {
    const selName = selected.priorityInfo.selectedName;
    const member =
      selected.priorityInfo.outbounds?.find(
        (m) =>
          m.selected ||
          m.displayName === selName ||
          m.code === selected.priorityInfo?.selectedCode,
      ) || group.outbounds.find((o) => o.displayName === selName);

    return {
      sectionName,
      sectionDisplayName,
      name: selName || member?.displayName || selected.displayName,
      selector: `${selected.displayName} (Priority)`,
      latency: member?.latency ?? -1,
      type: member?.type || 'Priority',
    };
  }

  if (selected.urlTestInfo) {
    const selName = selected.urlTestInfo.selectedName;
    const member =
      selected.urlTestInfo.outbounds?.find(
        (m) =>
          m.selected ||
          m.displayName === selName ||
          m.code === selected.urlTestInfo?.selectedCode,
      ) || group.outbounds.find((o) => o.displayName === selName);

    return {
      sectionName,
      sectionDisplayName,
      name: selName || member?.displayName || selected.displayName,
      selector: `${selected.displayName} (URLTest)`,
      latency: member?.latency ?? -1,
      type: member?.type || 'URLTest',
    };
  }

  return {
    sectionName,
    sectionDisplayName,
    name: selected.displayName,
    selector: tr('Ручной выбор', 'Manual selection'),
    latency: selected.latency ?? -1,
    type: selected.type || 'Proxy',
  };
}

export function getAllActiveRoutes(
  groups: Tachyon.OutboundGroup[],
): ActiveRouteInfo[] {
  if (!groups || groups.length === 0) return [];

  const proxyGroups = groups.filter(
    (g) => !isServiceGroup(g) && g.outbounds && g.outbounds.length > 0,
  );

  return proxyGroups
    .map((g) => getGroupActiveRoute(g))
    .filter((r): r is ActiveRouteInfo => r !== null);
}

export function getActiveRoute(
  groups: Tachyon.OutboundGroup[],
): ActiveRouteInfo | null {
  const routes = getAllActiveRoutes(groups);
  if (routes.length === 0) return null;

  const main = routes.find((r) => r.sectionName?.toLowerCase() === 'main');
  return main || routes[0];
}
