import { Tachyon } from '../types';
import { initialDiagnosticStore } from '../tabs/diagnostic/diagnostic.store';

function jsonStableStringify<T, V>(obj: T): string {
  return JSON.stringify(obj, (_, value) => {
    if (value && typeof value === 'object' && !Array.isArray(value)) {
      return Object.keys(value)
        .sort()
        .reduce(
          (acc, key) => {
            acc[key] = value[key];
            return acc;
          },
          {} as Record<string, V>,
        );
    }
    return value;
  });
}

function jsonEqual<A, B>(a: A, b: B): boolean {
  try {
    return jsonStableStringify(a) === jsonStableStringify(b);
  } catch {
    return false;
  }
}

type Listener<T> = (next: T, prev: T, diff: Partial<T>) => void;

// eslint-disable-next-line
export class StoreService<T extends Record<string, any>> {
  private value: T;
  private readonly initial: T;
  private listeners = new Set<Listener<T>>();

  constructor(initial: T) {
    this.value = initial;
    this.initial = structuredClone(initial);
  }

  get(): T {
    return this.value;
  }

  set(next: Partial<T>): void {
    const prev = this.value;
    const diff: Partial<T> = {};

    for (const key in next) {
      // Reference equality fast path: most poll ticks pass the same object
      // identity or genuinely new objects; the sorted stringify below runs
      // on every key of a multi-hundred-KB payload twice per second
      // otherwise.
      if (next[key] === prev[key]) continue;
      if (!jsonEqual(next[key], prev[key])) diff[key] = next[key];
    }

    if (Object.keys(diff).length === 0) {
      return;
    }

    const merged = { ...prev, ...next };
    this.value = merged;
    this.listeners.forEach((cb) => cb(this.value, prev, diff));
  }

  reset<K extends keyof T>(keys?: K[]): void {
    const prev = this.value;
    const next = structuredClone(this.value);

    if (keys && keys.length > 0) {
      keys.forEach((key) => {
        next[key] = structuredClone(this.initial[key]);
      });
    } else {
      Object.assign(next, structuredClone(this.initial));
    }

    if (jsonEqual(prev, next)) return;

    this.value = next;

    const diff: Partial<T> = {};
    for (const key in next) {
      if (!jsonEqual(next[key], prev[key])) diff[key] = next[key];
    }

    this.listeners.forEach((cb) => cb(this.value, prev, diff));
  }

  subscribe(cb: Listener<T>): () => void {
    this.listeners.add(cb);
    cb(this.value, this.value, {});
    return () => this.listeners.delete(cb);
  }

  unsubscribe(cb: Listener<T>): void {
    this.listeners.delete(cb);
  }

  patch<K extends keyof T>(key: K, value: T[K]): void {
    this.set({ [key]: value } as unknown as Partial<T>);
  }

  getKey<K extends keyof T>(key: K): T[K] {
    return this.value[key];
  }

  subscribeKey<K extends keyof T>(
    key: K,
    cb: (value: T[K]) => void,
  ): () => void {
    let prev = this.value[key];
    const wrapper: Listener<T> = (val) => {
      if (!jsonEqual(val[key], prev)) {
        prev = val[key];
        cb(val[key]);
      }
    };
    this.listeners.add(wrapper);
    return () => this.listeners.delete(wrapper);
  }
}

export interface IDiagnosticsChecksItem {
  state: 'error' | 'warning' | 'success';
  key: string;
  value: string;
}

export interface IDiagnosticsChecksStoreItem {
  order: number;
  code: string;
  title: string;
  description: string;
  state: 'loading' | 'warning' | 'success' | 'error' | 'skipped';
  items: Array<IDiagnosticsChecksItem>;
}

export interface StoreType {
  tabService: {
    current: string;
    all: string[];
  };
  activeEngine: string;
  bandwidthWidget: {
    loading: boolean;
    failed: boolean;
    data: { up: number; down: number };
  };
  trafficTotalWidget: {
    loading: boolean;
    failed: boolean;
    data: { downloadTotal: number; uploadTotal: number };
  };
  systemInfoWidget: {
    loading: boolean;
    failed: boolean;
    data: { connections: number; memory: number };
  };
  servicesInfoWidget: {
    loading: boolean;
    failed: boolean;
    data: {
      tachyonCore: number;
      tachyonRunning: number;
      tachyonEnabled: number;
      tachyonStatus: string;
      liteMode?: number;
      tachyonMemoryMb?: number;
      tachyonPid?: number;
      tachyonUptimeSeconds?: number;
      tachyonUptimePretty?: string;
      cpuLoadPercent?: number | null;
      cpuTempC?: number | null;
      watchdogRunning: number;
      tachyonCoreMemoryMb?: number;
      tachyonCorePid?: number;
      tachyonCoreUptimeSeconds?: number;
      tachyonCoreUptimePretty?: string;
      engineVersion?: string;
      dnsmasqRunning?: number;
      dnsmasqMemoryMb?: number;
      dnsmasqLocalCacheEnabled?: number;
      dnsmasqCacheSize?: number;
      dnsmasqPid?: number;
      dnsmasqUptimeSeconds?: number;
      dnsmasqUptimePretty?: string;
    };
  };
  sectionsWidget: {
    loading: boolean;
    failed: boolean;
    data: Tachyon.OutboundGroup[];
    latencyFetchingSections: Record<string, boolean>;
    latencyProgressSections: Record<string, Tachyon.LatencyActionProgress>;
    selectorSwitchingSections: Record<string, string>;
    subscriptionUpdatingSections: Record<string, boolean>;
  };
  diagnosticsRunAction: {
    loading: boolean;
  };
  diagnosticsChecks: Array<IDiagnosticsChecksStoreItem>;
  diagnosticsActions: {
    restart: { loading: boolean };
    start: { loading: boolean };
    stop: { loading: boolean };
    enable: { loading: boolean };
    disable: { loading: boolean };
    globalCheck: { loading: boolean };
    doctor: { loading: boolean };
    aiDoctor: { loading: boolean };
    viewLogs: { loading: boolean };
    showTachyonCoreConfig: { loading: boolean };
    generateBugReport: { loading: boolean };
    checkServices: { loading: boolean };
  };
  diagnosticsSystemInfo: {
    loading: boolean;
    loaded: boolean;
    providerInfoLoaded: boolean;
    tachyon_version: string;
    tachyon_commit_sha: string;
    tachyon_latest_version: string;
    luci_app_version: string;
    tachyon_core_version: string;
    tachyon_core_fptn?: number;
    tachyon_core_tailscale: number;
    tachyon_core_cert_pin?: number;
    tachyon_core_repo_url?: string;
    tachyon_core_backup_version?: string;
    tachyon_core_backup_time?: number;
    active_engine?: string;
    server_inbounds_enabled_count: number;
    direct_bypass_enabled?: number;
    direct_bypass_address?: string;
    direct_bypass_port?: string;
    torrserver_installed?: number;
    torrserver_version?: string;
    torrserver_running?: number;
    torrserver_direct_available?: number;
    torrserver_direct_enabled?: number;
    torrserver_direct_active?: number;
    openwrt_version: string;
    device_model: string;
    kernel_version?: string;
    cpu_arch?: string;
    uptime_seconds?: number;
    load_avg?: string;
    mem_total_mb?: number;
    mem_used_mb?: number;
    mem_free_mb?: number;
    mem_used_pct?: number;
    conntrack_count?: number;
    conntrack_max?: number;
    dns_type?: string;
    dns_strategy?: string;
    fakeip_enabled?: number;
    fakeip_inet4_range?: string;
    fakeip_inet6_range?: string;
    ipv6_mode?: string;
    ipv6_leak_guard?: '0' | '1' | number | boolean;
    ipv6_effective_state?:
      | 'disabled'
      | 'leak_guard'
      | 'tunnel_over_v4'
      | 'full'
      | string;
    wan_ip?: string;
    wan_ipv6?: string;
    lan_ip?: string;
    lan_ipv6?: string;
    wan6_prefix?: string;
    wan6_pd?: string[];
    wan6_available?: 0 | 1 | boolean;
    wan6_iface?: string;
    router_hostname?: string;
    runtime_dns_strategy?: string;
    webrtc_leak_protect?: '0' | '1' | number | boolean;
    inbound_mode?: string;
    active_sections_count?: number;
    total_sections_count?: number;
    quarantined_sections_count?: number;
    deferred_sections_count?: number;
  };
  updatesActions: {
    tachyonCheck: { loading: boolean };
    tachyonInstall: { loading: boolean };
    tachyonReinstall: { loading: boolean };
    tachyonRollback: { loading: boolean };
    tachyonCoreCheck: { loading: boolean };
    tachyonCoreInstall: { loading: boolean };
    tachyonCoreRollback: { loading: boolean };
    directBypassEnable: { loading: boolean };
    directBypassDisable: { loading: boolean };
    torrserverDirectCheck: { loading: boolean };
    torrserverDirectInstall: { loading: boolean };
    torrserverDirectRemove: { loading: boolean };
    torrserverDirectEnable: { loading: boolean };
    torrserverDirectDisable: { loading: boolean };
  };
  updatesChecks: Record<
    Tachyon.ComponentName,
    {
      status: 'latest' | 'outdated' | 'dev' | 'outdated_same_release' | null;
      latest_version: string;
      current_version?: string;
      release_url: string;
      release_notes?: string;
      current_sha?: string;
      latest_sha?: string;
    }
  >;
}

const initialStore: StoreType = {
  tabService: {
    current: '',
    all: [],
  },
  activeEngine: 'tachyon-core',
  bandwidthWidget: {
    loading: true,
    failed: false,
    data: { up: 0, down: 0 },
  },
  trafficTotalWidget: {
    loading: true,
    failed: false,
    data: { downloadTotal: 0, uploadTotal: 0 },
  },
  systemInfoWidget: {
    loading: true,
    failed: false,
    data: { connections: 0, memory: 0 },
  },
  servicesInfoWidget: {
    loading: true,
    failed: false,
    data: {
      tachyonCore: 0,
      tachyonRunning: 0,
      tachyonEnabled: 0,
      tachyonStatus: '',
      watchdogRunning: 0,
    },
  },
  sectionsWidget: {
    loading: true,
    failed: false,
    latencyFetchingSections: {},
    latencyProgressSections: {},
    selectorSwitchingSections: {},
    subscriptionUpdatingSections: {},
    data: [],
  },
  ...initialDiagnosticStore,
};

export const store = new StoreService<StoreType>(initialStore);
