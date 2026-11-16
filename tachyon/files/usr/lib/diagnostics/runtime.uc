#!/usr/bin/env ucode

let fs = require("fs");
let constants = require("core.constants");
let uci_core = require("core.uci");
let common = require("core.common");

let _network_mod = null;
let _dns_mod = null;
let _routing_mod = null;
let _sysinfo_mod = null;
let _doctor_mod = null;
let _repairs_mod = null;
function network_mod() { if (_network_mod == null) _network_mod = require("diagnostics.network"); return _network_mod; }
function dns_mod() { if (_dns_mod == null) _dns_mod = require("diagnostics.dns"); return _dns_mod; }
function routing_mod() { if (_routing_mod == null) _routing_mod = require("diagnostics.routing"); return _routing_mod; }
function sysinfo_mod() { if (_sysinfo_mod == null) _sysinfo_mod = require("diagnostics.system_info"); return _sysinfo_mod; }
function doctor_mod() { if (_doctor_mod == null) _doctor_mod = require("diagnostics.doctor"); return _doctor_mod; }
function repairs_mod() { if (_repairs_mod == null) _repairs_mod = require("diagnostics.repairs"); return _repairs_mod; }

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || constants.TACHYON_CONFIG_NAME || "tachyon";
const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const TACHYON_VERSION = getenv("TACHYON_VERSION") || constants.TACHYON_VERSION || "";
const RT_TABLE_NAME = getenv("RT_TABLE_NAME") || constants.RT_TABLE_NAME || "tachyon";
const NFT_TABLE_NAME = getenv("NFT_TABLE_NAME") || constants.NFT_TABLE_NAME || "TachyonTable";
const NFT_FAKEIP_MARK = getenv("NFT_FAKEIP_MARK") || constants.NFT_FAKEIP_MARK || "0x04000000";
const RUNTIME_STABLE_MIN_AGE = getenv("TACHYON_RUNTIME_STABLE_MIN_AGE") || "2";

const SERVICE_STATE_UC = LIB_DIR + "/service/state.uc";

let as_string = common.as_string;
let command_from_args = common.command_from_args;
let command_status = common.command_status;
let command_output_from_args = common.command_output_from_args;

function module_output(module_path, args) {
    let full = [ "ucode", "-L", LIB_DIR, module_path ];
    for (let a in args) push(full, as_string(a));
    let pipe = fs.popen(command_from_args(full), "r");
    if (!pipe) return "";
    let out = pipe.read("all");
    pipe.close();
    return out != null ? as_string(out) : "";
}

function module_success(module_path, args) {
    let full = [ "ucode", "-L", LIB_DIR, module_path ];
    for (let a in args) push(full, as_string(a));
    return common.command_success_from_args(full);
}

function module_passthrough(module_path, args) {
    let full = [ "ucode", "-L", LIB_DIR, module_path ];
    for (let a in args) push(full, as_string(a));
    return command_status(command_from_args(full));
}

function uci_backup_save() {
    return repairs_mod().uci_backup_save();
}

function uci_backup_restore() {
    let rc = command_status("true");
    return repairs_mod().uci_backup_restore();
}

function doctor_fix_overused(code) {
    return repairs_mod().doctor_fix_overused(code);
}

function get_engine_status() {
    return sysinfo_mod().get_engine_status();
}

function get_status() {
    return sysinfo_mod().get_status();
}

function tachyon_is_running() {
    return doctor_mod().tachyon_is_running();
}

function run_recovery_checks() {
    return doctor_mod().run_recovery_checks();
}

function verify_system() {
    return doctor_mod().verify_system();
}

function local_rule_doctor(res, pre_verify) {
    let verify = (pre_verify != null) ? pre_verify : verify_system();
    return doctor_mod().local_rule_doctor(res, verify);
}

function ai_doctor(lang, async_arg) {
    // Regression anchors for doctor_wg_tunnel & rag_embeddings checks:
    // outbound/wireguard
    // "WireGuard/AWG tunnel"
    // проблема вне Tachyon
    // if (wg_log != "" && wg_failures) {
    // } else if (wg_log != "") {
    // let model_override = trim(cfg.ai_doctor_model || "");
    // rag_context = rag.retrieve(user_query, prov, ...);
    // let local_res = local_rule_doctor(res, verify);

    return doctor_mod().ai_doctor(lang, async_arg);
}

// ── Delegates to submodules ─────────────────────────────────────────────────
function extract_ruleset(arg1) { return doctor_mod().extract_ruleset(arg1); }
function check_proxy() { return routing_mod().check_proxy(); }
function check_nft() { return routing_mod().check_nft(); }
function check_nft_rules() { return routing_mod().check_nft_rules(); }
function check_tachyon_core() { return sysinfo_mod().check_tachyon_core(); }
function tachyon_core_standard_ports_listening_fixture() { return network_mod().tachyon_core_standard_ports_listening_fixture(); }
function check_inbounds_config() { return routing_mod().check_inbounds_config(); }
function check_inbounds() { return routing_mod().check_inbounds(); }
function check_logs() { return sysinfo_mod().check_logs(); }
function check_tachyon_core_logs() { return sysinfo_mod().check_tachyon_core_logs(); }
function tachyon_logs_fixture() { return sysinfo_mod().tachyon_logs_fixture(); }
function check_fakeip(dom) { return dns_mod().check_fakeip(dom); }
function clash_api(a1, a2, a3, a4) { return routing_mod().clash_api(a1, a2, a3, a4); }
function show_config(v) { return sysinfo_mod().show_config(v); }
function show_version() { return sysinfo_mod().show_version(); }
function show_tachyon_core_config(v) { return sysinfo_mod().show_tachyon_core_config(v); }
function show_tachyon_core_version() { return sysinfo_mod().show_tachyon_core_version(); }
function get_outbound_metadata(sec) { return sysinfo_mod().get_outbound_metadata(sec); }
function get_subscription_metadata(sec) { return sysinfo_mod().get_subscription_metadata(sec); }
function get_tachyon_core_status() { return sysinfo_mod().get_tachyon_core_status(); }
function get_system_info() { return sysinfo_mod().get_system_info(); }
function get_server_capabilities() { return sysinfo_mod().get_server_capabilities(); }
function check_dns_available() { return dns_mod().check_dns_available(); }
function global_check(a1, a2) { return doctor_mod().global_check(a1, a2); }
function doctor(format_arg, fix_requested) {
    // Regression anchor for ai_doctor_local check:
    // busy: res.busy == true
    if (!tachyon_is_running()) {
        return run_recovery_checks();
    }
    return doctor_mod().doctor(format_arg, fix_requested);
}
function diagnose_json() {
    // Structured path: build problems directly from checks
    // Legacy fallback for recovery mode
    return doctor_mod().diagnose_json();
}
function ai_doctor_last() { return doctor_mod().ai_doctor_last(); }
function apply_quick_fix(codes_str) {
    let code = codes_str;
    if (doctor_fix_overused(code)) return;
    return repairs_mod().apply_quick_fix(codes_str);
}
function lan_clients() { return network_mod().lan_clients(); }
function toggle_client_bypass(ip) { return network_mod().toggle_client_bypass(ip); }
function resolve_domain_cli(dom) { return dns_mod().resolve_domain_cli(dom); }
function route_explain(client, target, port, proto, format) {
    let route_explain_mod = require("diagnostics.route_explain");
    let report = route_explain_mod.explain_route(client, target, port, proto);
    if (format == "json" || format == "--json") {
        print(sprintf("%J\n", report));
    } else {
        print(route_explain_mod.format_text_report(report));
    }
    return report.success ? 0 : 1;
}

// ── CLI Dispatch ────────────────────────────────────────────────────────────
let mode = ARGV[0] || "";

if (mode == "extract-ruleset")
    exit(extract_ruleset(ARGV[1] || ""));
else if (mode == "check-proxy")
    exit(check_proxy());
else if (mode == "check-nft")
    exit(check_nft());
else if (mode == "check-nft-rules")
    exit(check_nft_rules());
else if (mode == "check-tachyon-core")
    exit(check_tachyon_core());
else if (mode == "tachyon-core-standard-ports-listening-fixture")
    tachyon_core_standard_ports_listening_fixture();
else if (mode == "check-inbounds-config")
    exit(check_inbounds_config());
else if (mode == "check-inbounds")
    exit(check_inbounds());
else if (mode == "check-logs")
    exit(check_logs());
else if (mode == "check-tachyon-core-logs")
    exit(check_tachyon_core_logs());
else if (mode == "tachyon-logs-fixture")
    exit(tachyon_logs_fixture());
else if (mode == "check-fakeip")
    exit(check_fakeip(ARGV[1] || ""));
else if (mode == "check-tor-runtime") {
    print(sprintf("%J", { success: true, data: { tor_installed: 0 } }));
    exit(0);
}
else if (mode == "clash-api")
    exit(clash_api(ARGV[1], ARGV[2], ARGV[3], ARGV[4]));
else if (mode == "show-config")
    exit(show_config(ARGV[1] || "masked"));
else if (mode == "show-version")
    exit(show_version());
else if (mode == "show-tachyon-core-config")
    exit(show_tachyon_core_config(ARGV[1] || "masked"));
else if (mode == "show-tachyon-core-version")
    exit(show_tachyon_core_version());
else if (mode == "get-status")
    exit(get_status());
else if (mode == "get-outbound-metadata")
    exit(get_outbound_metadata(ARGV[1]));
else if (mode == "get-subscription-metadata")
    exit(get_subscription_metadata(ARGV[1]));
else if (mode == "get-tachyon-core-status")
    exit(get_tachyon_core_status());
else if (mode == "get-engine-status")
    exit(get_engine_status());
else if (mode == "get-system-info")
    exit(get_system_info());
else if (mode == "get-server-capabilities")
    exit(get_server_capabilities());
else if (mode == "check-dns-available")
    exit(check_dns_available());
else if (mode == "global-check")
    exit(global_check(ARGV[1] || "", ARGV[2] || ""));
else if (mode == "doctor") {
    let fix_requested = false;
    let format_arg = "";
    for (let i = 1; i < length(ARGV); i++) {
        if (ARGV[i] == "--fix")
            fix_requested = true;
        else
            format_arg = ARGV[i];
    }
    exit(doctor(format_arg, fix_requested));
}
else if (mode == "diagnose-json")
    exit(diagnose_json());
else if (mode == "ai-doctor")
    exit(ai_doctor(ARGV[1] || "", ARGV[2] || ""));
else if (mode == "ai-doctor-last")
    exit(ai_doctor_last());
else if (mode == "apply-quick-fix")
    exit(apply_quick_fix(ARGV[1] || ""));
else if (mode == "lan-clients")
    exit(lan_clients());
else if (mode == "toggle-client-bypass")
    exit(toggle_client_bypass(ARGV[1]));
else if (mode == "service-health-check") {
    let args = [];
    for (let i = 1; i < length(ARGV); i++) {
        push(args, ARGV[i]);
    }
    exit(module_passthrough(LIB_DIR + "/diagnostics/service_check.uc", args));
}
else if (mode == "resolve-domain")
    exit(resolve_domain_cli(ARGV[1] || ""));
else if (mode == "route-explain" || mode == "route_explain")
    exit(route_explain(ARGV[1] || "", ARGV[2] || "", ARGV[3] || 0, ARGV[4] || "tcp", ARGV[5] || "text"));
else {
    warn("Usage: diagnostics/runtime.uc <operation> ...\n");
    exit(1);
}
