#!/usr/bin/env ucode
//
// service/reconciler.uc - Granular Desired-vs-Actual State Reconciler for Tachyon.
//
// Architectural Role:
//   Reconciles the running system toward its desired state with MINIMAL disruption.
//   Instead of heavy, disruptive service restarts (bouncing all proxy connections,
//   flapping WAN interfaces, or tearing down nftables), the Reconciler diffs the
//   desired configuration against the live kernel/process state and performs
//   surgical, targeted remediation:
//     - Repairing DNS (dnsmasq redirect / SmartDNS) without bouncing proxy tunnels.
//     - Repopulating missing/flushed nftables sets without reloading the core engine.
//     - Restoring missing policy routing rules without restarting sing-box.
//     - Restarting crashed auxiliary daemons (nfqws/nfqws2/byedpi) without touching DNS.
//     - Restarting only the engine when the core process itself dies.
//
// Subsystems:
//   - "engine":   core routing engine (sing-box / steer / steer-extended)
//   - "dns":      dnsmasq interception, smartdns upstreams, localhost resolution
//   - "nftables": kernel tables (TachyonTable / steer), chains, runtime sets
//   - "routing":  policy routing rules (ip rule fwmark/tachyon), table routes
//   - "daemons":  auxiliary providers (zapret nfqws, zapret2 nfqws2, byedpi ciadpi, steer-zapret)
//
// Integration:
//   - Core Transaction Engine (core.transaction): multi-phase mutation with rollback
//   - Structured Logging (core.logging): audit trail to syslog / /dev/kmsg
//   - Event Journal (core.events): ring buffer facts recording with secret redaction
//   - Watchdog (service.watchdog): delegates L2 subsystem repairs to Reconciler
//   - Event Controller (service.event_controller): triggers targeted reconciliations on bus events
//

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");
let constants = require("core.constants");

let as_string = common.as_string;
let shell_quote = common.shell_quote;
let command_from_args = common.command_from_args;
let command_status = common.command_status;
let command_success_from_args = common.command_success_from_args;
let file_exists = common.file_exists;
let object_or_empty = common.object_or_empty;
let array_or_empty = common.array_or_empty;
let read_json_file = common.read_json_file;

// Optional core modules loaded with safe try/catch fallbacks
let proc = null;
try { proc = require("core.process"); } catch (e) {}

let logging = null;
try { logging = require("core.logging"); } catch (e) {}

let events = null;
try { events = require("core.events"); } catch (e) {}

let transaction = null;
try { transaction = require("core.transaction"); } catch (e) {}

let engine_core = null;
try { engine_core = require("core.engine"); } catch (e) {}

// ---------------------------------------------------------------------------
// Constants & Definitions
// ---------------------------------------------------------------------------

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const RUNTIME_STATE_DIR = getenv("TACHYON_RUNTIME_STATE_DIR") || "/var/run/tachyon";

const SUBSYSTEM_ENGINE = "engine";
const SUBSYSTEM_DNS = "dns";
const SUBSYSTEM_NFTABLES = "nftables";
const SUBSYSTEM_ROUTING = "routing";
const SUBSYSTEM_DAEMONS = "daemons";

const SUBSYSTEMS = [
    SUBSYSTEM_ENGINE,
    SUBSYSTEM_DAEMONS,
    SUBSYSTEM_ROUTING,
    SUBSYSTEM_NFTABLES,
    SUBSYSTEM_DNS
];

const SEVERITY_CRITICAL = "critical";
const SEVERITY_HIGH = "high";
const SEVERITY_MEDIUM = "medium";
const SEVERITY_LOW = "low";

const ACTION_REPAIR_ENGINE = "repair_engine";
const ACTION_REPAIR_DNS = "repair_dns";
const ACTION_REPAIR_NFT_TABLE = "repair_nft_table";
const ACTION_REPAIR_NFT_SETS = "repair_nft_sets";
const ACTION_REPAIR_ROUTING = "repair_routing";
const ACTION_REPAIR_DAEMON = "repair_daemon";
const ACTION_RELOAD_SERVICE = "reload_service";

const NFT_TABLE_SINGBOX = "TachyonTable";
const NFT_TABLE_STEER = "steer";
const RT_TABLE_NAME = "tachyon";
const RT_TABLE_ID = "4249";

const CORE_NFT_SETS = [
    "localv4",
    "localv6",
    "tachyon_subnets",
    "tachyon_ports",
    "tachyon_ip_ports"
];

// ---------------------------------------------------------------------------
// Logging & Audit Helpers
// ---------------------------------------------------------------------------

function log(message, level) {
    let lvl = level || "info";
    if (logging && logging.log) {
        logging.log(message, { level: lvl, subsystem: "service.reconciler" });
    } else {
        let prefix = sprintf("[%s] Reconciler: ", lvl);
        command_success_from_args([ "logger", "-t", "tachyon", prefix + as_string(message) ]);
    }
}

function emit_event(name, data) {
    if (!events) return;
    try {
        let bus = events.bus({ journal: true });
        bus.publish(name, data);
    } catch (e) {
        // Non-fatal if event recording fails
    }
}

// ---------------------------------------------------------------------------
// Shell & Process Execution Helpers
// ---------------------------------------------------------------------------

function command_capture(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return { status: 1, output: "" };
    let data = pipe.read("all");
    let status = pipe.close();
    if (status > 255) status = int(status / 256);
    return { status, output: data == null ? "" : as_string(data) };
}

function command_output_from_args(args) {
    let result = command_capture(command_from_args(args) + " 2>/dev/null");
    return result.status == 0 ? trim(result.output) : "";
}

function is_proc_alive(pid, expected_name) {
    if (!pid || match(as_string(pid), /^[0-9]+$/) == null)
        return false;
    if (proc && proc.process_running)
        return proc.process_running(pid, expected_name);
    if (fs.stat("/proc/" + pid) == null)
        return false;
    if (expected_name) {
        let comm = trim(as_string(fs.readfile("/proc/" + pid + "/comm") || ""));
        return comm == expected_name || index(comm, expected_name) >= 0;
    }
    return true;
}

function read_pid_file(path, expected_name) {
    if (!file_exists(path)) return "";
    let content = trim(as_string(fs.readfile(path) || ""));
    if (content == "") return "";
    let lines = split(content, "\n");
    let pid = trim(lines[0]);
    if (is_proc_alive(pid, expected_name))
        return pid;
    return "";
}

function get_pid_by_name(name) {
    let res = command_capture("pidof " + shell_quote(name) + " 2>/dev/null");
    if (res.status == 0 && trim(res.output) != "") {
        let pids = split(trim(res.output), /[ \t]+/);
        if (length(pids) > 0 && is_proc_alive(pids[0], name))
            return pids[0];
    }
    return "";
}

// ---------------------------------------------------------------------------
// UCI and Configuration Probing Helpers
// ---------------------------------------------------------------------------

function get_settings() {
    return object_or_empty(uci_core.get_all(CONFIG_NAME, "settings"));
}

function is_service_enabled() {
    let s = get_settings();
    return s.enabled == "1" || s.enabled == "true" || s.enabled == true;
}

function get_active_engine_id() {
    if (engine_core && engine_core.active_engine_id)
        return engine_core.active_engine_id();
    let s = get_settings();
    return s.engine || "sing-box";
}

function is_engine_steer(engine_id) {
    let id = engine_id || get_active_engine_id();
    return id == "steer" || id == "steer-extended";
}

function get_enabled_outbound_sections() {
    let sections = [];
    let all = uci_core.get_all(CONFIG_NAME);
    if (!all) return sections;
    for (let sname, sec in all) {
        if (sec[".type"] == "outbound" && (sec.enabled == "1" || sec.enabled == "true" || sec.enabled == null)) {
            push(sections, sec);
        }
    }
    return sections;
}

function has_provider_sections(action_type) {
    for (let sec in get_enabled_outbound_sections()) {
        if (sec.action == action_type)
            return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// DESIRED STATE BUILDERS
// ---------------------------------------------------------------------------

function build_desired_engine(opts) {
    let enabled = is_service_enabled();
    let engine_id = get_active_engine_id();
    return {
        enabled: enabled,
        id: engine_id,
        is_steer: is_engine_steer(engine_id),
        should_run: enabled
    };
}

function build_desired_dns(opts) {
    let enabled = is_service_enabled();
    let s = get_settings();
    let engine_id = get_active_engine_id();
    let is_steer = is_engine_steer(engine_id);

    // If dont_touch_dhcp is set to 1, Tachyon should NOT manage dnsmasq
    let dont_touch = s.dont_touch_dhcp == "1" || s.dont_touch_dhcp == "true";
    let manage_dnsmasq = enabled && !dont_touch;

    let encrypted_dns = s.dns_type && s.dns_type != "udp";
    let smartdns_needed = is_steer && manage_dnsmasq && encrypted_dns;

    return {
        manage_dnsmasq: manage_dnsmasq,
        mode: is_steer ? "steer" : "sing-box",
        smartdns_needed: smartdns_needed,
        dns_type: s.dns_type || "doh",
        expect_resolving: enabled
    };
}

function build_desired_nftables(opts) {
    let enabled = is_service_enabled();
    let engine_id = get_active_engine_id();
    let is_steer = is_engine_steer(engine_id);

    if (!enabled) {
        return {
            table_needed: false,
            table_name: is_steer ? NFT_TABLE_STEER : NFT_TABLE_SINGBOX,
            sets_needed: []
        };
    }

    if (is_steer) {
        return {
            table_needed: true,
            table_name: NFT_TABLE_STEER,
            sets_needed: [] // steer manages its own sets internally
        };
    }

    return {
        table_needed: true,
        table_name: NFT_TABLE_SINGBOX,
        sets_needed: CORE_NFT_SETS
    };
}

function build_desired_routing(opts) {
    let enabled = is_service_enabled();
    let is_steer = is_engine_steer();

    return {
        needed: enabled && !is_steer, // steer owns policy routing when active
        table_name: RT_TABLE_NAME,
        table_id: RT_TABLE_ID,
        rule_mark: "0x04000000"
    };
}

function build_desired_daemons(opts) {
    let enabled = is_service_enabled();
    let is_steer = is_engine_steer();
    let daemons = [];

    if (!enabled) return daemons;

    if (is_steer) {
        // On steer, zapret is handled by tachyon-steer-zapret procd init
        if (has_provider_sections("zapret") || has_provider_sections("zapret2")) {
            push(daemons, {
                id: "steer-zapret",
                name: "tachyon-steer-zapret",
                kind: "procd_service",
                critical: false
            });
        }
    } else {
        // On sing-box, auxiliary daemons run as local background providers
        if (has_provider_sections("zapret")) {
            push(daemons, {
                id: "zapret",
                name: "nfqws",
                kind: "provider",
                critical: false
            });
        }
        if (has_provider_sections("zapret2")) {
            push(daemons, {
                id: "zapret2",
                name: "nfqws2",
                kind: "provider",
                critical: false
            });
        }
        if (has_provider_sections("byedpi")) {
            push(daemons, {
                id: "byedpi",
                name: "ciadpi",
                kind: "provider",
                critical: false
            });
        }
        if (has_provider_sections("fptn")) {
            push(daemons, {
                id: "fptn",
                name: "fptn",
                kind: "provider",
                critical: false
            });
        }
    }

    return daemons;
}

function get_desired_state(opts) {
    opts = opts || {};
    return {
        timestamp: time(),
        engine: build_desired_engine(opts),
        dns: build_desired_dns(opts),
        nftables: build_desired_nftables(opts),
        routing: build_desired_routing(opts),
        daemons: build_desired_daemons(opts)
    };
}

// ---------------------------------------------------------------------------
// ACTUAL STATE INSPECTORS
// ---------------------------------------------------------------------------

function inspect_actual_engine(desired_engine) {
    let engine_id = desired_engine.id;
    let running = false;
    let pid = "";

    if (desired_engine.is_steer) {
        pid = read_pid_file("/var/run/steer.pid", "steer");
        if (!pid) pid = get_pid_by_name("steer");
        running = pid != "";
    } else {
        for (let p in [ "/var/run/sing-box.pid", "/var/run/sing-box/sing-box.pid" ]) {
            pid = read_pid_file(p, "sing-box");
            if (pid) break;
        }
        if (!pid) pid = get_pid_by_name("sing-box");
        running = pid != "";
    }

    return {
        id: engine_id,
        running: running,
        pid: pid
    };
}

function probe_dns_resolution() {
    let cmd = "nslookup -timeout=2 yandex.ru 127.0.0.1 >/dev/null 2>&1 || " +
              "nslookup -timeout=2 connectivitycheck.gstatic.com 127.0.0.1 >/dev/null 2>&1 || " +
              "nslookup -timeout=2 google.com 127.0.0.1 >/dev/null 2>&1";
    return command_status(cmd) == 0;
}

function inspect_actual_dns(desired_dns) {
    let dnsmasq_pid = read_pid_file("/var/run/dnsmasq/dnsmasq.pid", "dnsmasq");
    if (!dnsmasq_pid) dnsmasq_pid = get_pid_by_name("dnsmasq");
    let dnsmasq_running = dnsmasq_pid != "";

    // Check if dnsmasq has Tachyon managed config
    let dnsmasq_managed = false;
    let res = command_capture(sprintf("ucode -L %s %s/dns/apply.uc has-managed-state 2>/dev/null", LIB_DIR, LIB_DIR));
    if (res.status == 0) {
        dnsmasq_managed = true;
    } else {
        // Fallback: check dhcp uci directly
        let servers = uci_core.get("dhcp", "@dnsmasq[0]", "server");
        if (servers) {
            let str_srv = sprintf("%J", servers);
            if (index(str_srv, "127.0.0.42#") >= 0 || index(str_srv, "127.0.0.1#") >= 0)
                dnsmasq_managed = true;
        }
    }

    let smartdns_running = false;
    let smartdns_pid = "";
    if (desired_dns.smartdns_needed) {
        smartdns_pid = read_pid_file(RUNTIME_STATE_DIR + "/steer-smartdns.pid", "smartdns");
        if (!smartdns_pid) smartdns_pid = get_pid_by_name("smartdns");
        smartdns_running = smartdns_pid != "";
    }

    let resolving = probe_dns_resolution();

    return {
        dnsmasq_running: dnsmasq_running,
        dnsmasq_pid: dnsmasq_pid,
        dnsmasq_managed: dnsmasq_managed,
        smartdns_running: smartdns_running,
        smartdns_pid: smartdns_pid,
        resolving: resolving
    };
}

function inspect_actual_nftables(desired_nft) {
    let table_name = desired_nft.table_name;
    let table_present = command_status(sprintf("nft list table inet %s >/dev/null 2>&1", shell_quote(table_name))) == 0;

    let sets_present = [];
    let sets_missing = [];
    let sets_empty = [];

    if (table_present && length(desired_nft.sets_needed) > 0) {
        for (let set_name in desired_nft.sets_needed) {
            let res = command_capture(sprintf("nft list set inet %s %s 2>/dev/null", shell_quote(table_name), shell_quote(set_name)));
            if (res.status != 0) {
                push(sets_missing, set_name);
            } else {
                push(sets_present, set_name);
                // Check if empty
                if (index(res.output, "elements = {") < 0 || match(res.output, /elements\s*=\s*\{\s*\}/)) {
                    push(sets_empty, set_name);
                }
            }
        }
    }

    return {
        table_present: table_present,
        table_name: table_name,
        sets_present: sets_present,
        sets_missing: sets_missing,
        sets_empty: sets_empty
    };
}

function inspect_actual_routing(desired_routing) {
    let rule4_present = false;
    let rule6_present = false;
    let route_present = false;

    if (desired_routing.needed) {
        let r4 = command_output_from_args([ "ip", "rule", "show" ]);
        if (index(r4, "tachyon") >= 0 || index(r4, "4249") >= 0 || index(r4, "0x4000000") >= 0)
            rule4_present = true;

        let r6 = command_output_from_args([ "ip", "-6", "rule", "show" ]);
        if (index(r6, "tachyon") >= 0 || index(r6, "4249") >= 0 || index(r6, "0x4000000") >= 0)
            rule6_present = true;

        let routes = command_output_from_args([ "ip", "route", "show", "table", desired_routing.table_name ]);
        if (routes != "")
            route_present = true;
    }

    return {
        rule4_present: rule4_present,
        rule6_present: rule6_present,
        route_present: route_present
    };
}

function inspect_actual_daemons(desired_daemons) {
    let daemons = [];
    for (let d in desired_daemons) {
        let running = false;
        let pid = "";

        if (d.kind == "procd_service") {
            let res = command_capture(sprintf("/etc/init.d/%s status 2>/dev/null", d.name));
            if (res.status == 0 && index(res.output, "running") >= 0) {
                running = true;
            } else {
                let pids = command_output_from_args([ "pgrep", "-f", "steer-nfqws" ]);
                if (pids != "") running = true;
            }
        } else {
            pid = get_pid_by_name(d.name);
            running = pid != "";
        }

        push(daemons, {
            id: d.id,
            name: d.name,
            running: running,
            pid: pid
        });
    }
    return daemons;
}

function get_actual_state(desired, opts) {
    desired = desired || get_desired_state(opts);
    return {
        timestamp: time(),
        engine: inspect_actual_engine(desired.engine),
        dns: inspect_actual_dns(desired.dns),
        nftables: inspect_actual_nftables(desired.nftables),
        routing: inspect_actual_routing(desired.routing),
        daemons: inspect_actual_daemons(desired.daemons)
    };
}

// ---------------------------------------------------------------------------
// DIFF & PLANNING ENGINE
// ---------------------------------------------------------------------------

function diff_engine(desired_eng, actual_eng) {
    let drifts = [];
    if (desired_eng.should_run && !actual_eng.running) {
        push(drifts, {
            subsystem: SUBSYSTEM_ENGINE,
            item: "engine_stopped",
            expected: "running",
            actual: "stopped",
            severity: SEVERITY_CRITICAL,
            action: ACTION_REPAIR_ENGINE,
            reason: sprintf("Core routing engine '%s' is not running", desired_eng.id)
        });
    } else if (!desired_eng.should_run && actual_eng.running) {
        push(drifts, {
            subsystem: SUBSYSTEM_ENGINE,
            item: "engine_unwanted",
            expected: "stopped",
            actual: "running",
            severity: SEVERITY_HIGH,
            action: ACTION_RELOAD_SERVICE,
            reason: sprintf("Routing engine '%s' running but service is disabled", desired_eng.id)
        });
    }
    return drifts;
}

function diff_dns(desired_dns, actual_dns) {
    let drifts = [];

    if (!actual_dns.dnsmasq_running) {
        push(drifts, {
            subsystem: SUBSYSTEM_DNS,
            item: "dnsmasq_stopped",
            expected: "running",
            actual: "stopped",
            severity: SEVERITY_CRITICAL,
            action: ACTION_REPAIR_DNS,
            reason: "System resolver dnsmasq is not running"
        });
        return drifts; // No point checking other DNS items if dnsmasq is dead
    }

    if (desired_dns.manage_dnsmasq && !actual_dns.dnsmasq_managed) {
        push(drifts, {
            subsystem: SUBSYSTEM_DNS,
            item: "dnsmasq_redirect_missing",
            expected: "managed",
            actual: "unmanaged",
            severity: SEVERITY_HIGH,
            action: ACTION_REPAIR_DNS,
            reason: "Tachyon DNS redirection is missing in dnsmasq"
        });
    }

    if (desired_dns.smartdns_needed && !actual_dns.smartdns_running) {
        push(drifts, {
            subsystem: SUBSYSTEM_DNS,
            item: "smartdns_stopped",
            expected: "running",
            actual: "stopped",
            severity: SEVERITY_HIGH,
            action: ACTION_REPAIR_DNS,
            reason: "Encrypted DNS upstream smartdns is not running for steer"
        });
    }

    if (desired_dns.expect_resolving && !actual_dns.resolving) {
        push(drifts, {
            subsystem: SUBSYSTEM_DNS,
            item: "dns_resolution_failed",
            expected: "resolving",
            actual: "failing",
            severity: SEVERITY_HIGH,
            action: ACTION_REPAIR_DNS,
            reason: "Local DNS queries to 127.0.0.1 fail to resolve"
        });
    }

    return drifts;
}

function diff_nftables(desired_nft, actual_nft) {
    let drifts = [];

    if (desired_nft.table_needed && !actual_nft.table_present) {
        push(drifts, {
            subsystem: SUBSYSTEM_NFTABLES,
            item: "table_missing",
            expected: desired_nft.table_name,
            actual: "missing",
            severity: SEVERITY_CRITICAL,
            action: ACTION_REPAIR_NFT_TABLE,
            reason: sprintf("nftables table '%s' is missing", desired_nft.table_name)
        });
        return drifts; // Sets can't exist without table
    }

    if (length(actual_nft.sets_missing) > 0) {
        push(drifts, {
            subsystem: SUBSYSTEM_NFTABLES,
            item: "sets_missing",
            expected: desired_nft.sets_needed,
            actual: actual_nft.sets_missing,
            severity: SEVERITY_HIGH,
            action: ACTION_REPAIR_NFT_SETS,
            reason: sprintf("Missing nftables sets: %s", join(", ", actual_nft.sets_missing))
        });
    }

    if (length(actual_nft.sets_empty) > 0) {
        push(drifts, {
            subsystem: SUBSYSTEM_NFTABLES,
            item: "sets_empty",
            expected: "populated",
            actual: actual_nft.sets_empty,
            severity: SEVERITY_MEDIUM,
            action: ACTION_REPAIR_NFT_SETS,
            reason: sprintf("Empty nftables sets: %s", join(", ", actual_nft.sets_empty))
        });
    }

    return drifts;
}

function diff_routing(desired_rt, actual_rt) {
    let drifts = [];

    if (desired_rt.needed) {
        if (!actual_rt.rule4_present) {
            push(drifts, {
                subsystem: SUBSYSTEM_ROUTING,
                item: "rule4_missing",
                expected: "rule_present",
                actual: "missing",
                severity: SEVERITY_HIGH,
                action: ACTION_REPAIR_ROUTING,
                reason: "IPv4 policy routing rule to table tachyon is missing"
            });
        }

        if (!actual_rt.route_present) {
            push(drifts, {
                subsystem: SUBSYSTEM_ROUTING,
                item: "route_missing",
                expected: "route_present",
                actual: "missing",
                severity: SEVERITY_HIGH,
                action: ACTION_REPAIR_ROUTING,
                reason: "Routing table 'tachyon' has no active routes"
            });
        }
    }

    return drifts;
}

function diff_daemons(desired_daemons, actual_daemons) {
    let drifts = [];
    let actual_map = {};
    for (let ad in actual_daemons)
        actual_map[ad.id] = ad;

    for (let dd in desired_daemons) {
        let ad = actual_map[dd.id];
        if (!ad || !ad.running) {
            push(drifts, {
                subsystem: SUBSYSTEM_DAEMONS,
                item: dd.id + "_stopped",
                daemon_id: dd.id,
                daemon_name: dd.name,
                expected: "running",
                actual: "stopped",
                severity: dd.critical ? SEVERITY_HIGH : SEVERITY_MEDIUM,
                action: ACTION_REPAIR_DAEMON,
                reason: sprintf("Auxiliary daemon '%s' is not running", dd.name)
            });
        }
    }

    return drifts;
}

function diff_state(desired, actual) {
    let drifts = [];

    let eng_drifts = diff_engine(desired.engine, actual.engine);
    for (let d in eng_drifts) push(drifts, d);

    let daemon_drifts = diff_daemons(desired.daemons, actual.daemons);
    for (let d in daemon_drifts) push(drifts, d);

    let rt_drifts = diff_routing(desired.routing, actual.routing);
    for (let d in rt_drifts) push(drifts, d);

    let nft_drifts = diff_nftables(desired.nftables, actual.nftables);
    for (let d in nft_drifts) push(drifts, d);

    let dns_drifts = diff_dns(desired.dns, actual.dns);
    for (let d in dns_drifts) push(drifts, d);

    return {
        timestamp: time(),
        clean: length(drifts) == 0,
        drift_count: length(drifts),
        drifts: drifts
    };
}

function plan(opts) {
    opts = opts || {};
    let desired = get_desired_state(opts);
    let actual = get_actual_state(desired, opts);
    let diff = diff_state(desired, actual);

    // Group drifts by subsystem for structured execution
    let actions_by_subsystem = {};
    for (let sub in SUBSYSTEMS)
        actions_by_subsystem[sub] = [];

    for (let item in diff.drifts) {
        if (actions_by_subsystem[item.subsystem])
            push(actions_by_subsystem[item.subsystem], item);
    }

    return {
        timestamp: diff.timestamp,
        clean: diff.clean,
        drift_count: diff.drift_count,
        drifts: diff.drifts,
        actions_by_subsystem: actions_by_subsystem,
        desired: desired,
        actual: actual
    };
}

// ---------------------------------------------------------------------------
// SUBSYSTEM REPAIRS (SURGICAL REMEDIATION)
// ---------------------------------------------------------------------------

function repair_engine_subsystem(drift_items, opts) {
    log("Reconciler: repairing engine subsystem...", "info");
    let engine_id = get_active_engine_id();

    // Check if engine_runtime module is available
    let engine_runtime = null;
    try { engine_runtime = require("service.engine_runtime"); } catch (e) {}

    let res = null;
    if (engine_runtime && engine_runtime.run_init) {
        res = engine_runtime.run_init(engine_id, "restart");
    } else {
        let init_script = sprintf("/etc/init.d/%s", engine_id);
        if (file_exists(init_script)) {
            let code = command_status(sprintf("%s restart >/dev/null 2>&1", init_script));
            res = { ok: code == 0, status: code };
        } else {
            res = { ok: false, reason: "init_not_found" };
        }
    }

    if (res && res.ok) {
        log(sprintf("Reconciler: engine '%s' restarted successfully", engine_id), "info");
        return { ok: true, subsystem: SUBSYSTEM_ENGINE, engine: engine_id };
    } else {
        log(sprintf("Reconciler: failed to restart engine '%s'", engine_id), "err");
        return { ok: false, subsystem: SUBSYSTEM_ENGINE, error: res ? res.reason : "unknown" };
    }
}

function repair_dns_subsystem(drift_items, opts) {
    log("Reconciler: repairing DNS subsystem...", "info");
    let engine_id = get_active_engine_id();
    let is_steer = is_engine_steer(engine_id);
    let s = get_settings();

    // 1. If dnsmasq is dead, resurrect it first
    let dnsmasq_pid = read_pid_file("/var/run/dnsmasq/dnsmasq.pid", "dnsmasq");
    if (!dnsmasq_pid) dnsmasq_pid = get_pid_by_name("dnsmasq");
    if (!dnsmasq_pid) {
        log("Reconciler: dnsmasq is stopped, restarting /etc/init.d/dnsmasq...", "warn");
        command_status("/etc/init.d/dnsmasq restart >/dev/null 2>&1");
    }

    // 2. If steer smartdns is dead, restart it
    if (is_steer && s.dns_type && s.dns_type != "udp") {
        let steer_dns = null;
        try { steer_dns = require("steer.dns"); } catch (e) {}
        if (steer_dns && steer_dns.start_runtime) {
            log("Reconciler: restarting steer smartdns upstream...", "info");
            steer_dns.start_runtime();
        }
    }

    // 3. Re-apply Tachyon DNS interception in dnsmasq
    let apply_subcmd = is_steer ? "configure-steer" : "configure";
    let cmd = sprintf("ucode -L %s %s/dns/apply.uc %s force >/dev/null 2>&1", LIB_DIR, LIB_DIR, apply_subcmd);
    let code = command_status(cmd);

    // 4. Send SIGHUP to flush dnsmasq caches
    command_status("killall -SIGHUP dnsmasq >/dev/null 2>&1 || ubus call dnsmasq reload >/dev/null 2>&1");

    // 5. Verification
    let resolving = probe_dns_resolution();
    if (code == 0 || resolving) {
        log("Reconciler: DNS subsystem repaired and verified", "info");
        return { ok: true, subsystem: SUBSYSTEM_DNS, resolving: resolving };
    } else {
        log("Reconciler: DNS repair failed to restore resolution", "warn");
        return { ok: false, subsystem: SUBSYSTEM_DNS, code: code, resolving: resolving };
    }
}

function repair_nftables_subsystem(drift_items, opts) {
    log("Reconciler: repairing nftables subsystem...", "info");
    let is_steer = is_engine_steer();

    if (is_steer) {
        // On steer, trigger spec apply
        log("Reconciler: applying steer spec rules...", "info");
        let code = command_status("steer apply >/dev/null 2>&1 || /etc/init.d/steer reload >/dev/null 2>&1");
        return { ok: code == 0, subsystem: SUBSYSTEM_NFTABLES };
    }

    // On sing-box:
    // Determine whether table is missing or only sets need repopulating
    let table_missing = false;
    for (let item in drift_items) {
        if (item.item == "table_missing") {
            table_missing = true;
            break;
        }
    }

    let code = 0;
    if (table_missing) {
        log("Reconciler: rebuilding entire TachyonTable runtime rules...", "info");
        let cmd = sprintf("ucode -L %s %s/service/lifecycle.uc reload_firewall >/dev/null 2>&1", LIB_DIR, LIB_DIR);
        code = command_status(cmd);
    } else {
        log("Reconciler: repopulating runtime nftables sets...", "info");
        let cmd = sprintf("ucode -L %s %s/service/lifecycle.uc nft_populate_runtime_sets >/dev/null 2>&1", LIB_DIR, LIB_DIR);
        code = command_status(cmd);
    }

    return { ok: code == 0, subsystem: SUBSYSTEM_NFTABLES, table_rebuilt: table_missing };
}

function repair_routing_subsystem(drift_items, opts) {
    log("Reconciler: repairing routing subsystem...", "info");

    // Ensure policy routing table and rules exist
    let cmd = sprintf("ucode -L %s %s/nft/apply.uc ensure-tproxy-route-rule %s %s 0x04000000 >/dev/null 2>&1",
        LIB_DIR, LIB_DIR, RT_TABLE_NAME, RT_TABLE_ID);
    let code = command_status(cmd);

    // Ensure local route in table
    command_status(sprintf("ip route add local default dev lo table %s 2>/dev/null", RT_TABLE_ID));

    return { ok: code == 0, subsystem: SUBSYSTEM_ROUTING };
}

function repair_daemons_subsystem(drift_items, opts) {
    log("Reconciler: repairing auxiliary daemons subsystem...", "info");
    let repaired_daemons = [];
    let failed_daemons = [];

    for (let item in drift_items) {
        let daemon_id = item.daemon_id;
        if (!daemon_id) continue;

        log(sprintf("Reconciler: restarting daemon '%s'...", daemon_id), "info");
        let ok = false;

        if (daemon_id == "steer-zapret") {
            let code = command_status("/etc/init.d/tachyon-steer-zapret restart >/dev/null 2>&1");
            ok = code == 0;
        } else if (daemon_id == "zapret") {
            let cmd = sprintf("ucode -L %s %s/providers/zapret/runtime.uc start-runtime >/dev/null 2>&1", LIB_DIR, LIB_DIR);
            ok = command_status(cmd) == 0;
        } else if (daemon_id == "zapret2") {
            let cmd = sprintf("ucode -L %s %s/providers/zapret2/runtime.uc start-runtime >/dev/null 2>&1", LIB_DIR, LIB_DIR);
            ok = command_status(cmd) == 0;
        } else if (daemon_id == "byedpi") {
            let cmd = sprintf("ucode -L %s %s/providers/byedpi/runtime.uc start-runtime >/dev/null 2>&1", LIB_DIR, LIB_DIR);
            ok = command_status(cmd) == 0;
        } else if (daemon_id == "fptn") {
            let cmd = sprintf("ucode -L %s %s/providers/fptn/runtime.uc start-runtime >/dev/null 2>&1", LIB_DIR, LIB_DIR);
            ok = command_status(cmd) == 0;
        }

        if (ok)
            push(repaired_daemons, daemon_id);
        else
            push(failed_daemons, daemon_id);
    }

    return {
        ok: length(failed_daemons) == 0,
        subsystem: SUBSYSTEM_DAEMONS,
        repaired: repaired_daemons,
        failed: failed_daemons
    };
}

function execute_subsystem_repair(subsystem, drift_items, opts) {
    opts = opts || {};
    if (subsystem == SUBSYSTEM_ENGINE)
        return repair_engine_subsystem(drift_items, opts);
    if (subsystem == SUBSYSTEM_DAEMONS)
        return repair_daemons_subsystem(drift_items, opts);
    if (subsystem == SUBSYSTEM_ROUTING)
        return repair_routing_subsystem(drift_items, opts);
    if (subsystem == SUBSYSTEM_NFTABLES)
        return repair_nftables_subsystem(drift_items, opts);
    if (subsystem == SUBSYSTEM_DNS)
        return repair_dns_subsystem(drift_items, opts);

    return { ok: false, subsystem: subsystem, error: "unknown_subsystem" };
}

// ---------------------------------------------------------------------------
// CENTRAL RECONCILIATION ORCHESTRATOR
// ---------------------------------------------------------------------------

function reconcile(opts) {
    opts = opts || {};
    let target_subsystem = opts.subsystem || "";
    let dry_run = opts.dry_run == true;

    let initial_plan = plan(opts);
    if (initial_plan.clean) {
        log("Reconciler: system state is fully clean, no remediation needed", "debug");
        return {
            ok: true,
            changed: false,
            drifts: [],
            repaired: [],
            failed: []
        };
    }

    log(sprintf("Reconciler: detected %d drift(s) across subsystems", initial_plan.drift_count), "info");
    emit_event("reconcile.drift_detected", { count: initial_plan.drift_count, drifts: initial_plan.drifts });

    if (dry_run) {
        return {
            ok: true,
            dry_run: true,
            changed: false,
            drifts: initial_plan.drifts,
            actions_by_subsystem: initial_plan.actions_by_subsystem
        };
    }

    emit_event("reconcile.started", { target_subsystem: target_subsystem || "all" });

    let repaired = [];
    let failed = [];

    // Execute in strict dependency order:
    // Engine -> Auxiliary Daemons -> Routing -> Nftables -> DNS
    for (let sub in SUBSYSTEMS) {
        if (target_subsystem != "" && sub != target_subsystem)
            continue;

        let drift_items = initial_plan.actions_by_subsystem[sub];
        if (!drift_items || length(drift_items) == 0)
            continue;

        log(sprintf("Reconciler: repairing subsystem '%s' (%d drift items)...", sub, length(drift_items)), "info");

        let result = null;
        if (transaction && transaction.run) {
            // Execute inside transaction for audit logging & rollback resilience
            let tx_res = transaction.run("reconcile_" + sub, {
                plan: function(tx) { return { subsystem: sub, items: drift_items }; },
                preflight: function(tx) { return true; },
                snapshot: function(tx) { return true; },
                mutate: function(tx) {
                    return execute_subsystem_repair(sub, drift_items, opts);
                },
                validate: function(tx) { return true; },
                activate: function(tx) { return true; },
                verify: function(tx) { return true; }
            });
            result = tx_res && tx_res.mutate_result ? tx_res.mutate_result : { ok: tx_res && tx_res.ok };
        } else {
            result = execute_subsystem_repair(sub, drift_items, opts);
        }

        if (result && result.ok) {
            push(repaired, sub);
            emit_event("reconcile.repaired", { subsystem: sub, details: result });
        } else {
            push(failed, sub);
            emit_event("reconcile.failed", { subsystem: sub, details: result });
        }
    }

    // Verify final state
    let final_plan = plan(opts);
    let success = length(failed) == 0 && (target_subsystem != "" || final_plan.clean);

    log(sprintf("Reconciler: finished reconciliation. Repaired: [%s], Failed: [%s], Remaining drifts: %d",
        join(", ", repaired), join(", ", failed), final_plan.drift_count), success ? "info" : "warn");

    return {
        ok: success,
        changed: length(repaired) > 0,
        repaired: repaired,
        failed: failed,
        remaining_drifts: final_plan.drifts
    };
}

// ---------------------------------------------------------------------------
// EVENT BUS INTEGRATION (REMEDIATE BY EVENT FACT)
// ---------------------------------------------------------------------------

function reconcile_event(event_type, event_payload, opts) {
    opts = opts || {};
    if (!event_type) return { ok: false, reason: "empty_event" };

    log(sprintf("Reconciler: handling event trigger '%s'", event_type), "info");

    let sub_opts = {};
    for (let k, v in opts) sub_opts[k] = v;

    if (event_type == "dns.down" || event_type == "dns_down") {
        sub_opts.subsystem = SUBSYSTEM_DNS;
        return reconcile(sub_opts);
    }
    if (event_type == "nft.missing" || event_type == "nft_missing") {
        sub_opts.subsystem = SUBSYSTEM_NFTABLES;
        return reconcile(sub_opts);
    }
    if (event_type == "singbox.stopped" || event_type == "singbox_stopped") {
        sub_opts.subsystem = SUBSYSTEM_ENGINE;
        return reconcile(sub_opts);
    }
    if (event_type == "nfqueue.down" || event_type == "nfqueue_down") {
        sub_opts.subsystem = SUBSYSTEM_DAEMONS;
        return reconcile(sub_opts);
    }
    if (event_type == "firewall.reloaded" || event_type == "firewall_reloaded") {
        sub_opts.subsystem = SUBSYSTEM_NFTABLES;
        let r1 = reconcile(sub_opts);
        sub_opts.subsystem = SUBSYSTEM_ROUTING;
        let r2 = reconcile(sub_opts);
        return { ok: r1.ok && r2.ok, repaired: [ "nftables", "routing" ] };
    }
    if (event_type == "wan.down" || event_type == "wan_down") {
        sub_opts.subsystem = SUBSYSTEM_DNS;
        return reconcile(sub_opts);
    }

    // Default: full plan & targeted reconcile
    return reconcile(sub_opts);
}

// ---------------------------------------------------------------------------
// Module Exports
// ---------------------------------------------------------------------------

function module_exports() {
    return {
        // Subsystem constants
        SUBSYSTEM_ENGINE,
        SUBSYSTEM_DNS,
        SUBSYSTEM_NFTABLES,
        SUBSYSTEM_ROUTING,
        SUBSYSTEM_DAEMONS,
        SUBSYSTEMS,

        // Severity constants
        SEVERITY_CRITICAL,
        SEVERITY_HIGH,
        SEVERITY_MEDIUM,
        SEVERITY_LOW,

        // Actions
        ACTION_REPAIR_ENGINE,
        ACTION_REPAIR_DNS,
        ACTION_REPAIR_NFT_TABLE,
        ACTION_REPAIR_NFT_SETS,
        ACTION_REPAIR_ROUTING,
        ACTION_REPAIR_DAEMON,
        ACTION_RELOAD_SERVICE,

        // Core Functions
        get_desired_state,
        get_actual_state,
        diff_state,
        plan,
        reconcile,
        reconcile_event,

        // Subsystem Repairs
        repair_engine_subsystem,
        repair_dns_subsystem,
        repair_nftables_subsystem,
        repair_routing_subsystem,
        repair_daemons_subsystem
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

// ---------------------------------------------------------------------------
// CLI & Selftest
// ---------------------------------------------------------------------------

let mode = ARGV[0] || "";

let _test_pass = 0;
let _test_fail = 0;

function _assert(cond, msg) {
    if (cond) {
        _test_pass++;
    } else {
        _test_fail++;
        print("FAIL: " + msg + "\n");
    }
}

if (mode == "selftest") {
    _test_pass = 0;
    _test_fail = 0;

    // Test 1: Subsystems list
    _assert(length(SUBSYSTEMS) == 5, "Should have 5 core subsystems");
    _assert(index(SUBSYSTEMS, "engine") >= 0, "engine should be a subsystem");
    _assert(index(SUBSYSTEMS, "dns") >= 0, "dns should be a subsystem");
    _assert(index(SUBSYSTEMS, "nftables") >= 0, "nftables should be a subsystem");
    _assert(index(SUBSYSTEMS, "routing") >= 0, "routing should be a subsystem");
    _assert(index(SUBSYSTEMS, "daemons") >= 0, "daemons should be a subsystem");

    // Test 2: diff_state on clean synthetic state
    let clean_desired = {
        engine: { should_run: true, id: "sing-box", is_steer: false },
        dns: { manage_dnsmasq: true, smartdns_needed: false, expect_resolving: true },
        nftables: { table_needed: true, table_name: "TachyonTable", sets_needed: [ "localv4" ] },
        routing: { needed: true, table_name: "tachyon" },
        daemons: []
    };
    let clean_actual = {
        engine: { running: true, id: "sing-box" },
        dns: { dnsmasq_running: true, dnsmasq_managed: true, smartdns_running: false, resolving: true },
        nftables: { table_present: true, table_name: "TachyonTable", sets_present: [ "localv4" ], sets_missing: [], sets_empty: [] },
        routing: { rule4_present: true, rule6_present: true, route_present: true },
        daemons: []
    };

    let diff_clean = diff_state(clean_desired, clean_actual);
    _assert(diff_clean.clean == true, "Clean state should have clean == true");
    _assert(diff_clean.drift_count == 0, "Clean state should have 0 drifts");

    // Test 3: DNS drift detection
    let dns_dirty_actual = {
        engine: { running: true, id: "sing-box" },
        dns: { dnsmasq_running: true, dnsmasq_managed: false, smartdns_running: false, resolving: false },
        nftables: { table_present: true, table_name: "TachyonTable", sets_present: [ "localv4" ], sets_missing: [], sets_empty: [] },
        routing: { rule4_present: true, rule6_present: true, route_present: true },
        daemons: []
    };
    let diff_dns_dirty = diff_state(clean_desired, dns_dirty_actual);
    _assert(diff_dns_dirty.clean == false, "DNS dirty state should detect drift");
    _assert(diff_dns_dirty.drift_count >= 1, "Should have at least 1 drift for DNS");
    let has_dns_action = false;
    for (let d in diff_dns_dirty.drifts) {
        if (d.subsystem == "dns" && d.action == ACTION_REPAIR_DNS)
            has_dns_action = true;
    }
    _assert(has_dns_action == true, "Should require ACTION_REPAIR_DNS");

    // Test 4: NFT table missing detection
    let nft_missing_actual = {
        engine: { running: true, id: "sing-box" },
        dns: { dnsmasq_running: true, dnsmasq_managed: true, smartdns_running: false, resolving: true },
        nftables: { table_present: false, table_name: "TachyonTable", sets_present: [], sets_missing: [ "localv4" ], sets_empty: [] },
        routing: { rule4_present: true, rule6_present: true, route_present: true },
        daemons: []
    };
    let diff_nft = diff_state(clean_desired, nft_missing_actual);
    _assert(diff_nft.clean == false, "NFT missing table should detect drift");
    let has_nft_action = false;
    for (let d in diff_nft.drifts) {
        if (d.subsystem == "nftables" && d.action == ACTION_REPAIR_NFT_TABLE)
            has_nft_action = true;
    }
    _assert(has_nft_action == true, "Should require ACTION_REPAIR_NFT_TABLE");

    // Test 5: Engine stopped detection
    let eng_stopped_actual = {
        engine: { running: false, id: "sing-box" },
        dns: { dnsmasq_running: true, dnsmasq_managed: true, smartdns_running: false, resolving: true },
        nftables: { table_present: true, table_name: "TachyonTable", sets_present: [ "localv4" ], sets_missing: [], sets_empty: [] },
        routing: { rule4_present: true, rule6_present: true, route_present: true },
        daemons: []
    };
    let diff_eng = diff_state(clean_desired, eng_stopped_actual);
    _assert(diff_eng.clean == false, "Engine stopped should detect drift");
    let has_eng_action = false;
    for (let d in diff_eng.drifts) {
        if (d.subsystem == "engine" && d.action == ACTION_REPAIR_ENGINE)
            has_eng_action = true;
    }
    _assert(has_eng_action == true, "Should require ACTION_REPAIR_ENGINE");

    // Test 6: Daemons stopped detection
    let daemon_desired = {
        engine: { should_run: true, id: "sing-box", is_steer: false },
        dns: { manage_dnsmasq: true, smartdns_needed: false, expect_resolving: true },
        nftables: { table_needed: true, table_name: "TachyonTable", sets_needed: [] },
        routing: { needed: true, table_name: "tachyon" },
        daemons: [ { id: "zapret", name: "nfqws", kind: "provider", critical: false } ]
    };
    let daemon_dead_actual = {
        engine: { running: true, id: "sing-box" },
        dns: { dnsmasq_running: true, dnsmasq_managed: true, smartdns_running: false, resolving: true },
        nftables: { table_present: true, table_name: "TachyonTable", sets_present: [], sets_missing: [], sets_empty: [] },
        routing: { rule4_present: true, rule6_present: true, route_present: true },
        daemons: [ { id: "zapret", name: "nfqws", running: false } ]
    };
    let diff_daemon = diff_state(daemon_desired, daemon_dead_actual);
    _assert(diff_daemon.clean == false, "Dead daemon should detect drift");
    let has_daemon_action = false;
    for (let d in diff_daemon.drifts) {
        if (d.subsystem == "daemons" && d.action == ACTION_REPAIR_DAEMON)
            has_daemon_action = true;
    }
    _assert(has_daemon_action == true, "Should require ACTION_REPAIR_DAEMON");

    // Test 7: Dry run reconcile
    let dry_res = reconcile({ dry_run: true });
    _assert(dry_res != null, "reconcile dry_run should return result");
    _assert(dry_res.dry_run == true, "Result should flag dry_run == true");

    print(sprintf("Selftest complete: %d passed, %d failed\n", _test_pass, _test_fail));
    exit(_test_fail == 0 ? 0 : 1);
}
else if (mode == "desired") {
    let desired = get_desired_state();
    print(sprintf("%J\n", desired));
    exit(0);
}
else if (mode == "actual") {
    let desired = get_desired_state();
    let actual = get_actual_state(desired);
    print(sprintf("%J\n", actual));
    exit(0);
}
else if (mode == "plan") {
    let p = plan();
    print(sprintf("%J\n", p));
    exit(0);
}
else if (mode == "status") {
    let p = plan();
    print(sprintf("%J\n", {
        clean: p.clean,
        drift_count: p.drift_count,
        drifts: p.drifts
    }));
    exit(0);
}
else if (mode == "apply" || mode == "sync") {
    let target_subsystem = ARGV[1] || "";
    let dry_run = false;
    if (target_subsystem == "--dry-run" || target_subsystem == "dry-run" || target_subsystem == "-n") {
        target_subsystem = "";
        dry_run = true;
    } else if (ARGV[2] == "--dry-run" || ARGV[2] == "dry-run" || ARGV[2] == "-n") {
        dry_run = true;
    }
    let res = reconcile({ subsystem: target_subsystem, dry_run: dry_run });
    print(sprintf("%J\n", res));
    exit(res.ok ? 0 : 1);
}
else if (mode == "event") {
    let ev_name = ARGV[1] || "";
    let dry_run = ARGV[2] == "--dry-run" || ARGV[2] == "dry-run" || ARGV[2] == "-n";
    let res = reconcile_event(ev_name, {}, { dry_run: dry_run });
    print(sprintf("%J\n", res));
    exit(res.ok ? 0 : 1);
}
else {
    print("Usage: service/reconciler.uc <selftest|desired|actual|plan|status|apply [subsystem] [dry-run]|event <name> [dry-run]>\n");
    exit(1);
}
