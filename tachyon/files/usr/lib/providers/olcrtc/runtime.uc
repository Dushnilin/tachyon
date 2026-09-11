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

let cfg = require("providers.olcrtc.common").config({ lib_dir: LIB_DIR });
let olcrtc_validator = require("providers.olcrtc.validator");

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

function yaml_quote(value) {
    value = as_string(value);
    if (value == "")
        return "''";
    if (match(value, /^[a-zA-Z0-9_./:-]+$/) != null)
        return value;
    return "'" + replace(value, "'", "''") + "'";
}

function enabled_sections() {
    return connections.olcrtc_sections();
}

function enabled_rule_count() {
    let sections = enabled_sections();
    return length(sections);
}

function provider_available() {
    return fs.stat(cfg.binary) != null;
}

function service_init_exists() {
    return fs.stat(cfg.service_init) != null;
}

function service_running() {
    return command_success_from_args([cfg.service_init, "status"]);
}

function service_enabled() {
    return command_success_from_args([cfg.service_init, "enabled"]);
}

function package_version() {
    let ver = trim(fs.readfile("/etc/olcrtc/.version") || "");
    if (ver != "")
        return ver;
    return "";
}

function fetch_url(url) {
    let tmp = "/tmp/tachyon-olcrtc-sub";
    if (command_success_from_args(["curl", "-fsSL", "-o", tmp, "--connect-timeout", "20", "--max-time", "20", url]))
        return trim(fs.readfile(tmp) || "");
    if (command_success_from_args(["wget", "-q", "-O", tmp, "--timeout=20", url]))
        return trim(fs.readfile(tmp) || "");
    if (command_success_from_args(["uclient-fetch", "-q", "-O", tmp, "--timeout=20", url]))
        return trim(fs.readfile(tmp) || "");
    return "";
}

function first_uri_from_subscription(data) {
    let lines = split(data, "\n\r");
    for (let line in lines) {
        line = trim(line);
        if (substr(line, 0, 9) == "olcrtc://")
            return line;
    }
    return "";
}

function resolve_connection(section) {
    let links = list_option(section, "subscription_links");
    let resolved = null;
    let used_link = "";
    let subscription_name = "";
    let subscription_refresh = "";

    for (let link in links) {
        link = trim(as_string(link));
        if (link == "")
            continue;

        if (substr(link, 0, 9) == "olcrtc://") {
            let parsed = olcrtc_validator.parse_uri(link);
            if (parsed.valid) {
                resolved = parsed;
                used_link = link;
                break;
            }
            log_message("Invalid olcrtc:// URI: " + parsed.reason, "warn");
            continue;
        }

        if (substr(link, 0, 8) == "https://" || substr(link, 0, 7) == "http://") {
            let data = fetch_url(link);
            if (data == "") {
                log_message("Failed to fetch subscription: " + link, "warn");
                continue;
            }
            let uri = first_uri_from_subscription(data);
            if (uri == "") {
                log_message("No olcrtc:// URI found in subscription: " + link, "warn");
                continue;
            }
            let parsed = olcrtc_validator.parse_uri(uri);
            if (parsed.valid) {
                resolved = parsed;
                used_link = link;
                let lines = split(data, "\n\r");
                for (let line in lines) {
                    line = trim(line);
                    if (substr(line, 0, 6) == "#name:")
                        subscription_name = trim(substr(line, 6));
                    else if (substr(line, 0, 8) == "#refresh:")
                        subscription_refresh = trim(substr(line, 8));
                }
                break;
            }
            log_message("Invalid olcrtc URI in subscription: " + parsed.reason, "warn");
        }
    }

    if (resolved == null)
        return { valid: false, reason: "No valid connection found in subscription links" };

    let provider = option(section, "provider", "");
    if (provider == "")
        provider = resolved.provider;
    let transport = option(section, "transport", "");
    if (transport == "")
        transport = resolved.transport;
    let room_id = option(section, "room_id", "");
    if (room_id == "")
        room_id = resolved.room_id;
    let crypto_key = option(section, "crypto_key", "");
    if (crypto_key == "")
        crypto_key = resolved.crypto_key;

    return {
        valid: true,
        provider: provider,
        transport: transport,
        room_id: room_id,
        crypto_key: crypto_key,
        mimo: resolved.mimo,
        payload: resolved.payload,
        used_link: used_link,
        subscription_name: subscription_name,
        subscription_refresh: subscription_refresh
    };
}

function payload_option_mapping() {
    return {
        "vp8-fps": "vp8_fps",
        "vp8-batch": "vp8_batch",
        "fps": "sei_fps",
        "batch": "sei_batch",
        "video-w": "video_w",
        "video-h": "video_h",
        "video-fps": "video_fps",
        "video-codec": "video_codec",
        "video-qr-size": "video_qr_size",
        "video-qr-recovery": "video_qr_recovery",
        "video-tile-module": "video_tile_module",
        "video-tile-rs": "video_tile_rs"
    };
}

function payload_uci_commands(payload) {
    let cmds = [];
    if (payload == "" || payload == null)
        return cmds;
    let mapping = payload_option_mapping();
    let pairs = split(payload, "&");
    for (let pair in pairs) {
        let kv = split(pair, "=", 2);
        if (length(kv) == 2) {
            let key = kv[0];
            let val = kv[1];
            if (mapping[key] != null)
                push(cmds, "uci set olcrtc.config." + mapping[key] + "=" + yaml_quote(val));
        }
    }
    return cmds;
}

function write_olcrtc_config(section, connection) {
    let uci_cmds = [
        "uci set olcrtc.config.carrier=" + yaml_quote(connection.provider),
        "uci set olcrtc.config.transport=" + yaml_quote(connection.transport),
        "uci set olcrtc.config.room_id=" + yaml_quote(connection.room_id),
        "uci set olcrtc.config.key=" + yaml_quote(connection.crypto_key),
        "uci set olcrtc.config.socks_host=" + yaml_quote(option(section, "socks_host", cfg.default_socks_host)),
        "uci set olcrtc.config.socks_port=" + yaml_quote(option(section, "socks_port", cfg.default_socks_port)),
        "uci set olcrtc.config.dns=" + yaml_quote(option(section, "dns_server", cfg.default_dns))
    ];

    let socks_user = option(section, "socks_user", "");
    if (socks_user != "")
        push(uci_cmds, "uci set olcrtc.config.socks_user=" + yaml_quote(socks_user));
    let socks_pass = option(section, "socks_pass", "");
    if (socks_pass != "")
        push(uci_cmds, "uci set olcrtc.config.socks_pass=" + yaml_quote(socks_pass));

    let payload_cmds = payload_uci_commands(connection.payload);
    for (let cmd in payload_cmds)
        push(uci_cmds, cmd);

    for (let cmd in uci_cmds)
        system(cmd);
    system("uci commit olcrtc");

    return true;
}

function write_olcrtc_yaml_config(section, connection) {
    let yaml = "mode: cnc\n";
    yaml += "auth:\n";
    yaml += "  provider: " + yaml_quote(connection.provider) + "\n";
    yaml += "room:\n";
    yaml += "  id: " + yaml_quote(connection.room_id) + "\n";
    yaml += "crypto:\n";
    yaml += "  key: " + yaml_quote(connection.crypto_key) + "\n";
    yaml += "net:\n";
    yaml += "  transport: " + yaml_quote(connection.transport) + "\n";
    yaml += "  dns: " + yaml_quote(option(section, "dns_server", cfg.default_dns)) + "\n";
    yaml += "socks:\n";
    yaml += "  host: " + yaml_quote(option(section, "socks_host", cfg.default_socks_host)) + "\n";
    yaml += "  port: " + yaml_quote(option(section, "socks_port", cfg.default_socks_port)) + "\n";

    let socks_user = option(section, "socks_user", "");
    if (socks_user != "") {
        yaml += "  username: " + yaml_quote(socks_user) + "\n";
        yaml += "  password: " + yaml_quote(option(section, "socks_pass", "")) + "\n";
    }

    let tmp = cfg.config_path + ".tmp";
    let f = fs.open(tmp, "w");
    if (!f)
        return false;
    f.write(yaml);
    f.close();
    return rename(tmp, cfg.config_path) == 0;
}

function start_runtime() {
    let sections = enabled_sections();
    if (length(sections) == 0) {
        log_message("No enabled OlcRTC sections found, stopping service");
        command_success_from_args([cfg.service_init, "stop"]);
        return true;
    }

    if (!provider_available()) {
        log_message("OlcRTC provider not available (binary not found: " + cfg.binary + ")", "fatal");
        return false;
    }

    if (!service_init_exists()) {
        log_message("OlcRTC service init script not found: " + cfg.service_init, "fatal");
        return false;
    }

    if (length(sections) > 1)
        log_message("Multiple OlcRTC sections found, using first: " + section_name(sections[0]), "warn");

    let section = sections[0];
    let connection = resolve_connection(section);
    if (!connection.valid) {
        log_message("OlcRTC rule '" + section_name(section) + "': " + connection.reason, "fatal");
        return false;
    }

    let config_type = fs.stat("/etc/olcrtc/client.yaml") != null ? "yaml" : "uci";

    if (config_type == "yaml") {
        if (!write_olcrtc_yaml_config(section, connection)) {
            log_message("Failed to write OlcRTC YAML config", "fatal");
            return false;
        }
    }
    else {
        if (!write_olcrtc_config(section, connection)) {
            log_message("Failed to write OlcRTC UCI config", "fatal");
            return false;
        }
    }

    if (!command_success_from_args([cfg.service_init, "restart"])) {
        log_message("Failed to restart OlcRTC service", "fatal");
        return false;
    }

    log_message("OlcRTC provider started successfully (provider=" + connection.provider + ", transport=" + connection.transport + ")");
    return true;
}

function stop_runtime() {
    command_success_from_args([cfg.service_init, "stop"]);
    log_message("OlcRTC provider stopped");
    return true;
}

function status_json() {
    let installed = provider_available();
    let running = installed ? service_running() : false;
    let enabled = installed ? service_enabled() : false;
    let rule_count = enabled_rule_count();
    let version = package_version();

    write_json({
        installed: installed,
        configured: rule_count > 0,
        enabled_rule_count: rule_count,
        service_enabled: enabled,
        service_running: running,
        config_path: cfg.config_path,
        binary: cfg.binary,
        service_init: cfg.service_init,
        ready: installed && running && rule_count > 0,
        status_message: running ? "olcrtc provider status is normal" : (installed ? "olcrtc service is not running" : "olcrtc is not installed")
    });
    return true;
}

function check_json() {
    write_json({
        olcrtc_installed: provider_available(),
        olcrtc_config_path: cfg.config_path
    });
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
else {
    warn("Usage: olcrtc/runtime.uc <operation>\n");
    exit(1);
}
