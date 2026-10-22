import { Tachyon } from '../../types';

export interface ActiveRouteInfo {
  name: string;
  selector: string;
  latency: number;
  type: string;
}

export function getActiveRoute(
  groups: Tachyon.OutboundGroup[],
): ActiveRouteInfo | null {
  if (!groups || groups.length === 0) return null;
  const group = groups.find((g) => g.sectionName === 'main') || groups[0];
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
    selector: _('Manual selection'),
    latency: selected.latency ?? -1,
    type: selected.type || 'Proxy',
  };
}
