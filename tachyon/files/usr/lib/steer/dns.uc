#!/usr/bin/env ucode
//
// steer/dns.uc - DNS upstream resolver for the steer routing engine.
//
// When sing-box is the active engine it provides a local DNS inbound at
// 127.0.0.42:53 that resolves domains through the configured DNS server
// (DoH/DoT/UDP). steer does not run sing-box, so there is no such inbound;
// steer dnsd defaults to the system resolver on port 53, which ISPs often
// intercept and which cannot use DoH.
//
// This module bridges the gap: it reads the same tachyon DNS settings
// (dns_type, dns_server, bootstrap_dns_server, dns_fallback_server) that
// sing-box uses, generates a smartdns configuration file, and starts
// smartdns as a background process. The port smartdns listens on is written
// to a well-known file so that steer init.d can pass it as --upstream-port
// when launching steer dnsd.
//
// Lifecycle commands (called by service/lifecycle.uc):
//   start-runtime   -- generate config, start smartdns, write port file
//   stop-runtime    -- kill smartdns, remove port file
//   check-health    -- probe that smartdns is alive and responding
//   is-available    -- exit 0 if smartdns binary is present
//
// For sing-box engine this module is NOT called.
//

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");
let runtime_url = require("core.url");

let as_string = common.as_string;
let shell_quote = common.shell_quote;
let command_from_args = common.command_from_args;
let command_status = common.command_status;
let command_success_from_args = common.command_success_from_args;
let background_command_with_pid = common.background_command_with_pid;
let file_first_line = common.file_first_line;
let ensure_dir = common.ensure_dir;
let remove_file = common.remove_file;
let option = common.option;
let list_option = common.list_option;
let object_or_empty = common.object_or_empty;

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const RUNTIME_STATE_DIR = getenv("TACHYON_RUNTIME_STATE_DIR") || "/var/run/tachyon";

// The port smartdns listens on for steer dnsd upstream queries.
const STEER_DNS_PORT = int(getenv("TACHYON_STEER_DNS_PORT") || "5354");

// Files written by this module and read by steer init.d / watchdog.
const SMARTDNS_CONF_FILE = getenv("TACHYON_STEER_DNS_CONF") || "/tmp/tachyon-steer-smartdns.conf";
const SMARTDNS_PID_FILE = getenv("TACHYON_STEER_DNS_PID") || RUNTIME_STATE_DIR + "/steer-smartdns.pid";
const UPSTREAM_PORT_FILE = RUNTIME_STATE_DIR + "/steer-dns-upstream-port";

const SMARTDNS_BIN = getenv("TACHYON_SMARTDNS_BIN") || "/usr/sbin/smartdns";

function settings() {
    return object_or_empty(uci_core.get_all(CONFIG_NAME, "settings"));
}

function log_message(message, level) {
    command_success_from_args([
        "logger", "-t", "tachyon",
        "[" + as_string(level || "info") + "] steer-dns: " + as_string(message)
    ]);
}

// ---------------------------------------------------------------------------
// Detect whether smartdns is available on this device.
// ---------------------------------------------------------------------------
function smartdns_available() {
    return command_success_from_args([ "test", "-x", SMARTDNS_BIN ]);
}

// ---------------------------------------------------------------------------
// Find the primary outbound interface from the steer spec.
// DNS traffic routes through the same interface as user traffic.
// Returns "" if not found (smartdns uses the default route).
// ---------------------------------------------------------------------------
function find_main_interface() {
    let spec_data = fs.readfile("/etc/steer/spec.json");
    if (!spec_data)
        return "";
    let spec = null;
    try { spec = json(spec_data); } catch(e) { return ""; }
    let outputs = object_or_empty(spec.outputs);
    for (let name in outputs) {
        let out = outputs[name];
        if (as_string(out.kind) == "interface") {
            let devices = out.devices || [];
            if (length(devices) > 0)
                return as_string(devices[0]);
        }
    }
    return "";
}

// ---------------------------------------------------------------------------
// Build a single server-line for smartdns.
// Returns null for unsupported types (doq).
// ---------------------------------------------------------------------------
function server_line(dns_type, address, iface) {
    dns_type = as_string(dns_type || "udp");
    address = as_string(address || "");
    if (address == "")
        return null;

    let iface_suffix = (as_string(iface) != "") ? " -interface " + iface : "";
    // All primary servers go into the steer-dns group so we can reference them
    // with a single nameserver directive.
    let group_suffix = " -group steer-dns -exclude-default-group";
    let common_suffix = iface_suffix + group_suffix;

    if (dns_type == "udp")
        return "server " + address + common_suffix;
    if (dns_type == "doh")
        return "server-https " + address + common_suffix;
    if (dns_type == "dot") {
        let server = runtime_url.host(address);
        let port = runtime_url.port(address);
        let addr_str = (server != "" ? server : address);
        if (port != "")
            addr_str += ":" + port;
        return "server-tls " + addr_str + common_suffix;
    }
    return null;  // doq: not supported by smartdns
}

// ---------------------------------------------------------------------------
// Generate the full smartdns config text.
// ---------------------------------------------------------------------------
function generate_config(cfg, iface) {
    let dns_type = as_string(option(cfg, "dns_type", "udp"));
    let dns_servers = list_option(cfg, "dns_server");
    let fallback_servers = list_option(cfg, "dns_fallback_server");
    let bootstrap_servers = list_option(cfg, "bootstrap_dns_server");

    // Primary DNS server lines (all configured primaries, in order).
    let primary_lines = [];
    for (let srv in dns_servers) {
        let line = server_line(dns_type, srv, iface);
        if (line != null)
            push(primary_lines, line);
    }
    // Explicit fallback servers -- always plain UDP, no interface binding (same as sing-box).
    for (let srv in fallback_servers) {
        let line = server_line("udp", srv, "");
        if (line != null)
            push(primary_lines, line);
    }
    // Nothing configured: use Cloudflare DoH as a safe default.
    if (length(primary_lines) == 0) {
        let fallback_type = (dns_type == "udp") ? "doh" : dns_type;
        let fallback_line = server_line(fallback_type, "https://cloudflare-dns.com/dns-query", iface);
        push(primary_lines, fallback_line || "server 1.1.1.1" + " -group steer-dns -exclude-default-group");
    }

    // Bootstrap servers for resolving DoH/DoT hostnames (plain UDP, default group).
    let bootstrap_lines = [];
    for (let srv in bootstrap_servers) {
        srv = as_string(srv);
        if (srv != "")
            push(bootstrap_lines, "server " + srv + " -group bootstrap -exclude-default-group");
    }

    let lines = [
        "# Generated by tachyon steer/dns.uc -- do not edit manually.",
        "bind 127.0.0.1:" + as_string(STEER_DNS_PORT),
        
        "speed-check-mode none",
        "log-level fatal",
        "",
    ];

    if (length(bootstrap_lines) > 0) {
        push(lines, "# Bootstrap resolvers (plain UDP) for DoH/DoT hostname lookup");
        for (let bl in bootstrap_lines)
            push(lines, bl);
        // Forward DoH/DoT hostnames through bootstrap group.
        push(lines, "nameserver /cloudflare-dns.com/bootstrap");
        push(lines, "nameserver /dns.google/bootstrap");
        push(lines, "nameserver /dns.quad9.net/bootstrap");
        push(lines, "nameserver /dns.adguard-dns.com/bootstrap");
        push(lines, "nameserver /freedns.controld.com/bootstrap");
        push(lines, "nameserver /dns.mullvad.net/bootstrap");
        push(lines, "nameserver /odvr.nic.cz/bootstrap");
        push(lines, "nameserver /zero.dns0.eu/bootstrap");
        push(lines, "");
    }

    push(lines, "# Primary DNS (" + dns_type + ")");
    for (let pl in primary_lines)
        push(lines, pl);
    push(lines, "");

    // Route all queries through the steer-dns group.
    push(lines, "nameserver //" + "steer-dns");
    push(lines, "");

    return join("\n", lines);
}

// ---------------------------------------------------------------------------
// Atomic config write (tmp + rename).
// ---------------------------------------------------------------------------
function write_config(content) {
    let tmp = SMARTDNS_CONF_FILE + ".tmp." + int(time());
    if (fs.writefile(tmp, content) == null) {
        try { fs.unlink(tmp); } catch(e) {}
        return false;
    }
    if (!fs.rename(tmp, SMARTDNS_CONF_FILE)) {
        try { fs.unlink(tmp); } catch(e) {}
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Write / remove the port file read by steer init.d.
// ---------------------------------------------------------------------------
function write_upstream_port_file(port) {
    if (!ensure_dir(RUNTIME_STATE_DIR))
        return false;
    return fs.writefile(UPSTREAM_PORT_FILE, as_string(port) + "\n") != null;
}

// ---------------------------------------------------------------------------
// Process management
// ---------------------------------------------------------------------------
function process_running(pid) {
    pid = as_string(pid || "");
    if (!match(pid, /^[0-9]+$/))
        return false;
    return command_success_from_args([ "kill", "-0", pid ]);
}

function smartdns_running() {
    return process_running(file_first_line(SMARTDNS_PID_FILE));
}

function stop_runtime() {
    let pid = file_first_line(SMARTDNS_PID_FILE);
    if (process_running(pid))
        command_success_from_args([ "kill", "-9", pid ]);
    remove_file(SMARTDNS_PID_FILE);
    remove_file(UPSTREAM_PORT_FILE);
    // Belt-and-suspenders: kill any stale smartdns using our config file.
    system(common.kill_matching_command(shell_quote(SMARTDNS_CONF_FILE)));
    return 0;
}

function start_runtime() {
    let cfg = settings();

    if (!smartdns_available()) {
        log_message("smartdns not found at " + SMARTDNS_BIN +
            "; DNS upstream for steer will use system resolver (port 53)", "warn");
        return 0;  // non-fatal: steer dnsd falls back to default port 53
    }

    stop_runtime();

    let iface = find_main_interface();
    let config = generate_config(cfg, iface);

    if (!ensure_dir(RUNTIME_STATE_DIR)) {
        log_message("Cannot create runtime state dir " + RUNTIME_STATE_DIR, "error");
        return 1;
    }

    if (!write_config(config)) {
        log_message("Failed to write smartdns config " + SMARTDNS_CONF_FILE, "error");
        return 1;
    }

    // Start smartdns in the foreground as a background shell job.
    // -f  foreground mode (we background it ourselves with & for clean PID capture)
    // -p  - means don't write smartdns own pid file (we capture it via $!)
    let command = background_command_with_pid(
        command_from_args([ SMARTDNS_BIN, "-f", "-c", SMARTDNS_CONF_FILE, "-p", "-" ]),
        ">/dev/null",
        ">" + shell_quote(SMARTDNS_PID_FILE)
    );
    let status = command_status(command);
    if (status != 0) {
        log_message("Failed to start smartdns (exit " + as_string(status) + ")", "error");
        remove_file(SMARTDNS_PID_FILE);
        return 1;
    }

    if (!write_upstream_port_file(STEER_DNS_PORT))
        log_message("Failed to write upstream port file " + UPSTREAM_PORT_FILE + " (non-fatal)", "warn");

    log_message("started on 127.0.0.1:" + as_string(STEER_DNS_PORT) +
        (iface != "" ? " via " + iface : ", default route") +
        "; steer dnsd upstream-port=" + as_string(STEER_DNS_PORT), "info");
    return 0;
}

// ---------------------------------------------------------------------------
// Health check -- called by watchdog.
// ---------------------------------------------------------------------------
function check_health() {
    if (!smartdns_available())
        return 0;  // not installed -> no health check needed
    if (!smartdns_running())
        return 1;
    // Quick DNS probe with dig if available.
    let ok = command_success_from_args([
        "sh", "-c",
        "dig +short +time=2 +tries=1 @127.0.0.1 -p " + as_string(STEER_DNS_PORT) +
        " example.com A </dev/null 2>/dev/null | grep -qE '^[0-9]'"
    ]);
    return ok ? 0 : 1;
}

// ---------------------------------------------------------------------------
// CLI dispatch
// ---------------------------------------------------------------------------
let mode = ARGV[0] || "";

if (mode == "start-runtime")
    exit(start_runtime());
else if (mode == "stop-runtime")
    exit(stop_runtime());
else if (mode == "check-health")
    exit(check_health());
else if (mode == "is-available")
    exit(smartdns_available() ? 0 : 1);
else {
    warn("Usage: steer/dns.uc <start-runtime|stop-runtime|check-health|is-available>\n");
    exit(1);
}