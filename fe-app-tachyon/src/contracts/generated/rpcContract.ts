/**
 * AUTO-GENERATED FILE — DO NOT EDIT DIRECTLY
 * Generated from contracts/tachyon-rpc.json via tools/generate_rpc_contract.js
 * Contract version: 2.0.0
 */

export type RpcAclLevel = 'read' | 'write' | 'admin' | 'diagnostic';
export type RpcCategory =
  | 'ai'
  | 'diagnostics'
  | 'fuzzer'
  | 'known_good'
  | 'stability'
  | 'system'
  | 'telegram'
  | 'updates';

export const TACHYON_RPC_METHODS = [
  'agent_cgi',
  'ai_doctor',
  'ai_doctor_last',
  'ai_heal',
  'ai_status',
  'ai_status_full',
  'apply_quick_fix',
  'check_byedpi_runtime',
  'check_dns_available',
  'check_dns_leak',
  'check_fakeip',
  'check_inbounds',
  'check_inbounds_config',
  'check_ip_leak',
  'check_logs',
  'check_nft',
  'check_nft_rules',
  'check_proxy',
  'check_sing_box',
  'check_sing_box_logs',
  'check_steer',
  'check_tor_runtime',
  'check_zapret2_runtime',
  'check_zapret_runtime',
  'clash_api',
  'component_action',
  'component_action_async',
  'component_action_log',
  'component_action_status',
  'component_auto_update_apply',
  'component_install_version',
  'component_list_releases',
  'component_update_check_cache',
  'component_updates_if_due',
  'config-plan',
  'config-validate',
  'config_plan',
  'config_validate',
  'delete_section',
  'diagnose_json',
  'disable',
  'dns_autotune',
  'dns_benchmark',
  'dns_benchmark_apply',
  'dns_benchmark_async',
  'dns_benchmark_status',
  'dns_benchmark_stop',
  'dns_failover_apply',
  'dns_speed_test_start',
  'dns_speed_test_status',
  'dnsmasq_restore',
  'doctor',
  'emergency_reset',
  'emergency_status',
  'emergency_trigger',
  'enable',
  'engine_apply',
  'engine_diag',
  'engine_explain',
  'engine_features',
  'engine_generate',
  'engine_info',
  'engine_plan',
  'engine_reload',
  'engine_start',
  'engine_status',
  'engine_stop',
  'engine_switch',
  'engine_switch_back',
  'escalation_status',
  'event-clear',
  'event-query',
  'event-record',
  'event-stats',
  'event-tail',
  'event_clear',
  'event_query',
  'event_record',
  'event_stats',
  'event_tail',
  'extract_ruleset',
  'failover_check',
  'fuzzer_ai_synthesize',
  'fuzzer_apply',
  'fuzzer_auto_apply',
  'fuzzer_clear_history',
  'fuzzer_detect_dpi',
  'fuzzer_generate',
  'fuzzer_get_patterns',
  'fuzzer_history',
  'fuzzer_presets_info',
  'fuzzer_reset_patterns',
  'fuzzer_save_patterns',
  'fuzzer_start',
  'fuzzer_status',
  'fuzzer_stop',
  'fuzzer_strategies',
  'fuzzer_update_presets',
  'generate_reality_keypair',
  'generate_warp',
  'get_byedpi_status',
  'get_engine_status',
  'get_fptn_status',
  'get_olcrtc_status',
  'get_outbound_metadata',
  'get_server_capabilities',
  'get_sing_box_status',
  'get_status',
  'get_subscription_metadata',
  'get_system_info',
  'get_tailscale_peers',
  'get_tailscale_status',
  'get_tls_certificate_sha256',
  'get_ui_capabilities',
  'get_ui_state',
  'get_wdtt_status',
  'get_zapret2_status',
  'get_zapret_status',
  'global_check',
  'hosts_list_status',
  'hosts_list_update',
  'import-settings',
  'import_settings',
  'install_tor',
  'job-cancel',
  'job-gc',
  'job-list',
  'job-query',
  'job-request-cancel',
  'job_cancel',
  'job_gc',
  'job_list',
  'job_query',
  'job_request_cancel',
  'known-good',
  'known-good-check',
  'known-good-promote',
  'known-good-restore',
  'known-good-rollback',
  'known-good-status',
  'known_good',
  'known_good_check',
  'known_good_promote',
  'known_good_restore',
  'known_good_rollback',
  'known_good_status',
  'lan_clients',
  'latency_test_async',
  'latency_test_status',
  'leak_check',
  'leak_check_async',
  'leak_check_status',
  'list_update',
  'list_update_async',
  'list_update_if_due',
  'list_update_status',
  'luci_postinst',
  'main',
  'mcp',
  'neutralize_zapret_defaults',
  'package_postinst',
  'package_prerm',
  'parental_quota_reset',
  'parental_quota_tick',
  'reconcile',
  'reconcile_plan',
  'reconcile_status',
  'reload',
  'reload_firewall',
  'reset_settings',
  'resolve-domain',
  'resolve_domain',
  'restart',
  'restore_dnsmasq',
  'route-explain',
  'route_explain',
  'server-best',
  'server-probe',
  'server-probe-all',
  'server-query',
  'server-stats',
  'server-stats-reset',
  'server_best',
  'server_probe',
  'server_probe_all',
  'server_query',
  'server_stats',
  'server_stats_reset',
  'service_action_async',
  'service_action_status',
  'service_health_check',
  'show_config',
  'show_sing_box_config',
  'show_sing_box_version',
  'show_version',
  'snapshot_delete',
  'snapshot_list',
  'snapshot_restore',
  'snapshot_save',
  'stability-report',
  'stability-status',
  'stability_report',
  'stability_status',
  'start',
  'stop',
  'subscription_update',
  'subscription_update_async',
  'subscription_update_if_due',
  'subscription_update_status',
  'support-bundle',
  'support_bundle',
  'tailscale_restart',
  'telegram',
  'telegram_diagnose',
  'telegram_start',
  'telegram_status',
  'telegram_stop',
  'toggle_client_bypass',
  'ui_action_ack',
  'uninstall',
  'validate_byedpi_strategy_json',
  'validate_nfqws2_strategy_json',
  'validate_nfqws_strategy_json',
  'watchdog',
  'watchdog_start',
  'watchdog_stop',
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

/** __cgi (service/agent_api.uc) */
export type AgentcgiParams = Record<string, never>;

export type AgentcgiResult = Record<string, unknown>;

/** ai-doctor (diagnostics/runtime.uc) */
export interface AidoctorParams {
  /** positional argument 1 of ai_doctor */
  arg1?: string;
}

export type AidoctorResult = Record<string, unknown>;

/** ai-doctor-last (diagnostics/runtime.uc) */
export type AidoctorlastParams = Record<string, never>;

export type AidoctorlastResult = Record<string, unknown>;

/** ai-heal (service/watchdog.uc) */
export type AihealParams = Record<string, never>;

export type AihealResult = Record<string, unknown>;

/** ai-status (service/watchdog.uc) */
export type AistatusParams = Record<string, never>;

export type AistatusResult = Record<string, unknown>;

/** ai-status-full (service/watchdog.uc) */
export type AistatusfullParams = Record<string, never>;

export type AistatusfullResult = Record<string, unknown>;

/** apply-quick-fix (diagnostics/runtime.uc) */
export interface ApplyquickfixParams {
  /** positional argument 1 of apply_quick_fix */
  arg1?: string;
}

export type ApplyquickfixResult = Record<string, unknown>;

/** check-byedpi-runtime (diagnostics/runtime.uc) */
export type CheckbyedpiruntimeParams = Record<string, never>;

export type CheckbyedpiruntimeResult = Record<string, unknown>;

/** check-dns-available (diagnostics/runtime.uc) */
export type CheckdnsavailableParams = Record<string, never>;

export type CheckdnsavailableResult = Record<string, unknown>;

/** dns-leak (diagnostics/leak_check.uc) */
export type CheckdnsleakParams = Record<string, never>;

export type CheckdnsleakResult = Record<string, unknown>;

/** check-fakeip (diagnostics/runtime.uc) */
export type CheckfakeipParams = Record<string, never>;

export type CheckfakeipResult = Record<string, unknown>;

/** check-inbounds (diagnostics/runtime.uc) */
export type CheckinboundsParams = Record<string, never>;

export type CheckinboundsResult = Record<string, unknown>;

/** check-inbounds-config (diagnostics/runtime.uc) */
export type CheckinboundsconfigParams = Record<string, never>;

export type CheckinboundsconfigResult = Record<string, unknown>;

/** ip-leak (diagnostics/leak_check.uc) */
export type CheckipleakParams = Record<string, never>;

export type CheckipleakResult = Record<string, unknown>;

/** check-logs (diagnostics/runtime.uc) */
export type ChecklogsParams = Record<string, never>;

export type ChecklogsResult = Record<string, unknown>;

/** check-nft (diagnostics/runtime.uc) */
export type ChecknftParams = Record<string, never>;

export type ChecknftResult = Record<string, unknown>;

/** check-nft-rules (diagnostics/runtime.uc) */
export type ChecknftrulesParams = Record<string, never>;

export type ChecknftrulesResult = Record<string, unknown>;

/** check-proxy (diagnostics/runtime.uc) */
export type CheckproxyParams = Record<string, never>;

export type CheckproxyResult = Record<string, unknown>;

/** check-sing-box (diagnostics/runtime.uc) */
export type ChecksingboxParams = Record<string, never>;

export type ChecksingboxResult = Record<string, unknown>;

/** check-sing-box-logs (diagnostics/runtime.uc) */
export type ChecksingboxlogsParams = Record<string, never>;

export type ChecksingboxlogsResult = Record<string, unknown>;

/** check-steer (diagnostics/runtime.uc) */
export type ChecksteerParams = Record<string, never>;

export type ChecksteerResult = Record<string, unknown>;

/** check-tor-runtime (diagnostics/runtime.uc) */
export type ChecktorruntimeParams = Record<string, never>;

export type ChecktorruntimeResult = Record<string, unknown>;

/** check-zapret2-runtime (diagnostics/runtime.uc) */
export type Checkzapret2runtimeParams = Record<string, never>;

export type Checkzapret2runtimeResult = Record<string, unknown>;

/** check-zapret-runtime (diagnostics/runtime.uc) */
export type CheckzapretruntimeParams = Record<string, never>;

export type CheckzapretruntimeResult = Record<string, unknown>;

/** clash-api (diagnostics/runtime.uc) */
export interface ClashapiParams {
  /** positional argument 1 of clash_api */
  arg1?: string;
  /** positional argument 2 of clash_api */
  arg2?: string;
  /** positional argument 3 of clash_api */
  arg3?: string;
  /** positional argument 4 of clash_api */
  arg4?: string;
}

export type ClashapiResult = Record<string, unknown>;

/** component-action (components/action.uc) */
export interface ComponentactionParams {
  /** positional argument 1 of component_action */
  arg1?: string;
  /** positional argument 2 of component_action */
  arg2?: string;
}

export type ComponentactionResult = Record<string, unknown>;

/** component-action-async (components/updates.uc) */
export interface ComponentactionasyncParams {
  /** positional argument 1 of component_action_async */
  arg1?: string;
  /** positional argument 2 of component_action_async */
  arg2?: string;
}

export type ComponentactionasyncResult = Record<string, unknown>;

/** component-action-log (components/updates.uc) */
export interface ComponentactionlogParams {
  /** positional argument 1 of component_action_log */
  arg1?: string;
  /** positional argument 2 of component_action_log */
  arg2?: string;
}

export type ComponentactionlogResult = Record<string, unknown>;

/** component-action-status (components/updates.uc) */
export interface ComponentactionstatusParams {
  /** positional argument 1 of component_action_status */
  arg1?: string;
}

export type ComponentactionstatusResult = Record<string, unknown>;

/** component-auto-update-apply (components/updates.uc) */
export type ComponentautoupdateapplyParams = Record<string, never>;

export type ComponentautoupdateapplyResult = Record<string, unknown>;

/** install-component-version (components/action.uc) */
export interface ComponentinstallversionParams {
  /** positional argument 1 of component_install_version */
  arg1?: string;
  /** positional argument 2 of component_install_version */
  arg2?: string;
}

export type ComponentinstallversionResult = Record<string, unknown>;

/** list-component-releases (components/action.uc) */
export interface ComponentlistreleasesParams {
  /** positional argument 1 of component_list_releases */
  arg1?: string;
  /** positional argument 2 of component_list_releases */
  arg2?: string;
}

export type ComponentlistreleasesResult = Record<string, unknown>;

/** component-update-check-cache (components/updates.uc) */
export type ComponentupdatecheckcacheParams = Record<string, never>;

export type ComponentupdatecheckcacheResult = Record<string, unknown>;

/** component-updates-if-due (components/updates.uc) */
export type ComponentupdatesifdueParams = Record<string, never>;

export type ComponentupdatesifdueResult = Record<string, unknown>;

/** plan (service/config_plan.uc) */
export interface ConfigPlanParams {
  /** positional argument 1 of config-plan */
  arg1?: string;
  /** positional argument 2 of config-plan */
  arg2?: string;
}

export type ConfigPlanResult = Record<string, unknown>;

/** validate (service/config_plan.uc) */
export interface ConfigValidateParams {
  /** positional argument 1 of config-validate */
  arg1?: string;
}

export type ConfigValidateResult = Record<string, unknown>;

/** plan (service/config_plan.uc) */
export interface ConfigplanParams {
  /** positional argument 1 of config_plan */
  arg1?: string;
  /** positional argument 2 of config_plan */
  arg2?: string;
}

export type ConfigplanResult = Record<string, unknown>;

/** validate (service/config_plan.uc) */
export interface ConfigvalidateParams {
  /** positional argument 1 of config_validate */
  arg1?: string;
}

export type ConfigvalidateResult = Record<string, unknown>;

/** delete-section (config/connections.uc) */
export interface DeletesectionParams {
  /** positional argument 1 of delete_section */
  arg1?: string;
}

export type DeletesectionResult = Record<string, unknown>;

/** diagnose-json (diagnostics/runtime.uc) */
export type DiagnosejsonParams = Record<string, never>;

export type DiagnosejsonResult = Record<string, unknown>;

/** disable (service/lifecycle.uc) */
export type DisableParams = Record<string, never>;

export type DisableResult = Record<string, unknown>;

/** autotune (dns/benchmark.uc) */
export interface DnsautotuneParams {
  /** positional argument 1 of dns_autotune */
  arg1?: string;
}

export type DnsautotuneResult = Record<string, unknown>;

/** benchmark (dns/benchmark.uc) */
export interface DnsbenchmarkParams {
  /** positional argument 1 of dns_benchmark */
  arg1?: string;
}

export type DnsbenchmarkResult = Record<string, unknown>;

/** benchmark_apply (dns/benchmark.uc) */
export type DnsbenchmarkapplyParams = Record<string, never>;

export type DnsbenchmarkapplyResult = Record<string, unknown>;

/** benchmark_async (dns/benchmark.uc) */
export type DnsbenchmarkasyncParams = Record<string, never>;

export type DnsbenchmarkasyncResult = Record<string, unknown>;

/** benchmark_status (dns/benchmark.uc) */
export type DnsbenchmarkstatusParams = Record<string, never>;

export type DnsbenchmarkstatusResult = Record<string, unknown>;

/** benchmark_stop (dns/benchmark.uc) */
export type DnsbenchmarkstopParams = Record<string, never>;

export type DnsbenchmarkstopResult = Record<string, unknown>;

/** dns-failover-apply (service/lifecycle.uc) */
export interface DnsfailoverapplyParams {
  /** positional argument 1 of dns_failover_apply */
  arg1?: string;
}

export type DnsfailoverapplyResult = Record<string, unknown>;

/** start (dns/speed_test.uc) */
export interface DnsspeedteststartParams {
  /** positional argument 1 of dns_speed_test_start */
  arg1?: string;
}

export type DnsspeedteststartResult = Record<string, unknown>;

/** status (dns/speed_test.uc) */
export type DnsspeedteststatusParams = Record<string, never>;

export type DnsspeedteststatusResult = Record<string, unknown>;

/** dnsmasq-restore (service/lifecycle.uc) */
export type DnsmasqrestoreParams = Record<string, never>;

export type DnsmasqrestoreResult = Record<string, unknown>;

/** doctor (diagnostics/runtime.uc) */
export interface DoctorParams {
  /** positional argument 1 of doctor */
  arg1?: string;
}

export type DoctorResult = Record<string, unknown>;

/** emergency-reset (service/watchdog.uc) */
export type EmergencyresetParams = Record<string, never>;

export type EmergencyresetResult = Record<string, unknown>;

/** emergency-status (service/watchdog.uc) */
export type EmergencystatusParams = Record<string, never>;

export type EmergencystatusResult = Record<string, unknown>;

/** emergency-trigger (service/watchdog.uc) */
export interface EmergencytriggerParams {
  /** positional argument 1 of emergency_trigger */
  arg1?: string;
}

export type EmergencytriggerResult = Record<string, unknown>;

/** enable (service/lifecycle.uc) */
export type EnableParams = Record<string, never>;

export type EnableResult = Record<string, unknown>;

/** engine-apply (service/engine_runtime.uc) */
export interface EngineapplyParams {
  /** positional argument 1 of engine_apply */
  arg1?: string;
}

export type EngineapplyResult = Record<string, unknown>;

/** engine-diag (service/engine_runtime.uc) */
export type EnginediagParams = Record<string, never>;

export type EnginediagResult = Record<string, unknown>;

/** engine-explain (service/engine_runtime.uc) */
export interface EngineexplainParams {
  /** positional argument 1 of engine_explain */
  arg1?: string;
}

export type EngineexplainResult = Record<string, unknown>;

/** engine-features (service/engine_runtime.uc) */
export type EnginefeaturesParams = Record<string, never>;

export type EnginefeaturesResult = Record<string, unknown>;

/** engine-generate (service/engine_runtime.uc) */
export interface EnginegenerateParams {
  /** positional argument 1 of engine_generate */
  arg1?: string;
}

export type EnginegenerateResult = Record<string, unknown>;

/** engine-info (service/engine_runtime.uc) */
export type EngineinfoParams = Record<string, never>;

export type EngineinfoResult = Record<string, unknown>;

/** engine-plan (service/engine_runtime.uc) */
export interface EngineplanParams {
  /** positional argument 1 of engine_plan */
  arg1?: string;
}

export type EngineplanResult = Record<string, unknown>;

/** engine-reload (service/engine_runtime.uc) */
export interface EnginereloadParams {
  /** positional argument 1 of engine_reload */
  arg1?: string;
}

export type EnginereloadResult = Record<string, unknown>;

/** engine-start (service/engine_runtime.uc) */
export type EnginestartParams = Record<string, never>;

export type EnginestartResult = Record<string, unknown>;

/** engine-status (service/engine_runtime.uc) */
export type EnginestatusParams = Record<string, never>;

export type EnginestatusResult = Record<string, unknown>;

/** engine-stop (service/engine_runtime.uc) */
export type EnginestopParams = Record<string, never>;

export type EnginestopResult = Record<string, unknown>;

/** engine-switch (service/engine_runtime.uc) */
export interface EngineswitchParams {
  /** positional argument 1 of engine_switch */
  arg1?: string;
  /** positional argument 2 of engine_switch */
  arg2?: string;
  /** positional argument 3 of engine_switch */
  arg3?: string;
}

export type EngineswitchResult = Record<string, unknown>;

/** engine-switch-back (service/engine_runtime.uc) */
export type EngineswitchbackParams = Record<string, never>;

export type EngineswitchbackResult = Record<string, unknown>;

/** escalation-status (service/watchdog.uc) */
export type EscalationstatusParams = Record<string, never>;

export type EscalationstatusResult = Record<string, unknown>;

/** clear (core/events.uc) */
export type EventClearParams = Record<string, never>;

export type EventClearResult = Record<string, unknown>;

/** query (core/events.uc) */
export type EventQueryParams = Record<string, never>;

export type EventQueryResult = Record<string, unknown>;

/** record (core/events.uc) */
export interface EventRecordParams {
  /** positional argument 1 of event-record */
  arg1?: string;
}

export type EventRecordResult = Record<string, unknown>;

/** stats (core/events.uc) */
export type EventStatsParams = Record<string, never>;

export type EventStatsResult = Record<string, unknown>;

/** tail (core/events.uc) */
export type EventTailParams = Record<string, never>;

export type EventTailResult = Record<string, unknown>;

/** clear (core/events.uc) */
export type EventclearParams = Record<string, never>;

export type EventclearResult = Record<string, unknown>;

/** query (core/events.uc) */
export type EventqueryParams = Record<string, never>;

export type EventqueryResult = Record<string, unknown>;

/** record (core/events.uc) */
export interface EventrecordParams {
  /** positional argument 1 of event_record */
  arg1?: string;
}

export type EventrecordResult = Record<string, unknown>;

/** stats (core/events.uc) */
export type EventstatsParams = Record<string, never>;

export type EventstatsResult = Record<string, unknown>;

/** tail (core/events.uc) */
export type EventtailParams = Record<string, never>;

export type EventtailResult = Record<string, unknown>;

/** extract-ruleset (diagnostics/runtime.uc) */
export interface ExtractrulesetParams {
  /** positional argument 1 of extract_ruleset */
  arg1?: string;
}

export type ExtractrulesetResult = Record<string, unknown>;

/** check (service/failover.uc) */
export type FailovercheckParams = Record<string, never>;

export type FailovercheckResult = Record<string, unknown>;

/** ai_synthesize (diagnostics/fuzzer.uc) */
export interface FuzzeraisynthesizeParams {
  /** positional argument 1 of fuzzer_ai_synthesize */
  arg1?: string;
  /** positional argument 2 of fuzzer_ai_synthesize */
  arg2?: string;
  /** positional argument 3 of fuzzer_ai_synthesize */
  arg3?: string;
  /** positional argument 4 of fuzzer_ai_synthesize */
  arg4?: string;
}

export type FuzzeraisynthesizeResult = Record<string, unknown>;

/** apply (diagnostics/fuzzer.uc) */
export interface FuzzerapplyParams {
  /** positional argument 1 of fuzzer_apply */
  arg1?: string;
  /** positional argument 2 of fuzzer_apply */
  arg2?: string;
  /** positional argument 3 of fuzzer_apply */
  arg3?: string;
}

export type FuzzerapplyResult = Record<string, unknown>;

/** auto_apply (diagnostics/fuzzer.uc) */
export interface FuzzerautoapplyParams {
  /** positional argument 1 of fuzzer_auto_apply */
  arg1?: string;
}

export type FuzzerautoapplyResult = Record<string, unknown>;

/** clear_history (diagnostics/fuzzer.uc) */
export type FuzzerclearhistoryParams = Record<string, never>;

export type FuzzerclearhistoryResult = Record<string, unknown>;

/** detect_dpi (diagnostics/fuzzer.uc) */
export interface FuzzerdetectdpiParams {
  /** positional argument 1 of fuzzer_detect_dpi */
  arg1?: string;
  /** positional argument 2 of fuzzer_detect_dpi */
  arg2?: string;
}

export type FuzzerdetectdpiResult = Record<string, unknown>;

/** generate (diagnostics/fuzzer.uc) */
export interface FuzzergenerateParams {
  /** positional argument 1 of fuzzer_generate */
  arg1?: string;
  /** positional argument 2 of fuzzer_generate */
  arg2?: string;
}

export type FuzzergenerateResult = Record<string, unknown>;

/** get_patterns (diagnostics/fuzzer.uc) */
export type FuzzergetpatternsParams = Record<string, never>;

export type FuzzergetpatternsResult = Record<string, unknown>;

/** history (diagnostics/fuzzer.uc) */
export interface FuzzerhistoryParams {
  /** positional argument 1 of fuzzer_history */
  arg1?: string;
}

export type FuzzerhistoryResult = Record<string, unknown>;

/** presets_info (diagnostics/fuzzer.uc) */
export type FuzzerpresetsinfoParams = Record<string, never>;

export type FuzzerpresetsinfoResult = Record<string, unknown>;

/** reset_patterns (diagnostics/fuzzer.uc) */
export type FuzzerresetpatternsParams = Record<string, never>;

export type FuzzerresetpatternsResult = Record<string, unknown>;

/** save_patterns (diagnostics/fuzzer.uc) */
export interface FuzzersavepatternsParams {
  /** positional argument 1 of fuzzer_save_patterns */
  arg1?: string;
}

export type FuzzersavepatternsResult = Record<string, unknown>;

/** start (diagnostics/fuzzer.uc) */
export interface FuzzerstartParams {
  /** positional argument 1 of fuzzer_start */
  arg1?: string;
  /** positional argument 2 of fuzzer_start */
  arg2?: string;
  /** positional argument 3 of fuzzer_start */
  arg3?: string;
  /** positional argument 4 of fuzzer_start */
  arg4?: string;
  /** positional argument 5 of fuzzer_start */
  arg5?: string;
  /** positional argument 6 of fuzzer_start */
  arg6?: string;
  /** positional argument 7 of fuzzer_start */
  arg7?: string;
}

export type FuzzerstartResult = Record<string, unknown>;

/** status (diagnostics/fuzzer.uc) */
export type FuzzerstatusParams = Record<string, never>;

export type FuzzerstatusResult = Record<string, unknown>;

/** stop (diagnostics/fuzzer.uc) */
export type FuzzerstopParams = Record<string, never>;

export type FuzzerstopResult = Record<string, unknown>;

/** strategies (diagnostics/fuzzer.uc) */
export interface FuzzerstrategiesParams {
  /** positional argument 1 of fuzzer_strategies */
  arg1?: string;
}

export type FuzzerstrategiesResult = Record<string, unknown>;

/** update_presets (diagnostics/fuzzer.uc) */
export type FuzzerupdatepresetsParams = Record<string, never>;

export type FuzzerupdatepresetsResult = Record<string, unknown>;

/** generate-reality-keypair (server/service.uc) */
export type GeneraterealitykeypairParams = Record<string, never>;

export type GeneraterealitykeypairResult = Record<string, unknown>;

/**  (service/warp_generator.uc) */
export interface GeneratewarpParams {
  /** positional argument 1 of generate_warp */
  arg1?: string;
  /** positional argument 2 of generate_warp */
  arg2?: string;
}

export type GeneratewarpResult = Record<string, unknown>;

/** get-byedpi-status (diagnostics/runtime.uc) */
export type GetbyedpistatusParams = Record<string, never>;

export type GetbyedpistatusResult = Record<string, unknown>;

/** get-engine-status (diagnostics/runtime.uc) */
export type GetenginestatusParams = Record<string, never>;

export type GetenginestatusResult = Record<string, unknown>;

/** get-fptn-status (diagnostics/runtime.uc) */
export type GetfptnstatusParams = Record<string, never>;

export type GetfptnstatusResult = Record<string, unknown>;

/** get-olcrtc-status (diagnostics/runtime.uc) */
export type GetolcrtcstatusParams = Record<string, never>;

export type GetolcrtcstatusResult = Record<string, unknown>;

/** get-outbound-metadata (diagnostics/runtime.uc) */
export interface GetoutboundmetadataParams {
  /** positional argument 1 of get_outbound_metadata */
  arg1?: string;
}

export type GetoutboundmetadataResult = Record<string, unknown>;

/** get-server-capabilities (diagnostics/runtime.uc) */
export type GetservercapabilitiesParams = Record<string, never>;

export type GetservercapabilitiesResult = Record<string, unknown>;

/** get-sing-box-status (diagnostics/runtime.uc) */
export type GetsingboxstatusParams = Record<string, never>;

export type GetsingboxstatusResult = Record<string, unknown>;

/** get-status (diagnostics/runtime.uc) */
export type GetstatusParams = Record<string, never>;

export type GetstatusResult = Record<string, unknown>;

/** get-subscription-metadata (diagnostics/runtime.uc) */
export interface GetsubscriptionmetadataParams {
  /** positional argument 1 of get_subscription_metadata */
  arg1?: string;
}

export type GetsubscriptionmetadataResult = Record<string, unknown>;

/** get-system-info (diagnostics/runtime.uc) */
export type GetsysteminfoParams = Record<string, never>;

export type GetsysteminfoResult = Record<string, unknown>;

/** get-tailscale-peers (diagnostics/runtime.uc) */
export type GettailscalepeersParams = Record<string, never>;

export type GettailscalepeersResult = Record<string, unknown>;

/** get-tailscale-status (diagnostics/runtime.uc) */
export type GettailscalestatusParams = Record<string, never>;

export type GettailscalestatusResult = Record<string, unknown>;

/** tls-certificate-sha256 (server/service.uc) */
export interface Gettlscertificatesha256Params {
  /** positional argument 1 of get_tls_certificate_sha256 */
  arg1?: string;
}

export type Gettlscertificatesha256Result = Record<string, unknown>;

/** get-ui-capabilities (service/ui.uc) */
export type GetuicapabilitiesParams = Record<string, never>;

export type GetuicapabilitiesResult = Record<string, unknown>;

/** get-ui-state (service/ui.uc) */
export type GetuistateParams = Record<string, never>;

export type GetuistateResult = Record<string, unknown>;

/** get-wdtt-status (diagnostics/runtime.uc) */
export type GetwdttstatusParams = Record<string, never>;

export type GetwdttstatusResult = Record<string, unknown>;

/** get-zapret2-status (diagnostics/runtime.uc) */
export type Getzapret2statusParams = Record<string, never>;

export type Getzapret2statusResult = Record<string, unknown>;

/** get-zapret-status (diagnostics/runtime.uc) */
export type GetzapretstatusParams = Record<string, never>;

export type GetzapretstatusResult = Record<string, unknown>;

/** global-check (diagnostics/runtime.uc) */
export interface GlobalcheckParams {
  /** positional argument 1 of global_check */
  arg1?: string;
  /** positional argument 2 of global_check */
  arg2?: string;
}

export type GlobalcheckResult = Record<string, unknown>;

/** list-status (components/hosts.uc) */
export type HostsliststatusParams = Record<string, never>;

export type HostsliststatusResult = Record<string, unknown>;

/** list-update (components/hosts.uc) */
export interface HostslistupdateParams {
  /** positional argument 1 of hosts_list_update */
  arg1?: string;
}

export type HostslistupdateResult = Record<string, unknown>;

/** import-settings (config/migration.uc) */
export interface ImportSettingsParams {
  /** positional argument 1 of import-settings */
  arg1?: string;
}

export type ImportSettingsResult = Record<string, unknown>;

/** import-settings (config/migration.uc) */
export interface ImportsettingsParams {
  /** positional argument 1 of import_settings */
  arg1?: string;
}

export type ImportsettingsResult = Record<string, unknown>;

/** install-tor (diagnostics/runtime.uc) */
export type InstalltorParams = Record<string, never>;

export type InstalltorResult = Record<string, unknown>;

/** cancel (core/jobs.uc) */
export interface JobCancelParams {
  /** positional argument 1 of job-cancel */
  arg1?: string;
}

export type JobCancelResult = Record<string, unknown>;

/** gc (core/jobs.uc) */
export type JobGcParams = Record<string, never>;

export type JobGcResult = Record<string, unknown>;

/** list (core/jobs.uc) */
export type JobListParams = Record<string, never>;

export type JobListResult = Record<string, unknown>;

/** query (core/jobs.uc) */
export interface JobQueryParams {
  /** positional argument 1 of job-query */
  arg1?: string;
}

export type JobQueryResult = Record<string, unknown>;

/** request-cancel (core/jobs.uc) */
export interface JobRequestCancelParams {
  /** positional argument 1 of job-request-cancel */
  arg1?: string;
}

export type JobRequestCancelResult = Record<string, unknown>;

/** cancel (core/jobs.uc) */
export interface JobcancelParams {
  /** positional argument 1 of job_cancel */
  arg1?: string;
}

export type JobcancelResult = Record<string, unknown>;

/** gc (core/jobs.uc) */
export type JobgcParams = Record<string, never>;

export type JobgcResult = Record<string, unknown>;

/** list (core/jobs.uc) */
export type JoblistParams = Record<string, never>;

export type JoblistResult = Record<string, unknown>;

/** query (core/jobs.uc) */
export interface JobqueryParams {
  /** positional argument 1 of job_query */
  arg1?: string;
}

export type JobqueryResult = Record<string, unknown>;

/** request-cancel (core/jobs.uc) */
export interface JobrequestcancelParams {
  /** positional argument 1 of job_request_cancel */
  arg1?: string;
}

export type JobrequestcancelResult = Record<string, unknown>;

/** status (service/known_good.uc) */
export interface KnownGoodParams {
  /** positional argument 1 of known-good */
  arg1?: string;
  /** positional argument 2 of known-good */
  arg2?: string;
}

export type KnownGoodResult = Record<string, unknown>;

/** check (service/known_good.uc) */
export type KnownGoodCheckParams = Record<string, never>;

export type KnownGoodCheckResult = Record<string, unknown>;

/** promote (service/known_good.uc) */
export interface KnownGoodPromoteParams {
  /** positional argument 1 of known-good-promote */
  arg1?: string;
}

export type KnownGoodPromoteResult = Record<string, unknown>;

/** restore (service/known_good.uc) */
export interface KnownGoodRestoreParams {
  /** positional argument 1 of known-good-restore */
  arg1?: string;
}

export type KnownGoodRestoreResult = Record<string, unknown>;

/** rollback (service/known_good.uc) */
export interface KnownGoodRollbackParams {
  /** positional argument 1 of known-good-rollback */
  arg1?: string;
}

export type KnownGoodRollbackResult = Record<string, unknown>;

/** status (service/known_good.uc) */
export interface KnownGoodStatusParams {
  /** positional argument 1 of known-good-status */
  arg1?: string;
  /** positional argument 2 of known-good-status */
  arg2?: string;
}

export type KnownGoodStatusResult = Record<string, unknown>;

/** status (service/known_good.uc) */
export interface KnowngoodParams {
  /** positional argument 1 of known_good */
  arg1?: string;
  /** positional argument 2 of known_good */
  arg2?: string;
}

export type KnowngoodResult = Record<string, unknown>;

/** check (service/known_good.uc) */
export type KnowngoodcheckParams = Record<string, never>;

export type KnowngoodcheckResult = Record<string, unknown>;

/** promote (service/known_good.uc) */
export interface KnowngoodpromoteParams {
  /** positional argument 1 of known_good_promote */
  arg1?: string;
}

export type KnowngoodpromoteResult = Record<string, unknown>;

/** restore (service/known_good.uc) */
export interface KnowngoodrestoreParams {
  /** positional argument 1 of known_good_restore */
  arg1?: string;
}

export type KnowngoodrestoreResult = Record<string, unknown>;

/** rollback (service/known_good.uc) */
export interface KnowngoodrollbackParams {
  /** positional argument 1 of known_good_rollback */
  arg1?: string;
}

export type KnowngoodrollbackResult = Record<string, unknown>;

/** status (service/known_good.uc) */
export interface KnowngoodstatusParams {
  /** positional argument 1 of known_good_status */
  arg1?: string;
  /** positional argument 2 of known_good_status */
  arg2?: string;
}

export type KnowngoodstatusResult = Record<string, unknown>;

/** lan-clients (diagnostics/runtime.uc) */
export type LanclientsParams = Record<string, never>;

export type LanclientsResult = Record<string, unknown>;

/** latency-test-async (service/ui.uc) */
export interface LatencytestasyncParams {
  /** positional argument 1 of latency_test_async */
  arg1?: string;
  /** positional argument 2 of latency_test_async */
  arg2?: string;
  /** positional argument 3 of latency_test_async */
  arg3?: string;
  /** positional argument 4 of latency_test_async */
  arg4?: string;
}

export type LatencytestasyncResult = Record<string, unknown>;

/** latency-test-status (service/ui.uc) */
export interface LatencyteststatusParams {
  /** positional argument 1 of latency_test_status */
  arg1?: string;
}

export type LatencyteststatusResult = Record<string, unknown>;

/** leak-check (diagnostics/leak_check.uc) */
export interface LeakcheckParams {
  /** positional argument 1 of leak_check */
  arg1?: string;
  /** positional argument 2 of leak_check */
  arg2?: string;
}

export type LeakcheckResult = Record<string, unknown>;

/** leak-check-async (diagnostics/leak_check.uc) */
export interface LeakcheckasyncParams {
  /** positional argument 1 of leak_check_async */
  arg1?: string;
}

export type LeakcheckasyncResult = Record<string, unknown>;

/** leak-check-status (diagnostics/leak_check.uc) */
export interface LeakcheckstatusParams {
  /** positional argument 1 of leak_check_status */
  arg1?: string;
}

export type LeakcheckstatusResult = Record<string, unknown>;

/** list-update (components/updates.uc) */
export type ListupdateParams = Record<string, never>;

export type ListupdateResult = Record<string, unknown>;

/** list-update-async (components/updates.uc) */
export type ListupdateasyncParams = Record<string, never>;

export type ListupdateasyncResult = Record<string, unknown>;

/** list-update-if-due (components/updates.uc) */
export type ListupdateifdueParams = Record<string, never>;

export type ListupdateifdueResult = Record<string, unknown>;

/** list-update-status (components/updates.uc) */
export type ListupdatestatusParams = Record<string, never>;

export type ListupdatestatusResult = Record<string, unknown>;

/** luci-postinst (service/package.uc) */
export type LucipostinstParams = Record<string, never>;

export type LucipostinstResult = Record<string, unknown>;

/** main (service/lifecycle.uc) */
export type MainParams = Record<string, never>;

export type MainResult = Record<string, unknown>;

/**  (service/agent_mcp.uc) */
export type McpParams = Record<string, never>;

export type McpResult = Record<string, unknown>;

/** neutralize-zapret-defaults (diagnostics/runtime.uc) */
export type NeutralizezapretdefaultsParams = Record<string, never>;

export type NeutralizezapretdefaultsResult = Record<string, unknown>;

/** postinst (service/package.uc) */
export type PackagepostinstParams = Record<string, never>;

export type PackagepostinstResult = Record<string, unknown>;

/** prerm (service/package.uc) */
export interface PackageprermParams {
  /** positional argument 1 of package_prerm */
  arg1?: string;
}

export type PackageprermResult = Record<string, unknown>;

/** reset (service/parental_quota.uc) */
export type ParentalquotaresetParams = Record<string, never>;

export type ParentalquotaresetResult = Record<string, unknown>;

/** tick (service/parental_quota.uc) */
export type ParentalquotatickParams = Record<string, never>;

export type ParentalquotatickResult = Record<string, unknown>;

/** apply (service/reconciler.uc) */
export type ReconcileParams = Record<string, never>;

export type ReconcileResult = Record<string, unknown>;

/** plan (service/reconciler.uc) */
export type ReconcileplanParams = Record<string, never>;

export type ReconcileplanResult = Record<string, unknown>;

/** status (service/reconciler.uc) */
export type ReconcilestatusParams = Record<string, never>;

export type ReconcilestatusResult = Record<string, unknown>;

/** reload (service/lifecycle.uc) */
export interface ReloadParams {
  /** positional argument 1 of reload */
  arg1?: string;
}

export type ReloadResult = Record<string, unknown>;

/** reload-firewall (service/lifecycle.uc) */
export type ReloadfirewallParams = Record<string, never>;

export type ReloadfirewallResult = Record<string, unknown>;

/** reset-settings (service/reset.uc) */
export interface ResetsettingsParams {
  /** positional argument 1 of reset_settings */
  arg1?: string;
}

export type ResetsettingsResult = Record<string, unknown>;

/** resolve-domain (diagnostics/runtime.uc) */
export interface ResolveDomainParams {
  /** positional argument 1 of resolve-domain */
  arg1?: string;
}

export type ResolveDomainResult = Record<string, unknown>;

/** resolve-domain (diagnostics/runtime.uc) */
export interface ResolvedomainParams {
  /** positional argument 1 of resolve_domain */
  arg1?: string;
}

export type ResolvedomainResult = Record<string, unknown>;

/** restart (service/lifecycle.uc) */
export type RestartParams = Record<string, never>;

export type RestartResult = Record<string, unknown>;

/** dnsmasq-restore (service/lifecycle.uc) */
export type RestorednsmasqParams = Record<string, never>;

export type RestorednsmasqResult = Record<string, unknown>;

/** explain (diagnostics/route_explain.uc) */
export interface RouteExplainParams {
  /** positional argument 1 of route-explain */
  arg1?: string;
  /** positional argument 2 of route-explain */
  arg2?: string;
  /** positional argument 3 of route-explain */
  arg3?: string;
  /** positional argument 4 of route-explain */
  arg4?: string;
}

export type RouteExplainResult = Record<string, unknown>;

/** explain (diagnostics/route_explain.uc) */
export interface RouteexplainParams {
  /** positional argument 1 of route_explain */
  arg1?: string;
  /** positional argument 2 of route_explain */
  arg2?: string;
  /** positional argument 3 of route_explain */
  arg3?: string;
  /** positional argument 4 of route_explain */
  arg4?: string;
}

export type RouteexplainResult = Record<string, unknown>;

/** best (diagnostics/server_stats.uc) */
export interface ServerBestParams {
  /** positional argument 1 of server-best */
  arg1?: string;
  /** positional argument 2 of server-best */
  arg2?: string;
}

export type ServerBestResult = Record<string, unknown>;

/** probe (diagnostics/server_stats.uc) */
export interface ServerProbeParams {
  /** positional argument 1 of server-probe */
  arg1?: string;
  /** positional argument 2 of server-probe */
  arg2?: string;
}

export type ServerProbeResult = Record<string, unknown>;

/** probe_all (diagnostics/server_stats.uc) */
export interface ServerProbeAllParams {
  /** positional argument 1 of server-probe-all */
  arg1?: string;
  /** positional argument 2 of server-probe-all */
  arg2?: string;
}

export type ServerProbeAllResult = Record<string, unknown>;

/** query (diagnostics/server_stats.uc) */
export interface ServerQueryParams {
  /** positional argument 1 of server-query */
  arg1?: string;
}

export type ServerQueryResult = Record<string, unknown>;

/** summary (diagnostics/server_stats.uc) */
export type ServerStatsParams = Record<string, never>;

export type ServerStatsResult = Record<string, unknown>;

/** reset (diagnostics/server_stats.uc) */
export type ServerStatsResetParams = Record<string, never>;

export type ServerStatsResetResult = Record<string, unknown>;

/** best (diagnostics/server_stats.uc) */
export interface ServerbestParams {
  /** positional argument 1 of server_best */
  arg1?: string;
  /** positional argument 2 of server_best */
  arg2?: string;
}

export type ServerbestResult = Record<string, unknown>;

/** probe (diagnostics/server_stats.uc) */
export interface ServerprobeParams {
  /** positional argument 1 of server_probe */
  arg1?: string;
  /** positional argument 2 of server_probe */
  arg2?: string;
}

export type ServerprobeResult = Record<string, unknown>;

/** probe_all (diagnostics/server_stats.uc) */
export interface ServerprobeallParams {
  /** positional argument 1 of server_probe_all */
  arg1?: string;
  /** positional argument 2 of server_probe_all */
  arg2?: string;
}

export type ServerprobeallResult = Record<string, unknown>;

/** query (diagnostics/server_stats.uc) */
export interface ServerqueryParams {
  /** positional argument 1 of server_query */
  arg1?: string;
}

export type ServerqueryResult = Record<string, unknown>;

/** summary (diagnostics/server_stats.uc) */
export type ServerstatsParams = Record<string, never>;

export type ServerstatsResult = Record<string, unknown>;

/** reset (diagnostics/server_stats.uc) */
export type ServerstatsresetParams = Record<string, never>;

export type ServerstatsresetResult = Record<string, unknown>;

/** service-action-async (service/ui.uc) */
export interface ServiceactionasyncParams {
  /** positional argument 1 of service_action_async */
  arg1?: string;
}

export type ServiceactionasyncResult = Record<string, unknown>;

/** service-action-status (service/ui.uc) */
export interface ServiceactionstatusParams {
  /** positional argument 1 of service_action_status */
  arg1?: string;
}

export type ServiceactionstatusResult = Record<string, unknown>;

/** service-health-check (diagnostics/runtime.uc) */
export interface ServicehealthcheckParams {
  /** positional argument 1 of service_health_check */
  arg1?: string;
  /** positional argument 2 of service_health_check */
  arg2?: string;
}

export type ServicehealthcheckResult = Record<string, unknown>;

/** show-config (diagnostics/runtime.uc) */
export interface ShowconfigParams {
  /** positional argument 1 of show_config */
  arg1?: string;
}

export type ShowconfigResult = Record<string, unknown>;

/** show-sing-box-config (diagnostics/runtime.uc) */
export interface ShowsingboxconfigParams {
  /** positional argument 1 of show_sing_box_config */
  arg1?: string;
}

export type ShowsingboxconfigResult = Record<string, unknown>;

/** show-sing-box-version (diagnostics/runtime.uc) */
export type ShowsingboxversionParams = Record<string, never>;

export type ShowsingboxversionResult = Record<string, unknown>;

/** show-version (diagnostics/runtime.uc) */
export type ShowversionParams = Record<string, never>;

export type ShowversionResult = Record<string, unknown>;

/** snapshot-delete (service/snapshot.uc) */
export interface SnapshotdeleteParams {
  /** positional argument 1 of snapshot_delete */
  arg1?: string;
}

export type SnapshotdeleteResult = Record<string, unknown>;

/** snapshot-list (service/snapshot.uc) */
export type SnapshotlistParams = Record<string, never>;

export type SnapshotlistResult = Record<string, unknown>;

/** snapshot-restore (service/snapshot.uc) */
export interface SnapshotrestoreParams {
  /** positional argument 1 of snapshot_restore */
  arg1?: string;
}

export type SnapshotrestoreResult = Record<string, unknown>;

/** snapshot-save (service/snapshot.uc) */
export interface SnapshotsaveParams {
  /** positional argument 1 of snapshot_save */
  arg1?: string;
}

export type SnapshotsaveResult = Record<string, unknown>;

/** report (diagnostics/stability.uc) */
export type StabilityReportParams = Record<string, never>;

export type StabilityReportResult = Record<string, unknown>;

/** status (diagnostics/stability.uc) */
export type StabilityStatusParams = Record<string, never>;

export type StabilityStatusResult = Record<string, unknown>;

/** report (diagnostics/stability.uc) */
export type StabilityreportParams = Record<string, never>;

export type StabilityreportResult = Record<string, unknown>;

/** status (diagnostics/stability.uc) */
export type StabilitystatusParams = Record<string, never>;

export type StabilitystatusResult = Record<string, unknown>;

/** start (service/lifecycle.uc) */
export type StartParams = Record<string, never>;

export type StartResult = Record<string, unknown>;

/** stop (service/lifecycle.uc) */
export type StopParams = Record<string, never>;

export type StopResult = Record<string, unknown>;

/** subscription-update (components/updates.uc) */
export interface SubscriptionupdateParams {
  /** positional argument 1 of subscription_update */
  arg1?: string;
  /** positional argument 2 of subscription_update */
  arg2?: string;
}

export type SubscriptionupdateResult = Record<string, unknown>;

/** subscription-update-async (components/updates.uc) */
export interface SubscriptionupdateasyncParams {
  /** positional argument 1 of subscription_update_async */
  arg1?: string;
  /** positional argument 2 of subscription_update_async */
  arg2?: string;
}

export type SubscriptionupdateasyncResult = Record<string, unknown>;

/** subscription-update-if-due (components/updates.uc) */
export type SubscriptionupdateifdueParams = Record<string, never>;

export type SubscriptionupdateifdueResult = Record<string, unknown>;

/** subscription-update-status (components/updates.uc) */
export interface SubscriptionupdatestatusParams {
  /** positional argument 1 of subscription_update_status */
  arg1?: string;
}

export type SubscriptionupdatestatusResult = Record<string, unknown>;

/** create (service/support_bundle.uc) */
export interface SupportBundleParams {
  /** positional argument 1 of support-bundle */
  arg1?: string;
  /** positional argument 2 of support-bundle */
  arg2?: string;
  /** positional argument 3 of support-bundle */
  arg3?: string;
}

export type SupportBundleResult = Record<string, unknown>;

/** create (service/support_bundle.uc) */
export interface SupportbundleParams {
  /** positional argument 1 of support_bundle */
  arg1?: string;
  /** positional argument 2 of support_bundle */
  arg2?: string;
  /** positional argument 3 of support_bundle */
  arg3?: string;
}

export type SupportbundleResult = Record<string, unknown>;

/** start-runtime (providers/tailscale/runtime.uc) */
export type TailscalerestartParams = Record<string, never>;

export type TailscalerestartResult = Record<string, unknown>;

/**  (service/telegram.uc) */
export interface TelegramParams {
  /** positional argument 1 of telegram */
  arg1?: string;
  /** positional argument 2 of telegram */
  arg2?: string;
}

export type TelegramResult = Record<string, unknown>;

/** diagnose (service/telegram.uc) */
export type TelegramdiagnoseParams = Record<string, never>;

export type TelegramdiagnoseResult = Record<string, unknown>;

/** start-runtime (service/telegram.uc) */
export type TelegramstartParams = Record<string, never>;

export type TelegramstartResult = Record<string, unknown>;

/** status (service/telegram.uc) */
export type TelegramstatusParams = Record<string, never>;

export type TelegramstatusResult = Record<string, unknown>;

/** stop-runtime (service/telegram.uc) */
export type TelegramstopParams = Record<string, never>;

export type TelegramstopResult = Record<string, unknown>;

/** toggle-client-bypass (diagnostics/runtime.uc) */
export interface ToggleclientbypassParams {
  /** positional argument 1 of toggle_client_bypass */
  arg1?: string;
}

export type ToggleclientbypassResult = Record<string, unknown>;

/** action-ack (service/ui.uc) */
export interface UiactionackParams {
  /** positional argument 1 of ui_action_ack */
  arg1?: string;
  /** positional argument 2 of ui_action_ack */
  arg2?: string;
}

export type UiactionackResult = Record<string, unknown>;

/** uninstall (service/uninstall.uc) */
export interface UninstallParams {
  /** positional argument 1 of uninstall */
  arg1?: string;
}

export type UninstallResult = Record<string, unknown>;

/** validate-byedpi-strategy-json (diagnostics/runtime.uc) */
export interface ValidatebyedpistrategyjsonParams {
  /** positional argument 1 of validate_byedpi_strategy_json */
  arg1?: string;
}

export type ValidatebyedpistrategyjsonResult = Record<string, unknown>;

/** validate-nfqws2-strategy-json (diagnostics/runtime.uc) */
export interface Validatenfqws2strategyjsonParams {
  /** positional argument 1 of validate_nfqws2_strategy_json */
  arg1?: string;
}

export type Validatenfqws2strategyjsonResult = Record<string, unknown>;

/** validate-nfqws-strategy-json (diagnostics/runtime.uc) */
export interface ValidatenfqwsstrategyjsonParams {
  /** positional argument 1 of validate_nfqws_strategy_json */
  arg1?: string;
}

export type ValidatenfqwsstrategyjsonResult = Record<string, unknown>;

/**  (service/watchdog.uc) */
export interface WatchdogParams {
  /** positional argument 1 of watchdog */
  arg1?: string;
}

export type WatchdogResult = Record<string, unknown>;

/** start-runtime (service/watchdog.uc) */
export type WatchdogstartParams = Record<string, never>;

export type WatchdogstartResult = Record<string, unknown>;

/** stop-runtime (service/watchdog.uc) */
export type WatchdogstopParams = Record<string, never>;

export type WatchdogstopResult = Record<string, unknown>;

export interface TachyonRpcRegistry {
  agent_cgi: {
    params: AgentcgiParams;
    result: AgentcgiResult;
  };
  ai_doctor: {
    params: AidoctorParams;
    result: AidoctorResult;
  };
  ai_doctor_last: {
    params: AidoctorlastParams;
    result: AidoctorlastResult;
  };
  ai_heal: {
    params: AihealParams;
    result: AihealResult;
  };
  ai_status: {
    params: AistatusParams;
    result: AistatusResult;
  };
  ai_status_full: {
    params: AistatusfullParams;
    result: AistatusfullResult;
  };
  apply_quick_fix: {
    params: ApplyquickfixParams;
    result: ApplyquickfixResult;
  };
  check_byedpi_runtime: {
    params: CheckbyedpiruntimeParams;
    result: CheckbyedpiruntimeResult;
  };
  check_dns_available: {
    params: CheckdnsavailableParams;
    result: CheckdnsavailableResult;
  };
  check_dns_leak: {
    params: CheckdnsleakParams;
    result: CheckdnsleakResult;
  };
  check_fakeip: {
    params: CheckfakeipParams;
    result: CheckfakeipResult;
  };
  check_inbounds: {
    params: CheckinboundsParams;
    result: CheckinboundsResult;
  };
  check_inbounds_config: {
    params: CheckinboundsconfigParams;
    result: CheckinboundsconfigResult;
  };
  check_ip_leak: {
    params: CheckipleakParams;
    result: CheckipleakResult;
  };
  check_logs: {
    params: ChecklogsParams;
    result: ChecklogsResult;
  };
  check_nft: {
    params: ChecknftParams;
    result: ChecknftResult;
  };
  check_nft_rules: {
    params: ChecknftrulesParams;
    result: ChecknftrulesResult;
  };
  check_proxy: {
    params: CheckproxyParams;
    result: CheckproxyResult;
  };
  check_sing_box: {
    params: ChecksingboxParams;
    result: ChecksingboxResult;
  };
  check_sing_box_logs: {
    params: ChecksingboxlogsParams;
    result: ChecksingboxlogsResult;
  };
  check_steer: {
    params: ChecksteerParams;
    result: ChecksteerResult;
  };
  check_tor_runtime: {
    params: ChecktorruntimeParams;
    result: ChecktorruntimeResult;
  };
  check_zapret2_runtime: {
    params: Checkzapret2runtimeParams;
    result: Checkzapret2runtimeResult;
  };
  check_zapret_runtime: {
    params: CheckzapretruntimeParams;
    result: CheckzapretruntimeResult;
  };
  clash_api: {
    params: ClashapiParams;
    result: ClashapiResult;
  };
  component_action: {
    params: ComponentactionParams;
    result: ComponentactionResult;
  };
  component_action_async: {
    params: ComponentactionasyncParams;
    result: ComponentactionasyncResult;
  };
  component_action_log: {
    params: ComponentactionlogParams;
    result: ComponentactionlogResult;
  };
  component_action_status: {
    params: ComponentactionstatusParams;
    result: ComponentactionstatusResult;
  };
  component_auto_update_apply: {
    params: ComponentautoupdateapplyParams;
    result: ComponentautoupdateapplyResult;
  };
  component_install_version: {
    params: ComponentinstallversionParams;
    result: ComponentinstallversionResult;
  };
  component_list_releases: {
    params: ComponentlistreleasesParams;
    result: ComponentlistreleasesResult;
  };
  component_update_check_cache: {
    params: ComponentupdatecheckcacheParams;
    result: ComponentupdatecheckcacheResult;
  };
  component_updates_if_due: {
    params: ComponentupdatesifdueParams;
    result: ComponentupdatesifdueResult;
  };
  'config-plan': {
    params: ConfigPlanParams;
    result: ConfigPlanResult;
  };
  'config-validate': {
    params: ConfigValidateParams;
    result: ConfigValidateResult;
  };
  config_plan: {
    params: ConfigplanParams;
    result: ConfigplanResult;
  };
  config_validate: {
    params: ConfigvalidateParams;
    result: ConfigvalidateResult;
  };
  delete_section: {
    params: DeletesectionParams;
    result: DeletesectionResult;
  };
  diagnose_json: {
    params: DiagnosejsonParams;
    result: DiagnosejsonResult;
  };
  disable: {
    params: DisableParams;
    result: DisableResult;
  };
  dns_autotune: {
    params: DnsautotuneParams;
    result: DnsautotuneResult;
  };
  dns_benchmark: {
    params: DnsbenchmarkParams;
    result: DnsbenchmarkResult;
  };
  dns_benchmark_apply: {
    params: DnsbenchmarkapplyParams;
    result: DnsbenchmarkapplyResult;
  };
  dns_benchmark_async: {
    params: DnsbenchmarkasyncParams;
    result: DnsbenchmarkasyncResult;
  };
  dns_benchmark_status: {
    params: DnsbenchmarkstatusParams;
    result: DnsbenchmarkstatusResult;
  };
  dns_benchmark_stop: {
    params: DnsbenchmarkstopParams;
    result: DnsbenchmarkstopResult;
  };
  dns_failover_apply: {
    params: DnsfailoverapplyParams;
    result: DnsfailoverapplyResult;
  };
  dns_speed_test_start: {
    params: DnsspeedteststartParams;
    result: DnsspeedteststartResult;
  };
  dns_speed_test_status: {
    params: DnsspeedteststatusParams;
    result: DnsspeedteststatusResult;
  };
  dnsmasq_restore: {
    params: DnsmasqrestoreParams;
    result: DnsmasqrestoreResult;
  };
  doctor: {
    params: DoctorParams;
    result: DoctorResult;
  };
  emergency_reset: {
    params: EmergencyresetParams;
    result: EmergencyresetResult;
  };
  emergency_status: {
    params: EmergencystatusParams;
    result: EmergencystatusResult;
  };
  emergency_trigger: {
    params: EmergencytriggerParams;
    result: EmergencytriggerResult;
  };
  enable: {
    params: EnableParams;
    result: EnableResult;
  };
  engine_apply: {
    params: EngineapplyParams;
    result: EngineapplyResult;
  };
  engine_diag: {
    params: EnginediagParams;
    result: EnginediagResult;
  };
  engine_explain: {
    params: EngineexplainParams;
    result: EngineexplainResult;
  };
  engine_features: {
    params: EnginefeaturesParams;
    result: EnginefeaturesResult;
  };
  engine_generate: {
    params: EnginegenerateParams;
    result: EnginegenerateResult;
  };
  engine_info: {
    params: EngineinfoParams;
    result: EngineinfoResult;
  };
  engine_plan: {
    params: EngineplanParams;
    result: EngineplanResult;
  };
  engine_reload: {
    params: EnginereloadParams;
    result: EnginereloadResult;
  };
  engine_start: {
    params: EnginestartParams;
    result: EnginestartResult;
  };
  engine_status: {
    params: EnginestatusParams;
    result: EnginestatusResult;
  };
  engine_stop: {
    params: EnginestopParams;
    result: EnginestopResult;
  };
  engine_switch: {
    params: EngineswitchParams;
    result: EngineswitchResult;
  };
  engine_switch_back: {
    params: EngineswitchbackParams;
    result: EngineswitchbackResult;
  };
  escalation_status: {
    params: EscalationstatusParams;
    result: EscalationstatusResult;
  };
  'event-clear': {
    params: EventClearParams;
    result: EventClearResult;
  };
  'event-query': {
    params: EventQueryParams;
    result: EventQueryResult;
  };
  'event-record': {
    params: EventRecordParams;
    result: EventRecordResult;
  };
  'event-stats': {
    params: EventStatsParams;
    result: EventStatsResult;
  };
  'event-tail': {
    params: EventTailParams;
    result: EventTailResult;
  };
  event_clear: {
    params: EventclearParams;
    result: EventclearResult;
  };
  event_query: {
    params: EventqueryParams;
    result: EventqueryResult;
  };
  event_record: {
    params: EventrecordParams;
    result: EventrecordResult;
  };
  event_stats: {
    params: EventstatsParams;
    result: EventstatsResult;
  };
  event_tail: {
    params: EventtailParams;
    result: EventtailResult;
  };
  extract_ruleset: {
    params: ExtractrulesetParams;
    result: ExtractrulesetResult;
  };
  failover_check: {
    params: FailovercheckParams;
    result: FailovercheckResult;
  };
  fuzzer_ai_synthesize: {
    params: FuzzeraisynthesizeParams;
    result: FuzzeraisynthesizeResult;
  };
  fuzzer_apply: {
    params: FuzzerapplyParams;
    result: FuzzerapplyResult;
  };
  fuzzer_auto_apply: {
    params: FuzzerautoapplyParams;
    result: FuzzerautoapplyResult;
  };
  fuzzer_clear_history: {
    params: FuzzerclearhistoryParams;
    result: FuzzerclearhistoryResult;
  };
  fuzzer_detect_dpi: {
    params: FuzzerdetectdpiParams;
    result: FuzzerdetectdpiResult;
  };
  fuzzer_generate: {
    params: FuzzergenerateParams;
    result: FuzzergenerateResult;
  };
  fuzzer_get_patterns: {
    params: FuzzergetpatternsParams;
    result: FuzzergetpatternsResult;
  };
  fuzzer_history: {
    params: FuzzerhistoryParams;
    result: FuzzerhistoryResult;
  };
  fuzzer_presets_info: {
    params: FuzzerpresetsinfoParams;
    result: FuzzerpresetsinfoResult;
  };
  fuzzer_reset_patterns: {
    params: FuzzerresetpatternsParams;
    result: FuzzerresetpatternsResult;
  };
  fuzzer_save_patterns: {
    params: FuzzersavepatternsParams;
    result: FuzzersavepatternsResult;
  };
  fuzzer_start: {
    params: FuzzerstartParams;
    result: FuzzerstartResult;
  };
  fuzzer_status: {
    params: FuzzerstatusParams;
    result: FuzzerstatusResult;
  };
  fuzzer_stop: {
    params: FuzzerstopParams;
    result: FuzzerstopResult;
  };
  fuzzer_strategies: {
    params: FuzzerstrategiesParams;
    result: FuzzerstrategiesResult;
  };
  fuzzer_update_presets: {
    params: FuzzerupdatepresetsParams;
    result: FuzzerupdatepresetsResult;
  };
  generate_reality_keypair: {
    params: GeneraterealitykeypairParams;
    result: GeneraterealitykeypairResult;
  };
  generate_warp: {
    params: GeneratewarpParams;
    result: GeneratewarpResult;
  };
  get_byedpi_status: {
    params: GetbyedpistatusParams;
    result: GetbyedpistatusResult;
  };
  get_engine_status: {
    params: GetenginestatusParams;
    result: GetenginestatusResult;
  };
  get_fptn_status: {
    params: GetfptnstatusParams;
    result: GetfptnstatusResult;
  };
  get_olcrtc_status: {
    params: GetolcrtcstatusParams;
    result: GetolcrtcstatusResult;
  };
  get_outbound_metadata: {
    params: GetoutboundmetadataParams;
    result: GetoutboundmetadataResult;
  };
  get_server_capabilities: {
    params: GetservercapabilitiesParams;
    result: GetservercapabilitiesResult;
  };
  get_sing_box_status: {
    params: GetsingboxstatusParams;
    result: GetsingboxstatusResult;
  };
  get_status: {
    params: GetstatusParams;
    result: GetstatusResult;
  };
  get_subscription_metadata: {
    params: GetsubscriptionmetadataParams;
    result: GetsubscriptionmetadataResult;
  };
  get_system_info: {
    params: GetsysteminfoParams;
    result: GetsysteminfoResult;
  };
  get_tailscale_peers: {
    params: GettailscalepeersParams;
    result: GettailscalepeersResult;
  };
  get_tailscale_status: {
    params: GettailscalestatusParams;
    result: GettailscalestatusResult;
  };
  get_tls_certificate_sha256: {
    params: Gettlscertificatesha256Params;
    result: Gettlscertificatesha256Result;
  };
  get_ui_capabilities: {
    params: GetuicapabilitiesParams;
    result: GetuicapabilitiesResult;
  };
  get_ui_state: {
    params: GetuistateParams;
    result: GetuistateResult;
  };
  get_wdtt_status: {
    params: GetwdttstatusParams;
    result: GetwdttstatusResult;
  };
  get_zapret2_status: {
    params: Getzapret2statusParams;
    result: Getzapret2statusResult;
  };
  get_zapret_status: {
    params: GetzapretstatusParams;
    result: GetzapretstatusResult;
  };
  global_check: {
    params: GlobalcheckParams;
    result: GlobalcheckResult;
  };
  hosts_list_status: {
    params: HostsliststatusParams;
    result: HostsliststatusResult;
  };
  hosts_list_update: {
    params: HostslistupdateParams;
    result: HostslistupdateResult;
  };
  'import-settings': {
    params: ImportSettingsParams;
    result: ImportSettingsResult;
  };
  import_settings: {
    params: ImportsettingsParams;
    result: ImportsettingsResult;
  };
  install_tor: {
    params: InstalltorParams;
    result: InstalltorResult;
  };
  'job-cancel': {
    params: JobCancelParams;
    result: JobCancelResult;
  };
  'job-gc': {
    params: JobGcParams;
    result: JobGcResult;
  };
  'job-list': {
    params: JobListParams;
    result: JobListResult;
  };
  'job-query': {
    params: JobQueryParams;
    result: JobQueryResult;
  };
  'job-request-cancel': {
    params: JobRequestCancelParams;
    result: JobRequestCancelResult;
  };
  job_cancel: {
    params: JobcancelParams;
    result: JobcancelResult;
  };
  job_gc: {
    params: JobgcParams;
    result: JobgcResult;
  };
  job_list: {
    params: JoblistParams;
    result: JoblistResult;
  };
  job_query: {
    params: JobqueryParams;
    result: JobqueryResult;
  };
  job_request_cancel: {
    params: JobrequestcancelParams;
    result: JobrequestcancelResult;
  };
  'known-good': {
    params: KnownGoodParams;
    result: KnownGoodResult;
  };
  'known-good-check': {
    params: KnownGoodCheckParams;
    result: KnownGoodCheckResult;
  };
  'known-good-promote': {
    params: KnownGoodPromoteParams;
    result: KnownGoodPromoteResult;
  };
  'known-good-restore': {
    params: KnownGoodRestoreParams;
    result: KnownGoodRestoreResult;
  };
  'known-good-rollback': {
    params: KnownGoodRollbackParams;
    result: KnownGoodRollbackResult;
  };
  'known-good-status': {
    params: KnownGoodStatusParams;
    result: KnownGoodStatusResult;
  };
  known_good: {
    params: KnowngoodParams;
    result: KnowngoodResult;
  };
  known_good_check: {
    params: KnowngoodcheckParams;
    result: KnowngoodcheckResult;
  };
  known_good_promote: {
    params: KnowngoodpromoteParams;
    result: KnowngoodpromoteResult;
  };
  known_good_restore: {
    params: KnowngoodrestoreParams;
    result: KnowngoodrestoreResult;
  };
  known_good_rollback: {
    params: KnowngoodrollbackParams;
    result: KnowngoodrollbackResult;
  };
  known_good_status: {
    params: KnowngoodstatusParams;
    result: KnowngoodstatusResult;
  };
  lan_clients: {
    params: LanclientsParams;
    result: LanclientsResult;
  };
  latency_test_async: {
    params: LatencytestasyncParams;
    result: LatencytestasyncResult;
  };
  latency_test_status: {
    params: LatencyteststatusParams;
    result: LatencyteststatusResult;
  };
  leak_check: {
    params: LeakcheckParams;
    result: LeakcheckResult;
  };
  leak_check_async: {
    params: LeakcheckasyncParams;
    result: LeakcheckasyncResult;
  };
  leak_check_status: {
    params: LeakcheckstatusParams;
    result: LeakcheckstatusResult;
  };
  list_update: {
    params: ListupdateParams;
    result: ListupdateResult;
  };
  list_update_async: {
    params: ListupdateasyncParams;
    result: ListupdateasyncResult;
  };
  list_update_if_due: {
    params: ListupdateifdueParams;
    result: ListupdateifdueResult;
  };
  list_update_status: {
    params: ListupdatestatusParams;
    result: ListupdatestatusResult;
  };
  luci_postinst: {
    params: LucipostinstParams;
    result: LucipostinstResult;
  };
  main: {
    params: MainParams;
    result: MainResult;
  };
  mcp: {
    params: McpParams;
    result: McpResult;
  };
  neutralize_zapret_defaults: {
    params: NeutralizezapretdefaultsParams;
    result: NeutralizezapretdefaultsResult;
  };
  package_postinst: {
    params: PackagepostinstParams;
    result: PackagepostinstResult;
  };
  package_prerm: {
    params: PackageprermParams;
    result: PackageprermResult;
  };
  parental_quota_reset: {
    params: ParentalquotaresetParams;
    result: ParentalquotaresetResult;
  };
  parental_quota_tick: {
    params: ParentalquotatickParams;
    result: ParentalquotatickResult;
  };
  reconcile: {
    params: ReconcileParams;
    result: ReconcileResult;
  };
  reconcile_plan: {
    params: ReconcileplanParams;
    result: ReconcileplanResult;
  };
  reconcile_status: {
    params: ReconcilestatusParams;
    result: ReconcilestatusResult;
  };
  reload: {
    params: ReloadParams;
    result: ReloadResult;
  };
  reload_firewall: {
    params: ReloadfirewallParams;
    result: ReloadfirewallResult;
  };
  reset_settings: {
    params: ResetsettingsParams;
    result: ResetsettingsResult;
  };
  'resolve-domain': {
    params: ResolveDomainParams;
    result: ResolveDomainResult;
  };
  resolve_domain: {
    params: ResolvedomainParams;
    result: ResolvedomainResult;
  };
  restart: {
    params: RestartParams;
    result: RestartResult;
  };
  restore_dnsmasq: {
    params: RestorednsmasqParams;
    result: RestorednsmasqResult;
  };
  'route-explain': {
    params: RouteExplainParams;
    result: RouteExplainResult;
  };
  route_explain: {
    params: RouteexplainParams;
    result: RouteexplainResult;
  };
  'server-best': {
    params: ServerBestParams;
    result: ServerBestResult;
  };
  'server-probe': {
    params: ServerProbeParams;
    result: ServerProbeResult;
  };
  'server-probe-all': {
    params: ServerProbeAllParams;
    result: ServerProbeAllResult;
  };
  'server-query': {
    params: ServerQueryParams;
    result: ServerQueryResult;
  };
  'server-stats': {
    params: ServerStatsParams;
    result: ServerStatsResult;
  };
  'server-stats-reset': {
    params: ServerStatsResetParams;
    result: ServerStatsResetResult;
  };
  server_best: {
    params: ServerbestParams;
    result: ServerbestResult;
  };
  server_probe: {
    params: ServerprobeParams;
    result: ServerprobeResult;
  };
  server_probe_all: {
    params: ServerprobeallParams;
    result: ServerprobeallResult;
  };
  server_query: {
    params: ServerqueryParams;
    result: ServerqueryResult;
  };
  server_stats: {
    params: ServerstatsParams;
    result: ServerstatsResult;
  };
  server_stats_reset: {
    params: ServerstatsresetParams;
    result: ServerstatsresetResult;
  };
  service_action_async: {
    params: ServiceactionasyncParams;
    result: ServiceactionasyncResult;
  };
  service_action_status: {
    params: ServiceactionstatusParams;
    result: ServiceactionstatusResult;
  };
  service_health_check: {
    params: ServicehealthcheckParams;
    result: ServicehealthcheckResult;
  };
  show_config: {
    params: ShowconfigParams;
    result: ShowconfigResult;
  };
  show_sing_box_config: {
    params: ShowsingboxconfigParams;
    result: ShowsingboxconfigResult;
  };
  show_sing_box_version: {
    params: ShowsingboxversionParams;
    result: ShowsingboxversionResult;
  };
  show_version: {
    params: ShowversionParams;
    result: ShowversionResult;
  };
  snapshot_delete: {
    params: SnapshotdeleteParams;
    result: SnapshotdeleteResult;
  };
  snapshot_list: {
    params: SnapshotlistParams;
    result: SnapshotlistResult;
  };
  snapshot_restore: {
    params: SnapshotrestoreParams;
    result: SnapshotrestoreResult;
  };
  snapshot_save: {
    params: SnapshotsaveParams;
    result: SnapshotsaveResult;
  };
  'stability-report': {
    params: StabilityReportParams;
    result: StabilityReportResult;
  };
  'stability-status': {
    params: StabilityStatusParams;
    result: StabilityStatusResult;
  };
  stability_report: {
    params: StabilityreportParams;
    result: StabilityreportResult;
  };
  stability_status: {
    params: StabilitystatusParams;
    result: StabilitystatusResult;
  };
  start: {
    params: StartParams;
    result: StartResult;
  };
  stop: {
    params: StopParams;
    result: StopResult;
  };
  subscription_update: {
    params: SubscriptionupdateParams;
    result: SubscriptionupdateResult;
  };
  subscription_update_async: {
    params: SubscriptionupdateasyncParams;
    result: SubscriptionupdateasyncResult;
  };
  subscription_update_if_due: {
    params: SubscriptionupdateifdueParams;
    result: SubscriptionupdateifdueResult;
  };
  subscription_update_status: {
    params: SubscriptionupdatestatusParams;
    result: SubscriptionupdatestatusResult;
  };
  'support-bundle': {
    params: SupportBundleParams;
    result: SupportBundleResult;
  };
  support_bundle: {
    params: SupportbundleParams;
    result: SupportbundleResult;
  };
  tailscale_restart: {
    params: TailscalerestartParams;
    result: TailscalerestartResult;
  };
  telegram: {
    params: TelegramParams;
    result: TelegramResult;
  };
  telegram_diagnose: {
    params: TelegramdiagnoseParams;
    result: TelegramdiagnoseResult;
  };
  telegram_start: {
    params: TelegramstartParams;
    result: TelegramstartResult;
  };
  telegram_status: {
    params: TelegramstatusParams;
    result: TelegramstatusResult;
  };
  telegram_stop: {
    params: TelegramstopParams;
    result: TelegramstopResult;
  };
  toggle_client_bypass: {
    params: ToggleclientbypassParams;
    result: ToggleclientbypassResult;
  };
  ui_action_ack: {
    params: UiactionackParams;
    result: UiactionackResult;
  };
  uninstall: {
    params: UninstallParams;
    result: UninstallResult;
  };
  validate_byedpi_strategy_json: {
    params: ValidatebyedpistrategyjsonParams;
    result: ValidatebyedpistrategyjsonResult;
  };
  validate_nfqws2_strategy_json: {
    params: Validatenfqws2strategyjsonParams;
    result: Validatenfqws2strategyjsonResult;
  };
  validate_nfqws_strategy_json: {
    params: ValidatenfqwsstrategyjsonParams;
    result: ValidatenfqwsstrategyjsonResult;
  };
  watchdog: {
    params: WatchdogParams;
    result: WatchdogResult;
  };
  watchdog_start: {
    params: WatchdogstartParams;
    result: WatchdogstartResult;
  };
  watchdog_stop: {
    params: WatchdogstopParams;
    result: WatchdogstopResult;
  };
}

export const RPC_METADATA_MAP: Record<TachyonRpcMethodName, RpcMethodMetadata> =
  {
    agent_cgi: {
      name: 'agent_cgi',
      cli_command: 'agent_cgi',
      category: 'ai',
      acl: 'write',
      description: '__cgi (service/agent_api.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    ai_doctor: {
      name: 'ai_doctor',
      cli_command: 'ai_doctor',
      category: 'diagnostics',
      acl: 'read',
      description: 'ai-doctor (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of ai_doctor',
        },
      ],
    },
    ai_doctor_last: {
      name: 'ai_doctor_last',
      cli_command: 'ai_doctor_last',
      category: 'diagnostics',
      acl: 'write',
      description: 'ai-doctor-last (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    ai_heal: {
      name: 'ai_heal',
      cli_command: 'ai_heal',
      category: 'system',
      acl: 'write',
      description: 'ai-heal (service/watchdog.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    ai_status: {
      name: 'ai_status',
      cli_command: 'ai_status',
      category: 'system',
      acl: 'read',
      description: 'ai-status (service/watchdog.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    ai_status_full: {
      name: 'ai_status_full',
      cli_command: 'ai_status_full',
      category: 'system',
      acl: 'write',
      description: 'ai-status-full (service/watchdog.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    apply_quick_fix: {
      name: 'apply_quick_fix',
      cli_command: 'apply_quick_fix',
      category: 'diagnostics',
      acl: 'write',
      description: 'apply-quick-fix (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of apply_quick_fix',
        },
      ],
    },
    check_byedpi_runtime: {
      name: 'check_byedpi_runtime',
      cli_command: 'check_byedpi_runtime',
      category: 'diagnostics',
      acl: 'read',
      description: 'check-byedpi-runtime (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    check_dns_available: {
      name: 'check_dns_available',
      cli_command: 'check_dns_available',
      category: 'diagnostics',
      acl: 'read',
      description: 'check-dns-available (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    check_dns_leak: {
      name: 'check_dns_leak',
      cli_command: 'check_dns_leak',
      category: 'diagnostics',
      acl: 'read',
      description: 'dns-leak (diagnostics/leak_check.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    check_fakeip: {
      name: 'check_fakeip',
      cli_command: 'check_fakeip',
      category: 'diagnostics',
      acl: 'read',
      description: 'check-fakeip (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    check_inbounds: {
      name: 'check_inbounds',
      cli_command: 'check_inbounds',
      category: 'diagnostics',
      acl: 'read',
      description: 'check-inbounds (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    check_inbounds_config: {
      name: 'check_inbounds_config',
      cli_command: 'check_inbounds_config',
      category: 'diagnostics',
      acl: 'read',
      description: 'check-inbounds-config (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    check_ip_leak: {
      name: 'check_ip_leak',
      cli_command: 'check_ip_leak',
      category: 'diagnostics',
      acl: 'read',
      description: 'ip-leak (diagnostics/leak_check.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    check_logs: {
      name: 'check_logs',
      cli_command: 'check_logs',
      category: 'diagnostics',
      acl: 'read',
      description: 'check-logs (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    check_nft: {
      name: 'check_nft',
      cli_command: 'check_nft',
      category: 'diagnostics',
      acl: 'read',
      description: 'check-nft (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    check_nft_rules: {
      name: 'check_nft_rules',
      cli_command: 'check_nft_rules',
      category: 'diagnostics',
      acl: 'read',
      description: 'check-nft-rules (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    check_proxy: {
      name: 'check_proxy',
      cli_command: 'check_proxy',
      category: 'diagnostics',
      acl: 'read',
      description: 'check-proxy (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    check_sing_box: {
      name: 'check_sing_box',
      cli_command: 'check_sing_box',
      category: 'diagnostics',
      acl: 'read',
      description: 'check-sing-box (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    check_sing_box_logs: {
      name: 'check_sing_box_logs',
      cli_command: 'check_sing_box_logs',
      category: 'diagnostics',
      acl: 'read',
      description: 'check-sing-box-logs (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    check_steer: {
      name: 'check_steer',
      cli_command: 'check_steer',
      category: 'diagnostics',
      acl: 'read',
      description: 'check-steer (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    check_tor_runtime: {
      name: 'check_tor_runtime',
      cli_command: 'check_tor_runtime',
      category: 'diagnostics',
      acl: 'read',
      description: 'check-tor-runtime (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    check_zapret2_runtime: {
      name: 'check_zapret2_runtime',
      cli_command: 'check_zapret2_runtime',
      category: 'diagnostics',
      acl: 'read',
      description: 'check-zapret2-runtime (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    check_zapret_runtime: {
      name: 'check_zapret_runtime',
      cli_command: 'check_zapret_runtime',
      category: 'diagnostics',
      acl: 'read',
      description: 'check-zapret-runtime (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    clash_api: {
      name: 'clash_api',
      cli_command: 'clash_api',
      category: 'diagnostics',
      acl: 'read',
      description: 'clash-api (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of clash_api',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of clash_api',
        },
        {
          name: 'arg3',
          type: 'string',
          required: false,
          description: 'positional argument 3 of clash_api',
        },
        {
          name: 'arg4',
          type: 'string',
          required: false,
          description: 'positional argument 4 of clash_api',
        },
      ],
    },
    component_action: {
      name: 'component_action',
      cli_command: 'component_action',
      category: 'updates',
      acl: 'write',
      description: 'component-action (components/action.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of component_action',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of component_action',
        },
      ],
    },
    component_action_async: {
      name: 'component_action_async',
      cli_command: 'component_action_async',
      category: 'updates',
      acl: 'write',
      description: 'component-action-async (components/updates.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of component_action_async',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of component_action_async',
        },
      ],
    },
    component_action_log: {
      name: 'component_action_log',
      cli_command: 'component_action_log',
      category: 'updates',
      acl: 'read',
      description: 'component-action-log (components/updates.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of component_action_log',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of component_action_log',
        },
      ],
    },
    component_action_status: {
      name: 'component_action_status',
      cli_command: 'component_action_status',
      category: 'updates',
      acl: 'read',
      description: 'component-action-status (components/updates.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of component_action_status',
        },
      ],
    },
    component_auto_update_apply: {
      name: 'component_auto_update_apply',
      cli_command: 'component_auto_update_apply',
      category: 'updates',
      acl: 'write',
      description: 'component-auto-update-apply (components/updates.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    component_install_version: {
      name: 'component_install_version',
      cli_command: 'component_install_version',
      category: 'updates',
      acl: 'write',
      description: 'install-component-version (components/action.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of component_install_version',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of component_install_version',
        },
      ],
    },
    component_list_releases: {
      name: 'component_list_releases',
      cli_command: 'component_list_releases',
      category: 'updates',
      acl: 'write',
      description: 'list-component-releases (components/action.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of component_list_releases',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of component_list_releases',
        },
      ],
    },
    component_update_check_cache: {
      name: 'component_update_check_cache',
      cli_command: 'component_update_check_cache',
      category: 'updates',
      acl: 'write',
      description: 'component-update-check-cache (components/updates.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    component_updates_if_due: {
      name: 'component_updates_if_due',
      cli_command: 'component_updates_if_due',
      category: 'updates',
      acl: 'write',
      description: 'component-updates-if-due (components/updates.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    'config-plan': {
      name: 'config-plan',
      cli_command: 'config-plan',
      category: 'system',
      acl: 'read',
      description: 'plan (service/config_plan.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of config-plan',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of config-plan',
        },
      ],
    },
    'config-validate': {
      name: 'config-validate',
      cli_command: 'config-validate',
      category: 'system',
      acl: 'read',
      description: 'validate (service/config_plan.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of config-validate',
        },
      ],
    },
    config_plan: {
      name: 'config_plan',
      cli_command: 'config_plan',
      category: 'system',
      acl: 'read',
      description: 'plan (service/config_plan.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of config_plan',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of config_plan',
        },
      ],
    },
    config_validate: {
      name: 'config_validate',
      cli_command: 'config_validate',
      category: 'system',
      acl: 'read',
      description: 'validate (service/config_plan.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of config_validate',
        },
      ],
    },
    delete_section: {
      name: 'delete_section',
      cli_command: 'delete_section',
      category: 'system',
      acl: 'write',
      description: 'delete-section (config/connections.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of delete_section',
        },
      ],
    },
    diagnose_json: {
      name: 'diagnose_json',
      cli_command: 'diagnose_json',
      category: 'diagnostics',
      acl: 'read',
      description: 'diagnose-json (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    disable: {
      name: 'disable',
      cli_command: 'disable',
      category: 'system',
      acl: 'write',
      description: 'disable (service/lifecycle.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    dns_autotune: {
      name: 'dns_autotune',
      cli_command: 'dns_autotune',
      category: 'system',
      acl: 'write',
      description: 'autotune (dns/benchmark.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of dns_autotune',
        },
      ],
    },
    dns_benchmark: {
      name: 'dns_benchmark',
      cli_command: 'dns_benchmark',
      category: 'system',
      acl: 'read',
      description: 'benchmark (dns/benchmark.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of dns_benchmark',
        },
      ],
    },
    dns_benchmark_apply: {
      name: 'dns_benchmark_apply',
      cli_command: 'dns_benchmark_apply',
      category: 'system',
      acl: 'write',
      description: 'benchmark_apply (dns/benchmark.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    dns_benchmark_async: {
      name: 'dns_benchmark_async',
      cli_command: 'dns_benchmark_async',
      category: 'system',
      acl: 'write',
      description: 'benchmark_async (dns/benchmark.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    dns_benchmark_status: {
      name: 'dns_benchmark_status',
      cli_command: 'dns_benchmark_status',
      category: 'system',
      acl: 'read',
      description: 'benchmark_status (dns/benchmark.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    dns_benchmark_stop: {
      name: 'dns_benchmark_stop',
      cli_command: 'dns_benchmark_stop',
      category: 'system',
      acl: 'write',
      description: 'benchmark_stop (dns/benchmark.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    dns_failover_apply: {
      name: 'dns_failover_apply',
      cli_command: 'dns_failover_apply',
      category: 'system',
      acl: 'write',
      description: 'dns-failover-apply (service/lifecycle.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of dns_failover_apply',
        },
      ],
    },
    dns_speed_test_start: {
      name: 'dns_speed_test_start',
      cli_command: 'dns_speed_test_start',
      category: 'system',
      acl: 'write',
      description: 'start (dns/speed_test.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of dns_speed_test_start',
        },
      ],
    },
    dns_speed_test_status: {
      name: 'dns_speed_test_status',
      cli_command: 'dns_speed_test_status',
      category: 'system',
      acl: 'read',
      description: 'status (dns/speed_test.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    dnsmasq_restore: {
      name: 'dnsmasq_restore',
      cli_command: 'dnsmasq_restore',
      category: 'system',
      acl: 'write',
      description: 'dnsmasq-restore (service/lifecycle.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    doctor: {
      name: 'doctor',
      cli_command: 'doctor',
      category: 'diagnostics',
      acl: 'read',
      description: 'doctor (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of doctor',
        },
      ],
    },
    emergency_reset: {
      name: 'emergency_reset',
      cli_command: 'emergency_reset',
      category: 'system',
      acl: 'write',
      description: 'emergency-reset (service/watchdog.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    emergency_status: {
      name: 'emergency_status',
      cli_command: 'emergency_status',
      category: 'system',
      acl: 'read',
      description: 'emergency-status (service/watchdog.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    emergency_trigger: {
      name: 'emergency_trigger',
      cli_command: 'emergency_trigger',
      category: 'system',
      acl: 'write',
      description: 'emergency-trigger (service/watchdog.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of emergency_trigger',
        },
      ],
    },
    enable: {
      name: 'enable',
      cli_command: 'enable',
      category: 'system',
      acl: 'write',
      description: 'enable (service/lifecycle.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    engine_apply: {
      name: 'engine_apply',
      cli_command: 'engine_apply',
      category: 'system',
      acl: 'write',
      description: 'engine-apply (service/engine_runtime.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of engine_apply',
        },
      ],
    },
    engine_diag: {
      name: 'engine_diag',
      cli_command: 'engine_diag',
      category: 'system',
      acl: 'read',
      description: 'engine-diag (service/engine_runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    engine_explain: {
      name: 'engine_explain',
      cli_command: 'engine_explain',
      category: 'system',
      acl: 'read',
      description: 'engine-explain (service/engine_runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of engine_explain',
        },
      ],
    },
    engine_features: {
      name: 'engine_features',
      cli_command: 'engine_features',
      category: 'system',
      acl: 'read',
      description: 'engine-features (service/engine_runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    engine_generate: {
      name: 'engine_generate',
      cli_command: 'engine_generate',
      category: 'system',
      acl: 'write',
      description: 'engine-generate (service/engine_runtime.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of engine_generate',
        },
      ],
    },
    engine_info: {
      name: 'engine_info',
      cli_command: 'engine_info',
      category: 'system',
      acl: 'read',
      description: 'engine-info (service/engine_runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    engine_plan: {
      name: 'engine_plan',
      cli_command: 'engine_plan',
      category: 'system',
      acl: 'read',
      description: 'engine-plan (service/engine_runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of engine_plan',
        },
      ],
    },
    engine_reload: {
      name: 'engine_reload',
      cli_command: 'engine_reload',
      category: 'system',
      acl: 'write',
      description: 'engine-reload (service/engine_runtime.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of engine_reload',
        },
      ],
    },
    engine_start: {
      name: 'engine_start',
      cli_command: 'engine_start',
      category: 'system',
      acl: 'write',
      description: 'engine-start (service/engine_runtime.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    engine_status: {
      name: 'engine_status',
      cli_command: 'engine_status',
      category: 'system',
      acl: 'read',
      description: 'engine-status (service/engine_runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    engine_stop: {
      name: 'engine_stop',
      cli_command: 'engine_stop',
      category: 'system',
      acl: 'write',
      description: 'engine-stop (service/engine_runtime.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    engine_switch: {
      name: 'engine_switch',
      cli_command: 'engine_switch',
      category: 'system',
      acl: 'write',
      description: 'engine-switch (service/engine_runtime.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of engine_switch',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of engine_switch',
        },
        {
          name: 'arg3',
          type: 'string',
          required: false,
          description: 'positional argument 3 of engine_switch',
        },
      ],
    },
    engine_switch_back: {
      name: 'engine_switch_back',
      cli_command: 'engine_switch_back',
      category: 'system',
      acl: 'write',
      description: 'engine-switch-back (service/engine_runtime.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    escalation_status: {
      name: 'escalation_status',
      cli_command: 'escalation_status',
      category: 'system',
      acl: 'read',
      description: 'escalation-status (service/watchdog.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    'event-clear': {
      name: 'event-clear',
      cli_command: 'event-clear',
      category: 'system',
      acl: 'write',
      description: 'clear (core/events.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    'event-query': {
      name: 'event-query',
      cli_command: 'event-query',
      category: 'system',
      acl: 'read',
      description: 'query (core/events.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    'event-record': {
      name: 'event-record',
      cli_command: 'event-record',
      category: 'system',
      acl: 'write',
      description: 'record (core/events.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of event-record',
        },
      ],
    },
    'event-stats': {
      name: 'event-stats',
      cli_command: 'event-stats',
      category: 'system',
      acl: 'read',
      description: 'stats (core/events.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    'event-tail': {
      name: 'event-tail',
      cli_command: 'event-tail',
      category: 'system',
      acl: 'read',
      description: 'tail (core/events.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    event_clear: {
      name: 'event_clear',
      cli_command: 'event_clear',
      category: 'system',
      acl: 'write',
      description: 'clear (core/events.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    event_query: {
      name: 'event_query',
      cli_command: 'event_query',
      category: 'system',
      acl: 'read',
      description: 'query (core/events.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    event_record: {
      name: 'event_record',
      cli_command: 'event_record',
      category: 'system',
      acl: 'write',
      description: 'record (core/events.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of event_record',
        },
      ],
    },
    event_stats: {
      name: 'event_stats',
      cli_command: 'event_stats',
      category: 'system',
      acl: 'read',
      description: 'stats (core/events.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    event_tail: {
      name: 'event_tail',
      cli_command: 'event_tail',
      category: 'system',
      acl: 'read',
      description: 'tail (core/events.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    extract_ruleset: {
      name: 'extract_ruleset',
      cli_command: 'extract_ruleset',
      category: 'diagnostics',
      acl: 'read',
      description: 'extract-ruleset (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of extract_ruleset',
        },
      ],
    },
    failover_check: {
      name: 'failover_check',
      cli_command: 'failover_check',
      category: 'system',
      acl: 'read',
      description: 'check (service/failover.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    fuzzer_ai_synthesize: {
      name: 'fuzzer_ai_synthesize',
      cli_command: 'fuzzer_ai_synthesize',
      category: 'fuzzer',
      acl: 'write',
      description: 'ai_synthesize (diagnostics/fuzzer.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of fuzzer_ai_synthesize',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of fuzzer_ai_synthesize',
        },
        {
          name: 'arg3',
          type: 'string',
          required: false,
          description: 'positional argument 3 of fuzzer_ai_synthesize',
        },
        {
          name: 'arg4',
          type: 'string',
          required: false,
          description: 'positional argument 4 of fuzzer_ai_synthesize',
        },
      ],
    },
    fuzzer_apply: {
      name: 'fuzzer_apply',
      cli_command: 'fuzzer_apply',
      category: 'fuzzer',
      acl: 'write',
      description: 'apply (diagnostics/fuzzer.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of fuzzer_apply',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of fuzzer_apply',
        },
        {
          name: 'arg3',
          type: 'string',
          required: false,
          description: 'positional argument 3 of fuzzer_apply',
        },
      ],
    },
    fuzzer_auto_apply: {
      name: 'fuzzer_auto_apply',
      cli_command: 'fuzzer_auto_apply',
      category: 'fuzzer',
      acl: 'write',
      description: 'auto_apply (diagnostics/fuzzer.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of fuzzer_auto_apply',
        },
      ],
    },
    fuzzer_clear_history: {
      name: 'fuzzer_clear_history',
      cli_command: 'fuzzer_clear_history',
      category: 'fuzzer',
      acl: 'write',
      description: 'clear_history (diagnostics/fuzzer.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    fuzzer_detect_dpi: {
      name: 'fuzzer_detect_dpi',
      cli_command: 'fuzzer_detect_dpi',
      category: 'fuzzer',
      acl: 'write',
      description: 'detect_dpi (diagnostics/fuzzer.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of fuzzer_detect_dpi',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of fuzzer_detect_dpi',
        },
      ],
    },
    fuzzer_generate: {
      name: 'fuzzer_generate',
      cli_command: 'fuzzer_generate',
      category: 'fuzzer',
      acl: 'write',
      description: 'generate (diagnostics/fuzzer.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of fuzzer_generate',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of fuzzer_generate',
        },
      ],
    },
    fuzzer_get_patterns: {
      name: 'fuzzer_get_patterns',
      cli_command: 'fuzzer_get_patterns',
      category: 'fuzzer',
      acl: 'read',
      description: 'get_patterns (diagnostics/fuzzer.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    fuzzer_history: {
      name: 'fuzzer_history',
      cli_command: 'fuzzer_history',
      category: 'fuzzer',
      acl: 'read',
      description: 'history (diagnostics/fuzzer.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of fuzzer_history',
        },
      ],
    },
    fuzzer_presets_info: {
      name: 'fuzzer_presets_info',
      cli_command: 'fuzzer_presets_info',
      category: 'fuzzer',
      acl: 'read',
      description: 'presets_info (diagnostics/fuzzer.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    fuzzer_reset_patterns: {
      name: 'fuzzer_reset_patterns',
      cli_command: 'fuzzer_reset_patterns',
      category: 'fuzzer',
      acl: 'write',
      description: 'reset_patterns (diagnostics/fuzzer.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    fuzzer_save_patterns: {
      name: 'fuzzer_save_patterns',
      cli_command: 'fuzzer_save_patterns',
      category: 'fuzzer',
      acl: 'write',
      description: 'save_patterns (diagnostics/fuzzer.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of fuzzer_save_patterns',
        },
      ],
    },
    fuzzer_start: {
      name: 'fuzzer_start',
      cli_command: 'fuzzer_start',
      category: 'fuzzer',
      acl: 'write',
      description: 'start (diagnostics/fuzzer.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of fuzzer_start',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of fuzzer_start',
        },
        {
          name: 'arg3',
          type: 'string',
          required: false,
          description: 'positional argument 3 of fuzzer_start',
        },
        {
          name: 'arg4',
          type: 'string',
          required: false,
          description: 'positional argument 4 of fuzzer_start',
        },
        {
          name: 'arg5',
          type: 'string',
          required: false,
          description: 'positional argument 5 of fuzzer_start',
        },
        {
          name: 'arg6',
          type: 'string',
          required: false,
          description: 'positional argument 6 of fuzzer_start',
        },
        {
          name: 'arg7',
          type: 'string',
          required: false,
          description: 'positional argument 7 of fuzzer_start',
        },
      ],
    },
    fuzzer_status: {
      name: 'fuzzer_status',
      cli_command: 'fuzzer_status',
      category: 'fuzzer',
      acl: 'read',
      description: 'status (diagnostics/fuzzer.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    fuzzer_stop: {
      name: 'fuzzer_stop',
      cli_command: 'fuzzer_stop',
      category: 'fuzzer',
      acl: 'write',
      description: 'stop (diagnostics/fuzzer.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    fuzzer_strategies: {
      name: 'fuzzer_strategies',
      cli_command: 'fuzzer_strategies',
      category: 'fuzzer',
      acl: 'read',
      description: 'strategies (diagnostics/fuzzer.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of fuzzer_strategies',
        },
      ],
    },
    fuzzer_update_presets: {
      name: 'fuzzer_update_presets',
      cli_command: 'fuzzer_update_presets',
      category: 'fuzzer',
      acl: 'write',
      description: 'update_presets (diagnostics/fuzzer.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    generate_reality_keypair: {
      name: 'generate_reality_keypair',
      cli_command: 'generate_reality_keypair',
      category: 'system',
      acl: 'write',
      description: 'generate-reality-keypair (server/service.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    generate_warp: {
      name: 'generate_warp',
      cli_command: 'generate_warp',
      category: 'system',
      acl: 'write',
      description: ' (service/warp_generator.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of generate_warp',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of generate_warp',
        },
      ],
    },
    get_byedpi_status: {
      name: 'get_byedpi_status',
      cli_command: 'get_byedpi_status',
      category: 'diagnostics',
      acl: 'read',
      description: 'get-byedpi-status (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    get_engine_status: {
      name: 'get_engine_status',
      cli_command: 'get_engine_status',
      category: 'diagnostics',
      acl: 'read',
      description: 'get-engine-status (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    get_fptn_status: {
      name: 'get_fptn_status',
      cli_command: 'get_fptn_status',
      category: 'diagnostics',
      acl: 'read',
      description: 'get-fptn-status (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    get_olcrtc_status: {
      name: 'get_olcrtc_status',
      cli_command: 'get_olcrtc_status',
      category: 'diagnostics',
      acl: 'read',
      description: 'get-olcrtc-status (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    get_outbound_metadata: {
      name: 'get_outbound_metadata',
      cli_command: 'get_outbound_metadata',
      category: 'diagnostics',
      acl: 'read',
      description: 'get-outbound-metadata (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of get_outbound_metadata',
        },
      ],
    },
    get_server_capabilities: {
      name: 'get_server_capabilities',
      cli_command: 'get_server_capabilities',
      category: 'diagnostics',
      acl: 'read',
      description: 'get-server-capabilities (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    get_sing_box_status: {
      name: 'get_sing_box_status',
      cli_command: 'get_sing_box_status',
      category: 'diagnostics',
      acl: 'read',
      description: 'get-sing-box-status (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    get_status: {
      name: 'get_status',
      cli_command: 'get_status',
      category: 'diagnostics',
      acl: 'read',
      description: 'get-status (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    get_subscription_metadata: {
      name: 'get_subscription_metadata',
      cli_command: 'get_subscription_metadata',
      category: 'diagnostics',
      acl: 'read',
      description: 'get-subscription-metadata (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of get_subscription_metadata',
        },
      ],
    },
    get_system_info: {
      name: 'get_system_info',
      cli_command: 'get_system_info',
      category: 'diagnostics',
      acl: 'read',
      description: 'get-system-info (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    get_tailscale_peers: {
      name: 'get_tailscale_peers',
      cli_command: 'get_tailscale_peers',
      category: 'diagnostics',
      acl: 'read',
      description: 'get-tailscale-peers (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    get_tailscale_status: {
      name: 'get_tailscale_status',
      cli_command: 'get_tailscale_status',
      category: 'diagnostics',
      acl: 'read',
      description: 'get-tailscale-status (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    get_tls_certificate_sha256: {
      name: 'get_tls_certificate_sha256',
      cli_command: 'get_tls_certificate_sha256',
      category: 'system',
      acl: 'read',
      description: 'tls-certificate-sha256 (server/service.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of get_tls_certificate_sha256',
        },
      ],
    },
    get_ui_capabilities: {
      name: 'get_ui_capabilities',
      cli_command: 'get_ui_capabilities',
      category: 'system',
      acl: 'read',
      description: 'get-ui-capabilities (service/ui.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    get_ui_state: {
      name: 'get_ui_state',
      cli_command: 'get_ui_state',
      category: 'system',
      acl: 'read',
      description: 'get-ui-state (service/ui.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    get_wdtt_status: {
      name: 'get_wdtt_status',
      cli_command: 'get_wdtt_status',
      category: 'diagnostics',
      acl: 'read',
      description: 'get-wdtt-status (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    get_zapret2_status: {
      name: 'get_zapret2_status',
      cli_command: 'get_zapret2_status',
      category: 'diagnostics',
      acl: 'read',
      description: 'get-zapret2-status (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    get_zapret_status: {
      name: 'get_zapret_status',
      cli_command: 'get_zapret_status',
      category: 'diagnostics',
      acl: 'read',
      description: 'get-zapret-status (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    global_check: {
      name: 'global_check',
      cli_command: 'global_check',
      category: 'diagnostics',
      acl: 'read',
      description: 'global-check (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of global_check',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of global_check',
        },
      ],
    },
    hosts_list_status: {
      name: 'hosts_list_status',
      cli_command: 'hosts_list_status',
      category: 'system',
      acl: 'read',
      description: 'list-status (components/hosts.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    hosts_list_update: {
      name: 'hosts_list_update',
      cli_command: 'hosts_list_update',
      category: 'system',
      acl: 'write',
      description: 'list-update (components/hosts.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of hosts_list_update',
        },
      ],
    },
    'import-settings': {
      name: 'import-settings',
      cli_command: 'import-settings',
      category: 'system',
      acl: 'write',
      description: 'import-settings (config/migration.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of import-settings',
        },
      ],
    },
    import_settings: {
      name: 'import_settings',
      cli_command: 'import_settings',
      category: 'system',
      acl: 'write',
      description: 'import-settings (config/migration.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of import_settings',
        },
      ],
    },
    install_tor: {
      name: 'install_tor',
      cli_command: 'install_tor',
      category: 'diagnostics',
      acl: 'write',
      description: 'install-tor (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    'job-cancel': {
      name: 'job-cancel',
      cli_command: 'job-cancel',
      category: 'system',
      acl: 'write',
      description: 'cancel (core/jobs.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of job-cancel',
        },
      ],
    },
    'job-gc': {
      name: 'job-gc',
      cli_command: 'job-gc',
      category: 'system',
      acl: 'write',
      description: 'gc (core/jobs.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    'job-list': {
      name: 'job-list',
      cli_command: 'job-list',
      category: 'system',
      acl: 'read',
      description: 'list (core/jobs.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    'job-query': {
      name: 'job-query',
      cli_command: 'job-query',
      category: 'system',
      acl: 'read',
      description: 'query (core/jobs.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of job-query',
        },
      ],
    },
    'job-request-cancel': {
      name: 'job-request-cancel',
      cli_command: 'job-request-cancel',
      category: 'system',
      acl: 'write',
      description: 'request-cancel (core/jobs.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of job-request-cancel',
        },
      ],
    },
    job_cancel: {
      name: 'job_cancel',
      cli_command: 'job_cancel',
      category: 'system',
      acl: 'write',
      description: 'cancel (core/jobs.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of job_cancel',
        },
      ],
    },
    job_gc: {
      name: 'job_gc',
      cli_command: 'job_gc',
      category: 'system',
      acl: 'write',
      description: 'gc (core/jobs.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    job_list: {
      name: 'job_list',
      cli_command: 'job_list',
      category: 'system',
      acl: 'read',
      description: 'list (core/jobs.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    job_query: {
      name: 'job_query',
      cli_command: 'job_query',
      category: 'system',
      acl: 'read',
      description: 'query (core/jobs.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of job_query',
        },
      ],
    },
    job_request_cancel: {
      name: 'job_request_cancel',
      cli_command: 'job_request_cancel',
      category: 'system',
      acl: 'write',
      description: 'request-cancel (core/jobs.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of job_request_cancel',
        },
      ],
    },
    'known-good': {
      name: 'known-good',
      cli_command: 'known-good',
      category: 'known_good',
      acl: 'read',
      description: 'status (service/known_good.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of known-good',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of known-good',
        },
      ],
    },
    'known-good-check': {
      name: 'known-good-check',
      cli_command: 'known-good-check',
      category: 'known_good',
      acl: 'read',
      description: 'check (service/known_good.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    'known-good-promote': {
      name: 'known-good-promote',
      cli_command: 'known-good-promote',
      category: 'known_good',
      acl: 'write',
      description: 'promote (service/known_good.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of known-good-promote',
        },
      ],
    },
    'known-good-restore': {
      name: 'known-good-restore',
      cli_command: 'known-good-restore',
      category: 'known_good',
      acl: 'write',
      description: 'restore (service/known_good.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of known-good-restore',
        },
      ],
    },
    'known-good-rollback': {
      name: 'known-good-rollback',
      cli_command: 'known-good-rollback',
      category: 'known_good',
      acl: 'write',
      description: 'rollback (service/known_good.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of known-good-rollback',
        },
      ],
    },
    'known-good-status': {
      name: 'known-good-status',
      cli_command: 'known-good-status',
      category: 'known_good',
      acl: 'read',
      description: 'status (service/known_good.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of known-good-status',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of known-good-status',
        },
      ],
    },
    known_good: {
      name: 'known_good',
      cli_command: 'known_good',
      category: 'known_good',
      acl: 'read',
      description: 'status (service/known_good.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of known_good',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of known_good',
        },
      ],
    },
    known_good_check: {
      name: 'known_good_check',
      cli_command: 'known_good_check',
      category: 'known_good',
      acl: 'read',
      description: 'check (service/known_good.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    known_good_promote: {
      name: 'known_good_promote',
      cli_command: 'known_good_promote',
      category: 'known_good',
      acl: 'write',
      description: 'promote (service/known_good.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of known_good_promote',
        },
      ],
    },
    known_good_restore: {
      name: 'known_good_restore',
      cli_command: 'known_good_restore',
      category: 'known_good',
      acl: 'write',
      description: 'restore (service/known_good.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of known_good_restore',
        },
      ],
    },
    known_good_rollback: {
      name: 'known_good_rollback',
      cli_command: 'known_good_rollback',
      category: 'known_good',
      acl: 'write',
      description: 'rollback (service/known_good.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of known_good_rollback',
        },
      ],
    },
    known_good_status: {
      name: 'known_good_status',
      cli_command: 'known_good_status',
      category: 'known_good',
      acl: 'read',
      description: 'status (service/known_good.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of known_good_status',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of known_good_status',
        },
      ],
    },
    lan_clients: {
      name: 'lan_clients',
      cli_command: 'lan_clients',
      category: 'diagnostics',
      acl: 'read',
      description: 'lan-clients (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    latency_test_async: {
      name: 'latency_test_async',
      cli_command: 'latency_test_async',
      category: 'system',
      acl: 'write',
      description: 'latency-test-async (service/ui.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of latency_test_async',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of latency_test_async',
        },
        {
          name: 'arg3',
          type: 'string',
          required: false,
          description: 'positional argument 3 of latency_test_async',
        },
        {
          name: 'arg4',
          type: 'string',
          required: false,
          description: 'positional argument 4 of latency_test_async',
        },
      ],
    },
    latency_test_status: {
      name: 'latency_test_status',
      cli_command: 'latency_test_status',
      category: 'system',
      acl: 'read',
      description: 'latency-test-status (service/ui.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of latency_test_status',
        },
      ],
    },
    leak_check: {
      name: 'leak_check',
      cli_command: 'leak_check',
      category: 'diagnostics',
      acl: 'read',
      description: 'leak-check (diagnostics/leak_check.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of leak_check',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of leak_check',
        },
      ],
    },
    leak_check_async: {
      name: 'leak_check_async',
      cli_command: 'leak_check_async',
      category: 'diagnostics',
      acl: 'write',
      description: 'leak-check-async (diagnostics/leak_check.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of leak_check_async',
        },
      ],
    },
    leak_check_status: {
      name: 'leak_check_status',
      cli_command: 'leak_check_status',
      category: 'diagnostics',
      acl: 'write',
      description: 'leak-check-status (diagnostics/leak_check.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of leak_check_status',
        },
      ],
    },
    list_update: {
      name: 'list_update',
      cli_command: 'list_update',
      category: 'updates',
      acl: 'write',
      description: 'list-update (components/updates.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    list_update_async: {
      name: 'list_update_async',
      cli_command: 'list_update_async',
      category: 'updates',
      acl: 'write',
      description: 'list-update-async (components/updates.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    list_update_if_due: {
      name: 'list_update_if_due',
      cli_command: 'list_update_if_due',
      category: 'updates',
      acl: 'write',
      description: 'list-update-if-due (components/updates.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    list_update_status: {
      name: 'list_update_status',
      cli_command: 'list_update_status',
      category: 'updates',
      acl: 'read',
      description: 'list-update-status (components/updates.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    luci_postinst: {
      name: 'luci_postinst',
      cli_command: 'luci_postinst',
      category: 'system',
      acl: 'write',
      description: 'luci-postinst (service/package.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    main: {
      name: 'main',
      cli_command: 'main',
      category: 'system',
      acl: 'write',
      description: 'main (service/lifecycle.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    mcp: {
      name: 'mcp',
      cli_command: 'mcp',
      category: 'ai',
      acl: 'write',
      description: ' (service/agent_mcp.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    neutralize_zapret_defaults: {
      name: 'neutralize_zapret_defaults',
      cli_command: 'neutralize_zapret_defaults',
      category: 'diagnostics',
      acl: 'write',
      description: 'neutralize-zapret-defaults (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    package_postinst: {
      name: 'package_postinst',
      cli_command: 'package_postinst',
      category: 'system',
      acl: 'write',
      description: 'postinst (service/package.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    package_prerm: {
      name: 'package_prerm',
      cli_command: 'package_prerm',
      category: 'system',
      acl: 'write',
      description: 'prerm (service/package.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of package_prerm',
        },
      ],
    },
    parental_quota_reset: {
      name: 'parental_quota_reset',
      cli_command: 'parental_quota_reset',
      category: 'system',
      acl: 'write',
      description: 'reset (service/parental_quota.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    parental_quota_tick: {
      name: 'parental_quota_tick',
      cli_command: 'parental_quota_tick',
      category: 'system',
      acl: 'write',
      description: 'tick (service/parental_quota.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    reconcile: {
      name: 'reconcile',
      cli_command: 'reconcile',
      category: 'system',
      acl: 'write',
      description: 'apply (service/reconciler.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    reconcile_plan: {
      name: 'reconcile_plan',
      cli_command: 'reconcile_plan',
      category: 'system',
      acl: 'write',
      description: 'plan (service/reconciler.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    reconcile_status: {
      name: 'reconcile_status',
      cli_command: 'reconcile_status',
      category: 'system',
      acl: 'read',
      description: 'status (service/reconciler.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    reload: {
      name: 'reload',
      cli_command: 'reload',
      category: 'system',
      acl: 'write',
      description: 'reload (service/lifecycle.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of reload',
        },
      ],
    },
    reload_firewall: {
      name: 'reload_firewall',
      cli_command: 'reload_firewall',
      category: 'system',
      acl: 'write',
      description: 'reload-firewall (service/lifecycle.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    reset_settings: {
      name: 'reset_settings',
      cli_command: 'reset_settings',
      category: 'system',
      acl: 'write',
      description: 'reset-settings (service/reset.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of reset_settings',
        },
      ],
    },
    'resolve-domain': {
      name: 'resolve-domain',
      cli_command: 'resolve-domain',
      category: 'diagnostics',
      acl: 'read',
      description: 'resolve-domain (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of resolve-domain',
        },
      ],
    },
    resolve_domain: {
      name: 'resolve_domain',
      cli_command: 'resolve_domain',
      category: 'diagnostics',
      acl: 'read',
      description: 'resolve-domain (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of resolve_domain',
        },
      ],
    },
    restart: {
      name: 'restart',
      cli_command: 'restart',
      category: 'system',
      acl: 'write',
      description: 'restart (service/lifecycle.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    restore_dnsmasq: {
      name: 'restore_dnsmasq',
      cli_command: 'restore_dnsmasq',
      category: 'system',
      acl: 'write',
      description: 'dnsmasq-restore (service/lifecycle.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    'route-explain': {
      name: 'route-explain',
      cli_command: 'route-explain',
      category: 'system',
      acl: 'read',
      description: 'explain (diagnostics/route_explain.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of route-explain',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of route-explain',
        },
        {
          name: 'arg3',
          type: 'string',
          required: false,
          description: 'positional argument 3 of route-explain',
        },
        {
          name: 'arg4',
          type: 'string',
          required: false,
          description: 'positional argument 4 of route-explain',
        },
      ],
    },
    route_explain: {
      name: 'route_explain',
      cli_command: 'route_explain',
      category: 'system',
      acl: 'read',
      description: 'explain (diagnostics/route_explain.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of route_explain',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of route_explain',
        },
        {
          name: 'arg3',
          type: 'string',
          required: false,
          description: 'positional argument 3 of route_explain',
        },
        {
          name: 'arg4',
          type: 'string',
          required: false,
          description: 'positional argument 4 of route_explain',
        },
      ],
    },
    'server-best': {
      name: 'server-best',
      cli_command: 'server-best',
      category: 'system',
      acl: 'read',
      description: 'best (diagnostics/server_stats.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of server-best',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of server-best',
        },
      ],
    },
    'server-probe': {
      name: 'server-probe',
      cli_command: 'server-probe',
      category: 'system',
      acl: 'read',
      description: 'probe (diagnostics/server_stats.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of server-probe',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of server-probe',
        },
      ],
    },
    'server-probe-all': {
      name: 'server-probe-all',
      cli_command: 'server-probe-all',
      category: 'system',
      acl: 'read',
      description: 'probe_all (diagnostics/server_stats.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of server-probe-all',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of server-probe-all',
        },
      ],
    },
    'server-query': {
      name: 'server-query',
      cli_command: 'server-query',
      category: 'system',
      acl: 'read',
      description: 'query (diagnostics/server_stats.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of server-query',
        },
      ],
    },
    'server-stats': {
      name: 'server-stats',
      cli_command: 'server-stats',
      category: 'system',
      acl: 'read',
      description: 'summary (diagnostics/server_stats.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    'server-stats-reset': {
      name: 'server-stats-reset',
      cli_command: 'server-stats-reset',
      category: 'system',
      acl: 'write',
      description: 'reset (diagnostics/server_stats.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    server_best: {
      name: 'server_best',
      cli_command: 'server_best',
      category: 'system',
      acl: 'read',
      description: 'best (diagnostics/server_stats.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of server_best',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of server_best',
        },
      ],
    },
    server_probe: {
      name: 'server_probe',
      cli_command: 'server_probe',
      category: 'system',
      acl: 'read',
      description: 'probe (diagnostics/server_stats.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of server_probe',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of server_probe',
        },
      ],
    },
    server_probe_all: {
      name: 'server_probe_all',
      cli_command: 'server_probe_all',
      category: 'system',
      acl: 'read',
      description: 'probe_all (diagnostics/server_stats.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of server_probe_all',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of server_probe_all',
        },
      ],
    },
    server_query: {
      name: 'server_query',
      cli_command: 'server_query',
      category: 'system',
      acl: 'read',
      description: 'query (diagnostics/server_stats.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of server_query',
        },
      ],
    },
    server_stats: {
      name: 'server_stats',
      cli_command: 'server_stats',
      category: 'system',
      acl: 'read',
      description: 'summary (diagnostics/server_stats.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    server_stats_reset: {
      name: 'server_stats_reset',
      cli_command: 'server_stats_reset',
      category: 'system',
      acl: 'write',
      description: 'reset (diagnostics/server_stats.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    service_action_async: {
      name: 'service_action_async',
      cli_command: 'service_action_async',
      category: 'system',
      acl: 'write',
      description: 'service-action-async (service/ui.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of service_action_async',
        },
      ],
    },
    service_action_status: {
      name: 'service_action_status',
      cli_command: 'service_action_status',
      category: 'system',
      acl: 'read',
      description: 'service-action-status (service/ui.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of service_action_status',
        },
      ],
    },
    service_health_check: {
      name: 'service_health_check',
      cli_command: 'service_health_check',
      category: 'diagnostics',
      acl: 'read',
      description: 'service-health-check (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of service_health_check',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of service_health_check',
        },
      ],
    },
    show_config: {
      name: 'show_config',
      cli_command: 'show_config',
      category: 'diagnostics',
      acl: 'read',
      description: 'show-config (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of show_config',
        },
      ],
    },
    show_sing_box_config: {
      name: 'show_sing_box_config',
      cli_command: 'show_sing_box_config',
      category: 'diagnostics',
      acl: 'read',
      description: 'show-sing-box-config (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of show_sing_box_config',
        },
      ],
    },
    show_sing_box_version: {
      name: 'show_sing_box_version',
      cli_command: 'show_sing_box_version',
      category: 'diagnostics',
      acl: 'read',
      description: 'show-sing-box-version (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    show_version: {
      name: 'show_version',
      cli_command: 'show_version',
      category: 'diagnostics',
      acl: 'read',
      description: 'show-version (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    snapshot_delete: {
      name: 'snapshot_delete',
      cli_command: 'snapshot_delete',
      category: 'system',
      acl: 'write',
      description: 'snapshot-delete (service/snapshot.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of snapshot_delete',
        },
      ],
    },
    snapshot_list: {
      name: 'snapshot_list',
      cli_command: 'snapshot_list',
      category: 'system',
      acl: 'read',
      description: 'snapshot-list (service/snapshot.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    snapshot_restore: {
      name: 'snapshot_restore',
      cli_command: 'snapshot_restore',
      category: 'system',
      acl: 'write',
      description: 'snapshot-restore (service/snapshot.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of snapshot_restore',
        },
      ],
    },
    snapshot_save: {
      name: 'snapshot_save',
      cli_command: 'snapshot_save',
      category: 'system',
      acl: 'write',
      description: 'snapshot-save (service/snapshot.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of snapshot_save',
        },
      ],
    },
    'stability-report': {
      name: 'stability-report',
      cli_command: 'stability-report',
      category: 'stability',
      acl: 'read',
      description: 'report (diagnostics/stability.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    'stability-status': {
      name: 'stability-status',
      cli_command: 'stability-status',
      category: 'stability',
      acl: 'read',
      description: 'status (diagnostics/stability.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    stability_report: {
      name: 'stability_report',
      cli_command: 'stability_report',
      category: 'stability',
      acl: 'read',
      description: 'report (diagnostics/stability.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    stability_status: {
      name: 'stability_status',
      cli_command: 'stability_status',
      category: 'stability',
      acl: 'read',
      description: 'status (diagnostics/stability.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    start: {
      name: 'start',
      cli_command: 'start',
      category: 'system',
      acl: 'write',
      description: 'start (service/lifecycle.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    stop: {
      name: 'stop',
      cli_command: 'stop',
      category: 'system',
      acl: 'write',
      description: 'stop (service/lifecycle.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    subscription_update: {
      name: 'subscription_update',
      cli_command: 'subscription_update',
      category: 'updates',
      acl: 'write',
      description: 'subscription-update (components/updates.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of subscription_update',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of subscription_update',
        },
      ],
    },
    subscription_update_async: {
      name: 'subscription_update_async',
      cli_command: 'subscription_update_async',
      category: 'updates',
      acl: 'write',
      description: 'subscription-update-async (components/updates.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of subscription_update_async',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of subscription_update_async',
        },
      ],
    },
    subscription_update_if_due: {
      name: 'subscription_update_if_due',
      cli_command: 'subscription_update_if_due',
      category: 'updates',
      acl: 'write',
      description: 'subscription-update-if-due (components/updates.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    subscription_update_status: {
      name: 'subscription_update_status',
      cli_command: 'subscription_update_status',
      category: 'updates',
      acl: 'read',
      description: 'subscription-update-status (components/updates.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of subscription_update_status',
        },
      ],
    },
    'support-bundle': {
      name: 'support-bundle',
      cli_command: 'support-bundle',
      category: 'system',
      acl: 'read',
      description: 'create (service/support_bundle.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of support-bundle',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of support-bundle',
        },
        {
          name: 'arg3',
          type: 'string',
          required: false,
          description: 'positional argument 3 of support-bundle',
        },
      ],
    },
    support_bundle: {
      name: 'support_bundle',
      cli_command: 'support_bundle',
      category: 'system',
      acl: 'read',
      description: 'create (service/support_bundle.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of support_bundle',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of support_bundle',
        },
        {
          name: 'arg3',
          type: 'string',
          required: false,
          description: 'positional argument 3 of support_bundle',
        },
      ],
    },
    tailscale_restart: {
      name: 'tailscale_restart',
      cli_command: 'tailscale_restart',
      category: 'system',
      acl: 'write',
      description: 'start-runtime (providers/tailscale/runtime.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    telegram: {
      name: 'telegram',
      cli_command: 'telegram',
      category: 'telegram',
      acl: 'write',
      description: ' (service/telegram.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of telegram',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of telegram',
        },
      ],
    },
    telegram_diagnose: {
      name: 'telegram_diagnose',
      cli_command: 'telegram_diagnose',
      category: 'telegram',
      acl: 'read',
      description: 'diagnose (service/telegram.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    telegram_start: {
      name: 'telegram_start',
      cli_command: 'telegram_start',
      category: 'telegram',
      acl: 'write',
      description: 'start-runtime (service/telegram.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    telegram_status: {
      name: 'telegram_status',
      cli_command: 'telegram_status',
      category: 'telegram',
      acl: 'read',
      description: 'status (service/telegram.uc)',
      async: false,
      timeout_ms: 5000,
      params: [],
    },
    telegram_stop: {
      name: 'telegram_stop',
      cli_command: 'telegram_stop',
      category: 'telegram',
      acl: 'write',
      description: 'stop-runtime (service/telegram.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    toggle_client_bypass: {
      name: 'toggle_client_bypass',
      cli_command: 'toggle_client_bypass',
      category: 'diagnostics',
      acl: 'write',
      description: 'toggle-client-bypass (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of toggle_client_bypass',
        },
      ],
    },
    ui_action_ack: {
      name: 'ui_action_ack',
      cli_command: 'ui_action_ack',
      category: 'system',
      acl: 'write',
      description: 'action-ack (service/ui.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of ui_action_ack',
        },
        {
          name: 'arg2',
          type: 'string',
          required: false,
          description: 'positional argument 2 of ui_action_ack',
        },
      ],
    },
    uninstall: {
      name: 'uninstall',
      cli_command: 'uninstall',
      category: 'system',
      acl: 'write',
      description: 'uninstall (service/uninstall.uc)',
      async: false,
      timeout_ms: 60000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of uninstall',
        },
      ],
    },
    validate_byedpi_strategy_json: {
      name: 'validate_byedpi_strategy_json',
      cli_command: 'validate_byedpi_strategy_json',
      category: 'diagnostics',
      acl: 'read',
      description: 'validate-byedpi-strategy-json (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of validate_byedpi_strategy_json',
        },
      ],
    },
    validate_nfqws2_strategy_json: {
      name: 'validate_nfqws2_strategy_json',
      cli_command: 'validate_nfqws2_strategy_json',
      category: 'diagnostics',
      acl: 'read',
      description: 'validate-nfqws2-strategy-json (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of validate_nfqws2_strategy_json',
        },
      ],
    },
    validate_nfqws_strategy_json: {
      name: 'validate_nfqws_strategy_json',
      cli_command: 'validate_nfqws_strategy_json',
      category: 'diagnostics',
      acl: 'read',
      description: 'validate-nfqws-strategy-json (diagnostics/runtime.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of validate_nfqws_strategy_json',
        },
      ],
    },
    watchdog: {
      name: 'watchdog',
      cli_command: 'watchdog',
      category: 'system',
      acl: 'read',
      description: ' (service/watchdog.uc)',
      async: false,
      timeout_ms: 5000,
      params: [
        {
          name: 'arg1',
          type: 'string',
          required: false,
          description: 'positional argument 1 of watchdog',
        },
      ],
    },
    watchdog_start: {
      name: 'watchdog_start',
      cli_command: 'watchdog_start',
      category: 'system',
      acl: 'write',
      description: 'start-runtime (service/watchdog.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
    },
    watchdog_stop: {
      name: 'watchdog_stop',
      cli_command: 'watchdog_stop',
      category: 'system',
      acl: 'write',
      description: 'stop-runtime (service/watchdog.uc)',
      async: false,
      timeout_ms: 60000,
      params: [],
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
  const pObj =
    params && typeof params === 'object'
      ? (params as Record<string, unknown>)
      : {};

  for (const p of meta.params) {
    const val = pObj[p.name];
    if (p.required && (val === undefined || val === null || val === '')) {
      errors.push(`Missing required parameter '${p.name}' for RPC '${method}'`);
      continue;
    }
    if (val !== undefined && val !== null) {
      if (p.type === 'string' && typeof val !== 'string') {
        errors.push(
          `Parameter '${p.name}' must be a string, got ${typeof val}`,
        );
      } else if (p.type === 'number' && typeof val !== 'number') {
        errors.push(
          `Parameter '${p.name}' must be a number, got ${typeof val}`,
        );
      } else if (p.type === 'boolean' && typeof val !== 'boolean') {
        errors.push(
          `Parameter '${p.name}' must be a boolean, got ${typeof val}`,
        );
      } else if (p.type === 'array' && !Array.isArray(val)) {
        errors.push(`Parameter '${p.name}' must be an array`);
      } else if (
        p.type === 'object' &&
        (typeof val !== 'object' || Array.isArray(val))
      ) {
        errors.push(`Parameter '${p.name}' must be an object`);
      }
      if (p.enum && typeof val === 'string' && !p.enum.includes(val)) {
        errors.push(
          `Parameter '${p.name}' value '${val}' is not in allowed enum: ${p.enum.join(', ')}`,
        );
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
    if (desc.type === 'boolean') {
      if (val === true) {
        args.push(`--${desc.name}`);
      }
    } else if (desc.type === 'object') {
      args.push(JSON.stringify(val));
    } else {
      args.push(String(val));
    }
  }

  return args;
}
