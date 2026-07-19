declare const rpc: any;

const callHostHints = rpc.declare({
  object: "luci-rpc",
  method: "getHostHints",
  expect: { "": {} },
});

export async function fetchHostnames(): Promise<Map<string, string>> {
  const hostnames = new Map<string, string>();
  
  try {
    const hints = await callHostHints();
    if (hints && typeof hints === 'object') {
      for (const mac of Object.keys(hints)) {
        const hint = hints[mac];
        if (hint.name && hint.ipaddrs && Array.isArray(hint.ipaddrs)) {
          for (const ip of hint.ipaddrs) {
            if (!hostnames.has(ip)) {
              hostnames.set(ip, hint.name);
            }
          }
        }
      }
    }
  } catch (e) {
    console.error('fetchHostnames error', e);
  }

  return hostnames;
}
