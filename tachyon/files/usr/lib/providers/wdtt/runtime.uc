#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");
let connections = require("config.connections");

let as_string = common.as_string;
let bool_value = common.bool_value;
let object_or_empty = common.object_or_empty;

const MODE = as_string(getenv("TACHYON_CONFIG_NAME")) || "tachyon";
const LIB_DIR = as_string(getenv("TACHYON_LIB_DIR")) || "/usr/lib/tachyon";
const CONFIG_NAME = MODE;

let cfg = require("providers.wdtt.common").config({ lib_dir: LIB_DIR });
let wdtt_validator = require("providers.wdtt.validator");

function log_message(msg, level) {
    level = level || "info";
    printf("%s\n", msg);
    system("logger -t " + MODE + " -p " + (level == "fatal" ? "user.err" : level == "warn" ? "user.warning" : "user.info") + " '" + msg + "'");
}

function command_from_args(args) {
    let parts = [];
    for (let arg in args)
        push(parts, common.shell_quote(as_string(arg)));
    return join(" ", parts);
}

function command_output(cmd) {
    let output = trim(popen(cmd, "r") || "");
    return output;
}

function command_output_from_args(args) {
    return command_output(command_from_args(args));
}

function command_success_from_args(args) {
    return system(command_from_args(args)) == 0;
}

function option(section, key, fallback) {
    let val = section[key];
    if (val == null)
        return fallback || "";
    if (type(val) == "array")
        return join(" ", val);
    return as_string(val);
}

function bool_option(section, key, fallback) {
    let val = section[key];
    if (val == null)
        return fallback || false;
    return bool_value(val);
}

function list_option(section, key) {
    let val = section[key];
    if (val == null)
        return [];
    if (type(val) == "array")
        return val;
    return split(trim(as_string(val)), " \t\n\r");
}

function section_name(section) {
    return as_string(section[".name"] || "");
}

function read_json_file(path) {
    let data = fs.readfile(path);
    if (data == null || data == "")
        return null;
    return json(data);
}

function write_json_file(path, data) {
    let tmp = path + ".tmp";
    let f = fs.open(tmp, "w");
    if (!f)
        return false;
    f.write(sprintf("%J", data));
    f.close();
    return rename(tmp, path) == 0;
}

function lan_mac_address() {
    for (let iface in ["br-lan", "lan", "eth0", "eth1"]) {
        let mac_path = "/sys/class/net/" + iface + "/address";
        let mac = trim(fs.readfile(mac_path) || "");
        if (mac != "" && mac != "00:00:00:00:00:00")
            return mac;
    }
    return "";
}

function enabled_sections() {
    return connections.wdtt_sections();
}

function enabled_rule_count() {
    let sections = enabled_sections();
    return length(sections);
}

function provider_available() {
    return fs.stat(cfg.binary) != null || fs.stat(cfg.config_path) != null;
}

function qwdtt_installed() {
    return fs.stat(cfg.binary) != null;
}

function active_service_init() {
    if (qwdtt_installed())
        return cfg.qwdtt_service_init;
    return cfg.service_init;
}

function service_init_exists() {
    return fs.stat(active_service_init()) != null;
}

function service_running() {
    return command_success_from_args([active_service_init(), "status"]);
}

function service_enabled() {
    return command_success_from_args([active_service_init(), "enabled"]);
}

function package_version() {
    if (qwdtt_installed()) {
        let ver = trim(fs.readfile("/etc/qwdtt/.version") || "");
        if (ver != "")
            return ver;
    }
    return "";
}

function first_http_url(values) {
    for (let v in values) {
        v = trim(as_string(v));
        if (substr(v, 0, 7) == "http://")
            return v;
        if (substr(v, 0, 8) == "https://")
            return v;
    }
    return "";
}

function first_local_file(values) {
    for (let v in values) {
        v = trim(as_string(v));
        if (substr(v, 0, 1) == "/")
            return v;
    }
    return "";
}

function first_wdtt_link(values) {
    for (let v in values) {
        v = trim(as_string(v));
        if (substr(v, 0, 7) == "wdtt://")
            return v;
    }
    return "";
}

function write_wdtt_hashes_file(hashes_value) {
    let dir = cfg.hashes_dir;
    system("mkdir -p " + common.shell_quote(dir));
    let path = dir + "/vk-calls.txt";
    let tmp = path + ".tmp";
    let f = fs.open(tmp, "w");
    if (!f)
        return false;
    if (type(hashes_value) == "array") {
        for (let h in hashes_value)
            f.write(trim(as_string(h)) + "\n");
    }
    else {
        let hashes_str = trim(as_string(hashes_value));
        if (hashes_str != "") {
            let parts = split(hashes_str, " ,\n\r\t");
            for (let h in parts) {
                h = trim(h);
                if (h != "")
                    f.write(h + "\n");
            }
        }
    }
    f.close();
    rename(tmp, path);
    return true;
}

function qwdtt_hashes_list(section) {
    let hashes = [];
    let links = list_option(section, "subscription_links");
    let wdtt_link = first_wdtt_link(links);
    if (wdtt_link != "") {
        let parsed = wdtt_validator.parse_wdtt_uri(wdtt_link);
        if (parsed.valid && parsed.hashes != "") {
            let parts = split(parsed.hashes, ",");
            for (let h in parts) {
                h = trim(h);
                if (h != "")
                    push(hashes, h);
            }
        }
    }
    if (length(hashes) == 0) {
        let hashes_file = first_local_file(links);
        if (hashes_file != "" && fs.stat(hashes_file) != null) {
            let data = trim(fs.readfile(hashes_file) || "");
            if (data != "") {
                let lines = split(data, "\n\r");
                for (let line in lines) {
                    line = trim(line);
                    if (line != "")
                        push(hashes, line);
                }
            }
        }
    }
    return hashes;
}

function write_qwdtt_json_config(section, name) {
    let links = list_option(section, "subscription_links");
    let wdtt_link = first_wdtt_link(links);
    let parsed = null;
    if (wdtt_link != "")
        parsed = wdtt_validator.parse_wdtt_uri(wdtt_link);

    let peer = option(section, "peer", "");
    if (peer == "" && parsed != null && parsed.valid)
        peer = parsed.peer;
    if (peer == "")
        peer = cfg.default_peer;

    let password = option(section, "password", "");
    if (password == "" && parsed != null && parsed.valid)
        password = parsed.pass;

    let device_id = option(section, "device_id", "");
    if (device_id == "")
        device_id = lan_mac_address();

    let workers = option(section, "workers", "");
    if (workers == "" && parsed != null && parsed.valid && parsed.workers != "")
        workers = parsed.workers;
    if (workers == "")
        workers = cfg.default_workers_qwdtt;

    let hashes = qwdtt_hashes_list(section);
    let hashes_file = first_local_file(links);
    if (hashes_file != "" && length(hashes) == 0)
        write_wdtt_hashes_file([]);

    let qwdtt_mode = option(section, "qwdtt_mode", "rawtun");

    let config = {
        peer: peer,
        password: password,
        device_id: device_id,
        workers: int(workers) || 9,
        dns: option(section, "dns", "yandex"),
        obfs: option(section, "obfs", "audio"),
        captcha_mode: option(section, "captcha_mode", "auto"),
        vk_auth: option(section, "vk_auth", "anonymous"),
        vk_anon_path: option(section, "vk_anon_path", "vkcalls"),
        no_dtls: bool_option(section, "no_dtls", false),
        turn_tcp: bool_option(section, "turn_tcp", false),
        tun_name: option(section, "tun_name", "qwdtt0"),
        lan_interface: option(section, "lan_iface", "br-lan"),
        mode: qwdtt_mode
    };

    if (password != "")
        config.vk_creds_file = option(section, "vk_creds_file", "");
    config.captcha_token_file = option(section, "captcha_token_file", cfg.captcha_token_default);

    if (length(hashes) > 0)
        config.hashes = hashes;
    else if (hashes_file != "")
        config.hashes_file = hashes_file;

    if (qwdtt_mode == "socks") {
        let socks_port = option(section, "socks_port", "");
        if (socks_port == "" && parsed != null && parsed.valid && parsed.port != "")
            socks_port = parsed.port;
        if (socks_port == "")
            socks_port = as_string(cfg.default_socks_port_base);
        config.socks = option(section, "socks_addr", "127.0.0.1:" + socks_port);
    }

    let result = write_json_file(cfg.qwdtt_config_path, config);
    if (result)
        system("chmod 0600 " + common.shell_quote(cfg.qwdtt_config_path));

    system("uci set " + MODE + ".wdtt_state.enabled=" + (result ? "1" : "0"));
    system("uci commit " + MODE);

    return result;
}

function write_wdtt_uci_config(section) {
    let links = list_option(section, "subscription_links");
    let wdtt_link = first_wdtt_link(links);
    let parsed = null;
    if (wdtt_link != "")
        parsed = wdtt_validator.parse_wdtt_uri(wdtt_link);

    let peer = option(section, "peer", "");
    if (peer == "" && parsed != null && parsed.valid)
        peer = parsed.peer;
    if (peer == "")
        peer = cfg.default_peer;

    let password = option(section, "password", "");
    if (password == "" && parsed != null && parsed.valid)
        password = parsed.pass;

    let device_id = option(section, "device_id", "");
    if (device_id == "")
        device_id = lan_mac_address();

    let workers = option(section, "workers", "");
    if (workers == "" && parsed != null && parsed.valid && parsed.workers != "")
        workers = parsed.workers;
    if (workers == "")
        workers = cfg.default_workers_wdtt;

    let hashes_url = first_http_url(links);
    let hashes_file = first_local_file(links);

    let uci_cmds = [
        "uci set wdtt.settings.enabled='1'",
        "uci set wdtt.settings.peer='" + peer + "'",
        "uci set wdtt.settings.password='" + password + "'",
        "uci set wdtt.settings.device_id='" + device_id + "'",
        "uci set wdtt.settings.workers='" + workers + "'",
        "uci set wdtt.settings.max_hashes='" + option(section, "max_hashes", cfg.default_max_hashes) + "'",
        "uci set wdtt.settings.mode='" + option(section, "mode", cfg.default_mode) + "'",
        "uci set wdtt.settings.mtu='" + option(section, "mtu", cfg.default_mtu) + "'",
        "uci set wdtt.settings.refresh='" + option(section, "refresh", cfg.default_refresh) + "'",
        "uci set wdtt.settings.auto_update='" + (bool_option(section, "auto_update", true) ? "1" : "0") + "'",
        "uci set wdtt.settings.block_doh='" + (bool_option(section, "block_doh", false) ? "1" : "0") + "'",
        "uci set wdtt.settings.block_ipv6='" + (bool_option(section, "block_ipv6", false) ? "1" : "0") + "'"
    ];

    if (hashes_url != "")
        push(uci_cmds, "uci set wdtt.settings.hashes_url='" + hashes_url + "'");
    if (hashes_file != "")
        push(uci_cmds, "uci set wdtt.settings.hashes_file='" + hashes_file + "'");

    let port = "";
    if (parsed != null && parsed.valid && parsed.port != "")
        port = parsed.port;
    if (port != "")
        push(uci_cmds, "uci set wdtt.settings.listen='127.0.0.1:" + port + "'");

    for (let cmd in uci_cmds)
        system(cmd);
    system("uci commit wdtt");

    return true;
}

function udp_port_in_use(port) {
    let hex_port = sprintf("%04X", port);
    for (let proc_file in ["/proc/net/udp", "/proc/net/udp6"]) {
        let data = fs.readfile(proc_file);
        if (data == null)
            continue;
        let lines = split(data, "\n");
        for (let i = 1; i < length(lines); i++) {
            let parts = split(trim(lines[i]), " \t");
            if (length(parts) >= 2) {
                let local = parts[1];
                let colon_idx = index(local, ":");
                if (colon_idx >= 0) {
                    let port_hex = substr(local, colon_idx + 1);
                    if (port_hex == hex_port)
                        return true;
                }
            }
        }
    }
    return false;
}

function restart_qwdtt_service() {
    command_success_from_args([cfg.qwdtt_service_init, "stop"]);

    let wait_ms = 0;
    while (wait_ms < 5000) {
        if (command_output_from_args(["pidof", "qwdtt-client"]) == "")
            break;
        system("sleep 0.1");
        wait_ms += 100;
    }
    if (wait_ms >= 5000)
        system("killall -9 qwdtt-client 2>/dev/null || true");

    let port = cfg.default_socks_port_base;
    wait_ms = 0;
    while (wait_ms < 10000) {
        if (!udp_port_in_use(port))
            break;
        system("sleep 0.5");
        wait_ms += 500;
    }

    system("sleep 0.5");
    return command_success_from_args([cfg.qwdtt_service_init, "start"]);
}

function start_runtime() {
    let sections = enabled_sections();
    if (length(sections) == 0) {
        log_message("No enabled WDTT sections found, disabling provider");
        if (qwdtt_installed()) {
            system("uci set " + MODE + ".wdtt_state.enabled='0'");
            system("uci commit " + MODE);
            command_success_from_args([cfg.qwdtt_service_init, "stop"]);
        }
        else {
            system("uci set wdtt.settings.enabled='0'");
            system("uci commit wdtt");
            command_success_from_args([cfg.service_init, "stop"]);
        }
        return true;
    }

    if (!provider_available()) {
        log_message("WDTT provider not available (no binary or config found)", "fatal");
        return false;
    }

    if (!service_init_exists()) {
        log_message("WDTT service init script not found: " + active_service_init(), "fatal");
        return false;
    }

    if (length(sections) > 1)
        log_message("Multiple WDTT sections found, using first: " + section_name(sections[0]), "warn");

    let section = sections[0];

    if (qwdtt_installed()) {
        if (!write_qwdtt_json_config(section, section_name(section))) {
            log_message("Failed to write qwdtt config", "fatal");
            return false;
        }
        if (!restart_qwdtt_service()) {
            log_message("Failed to start qwdtt service", "fatal");
            return false;
        }
    }
    else {
        if (!write_wdtt_uci_config(section)) {
            log_message("Failed to write wdtt UCI config", "fatal");
            return false;
        }
        if (!command_success_from_args([cfg.service_init, "restart"])) {
            log_message("Failed to restart wdtt-client service", "fatal");
            return false;
        }
    }

    if (fs.stat(cfg.genlists_bin) != null)
        command_output_from_args([cfg.genlists_bin]);
    if (fs.stat(cfg.resolve_bin) != null)
        command_output_from_args([cfg.resolve_bin]);

    log_message("WDTT provider started successfully");
    return true;
}

function stop_runtime() {
    if (qwdtt_installed()) {
        system("uci set " + MODE + ".wdtt_state.enabled='0'");
        system("uci commit " + MODE);
        command_success_from_args([cfg.qwdtt_service_init, "stop"]);
    }
    else {
        system("uci set wdtt.settings.enabled='0'");
        system("uci commit wdtt");
        command_success_from_args([cfg.service_init, "stop"]);
    }
    log_message("WDTT provider stopped");
    return true;
}

function status_json() {
    let installed = provider_available();
    let running = installed ? service_running() : false;
    let enabled = installed ? service_enabled() : false;
    let rule_count = enabled_rule_count();
    let client = qwdtt_installed() ? "qwdtt" : "wdtt-openwrt";
    let config_path = qwdtt_installed() ? cfg.qwdtt_config_path : cfg.config_path;
    let version = package_version();

    write_json({
        installed: installed,
        configured: rule_count > 0,
        enabled_rule_count: rule_count,
        service_enabled: enabled,
        service_running: running,
        config_path: config_path,
        service_init: active_service_init(),
        client: client,
        package_version: version,
        ready: installed && running && rule_count > 0,
        status_message: running ? "wdtt provider status is normal" : (installed ? "wdtt service is not running" : "wdtt is not installed")
    });
    return true;
}

function check_json() {
    write_json({
        wdtt_installed: provider_available(),
        wdtt_config_path: cfg.config_path,
        qwdtt_installed: qwdtt_installed(),
        qwdtt_version: qwdtt_installed() ? package_version() : ""
    });
    return true;
}

function captcha_token_file() {
    if (qwdtt_installed()) {
        let config = read_json_file(cfg.qwdtt_config_path);
        if (config != null && config.captcha_token_file != null)
            return config.captcha_token_file;
    }
    return cfg.captcha_token_default;
}

function wdtt_captcha_status() {
    let running = service_running();
    let token_file = captcha_token_file();
    let has_token = fs.stat(token_file) != null;
    let token = "";
    if (has_token)
        token = trim(fs.readfile(token_file) || "");

    write_json({
        running: running,
        token_file: token_file,
        has_token: has_token,
        token: token
    });
    return true;
}

function wdtt_captcha_submit(token) {
    let token_file = captcha_token_file();
    let dir = "";
    let last_slash = rindex(token_file, "/");
    if (last_slash >= 0)
        dir = substr(token_file, 0, last_slash);
    if (dir != "")
        system("mkdir -p " + common.shell_quote(dir));

    let f = fs.open(token_file, "w");
    if (!f) {
        write_json({ success: false, error: "Failed to write token file" });
        return false;
    }
    f.write(trim(as_string(token)));
    f.close();
    system("chmod 0600 " + common.shell_quote(token_file));

    write_json({ success: true, path: token_file });
    return true;
}

let mode = as_string(ARGV[0]);
if (mode == "start-runtime")
    start_runtime();
else if (mode == "stop-runtime")
    stop_runtime();
else if (mode == "status")
    status_json();
else if (mode == "check")
    check_json();
else if (mode == "installed" || mode == "provider-available")
    exit(provider_available() ? 0 : 1);
else if (mode == "package-version")
    printf("%s\n", package_version());
else if (mode == "enabled-rule-count")
    printf("%d\n", enabled_rule_count());
else if (mode == "wdtt-captcha-status")
    wdtt_captcha_status();
else if (mode == "wdtt-captcha-submit")
    wdtt_captcha_submit(ARGV[1]);
else {
    warn("Usage: wdtt/runtime.uc <operation>\n");
    exit(1);
}
