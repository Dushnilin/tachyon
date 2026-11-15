export function canUseDirectClashApi(): boolean {
  // All engine communication goes through the pure-Rust backend (ubus_bridge / core_mgr).
  // TypeScript is strictly the web UI and never connects directly to :9090.
  return false;
}

export function getClashWsUrl(): string {
  const { hostname } = window.location;

  return `ws://${hostname}:9090`;
}

export function getClashHttpUrl(): string {
  const { hostname } = window.location;

  return `http://${hostname}:9090`;
}

export function getClashUIUrl(): string {
  const { hostname } = window.location;

  return `http://${hostname}:9090/ui`;
}
