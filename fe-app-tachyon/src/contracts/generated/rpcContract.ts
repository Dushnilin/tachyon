/**
 * AUTO-GENERATED FILE — DO NOT EDIT DIRECTLY
 * Generated from contracts/tachyon-rpc.json via tools/generate_rpc_contract.js
 * Contract version: 1.0.0
 */

export type RpcAclLevel = 'read' | 'write' | 'admin' | 'diagnostic';
export type RpcCategory = 'system' | 'engine' | 'diagnostics' | 'jobs' | 'events' | 'known_good' | 'updates' | 'dns' | 'fuzzer' | 'snapshots';

export const TACHYON_RPC_METHODS = [
  'get_status',
  'get_sing_box_status',
  'get_engine_status',
  'get_ui_capabilities',
  'get_ui_state',
  'service_action_async',
  'service_action_status',
  'clash_api',
  'job_list',
  'job_query',
  'job_cancel',
  'job_request_cancel',
  'job_gc',
  'event_query',
  'event_tail',
  'event_stats',
  'event_clear',
  'event_record',
  'known_good',
  'known_good_promote',
  'known_good_restore',
  'known_good_check',
  'route_explain',
  'support_bundle',
  'resolve_domain',
  'config_plan',
  'config_validate',
  'reconcile',
  'escalation_status',
  'emergency_status',
  'emergency_reset',
  'check_nft_rules',
  'check_fakeip',
  'check_dns_available',
  'check_ip_leak',
  'check_dns_leak',
  'list_update_async',
  'subscription_update_async',
  'dns_benchmark_async',
  'dns_benchmark_status',
  'fuzzer_start',
  'fuzzer_status',
  'snapshot_list',
  'snapshot_save',
  'snapshot_restore',
] as const;

export type TachyonRpcMethodName = (typeof TACHYON_RPC_METHODS)[number];

export interface RpcParamDescriptor {
  name: string;
  type: 'string' | 'number' | 'boolean' | 'object' | 'array';
  required: boolean;
  description: string;
  enum?: string[];
  default?: unknown;
}

export interface RpcMethodMetadata {
  name: TachyonRpcMethodName;
  cli_command: string;
  category: RpcCategory;
  acl: RpcAclLevel;
  description: string;
  async: boolean;
  timeout_ms: number;
  params: RpcParamDescriptor[];
}

/** Get current Tachyon daemon status and operational metrics */
export type GetstatusParams = Record<string, never>;

export type GetstatusResult = Record<string, unknown>;

/** Get sing-box process status and runtime flags */
export type GetsingboxstatusParams = Record<string, never>;

export type GetsingboxstatusResult = Record<string, unknown>;

/** Get active bypass engine status (sing-box or steer) */
export type GetenginestatusParams = Record<string, never>;

export type GetenginestatusResult = Record<string, unknown>;

/** Query hardware and software capabilities supported on this router */
export type GetuicapabilitiesParams = Record<string, never>;

export type GetuicapabilitiesResult = Record<string, unknown>;

/** Atomic composite snapshot of services, capabilities, and active jobs for UI */
export type GetuistateParams = Record<string, never>;

export type GetuistateResult = Record<string, unknown>;

/** Initiate async lifecycle action (start, stop, restart, reload) */
export interface ServiceactionasyncParams {
  /** Lifecycle action to trigger */
  action: 'start' | 'stop' | 'restart' | 'reload' | 'reload_firewall';
}

export type ServiceactionasyncResult = Record<string, unknown>;

/** Poll status of an async lifecycle action */
export interface ServiceactionstatusParams {
  /** Job ID returned by service_action_async */
  job_id: string;
}

export type ServiceactionstatusResult = Record<string, unknown>;

/** Query or mutate the sing-box / clash REST API interface */
export interface ClashapiParams {
  /** Clash API endpoint path or action */
  endpoint: string;
  /** First argument (e.g. proxy or group name) */
  arg1?: string;
  /** Second argument (e.g. selected node name or test URL) */
  arg2?: string;
  /** Third argument (e.g. timeout in ms) */
  arg3?: string;
}

export type ClashapiResult = Record<string, unknown>;

/** List background jobs with status, progress, and cancellation metadata */
export interface JoblistParams {
  /** Include completed and terminal jobs */
  all?: boolean;
}

export type JoblistResult = Record<string, unknown>[];

/** Query specific background job by ID */
export interface JobqueryParams {
  /** Unique job identifier */
  job_id: string;
}

export type JobqueryResult = Record<string, unknown>;

/** Cancel background job (cooperative with safe rollback, or forced kill) */
export interface JobcancelParams {
  /** Job ID to cancel */
  job_id: string;
  /** Immediately terminate worker process with SIGKILL */
  force?: boolean;
  /** Cancellation rationale */
  reason?: string;
}

export type JobcancelResult = Record<string, unknown>;

/** Request graceful cooperative cancellation of a background job */
export interface JobrequestcancelParams {
  /** Job ID */
  job_id: string;
  /** Cancellation reason */
  reason?: string;
}

export type JobrequestcancelResult = Record<string, unknown>;

/** Garbage collect stale and completed jobs from disk */
export type JobgcParams = Record<string, never>;

export type JobgcResult = Record<string, unknown>;

/** Query event journal entries matching criteria */
export interface EventqueryParams {
  /** Filter criteria (event, severity, source, job_id, since_ts, limit) */
  filter?: Record<string, unknown>;
}

export type EventqueryResult = Record<string, unknown>[];

/** Retrieve the most recent N entries from the event journal */
export interface EventtailParams {
  /** Number of recent entries to fetch */
  count?: number;
}

export type EventtailResult = Record<string, unknown>[];

/** Get event journal storage metrics and capacity */
export type EventstatsParams = Record<string, never>;

export type EventstatsResult = Record<string, unknown>;

/** Clear all entries in the event journal */
export type EventclearParams = Record<string, never>;

export type EventclearResult = boolean;

/** Record an event to the persistent event journal */
export interface EventrecordParams {
  /** Event identifier name */
  event: string;
  /** Event payload data */
  data?: Record<string, unknown>;
  /** Severity level */
  severity?: 'debug' | 'info' | 'warn' | 'error' | 'fatal';
  /** Originating subsystem */
  source?: string;
  /** Human-readable message */
  message?: string;
}

export type EventrecordResult = Record<string, unknown>;

/** Query Last Known Good status, active observation window, and manifests */
export interface KnowngoodParams {
  /** Output JSON format */
  json?: boolean;
}

export type KnowngoodResult = Record<string, unknown>;

/** Promote current running configuration to Last Known Good state */
export interface KnowngoodpromoteParams {
  /** Promotion rationale */
  reason?: string;
}

export type KnowngoodpromoteResult = Record<string, unknown>;

/** Rollback active configuration to Last Known Good state */
export interface KnowngoodrestoreParams {
  /** Rollback reason */
  reason?: string;
}

export type KnowngoodrestoreResult = Record<string, unknown>;

/** Probe health metrics during observation window and auto-promote if elapsed */
export type KnowngoodcheckParams = Record<string, never>;

export type KnowngoodcheckResult = Record<string, unknown>;

/** End-to-end tracing and explanation of routing, DNS, nftables, and outbound decisions */
export interface RouteexplainParams {
  /** Client IP address or CIDR */
  client: string;
  /** Destination domain or IP */
  target: string;
  /** Destination port */
  port?: number;
  /** L4 transport protocol */
  proto?: 'tcp' | 'udp';
}

export type RouteexplainResult = Record<string, unknown>;

/** Generate sanitized diagnostic support bundle archive without secrets */
export interface SupportbundleParams {
  /** Target destination path */
  path?: string;
  /** Generate directory instead of compressed tar.gz */
  no_archive?: boolean;
}

export type SupportbundleResult = Record<string, unknown>;

/** Resolve domain via system and proxy DNS and measure lookup latency */
export interface ResolvedomainParams {
  /** Domain name to resolve */
  domain: string;
}

export type ResolvedomainResult = Record<string, unknown>;

/** Dry-run diff and validate pending configuration changes before commit */
export interface ConfigplanParams {
  /** Optional path or serialized UCI content */
  target_config?: string;
}

export type ConfigplanResult = Record<string, unknown>;

/** Validate active or proposed UCI configuration against schema */
export type ConfigvalidateParams = Record<string, never>;

export type ConfigvalidateResult = Record<string, unknown>;

/** Reconcile system state with desired configuration (repair drift) */
export type ReconcileParams = Record<string, never>;

export type ReconcileResult = Record<string, unknown>;

/** Query watchdog escalation level and recovery cooldown */
export type EscalationstatusParams = Record<string, never>;

export type EscalationstatusResult = Record<string, unknown>;

/** Query emergency failsafe mode status */
export type EmergencystatusParams = Record<string, never>;

export type EmergencystatusResult = Record<string, unknown>;

/** Clear emergency failsafe lock and restore normal routing */
export type EmergencyresetParams = Record<string, never>;

export type EmergencyresetResult = Record<string, unknown>;

/** Inspect active nftables ruleset and table counters */
export type ChecknftrulesParams = Record<string, never>;

export type ChecknftrulesResult = Record<string, unknown>;

/** Verify sing-box FakeIP allocation and DNS pool health */
export type CheckfakeipParams = Record<string, never>;

export type CheckfakeipResult = Record<string, unknown>;

/** Check if configured upstream DNS servers are responding */
export interface CheckdnsavailableParams {
  /** Specific DNS server address to test */
  dns_server?: string;
}

export type CheckdnsavailableResult = Record<string, unknown>;

/** Detect real public IP vs proxy egress IP */
export type CheckipleakParams = Record<string, never>;

export type CheckipleakResult = Record<string, unknown>;

/** Perform DNS leak test via bash.ws resolver probe */
export type CheckdnsleakParams = Record<string, never>;

export type CheckdnsleakResult = Record<string, unknown>;

/** Trigger asynchronous update of geoip/geosite domain lists */
export type ListupdateasyncParams = Record<string, never>;

export type ListupdateasyncResult = Record<string, unknown>;

/** Trigger asynchronous fetch and parse of remote subscription */
export interface SubscriptionupdateasyncParams {
  /** UCI section name of subscription */
  section: string;
}

export type SubscriptionupdateasyncResult = Record<string, unknown>;

/** Start asynchronous DNS upstream latency and consistency benchmark */
export type DnsbenchmarkasyncParams = Record<string, never>;

export type DnsbenchmarkasyncResult = Record<string, unknown>;

/** Query status and intermediate results of DNS benchmark */
export type DnsbenchmarkstatusParams = Record<string, never>;

export type DnsbenchmarkstatusResult = Record<string, unknown>;

/** Launch DPI strategy fuzzer probe against target domains */
export interface FuzzerstartParams {
  /** Target domain or URL to fuzz */
  target_url?: string;
}

export type FuzzerstartResult = Record<string, unknown>;

/** Check current state and working DPI bypass strategies from fuzzer */
export type FuzzerstatusParams = Record<string, never>;

export type FuzzerstatusResult = Record<string, unknown>;

/** List configuration and system restore snapshots */
export type SnapshotlistParams = Record<string, never>;

export type SnapshotlistResult = Record<string, unknown>[];

/** Save current router state to a named snapshot */
export interface SnapshotsaveParams {
  /** Name or tag of the snapshot */
  name: string;
}

export type SnapshotsaveResult = Record<string, unknown>;

/** Restore router state from a named snapshot */
export interface SnapshotrestoreParams {
  /** Name or tag of the snapshot to restore */
  name: string;
}

export type SnapshotrestoreResult = Record<string, unknown>;

export interface TachyonRpcRegistry {
  'get_status': {
    params: GetstatusParams;
    result: GetstatusResult;
  };
  'get_sing_box_status': {
    params: GetsingboxstatusParams;
    result: GetsingboxstatusResult;
  };
  'get_engine_status': {
    params: GetenginestatusParams;
    result: GetenginestatusResult;
  };
  'get_ui_capabilities': {
    params: GetuicapabilitiesParams;
    result: GetuicapabilitiesResult;
  };
  'get_ui_state': {
    params: GetuistateParams;
    result: GetuistateResult;
  };
  'service_action_async': {
    params: ServiceactionasyncParams;
    result: ServiceactionasyncResult;
  };
  'service_action_status': {
    params: ServiceactionstatusParams;
    result: ServiceactionstatusResult;
  };
  'clash_api': {
    params: ClashapiParams;
    result: ClashapiResult;
  };
  'job_list': {
    params: JoblistParams;
    result: JoblistResult;
  };
  'job_query': {
    params: JobqueryParams;
    result: JobqueryResult;
  };
  'job_cancel': {
    params: JobcancelParams;
    result: JobcancelResult;
  };
  'job_request_cancel': {
    params: JobrequestcancelParams;
    result: JobrequestcancelResult;
  };
  'job_gc': {
    params: JobgcParams;
    result: JobgcResult;
  };
  'event_query': {
    params: EventqueryParams;
    result: EventqueryResult;
  };
  'event_tail': {
    params: EventtailParams;
    result: EventtailResult;
  };
  'event_stats': {
    params: EventstatsParams;
    result: EventstatsResult;
  };
  'event_clear': {
    params: EventclearParams;
    result: EventclearResult;
  };
  'event_record': {
    params: EventrecordParams;
    result: EventrecordResult;
  };
  'known_good': {
    params: KnowngoodParams;
    result: KnowngoodResult;
  };
  'known_good_promote': {
    params: KnowngoodpromoteParams;
    result: KnowngoodpromoteResult;
  };
  'known_good_restore': {
    params: KnowngoodrestoreParams;
    result: KnowngoodrestoreResult;
  };
  'known_good_check': {
    params: KnowngoodcheckParams;
    result: KnowngoodcheckResult;
  };
  'route_explain': {
    params: RouteexplainParams;
    result: RouteexplainResult;
  };
  'support_bundle': {
    params: SupportbundleParams;
    result: SupportbundleResult;
  };
  'resolve_domain': {
    params: ResolvedomainParams;
    result: ResolvedomainResult;
  };
  'config_plan': {
    params: ConfigplanParams;
    result: ConfigplanResult;
  };
  'config_validate': {
    params: ConfigvalidateParams;
    result: ConfigvalidateResult;
  };
  'reconcile': {
    params: ReconcileParams;
    result: ReconcileResult;
  };
  'escalation_status': {
    params: EscalationstatusParams;
    result: EscalationstatusResult;
  };
  'emergency_status': {
    params: EmergencystatusParams;
    result: EmergencystatusResult;
  };
  'emergency_reset': {
    params: EmergencyresetParams;
    result: EmergencyresetResult;
  };
  'check_nft_rules': {
    params: ChecknftrulesParams;
    result: ChecknftrulesResult;
  };
  'check_fakeip': {
    params: CheckfakeipParams;
    result: CheckfakeipResult;
  };
  'check_dns_available': {
    params: CheckdnsavailableParams;
    result: CheckdnsavailableResult;
  };
  'check_ip_leak': {
    params: CheckipleakParams;
    result: CheckipleakResult;
  };
  'check_dns_leak': {
    params: CheckdnsleakParams;
    result: CheckdnsleakResult;
  };
  'list_update_async': {
    params: ListupdateasyncParams;
    result: ListupdateasyncResult;
  };
  'subscription_update_async': {
    params: SubscriptionupdateasyncParams;
    result: SubscriptionupdateasyncResult;
  };
  'dns_benchmark_async': {
    params: DnsbenchmarkasyncParams;
    result: DnsbenchmarkasyncResult;
  };
  'dns_benchmark_status': {
    params: DnsbenchmarkstatusParams;
    result: DnsbenchmarkstatusResult;
  };
  'fuzzer_start': {
    params: FuzzerstartParams;
    result: FuzzerstartResult;
  };
  'fuzzer_status': {
    params: FuzzerstatusParams;
    result: FuzzerstatusResult;
  };
  'snapshot_list': {
    params: SnapshotlistParams;
    result: SnapshotlistResult;
  };
  'snapshot_save': {
    params: SnapshotsaveParams;
    result: SnapshotsaveResult;
  };
  'snapshot_restore': {
    params: SnapshotrestoreParams;
    result: SnapshotrestoreResult;
  };
}

export const RPC_METADATA_MAP: Record<TachyonRpcMethodName, RpcMethodMetadata> = {
  'get_status': {
    name: 'get_status',
    cli_command: 'get_status',
    category: 'system',
    acl: 'read',
    description: "Get current Tachyon daemon status and operational metrics",
    async: false,
    timeout_ms: 5000,
    params: [],
  },
  'get_sing_box_status': {
    name: 'get_sing_box_status',
    cli_command: 'get_sing_box_status',
    category: 'engine',
    acl: 'read',
    description: "Get sing-box process status and runtime flags",
    async: false,
    timeout_ms: 5000,
    params: [],
  },
  'get_engine_status': {
    name: 'get_engine_status',
    cli_command: 'get_engine_status',
    category: 'engine',
    acl: 'read',
    description: "Get active bypass engine status (sing-box or steer)",
    async: false,
    timeout_ms: 5000,
    params: [],
  },
  'get_ui_capabilities': {
    name: 'get_ui_capabilities',
    cli_command: 'get_ui_capabilities',
    category: 'system',
    acl: 'read',
    description: "Query hardware and software capabilities supported on this router",
    async: false,
    timeout_ms: 5000,
    params: [],
  },
  'get_ui_state': {
    name: 'get_ui_state',
    cli_command: 'get_ui_state',
    category: 'system',
    acl: 'read',
    description: "Atomic composite snapshot of services, capabilities, and active jobs for UI",
    async: false,
    timeout_ms: 10000,
    params: [],
  },
  'service_action_async': {
    name: 'service_action_async',
    cli_command: 'service_action_async',
    category: 'system',
    acl: 'write',
    description: "Initiate async lifecycle action (start, stop, restart, reload)",
    async: true,
    timeout_ms: 10000,
    params: [{"name":"action","type":"string","required":true,"enum":["start","stop","restart","reload","reload_firewall"],"description":"Lifecycle action to trigger"}],
  },
  'service_action_status': {
    name: 'service_action_status',
    cli_command: 'service_action_status',
    category: 'system',
    acl: 'read',
    description: "Poll status of an async lifecycle action",
    async: false,
    timeout_ms: 5000,
    params: [{"name":"job_id","type":"string","required":true,"description":"Job ID returned by service_action_async"}],
  },
  'clash_api': {
    name: 'clash_api',
    cli_command: 'clash_api',
    category: 'engine',
    acl: 'read',
    description: "Query or mutate the sing-box / clash REST API interface",
    async: false,
    timeout_ms: 15000,
    params: [{"name":"endpoint","type":"string","required":true,"description":"Clash API endpoint path or action"},{"name":"arg1","type":"string","required":false,"description":"First argument (e.g. proxy or group name)"},{"name":"arg2","type":"string","required":false,"description":"Second argument (e.g. selected node name or test URL)"},{"name":"arg3","type":"string","required":false,"description":"Third argument (e.g. timeout in ms)"}],
  },
  'job_list': {
    name: 'job_list',
    cli_command: 'job_list',
    category: 'jobs',
    acl: 'read',
    description: "List background jobs with status, progress, and cancellation metadata",
    async: false,
    timeout_ms: 10000,
    params: [{"name":"all","type":"boolean","required":false,"default":false,"description":"Include completed and terminal jobs"}],
  },
  'job_query': {
    name: 'job_query',
    cli_command: 'job_query',
    category: 'jobs',
    acl: 'read',
    description: "Query specific background job by ID",
    async: false,
    timeout_ms: 5000,
    params: [{"name":"job_id","type":"string","required":true,"description":"Unique job identifier"}],
  },
  'job_cancel': {
    name: 'job_cancel',
    cli_command: 'job_cancel',
    category: 'jobs',
    acl: 'write',
    description: "Cancel background job (cooperative with safe rollback, or forced kill)",
    async: false,
    timeout_ms: 10000,
    params: [{"name":"job_id","type":"string","required":true,"description":"Job ID to cancel"},{"name":"force","type":"boolean","required":false,"default":false,"description":"Immediately terminate worker process with SIGKILL"},{"name":"reason","type":"string","required":false,"description":"Cancellation rationale"}],
  },
  'job_request_cancel': {
    name: 'job_request_cancel',
    cli_command: 'job_request_cancel',
    category: 'jobs',
    acl: 'write',
    description: "Request graceful cooperative cancellation of a background job",
    async: false,
    timeout_ms: 5000,
    params: [{"name":"job_id","type":"string","required":true,"description":"Job ID"},{"name":"reason","type":"string","required":false,"description":"Cancellation reason"}],
  },
  'job_gc': {
    name: 'job_gc',
    cli_command: 'job_gc',
    category: 'jobs',
    acl: 'admin',
    description: "Garbage collect stale and completed jobs from disk",
    async: false,
    timeout_ms: 10000,
    params: [],
  },
  'event_query': {
    name: 'event_query',
    cli_command: 'event_query',
    category: 'events',
    acl: 'read',
    description: "Query event journal entries matching criteria",
    async: false,
    timeout_ms: 10000,
    params: [{"name":"filter","type":"object","required":false,"description":"Filter criteria (event, severity, source, job_id, since_ts, limit)"}],
  },
  'event_tail': {
    name: 'event_tail',
    cli_command: 'event_tail',
    category: 'events',
    acl: 'read',
    description: "Retrieve the most recent N entries from the event journal",
    async: false,
    timeout_ms: 5000,
    params: [{"name":"count","type":"number","required":false,"default":10,"description":"Number of recent entries to fetch"}],
  },
  'event_stats': {
    name: 'event_stats',
    cli_command: 'event_stats',
    category: 'events',
    acl: 'read',
    description: "Get event journal storage metrics and capacity",
    async: false,
    timeout_ms: 5000,
    params: [],
  },
  'event_clear': {
    name: 'event_clear',
    cli_command: 'event_clear',
    category: 'events',
    acl: 'admin',
    description: "Clear all entries in the event journal",
    async: false,
    timeout_ms: 5000,
    params: [],
  },
  'event_record': {
    name: 'event_record',
    cli_command: 'event_record',
    category: 'events',
    acl: 'write',
    description: "Record an event to the persistent event journal",
    async: false,
    timeout_ms: 5000,
    params: [{"name":"event","type":"string","required":true,"description":"Event identifier name"},{"name":"data","type":"object","required":false,"description":"Event payload data"},{"name":"severity","type":"string","required":false,"enum":["debug","info","warn","error","fatal"],"default":"info","description":"Severity level"},{"name":"source","type":"string","required":false,"default":"tachyon","description":"Originating subsystem"},{"name":"message","type":"string","required":false,"description":"Human-readable message"}],
  },
  'known_good': {
    name: 'known_good',
    cli_command: 'known_good',
    category: 'known_good',
    acl: 'read',
    description: "Query Last Known Good status, active observation window, and manifests",
    async: false,
    timeout_ms: 5000,
    params: [{"name":"json","type":"boolean","required":false,"default":true,"description":"Output JSON format"}],
  },
  'known_good_promote': {
    name: 'known_good_promote',
    cli_command: 'known_good_promote',
    category: 'known_good',
    acl: 'admin',
    description: "Promote current running configuration to Last Known Good state",
    async: false,
    timeout_ms: 10000,
    params: [{"name":"reason","type":"string","required":false,"description":"Promotion rationale"}],
  },
  'known_good_restore': {
    name: 'known_good_restore',
    cli_command: 'known_good_restore',
    category: 'known_good',
    acl: 'admin',
    description: "Rollback active configuration to Last Known Good state",
    async: false,
    timeout_ms: 15000,
    params: [{"name":"reason","type":"string","required":false,"description":"Rollback reason"}],
  },
  'known_good_check': {
    name: 'known_good_check',
    cli_command: 'known_good_check',
    category: 'known_good',
    acl: 'read',
    description: "Probe health metrics during observation window and auto-promote if elapsed",
    async: false,
    timeout_ms: 5000,
    params: [],
  },
  'route_explain': {
    name: 'route_explain',
    cli_command: 'route_explain',
    category: 'diagnostics',
    acl: 'diagnostic',
    description: "End-to-end tracing and explanation of routing, DNS, nftables, and outbound decisions",
    async: false,
    timeout_ms: 10000,
    params: [{"name":"client","type":"string","required":true,"description":"Client IP address or CIDR"},{"name":"target","type":"string","required":true,"description":"Destination domain or IP"},{"name":"port","type":"number","required":false,"default":443,"description":"Destination port"},{"name":"proto","type":"string","required":false,"enum":["tcp","udp"],"default":"tcp","description":"L4 transport protocol"}],
  },
  'support_bundle': {
    name: 'support_bundle',
    cli_command: 'support_bundle',
    category: 'diagnostics',
    acl: 'admin',
    description: "Generate sanitized diagnostic support bundle archive without secrets",
    async: false,
    timeout_ms: 30000,
    params: [{"name":"path","type":"string","required":false,"description":"Target destination path"},{"name":"no_archive","type":"boolean","required":false,"default":false,"description":"Generate directory instead of compressed tar.gz"}],
  },
  'resolve_domain': {
    name: 'resolve_domain',
    cli_command: 'resolve_domain',
    category: 'diagnostics',
    acl: 'diagnostic',
    description: "Resolve domain via system and proxy DNS and measure lookup latency",
    async: false,
    timeout_ms: 10000,
    params: [{"name":"domain","type":"string","required":true,"description":"Domain name to resolve"}],
  },
  'config_plan': {
    name: 'config_plan',
    cli_command: 'config_plan',
    category: 'system',
    acl: 'write',
    description: "Dry-run diff and validate pending configuration changes before commit",
    async: false,
    timeout_ms: 10000,
    params: [{"name":"target_config","type":"string","required":false,"description":"Optional path or serialized UCI content"}],
  },
  'config_validate': {
    name: 'config_validate',
    cli_command: 'config_validate',
    category: 'system',
    acl: 'read',
    description: "Validate active or proposed UCI configuration against schema",
    async: false,
    timeout_ms: 5000,
    params: [],
  },
  'reconcile': {
    name: 'reconcile',
    cli_command: 'reconcile',
    category: 'system',
    acl: 'admin',
    description: "Reconcile system state with desired configuration (repair drift)",
    async: false,
    timeout_ms: 15000,
    params: [],
  },
  'escalation_status': {
    name: 'escalation_status',
    cli_command: 'escalation_status',
    category: 'system',
    acl: 'read',
    description: "Query watchdog escalation level and recovery cooldown",
    async: false,
    timeout_ms: 5000,
    params: [],
  },
  'emergency_status': {
    name: 'emergency_status',
    cli_command: 'emergency_status',
    category: 'system',
    acl: 'read',
    description: "Query emergency failsafe mode status",
    async: false,
    timeout_ms: 5000,
    params: [],
  },
  'emergency_reset': {
    name: 'emergency_reset',
    cli_command: 'emergency_reset',
    category: 'system',
    acl: 'admin',
    description: "Clear emergency failsafe lock and restore normal routing",
    async: false,
    timeout_ms: 10000,
    params: [],
  },
  'check_nft_rules': {
    name: 'check_nft_rules',
    cli_command: 'check_nft_rules',
    category: 'diagnostics',
    acl: 'diagnostic',
    description: "Inspect active nftables ruleset and table counters",
    async: false,
    timeout_ms: 5000,
    params: [],
  },
  'check_fakeip': {
    name: 'check_fakeip',
    cli_command: 'check_fakeip',
    category: 'diagnostics',
    acl: 'diagnostic',
    description: "Verify sing-box FakeIP allocation and DNS pool health",
    async: false,
    timeout_ms: 5000,
    params: [],
  },
  'check_dns_available': {
    name: 'check_dns_available',
    cli_command: 'check_dns_available',
    category: 'diagnostics',
    acl: 'diagnostic',
    description: "Check if configured upstream DNS servers are responding",
    async: false,
    timeout_ms: 8000,
    params: [{"name":"dns_server","type":"string","required":false,"description":"Specific DNS server address to test"}],
  },
  'check_ip_leak': {
    name: 'check_ip_leak',
    cli_command: 'check_ip_leak',
    category: 'diagnostics',
    acl: 'diagnostic',
    description: "Detect real public IP vs proxy egress IP",
    async: false,
    timeout_ms: 15000,
    params: [],
  },
  'check_dns_leak': {
    name: 'check_dns_leak',
    cli_command: 'check_dns_leak',
    category: 'diagnostics',
    acl: 'diagnostic',
    description: "Perform DNS leak test via bash.ws resolver probe",
    async: false,
    timeout_ms: 15000,
    params: [],
  },
  'list_update_async': {
    name: 'list_update_async',
    cli_command: 'list_update_async',
    category: 'updates',
    acl: 'write',
    description: "Trigger asynchronous update of geoip/geosite domain lists",
    async: true,
    timeout_ms: 10000,
    params: [],
  },
  'subscription_update_async': {
    name: 'subscription_update_async',
    cli_command: 'subscription_update_async',
    category: 'updates',
    acl: 'write',
    description: "Trigger asynchronous fetch and parse of remote subscription",
    async: true,
    timeout_ms: 10000,
    params: [{"name":"section","type":"string","required":true,"description":"UCI section name of subscription"}],
  },
  'dns_benchmark_async': {
    name: 'dns_benchmark_async',
    cli_command: 'dns_benchmark_async',
    category: 'dns',
    acl: 'write',
    description: "Start asynchronous DNS upstream latency and consistency benchmark",
    async: true,
    timeout_ms: 10000,
    params: [],
  },
  'dns_benchmark_status': {
    name: 'dns_benchmark_status',
    cli_command: 'dns_benchmark_status',
    category: 'dns',
    acl: 'read',
    description: "Query status and intermediate results of DNS benchmark",
    async: false,
    timeout_ms: 5000,
    params: [],
  },
  'fuzzer_start': {
    name: 'fuzzer_start',
    cli_command: 'fuzzer_start',
    category: 'fuzzer',
    acl: 'write',
    description: "Launch DPI strategy fuzzer probe against target domains",
    async: true,
    timeout_ms: 10000,
    params: [{"name":"target_url","type":"string","required":false,"description":"Target domain or URL to fuzz"}],
  },
  'fuzzer_status': {
    name: 'fuzzer_status',
    cli_command: 'fuzzer_status',
    category: 'fuzzer',
    acl: 'read',
    description: "Check current state and working DPI bypass strategies from fuzzer",
    async: false,
    timeout_ms: 5000,
    params: [],
  },
  'snapshot_list': {
    name: 'snapshot_list',
    cli_command: 'snapshot_list',
    category: 'snapshots',
    acl: 'read',
    description: "List configuration and system restore snapshots",
    async: false,
    timeout_ms: 5000,
    params: [],
  },
  'snapshot_save': {
    name: 'snapshot_save',
    cli_command: 'snapshot_save',
    category: 'snapshots',
    acl: 'admin',
    description: "Save current router state to a named snapshot",
    async: false,
    timeout_ms: 10000,
    params: [{"name":"name","type":"string","required":true,"description":"Name or tag of the snapshot"}],
  },
  'snapshot_restore': {
    name: 'snapshot_restore',
    cli_command: 'snapshot_restore',
    category: 'snapshots',
    acl: 'admin',
    description: "Restore router state from a named snapshot",
    async: false,
    timeout_ms: 15000,
    params: [{"name":"name","type":"string","required":true,"description":"Name or tag of the snapshot to restore"}],
  },
};

export interface ValidationResult {
  valid: boolean;
  errors: string[];
}

export function validateRpcParams<M extends TachyonRpcMethodName>(
  method: M,
  params: unknown = {},
): ValidationResult {
  const meta = RPC_METADATA_MAP[method];
  if (!meta) {
    return { valid: false, errors: [`Unknown RPC method '${method}'`] };
  }

  const errors: string[] = [];
  const pObj = (params && typeof params === 'object') ? (params as Record<string, unknown>) : {};

  for (const p of meta.params) {
    const val = pObj[p.name];
    if (p.required && (val === undefined || val === null || val === "")) {
      errors.push(`Missing required parameter '${p.name}' for RPC '${method}'`);
      continue;
    }
    if (val !== undefined && val !== null) {
      if (p.type === "string" && typeof val !== "string") {
        errors.push(`Parameter '${p.name}' must be a string, got ${typeof val}`);
      } else if (p.type === "number" && typeof val !== "number") {
        errors.push(`Parameter '${p.name}' must be a number, got ${typeof val}`);
      } else if (p.type === "boolean" && typeof val !== "boolean") {
        errors.push(`Parameter '${p.name}' must be a boolean, got ${typeof val}`);
      } else if (p.type === "array" && !Array.isArray(val)) {
        errors.push(`Parameter '${p.name}' must be an array`);
      } else if (p.type === "object" && (typeof val !== "object" || Array.isArray(val))) {
        errors.push(`Parameter '${p.name}' must be an object`);
      }
      if (p.enum && typeof val === "string" && !p.enum.includes(val)) {
        errors.push(`Parameter '${p.name}' value '${val}' is not in allowed enum: ${p.enum.join(', ')}`);
      }
    }
  }

  return { valid: errors.length === 0, errors };
}

export function serializeRpcCliArgs<M extends TachyonRpcMethodName>(
  method: M,
  params: TachyonRpcRegistry[M]['params'],
): string[] {
  const meta = RPC_METADATA_MAP[method];
  if (!meta) return [];

  const args: string[] = [meta.cli_command];
  const p = params as Record<string, unknown>;

  for (const desc of meta.params) {
    const val = p[desc.name];
    if (val === undefined || val === null) {
      continue;
    }
    if (desc.type === "boolean") {
      if (val === true) {
        args.push(`--${desc.name}`);
      }
    } else if (desc.type === "object") {
      args.push(JSON.stringify(val));
    } else {
      args.push(String(val));
    }
  }

  return args;
}
