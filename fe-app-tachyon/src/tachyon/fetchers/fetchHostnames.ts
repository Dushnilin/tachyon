import { tr } from '../helpers/i18n';
import { store } from '../services/store.service';
import { unbracketHost } from '../../validators/hostPort';

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

  const sysInfo = store.get()?.diagnosticsSystemInfo;

  // 1. Resolve router hostname (for localhost 127.0.0.1 / ::1 and router LAN IPs)
  let routerHostname =
    sysInfo?.router_hostname?.trim() || tr('Роутер', 'Router');
  try {
    const globalObj = (
      typeof globalThis !== 'undefined'
        ? globalThis
        : typeof window !== 'undefined'
          ? window
          : {}
    ) as { L?: { env?: { hostname?: string } } };
    if (globalObj.L?.env?.hostname?.trim()) {
      routerHostname = globalObj.L.env.hostname.trim();
    } else if (
      !sysInfo?.router_hostname?.trim() &&
      typeof fs !== 'undefined' &&
      typeof fs.read === 'function'
    ) {
      const raw = await fs.read('/proc/sys/kernel/hostname');
      if (raw && raw.trim()) {
        routerHostname = raw.trim();
      }
    }
  } catch {
    // keep detected fallback
  }

  hostnames.set('127.0.0.1', routerHostname);
  hostnames.set('::1', routerHostname);

  // 2. Identify LAN & WAN IPv4/IPv6 addresses for Router labeling
  const lanIps = new Set<string>();
  const wanIps = new Set<string>();
  if (sysInfo?.lan_ip) lanIps.add(unbracketHost(sysInfo.lan_ip));
  if (sysInfo?.lan_ipv6) lanIps.add(unbracketHost(sysInfo.lan_ipv6));
  if (sysInfo?.wan_ip) wanIps.add(unbracketHost(sysInfo.wan_ip));
  if (sysInfo?.wan_ipv6) wanIps.add(unbracketHost(sysInfo.wan_ipv6));

  if (callNetworkInterfaceDump) {
    try {
      const dump = (await callNetworkInterfaceDump()) as {
        interface?: Array<{
          interface?: string;
          'ipv4-address'?: Array<{ address?: string }>;
          'ipv6-address'?: Array<{ address?: string }>;
          'ipv6-prefix-assignment'?: Array<{
            'local-address'?: { address?: string };
          }>;
        }>;
      };
      if (dump && Array.isArray(dump.interface)) {
        for (const iface of dump.interface) {
          const targetSet =
            iface.interface === 'wan' || iface.interface === 'wan6'
              ? wanIps
              : iface.interface === 'lan' || iface.interface === 'br-lan'
                ? lanIps
                : null;
          if (!targetSet) continue;
          if (Array.isArray(iface['ipv4-address'])) {
            for (const addr of iface['ipv4-address']) {
              if (addr?.address) {
                targetSet.add(unbracketHost(addr.address));
              }
            }
          }
          if (Array.isArray(iface['ipv6-address'])) {
            for (const addr of iface['ipv6-address']) {
              if (addr?.address) {
                targetSet.add(unbracketHost(addr.address));
              }
            }
          }
          if (Array.isArray(iface['ipv6-prefix-assignment'])) {
            for (const pd of iface['ipv6-prefix-assignment']) {
              const localAddr = pd?.['local-address']?.address;
              if (localAddr) {
                targetSet.add(unbracketHost(localAddr));
              }
            }
          }
        }
      }
    } catch {
      // ignore
    }
  }

  for (const lanIp of lanIps) {
    if (lanIp && !hostnames.has(lanIp)) {
      hostnames.set(lanIp, routerHostname);
    }
  }

  const routerWanLabel = tr('Роутер (WAN)', 'Router (WAN)');
  for (const wanIp of wanIps) {
    if (wanIp) {
      hostnames.set(wanIp, routerWanLabel);
    }
  }

  // 3. Resolve host hints from LuCI RPC (both IPv4 and IPv6)
  if (callHostHints) {
    try {
      const hints = await callHostHints();
      if (hints && typeof hints === 'object') {
        for (const mac of Object.keys(hints)) {
          const hint = hints[mac] as
            | { name?: string; ipaddrs?: string[]; ip6addrs?: string[] }
            | undefined;
          if (!hint) continue;
          const allAddrs = [
            ...(Array.isArray(hint.ipaddrs) ? hint.ipaddrs : []),
            ...(Array.isArray(hint.ip6addrs) ? hint.ip6addrs : []),
          ];
          if (allAddrs.length > 0) {
            const trimmedName =
              typeof hint.name === 'string' ? hint.name.trim() : '';
            const effectiveName =
              trimmedName && trimmedName !== '*' ? trimmedName : mac;
            for (const rawIp of allAddrs) {
              const cleanIp = unbracketHost(String(rawIp || '').split('%')[0]);
              if (cleanIp && !hostnames.has(cleanIp)) {
                hostnames.set(cleanIp, effectiveName);
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
