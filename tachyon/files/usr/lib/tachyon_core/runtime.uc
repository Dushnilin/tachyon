#!/usr/bin/env ucode

let fs = require("fs");
let uci_core = require("core.uci");
let common = require("core.common");
let runtime_dns = require("tachyon_core.dns");
let verifier = require("components.verifier");
let core_profile = require("tachyon_core.core_profile");

let as_string = common.as_string;
let shell_quote = common.shell_quote;
let command_from_args = common.command_from_args;
let command_output = common.command_output;
let command_output_from_args = common.command_output_from_args;
let command_status = common.command_status;
let command_success_from_args = common.command_success_from_args;
let command_status_from_args = common.command_status_from_args;
let object_or_empty = common.object_or_empty;
let array_or_empty = common.array_or_empty;
let option = common.option;
let bool_option = common.bool_option;
let file_exists = common.file_exists;
let remove_file = common.remove_file;

function core_process_or_null() {
    try {
        return require("core.process");
    } catch (e) {
        return null;
    }
}

function fallback_init_script_kills_itself(text) {
    for (let line in split(as_string(text), "\n")) {
        if (index(line, "killall") < 0)
            continue;
        if (match(line, /(^|[^A-Za-z0-9_-])tachyon-core([^A-Za-z0-9_-]|$)/) != null)
            return true;
    }
    return false;
}

function fallback_managed_core_init_script(marker) {
    marker = as_string(marker);
    if (marker == "")
        marker = "Tachyon managed tachyon-core service";
    return "#!/bin/sh /etc/rc.common\n" +
        "# " + marker + "\n\n" +
        "USE_PROCD=1\n" +
        "START=99\n" +
        "PROG=\"/usr/bin/tachyon-core\"\n\n" +
        "_kill_daemon_instances() {\n" +
        "    for p in $(pidof tachyon-core 2>/dev/null); do\n" +
        "        [ \"$p\" != \"$$\" ] || continue\n" +
        "        case \"$(readlink -f /proc/$p/exe 2>/dev/null)\" in\n" +
        "            */tachyon-core) kill -9 \"$p\" 2>/dev/null || true ;;\n" +
        "        esac\n" +
        "    done\n" +
        "}\n\n" +
        "_has_running_daemon() {\n" +
        "    for p in $(pidof tachyon-core 2>/dev/null); do\n" +
        "        [ \"$p\" != \"$$\" ] || continue\n" +
        "        case \"$(readlink -f /proc/$p/exe 2>/dev/null)\" in\n" +
        "            */tachyon-core) return 0 ;;\n" +
        "        esac\n" +
        "    done\n" +
        "    return 1\n" +
        "}\n\n" +
        "start_service() {\n" +
        "    [ -d /dev/net ] || mkdir -p /dev/net\n" +
        "    [ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200 2>/dev/null || true\n" +
        "    modprobe tun 2>/dev/null || true\n" +
        "    modprobe inet_diag 2>/dev/null || true\n\n" +
        "    config_load \"tachyon-core\"\n" +
        "    local enabled config_file working_directory\n" +
        "    local log_stderr\n\n" +
        "    config_get_bool enabled \"main\" \"enabled\" \"0\"\n" +
        "    [ \"$enabled\" -eq \"1\" ] || return 0\n\n" +
        "    [ -x \"$PROG\" ] || PROG=\"$(command -v tachyon-core 2>/dev/null || echo /usr/bin/tachyon-core)\"\n" +
        "    config_get config_file \"main\" \"conffile\" \"/etc/tachyon-core/config.json\"\n" +
        "    config_get working_directory \"main\" \"workdir\" \"/usr/share/tachyon-core\"\n" +
        "    [ -d \"$working_directory\" ] || mkdir -p \"$working_directory\"\n" +
        "    config_get_bool log_stderr \"main\" \"log_stderr\" \"1\"\n\n" +
        "    _kill_daemon_instances\n\n" +
        "    procd_open_instance\n" +
        "    procd_set_param command \"$PROG\" run -c \"$config_file\" -D \"$working_directory\"\n" +
        "    procd_set_param stderr \"$log_stderr\"\n" +
        "    procd_set_param limits core=\"0\"\n" +
        "    procd_set_param limits nofile=\"65535 65535\"\n" +
        "    local lite_mode=\"$(uci get tachyon.settings.lite_mode 2>/dev/null || echo 0)\"\n" +
        "    if [ \"$lite_mode\" = \"1\" ] || [ \"$lite_mode\" = \"true\" ]; then\n" +
        "        procd_set_param nice 15\n" +
        "    fi\n" +
        "    procd_set_param env TACHYON_RULESET_SOFT_START=\"1\"\n" +
        "    procd_set_param term_timeout 15\n" +
        "    procd_set_param respawn ${respawn_threshold:-3600} ${respawn_timeout:-5} ${respawn_retry:-0}\n" +
        "    procd_close_instance\n" +
        "}\n\n" +
        "stop_service() {\n" +
        "    for p in $(pidof tachyon-core 2>/dev/null); do\n" +
        "        [ \"$p\" != \"$$\" ] || continue\n" +
        "        case \"$(readlink -f /proc/$p/exe 2>/dev/null)\" in\n" +
        "            */tachyon-core) kill -TERM \"$p\" 2>/dev/null || true ;;\n" +
        "        esac\n" +
        "    done\n" +
        "    local i=0\n" +
        "    while [ \"$i\" -lt 20 ]; do\n" +
        "        _has_running_daemon || return 0\n" +
        "        sleep 0.1 2>/dev/null || sleep 1\n" +
        "        i=$(( i + 1 ))\n" +
        "    done\n" +
        "    _kill_daemon_instances\n" +
        "}\n\n" +
        "reload_service() {\n" +
        "    for p in $(pidof tachyon-core 2>/dev/null); do\n" +
        "        [ \"$p\" != \"$$\" ] || continue\n" +
        "        case \"$(readlink -f /proc/$p/exe 2>/dev/null)\" in\n" +
        "            */tachyon-core)\n" +
        "                if ucode -L /usr/lib/tachyon /usr/lib/tachyon/service/state.uc sighup-core-runtime \"$p\" >/dev/null 2>&1; then\n" +
        "                    return 0\n" +
        "                fi\n" +
        "                break\n" +
        "                ;;\n" +
        "        esac\n" +
        "    done\n" +
        "    restart\n" +
        "}\n\n" +
        "service_triggers() {\n" +
        "    procd_add_reload_trigger \"tachyon-core\"\n" +
        "}\n";
}

const CONFIG_NAME = getenv("TACHYON_CONFIG_NAME") || "tachyon";
const LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const TMP_TACHYON_CORE_FOLDER = getenv("TMP_TACHYON_CORE_FOLDER") || "/tmp/tachyon-core";
const TMP_RULESET_FOLDER = getenv("TMP_RULESET_FOLDER") || TMP_TACHYON_CORE_FOLDER + "/rulesets";
const TMP_SUBSCRIPTION_FOLDER = getenv("TMP_SUBSCRIPTION_FOLDER") || TMP_TACHYON_CORE_FOLDER + "/subscriptions";
const RUNTIME_STATE_DIR = getenv("TACHYON_RUNTIME_STATE_DIR") || "/var/run/tachyon";
const RELOAD_PREVIEW_FILE = getenv("TACHYON_RELOAD_PREVIEW_FILE") || RUNTIME_STATE_DIR + "/reload-preview.json";
const SUBSCRIPTION_UPDATE_STATE_DIR = getenv("TACHYON_SUBSCRIPTION_UPDATE_STATE_DIR") || RUNTIME_STATE_DIR + "/subscription-update";
const SUBSCRIPTION_LINKS_DIR = getenv("TACHYON_SUBSCRIPTION_LINKS_DIR") || RUNTIME_STATE_DIR + "/subscription-links";
const SUBSCRIPTION_METADATA_DIR = getenv("TACHYON_SUBSCRIPTION_METADATA_DIR") || RUNTIME_STATE_DIR + "/subscription-metadata";
const OUTBOUND_METADATA_DIR = getenv("TACHYON_OUTBOUND_METADATA_DIR") || RUNTIME_STATE_DIR + "/outbound-metadata";
const SECTION_CACHE_DIR = getenv("TACHYON_SECTION_CACHE_DIR") || RUNTIME_STATE_DIR + "/section-cache";
const RUNTIME_CACHE_FORMAT_FILE = getenv("TACHYON_RUNTIME_CACHE_FORMAT_FILE") || RUNTIME_STATE_DIR + "/cache-format";
const RUNTIME_CACHE_FORMAT = getenv("TACHYON_RUNTIME_CACHE_FORMAT") || "9";
const PERSISTENT_SUBSCRIPTION_CACHE_DIR = getenv("TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR") || "/etc/tachyon/subscription-cache";
const PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE = getenv("TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE") || PERSISTENT_SUBSCRIPTION_CACHE_DIR + "/cache-format";
const PERSISTENT_SUBSCRIPTION_CACHE_FORMAT = getenv("TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT") || "8";
const PENDING_RELOAD_FILE = getenv("TACHYON_PENDING_RELOAD_FILE") || RUNTIME_STATE_DIR + "/reload.pending";
const SERVICE_INIT = getenv("TACHYON_SERVICE_INIT") || "/etc/init.d/tachyon";
const NFT_TABLE_NAME = getenv("NFT_TABLE_NAME") || "TachyonTable";
const NFT_COMMON_SET_NAME = getenv("NFT_COMMON_SET_NAME") || "tachyon_subnets";
const NFT_COMMON6_SET_NAME = getenv("NFT_COMMON6_SET_NAME") || "tachyon_subnets6";
const NFT_PORT_SET_NAME = getenv("NFT_PORT_SET_NAME") || "tachyon_ports";
const NFT_IP_PORT_SET_NAME = getenv("NFT_IP_PORT_SET_NAME") || "tachyon_ip_ports";
const NFT_IP_PORT6_SET_NAME = getenv("NFT_IP_PORT6_SET_NAME") || "tachyon_ip6_ports";
const NFT_INTERFACE_SET_NAME = getenv("NFT_INTERFACE_SET_NAME") || "tachyon_interfaces";
const NFT_LOCALV4_SET_NAME = getenv("NFT_LOCALV4_SET_NAME") || "localv4";
const NFT_LOCALV6_SET_NAME = getenv("NFT_LOCALV6_SET_NAME") || "localv6";
const NFT_FAKEIP_MARK = getenv("NFT_FAKEIP_MARK") || "0x04000000";
const CORE_SERVICE_MIXED_INBOUND_ADDRESS = getenv("TACHYON_CORE_SERVICE_MIXED_INBOUND_ADDRESS") || "127.0.0.1";
const CORE_SERVICE_MIXED_INBOUND_PORT = getenv("TACHYON_CORE_SERVICE_MIXED_INBOUND_PORT") || "4534";
const CORE_VERSION_STATE_FILE = getenv("TACHYON_CORE_VERSION_FILE") || "/etc/tachyon/tachyon-core-version";
const CORE_MANAGED_SERVICE_MARKER = getenv("TACHYON_CORE_MANAGED_SERVICE_MARKER") || "Tachyon managed tachyon-core service";

function command_env(assignments) {
    let parts = [];
    for (let name, value in assignments)
        push(parts, name + "=" + shell_quote(value));
    return join(" ", parts);
}

function command_output_lenient(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return "";

    let data = pipe.read("all");
    pipe.close();
    return data != null ? as_string(data) : "";
}

function command_exists(name) {
    return command_success_from_args([ "command", "-v", name ]);
}

function write_file(path, value) {
    return common.write_file(as_string(path), as_string(value)) != null;
}

function remove_files(paths) {
    for (let path in paths)
        if (as_string(path) != "")
            remove_file(path);
}

let file_first_line = common.file_first_line;

function arg_bool(value) {
    value = lc(as_string(value));
    return value == "true" || value == "1" || value == "yes" || value == "on";
}

function whitespace_items(value) {
    let result = [];
    if (type(value) == "array") {
        for (let item in value) {
            item = as_string(item);
            if (item != "")
                push(result, item);
        }
        return result;
    }

    for (let item in split(trim(as_string(value)), /[ \t\r\n]+/))
        if (item != "")
            push(result, item);
    return result;
}

function ensure_dir(path) {
    return command_success_from_args([ "mkdir", "-p", path ]);
}

function ensure_parent_dir(path) {
    let dir = common.parent_dir(path);
    return dir == "" || dir == "." || ensure_dir(dir);
}

function temp_path() {
    return trim(command_output_from_args([ "mktemp", "/tmp/tachyon-XXXXXX" ]));
}

function md5_file(path) {
    let line = trim(command_output_from_args([ "md5sum", as_string(path) ]));
    return length(line) >= 32 ? substr(line, 0, 32) : "";
}

function first_line_last_field(value) {
    value = as_string(value);
    let newline = index(value, "\n");
    let line = trim(newline >= 0 ? substr(value, 0, newline) : value);
    let fields = split(line, /[ \t\r\n]+/);
    return length(fields) > 0 ? as_string(fields[length(fields) - 1]) : "";
}

let parse_core_version = common.parse_core_version;

function find_core_binary() {
    let path_env = as_string(getenv("PATH") || "/usr/sbin:/usr/bin:/sbin:/bin");
    for (let dir in split(path_env, ":")) {
        if (dir == "")
            continue;
        let candidate = dir + "/tachyon-core";
        if (fs.access(candidate, "x"))
            return candidate;
    }
    if (command_exists("tachyon-core"))
        return "tachyon-core";
    return "";
}

// The version string is taken from stdout whatever the exit status: tachyon-core
// prints "tachyon-core version X" first and may still exit non-zero (e.g. a warning
// about a missing config or a signal from a concurrent service stop).
function core_version_output() {
    let bin = find_core_binary();
    return bin != "" ? command_output_lenient(command_from_args([ bin, "version" ]) + " 2>/dev/null") : "";
}

function core_version_state() {
    return file_first_line(CORE_VERSION_STATE_FILE);
}

function core_write_version_state(version) {
    version = as_string(version);
    return version != "" && ensure_parent_dir(CORE_VERSION_STATE_FILE) && write_file(CORE_VERSION_STATE_FILE, version + "\n");
}

function core_clear_version_state() {
    remove_file(CORE_VERSION_STATE_FILE);
    return true;
}

function core_restore_version_state(version) {
    version = as_string(version);
    return version != "" ? core_write_version_state(version) : core_clear_version_state();
}

function core_version() {
    if (find_core_binary() == "")
        return "";
    let state_v = core_version_state();
    if (state_v != "")
        return state_v;
    let v = parse_core_version(core_version_output());
    return match(v, /^[vV]?[0-9]+/) ? v : "";
}

function module_command(args) {
    let command_args = [ "ucode", "-L", LIB_DIR ];
    for (let arg in args)
        push(command_args, arg);
    return command_from_args(command_args);
}

function module_success(args) {
    return command_status(module_command(args)) == 0;
}

// ─── the capability model ────────────────────────────────────────────────────
// The model itself lives in tachyon_core/core_profile.uc: it is a pure lookup, and
// requiring runtime.uc from a generator would run this file's command-line
// dispatch on load and exit the process with a usage message. What is left here
// is reading the installed binary version before delegating.

function core_installed_version() {
    if (find_core_binary() != "") {
        let parsed = parse_core_version(core_version_output());
        if (as_string(parsed) != "")
            return as_string(parsed);
    }
    return core_version();
}

function core_resolve(version, marker) {
    let build = as_string(version == null || version == "" ? core_installed_version() : version);
    return {
        version: build,
        marker: "tachyon-core"
    };
}

function core_profile_name(version, marker) {
    let resolved = core_resolve(version, marker);
    return core_profile.profile(resolved.version, resolved.marker);
}

function core_profile_data(profile) {
    return core_profile.profile_data(profile);
}

function core_pin_field(version, marker) {
    let resolved = core_resolve(version, marker);
    return core_profile.pin_field(resolved.version, resolved.marker);
}

function core_has_1_14(version, marker) {
    let resolved = core_resolve(version, marker);
    return core_profile.has_1_14(resolved.version, resolved.marker);
}

function core_has_1_15(version, marker) {
    let resolved = core_resolve(version, marker);
    return core_profile.has_1_15(resolved.version, resolved.marker);
}

function core_protocols(version, marker) {
    let resolved = core_resolve(version, marker);
    return core_profile.protocols(resolved.version, resolved.marker);
}

function core_supports_protocol(protocol, version, marker) {
    let resolved = core_resolve(version, marker);
    return core_profile.supports_protocol(protocol, resolved.version, resolved.marker);
}

function core_flag(version, marker, field, tag, version_output) {
    let resolved = core_resolve(version, marker);
    let answer = core_profile.flag(resolved.version, resolved.marker, field, tag, version_output);
    return answer == true;
}

function core_capabilities(version, marker, version_output) {
    let output = version_output == null ? null : as_string(version_output);
    let resolved = core_resolve(version, marker);
    let build = resolved.version;
    let field = core_profile.pin_field(build, resolved.marker);
    let protocols = core_profile.protocols(build, resolved.marker);
    let inbounds = core_profile.inbounds(build, resolved.marker);

    let tailscale = core_flag(build, marker, "tailscale", "with_tailscale", output != null ? output : "") ? 1 : 0;
    let xhttp = core_flag(build, marker, "xhttp", "with_xhttp", output != null ? output : "") ? 1 : 0;

    return {
        profile: core_profile.profile(build, resolved.marker),
        version: build,
        marker: resolved.marker,
        pin_field: field,
        cert_pin: field != "",
        schema_1_14: core_has_1_14(build, marker) ? 1 : 0,
        schema_1_15: core_has_1_15(build, marker) ? 1 : 0,
        xhttp,
        tailscale,
        foreign_series: core_profile_data(core_profile_name(build, marker)).foreign_series ? 1 : 0,
        protocols,
        inbounds,
        // What this core cannot do out of the protocols and inbound kinds Tachyon
        // knows, so the interface can name the gap instead of dropping a section
        // silently.
        missing_protocols: core_profile.missing_protocols(protocols),
        missing_inbounds: core_profile.missing_inbounds(inbounds)
    };
}

function core_supports_tailscale(version, version_output) {
    return core_flag(as_string(version), "", "tailscale", "with_tailscale", as_string(version_output));
}

function core_supports_xhttp(version, version_output) {
    return core_flag(as_string(version), "", "xhttp", "with_xhttp", as_string(version_output));
}

function core_supports_cert_pin(version) {
    return true;
}

function log_message(message, level) {
    level = as_string(level || "info");
    command_success_from_args([ "logger", "-t", "tachyon", "[" + level + "] " + as_string(message) ]);
}

function module_env_capture(env, args) {
    let output_path = temp_path();
    if (output_path == "")
        return { status: 1, output: "" };

    let status = command_status(command_env(env) + " " + module_command(args) + " >" + shell_quote(output_path) + " 2>&1");
    let output = as_string(fs.readfile(output_path) || "");
    remove_file(output_path);
    return { status, output };
}

function uci_settings() {
    return object_or_empty(uci_core.get_all(CONFIG_NAME, "settings"));
}

function uci_path(config, section, key) {
    return as_string(config) + "." + as_string(section) + "." + as_string(key);
}

function uci_get_option(config, section, key) {
    return trim(uci_core.get(uci_path(config, section, key)));
}

function uci_set_option(config, section, key, value) {
    if (!uci_core.exists(as_string(config) + "." + as_string(section)))
        return false;
    return uci_core.set(uci_path(config, section, key), value);
}

function uci_commit(config) {
    return uci_core.commit(config);
}

function ensure_core_main_section() {
    let cfg_file = "/etc/config/tachyon-core";
    if (!fs.stat(cfg_file)) {
        let dir = fs.stat("/etc/config");
        if (!dir || dir.type != "directory")
            fs.mkdir("/etc/config", 0755);
        write_file(cfg_file, "");
    }
    if (uci_core.exists("tachyon-core.main"))
        return true;
    if (!uci_core.set_section("tachyon-core.main", "tachyon-core"))
        return false;
    uci_set_option("tachyon-core", "main", "workdir", "/usr/share/tachyon-core");
    uci_set_option("tachyon-core", "main", "conffile", "/etc/tachyon-core/config.json");
    uci_set_option("tachyon-core", "main", "user", "root");
    uci_set_option("tachyon-core", "main", "log_stderr", "1");
    uci_commit("tachyon-core");
    return true;
}

function owner_pid() {
    let pid = trim(command_output_from_args([ "sh", "-c", "echo $PPID" ]));
    return match(pid, /^[0-9]+$/) != null ? pid : "0";
}

function managed_service_installed() {
    let data = fs.readfile("/etc/init.d/tachyon-core");
    if (data == null)
        return false;
    let s = as_string(data);
    return index(s, CORE_MANAGED_SERVICE_MARKER) >= 0 &&
        index(s, "GOMEMLIMIT") < 0 &&
        index(s, "GOGC=") < 0 &&
        index(s, "GODEBUG=") < 0;
}

// Скрипт от предыдущей схемы с Go-переменными, завышенными лимитами или
// самозавершением через killall считается устаревшим и перегенерируется.
function managed_service_script_stale() {
    let data = fs.readfile("/etc/init.d/tachyon-core");
    if (data == null)
        return false;
    data = as_string(data);
    let cp = core_process_or_null();
    let kills_self = (cp && type(cp.init_script_kills_itself) == "function")
        ? cp.init_script_kills_itself(data)
        : fallback_init_script_kills_itself(data);
    return index(data, "config_load \"tachyon-core\"") < 0 ||
        index(data, "core=\"unlimited\"") >= 0 ||
        index(data, "procd_set_param file ") >= 0 ||
        index(data, "GOMEMLIMIT") >= 0 ||
        index(data, "GOGC=") >= 0 ||
        index(data, "GODEBUG=") >= 0 ||
        index(data, "PROG=\"/usr/bin/tachyon-core\"") < 0 ||
        index(data, "stop_service()") < 0 ||
        index(data, "kill -TERM") < 0 ||
        index(data, "reload_service()") < 0 ||
        kills_self;
}

function managed_service_text() {
    let cp = core_process_or_null();
    if (cp && type(cp.managed_core_init_script) == "function")
        return cp.managed_core_init_script(CORE_MANAGED_SERVICE_MARKER, false);
    return fallback_managed_core_init_script(CORE_MANAGED_SERVICE_MARKER);
}

function install_managed_service_script() {
    let tmp = "/etc/init.d/tachyon-core.tachyon." + owner_pid();
    if (!write_file(tmp, managed_service_text()))
        return false;
    if (!command_success_from_args([ "chmod", "0755", tmp ])) {
        remove_file(tmp);
        return false;
    }
    return fs.rename(tmp, "/etc/init.d/tachyon-core");
}

function remove_managed_service_script() {
    if (!managed_service_installed())
        return;

    command_success_from_args([ "/etc/init.d/tachyon-core", "stop" ]);
    command_success_from_args([ "/etc/init.d/tachyon-core", "disable" ]);
    remove_file("/etc/init.d/tachyon-core");
}

function disable_service_config() {
    if (!ensure_core_main_section())
        return;
    uci_set_option("tachyon-core", "main", "enabled", "0");
    uci_commit("tachyon-core");
}

function prepare_service_disabled() {
    disable_service_config();
    if (file_exists("/etc/init.d/tachyon-core")) {
        command_success_from_args([ "/etc/init.d/tachyon-core", "stop" ]);
        command_success_from_args([ "/etc/init.d/tachyon-core", "disable" ]);
    }
}

function configure_service() {
    let settings = uci_settings();

    if ((!managed_service_installed() || managed_service_script_stale()) && !install_managed_service_script()) {
        log_message("Failed to install managed tachyon-core service. Aborted.", "fatal");
        exit(1);
    }

    if (!ensure_core_main_section())
        exit(1);

    let changed = false;
    let workdir = uci_get_option("tachyon-core", "main", "workdir") || "/usr/share/tachyon-core";
    if (!fs.stat(workdir)) {
        let parent = "/usr/share";
        if (!fs.stat(parent))
            fs.mkdir(parent, 0755);
        fs.mkdir(workdir, 0755);
    }

    if (fs.stat("/www")?.type == "directory" && fs.stat(workdir + "/ui")?.type == "directory") {
        let yacd_link = "/www/yacd";
        let yacd_target = workdir + "/ui";
        let current_target = fs.readlink(yacd_link);
        if (current_target != yacd_target) {
            try { fs.unlink(yacd_link); } catch (e) {}
            try { fs.symlink(yacd_target, yacd_link); } catch (e) {}
        }
    }

    if (uci_get_option("tachyon-core", "main", "enabled") != "1") {
        if (!uci_set_option("tachyon-core", "main", "enabled", "1"))
            exit(1);
        changed = true;
        log_message("tachyon-core service has been enabled", "info");
    }

    if (uci_get_option("tachyon-core", "main", "user") != "root") {
        if (!uci_set_option("tachyon-core", "main", "user", "root"))
            exit(1);
        changed = true;
        log_message("tachyon-core service user has been changed to root", "info");
    }

    let config_path = option(settings, "config_path", "");
    let conffile = uci_get_option("tachyon-core", "main", "conffile");
    if (conffile != config_path) {
        if (!uci_set_option("tachyon-core", "main", "conffile", config_path))
            exit(1);
        changed = true;
        log_message("tachyon-core service config path set to " + config_path, "info");
    }

    if (changed && !uci_commit("tachyon-core"))
        exit(1);

    if (file_exists("/etc/rc.d/S99tachyon-core")) {
        log_message("Disabling standalone tachyon-core autostart", "info");
        command_success_from_args([ "/etc/init.d/tachyon-core", "disable" ]);
    }
}

function download_via_proxy_option_for_purpose(purpose) {
    purpose = as_string(purpose || "lists");
    if (purpose == "lists")
        return "download_lists_via_proxy";
    if (purpose == "components")
        return "download_components_via_proxy";
    return "";
}

function download_via_proxy_section_option_for_purpose(purpose) {
    purpose = as_string(purpose || "lists");
    if (purpose == "lists")
        return "download_lists_via_proxy_section";
    if (purpose == "components")
        return "download_components_via_proxy_section";
    return "";
}

function download_via_proxy_section(settings, purpose) {
    let enabled_option = download_via_proxy_option_for_purpose(purpose);
    if (enabled_option == "" || !bool_option(settings, enabled_option, false))
        return "";

    let section_option = download_via_proxy_section_option_for_purpose(purpose);
    let configured = section_option != "" ? option(settings, section_option, "") : "";
    if (configured != "")
        return configured;

    return option(settings, "download_lists_via_proxy_section", "");
}

function service_proxy_port_for_purpose(purpose) {
    return int(CORE_SERVICE_MIXED_INBOUND_PORT) + (as_string(purpose || "lists") == "components" ? 1 : 0);
}

function service_proxy_address(settings, purpose) {
    return download_via_proxy_section(settings, purpose) != "" ?
        CORE_SERVICE_MIXED_INBOUND_ADDRESS + ":" + service_proxy_port_for_purpose(purpose) : "";
}

function ip_addr_first_inet4(data) {
    for (let line in split(as_string(data), "\n")) {
        let matched = match(line, /inet[ \t]+([0-9.]+)\//);
        if (matched)
            return as_string(matched[1]);
    }
    return "";
}

function network_interface_ipv4(name) {
    let data = command_output_from_args([ "ubus", "call", "network.interface." + as_string(name), "status" ]);
    try {
        let value = json(data);
        let addresses = array_or_empty(object_or_empty(value)["ipv4-address"]);
        if (length(addresses) > 0)
            return as_string(object_or_empty(addresses[0]).address);
    }
    catch (e) {
        // An interface that is down answers with an error rather than a status
        // object. The empty string the caller gets back means the same thing.
    }
    return "";
}

function device_ipv4_address_value(device) {
    return ip_addr_first_inet4(command_output_from_args([ "ip", "-4", "addr", "show", "dev", as_string(device) ]));
}

// Returns true for RFC-1918 private IPv4 addresses (10/8, 172.16/12, 192.168/16).
// Used to filter out WAN/public addresses when enumerating interfaces.
function is_private_ipv4(addr) {
    addr = as_string(addr);
    return match(addr, /^10\./) != null ||
           match(addr, /^172\.(1[6-9]|2[0-9]|3[01])\./) != null ||
           match(addr, /^192\.168\./) != null;
}

// Last-resort fallback for non-standard setups (e.g. x86/64 where the LAN
// interface is named "eth1", "enp2s0", etc. — not "lan" or "br-lan").
// Calls `ubus call network.interface dump` to get all UCI interfaces, then
// returns the first private IPv4 found on a non-loopback, non-WAN interface.
function network_interface_dump_first_private_ipv4() {
    let data = command_output_from_args([ "ubus", "call", "network.interface", "dump" ]);
    try {
        let value = json(data);
        let interfaces = array_or_empty(object_or_empty(value)["interface"]);
        for (let iface in interfaces) {
            iface = object_or_empty(iface);
            let name = as_string(iface["interface"] || "");
            // Skip obviously non-LAN interfaces.
            if (name == "wan" || name == "wan6" || name == "loopback" || name == "")
                continue;
            for (let addr_obj in array_or_empty(iface["ipv4-address"])) {
                let addr = as_string(object_or_empty(addr_obj).address);
                if (addr != "" && is_private_ipv4(addr))
                    return addr;
            }
        }
    }
    catch (e) {}
    return "";
}

function service_listen_address_value(settings) {
    let configured = option(settings, "service_listen_address", "");
    if (configured != "") {
        log_message("service_listen_address is set manually; automatic listen-address detection is skipped", "debug");
        return configured;
    }

    let address = network_interface_ipv4("lan");
    if (address != "")
        return address;

    for (let iface in whitespace_items(option(settings, "source_network_interfaces", "br-lan"))) {
        address = network_interface_ipv4(iface);
        if (address != "")
            return address;
        address = device_ipv4_address_value(iface);
        if (address != "")
            return address;
    }

    // Third-tier fallback: enumerate all UCI interfaces via ubus dump.
    // Handles x86/64 and other non-standard setups where LAN is not named
    // "lan"/"br-lan". Skips wan, wan6, loopback and any public addresses.
    address = network_interface_dump_first_private_ipv4();
    if (address != "") {
        log_message("listen-address auto-detected via interface dump: " + address + ". Set service_listen_address in UCI to pin it.", "warn");
        return address;
    }

    log_message("Failed to determine the listening IP address. Please open an issue to report this problem: https://github.com/Dushnilin/tachyon/issues", "error");
    return "";
}

function subscription_cache_env() {
    return {
        TACHYON_CONFIG_NAME: CONFIG_NAME,
        TACHYON_LIB: LIB_DIR,
        TMP_TACHYON_CORE_FOLDER,
        TMP_RULESET_FOLDER,
        TMP_SUBSCRIPTION_FOLDER,
        TACHYON_RUNTIME_STATE_DIR: RUNTIME_STATE_DIR,
        TACHYON_SUBSCRIPTION_UPDATE_STATE_DIR: SUBSCRIPTION_UPDATE_STATE_DIR,
        TACHYON_SUBSCRIPTION_LINKS_DIR: SUBSCRIPTION_LINKS_DIR,
        TACHYON_SUBSCRIPTION_METADATA_DIR: SUBSCRIPTION_METADATA_DIR,
        TACHYON_OUTBOUND_METADATA_DIR: OUTBOUND_METADATA_DIR,
        TACHYON_SECTION_CACHE_DIR: SECTION_CACHE_DIR,
        TACHYON_RUNTIME_CACHE_FORMAT_FILE: RUNTIME_CACHE_FORMAT_FILE,
        TACHYON_RUNTIME_CACHE_FORMAT: RUNTIME_CACHE_FORMAT,
        TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_DIR: PERSISTENT_SUBSCRIPTION_CACHE_DIR,
        TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE: PERSISTENT_SUBSCRIPTION_CACHE_FORMAT_FILE,
        TACHYON_PERSISTENT_SUBSCRIPTION_CACHE_FORMAT: PERSISTENT_SUBSCRIPTION_CACHE_FORMAT,
        TACHYON_PENDING_RELOAD_FILE: PENDING_RELOAD_FILE,
        TACHYON_SERVICE_INIT: SERVICE_INIT
    };
}

function subscription_cache_capture(args) {
    let command_args = [ LIB_DIR + "/subscription/cache.uc" ];
    for (let arg in args)
        push(command_args, arg);
    return module_env_capture(subscription_cache_env(), command_args);
}

function log_lines(text, level, prefix) {
    for (let line in split(as_string(text), "\n"))
        if (trim(as_string(line)) != "")
            log_message(as_string(prefix) + as_string(line), level);
}

function first_nonblank_line(path) {
    let data = as_string(fs.readfile(path) || "");
    for (let line in split(data, "\n"))
        if (trim(as_string(line)) != "")
            return as_string(line);
    return "";
}

function last_nonblank_line(path) {
    let result = "";
    let data = as_string(fs.readfile(path) || "");
    for (let line in split(data, "\n"))
        if (trim(as_string(line)) != "")
            result = as_string(line);
    return result;
}

function first_error_line(path) {
    let data = as_string(fs.readfile(path) || "");
    for (let line in split(data, "\n")) {
        let text = as_string(line);
        if (trim(text) == "")
            continue;
        if (match(text, /error|fail|invalid|unexpected|near here/i) != null)
            return text;
    }
    return "";
}

function generator_failure_reason(path, status) {
    let reason = first_error_line(path);
    if (reason == "")
        reason = last_nonblank_line(path);
    return reason != "" ? reason : "exit status " + status;
}

function log_file_lines(path, level, prefix) {
    log_lines(fs.readfile(path), level, prefix);
}

// The same binary core_check() runs, so the diagnosis names the file that
// actually failed rather than a path we guessed.
function core_binary_path() {
    // command_output_lenient returns the newline; stat'ing the raw value would
    // report an existing binary as missing.
    return trim(command_output_lenient("command -v tachyon-core 2>/dev/null")) || "/usr/bin/tachyon-core";
}


let binary_diag = require("tachyon_core.binary_diag");
let core_binary_problem = binary_diag.core_binary_problem;
let core_check_blamed_the_binary = binary_diag.core_check_blamed_the_binary;
function core_check(config_path, output_path) {
    let bin = find_core_binary();
    if (bin == "")
        bin = "tachyon-core";
    let check_cmd = command_from_args([ bin, "-c", config_path, "check" ]) +
        " >" + shell_quote(output_path) + " 2>&1";
    let status = command_status(check_cmd);
    if ((status == 247 || status == 137) && fs.stat("/proc/sys/vm/drop_caches") != null) {
        system("sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null");
        status = command_status(check_cmd);
    }
    let reason = status == 0 ? "" : first_nonblank_line(output_path);
    if (status != 0 && reason == "") {
        if (status == 247 || status == 137)
            reason = "Out of memory (OOM killed, exit status " + status + ")";
        else
            reason = "exit status " + status;
    }
    return { status, reason };
}

function core_engine_label() {
    return "tachyon-core";
}

function prepare_subscription_caches(prepared, no_refresh) {
    let result = subscription_cache_capture([ "prepare-caches", "runtime", prepared ? "1" : "0", no_refresh ? "1" : "0" ]);
    if (result.status != 0) {
        log_message("Subscription caches are not ready for " + core_engine_label() + " config generation. Aborted.", "fatal");
        log_lines(result.output, "debug", "subscription cache: ");
        return null;
    }
    let known_sections = {};
    for (let sec in array_or_empty(uci_core.sections(CONFIG_NAME, "section"))) {
        let name = common.section_name(sec);
        if (name != "")
            known_sections[name] = true;
    }
    let cleaned = [];
    for (let token in split(trim(as_string(result.output)), /[ \t\r\n]+/)) {
        if (token != "" && match(token, /^[A-Za-z0-9_-]+$/) != null &&
            (length(keys(known_sections)) == 0 || known_sections[token] == true))
            push(cleaned, token);
    }
    return join(" ", cleaned);
}

function listening_endpoints_changed(old_cfg, new_cfg) {
    let collect = function(cfg) {
        let out = [];
        if (type(cfg) != "object" || type(cfg.endpoints) != "array")
            return out;
        for (let ep in cfg.endpoints) {
            if (type(ep) == "object" && (int(ep.listen_port || 0) > 0 || ep.system === true))
                push(out, sprintf("%J", ep));
        }
        return out;
    };
    return sprintf("%J", collect(old_cfg)) != sprintf("%J", collect(new_cfg));
}

function enrich_reload_preview(parsed, current_path, candidate_path, old_exists) {
    let old_cfg = old_exists ? common.read_json_file(current_path) : null;
    let new_cfg = common.read_json_file(candidate_path);
    let keys_to_check = [ "inbounds", "outbounds", "endpoints", "route", "dns", "experimental" ];
    let subsystems = {};
    let changed_subsystems = [];
    for (let k in keys_to_check) {
        let old_val = type(old_cfg) == "object" ? sprintf("%J", old_cfg[k]) : "null";
        let new_val = type(new_cfg) == "object" ? sprintf("%J", new_cfg[k]) : "null";
        let diff = !old_exists || old_val != new_val;
        subsystems[k] = diff;
        if (diff)
            push(changed_subsystems, k);
    }
    parsed.subsystems = subsystems;
    parsed.changed_subsystems = changed_subsystems;
    if (!old_exists) {
        parsed.in_place = false;
        parsed.current_digest = "";
    } else if (listening_endpoints_changed(old_cfg, new_cfg)) {
        // Modified endpoints with a bound UDP listen_port or kernel interface cannot
        // bind a second time while the old instance still holds the socket/interface;
        // unchanged endpoints are inherited in-place by tachyon-core.
        parsed.in_place = false;
    }
    return parsed;
}

function write_reload_preview(current_path, candidate_path) {
    if (!file_exists(candidate_path))
        return;
    let bin = find_core_binary();
    if (bin == "") {
        remove_file(RELOAD_PREVIEW_FILE);
        return;
    }
    let old_exists = file_exists(current_path);
    let base_path = old_exists ? current_path : candidate_path;
    let out = trim(command_output_from_args([ bin, "reload-preview", "--current", base_path, "-c", candidate_path ]));
    if (out == "") {
        remove_file(RELOAD_PREVIEW_FILE);
        return;
    }
    try {
        let parsed = json(out);
        if (type(parsed) == "object" && (parsed.in_place === true || parsed.in_place === false)) {
            enrich_reload_preview(parsed, current_path, candidate_path, old_exists);
            ensure_parent_dir(RELOAD_PREVIEW_FILE);
            write_file(RELOAD_PREVIEW_FILE, sprintf("%J\n", parsed));
            return;
        }
    } catch (e) {
        remove_file(RELOAD_PREVIEW_FILE);
        return;
    }
    remove_file(RELOAD_PREVIEW_FILE);
}

function save_config_file(temp_file_path, config_path) {
    let current_hash = md5_file(config_path);
    let temp_hash = md5_file(temp_file_path);

    if (current_hash != temp_hash) {
        log_message(core_engine_label() + " configuration changed; updating " + config_path, "info");
        if (!ensure_parent_dir(config_path))
            return false;
        write_reload_preview(config_path, temp_file_path);
        return command_success_from_args([ "mv", "-f", temp_file_path, config_path ]);
    }

    write_reload_preview(config_path, temp_file_path);
    log_message(core_engine_label() + " configuration is unchanged", "info");
    remove_file(temp_file_path);
    return true;
}

function replace_dns_server(config, replacement) {
    let servers = array_or_empty(object_or_empty(config.dns).servers);
    for (let i = 0; i < length(servers); i++) {
        if (as_string(object_or_empty(servers[i]).tag) == as_string(replacement.tag)) {
            servers[i] = replacement;
            return true;
        }
    }
    return false;
}

function patch_dns_config(state_path) {
    let settings = uci_settings();
    let candidate_state = common.read_json_file(state_path);
    let expected = runtime_dns.state_template(settings);
    if (!runtime_dns.state_matches(expected, candidate_state)) {
        log_message("DNS failover state does not match the current UCI configuration", "warn");
        exit(2);
    }

    let config_path = option(settings, "config_path", "");
    let config = common.read_json_file(config_path);
    if (config_path == "" || type(config) != "object") {
        log_message("Cannot read the current " + core_engine_label() + " configuration for DNS failover", "error");
        exit(1);
    }

    let main = runtime_dns.server_config(settings, candidate_state);
    let bootstrap = runtime_dns.bootstrap_config(settings, candidate_state);
    if (main.unsupported || !replace_dns_server(config, main) || !replace_dns_server(config, bootstrap)) {
        log_message("Cannot locate or build canonical DNS servers for failover", "error");
        exit(1);
    }

    let backup_path = temp_path();
    let temp_config = temp_path();
    if (backup_path == "" || temp_config == "" ||
        fs.writefile(backup_path, fs.readfile(config_path)) == null ||
        !common.write_json_file(temp_config, config, 2)) {
        remove_files([ backup_path, temp_config ]);
        exit(1);
    }

    let check_log = temp_path();
    let check_result = check_log == ""
        ? { status: 1, reason: "unable to create check output file" }
        : core_check(temp_config, check_log);
    if (check_result.status != 0) {
        log_message("DNS failover produced an invalid " + core_engine_label() + " configuration: " + check_result.reason, "error");
        remove_files([ backup_path, temp_config, check_log ]);
        exit(1);
    }
    remove_file(check_log);

    let changed = md5_file(config_path) != md5_file(temp_config);
    if (!save_config_file(temp_config, config_path)) {
        remove_file(backup_path);
        exit(1);
    }

    if (!changed) {
        remove_file(backup_path);
        print("0\n");
        return;
    }

    print("1\t", backup_path, "\n");
}

function restore_dns_config(backup_path) {
    let config_path = option(uci_settings(), "config_path", "");
    if (config_path == "" || !file_exists(backup_path))
        return false;
    return command_success_from_args([ "mv", "-f", backup_path, config_path ]);
}


const EMPTY_SRS_BINARY = hexdec("5352530278da6200040000ffff00010001");

function file_has_valid_trs_magic(path) {
    let f = fs.open(path, "r");
    if (!f)
        return false;
    let magic = f.read(4);
    f.close();
    if (!magic || length(magic) < 3)
        return false;
    let m3 = substr(magic, 0, 3);
    return m3 == "TRS" || magic == "TSRS" || magic == "TCRS";
}

function ensure_local_rulesets_exist(temp_config) {
    try {
        let cfg_raw = as_string(fs.readfile(temp_config) || "");
        let cfg_obj = length(cfg_raw) > 0 ? json(cfg_raw) : null;
        if (type(cfg_obj) == "object" && type(cfg_obj.route) == "object" && type(cfg_obj.route.rule_set) == "array") {
            command_success_from_args(["mkdir", "-p", TMP_RULESET_FOLDER]);
            let active_local_paths = {};
            let keep_compiled_tags = {};
            let cfg_modified = false;
            for (let rs in cfg_obj.route.rule_set) {
                if (type(rs) != "object")
                    continue;
                let rs_tag = as_string(rs.tag || "");
                if (rs.type == "local" && rs.path) {
                    let rs_path = as_string(rs.path);
                    let is_trs_path = match(rs_path, /\.trs$/) != null;
                    active_local_paths[rs_path] = true;
                    if (!is_trs_path && rs_tag != "")
                        keep_compiled_tags[rs_tag] = true;
                    let st = fs.stat(rs_path);
                    let needs_repair = !st || st.size < (is_trs_path ? 16 : 17) ||
                        (is_trs_path && !file_has_valid_trs_magic(rs_path));
                    if (needs_repair) {
                        let bname = replace(rs_path, /^.*\//, "");
                        let etc_dir = getenv("TACHYON_PERSISTENT_RULESETS_DIR") || "/etc/tachyon/rulesets";
                        let etc_file = etc_dir + "/" + bname;
                        let etc_st = fs.stat(etc_file);
                        if (etc_st && etc_st.size >= (is_trs_path ? 16 : 17) &&
                            (!is_trs_path || file_has_valid_trs_magic(etc_file))) {
                            let content = fs.readfile(etc_file);
                            if (content) fs.writefile(rs_path, content);
                        } else if (rs.format == "source" || match(rs_path, /\.json$/)) {
                            fs.writefile(rs_path, sprintf("%J", { version: 3, rules: [] }));
                        } else if (is_trs_path) {
                            // Never write an SRS header stub to a .trs path: switch the temporary
                            // check entry to an empty JSON source set and delete any corrupt .trs file.
                            try { fs.unlink(rs_path); } catch (e) {}
                            let fallback_json = TMP_RULESET_FOLDER + "/" + replace(bname, /\.trs$/, ".empty.json");
                            fs.writefile(fallback_json, sprintf("%J", { version: 3, rules: [] }));
                            rs.format = "source";
                            rs.path = fallback_json;
                            if (rs_tag != "")
                                keep_compiled_tags[rs_tag] = true;
                            cfg_modified = true;
                        } else {
                            fs.writefile(rs_path, EMPTY_SRS_BINARY);
                        }
                    }
                } else if (rs_tag != "") {
                    keep_compiled_tags[rs_tag] = true;
                }
            }
            if (cfg_modified)
                fs.writefile(temp_config, sprintf("%J\n", cfg_obj));
            let rdir = fs.opendir(TMP_RULESET_FOLDER);
            if (rdir) {
                let entry;
                while ((entry = rdir.read()) != null) {
                    if (match(entry, /\.trs$/) && substr(entry, 0, 1) != ".") {
                        let full_p = TMP_RULESET_FOLDER + "/" + entry;
                        if (!active_local_paths[full_p])
                            remove_file(full_p);
                    }
                }
                rdir.close();
            }
            let cdir = fs.opendir("/tmp/tachyon-rulesets");
            if (cdir) {
                let entry;
                while ((entry = cdir.read()) != null) {
                    if (match(entry, /\.(trs|tsr|tmp)$/)) {
                        let tag_part = replace(entry, /\.(trs|tsr|tmp)$/, "");
                        if (!keep_compiled_tags[tag_part])
                            remove_file("/tmp/tachyon-rulesets/" + entry);
                    }
                }
                cdir.close();
            }
        }
    } catch (e) {}
}

// Strips the field tachyon-core rejected from the outbound it named, logging which one
// it was. Returns true only when something changed, so the caller retries instead of
// rewriting the same file for a reason it cannot act on. The repair itself lives in
// components/verifier so the apply path and the pre-flight share one tested copy:
// this branch used to inline it and called to_string(), which does not exist in
// ucode - the undefined call crashed init_config on the first rejected field and
// took the whole start down with it.
function repair_outbound_field(temp_config, reason) {
    if (!verifier.repair_unknown_outbound_field(temp_config, reason))
        return false;
    let core_name = "tachyon-core";
    let m = match(verifier.normalize_unknown_field_reason(reason), /outbounds\[(\d+)\]\.(\w+): json: unknown field/);
    if (m) {
        let bad_index = int(m[1]);
        log_message("Installed " + core_name + " does not support outbound field '" + m[2] +
            "' on outbound " + (bad_index >= 0 ? sprintf("%d", bad_index) : "?") +
            "; retrying without it there only", "warn");
    } else {
        log_message("Installed " + core_name + " does not support field reported in '" + reason + "'; retrying without it", "warn");
    }
    return true;
}

// --- section quarantine ------------------------------------------------------
//
// A generated config that tachyon-core refuses to load must not take the whole
// proxy down: the runtime isolates the offending section, regenerates without
// it and starts with the rest, leaving the error visible to the UI in
// /var/run/tachyon/section-errors.json. Only failures that tachyon-core itself
// attributes to an outbound/endpoint/inbound/rule-set tag get quarantined -
// tags carry the owning section name as their prefix, and section names are
// [A-Za-z0-9_]+ (valid_section_name in the generator), so the substring before
// the first "-" or "/" identifies the owner. A failure that cannot be
// attributed keeps the old fatal behaviour: guessing here would drop random
// sections and still leave the user without a proxy.

const SECTION_ERRORS_FILE = getenv("TACHYON_SECTION_ERRORS_FILE") || "/var/run/tachyon/section-errors.json";
const VALIDATOR_QUARANTINED_FILE = getenv("TACHYON_VALIDATOR_QUARANTINED_FILE") || "/var/run/tachyon/validator-quarantined.json";

function expand_check_error_reason(reason) {
    let raw = trim(as_string(reason || ""));
    let clean = replace(raw, /\x1b\[[0-9;]*[A-Za-z]/g, "");
    clean = replace(clean, /^.*tachyon-section-error:[A-Za-z0-9_]+:/, "");
    clean = replace(clean, /^(FATAL|ERROR)\[[0-9]+\][ \t]*/, "");
    if (index(clean, "Причина:") >= 0)
        return clean;

    let hint = "";
    if (index(clean, "unknown field") >= 0 || index(clean, "unknown transport") >= 0 || index(clean, "unknown outbound") >= 0 || index(clean, "unknown inbound") >= 0 || index(clean, "unknown endpoint") >= 0)
        hint = "Причина: установленное ядро не поддерживает указанное поле, транспорт или протокол. Решение: обновите ядро во вкладке «Компоненты» или измените параметры протокола в секции.";
    else if (index(clean, "missing required field") >= 0 || index(clean, "empty") >= 0)
        hint = "Причина: в конфигурации прокси-сервера или секции не заполнено обязательное поле (адрес сервера, порт, UUID или ключ). Решение: проверьте параметры подключения.";
    else if (index(clean, "address already in use") >= 0 || index(clean, "bind:") >= 0)
        hint = "Причина: порт прослушивания уже занят другой службой или другим входящим сервером. Решение: укажите свободный порт в настройках секции или входящего сервера.";
    else if (index(clean, "missing outbound tag") >= 0 || index(clean, "unknown outbound tag") >= 0)
        hint = "Причина: правило маршрутизации или каскадирования ссылается на несуществующий или изолированный прокси-выход. Решение: проверьте настройки источника серверов и каскадирования.";
    else if (index(clean, "no such file or directory") >= 0)
        hint = "Причина: не найден файл сертификата, ключа или локального списка правил (ruleset). Решение: проверьте пути к файлам в настройках.";
    else if (index(clean, "manual proxy link") >= 0 || index(clean, "not supported") >= 0 || index(clean, "unsupported") >= 0)
        hint = "Причина: неподдерживаемый формат прокси-ссылки или параметра секции. Решение: проверьте синтаксис ссылок во вкладке «Пул серверов» или настройках секции.";
    else if (index(clean, "invalid") >= 0 || index(clean, "parse") >= 0 || index(clean, "decode") >= 0)
        hint = "Причина: некорректный формат значения (IP-адрес, порт, ключ, регулярное выражение или JSON). Решение: проверьте введённые данные в настройках секции.";
    else
        hint = "Причина: ядро отклонило конфигурацию этой секции при проверке. Решение: проверьте параметры подключения и правила секции (остальные секции работают в штатном режиме).";

    return clean + " — " + hint;
}

function section_exists(name) {
    name = as_string(name || "");
    return name != "" && uci_core.exists(CONFIG_NAME + "." + name);
}

function section_from_tag(tag) {
    let s = as_string(tag || "");
    let srv = match(s, /^server-([A-Za-z0-9_]+)-in(-inner)?$/);
    if (srv)
        return srv[1];
    let m = match(s, /^([A-Za-z0-9_]+)[-\/]/);
    return m ? m[1] : "";
}

// The runtime keeps the quarantine map up to date for the UI. The file lives
// in /var/run (tmpfs), never on flash; write_json_file's unchanged-content
// guard keeps repeat writes silent.
function write_section_errors(quarantined) {
    let errors = {};
    for (let name in quarantined)
        errors[name] = as_string(quarantined[name] || "");
    if (length(errors) == 0) {
        remove_file(SECTION_ERRORS_FILE);
        return;
    }
    common.write_json_file(SECTION_ERRORS_FILE, errors);
}

// When generation itself dies on a section (runtime_generate_unsupported), the
// generator names the section in a tachyon-section-error:<name>:<reason> line
// before exiting 2.
function section_from_generator_log(log_path) {
    let text = as_string(fs.readfile(log_path) || "");
    let m = match(text, /tachyon-section-error:([A-Za-z0-9_]+):/);
    return m ? m[1] : "";
}

function config_item_tag(config, list_name, index) {
    let list = type(config) == "object" ? config[list_name] : null;
    if (type(list) != "array")
        return null;
    let i = int(index);
    if (i < 0 || i >= length(list) || type(list[i]) != "object")
        return null;
    return list[i].tag;
}

function load_config_owners(config_path) {
    let sidecar = common.read_json_file(as_string(config_path) + ".owners.json");
    if (type(sidecar) == "object")
        return sidecar;
    let global_owners = common.read_json_file(getenv("TACHYON_CONFIG_OWNERS_FILE") || "/var/run/tachyon/config-owners.json");
    return type(global_owners) == "object" ? global_owners : null;
}

// Maps a tachyon-core check failure to the section that produced the blamed
// element. Returns "" when the failure is not attributable to a section
// (global settings, inbounds of the service itself, unparseable output).
function section_from_check_reason(reason, config_path) {
    reason = as_string(reason || "");
    let tag = null;
    let owners = load_config_owners(config_path);
    let direct_owner = "";

    let m = match(reason, /(outbounds?|endpoints?|inbounds?)\[(\d+)\]/);
    if (m) {
        let kind = m[1];
        if (kind == "inbound")
            kind = "inbounds";
        else if (kind == "outbound")
            kind = "outbounds";
        else if (kind == "endpoint")
            kind = "endpoints";
        tag = config_item_tag(common.read_json_file(config_path), kind, m[2]);
        if (type(owners) == "object" && type(owners[kind]) == "object" && owners[kind][as_string(m[2])] != null)
            direct_owner = as_string(owners[kind][as_string(m[2])]);
    }

    if (tag == null) {
        let srv_m = match(reason, /\[(server-[A-Za-z0-9_]+-in(-inner)?)\]/);
        if (srv_m)
            tag = srv_m[1];
    }

    if (tag == null) {
        let rs = match(reason, /rule[-_]set\[(\d+)\]/);
        if (rs) {
            let cfg = common.read_json_file(config_path);
            let list = type(cfg) == "object" && type(cfg.route) == "object" ? cfg.route.rule_set : null;
            let i = int(rs[1]);
            if (type(list) == "array" && i >= 0 && i < length(list) && type(list[i]) == "object")
                tag = list[i].tag;
            if (type(owners) == "object" && type(owners.rule_set) == "object" && owners.rule_set[as_string(rs[1])] != null)
                direct_owner = as_string(owners.rule_set[as_string(rs[1])]);
        }
    }

    if (tag == null) {
        let tm = match(reason, /(missing|unknown) outbound tag: *([-A-Za-z0-9_/]+)/);
        if (tm)
            tag = tm[2];
    }

    if (tag == null) {
        let br_m = match(reason, /\[[A-Za-z0-9_.-]+\/([^\]]+)\]/);
        if (br_m)
            tag = br_m[1];
    }

    if (direct_owner == "" && type(owners) == "object") {
        // ucode's regex has no non-capturing group, so the optional
        // "route." prefix is matched with its own pattern and the index is
        // taken from whichever one hits.
        let rr_m = match(reason, /route\.rules\[(\d+)\]/);
        if (!rr_m)
            rr_m = match(reason, /rules\[(\d+)\]/);
        if (rr_m && type(owners.route_rules) == "object" && owners.route_rules[as_string(rr_m[1])] != null)
            direct_owner = as_string(owners.route_rules[as_string(rr_m[1])]);
        let ds_m = match(reason, /dns\.servers\[(\d+)\]/);
        if (ds_m && type(owners.dns_servers) == "object" && owners.dns_servers[as_string(ds_m[1])] != null)
            direct_owner = as_string(owners.dns_servers[as_string(ds_m[1])]);
        let port_m = match(reason, /:([0-9]{2,5})\b/);
        if (port_m && type(owners.ports) == "object" && owners.ports[as_string(port_m[1])] != null)
            direct_owner = as_string(owners.ports[as_string(port_m[1])]);
    }

    let name = section_from_tag(tag);
    if (section_exists(name))
        return name;
    if (tag != null && type(owners) == "object" && type(owners.tags) == "object" && owners.tags[as_string(tag)] != null) {
        let mapped = as_string(owners.tags[as_string(tag)]);
        if (section_exists(mapped))
            return mapped;
    }
    if (direct_owner != "" && section_exists(direct_owner))
        return direct_owner;
    return "";
}

function shift_owners_outbounds(config_path, removed_idx) {
    let sidecar_path = as_string(config_path) + ".owners.json";
    let owners = common.read_json_file(sidecar_path);
    if (type(owners) != "object" || type(owners.outbounds) != "object")
        return;
    let updated = {};
    for (let k, v in owners.outbounds) {
        let idx = int(k);
        if (idx == null || idx == removed_idx)
            continue;
        if (idx > removed_idx)
            updated[as_string(idx - 1)] = v;
        else
            updated[as_string(idx)] = v;
    }
    owners.outbounds = updated;
    common.write_json_file(sidecar_path, owners);
}

// Strips a single incompatible leaf outbound (e.g. one subscription VLESS node
// with unsupported encryption padding) when every group/selector referencing it
// still has at least one other working member. If the node is the only member
// of its section selector, returns false so the section quarantine loop handles
// the section as a whole.
function strip_broken_leaf_outbound(temp_config, reason) {
    reason = as_string(reason || "");
    let m = match(reason, /outbounds?\[(\d+)\]/);
    if (!m)
        return false;
    let out_idx = int(m[1]);
    let cfg_text = as_string(fs.readfile(temp_config) || "");
    let cfg = length(cfg_text) > 0 ? json(cfg_text) : null;
    if (type(cfg) != "object" || type(cfg.outbounds) != "array" || out_idx < 0 || out_idx >= length(cfg.outbounds))
        return false;
    let bad_out = cfg.outbounds[out_idx];
    if (type(bad_out) != "object")
        return false;
    let btype = as_string(bad_out.type || "");
    let btag = as_string(bad_out.tag || "");
    if (btag == "" || btype == "selector" || btype == "urltest" || btype == "direct" || btype == "block" || btype == "dns")
        return false;
    if (match(btag, /-out$/) != null)
        return false;

    let referenced_in_group = false;
    for (let i = 0; i < length(cfg.outbounds); i++) {
        if (i == out_idx)
            continue;
        let outb = cfg.outbounds[i];
        if (type(outb) != "object")
            continue;
        if (as_string(outb.detour || "") == btag)
            return false;
        if (type(outb.outbounds) == "array") {
            let has_btag = false;
            let remaining = 0;
            for (let member in outb.outbounds) {
                if (as_string(member) == btag)
                    has_btag = true;
                else
                    remaining++;
            }
            if (has_btag) {
                referenced_in_group = true;
                if (remaining == 0)
                    return false;
            }
        }
    }
    if (!referenced_in_group)
        return false;

    if (type(cfg.route) == "object" && type(cfg.route.rules) == "array") {
        for (let r in cfg.route.rules) {
            if (type(r) == "object" && as_string(r.outbound || "") == btag)
                return false;
        }
    }
    if (type(cfg.dns) == "object" && type(cfg.dns.servers) == "array") {
        for (let ds in cfg.dns.servers) {
            if (type(ds) == "object" && as_string(ds.detour || "") == btag)
                return false;
        }
    }

    log_message("Skipping incompatible outbound '" + btag + "' at index " + out_idx + " (" + reason + "); keeping remaining working nodes", "warn");
    splice(cfg.outbounds, out_idx, 1);
    for (let outb in cfg.outbounds) {
        if (type(outb) == "object" && type(outb.outbounds) == "array") {
            let filtered = [];
            for (let tag in outb.outbounds) {
                if (as_string(tag) != btag)
                    push(filtered, tag);
            }
            outb.outbounds = filtered;
            if (as_string(outb.default || "") == btag) {
                if (length(filtered) > 0)
                    outb.default = filtered[0];
                else
                    delete outb.default;
            }
        }
    }
    write_file(temp_config, sprintf("%J", cfg));
    shift_owners_outbounds(temp_config, out_idx);
    return true;
}

// Inspects generated outbounds for references (detour or selector/urltest
// members) to tags that do not exist in outbounds/endpoints (for example, when
// a target section like Proxy was quarantined and another section references
// Proxy-out). Prunes missing tags from multi-member groups, and returns a
// synthetic check failure reason when an outbound's sole target or detour is
// missing so the quarantine loop isolates the dependent section cleanly before
// starting the service.
function repair_or_find_dangling_outbound_dependency(temp_config) {
    let cfg_text = as_string(fs.readfile(temp_config) || "");
    let cfg = length(cfg_text) > 0 ? json(cfg_text) : null;
    if (type(cfg) != "object" || type(cfg.outbounds) != "array")
        return "";

    let known_tags = {};
    for (let outb in cfg.outbounds) {
        if (type(outb) == "object" && as_string(outb.tag || "") != "")
            known_tags[as_string(outb.tag)] = true;
    }
    if (type(cfg.endpoints) == "array") {
        for (let ep in cfg.endpoints) {
            if (type(ep) == "object" && as_string(ep.tag || "") != "")
                known_tags[as_string(ep.tag)] = true;
        }
    }

    let modified = false;
    for (let i = 0; i < length(cfg.outbounds); i++) {
        let outb = cfg.outbounds[i];
        if (type(outb) != "object")
            continue;
        let otag = as_string(outb.tag || ("#" + i));
        let detour = as_string(outb.detour || "");
        if (detour != "" && !known_tags[detour]) {
            return "outbounds[" + i + "]: dependency[" + detour + "] not found for outbound[" + otag + "]: missing outbound tag: " + detour;
        }
        if (type(outb.outbounds) == "array" && length(outb.outbounds) > 0) {
            let valid_members = [];
            let missing_members = [];
            for (let m in outb.outbounds) {
                let mtag = as_string(m);
                if (known_tags[mtag])
                    push(valid_members, mtag);
                else if (mtag != "")
                    push(missing_members, mtag);
            }
            if (length(missing_members) > 0) {
                if (length(valid_members) == 0) {
                    let first_missing = missing_members[0];
                    return "outbounds[" + i + "]: dependency[" + first_missing + "] not found for outbound[" + otag + "]: missing outbound tag: " + first_missing;
                }
                outb.outbounds = valid_members;
                if (outb.default != null && !known_tags[as_string(outb.default)])
                    outb.default = valid_members[0];
                modified = true;
            }
        }
    }

    if (modified)
        write_file(temp_config, sprintf("%J", cfg));
    return "";
}

// Runs tachyon-core check and applies the known graceful-degradation repairs
// (stripping fields older builds reject) until either the config passes or
// nothing else can be stripped. Extracted from init_config so the quarantine
// loop can call it once per attempt without re-running the repairs inline.
function check_with_field_repairs(temp_config, runtime_log) {
    ensure_local_rulesets_exist(temp_config);
    let core_name = "tachyon-core";
    let check_result = core_check(temp_config, runtime_log);
    while (check_result.status != 0) {
        // Graceful degradation: if the installed tachyon-core does not support an inbound
        // field that was added for newer versions (e.g. close_timeout for MTProto
        // hot-reload fix, issue #15, prefer_ip, tolerate_time_skewness), strip it
        // from all inbounds and retry. Loops to handle multiple unknown fields
        // across retries (e.g. prefer_ip then tolerate_time_skewness).
        let norm_reason = verifier.normalize_unknown_field_reason(check_result.reason);
        let cert_pin_m = match(check_result.reason, /certificate_sha256/) != null;
        let user_field_m = match(norm_reason, /inbounds\[\d+\]\.users\[\d+\]\.(\w+): json: unknown field/);
        let field_m = match(norm_reason, /inbounds\[\d+\]\.(\w+): json: unknown field/);
        let stripped = false;
        if (cert_pin_m) {
            log_message("Installed " + core_name + " rejected tls.certificate_sha256 (this build predates it); stripping certificate pins and retrying", "warn");
            let cfg_text = as_string(fs.readfile(temp_config) || "");
            let cfg = length(cfg_text) > 0 ? json(cfg_text) : null;
            let found = false;
            if (type(cfg) == "object") {
                for (let list in [ cfg.outbounds, cfg.endpoints ]) {
                    if (type(list) != "array")
                        continue;
                    for (let item in list) {
                        if (type(item) == "object" && type(item.tls) == "object" && item.tls.certificate_sha256 != null) {
                            delete item.tls.certificate_sha256;
                            found = true;
                        }
                    }
                }
            }
            if (found) {
                write_file(temp_config, sprintf("%J", cfg));
                stripped = true;
            }
        }
        else if (user_field_m) {
            let unknown_field = user_field_m[1];
            log_message("Installed " + core_name + " does not support inbound user field '" + unknown_field + "'; retrying without it", "warn");
            let cfg_text = as_string(fs.readfile(temp_config) || "");
            let cfg = length(cfg_text) > 0 ? json(cfg_text) : null;
            if (type(cfg) == "object" && type(cfg.inbounds) == "array") {
                for (let inb in cfg.inbounds) {
                    if (type(inb) == "object" && type(inb.users) == "array") {
                        for (let u in inb.users) {
                            if (type(u) == "object")
                                delete u[unknown_field];
                        }
                    }
                }
                write_file(temp_config, sprintf("%J", cfg));
                stripped = true;
            }
        }
        else if (field_m) {
            let unknown_field = field_m[1];
            log_message("Installed " + core_name + " does not support inbound field '" + unknown_field + "'; retrying without it", "warn");
            let cfg_text = as_string(fs.readfile(temp_config) || "");
            let cfg = length(cfg_text) > 0 ? json(cfg_text) : null;
            if (type(cfg) == "object" && type(cfg.inbounds) == "array") {
                for (let inb in cfg.inbounds) {
                    if (type(inb) == "object")
                        delete inb[unknown_field];
                }
                write_file(temp_config, sprintf("%J", cfg));
                stripped = true;
            }
        }
        else {
            // Nested TLS container fields, e.g. outbounds[N].tls.reality.support_x25519mlkem768.
            // The other patterns above all match a single top-level key, so this
            // class of error used to reach the bottom of the loop with nothing
            // stripped: the check failed, the retry gave up, and one node with an
            // unknown REALITY field took the whole proxy down instead of dropping
            // that node. The dotted path is captured whole and deleted at each
            // level, the same way the endpoints path below already does for
            // `amnezia`.
            let tls_field_m = match(norm_reason, /(outbounds|inbounds)\[\d+\]\.tls\.(\w+)\.(\w+): json: unknown field/);
            if (tls_field_m) {
                let container = tls_field_m[2];
                let unknown_field = tls_field_m[3];
                log_message("Installed " + core_name + " does not support tls." + container + "." + unknown_field + " (added in a later release); dropping it and retrying", "warn");
                let cfg_text = as_string(fs.readfile(temp_config) || "");
                let cfg = length(cfg_text) > 0 ? json(cfg_text) : null;
                if (type(cfg) == "object") {
                    for (let list in [ cfg.outbounds, cfg.inbounds ]) {
                        if (type(list) != "array")
                            continue;
                        for (let item in list) {
                            if (type(item) != "object" || type(item.tls) != "object")
                                continue;
                            if (type(item.tls[container]) == "object")
                                delete item.tls[container][unknown_field];
                        }
                    }
                    write_file(temp_config, sprintf("%J", cfg));
                    stripped = true;
                }
            }
            let ep_field_m = match(norm_reason, /endpoints\[\d+\]\.(\w+): json: unknown field/);
            let out_field_m = match(norm_reason, /outbounds\[(\d+)\]\.(\w+): json: unknown field/);
            if (ep_field_m) {
                let unknown_field = ep_field_m[1];
                log_message("Installed " + core_name + " does not support endpoint field '" + unknown_field + "'; adjusting configuration", "warn");
                let cfg_text = as_string(fs.readfile(temp_config) || "");
                let cfg = length(cfg_text) > 0 ? json(cfg_text) : null;
                if (type(cfg) == "object" && type(cfg.endpoints) == "array") {
                    for (let ep in cfg.endpoints) {
                        if (type(ep) == "object") {
                            if (unknown_field == "amnezia" && type(ep.amnezia) == "object") {
                                for (let k, v in ep.amnezia) {
                                    if (ep[k] == null)
                                        ep[k] = v;
                                }
                            }
                            delete ep[unknown_field];
                        }
                    }
                    write_file(temp_config, sprintf("%J", cfg));
                    stripped = true;
                }
            }
            else if (out_field_m) {
                // tachyon-core names the exact outbound it choked on, so only that one
                // loses the field instead of stripping working fields across all outbounds.
                // The repair runs through components/verifier so apply and pre-flight cannot drift.
                if (repair_outbound_field(temp_config, check_result.reason))
                    stripped = true;
            }
            else if (match(check_result.reason, /experimental\.cache_file\.store_dns/)) {
                log_message("Installed " + core_name + " rejected store_dns: " + check_result.reason + "; switching to store_rdrc and retrying", "warn");
                let cfg_text = as_string(fs.readfile(temp_config) || "");
                let cfg = length(cfg_text) > 0 ? json(cfg_text) : null;
                if (type(cfg) == "object" && type(cfg.experimental) == "object" && type(cfg.experimental.cache_file) == "object") {
                    delete cfg.experimental.cache_file.store_dns;
                    cfg.experimental.cache_file.store_rdrc = true;
                    write_file(temp_config, sprintf("%J", cfg));
                    stripped = true;
                }
            }
            // Later schema revisions answer with a deprecation notice that does not carry the
            // option path, so matching only "experimental.cache_file.store_rdrc" missed
            // it and the whole start died on [fatal] instead of retrying with store_dns.
            else if (match(check_result.reason, /store_rdrc cache file option is deprecated/)) {
                log_message("Installed " + core_name + " rejected store_rdrc: " + check_result.reason + "; switching to store_dns and retrying", "warn");
                let cfg_text = as_string(fs.readfile(temp_config) || "");
                let cfg = length(cfg_text) > 0 ? json(cfg_text) : null;
                if (type(cfg) == "object" && type(cfg.experimental) == "object" && type(cfg.experimental.cache_file) == "object") {
                    delete cfg.experimental.cache_file.store_rdrc;
                    cfg.experimental.cache_file.store_dns = true;
                    write_file(temp_config, sprintf("%J", cfg));
                    stripped = true;
                }
            }
            else if (match(check_result.reason, /experimental\.cache_file\.store_rdrc/)) {
                log_message("Installed " + core_name + " rejected store_rdrc: " + check_result.reason + "; switching to store_dns and retrying", "warn");
                let cfg_text = as_string(fs.readfile(temp_config) || "");
                let cfg = length(cfg_text) > 0 ? json(cfg_text) : null;
                if (type(cfg) == "object" && type(cfg.experimental) == "object" && type(cfg.experimental.cache_file) == "object") {
                    delete cfg.experimental.cache_file.store_rdrc;
                    cfg.experimental.cache_file.store_dns = true;
                    write_file(temp_config, sprintf("%J", cfg));
                    stripped = true;
                }
            }
            else if (match(norm_reason, /experimental\.cache_file\.(\w+): json: unknown field/)) {
                let cf_m = match(norm_reason, /experimental\.cache_file\.(\w+): json: unknown field/);
                let unknown_field = cf_m[1];
                log_message("Installed " + core_name + " does not support cache_file field '" + unknown_field + "'; stripping and retrying", "warn");
                let cfg_text = as_string(fs.readfile(temp_config) || "");
                let cfg = length(cfg_text) > 0 ? json(cfg_text) : null;
                if (type(cfg) == "object" && type(cfg.experimental) == "object" && type(cfg.experimental.cache_file) == "object") {
                    delete cfg.experimental.cache_file[unknown_field];
                    write_file(temp_config, sprintf("%J", cfg));
                    stripped = true;
                }
            }
            else if (match(check_result.reason, /outbounds\[\d+\]\.transport: unknown transport type: (\w+)/)) {
                let tr_m = match(check_result.reason, /outbounds\[\d+\]\.transport: unknown transport type: (\w+)/);
                let bad_transport = tr_m[1];
                let out_idx_m = match(check_result.reason, /outbounds\[(\d+)\]/);
                let out_idx = out_idx_m ? int(out_idx_m[1]) : -1;
                log_message("Installed " + core_name + " does not support transport '" + bad_transport + "' on outbound index " + out_idx + "; stripping outbound and retrying", "warn");
                let cfg_text = as_string(fs.readfile(temp_config) || "");
                let cfg = length(cfg_text) > 0 ? json(cfg_text) : null;
                if (type(cfg) == "object" && type(cfg.outbounds) == "array" && out_idx >= 0 && out_idx < length(cfg.outbounds)) {
                    let bad_tag = cfg.outbounds[out_idx].tag;
                    splice(cfg.outbounds, out_idx, 1);
                    for (let outb in cfg.outbounds) {
                        if (type(outb) == "object" && type(outb.outbounds) == "array") {
                            let filtered = [];
                            for (let tag in outb.outbounds) {
                                if (tag != bad_tag)
                                    push(filtered, tag);
                            }
                            outb.outbounds = filtered;
                        }
                    }
                    write_file(temp_config, sprintf("%J", cfg));
                    shift_owners_outbounds(temp_config, out_idx);
                    stripped = true;
                }
            }
            else if (match(check_result.reason, /experimental\.unified_delay/)) {
                log_message("Installed core rejected experimental.unified_delay; stripping unified_delay and retrying", "warn");
                let cfg_text = as_string(fs.readfile(temp_config) || "");
                let cfg = length(cfg_text) > 0 ? json(cfg_text) : null;
                if (type(cfg) == "object" && type(cfg.experimental) == "object" && cfg.experimental.unified_delay != null) {
                    delete cfg.experimental.unified_delay;
                    write_file(temp_config, sprintf("%J", cfg));
                    stripped = true;
                }
            }
            else if (match(check_result.reason, /certificate is unavailable in reality/)) {
                log_message("Installed " + core_name + " rejected certificate on reality inbound; stripping certificate/key from reality inbounds and retrying", "warn");
                let cfg_text = as_string(fs.readfile(temp_config) || "");
                let cfg = length(cfg_text) > 0 ? json(cfg_text) : null;
                let found = false;
                if (type(cfg) == "object" && type(cfg.inbounds) == "array") {
                    for (let inb in cfg.inbounds) {
                        if (type(inb) == "object" && type(inb.tls) == "object" &&
                            type(inb.tls.reality) == "object" && inb.tls.reality.enabled == true) {
                            for (let k in [ "certificate", "certificate_path", "key", "key_path" ]) {
                                if (inb.tls[k] != null) {
                                    delete inb.tls[k];
                                    found = true;
                                }
                            }
                        }
                    }
                }
                if (found) {
                    write_file(temp_config, sprintf("%J", cfg));
                    stripped = true;
                }
            }
            else if (match(check_result.reason, /rule[-_]set\[(\d+)\]: .*(invalid .*rule-set file|unexpected EOF)/)) {
                let rs_m = match(check_result.reason, /rule[-_]set\[(\d+)\]/);
                let rs_idx = rs_m ? int(rs_m[1]) : -1;
                let cfg_text = as_string(fs.readfile(temp_config) || "");
                let cfg = length(cfg_text) > 0 ? json(cfg_text) : null;
                if (type(cfg) == "object" && type(cfg.route) == "object" && type(cfg.route.rule_set) == "array" &&
                    rs_idx >= 0 && rs_idx < length(cfg.route.rule_set)) {
                    let rs_entry = cfg.route.rule_set[rs_idx];
                    if (type(rs_entry) == "object" && rs_entry.type == "local" && as_string(rs_entry.path || "") != "") {
                        let bad_path = as_string(rs_entry.path);
                        log_message("Installed " + core_name +
                            " rejected local rule-set at index " + rs_idx + " (" + bad_path + "); removing broken rule-set and retrying", "warn");
                        remove_file(bad_path);
                        let fallback_trs = replace(bad_path, /\.trs$/, ".empty.json");
                        if (fallback_trs != bad_path) {
                            let etc_bad_trs = replace(bad_path, /^.*\/(community-[^\/]+\.trs)$/, "/etc/tachyon/rulesets/$1");
                            if (index(etc_bad_trs, "/etc/tachyon/rulesets/") == 0)
                                remove_file(etc_bad_trs);
                            write_file(fallback_trs, "{\"version\":1,\"rules\":[]}");
                            rs_entry.path = fallback_trs;
                            rs_entry.format = "source";
                        } else {
                            let srs_st = fs.stat(rs_entry.path);
                            if (!srs_st || srs_st.size < 17)
                                fs.writefile(rs_entry.path, EMPTY_SRS_BINARY);
                        }
                        write_file(temp_config, sprintf("%J", cfg));
                        stripped = true;
                    }
                }
            }
            else if (match(check_result.reason, /dns\.rules\[\d+\]\.answer|bad owner name/)) {
                let cfg_text = as_string(fs.readfile(temp_config) || "");
                let cfg = length(cfg_text) > 0 ? json(cfg_text) : null;
                if (type(cfg) == "object" && type(cfg.dns) == "object" && type(cfg.dns.rules) == "array") {
                    let fixed_owner = false;
                    let stripped_ans = false;
                    for (let r in cfg.dns.rules) {
                        if (type(r) != "object" || type(r.answer) != "array")
                            continue;
                        let new_ans = [];
                        for (let item in r.answer) {
                            if (type(item) == "string" && substr(item, 0, 2) == "* ") {
                                push(new_ans, "*." + substr(item, 1));
                                fixed_owner = true;
                            } else if (type(item) == "object" && item.value != null) {
                                let owner = trim(as_string(item.name || "*"));
                                if (substr(owner, length(owner) - 1, 1) != ".")
                                    owner = owner + ".";
                                let ttl_s = as_string(item.ttl != null ? item.ttl : 60);
                                let rr_t = index(as_string(item.value), ":") >= 0 ? "AAAA" : "A";
                                push(new_ans, owner + " " + ttl_s + " IN " + rr_t + " " + as_string(item.value));
                                fixed_owner = true;
                            } else {
                                push(new_ans, item);
                            }
                        }
                        if (fixed_owner)
                            r.answer = new_ans;
                    }
                    if (!fixed_owner) {
                        for (let r in cfg.dns.rules) {
                            if (type(r) == "object" && r.action == "predefined" && r.answer != null) {
                                delete r.answer;
                                if (r.rcode == null)
                                    r.rcode = "NOERROR";
                                stripped_ans = true;
                            }
                        }
                    }
                    if (fixed_owner || stripped_ans) {
                        log_message("Installed " + core_name + " rejected DNS predefined answer (" + check_result.reason + "); repaired and retrying", "warn");
                        write_file(temp_config, sprintf("%J", cfg));
                        stripped = true;
                    }
                }
            }
            else if (match(norm_reason, /json: unknown field/)) {
                if (repair_outbound_field(temp_config, norm_reason))
                    stripped = true;
            }
            else if (strip_broken_leaf_outbound(temp_config, check_result.reason)) {
                stripped = true;
            }
        }
        if (!stripped)
            break;
        check_result = core_check(temp_config, runtime_log);
    }
    return check_result;
}

function is_global_quarantine_key(name) {
    return substr(as_string(name || ""), 0, 1) == "_";
}

function build_safe_minimal_config(settings, listen_addr) {
    settings = object_or_empty(settings);
    let proxy_mode = lc(trim(option(settings, "proxy_mode", "tproxy")));
    let host = trim(as_string(listen_addr || "")) || "127.0.0.1";
    let clash_controller = index(host, ":") >= 0 ? ("[" + host + "]:9090") : (host + ":9090");

    let primary_inbound = proxy_mode == "tun"
        ? {
            type: "tun",
            tag: "tun-in",
            interface_name: trim(option(settings, "tun_interface", "tun0")) || "tun0",
            address: [ "172.19.0.1/30" ],
            mtu: 1400,
            auto_route: true,
            strict_route: true,
            stack: "system"
        }
        : {
            type: "tproxy",
            tag: "tproxy-in",
            listen: "::",
            listen_port: 1602,
            tcp_fast_open: true,
            udp_fragment: true
        };

    return {
        log: {
            level: "warn",
            timestamp: true
        },
        dns: {
            servers: [
                {
                    type: "udp",
                    tag: "bootstrap-dns-server",
                    server: "77.88.8.8",
                    server_port: 53,
                    detour: "direct-out"
                },
                {
                    type: "udp",
                    tag: "dns-fallback-1",
                    server: "1.1.1.1",
                    server_port: 53,
                    detour: "direct-out"
                },
                {
                    type: "group",
                    tag: "dns-resilient",
                    mode: "stable",
                    error_ttl: "30s",
                    timeout: "4s",
                    servers: [ "dns-fallback-1", "bootstrap-dns-server" ]
                }
            ],
            rules: [],
            "final": "dns-resilient",
            strategy: "prefer_ipv4",
            reverse_mapping: true
        },
        endpoints: [],
        inbounds: [
            primary_inbound,
            {
                type: "direct",
                tag: "dns-in",
                listen: "127.0.0.42",
                listen_port: 53
            }
        ],
        outbounds: [
            { type: "direct", tag: "direct-out" },
            { type: "block", tag: "block-out" }
        ],
        route: {
            rules: [
                { action: "sniff" },
                { inbound: [ "dns-in" ], action: "hijack-dns" }
            ],
            rule_set: [],
            "final": "direct-out",
            auto_detect_interface: true,
            default_mark: 1073741824,
            default_domain_resolver: "dns-resilient"
        },
        experimental: {
            clash_api: {
                external_controller: clash_controller
            }
        }
    };
}

function init_config(populate_nft, caches_prepared, no_refresh) {
    let settings = uci_settings();
    let core_name = "tachyon-core";
    let config_path = option(settings, "config_path", "");
    if (config_path == "") {
        log_message(core_name + " config path is empty. Aborted.", "fatal");
        exit(1);
    }

    // Cleanup stale temp config files from previous failed runs
    try {
        let now_sec = int(clock()[0]);
        let entries = fs.lsdir("/tmp");
        if (type(entries) == "array") {
            for (let name in entries) {
                if (!wildcard(as_string(name), "config.json.*.tmp.*"))
                    continue;
                let path = "/tmp/" + name;
                let st = fs.stat(path);
                if (st != null && st.type == "file" && (now_sec - int(st.mtime || 0)) > 300)
                    remove_file(path);
            }
        }
    }
    catch (e) {
        // Housekeeping for temp files left by earlier failed runs. Failing here
        // leaves a few stale files in /tmp and must not stop the start.
    }

    let mwan3_active = module_success([ LIB_DIR + "/config/validator.uc", "mwan3-is-active" ]);
    let output_interface = option(settings, "output_network_interface", "");
    if (mwan3_active && output_interface != "")
        log_message("mwan3 is active and Output Network Interface is set to '" + output_interface + "'; " + core_name + " egress is pinned to this interface", "warn");
    else if (mwan3_active)
        log_message("mwan3 is active; disabling " + core_name + " auto_detect_interface so mwan3 can control egress routing", "warn");

    let deferred_sections = prepare_subscription_caches(caches_prepared, no_refresh);
    if (deferred_sections == null)
        exit(1);

    let temp_config = temp_path();
    let runtime_log = temp_path();
    if (temp_config == "" || runtime_log == "") {
        remove_files([ temp_config, runtime_log ]);
        exit(1);
    }

    // Quarantine loop: each iteration either yields a config tachyon-core accepts
    // or isolates one more section that both the generator and tachyon-core check
    // could attribute by name. 16 bounds the loop for pathological cases; in
    // practice every pass quarantines at least one section or breaks out.
    let quarantined = {};
    let pre_quarantined = common.read_json_file(VALIDATOR_QUARANTINED_FILE);
    if (type(pre_quarantined) == "object") {
        for (let qname in keys(pre_quarantined)) {
            if (section_exists(qname) || is_global_quarantine_key(qname))
                quarantined[qname] = as_string(pre_quarantined[qname]);
        }
    }
    let safe_dns_fallback = (quarantined["_dns"] != null);
    let last_failure_reason = "";
    let gen_quarantined_file = temp_config + ".quarantined.json";
    let check_result = { status: 1, reason: "configuration was not generated" };
    for (let attempt = 0; attempt < 16; attempt++) {
        remove_file(gen_quarantined_file);
        let generate_status = command_status(
            command_env({
                TACHYON_GENERATOR_QUARANTINE_OUT: gen_quarantined_file,
                TACHYON_SAFE_DNS_FALLBACK: safe_dns_fallback ? "1" : "0"
            }) + " " +
            module_command([
                LIB_DIR + "/tachyon_core/generator.uc",
                "generate-config",
                temp_config,
                service_listen_address_value(settings),
                mwan3_active ? "1" : "0",
                core_supports_xhttp(core_version()) ? "1" : "0",
                deferred_sections,
                join(",", keys(quarantined))
            ]) + " >" + shell_quote(runtime_log) + " 2>&1"
        );
        let in_proc_entries = common.read_json_file(gen_quarantined_file);
        remove_file(gen_quarantined_file);
        if (type(in_proc_entries) == "array") {
            for (let entry in in_proc_entries) {
                if (type(entry) != "object")
                    continue;
                let qsec = as_string(entry.section || "");
                let qreason = as_string(entry.reason || "");
                if (qsec != "" && quarantined[qsec] == null && section_exists(qsec)) {
                    let expanded_gen_reason = expand_check_error_reason(qreason);
                    log_message("Section '" + qsec + "' failed to generate: " + expanded_gen_reason +
                        ". Not loading it; the rest of the configuration starts normally", "warn");
                    quarantined[qsec] = expanded_gen_reason;
                }
            }
        }
        if (generate_status != 0) {
            let reason = generator_failure_reason(runtime_log, generate_status);
            let section = section_from_generator_log(runtime_log);
            if (section != "" && quarantined[section] == null && section_exists(section)) {
                let expanded_gen_reason = expand_check_error_reason(reason);
                log_message("Section '" + section + "' failed to generate: " + expanded_gen_reason +
                    ". Not loading it; the rest of the configuration starts normally", "warn");
                quarantined[section] = expanded_gen_reason;
                continue;
            }
            last_failure_reason = reason;
            log_file_lines(runtime_log, "debug", core_name + " config generator output: ");
            break;
        }
        log_file_lines(runtime_log, "warn", core_name + " config generator: ");

        let dangling_reason = repair_or_find_dangling_outbound_dependency(temp_config);
        if (dangling_reason != "") {
            let dep_section = section_from_check_reason(dangling_reason, temp_config);
            if (dep_section != "" && quarantined[dep_section] == null && section_exists(dep_section)) {
                let expanded_dep_reason = expand_check_error_reason(dangling_reason);
                log_message("Section '" + dep_section + "' depends on a quarantined or missing outbound (" + expanded_dep_reason +
                    "). Not loading it; the rest of the configuration starts normally", "warn");
                quarantined[dep_section] = expanded_dep_reason;
                continue;
            }
        }

        check_result = check_with_field_repairs(temp_config, runtime_log);
        if (check_result.status == 0)
            break;

        // Say which of the two it was before blaming the configuration.
        let bin_problem = core_binary_problem(core_binary_path());
        if (bin_problem == "" && core_check_blamed_the_binary(check_result.reason))
            bin_problem = core_name + " could not be run: " + check_result.reason;
        if (bin_problem != "") {
            log_message("Cannot verify the generated configuration: " + bin_problem +
                ". This is not a configuration problem. The raw output was: " + check_result.reason, "fatal");
            remove_files([ temp_config, temp_config + ".owners.json", runtime_log ]);
            exit(1);
        }

        last_failure_reason = check_result.reason;
        if (!safe_dns_fallback && match(lc(check_result.reason), /(config: dns|dns\.|dns-server|dns-resilient|bootstrap-dns)/) != null) {
            safe_dns_fallback = true;
            let expanded_dns_reason = expand_check_error_reason(check_result.reason);
            quarantined["_dns"] = expanded_dns_reason;
            log_message(core_name + " rejected DNS configuration (" + expanded_dns_reason +
                "). Switching to resilient UDP DNS fallback so core startup continues", "warn");
            continue;
        }

        let section = section_from_check_reason(check_result.reason, temp_config);
        if (section == "" || quarantined[section] != null)
            break;
        let expanded_check_reason = expand_check_error_reason(check_result.reason);
        log_message(core_name + " rejected the configuration at section '" + section + "' (" + expanded_check_reason +
            "). Not loading it; the rest of the configuration starts normally", "warn");
        quarantined[section] = expanded_check_reason;
    }
    if (check_result.status != 0) {
        let minimal_cfg = build_safe_minimal_config(settings, service_listen_address_value(settings));
        if (write_file(temp_config, sprintf("%J", minimal_cfg))) {
            check_result = core_check(temp_config, runtime_log);
            if (check_result.status == 0) {
                let expanded_min_reason = expand_check_error_reason(last_failure_reason != "" ? last_failure_reason : "configuration check failed");
                quarantined["_core_runtime"] = expanded_min_reason + " — Запущен безопасный минимальный режим (DNS + direct), чтобы сохранить сеть.";
                log_message(core_name + " started in safe minimal mode (DNS + direct) because full configuration failed: " + expanded_min_reason, "warn");
            }
        }
    }
    write_section_errors(quarantined);
    remove_file(temp_config + ".owners.json");
    if (check_result.status != 0) {
        log_message("Generated tachyon-core configuration is invalid: " + check_result.reason + ". Aborted.", "fatal");
        remove_files([ temp_config, runtime_log ]);
        exit(1);
    }

    let nft_deferred_sections = deferred_sections;
    for (let qname in keys(quarantined)) {
        if (!is_global_quarantine_key(qname))
            nft_deferred_sections = nft_deferred_sections != "" ? (nft_deferred_sections + " " + qname) : qname;
    }

    if (populate_nft && !module_success([
        LIB_DIR + "/nft/apply.uc",
        "nft-populate-runtime-sets-from-uci",
        "1",
        nft_deferred_sections,
        NFT_TABLE_NAME,
        NFT_COMMON_SET_NAME,
        NFT_PORT_SET_NAME,
        NFT_IP_PORT_SET_NAME,
        NFT_INTERFACE_SET_NAME,
        NFT_LOCALV4_SET_NAME,
        NFT_FAKEIP_MARK,
        NFT_COMMON6_SET_NAME,
        NFT_IP_PORT6_SET_NAME,
        NFT_LOCALV6_SET_NAME
    ])) {
        log_message("Failed to update nftables runtime sets from the generated " + core_name + " configuration. Aborted.", "fatal");
        remove_files([ temp_config, runtime_log ]);
        exit(1);
    }

    if (!save_config_file(temp_config, config_path)) {
        remove_file(runtime_log);
        exit(1);
    }
    remove_file(runtime_log);
    print(deferred_sections, "\n");
}

let mode = ARGV[0] || "";

if (mode == "configure-service")
    configure_service();
else if (mode == "init-config")
    init_config(arg_bool(ARGV[1] || "1"), arg_bool(ARGV[2] || "0"), arg_bool(ARGV[3] || "0"));
else if (mode == "save-config-file-fixture")
    exit(save_config_file(ARGV[1] || "", ARGV[2] || "") ? 0 : 1);
else if (mode == "check-config-fixture") {
    let result = core_check(ARGV[1] || "", ARGV[2] || "");
    if (result.reason != "")
        print(result.reason, "\n");
    exit(result.status);
}
else if (mode == "safe-minimal-config-fixture") {
    print(sprintf("%J\n", build_safe_minimal_config({}, ARGV[1] || "127.0.0.1")));
    exit(0);
}
else if (mode == "ensure-local-rulesets-fixture") {
    ensure_local_rulesets_exist(ARGV[1] || "");
    exit(0);
}
else if (mode == "quarantine-attribution-fixture")
    print(section_from_check_reason(ARGV[1] || "", ARGV[2] || ""), "\n");
else if (mode == "quarantine-marker-fixture")
    print(section_from_generator_log(ARGV[1] || ""), "\n");
else if (mode == "generator-failure-reason-fixture")
    print(generator_failure_reason(ARGV[1] || "", int(ARGV[2] || "1")), "\n");
else if (mode == "outbound-repair-fixture") {
    printf("%s\n", repair_outbound_field(ARGV[1] || "", ARGV[2] || "") ? "repaired" : "not-repaired");
}
else if (mode == "strip-leaf-outbound-fixture") {
    printf("%s\n", strip_broken_leaf_outbound(ARGV[1] || "", ARGV[2] || "") ? "stripped" : "not-stripped");
}
else if (mode == "dangling-dependency-fixture") {
    printf("%s\n", repair_or_find_dangling_outbound_dependency(ARGV[1] || ""));
}
else if (mode == "expand-check-reason-fixture") {
    printf("%s\n", expand_check_error_reason(ARGV[1] || ""));
}
else if (mode == "patch-dns-config")
    patch_dns_config(ARGV[1] || "");
else if (mode == "restore-dns-config")
    exit(restore_dns_config(ARGV[1] || "") ? 0 : 1);
else if (mode == "managed-service-installed")
    exit(managed_service_installed() ? 0 : 1);
else if (mode == "remove-managed-service-script")
    remove_managed_service_script();
else if (mode == "prepare-service-disabled")
    prepare_service_disabled();
else if (mode == "service-proxy-address")
    print(service_proxy_address(uci_settings(), ARGV[1] || "lists"), "\n");
else if (mode == "service-listen-address") {
    let address = service_listen_address_value(uci_settings());
    if (address == "")
        exit(1);
    print(address, "\n");
}
else if (mode == "device-ipv4-address") {
    let address = device_ipv4_address_value(ARGV[1]);
    if (address == "")
        exit(1);
    print(address, "\n");
}
else if (mode == "ip-addr-first-inet4")
    print(ip_addr_first_inet4(fs.readfile("/dev/stdin")), "\n");
else if (mode == "version")
    print(core_version(), "\n");
else if (mode == "version-output")
    print(core_version_output());
else if (mode == "version-from-output")
    print(parse_core_version(fs.readfile("/dev/stdin")), "\n");
else if (mode == "read-version-state")
    print(core_version_state(), "\n");
else if (mode == "write-version-state")
    exit(core_write_version_state(ARGV[1]) ? 0 : 1);
else if (mode == "clear-version-state")
    exit(core_clear_version_state() ? 0 : 1);
else if (mode == "restore-version-state")
    exit(core_restore_version_state(ARGV[1]) ? 0 : 1);
else if (mode == "supports-xhttp")
    exit(core_supports_xhttp(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "supports-tailscale")
    exit(core_supports_tailscale(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "supports-cert-pin")
    exit(core_supports_cert_pin(ARGV[1]) ? 0 : 1);
else if (mode == "core-profile")
    print(core_profile_name(ARGV[1], ARGV[2]), "\n");
else if (mode == "core-pin-field") {
    let field = core_pin_field(ARGV[1], ARGV[2]);
    print(field, "\n");
    exit(field != "" ? 0 : 1);
}
else if (mode == "core-has-1-14")
    exit(core_has_1_14(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "core-has-1-15")
    exit(core_has_1_15(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "core-protocols")
    print(sprintf("%J\n", core_protocols(ARGV[1], ARGV[2])));
else if (mode == "core-supports-protocol")
    exit(core_supports_protocol(ARGV[1], ARGV[2], ARGV[3]) ? 0 : 1);
else if (mode == "core-inbounds")
    print(sprintf("%J\n", core_profile.inbounds(core_resolve(ARGV[1], ARGV[2]).version, core_resolve(ARGV[1], ARGV[2]).marker)));
else if (mode == "core-supports-inbound")
    exit(core_profile.supports_inbound(ARGV[1], core_resolve(ARGV[2], ARGV[3]).version, core_resolve(ARGV[2], ARGV[3]).marker) ? 0 : 1);
else if (mode == "core-capabilities")
    print(sprintf("%J\n", core_capabilities(ARGV[1], ARGV[2], ARGV[3])));
else {
    warn("Usage: tachyon_core/runtime.uc <operation> ...\n");
    exit(1);
}
