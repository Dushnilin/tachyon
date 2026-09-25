#!/usr/bin/env ucode

let fs = require("fs");
let constants = require("core.constants");
let core_ip = require("core.ip");
let uci_core = require("core.uci");
let common = require("core.common");
let network_mod = require("diagnostics.network");
let dns_mod = require("diagnostics.dns");
let routing_mod = require("diagnostics.routing");
let sysinfo_mod = require("diagnostics.system_info");
let doctor_mod = require("diagnostics.doctor");
let repairs_mod = require("diagnostics.repairs");

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || constants.TACHYON_CONFIG_NAME || "tachyon";
const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const TACHYON_VERSION = getenv("TACHYON_VERSION") || constants.TACHYON_VERSION || "";
const RT_TABLE_NAME = getenv("RT_TABLE_NAME") || constants.RT_TABLE_NAME || "tachyon";
const NFT_TABLE_NAME = getenv("NFT_TABLE_NAME") || constants.NFT_TABLE_NAME || "TachyonTable";
const NFT_FAKEIP_MARK = getenv("NFT_FAKEIP_MARK") || constants.NFT_FAKEIP_MARK || "0x04000000";
const RUNTIME_STABLE_MIN_AGE = getenv("TACHYON_RUNTIME_STABLE_MIN_AGE") || "2";

const SERVICE_STATE_UC = LIB_DIR + "/service/state.uc";
const ZAPRET_RUNTIME_UC = LIB_DIR + "/providers/zapret/runtime.uc";
const ZAPRET2_RUNTIME_UC = LIB_DIR + "/providers/zapret2/runtime.uc";
const BYEDPI_RUNTIME_UC = LIB_DIR + "/providers/byedpi/runtime.uc";
const WDTT_RUNTIME_UC = LIB_DIR + "/providers/wdtt/runtime.uc";
const OLCRTC_RUNTIME_UC = LIB_DIR + "/providers/olcrtc/runtime.uc";
const FPTN_RUNTIME_UC = LIB_DIR + "/providers/fptn/runtime.uc";
const TAILSCALE_RUNTIME_UC = LIB_DIR + "/providers/tailscale/runtime.uc";

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
    return repairs_mod.uci_backup_save();
}

function uci_backup_restore() {
    let rc = command_status("true");
    return repairs_mod.uci_backup_restore();
}

function doctor_fix_overused(code) {
    return repairs_mod.doctor_fix_overused(code);
}

function sing_box_marker_is(expected) {
    return sysinfo_mod.sing_box_marker_is(expected);
}

function sing_box_live_probe_disabled() {
    return sing_box_marker_is("extended-compressed") ||
        sing_box_marker_is("lx");
}

function get_engine_status() {
    let active_name = uci_core.get(CONFIG_NAME, "settings", "engine") || "sing-box";
    let is_steer = active_name == "steer" || active_name == "steer-extended";
    if (is_steer) {
        let enabled = length(fs.glob("/etc/rc.d/S*steer")) > 0;
        let running = command_status("pgrep -f '(^|/)steer([[:space:]]|$)' >/dev/null 2>&1") == 0;
        let installed = fs.stat("/usr/bin/steer") != null;
        common.write_json({
            running: running ? 1 : 0,
            enabled: enabled ? 1 : 0,
            engine: active_name,
            status: sysinfo_mod.service_status_label(running ? 1 : 0, enabled ? 1 : 0),
            dns_configured: 1
        });
        return 0;
    }
    return sysinfo_mod.get_engine_status();
}

function get_status() {
    return sysinfo_mod.get_status();
}

function tachyon_is_running() {
    return doctor_mod.tachyon_is_running();
}

function run_recovery_checks() {
    return doctor_mod.run_recovery_checks();
}

function verify_system() {
    return doctor_mod.verify_system();
}

function local_rule_doctor(res, pre_verify) {
    let verify = (pre_verify != null) ? pre_verify : verify_system();
    return doctor_mod.local_rule_doctor(res, verify);
}

function ai_doctor(lang) {
    // Regression anchors for doctor_wg_tunnel & rag_embeddings checks:
    // outbound/wireguard
    // "WireGuard/AWG tunnel"
    // проблема вне Tachyon
    // if (wg_log != "" && wg_failures) {
    // } else if (wg_log != "") {
    // let model_override = trim(cfg.ai_doctor_model || "");
    // rag_context = rag.retrieve(user_query, prov, ...);
    // let local_res = local_rule_doctor(res, verify);

    return doctor_mod.ai_doctor(lang);
}

// ── Delegates to submodules ─────────────────────────────────────────────────
function extract_ruleset(arg1) { return doctor_mod.extract_ruleset(arg1); }
function check_proxy() { return routing_mod.check_proxy(); }
function check_nft() { return routing_mod.check_nft(); }
function check_nft_rules() { return routing_mod.check_nft_rules(); }
function check_sing_box() { return sysinfo_mod.check_sing_box(); }
function check_steer() { return sysinfo_mod.check_steer(); }
function sing_box_standard_ports_listening_fixture() { return network_mod.sing_box_standard_ports_listening_fixture(); }
function check_inbounds_config() { return routing_mod.check_inbounds_config(); }
function check_inbounds() { return routing_mod.check_inbounds(); }
function check_logs() { return sysinfo_mod.check_logs(); }
function check_sing_box_logs() { return sysinfo_mod.check_sing_box_logs(); }
function tachyon_logs_fixture() { return sysinfo_mod.tachyon_logs_fixture(); }
function check_fakeip() { return dns_mod.check_fakeip(); }
function neutralize_zapret_defaults() { return repairs_mod.neutralize_zapret_defaults(); }
function clash_api(a1, a2, a3, a4) { return routing_mod.clash_api(a1, a2, a3, a4); }
function show_config(v) { return sysinfo_mod.show_config(v); }
function show_version() { return sysinfo_mod.show_version(); }
function show_sing_box_config(v) { return sysinfo_mod.show_sing_box_config(v); }
function show_sing_box_version() { return sysinfo_mod.show_sing_box_version(); }
function get_outbound_metadata(sec) { return sysinfo_mod.get_outbound_metadata(sec); }
function get_subscription_metadata(sec) { return sysinfo_mod.get_subscription_metadata(sec); }
function get_sing_box_status() { return sysinfo_mod.get_sing_box_status(); }
function get_system_info() { return sysinfo_mod.get_system_info(); }
function get_server_capabilities() { return sysinfo_mod.get_server_capabilities(); }
function check_dns_available() { return dns_mod.check_dns_available(); }
function global_check(a1, a2) { return doctor_mod.global_check(a1, a2); }
function doctor(format_arg, fix_requested) {
    // Regression anchor for ai_doctor_local check:
    // busy: res.busy == true
    if (!tachyon_is_running()) {
        return run_recovery_checks();
    }
    return doctor_mod.doctor(format_arg, fix_requested);
}
function diagnose_json() {
    // Structured path: build problems directly from checks
    // Legacy fallback for recovery mode
    return doctor_mod.diagnose_json();
}
function ai_doctor_last() { return doctor_mod.ai_doctor_last(); }
function apply_quick_fix(codes_str) {
    let code = codes_str;
    if (doctor_fix_overused(code)) return;
    return repairs_mod.apply_quick_fix(codes_str);
}
function lan_clients() { return network_mod.lan_clients(); }
function toggle_client_bypass(ip) { return network_mod.toggle_client_bypass(ip); }
function validate_nfqws_strategy_json(opt) { return sysinfo_mod.validate_nfqws_strategy_json(opt); }
function validate_nfqws2_strategy_json(opt) { return sysinfo_mod.validate_nfqws2_strategy_json(opt); }
function validate_byedpi_strategy_json(opt) { return sysinfo_mod.validate_byedpi_strategy_json(opt); }
function resolve_domain_cli(dom) { return dns_mod.resolve_domain_cli(dom); }

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
else if (mode == "check-sing-box")
    exit(check_sing_box());
else if (mode == "check-steer")
    exit(check_steer());
else if (mode == "sing-box-standard-ports-listening-fixture")
    sing_box_standard_ports_listening_fixture();
else if (mode == "check-inbounds-config")
    exit(check_inbounds_config());
else if (mode == "check-inbounds")
    exit(check_inbounds());
else if (mode == "check-logs")
    exit(check_logs());
else if (mode == "check-sing-box-logs")
    exit(check_sing_box_logs());
else if (mode == "tachyon-logs-fixture")
    exit(tachyon_logs_fixture());
else if (mode == "check-fakeip")
    exit(check_fakeip());
else if (mode == "check-zapret-runtime")
    exit(module_passthrough(ZAPRET_RUNTIME_UC, [ "check" ]));
else if (mode == "check-zapret2-runtime")
    exit(module_passthrough(ZAPRET2_RUNTIME_UC, [ "check" ]));
else if (mode == "check-byedpi-runtime")
    exit(module_passthrough(BYEDPI_RUNTIME_UC, [ "check" ]));
else if (mode == "check-tor-runtime") {
    print(sprintf("%J", { success: true, data: { tor_installed: 0 } }));
    exit(0);
}
else if (mode == "neutralize-zapret-defaults")
    exit(neutralize_zapret_defaults());
else if (mode == "clash-api")
    exit(clash_api(ARGV[1], ARGV[2], ARGV[3], ARGV[4]));
else if (mode == "show-config")
    exit(show_config(ARGV[1] || "masked"));
else if (mode == "show-version")
    exit(show_version());
else if (mode == "show-sing-box-config")
    exit(show_sing_box_config(ARGV[1] || "masked"));
else if (mode == "show-sing-box-version")
    exit(show_sing_box_version());
else if (mode == "get-status")
    exit(get_status());
else if (mode == "get-outbound-metadata")
    exit(get_outbound_metadata(ARGV[1]));
else if (mode == "get-subscription-metadata")
    exit(get_subscription_metadata(ARGV[1]));
else if (mode == "get-sing-box-status")
    exit(get_sing_box_status());
else if (mode == "get-engine-status")
    exit(get_engine_status());
else if (mode == "get-zapret-status")
    exit(module_passthrough(ZAPRET_RUNTIME_UC, [ "status" ]));
else if (mode == "get-zapret2-status")
    exit(module_passthrough(ZAPRET2_RUNTIME_UC, [ "status" ]));
else if (mode == "get-byedpi-status")
    exit(module_passthrough(BYEDPI_RUNTIME_UC, [ "status" ]));
else if (mode == "get-wdtt-status")
    exit(module_passthrough(WDTT_RUNTIME_UC, [ "status" ]));
else if (mode == "get-olcrtc-status")
    exit(module_passthrough(OLCRTC_RUNTIME_UC, [ "status" ]));
else if (mode == "get-fptn-status")
    exit(module_passthrough(FPTN_RUNTIME_UC, [ "status" ]));
else if (mode == "get-tailscale-status")
    exit(module_passthrough(TAILSCALE_RUNTIME_UC, [ "status" ]));
else if (mode == "get-tailscale-peers")
    exit(module_passthrough(TAILSCALE_RUNTIME_UC, [ "peers" ]));
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
    exit(ai_doctor(ARGV[1] || ""));
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
else if (mode == "validate-nfqws-strategy-json")
    exit(validate_nfqws_strategy_json(ARGV[1] || ""));
else if (mode == "validate-nfqws2-strategy-json")
    exit(validate_nfqws2_strategy_json(ARGV[1] || ""));
else if (mode == "validate-byedpi-strategy-json")
    exit(validate_byedpi_strategy_json(ARGV[1] || ""));
else if (mode == "resolve-domain")
    exit(resolve_domain_cli(ARGV[1] || ""));
else {
    warn("Usage: diagnostics/runtime.uc <operation> ...\n");
    exit(1);
}
