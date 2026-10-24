import { tr } from '../helpers/i18n';

declare const rpc:
  | {
      declare: (spec: unknown) => () => Promise<Record<string, unknown>>;
    }
  | undefined;

const callHostHints =
  typeof rpc !== 'undefined' && typeof rpc.declare === 'function'
    ? rpc.declare({
        object: 'luci-rpc',
        method: 'getHostHints',
        expect: { '': {} },
      })
    : null;

const callNetworkInterfaceDump =
  typeof rpc !== 'undefined' && typeof rpc.declare === 'function'
    ? rpc.declare({
        object: 'network.interface',
        method: 'dump',
        expect: { '': {} },
      })
    : null;

export async function fetchHostnames(): Promise<Map<string, string>> {
  const hostnames = new Map<string, string>();

  // 1. Resolve router hostname (for localhost / 127.0.0.1)
  let routerHostname = 'Flint-2';
  try {
    const globalObj = (
      typeof globalThis !== 'undefined'
        ? globalThis
        : typeof window !== 'undefined'
          ? window
          : {}
    ) as { L?: { env?: { hostname?: string } } };
    if (globalObj.L?.env?.hostname) {
      routerHostname = globalObj.L.env.hostname;
    } else if (typeof fs !== 'undefined' && typeof fs.read === 'function') {
      const raw = await fs.read('/proc/sys/kernel/hostname');
      if (raw && raw.trim()) {
        routerHostname = raw.trim();
      }
    }
  } catch {
    // fallback to Flint-2
  }

  hostnames.set('127.0.0.1', routerHostname);

  // 2. Identify WAN interface IPv4 addresses for Router (WAN) labeling
  const wanIps = new Set<string>(['95.165.105.233']);
  if (callNetworkInterfaceDump) {
    try {
      const dump = (await callNetworkInterfaceDump()) as {
        interface?: Array<{
          interface?: string;
          'ipv4-address'?: Array<{ address?: string }>;
        }>;
      };
      if (dump && Array.isArray(dump.interface)) {
        for (const iface of dump.interface) {
          if (iface.interface === 'wan' || iface.interface === 'wan6') {
            if (Array.isArray(iface['ipv4-address'])) {
              for (const addr of iface['ipv4-address']) {
                if (addr?.address) {
                  wanIps.add(addr.address);
                }
              }
            }
          }
        }
      }
    } catch {
      // ignore
    }
  }

  const routerWanLabel = tr('Роутер (WAN)', 'Router (WAN)');
  for (const wanIp of wanIps) {
    hostnames.set(wanIp, routerWanLabel);
  }

  // 3. Resolve host hints from LuCI RPC
  if (callHostHints) {
    try {
      const hints = await callHostHints();
      if (hints && typeof hints === 'object') {
        for (const mac of Object.keys(hints)) {
          const hint = hints[mac] as
            | { name?: string; ipaddrs?: string[] }
            | undefined;
          if (hint && hint.ipaddrs && Array.isArray(hint.ipaddrs)) {
            const trimmedName =
              typeof hint.name === 'string' ? hint.name.trim() : '';
            const effectiveName =
              trimmedName && trimmedName !== '*' ? trimmedName : mac;
            for (const ip of hint.ipaddrs) {
              if (!hostnames.has(ip)) {
                hostnames.set(ip, effectiveName);
              }
            }
          }
        }
      }
    } catch (e) {
      console.error('fetchHostnames error', e);
    }
  }

  return hostnames;
}
