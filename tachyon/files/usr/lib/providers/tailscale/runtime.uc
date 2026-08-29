#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");

// NOTE: ucode does not hoist function declarations - a callee must be
// textually defined above its first caller. Keep that order intact.

let as_string = common.as_string;
let bool_value = common.bool_value;
let write_json = common.write_json;
let shell_quote = common.shell_quote;
let write_file = common.write_file;
let command_from_args = common.command_from_args;
let command_output = common.command_output;
let command_output_from_args = common.command_output_from_args;
let command_status = common.command_status;
let command_success_from_args = common.command_success_from_args;
let object_or_empty = common.object_or_empty;
let object_key_count = common.object_key_count;
let array_or_empty = common.array_or_empty;
let option = common.option;
let parent_dir = common.parent_dir;

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const TAILSCALE_BIN = getenv("TAILSCALE_BIN") || "/usr/sbin/tailscale";
const TAILSCALED_BIN = getenv("TAILSCALED_BIN") || "/usr/sbin/tailscaled";
const PERSISTENT_STATE_BASE = getenv("TAILSCALE_STATE_BASE") || "/etc/tachyon/tailscale";
const RUNTIME_DIR = getenv("TAILSCALE_RUNTIME_DIR") || "/var/run/tachyon/tailscale";
const TAILSCALED_PORT = getenv("TAILSCALED_PORT") || "41641";
const DEFAULT_CONTROL_URL = "https://controlplane.tailscale.com";
const MAGICDNS_DNSMASQ_FILE = getenv("TAILSCALE_DNSMASQ_FILE") || "/tmp/dnsmasq.d/tachyon-tailscale.conf";
const MAGICDNS_ADDRESS = getenv("TAILSCALE_MAGICDNS_ADDRESS") || "100.100.100.100";

// Marks live inside the mask reserved by the config validator (0x00ff0000):
// no other Tachyon engine may allocate bits there.
const TS_MARK_MASK = getenv("TAILSCALE_MARK_MASK") || "0x00ff0000";
const TS_MARK_EXIT_NODE = getenv("TAILSCALE_MARK_EXIT") || "0x00200000";
const TS_ROUTE_TABLE = getenv("TAILSCALE_ROUTE_TABLE") || "4247";
const TS_EXIT_TABLE = getenv("TAILSCALE_EXIT_TABLE") || "4248";
const TS_RULE_PRIORITY = getenv("TAILSCALE_RULE_PRIORITY") || "100";
const TS_EXIT_RULE_PRIORITY = getenv("TAILSCALE_EXIT_RULE_PRIORITY") || "90";

// Tailnet CGNAT ranges every peer address lives in.
const TAILNET_V4 = "100.64.0.0/10";
const TAILNET_V6 = "fd7a:115c:a1e0::/48";
// Destinations that must never be pushed through an exit node tunnel.
const EXIT_NODE_EXCLUDES_V4 = [
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16",
    "100.64.0.0/10", "127.0.0.0/8", "224.0.0.0/4", "240.0.0.0/4"
];
const EXIT_NODE_EXCLUDES_V6 = [ "fc00::/7", "fe80::/10", "ff00::/8" ];

const NFT_TS_TABLE = "tachyon_tailscale";

function log_message(message, level) {
    level = as_string(level || "info");
    command_success_from_args([ "logger", "-t", "tachyon", "[tailscale] [" + level + "] " + as_string(message) ]);
}

function bool_option(section, key, fallback) {
    let value = object_or_empty(section)[key];
    return value == null ? !!fallback : bool_value(value);
}

function list_option(section, key) {
    let value = object_or_empty(section)[key];
    if (value == null)
        return [];
    if (type(value) != "array")
        value = [ value ];
    let result = [];
    for (let item in value) {
        item = trim(as_string(item));
        if (item != "")
            push(result, item);
    }
    return result;
}

function section_name(section) {
    return as_string(object_or_empty(section)[".name"]);
}

function uci_sections(type_name) {
    return uci_core.section_objects(CONFIG_NAME, as_string(type_name));
}

function is_native_mode(section) {
    return as_string(option(section, "tailscale_mode", "") || "") == "native";
}

function native_tailscale_sections() {
    let result = [];
    for (let section in uci_sections("server")) {
        if (!bool_option(section, "enabled", true))
            continue;
        if (as_string(option(section, "protocol", "")) != "tailscale")
            continue;
        if (!is_native_mode(section))
            continue;
        push(result, section);
    }
    return result;
}

function safe_filename(name) {
    name = as_string(name);
    name = replace(name, /[^a-zA-Z0-9_-]/g, "_");
    return name == "" ? "section" : name;
}

function section_state_dir(section) {
    return PERSISTENT_STATE_BASE + "/" + safe_filename(section_name(section)) + "/native";
}

function section_runtime_dir(section) {
    return RUNTIME_DIR + "/" + safe_filename(section_name(section));
}

function section_pid_file(section) {
    return section_runtime_dir(section) + "/tailscaled.pid";
}

function command_exists(name) {
    return command_success_from_args([ "command", "-v", name ]);
}

function binary_available() {
    return command_exists("tailscaled") && command_exists("tailscale");
}

function read_pid(path) {
    let raw = trim(as_string(fs.readfile(path)) || "");
    if (raw == "" || int(raw) <= 0)
        return 0;
    return int(raw);
}

function pid_alive(pid) {
    if (pid <= 0)
        return false;
    return command_success_from_args([ "kill", "-0", as_string(pid) ]);
}

function running_pid(section) {
    return pid_alive(read_pid(section_pid_file(section)));
}

function package_installed() {
    if (command_exists("apk") && command_success_from_args([ "apk", "info", "-e", "tailscale" ]))
        return true;
    if (!command_exists("opkg"))
        return false;
    for (let line in split(command_output_from_args([ "opkg", "list-installed" ]), "\n")) {
        if (match(trim(as_string(line)), /^tailscale[ \t]+-/))
            return true;
    }
    return false;
}

function daemon_version() {
    if (!binary_available())
        return "";
    let out = trim(command_output_from_args([ "tailscale", "version" ]));
    if (out == "")
        return "";
    return split(out, "\n")[0];
}

function ensure_dirs(section) {
    let state_dir = section_state_dir(section);
    let runtime_dir = section_runtime_dir(section);
    if (!command_success_from_args([ "mkdir", "-p", state_dir, runtime_dir ]))
        return false;
    // The daemon stores node identity here; it must survive reboots and resets.
    fs.chmod(state_dir, 448);
    return true;
}

function run_step(description, args) {
    let status = command_status(command_from_args(args));
    if (status != 0) {
        log_message(description + " failed (exit " + as_string(status) + ")", "warn");
        return false;
    }
    log_message(description + ": ok", "debug");
    return true;
}

function tailscale_client_args(section) {
    let runtime_dir = section_runtime_dir(section);
    return [ TAILSCALE_BIN, "--socket", runtime_dir + "/tailscaled.sock" ];
}

function remove_magicdns_dns() {
    fs.unlink(MAGICDNS_DNSMASQ_FILE);
    command_status(command_from_args([ "/etc/init.d/dnsmasq", "restart" ]) + " >/dev/null 2>&1");
}

function remove_kernel_routing(keep_dns) {
    command_status(command_from_args([ "ip", "rule", "del", "to", TAILNET_V4,
        "priority", TS_RULE_PRIORITY, "table", TS_ROUTE_TABLE ]) + " 2>/dev/null");
    command_status(command_from_args([ "ip", "-6", "rule", "del", "to", TAILNET_V6,
        "priority", TS_RULE_PRIORITY, "table", TS_ROUTE_TABLE ]) + " 2>/dev/null");
    command_status(command_from_args([ "ip", "route", "flush", "table", TS_ROUTE_TABLE ]) + " 2>/dev/null");
    command_status(command_from_args([ "ip", "-6", "route", "flush", "table", TS_ROUTE_TABLE ]) + " 2>/dev/null");
    command_status(command_from_args([ "ip", "rule", "del", "fwmark", TS_MARK_EXIT_NODE + "/" + TS_MARK_MASK,
        "priority", TS_EXIT_RULE_PRIORITY, "table", TS_EXIT_TABLE ]) + " 2>/dev/null");
    command_status(command_from_args([ "ip", "route", "flush", "table", TS_EXIT_TABLE ]) + " 2>/dev/null");
    command_status(command_from_args([ "nft", "delete", "table", "inet", NFT_TS_TABLE ]) + " 2>/dev/null");
    if (!keep_dns)
        remove_magicdns_dns();
}

function install_exit_node_routing() {
    // Opt-in: forward all non-local LAN traffic through the tailnet exit node.
    // Marked packets are skipped by Tachyon's mangle chain (mask-based return),
    // so they never enter tproxy, then follow the dedicated routing table.
    command_status(command_from_args([ "ip", "rule", "del", "fwmark", TS_MARK_EXIT_NODE + "/" + TS_MARK_MASK,
        "priority", TS_EXIT_RULE_PRIORITY, "table", TS_EXIT_TABLE ]) + " 2>/dev/null");
    command_status(command_from_args([ "ip", "route", "flush", "table", TS_EXIT_TABLE ]) + " 2>/dev/null");

    let nft_lines = [
        "table inet " + NFT_TS_TABLE + " {",
        "    set exit_exclude_v4 { type ipv4_addr; flags interval; elements = { " + join(", ", EXIT_NODE_EXCLUDES_V4) + " } }",
        "    set exit_exclude_v6 { type ipv6_addr; flags interval; elements = { " + join(", ", EXIT_NODE_EXCLUDES_V6) + " } }",
        "    chain prerouting_mark {",
        "        type filter hook prerouting priority -150; policy accept;",
        "        meta mark & " + TS_MARK_MASK + " != 0 return",
        "        ip daddr @exit_exclude_v4 return",
        "        ip6 daddr @exit_exclude_v6 return",
        "        meta mark set " + TS_MARK_EXIT_NODE + " comment \"tachyon-tailscale exit-node\"",
        "    }",
        "}"
    ];
    if (command_status("nft -f - <<'EOF'\n" + join("\n", nft_lines) + "\nEOF\n") != 0) {
        log_message("Failed to install exit-node marking rules", "warn");
        return false;
    }
    let ok =
        run_step("Adding exit-node route rule", [ "ip", "rule", "add", "fwmark", TS_MARK_EXIT_NODE + "/" + TS_MARK_MASK,
            "priority", TS_EXIT_RULE_PRIORITY, "table", TS_EXIT_TABLE ]) &&
        run_step("Adding exit-node default route", [ "ip", "route", "add", "default", "dev", "tailscale0", "table", TS_EXIT_TABLE ]);
    if (!ok)
        log_message("Exit-node routing setup failed", "warn");
    return ok;
}

function configure_firewall(section) {
    // Masquerade LAN sources leaving through the tunnel unless the user opted
    // out; without SNAT peers cannot answer addresses they don't know.
    let masquerade = bool_option(section, "tailscale_masquerade", true);
    let nft_lines = [
        "table inet " + NFT_TS_TABLE + " {",
        "    chain postrouting_snat {",
        "        type nat hook postrouting priority 110; policy accept;",
        "        oifname \"tailscale0\" ip saddr " + TAILNET_V4 + " return",
        "        oifname \"tailscale0\" ip6 saddr " + TAILNET_V6 + " return"
    ];
    if (masquerade)
        push(nft_lines, "        oifname \"tailscale0\" counter masquerade");
    push(nft_lines, "    }");
    push(nft_lines, "}");
    if (command_status("nft -f - <<'EOF'\n" + join("\n", nft_lines) + "\nEOF\n") != 0) {
        log_message("Failed to install tailscale firewall rules", "warn");
        return false;
    }
    return true;
}

function configure_magicdns_dns() {
    // Hand *.ts.net to the tailnet resolver without letting tailscaled touch
    // resolv.conf; dnsmasq picks the file up from its conf-dir.
    if (!command_success_from_args([ "mkdir", "-p", parent_dir(MAGICDNS_DNSMASQ_FILE) ]))
        return false;
    let lines = [
        "# Managed by Tachyon native Tailscale runtime",
        "server=/ts.net/" + MAGICDNS_ADDRESS
    ];
    if (!write_file(MAGICDNS_DNSMASQ_FILE, join("\n", lines) + "\n")) {
        log_message("Failed to write MagicDNS dnsmasq config", "warn");
        return false;
    }
    command_status(command_from_args([ "/etc/init.d/dnsmasq", "restart" ]) + " >/dev/null 2>&1");
    return true;
}

function install_kernel_routing(section) {
    // Steer tailnet-bound traffic into the tunnel before Tachyon's policy
    // routing (fwmark rule at priority 105) can send it into tproxy.
    // Start from a clean slate so restarts never stack duplicate rules.
    remove_kernel_routing(true);

    let installed =
        run_step("Adding IPv4 tailnet route", [ "ip", "route", "add", TAILNET_V4, "dev", "tailscale0", "table", TS_ROUTE_TABLE ]) &&
        run_step("Adding IPv6 tailnet route", [ "ip", "-6", "route", "add", TAILNET_V6, "dev", "tailscale0", "table", TS_ROUTE_TABLE ]) &&
        run_step("Adding IPv4 route rule", [ "ip", "rule", "add", "to", TAILNET_V4, "priority", TS_RULE_PRIORITY, "table", TS_ROUTE_TABLE ]) &&
        run_step("Adding IPv6 route rule", [ "ip", "-6", "rule", "add", "to", TAILNET_V6, "priority", TS_RULE_PRIORITY, "table", TS_ROUTE_TABLE ]);
    if (!installed) {
        log_message("Kernel routing setup failed for " + section_name(section), "warn");
        return false;
    }

    if (bool_option(section, "tailscale_use_exit_node", false))
        install_exit_node_routing();
    configure_firewall(section);
    configure_magicdns_dns();
    return true;
}

// The official package ships its own init script; if it autostarted at boot,
// its daemon holds UDP 41641 and ours dies instantly. Neutralize it the same
// way component install does - stop + disable, idempotent.
function file_executable(path) {
    let st = fs.stat(path);
    return st != null && st.mode != null && (int(st.mode) & 73) != 0;
}

function neutralize_standalone_service() {
    let init = "/etc/init.d/tailscale";
    if (!file_executable(init))
        return;
    command_status(command_from_args([ init, "stop" ]) + " >/dev/null 2>&1");
    command_status(command_from_args([ init, "disable" ]) + " >/dev/null 2>&1");
    log_message("standalone tailscale service stopped and disabled", "info");
}

function log_file_tail(path) {
    let data = "";
    try {
        data = as_string(fs.readfile(path)) || "";
    } catch (e) {
        return "";
    }
    let lines = split(trim(data), "\n");
    let start = length(lines) > 5 ? length(lines) - 5 : 0;
    let tail = [];
    for (let i = start; i < length(lines); i++)
        push(tail, lines[i]);
    return join(" | ", tail);
}

function start_daemon(section) {
    if (running_pid(section)) {
        log_message("tailscaled for " + section_name(section) + " already running", "debug");
        return true;
    }

    neutralize_standalone_service();

    let runtime_dir = section_runtime_dir(section);
    let socket_path = runtime_dir + "/tailscaled.sock";
    let log_file = runtime_dir + "/tailscaled.log";
    let state_dir = section_state_dir(section);

    let args = [
        TAILSCALED_BIN,
        "--tun=tailscale0",
        "--statedir=" + state_dir,
        "--socket=" + socket_path,
        "--port=" + TAILSCALED_PORT
    ];

    fs.unlink(log_file);
    let cmdline = command_from_args(args) +
        " >" + shell_quote(log_file) + " 2>&1 </dev/null & echo $!";
    let output = trim(command_output(cmdline));
    let pid = int(output);
    if (pid <= 0) {
        log_message("Failed to spawn tailscaled for " + section_name(section), "warn");
        return false;
    }
    write_file(section_pid_file(section), as_string(pid));

    // Wait until the client socket answers before running `up`. Probe parses
    // JSON instead of trusting the exit code: an unlogged-in node answers
    // with BackendState=NeedsLogin and a non-zero exit code, which must still
    // count as "daemon ready".
    for (let attempt = 0; attempt < 30; attempt++) {
        let probe = command_output_from_args([ TAILSCALE_BIN, "--socket", socket_path, "status", "--json", "--peers=false" ]);
        if (index(as_string(probe), "\"BackendState\"") >= 0)
            return true;
        if (!pid_alive(pid))
            break;
        command_success_from_args([ "sleep", "1" ]);
    }

    let tail = log_file_tail(log_file);
    if (!pid_alive(pid))
        log_message("tailscaled for " + section_name(section) + " exited during startup; log tail: " + (tail == "" ? "<empty>" : tail), "warn");
    else
        log_message("tailscaled did not become ready for " + section_name(section) + "; log tail: " + (tail == "" ? "<empty>" : tail), "warn");
    return false;
}

function bring_up(section) {
    let args = tailscale_client_args(section);
    push(args, "up");
    push(args, "--authkey=" + as_string(option(section, "tailscale_auth_key", "") || ""));
    let hostname = as_string(option(section, "tailscale_hostname", "") || "");
    if (hostname != "")
        push(args, "--hostname=" + hostname);
    let control_url = as_string(option(section, "tailscale_control_url", DEFAULT_CONTROL_URL) || DEFAULT_CONTROL_URL);
    if (control_url != "" && control_url != DEFAULT_CONTROL_URL)
        push(args, "--login-server=" + control_url);
    if (bool_option(section, "tailscale_accept_routes", false))
        push(args, "--accept-routes");
    let advertise_routes = list_option(section, "tailscale_advertise_routes");
    if (length(advertise_routes) > 0)
        push(args, "--advertise-routes=" + join(",", advertise_routes));
    else
        push(args, "--advertise-routes=");
    if (bool_option(section, "tailscale_advertise_exit_node", false))
        push(args, "--advertise-exit-node");
    else
        push(args, "--advertise-exit-node=false");
    // DNS stays under dnsmasq/Tachyon control; MagicDNS names are resolved
    // through the dedicated dnsmasq forward instead of resolv.conf takeover.
    push(args, "--accept-dns=false");
    // Never block the runtime on interactive prompts or dead control planes.
    push(args, "--timeout=120s");
    push(args, "--reset");

    if (!run_step("tailscale up (" + section_name(section) + ")", args))
        return false;
    return install_kernel_routing(section);
}

function stop_section(section) {
    let down_args = tailscale_client_args(section);
    push(down_args, "down");
    command_status(command_from_args(down_args) + " 2>/dev/null");
    let pid_file = section_pid_file(section);
    let pid = read_pid(pid_file);
    if (pid_alive(pid)) {
        command_success_from_args([ "kill", as_string(pid) ]);
        for (let attempt = 0; attempt < 10 && pid_alive(pid); attempt++)
            command_success_from_args([ "sleep", "1" ]);
        if (pid_alive(pid))
            command_success_from_args([ "kill", "-9", as_string(pid) ]);
    }
    fs.unlink(pid_file);
}

function backend_state() {
    if (!binary_available())
        return "";
    let out = trim(command_output_from_args([ TAILSCALE_BIN, "status", "--json", "--peers=false" ]));
    if (out == "")
        return "";
    let parsed = json(out);
    return as_string(object_or_empty(parsed)["BackendState"] || "");
}

function status_json() {
    let sections = native_tailscale_sections();
    let configured = length(sections) > 0;
    let available = binary_available();
    let pkg = package_installed();
    let version = available ? (daemon_version() || "unknown") : "not installed";

    let running = 0;
    let states = {};
    for (let section in sections) {
        if (running_pid(section)) {
            running++;
            let state = backend_state();
            if (state != "")
                states[section_name(section)] = state;
        }
    }

    let message = "tailscale provider status is normal";
    if (configured && !available)
        message = "native Tailscale is configured, but the tailscale package is missing; install it on the Updates tab";
    else if (configured && running < length(sections))
        message = "native Tailscale is configured, but tailscaled is not running for every section";
    else if (!configured && available)
        message = "Tailscale package is installed, but no server section uses native mode";
    else if (!configured && !available)
        message = "tailscale package is not installed; native Tailscale is unavailable";

    write_json({
        installed: available,
        package_installed: pkg,
        provider_available: available,
        provider_path: TAILSCALED_BIN,
        version,
        configured,
        expected_process_count: length(sections),
        running_process_count: running,
        backend_states: states,
        ready: configured && available && running == length(sections) && length(sections) > 0,
        conflict: running > length(sections),
        status_message: message
    });
}

function check_json() {
    write_json({
        tailscale_installed: binary_available(),
        tailscale_package_installed: package_installed(),
        tailscale_provider_path: TAILSCALED_BIN
    });
}

function peer_entry(peer) {
    peer = object_or_empty(peer);
    return {
        name: as_string(peer["HostName"] || ""),
        dns_name: as_string(peer["DNSName"] || ""),
        ips: array_or_empty(peer["TailscaleIPs"]),
        online: peer["Online"] == true
    };
}

// Tailnet peers of the first native section, via its per-section socket.
// All Tachyon-managed sections are separate nodes; the dashboard shows the
// first one (users run a single native section in practice).
function peers_json() {
    let sections = native_tailscale_sections();
    if (!binary_available() || length(sections) == 0) {
        write_json({ configured: false, backend_state: "", self: null, peers: [] });
        return;
    }

    let args = tailscale_client_args(sections[0]);
    push(args, "status");
    push(args, "--json");
    let out = trim(command_output_from_args(args));

    let backend_state = "";
    let self_entry = null;
    let peers = [];
    if (out != "") {
        let parsed = object_or_empty(json(out));
        backend_state = as_string(parsed["BackendState"] || "");
        let self = object_or_empty(parsed["Self"]);
        if (object_key_count(self) > 0) {
            self_entry = peer_entry(self);
            self_entry.online = true;
        }
        let peer_map = object_or_empty(parsed["Peer"]);
        for (let key, peer in peer_map)
            push(peers, peer_entry(peer));
    }

    write_json({
        configured: true,
        backend_state,
        self: self_entry,
        peers
    });
}

function stop_runtime() {
    for (let section in native_tailscale_sections())
        stop_section(section);
    // Also clean leftovers for sections that disappeared from the config.
    try {
        let dir = fs.opendir(RUNTIME_DIR);
        if (dir) {
            let entry;
            while ((entry = dir.read()) != null) {
                if (entry == "." || entry == "..") continue;
                let pid_file = RUNTIME_DIR + "/" + as_string(entry) + "/tailscaled.pid";
                let pid = read_pid(pid_file);
                if (pid_alive(pid))
                    command_success_from_args([ "kill", as_string(pid) ]);
            }
            dir.close();
        }
    } catch (e) {
    }
    remove_kernel_routing(false);
    return 0;
}

function start_runtime() {
    let sections = native_tailscale_sections();
    if (length(sections) == 0) {
        // Nothing configured: make sure nothing is left over from a removed section.
        stop_runtime();
        return 0;
    }
    if (!binary_available()) {
        log_message("tailscale binaries are missing; install the Tailscale component first", "warn");
        return 1;
    }
    let failures = 0;
    for (let section in sections) {
        if (!ensure_dirs(section) || !start_daemon(section) || !bring_up(section))
            failures++;
    }
    return failures > 0 ? 1 : 0;
}

let mode = ARGV[0] || "";

if (mode == "start-runtime")
    exit(start_runtime());
else if (mode == "stop-runtime")
    exit(stop_runtime());
else if (mode == "status")
    status_json();
else if (mode == "check")
    check_json();
else if (mode == "peers")
    peers_json();
else if (mode == "installed" || mode == "provider-available")
    exit(binary_available() ? 0 : 1);
else if (mode == "package-installed")
    exit(package_installed() ? 0 : 1);
else if (mode == "package-version")
    print(daemon_version(), "\n");
else if (mode == "native-section-count")
    print(length(native_tailscale_sections()), "\n");
else {
    warn("Usage: providers/tailscale/runtime.uc <start-runtime|stop-runtime|status|check|installed|package-installed|package-version|native-section-count>\n");
    exit(1);
}
