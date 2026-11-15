declare const rpc:
  | {
      declare: (spec: unknown) => () => Promise<Record<string, unknown>>;
    }
  | undefined;

declare const network:
  | {
      getDevices: () => Promise<
        Array<{
          getName?: () => string;
          getType?: () => string;
          getTypeI18n?: () => string;
          name?: string;
          device?: string;
          type?: string;
        }>
      >;
    }
  | undefined;

export interface AdvNetworkDevice {
  id: string;
  label: string;
  proto?: string;
  device?: string;
}

interface InterfaceDumpResponse {
  interface?: Array<{
    interface?: string;
    device?: string;
    l3_device?: string;
    proto?: string;
    up?: boolean;
  }>;
}

const callNetworkInterfaceDump =
  typeof rpc !== 'undefined' && typeof rpc.declare === 'function'
    ? rpc.declare({
        object: 'network.interface',
        method: 'dump',
        expect: { '': {} },
      })
    : null;

export async function fetchNetworkInterfaces(): Promise<AdvNetworkDevice[]> {
  const result: AdvNetworkDevice[] = [];
  const seen = new Set<string>();

  // 1. Try fetching logical and physical interfaces from ubus network.interface dump
  if (callNetworkInterfaceDump) {
    try {
      const dump = (await callNetworkInterfaceDump()) as InterfaceDumpResponse;
      if (dump && Array.isArray(dump.interface)) {
        for (const iface of dump.interface) {
          const ifname = iface.interface;
          const dev = iface.l3_device || iface.device;
          const proto = iface.proto || '';

          if (dev && dev !== 'lo' && !seen.has(dev)) {
            seen.add(dev);
            const protoDesc = proto ? ` (${proto})` : '';
            result.push({
              id: dev,
              label: `${dev}${protoDesc}`,
              proto,
              device: dev,
            });
          }

          if (ifname && ifname !== 'loopback' && !seen.has(ifname)) {
            seen.add(ifname);
            const ifaceDesc =
              dev && dev !== ifname
                ? ` (${proto || 'iface'}: ${dev})`
                : proto
                  ? ` (${proto})`
                  : '';
            result.push({
              id: ifname,
              label: `${ifname}${ifaceDesc}`,
              proto,
              device: dev,
            });
          }
        }
      }
    } catch (_e) {
      // Ignore RPC error in tests or unsupported environments
    }
  }

  // 2. Fallback or augment via LuCI network.getDevices() if available
  if (
    typeof network !== 'undefined' &&
    typeof network.getDevices === 'function'
  ) {
    try {
      const devices = await network.getDevices();
      if (Array.isArray(devices)) {
        for (const dev of devices) {
          const name =
            typeof dev.getName === 'function'
              ? dev.getName()
              : dev.name || dev.device;
          if (name && name !== 'lo' && !seen.has(name)) {
            seen.add(name);
            const type =
              typeof dev.getTypeI18n === 'function'
                ? dev.getTypeI18n()
                : typeof dev.getType === 'function'
                  ? dev.getType()
                  : dev.type || '';
            const typeDesc = type ? ` (${type})` : '';
            result.push({
              id: name,
              label: `${name}${typeDesc}`,
              device: name,
            });
          }
        }
      }
    } catch (_e) {
      // Ignore
    }
  }

  return result;
}
