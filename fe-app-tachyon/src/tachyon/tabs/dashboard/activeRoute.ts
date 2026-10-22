import { Tachyon } from '../../types';
import { tr } from '../../helpers/i18n';

export interface ActiveRouteInfo {
  name: string;
  selector: string;
  latency: number;
  type: string;
}

const SERVICE_ACTIONS = new Set([
  'zapret',
  'zapret2',
  'byedpi',
  'wdtt',
  'olcrtc',
]);
const SERVICE_OUTBOUND_TYPES = new Set([
  'SING_BOX',
  'ZAPRET',
  'ZAPRET2',
  'BYEDPI',
]);

function isServiceGroup(group: Tachyon.OutboundGroup): boolean {
  if (group.serviceStatus) return true;
  if (group.action && SERVICE_ACTIONS.has(group.action.toLowerCase())) {
    return true;
  }
  if (
    group.outbounds?.length > 0 &&
    group.outbounds.every((o) => SERVICE_OUTBOUND_TYPES.has(o.type))
  ) {
    return true;
  }
  return false;
}

export function getActiveRoute(
  groups: Tachyon.OutboundGroup[],
): ActiveRouteInfo | null {
  if (!groups || groups.length === 0) return null;

  const proxyGroups = groups.filter(
    (g) => !isServiceGroup(g) && g.outbounds && g.outbounds.length > 0,
  );
  const candidateGroups = proxyGroups.length > 0 ? proxyGroups : [];
  if (candidateGroups.length === 0) return null;

  const group =
    candidateGroups.find((g) => g.sectionName.toLowerCase() === 'main') ||
    candidateGroups.find((g) => g.withTagSelect) ||
    candidateGroups[0];
  if (!group || !group.outbounds || group.outbounds.length === 0) return null;

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
      name: selName || member?.displayName || selected.displayName,
      selector: `${selected.displayName} (URLTest)`,
      latency: member?.latency ?? -1,
      type: member?.type || 'URLTest',
    };
  }

  return {
    name: selected.displayName,
    selector: tr('Ручной выбор', 'Manual selection'),
    latency: selected.latency ?? -1,
    type: selected.type || 'Proxy',
  };
}
