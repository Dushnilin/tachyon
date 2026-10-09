#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");
let connections = require("config.connections");

let as_string = common.as_string;
let bool_value = common.bool_value;
let write_json = common.write_json;
let shell_quote = common.shell_quote;
let command_from_args = common.command_from_args;
let command_output = common.command_output;
let command_status = common.command_status;
let command_success_from_args = common.command_success_from_args;
let object_or_empty = common.object_or_empty;
let option = common.option;
let bool_option = common.bool_option;
let section_name = common.section_name;
let remove_file = common.remove_file;

const MODE = as_string(getenv("TACHYON_CONFIG_NAME")) || "tachyon";
const LIB_DIR = as_string(getenv("TACHYON_LIB_DIR")) || "/usr/lib/tachyon";
const CONFIG_NAME = MODE;

let cfg = require("providers.fptn.common").config({ lib_dir: LIB_DIR });

function log_message(msg, level) {
    level = level || "info";
    command_status("logger -t tachyon-fptn -p " + (level == "fatal" ? "user.err" : level == "warn" ? "user.warning" : "user.info") + " " + shell_quote(msg));
}

function provider_available() {
    let st = fs.stat(cfg.binary);
    return st != null && st.mode != null && (int(st.mode) & 73) != 0;
}

// tachyon-core dials FPTN from the generated config itself: no external
// client, no tun-fptn, no fwmark routing. The decision lives in the single
// resolver in config.connections so the runtime and the generator cannot
// disagree about which tunnel owns the traffic.
function native_core_mode() {
    return connections.fptn_transport_mode() == "native";
}

function enabled_sections() {
    let sections = uci_core.section_objects(CONFIG_NAME, "section");
    if (connections && connections.active_provider_sections)
        return connections.active_provider_sections("fptn", sections);
    if (connections && connections.fptn_sections)
        return connections.fptn_sections();

    let result = [];
    for (let s in sections) {
        if (bool_option(s, "enabled", true) && option(s, "action", "") == "fptn")
            push(result, s);
    }
    return result;
}

function enabled_rule_count() {
    return length(enabled_sections());
}

function running_pid() {
    let pid_data = trim(as_string(fs.readfile(cfg.pid_file) || ""));
    if (pid_data == "" || match(pid_data, /[^0-9]/))
        return null;

    let pid = int(pid_data);
    if (pid <= 0)
        return null;

    if (fs.stat("/proc/" + pid) != null)
        return pid;

    remove_file(cfg.pid_file);
    return null;
}

function package_version() {
    if (!provider_available())
        return "";

    let out = trim(command_output(shell_quote(cfg.binary) + " --version 2>&1 || true"));
    let m = match(out, /version[ \t]*([0-9a-zA-Z._-]+)/i) || match(out, /([0-9]+\.[0-9a-zA-Z._-]+)/);
    if (m)
        return m[1];

    let pkgs = require("core.packages");
    if (pkgs && pkgs.version)
        return pkgs.version("fptn") || pkgs.version("fptn-client") || "";

    return "";
}

function install_shims() {
    let shims_dir = cfg.shims_dir || (cfg.state_dir + "/bin");
    command_status("mkdir -p " + shell_quote(shims_dir) + " 2>/dev/null");

    let ip_shim = "#!/bin/sh\n" +
        "REAL_IP=''\n" +
        "for p in /sbin/ip /usr/sbin/ip /usr/bin/ip /bin/ip; do\n" +
        "    if [ -x \"$p\" ] && [ \"$p\" != \"$0\" ]; then\n" +
        "        REAL_IP=\"$p\"\n" +
        "        break\n" +
        "    fi\n" +
        "done\n" +
        "[ -z \"$REAL_IP\" ] && REAL_IP='ip'\n" +
        "CMD_LINE=\"$*\"\n" +
        "case \"$CMD_LINE\" in\n" +
        "    *route*default*|*default*route*)\n" +
        "        case \"$CMD_LINE\" in\n" +
        "            *replace*|*add*|*del*)\n" +
        "                exit 0\n" +
        "                ;;\n" +
        "        esac\n" +
        "        ;;\n" +
        "esac\n" +
        "exec \"$REAL_IP\" \"$@\"\n";
    fs.writefile(shims_dir + "/ip", ip_shim);
    command_status("chmod +x " + shell_quote(shims_dir + "/ip") + " 2>/dev/null");

    let sed_shim = "#!/bin/sh\n" +
        "REAL_SED=''\n" +
        "for p in /bin/sed /usr/bin/sed /sbin/sed /usr/sbin/sed; do\n" +
        "    if [ -x \"$p\" ] && [ \"$p\" != \"$0\" ]; then\n" +
        "        REAL_SED=\"$p\"\n" +
        "        break\n" +
        "    fi\n" +
        "done\n" +
        "[ -z \"$REAL_SED\" ] && REAL_SED='sed'\n" +
        "case \"$*\" in\n" +
        "    *resolv.conf*)\n" +
        "        exit 0\n" +
        "        ;;\n" +
        "esac\n" +
        "exec \"$REAL_SED\" \"$@\"\n";
    fs.writefile(shims_dir + "/sed", sed_shim);
    command_status("chmod +x " + shell_quote(shims_dir + "/sed") + " 2>/dev/null");

    let dummy_names = ["iptables", "ip6tables", "resolvectl", "chattr", "systemctl"];
    let dummy_shim = "#!/bin/sh\nexit 0\n";
    for (let idx, name in dummy_names) {
        fs.writefile(shims_dir + "/" + name, dummy_shim);
        command_status("chmod +x " + shell_quote(shims_dir + "/" + name) + " 2>/dev/null");
    }
}

function sanitize_system() {
    command_status("chattr -i /etc/resolv.conf 2>/dev/null; true");

    if (fs.stat("/etc/resolv.conf") == null) {
        if (fs.stat("/tmp/resolv.conf") != null)
            command_status("ln -sf /tmp/resolv.conf /etc/resolv.conf 2>/dev/null; true");
        else if (fs.stat("/tmp/resolv.conf.d/resolv.conf.auto") != null)
            command_status("ln -sf /tmp/resolv.conf.d/resolv.conf.auto /etc/resolv.conf 2>/dev/null; true");
    }

    command_status("sed -i '/nameserver 172\\.20\\./d' /etc/resolv.conf 2>/dev/null; true");

    for (let i = 0; i < 4; i++) {
        command_status("iptables -D OUTPUT -p udp --dport 53 -m comment --comment fptn -j DROP 2>/dev/null; true");
        command_status("iptables -D OUTPUT -p tcp --dport 53 -m comment --comment fptn -j DROP 2>/dev/null; true");
        command_status("iptables -D OUTPUT -p udp --dport 853 -m comment --comment fptn -j DROP 2>/dev/null; true");
        command_status("iptables -D OUTPUT -p tcp --dport 853 -m comment --comment fptn -j DROP 2>/dev/null; true");
    }

    command_status("uci del_list dhcp.@dnsmasq[0].server='172.20.0.1' 2>/dev/null; uci commit dhcp 2>/dev/null; true");

    let main_default = trim(command_output("ip -4 route show table main default 2>/dev/null | grep dev | grep " + shell_quote(cfg.tun_interface) + " || true"));
    if (main_default != "") {
        log_message("Sanitizing rogue default route dev " + cfg.tun_interface + " in table main", "warn");
        command_status("ip -4 route del default dev " + shell_quote(cfg.tun_interface) + " table main 2>/dev/null; true");
    }
}

function remove_kernel_routing(keep_link) {
    let p = cfg.rule_priority || "102";
    let mark_spec = cfg.fwmark + "/" + cfg.mark_mask;

    for (let i = 0; i < 5; i++) {
        if (command_status("ip rule del fwmark " + mark_spec + " table " + cfg.route_table + " priority " + p + " 2>/dev/null") != 0)
            break;
    }

    command_status("ip route flush table " + cfg.route_table + " 2>/dev/null; true");
    command_status("ip -4 route del default dev " + shell_quote(cfg.tun_interface) + " table main 2>/dev/null; true");
    if (!keep_link && command_status("ip link show " + shell_quote(cfg.tun_interface) + " >/dev/null 2>&1") == 0)
        command_status("ip link set dev " + shell_quote(cfg.tun_interface) + " down 2>/dev/null; true");

    sanitize_system();
}

function install_kernel_routing() {
    remove_kernel_routing(true);

    command_status("ip link set dev " + shell_quote(cfg.tun_interface) + " up 2>/dev/null; true");
    let route_ok = command_status("ip route replace default dev " + shell_quote(cfg.tun_interface) + " table " + cfg.route_table + " 2>/dev/null") == 0;
    if (!route_ok) {
        log_message("Failed to add default route dev " + cfg.tun_interface + " to table " + cfg.route_table, "warn");
        return false;
    }

    let p = cfg.rule_priority || "102";
    let mark_spec = cfg.fwmark + "/" + cfg.mark_mask;
    let rule_ok = command_status("ip rule add fwmark " + mark_spec + " table " + cfg.route_table + " priority " + p + " 2>/dev/null") == 0;
    if (!rule_ok) {
        log_message("Failed to add ip rule for table " + cfg.route_table, "warn");
        return false;
    }

    sanitize_system();

    return true;
}

function stop_runtime() {
    let pid = running_pid();
    if (pid != null) {
        log_message("Stopping FPTN daemon (PID " + pid + ")", "info");
        command_status("kill -15 " + pid + " 2>/dev/null; true");

        let stopped = false;
        for (let i = 0; i < 20; i++) {
            if (fs.stat("/proc/" + pid) == null) {
                stopped = true;
                break;
            }
            system("sleep 0.1 2>/dev/null || sleep 1");
        }

        if (!stopped && fs.stat("/proc/" + pid) != null) {
            log_message("FPTN daemon did not stop gracefully; sending SIGKILL", "warn");
            command_status("kill -9 " + pid + " 2>/dev/null; true");
        }
    }

    remove_file(cfg.pid_file);
    remove_kernel_routing();
    return true;
}

function launch_fptn_process(section) {
    let token = as_string(option(section, "access_token", ""));
    if (token == "")
        return false;

    command_status("mkdir -p " + shell_quote(cfg.state_dir) + " 2>/dev/null");
    install_shims();

    let cmd_args = [
        cfg.binary,
        "--access-token", token,
        "--tun-interface-name", cfg.tun_interface,
        "--enable-split-tunnel", "false"
    ];

    let sni = as_string(option(section, "sni", ""));
    if (sni != "") {
        push(cmd_args, "--sni");
        push(cmd_args, sni);
    }

    let bypass_method = as_string(option(section, "bypass_method", ""));
    if (bypass_method != "") {
        push(cmd_args, "--bypass-method");
        push(cmd_args, bypass_method);
    }

    let preferred_server = as_string(option(section, "preferred_server", ""));
    if (preferred_server != "") {
        push(cmd_args, "--preferred-server");
        push(cmd_args, preferred_server);
    }

    let shims_dir = cfg.shims_dir || (cfg.state_dir + "/bin");
    // Same fd-1000 hazard as tailscale: a hand-rolled `& echo $! > pid` leaves
    // procd's lock descriptor open in the client, and the lock belongs to the
    // open file, so every later /etc/init.d/tachyon reload would block on it.
    let cmd_str = common.background_command_with_pid(
        "PATH=" + shell_quote(shims_dir) + ":$PATH " + command_from_args(cmd_args),
        ">>" + shell_quote(cfg.log_file),
        ">" + shell_quote(cfg.pid_file)
    );
    log_message("Starting FPTN client on interface " + cfg.tun_interface, "info");
    system(cmd_str);
    return true;
}

function launch_supervisor() {
    let sup_pid_file = cfg.state_dir + "/supervisor.pid";
    let cur_pid = trim(as_string(fs.readfile(sup_pid_file) || ""));
    let my_pid = trim(as_string(fs.readlink("/proc/self") || ""));
    if (cur_pid != "" && cur_pid != my_pid && !match(cur_pid, /[^0-9]/) && fs.stat("/proc/" + cur_pid) != null)
        return true;

    let sup_exec = sprintf("ucode -L %s %s supervise-runtime",
        shell_quote(LIB_DIR), shell_quote(LIB_DIR + "/providers/fptn/runtime.uc"));
    system(common.background_command_with_pid(sup_exec, ">/dev/null", ">" + shell_quote(sup_pid_file)));
    return true;
}

function supervise_runtime() {
    let sup_pid_file = cfg.state_dir + "/supervisor.pid";
    let my_pid = trim(as_string(fs.readlink("/proc/self") || ""));
    let cur_pid = trim(as_string(fs.readfile(sup_pid_file) || ""));
    if (cur_pid != "" && cur_pid != my_pid && !match(cur_pid, /[^0-9]/) && fs.stat("/proc/" + cur_pid) != null)
        return true;
    if (my_pid != "")
        fs.writefile(sup_pid_file, my_pid);

    let delays = [ 2, 3, 5, 5, 10, 10, 15, 20, 30, 30 ];
    for (let i = 0; i < length(delays); i++) {
        let sec_wait = delays[i];
        system(sprintf("sleep %d 2>/dev/null || sleep %d", sec_wait, sec_wait));

        let sections = enabled_sections();
        if (length(sections) == 0)
            break;

        let tun_ok = command_status("ip link show " + shell_quote(cfg.tun_interface) + " >/dev/null 2>&1") == 0;
        let p = running_pid();

        if (tun_ok) {
            let routed = install_kernel_routing();
            if (routed) {
                log_message("FPTN supervisor: interface " + cfg.tun_interface + " is UP and routing installed", "info");
                remove_file(sup_pid_file);
                return true;
            }
        }

        if (p == null || (i >= 5 && !tun_ok)) {
            log_message("FPTN supervisor: retrying start (attempt " + (i + 1) + ")", "info");
            stop_runtime();
            launch_fptn_process(sections[0]);
            for (let wait_i = 0; wait_i < 20; wait_i++) {
                if (command_status("ip link show " + shell_quote(cfg.tun_interface) + " >/dev/null 2>&1") == 0) {
                    tun_ok = true;
                    break;
                }
                system("sleep 0.5 2>/dev/null || sleep 1");
            }
            if (tun_ok) {
                let routed = install_kernel_routing();
                if (routed) {
                    log_message("FPTN supervisor: interface " + cfg.tun_interface + " is UP and routing installed", "info");
                    remove_file(sup_pid_file);
                    return true;
                }
            }
        }
    }
    remove_file(sup_pid_file);
    return false;
}


function start_runtime() {
    let sections = enabled_sections();
    if (length(sections) == 0) {
        stop_runtime();
        return true;
    }

    if (native_core_mode()) {
        // Clear any leftover tun/fwmark state from a previous component-mode
        // run, then stand down: the core handles the tunnel itself.
        stop_runtime();
        return true;
    }

    if (!provider_available()) {
        log_message("Cannot start FPTN: binary " + cfg.binary + " not found or not executable", "warn");
        return false;
    }

    let section = sections[0];
    let token = as_string(option(section, "access_token", ""));
    if (token == "") {
        log_message("Cannot start FPTN: access_token not configured for section " + section_name(section), "warn");
        return false;
    }

    // Stop and disable conflicting standalone init.d service if present
    command_status("/etc/init.d/fptn stop >/dev/null 2>&1 || true; /etc/init.d/fptn disable >/dev/null 2>&1 || true;");

    stop_runtime();

    if (!launch_fptn_process(section))
        return false;

    let started = false;
    for (let i = 0; i < 40; i++) {
        if (command_status("ip link show " + shell_quote(cfg.tun_interface) + " >/dev/null 2>&1") == 0) {
            started = true;
            break;
        }
        let p = running_pid();
        if (p == null && i > 5)
            break;
        system("sleep 0.25 2>/dev/null || sleep 1");
    }

    if (!started) {
        log_message("FPTN interface " + cfg.tun_interface + " did not come up immediately (WAN may be initializing); launching background retry supervisor", "warn");
        launch_supervisor();
        return true;
    }

    let routing_ok = install_kernel_routing();
    if (!routing_ok) {
        log_message("FPTN interface " + cfg.tun_interface + " came up but routing failed; launching background supervisor", "warn");
        launch_supervisor();
        return true;
    }

    log_message("FPTN client successfully started on " + cfg.tun_interface + " (table " + cfg.route_table + ")", "info");
    return true;
}

function ensure_routing() {
    let sections = enabled_sections();
    if (length(sections) == 0)
        return true;
    if (native_core_mode())
        return true;
    let tun_up = command_status("ip link show " + shell_quote(cfg.tun_interface) + " >/dev/null 2>&1") == 0;
    let p = running_pid();
    if (p != null && tun_up) {
        let route_installed = command_status("ip route show table " + cfg.route_table + " default dev " + shell_quote(cfg.tun_interface) + " 2>/dev/null | grep -q default") == 0;
        let rule_installed = command_status("ip rule show 2>/dev/null | grep -q " + shell_quote(cfg.route_table)) == 0;
        if (route_installed && rule_installed) {
            sanitize_system();
            return true;
        }
        return install_kernel_routing();
    }
    if (p != null && !tun_up) {
        launch_supervisor();
        return true;
    }
    return start_runtime();
}

function status_json() {
    let installed = provider_available();
    let pid = running_pid();
    let running = pid != null;
    let rule_count = enabled_rule_count();

    if (native_core_mode()) {
        let sing_box_up = command_status("pidof sing-box >/dev/null 2>&1") == 0;
        write_json({
            installed: 1,
            configured: rule_count > 0,
            enabled_rule_count: rule_count,
            service_running: sing_box_up,
            process_running: sing_box_up,
            tun_up: true,
            route_installed: true,
            rule_installed: true,
            pid: null,
            version: "",
            binary: "",
            tun_interface: cfg.tun_interface,
            route_table: cfg.route_table,
            log_file: cfg.log_file,
            ready: sing_box_up && rule_count > 0,
            native: 1,
            status_message: sing_box_up
                ? "FPTN is running (native, via tachyon-core)"
                : "FPTN is stopped (tachyon-core is not running)"
        });
        return true;
    }

    let ver = package_version();
    let tun_up = command_status("ip link show " + shell_quote(cfg.tun_interface) + " >/dev/null 2>&1") == 0;
    let route_installed = command_status("ip route show table " + cfg.route_table + " default dev " + shell_quote(cfg.tun_interface) + " 2>/dev/null | grep -q default") == 0;
    let rule_installed = command_status("ip rule show 2>/dev/null | grep -q " + shell_quote(cfg.route_table)) == 0;

    // Auto-heal missing kernel routing if process is running and tun interface is UP
    if (installed && running && tun_up && (!route_installed || !rule_installed) && rule_count > 0) {
        if (install_kernel_routing()) {
            route_installed = command_status("ip route show table " + cfg.route_table + " default dev " + shell_quote(cfg.tun_interface) + " 2>/dev/null | grep -q default") == 0;
            rule_installed = command_status("ip rule show 2>/dev/null | grep -q " + shell_quote(cfg.route_table)) == 0;
        }
    }

    let ready = installed && running && tun_up && route_installed && rule_installed && rule_count > 0;

    let status_msg = "FPTN is running";
    if (!installed)
        status_msg = "FPTN is not installed";
    else if (rule_count == 0)
        status_msg = "FPTN is not configured";
    else if (!running)
        status_msg = "FPTN is stopped";
    else if (!tun_up)
        status_msg = "FPTN is running (degraded: tun interface down)";
    else if (!route_installed)
        status_msg = "FPTN is running (degraded: table " + cfg.route_table + " route missing)";
    else if (!rule_installed)
        status_msg = "FPTN is running (degraded: table " + cfg.route_table + " ip rule missing)";

    write_json({
        installed: installed,
        configured: rule_count > 0,
        enabled_rule_count: rule_count,
        service_running: running,
        process_running: running,
        tun_up: tun_up,
        route_installed: route_installed,
        rule_installed: rule_installed,
        pid: pid,
        version: ver,
        binary: cfg.binary,
        tun_interface: cfg.tun_interface,
        route_table: cfg.route_table,
        log_file: cfg.log_file,
        ready: ready,
        status_message: status_msg
    });
    return true;
}

function check_json() {
    write_json({
        fptn_installed: (native_core_mode() || provider_available()) ? 1 : 0,
        fptn_version: package_version(),
        binary: cfg.binary
    });
    return true;
}

function module_exports() {
    return {
        provider_available: provider_available,
        package_version: package_version,
        start_runtime: start_runtime,
        stop_runtime: stop_runtime,
        ensure_routing: ensure_routing,
        supervise_runtime: supervise_runtime,
        status_json: status_json,
        check_json: check_json,
        install_shims: install_shims,
        sanitize_system: sanitize_system
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

let mode = as_string(ARGV[0]);
if (mode == "start-runtime")
    exit(start_runtime() ? 0 : 1);
else if (mode == "stop-runtime")
    exit(stop_runtime() ? 0 : 1);
else if (mode == "restart-runtime") {
    stop_runtime();
    exit(start_runtime() ? 0 : 1);
}
else if (mode == "ensure-routing")
    exit(ensure_routing() ? 0 : 1);
else if (mode == "supervise-runtime")
    exit(supervise_runtime() ? 0 : 1);
else if (mode == "install-shims") {
    install_shims();
    exit(0);
}
else if (mode == "sanitize-system") {
    sanitize_system();
    exit(0);
}
else if (mode == "status")
    status_json();
else if (mode == "check")
    check_json();
else if (mode == "installed" || mode == "provider-available")
    exit(provider_available() ? 0 : 1);
else if (mode == "package-version" || mode == "version")
    printf("%s\n", package_version());
else if (mode == "enabled-rule-count")
    printf("%d\n", enabled_rule_count());
else {
    warn("Usage: providers/fptn/runtime.uc <start-runtime|stop-runtime|restart-runtime|ensure-routing|supervise-runtime|status|check|installed|version>\n");
    exit(1);
}
