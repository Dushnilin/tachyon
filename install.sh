#!/bin/sh
# shellcheck shell=dash

REPO_OWNER="ushan0v"
REPO_NAME="podkop-plus"

REQUIRED_SPACE_KB=15360

PKG_IS_APK=0
FETCHER=""
TMP_DIR=""
PODKOP_WAS_ENABLED=0
PODKOP_WAS_RUNNING=0
PODKOP_PLUS_I18N_REQUESTED=0
INSTALLER_LANG="en"
SING_BOX_INSTALL_VARIANT=""

PODKOP_PLUS_RELEASE_JSON=""
PODKOP_PLUS_RELEASE_TAG=""
PODKOP_PLUS_BACKEND_URL=""
PODKOP_PLUS_BACKEND_NAME=""
PODKOP_PLUS_BACKEND_FILE=""
PODKOP_PLUS_APP_URL=""
PODKOP_PLUS_APP_NAME=""
PODKOP_PLUS_APP_FILE=""
PODKOP_PLUS_I18N_URL=""
PODKOP_PLUS_I18N_NAME=""
PODKOP_PLUS_I18N_FILE=""
PODKOP_PLUS_PACKAGE_VERSION=""
SING_BOX_VARIANT_STATE_FILE="/etc/podkop-plus/sing-box-variant"
SING_BOX_VERSION_STATE_FILE="/etc/podkop-plus/sing-box-version"

command -v apk >/dev/null 2>&1 && PKG_IS_APK=1

msg() {
    printf '\033[32;1m%s\033[0m\n' "$1"
}

warn() {
    printf '\033[33;1m%s\033[0m\n' "$1"
}

fail() {
    printf '\033[31;1m%s\033[0m\n' "$1" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: $0

Installs or updates Podkop Plus packages:
  - podkop-plus
  - luci-app-podkop-plus
  - luci-i18n-podkop-plus-ru when requested or when LuCI language is Russian

Can also install or switch sing-box variant:
  - stable/full sing-box from OpenWrt feeds
  - sing-box-tiny from OpenWrt feeds
  - sing-box-extended from GitHub OpenWrt packages
  - sing-box-extended compressed from GitHub binary archives
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            *)
                fail "Unknown installer option: $1"
                ;;
        esac
        shift
    done
}

cleanup() {
    [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"
}

read_openwrt_release_value() {
    key="$1"

    [ -f /etc/openwrt_release ] || return 0
    sed -n "s/^${key}='\(.*\)'/\1/p" /etc/openwrt_release 2>/dev/null | head -n 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

init_tmp_dir() {
    TMP_DIR="$(mktemp -d /tmp/podkop-plus.XXXXXX 2>/dev/null || true)"

    if [ -z "$TMP_DIR" ]; then
        TMP_DIR="/tmp/podkop-plus.$$"
        mkdir -p "$TMP_DIR" || fail "Failed to create temporary directory: $TMP_DIR"
    fi
}

detect_fetcher() {
    if command_exists wget; then
        FETCHER="wget"
        return 0
    fi

    if command_exists curl; then
        FETCHER="curl"
        return 0
    fi

    fail "wget or curl is required to download Podkop Plus"
}

http_get() {
    case "$FETCHER" in
        wget)
            wget -qO- "$1"
            ;;
        curl)
            curl -fsSL "$1"
            ;;
        *)
            return 1
            ;;
    esac
}

install_json_helper_path() {
    helper_path="$TMP_DIR/install-json.uc"

    if [ ! -s "$helper_path" ]; then
        cat > "$helper_path" <<'EOF'
#!/usr/bin/env ucode

let fs = require("fs");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function read_stdin() {
    let input = fs.open("/dev/stdin", "r");
    if (!input)
        return "";
    let data = input.read("all");
    input.close();
    return data == null ? "" : data;
}

function read_stdin_json() {
    try {
        return json(read_stdin());
    }
    catch (e) {
        return null;
    }
}

function starts_with(value, prefix) {
    value = as_string(value);
    prefix = as_string(prefix);
    return substr(value, 0, length(prefix)) == prefix;
}

function ends_with(value, suffix) {
    value = as_string(value);
    suffix = as_string(suffix);
    return length(value) >= length(suffix) && substr(value, length(value) - length(suffix)) == suffix;
}

let uci_cursor_state = false;

function words(value) {
    value = trim(as_string(value));
    return value == "" ? [] : split(value, /[ \t\r\n]+/);
}

function truthy(value) {
    value = lc(as_string(value));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function path_parts(path) {
    path = as_string(path);
    let first = index(path, ".");
    if (first < 0)
        return null;

    let package_name = substr(path, 0, first);
    let rest = substr(path, first + 1);
    let second = index(rest, ".");
    if (second < 0)
        return { package: package_name, section: rest, option: "" };

    return {
        package: package_name,
        section: substr(rest, 0, second),
        option: substr(rest, second + 1)
    };
}

function uci_cursor() {
    if (uci_cursor_state !== false)
        return uci_cursor_state;

    try {
        uci_cursor_state = require("uci").cursor();
    }
    catch (e) {
        uci_cursor_state = null;
    }

    return uci_cursor_state;
}

function uci_available() {
    return uci_cursor() != null;
}

function uci_load(package_name) {
    let c = uci_cursor();
    if (c == null)
        return false;

    try {
        c.load(as_string(package_name));
        return true;
    }
    catch (e) {
        return false;
    }
}

function uci_value_to_string(value) {
    if (value == null)
        return "";
    if (type(value) == "array")
        return join(" ", value);
    return as_string(value);
}

function uci_value_to_list(value) {
    if (value == null)
        return [];
    if (type(value) == "array")
        return value;
    return words(value);
}

function uci_get(path) {
    let parts = path_parts(path);
    let c = uci_cursor();
    if (c == null || parts == null || parts.option == "")
        return "";
    if (!uci_load(parts.package))
        return "";

    return uci_value_to_string(c.get(parts.package, parts.section, parts.option));
}

function uci_exists(path) {
    let parts = path_parts(path);
    let c = uci_cursor();
    if (c == null || parts == null)
        return false;
    if (!uci_load(parts.package))
        return false;

    if (parts.option == "")
        return c.get_all(parts.package, parts.section) != null;
    return c.get(parts.package, parts.section, parts.option) != null;
}

function uci_delete(path) {
    let parts = path_parts(path);
    let c = uci_cursor();
    if (c == null || parts == null)
        return false;

    try {
        if (parts.option == "")
            c.delete(parts.package, parts.section);
        else
            c.delete(parts.package, parts.section, parts.option);
        return true;
    }
    catch (e) {
        return false;
    }
}

function uci_set(path, value) {
    let parts = path_parts(path);
    let c = uci_cursor();
    if (c == null || parts == null || parts.option == "")
        return false;

    try {
        c.set(parts.package, parts.section, parts.option, type(value) == "array" ? value : as_string(value));
        return true;
    }
    catch (e) {
        return false;
    }
}

function uci_add_list(path, value) {
    let parts = path_parts(path);
    let c = uci_cursor();
    if (c == null || parts == null || parts.option == "")
        return false;

    try {
        let values = uci_value_to_list(c.get(parts.package, parts.section, parts.option));
        push(values, as_string(value));
        c.set(parts.package, parts.section, parts.option, values);
        return true;
    }
    catch (e) {
        return false;
    }
}

function uci_del_list(path, value) {
    let parts = path_parts(path);
    let c = uci_cursor();
    if (c == null || parts == null || parts.option == "")
        return false;

    let values = [];
    let removed = false;
    for (let item in uci_value_to_list(c.get(parts.package, parts.section, parts.option))) {
        if (item == value) {
            removed = true;
            continue;
        }
        push(values, item);
    }

    if (!removed)
        return false;

    try {
        if (length(values) == 0)
            c.delete(parts.package, parts.section, parts.option);
        else
            c.set(parts.package, parts.section, parts.option, values);
        return true;
    }
    catch (e) {
        return false;
    }
}

function uci_commit(package_name) {
    let c = uci_cursor();
    if (c == null)
        return false;

    try {
        return c.commit(package_name) != false;
    }
    catch (e) {
        return false;
    }
}

function run(command) {
    return system(command) == 0;
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_quote(arg));
    return join(" ", parts);
}

function normalize_status(status) {
    status = int(status);
    return status > 255 ? int(status / 256) : status;
}

function run_args(args) {
    return normalize_status(system(command_from_args(args) + " >/dev/null 2>&1")) == 0;
}

function command_output(args) {
    let pipe = fs.popen(command_from_args(args) + " 2>/dev/null", "r");
    if (!pipe)
        return "";

    let data = pipe.read("all");
    pipe.close();
    return data == null ? "" : data;
}

function env(name, fallback) {
    let value = getenv(name);
    if (value == null || value == "")
        return as_string(fallback);
    return as_string(value);
}

const INSTALLER_PODKOP_PLUS_INIT = env("PODKOP_INSTALLER_PODKOP_PLUS_INIT", "/etc/init.d/podkop-plus");
const INSTALLER_ORIGINAL_PODKOP_INIT = env("PODKOP_INSTALLER_ORIGINAL_PODKOP_INIT", "/etc/init.d/podkop");
const INSTALLER_PODKOP_PLUS_BIN = env("PODKOP_INSTALLER_PODKOP_PLUS_BIN", "/usr/bin/podkop-plus");
const INSTALLER_PODKOP_PLUS_LIB = env("PODKOP_INSTALLER_PODKOP_PLUS_LIB", "/usr/lib/podkop-plus");
const INSTALLER_PODKOP_PLUS_UCI_DEFAULTS = env("PODKOP_INSTALLER_PODKOP_PLUS_UCI_DEFAULTS", "/etc/uci-defaults/50_luci-podkop-plus");
const INSTALLER_PODKOP_PLUS_LUCI_VIEW = env("PODKOP_INSTALLER_PODKOP_PLUS_LUCI_VIEW", "/www/luci-static/resources/view/podkop_plus");
const INSTALLER_MENU_JSON = env("PODKOP_INSTALLER_MENU_JSON", "/usr/share/luci/menu.d/luci-app-podkop-plus.json");
const INSTALLER_ACL_JSON = env("PODKOP_INSTALLER_ACL_JSON", "/usr/share/rpcd/acl.d/luci-app-podkop-plus.json");
const INSTALLER_RU_LMO = env("PODKOP_INSTALLER_RU_LMO", "/usr/lib/lua/luci/i18n/podkop_plus.ru.lmo");
const INSTALLER_EN_LMO = env("PODKOP_INSTALLER_EN_LMO", "/usr/lib/lua/luci/i18n/podkop_plus.en.lmo");
const INSTALLER_RU_LUA = env("PODKOP_INSTALLER_RU_LUA", "/usr/lib/lua/luci/i18n/podkop_plus.ru.lua");
const INSTALLER_EN_LUA = env("PODKOP_INSTALLER_EN_LUA", "/usr/lib/lua/luci/i18n/podkop_plus.en.lua");
const INSTALLER_RPCD_INIT = env("PODKOP_INSTALLER_RPCD_INIT", "/etc/init.d/rpcd");

function path_exists(path) {
    return fs.stat(as_string(path)) != null;
}

function path_executable(path) {
    return run_args([ "test", "-x", path ]);
}

function remove_path(path) {
    if (as_string(path) == "" || !path_exists(path))
        return true;
    return run_args([ "rm", "-rf", path ]);
}

function remove_glob(pattern) {
    pattern = as_string(pattern);
    if (pattern == "")
        return;
    for (let path in fs.glob(pattern))
        remove_path(path);
}

function remove_globs(patterns) {
    for (let pattern in words(patterns))
        remove_glob(pattern);
}

function restart_dnsmasq() {
    return run("[ -x /etc/init.d/dnsmasq ] && /etc/init.d/dnsmasq restart");
}

function installer_package_manager() {
    return run_args([ "apk", "--version" ]) ? "apk" : "opkg";
}

function installer_installed_package_names() {
    let manager = installer_package_manager();
    let output = manager == "apk" ?
        command_output([ "apk", "info" ]) :
        command_output([ "opkg", "list-installed" ]);
    let names = [];

    for (let line in split(output, "\n")) {
        line = trim(as_string(line));
        if (line == "")
            continue;
        if (manager == "opkg") {
            let parts = split(line, /[ \t]+/);
            line = parts[0] || "";
        }
        if (line != "")
            push(names, line);
    }

    return names;
}

function installer_package_installed(name) {
    name = as_string(name);
    if (name == "")
        return false;

    if (installer_package_manager() == "apk")
        return run_args([ "apk", "info", "-e", name ]);

    for (let installed in installer_installed_package_names())
        if (installed == name)
            return true;
    return false;
}

function installer_remove_package(name) {
    name = as_string(name);
    if (name == "" || !installer_package_installed(name))
        return true;

    if (installer_package_manager() == "apk")
        run_args([ "apk", "del", name ]);
    else
        run_args([ "opkg", "remove", "--force-depends", name ]);
    return true;
}

function installer_remove_package_prefix(prefix) {
    prefix = as_string(prefix);
    if (prefix == "")
        return true;

    for (let name in installer_installed_package_names())
        if (starts_with(name, prefix))
            installer_remove_package(name);
    return true;
}

function installer_confirm_remove_https_dns_proxy() {
    if (!installer_package_installed("https-dns-proxy"))
        return true;

    warn("Detected conflicting package: https-dns-proxy\n");

    if (run("[ ! -t 0 ]")) {
        warn("Remove the conflicting https-dns-proxy package and continue?: 1 (yes, non-interactive)\n");
        return true;
    }

    while (true) {
        warn("\nRemove the conflicting https-dns-proxy package and continue?\n");
        warn("  1) yes\n");
        warn("  2) no\n");
        warn("Select [2]: ");

        let input = fs.open("/dev/stdin", "r");
        let answer = input ? trim(as_string(input.read("line"))) : "";
        if (input)
            input.close();

        if (answer == "1")
            return true;
        if (answer == "" || answer == "2")
            return false;
        warn("Invalid choice\n");
    }
}

function installer_service_enabled(init_script) {
    return path_executable(init_script) && run_args([ init_script, "enabled" ]);
}

function installer_service_running(init_script) {
    if (!path_executable(init_script))
        return false;

    if (trim(command_output([ init_script, "status" ])) == "running")
        return true;
    return run_args([ init_script, "running" ]);
}

function installer_podkop_plus_status_running() {
    if (!path_executable(INSTALLER_PODKOP_PLUS_BIN))
        return false;
    return index(command_output([ INSTALLER_PODKOP_PLUS_BIN, "get_status" ]), "\"running\":1") >= 0;
}

function installer_restore_dnsmasq() {
    if (path_executable(INSTALLER_PODKOP_PLUS_BIN) &&
        run_args([ INSTALLER_PODKOP_PLUS_BIN, "restore_dnsmasq" ]))
        return true;

    return dnsmasq_failsafe_restore();
}

function installer_deactivate_original_podkop() {
    if (!path_executable(INSTALLER_ORIGINAL_PODKOP_INIT))
        return;

    if (installer_service_running(INSTALLER_ORIGINAL_PODKOP_INIT)) {
        warn("Detected a running original Podkop service. Stopping it before installing Podkop Plus.\n");
        run_args([ INSTALLER_ORIGINAL_PODKOP_INIT, "stop" ]);
    }

    if (installer_service_enabled(INSTALLER_ORIGINAL_PODKOP_INIT)) {
        warn("Detected an enabled original Podkop autostart. Disabling it before installing Podkop Plus.\n");
        run_args([ INSTALLER_ORIGINAL_PODKOP_INIT, "disable" ]);
    }
}

function installer_cleanup_legacy() {
    let backend_installed = installer_package_installed("podkop-plus");
    let was_enabled = installer_service_enabled(INSTALLER_PODKOP_PLUS_INIT);
    let was_running = installer_service_running(INSTALLER_PODKOP_PLUS_INIT) || installer_podkop_plus_status_running();

    if (!installer_confirm_remove_https_dns_proxy())
        return false;

    installer_deactivate_original_podkop();

    if (path_executable(INSTALLER_PODKOP_PLUS_INIT)) {
        run_args([ INSTALLER_PODKOP_PLUS_INIT, "stop" ]);
        installer_restore_dnsmasq();
        run_args([ INSTALLER_PODKOP_PLUS_INIT, "disable" ]);
    }

    installer_remove_package("luci-app-https-dns-proxy");
    installer_remove_package("https-dns-proxy");
    installer_remove_package_prefix("luci-i18n-https-dns-proxy");
    installer_remove_package_prefix("luci-i18n-podkop-plus");
    installer_remove_package("luci-app-podkop-plus");

    if (!backend_installed) {
        remove_path(INSTALLER_PODKOP_PLUS_LIB);
        remove_path(INSTALLER_PODKOP_PLUS_INIT);
        remove_path(INSTALLER_PODKOP_PLUS_BIN);
    }

    for (let path in [
        INSTALLER_PODKOP_PLUS_LUCI_VIEW,
        INSTALLER_MENU_JSON,
        INSTALLER_ACL_JSON,
        INSTALLER_PODKOP_PLUS_UCI_DEFAULTS,
        INSTALLER_RU_LMO,
        INSTALLER_EN_LMO,
        INSTALLER_RU_LUA,
        INSTALLER_EN_LUA
    ])
        remove_path(path);

    print("PODKOP_WAS_ENABLED=", was_enabled ? "1" : "0", "\n");
    print("PODKOP_WAS_RUNNING=", was_running ? "1" : "0", "\n");
    return true;
}

function installer_post_install() {
    remove_globs(env("PODKOP_INSTALLER_LUCI_CACHE_GLOBS", "/var/luci-indexcache* /tmp/luci-indexcache*"));
    for (let path in [
        env("PODKOP_INSTALLER_LATEST_VERSION_CACHE", "/tmp/podkop-plus.latest-version.cache"),
        env("PODKOP_INSTALLER_SYSTEM_INFO_CACHE", "/var/run/podkop-plus/system-info.json"),
        env("PODKOP_INSTALLER_SERVER_COUNTRY_CACHE", "/var/run/podkop-plus/server-country-cache.json"),
        env("PODKOP_INSTALLER_SING_BOX_VERSION_CACHE", "/var/run/podkop-plus/ui-state/sing-box-version"),
        env("PODKOP_INSTALLER_TMP_SYSTEM_INFO_CACHE", "/tmp/podkop-plus/system-info.json")
    ])
        remove_path(path);

    if (path_executable(INSTALLER_RPCD_INIT))
        run_args([ INSTALLER_RPCD_INIT, "reload" ]);

    if (env("PODKOP_WAS_ENABLED", "0") == "1" && path_executable(INSTALLER_PODKOP_PLUS_INIT))
        run_args([ INSTALLER_PODKOP_PLUS_INIT, "enable" ]);

    if (env("PODKOP_WAS_RUNNING", "0") == "1" && path_executable(INSTALLER_PODKOP_PLUS_INIT)) {
        if (!run_args([ INSTALLER_PODKOP_PLUS_INIT, "start" ]) &&
            !run_args([ INSTALLER_PODKOP_PLUS_INIT, "restart" ]))
            warn("Failed to start Podkop Plus after upgrade.\n");
    }

    return true;
}

function list_has(values, needle) {
    for (let value in words(values))
        if (value == needle)
            return true;
    return false;
}

function dnsmasq_legacy_instance_exists() {
    return uci_exists("dhcp.podkop_plus");
}

function dnsmasq_default_servers() {
    return uci_get("dhcp.@dnsmasq[0].server");
}

function dnsmasq_default_has_podkop_dns() {
    return list_has(dnsmasq_default_servers(), "127.0.0.42");
}

function dnsmasq_has_podkop_dns() {
    return dnsmasq_default_has_podkop_dns() || dnsmasq_legacy_instance_exists();
}

function dnsmasq_has_podkop_managed_state() {
    return uci_get("dhcp.@dnsmasq[0].podkop_server") != "" ||
        uci_get("dhcp.@dnsmasq[0].podkop_noresolv") != "" ||
        uci_get("dhcp.@dnsmasq[0].podkop_cachesize") != "" ||
        uci_get("dhcp.@dnsmasq[0].podkop_notinterface") != "" ||
        dnsmasq_legacy_instance_exists();
}

function dnsmasq_management_disabled() {
    return truthy(uci_get("podkop-plus.settings.dont_touch_dhcp"));
}

function dnsmasq_legacy_interfaces() {
    let legacy_interfaces = uci_get("dhcp.podkop_plus.interface");
    if (legacy_interfaces == "")
        legacy_interfaces = uci_get("podkop-plus.settings.source_network_interfaces");
    if (legacy_interfaces == "")
        legacy_interfaces = "br-lan";

    return legacy_interfaces;
}

function dnsmasq_cleanup_legacy_instance() {
    let legacy_instance_present = dnsmasq_legacy_instance_exists();
    let legacy_interfaces = legacy_instance_present ? dnsmasq_legacy_interfaces() : "";

    uci_delete("dhcp.podkop_plus");

    let backup_notinterfaces = uci_get("dhcp.@dnsmasq[0].podkop_notinterface");
    if (backup_notinterfaces != "") {
        uci_delete("dhcp.@dnsmasq[0].notinterface");
        for (let value in words(backup_notinterfaces))
            uci_add_list("dhcp.@dnsmasq[0].notinterface", value);
        uci_delete("dhcp.@dnsmasq[0].podkop_notinterface");
        return;
    }

    if (legacy_instance_present) {
        for (let value in words(legacy_interfaces))
            uci_del_list("dhcp.@dnsmasq[0].notinterface", value);
    }

    uci_delete("dhcp.@dnsmasq[0].podkop_notinterface");
}

function dnsmasq_restore_default_instance() {
    let server_list = dnsmasq_default_servers();
    let backup_servers = uci_get("dhcp.@dnsmasq[0].podkop_server");
    let managed_global_dns = list_has(server_list, "127.0.0.42");

    uci_delete("dhcp.@dnsmasq[0].server");
    if (backup_servers != "") {
        for (let value in words(backup_servers))
            uci_add_list("dhcp.@dnsmasq[0].server", value);
        uci_delete("dhcp.@dnsmasq[0].podkop_server");
    }
    else {
        for (let value in words(server_list)) {
            if (value != "127.0.0.42")
                uci_add_list("dhcp.@dnsmasq[0].server", value);
        }
    }
    uci_delete("dhcp.@dnsmasq[0].podkop_server");

    let noresolv = uci_get("dhcp.@dnsmasq[0].podkop_noresolv");
    if (noresolv != "") {
        uci_set("dhcp.@dnsmasq[0].noresolv", noresolv);
        uci_delete("dhcp.@dnsmasq[0].podkop_noresolv");
    }
    else if (managed_global_dns) {
        uci_set("dhcp.@dnsmasq[0].noresolv", "0");
    }

    let cachesize = uci_get("dhcp.@dnsmasq[0].podkop_cachesize");
    if (cachesize != "") {
        uci_set("dhcp.@dnsmasq[0].cachesize", cachesize);
        uci_delete("dhcp.@dnsmasq[0].podkop_cachesize");
    }
    else if (managed_global_dns) {
        uci_set("dhcp.@dnsmasq[0].cachesize", "150");
    }
}

function dnsmasq_failsafe_restore() {
    if (!uci_available())
        return true;

    if (dnsmasq_management_disabled() && !dnsmasq_has_podkop_managed_state())
        return true;

    if (!dnsmasq_has_podkop_dns() && !dnsmasq_has_podkop_managed_state())
        return true;

    dnsmasq_cleanup_legacy_instance();
    dnsmasq_restore_default_instance();
    uci_commit("dhcp");
    restart_dnsmasq();
    return true;
}

function asset_matches(name, kind, ext) {
    let suffix = "." + ext;
    if (!ends_with(name, suffix))
        return false;

    if (kind == "backend")
        return starts_with(name, "podkop-plus_") || starts_with(name, "podkop-plus-");
    if (kind == "app")
        return starts_with(name, "luci-app-podkop-plus_") || starts_with(name, "luci-app-podkop-plus-");
    if (kind == "i18n")
        return starts_with(name, "luci-i18n-podkop-plus-ru_") || starts_with(name, "luci-i18n-podkop-plus-ru-");
    return false;
}

function github_message() {
    let value = read_stdin_json();
    if (value == null)
        exit(2);
    if (type(value) == "object" && value.message != null)
        print(as_string(value.message), "\n");
}

function release_tag() {
    let release = read_stdin_json();
    if (type(release) == "object" && release.tag_name != null)
        print(as_string(release.tag_name), "\n");
}

function release_asset_url(kind, ext) {
    let release = read_stdin_json();
    if (type(release) != "object" || type(release.assets) != "array")
        return;
    for (let asset in release.assets) {
        if (type(asset) == "object" && asset_matches(asset.name, kind, ext)) {
            print(as_string(asset.browser_download_url || ""), "\n");
            return;
        }
    }
}

let mode = ARGV[0] || "";

if (mode == "github-message")
    github_message();
else if (mode == "release-tag")
    release_tag();
else if (mode == "release-asset-url")
    release_asset_url(ARGV[1], ARGV[2]);
else if (mode == "uci-get") {
    let value = uci_get(ARGV[1]);
    if (value != "")
        print(value, "\n");
}
else if (mode == "dnsmasq-failsafe-restore")
    exit(dnsmasq_failsafe_restore() ? 0 : 1);
else if (mode == "installer-cleanup-legacy")
    exit(installer_cleanup_legacy() ? 0 : 1);
else if (mode == "installer-post-install")
    exit(installer_post_install() ? 0 : 1);
else
    exit(1);
EOF
    fi

    printf '%s\n' "$helper_path"
}

install_json_ucode() {
    ucode "$(install_json_helper_path)" "$@"
}

download_file_once() {
    case "$FETCHER" in
        wget)
            wget -q -O "$2" "$1"
            ;;
        curl)
            curl -fsSL "$1" -o "$2"
            ;;
        *)
            return 1
            ;;
    esac
}

download_with_retry() {
    url="$1"
    output_path="$2"
    label="$3"
    attempt=1
    max_attempts=3

    while [ "$attempt" -le "$max_attempts" ]; do
        msg "Downloading $label ($attempt/$max_attempts)"

        if download_file_once "$url" "$output_path" && [ -s "$output_path" ]; then
            return 0
        fi

        rm -f "$output_path"
        warn "Retrying $label"
        attempt=$((attempt + 1))
    done

    return 1
}

pkg_is_installed() {
    pkg_name="$1"

    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk info -e "$pkg_name" >/dev/null 2>&1
    else
        opkg list-installed 2>/dev/null | awk -v pkg="$pkg_name" '$1 == pkg { found = 1 } END { exit(found ? 0 : 1) }'
    fi
}

pkg_list_update() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk update </dev/null
    else
        opkg update </dev/null
    fi
}

pkg_install_name() {
    pkg_name="$1"

    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk add "$pkg_name" </dev/null
    else
        opkg install "$pkg_name" </dev/null
    fi
}

pkg_install_files() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk add --allow-untrusted "$@" </dev/null
    else
        opkg install --force-overwrite --force-downgrade "$@" </dev/null
    fi
}

ensure_bootstrap_tool() {
    tool_name="$1"
    package_name="$2"

    if command_exists "$tool_name"; then
        return 0
    fi

    msg "Installing bootstrap dependency: $package_name"
    pkg_install_name "$package_name" || fail "Failed to install $package_name"
}

ensure_bootstrap_package() {
    package_name="$1"

    if pkg_is_installed "$package_name"; then
        return 0
    fi

    msg "Installing bootstrap dependency: $package_name"
    pkg_install_name "$package_name" || fail "Failed to install $package_name"
}

ensure_bootstrap_ucode_runtime() {
    ensure_bootstrap_tool "ucode" "ucode"
    ensure_bootstrap_package "ucode-mod-fs"
    ensure_bootstrap_package "ucode-mod-uci"
}

sync_time() {
    current_year=""

    if ! command_exists ntpd; then
        return 0
    fi

    current_year="$(date +%Y 2>/dev/null || true)"
    case "$current_year" in
        ''|*[!0-9]*) current_year=0 ;;
    esac

    if [ "$current_year" -ge 2024 ]; then
        return 0
    fi

    ntpd -q \
        -p 194.190.168.1 \
        -p 216.239.35.0 \
        -p 216.239.35.4 \
        -p 162.159.200.1 \
        -p 162.159.200.123 >/dev/null 2>&1 || true
}

check_root() {
    if command_exists id && [ "$(id -u)" != "0" ]; then
        fail "Please run this installer as root"
    fi
}

check_system() {
    release=""
    major=""
    model=""
    available_space=""

    [ -f /etc/openwrt_release ] || fail "This installer supports OpenWrt only"

    model="$(cat /tmp/sysinfo/model 2>/dev/null || true)"
    [ -n "$model" ] && msg "Router model: $model"

    release="$(read_openwrt_release_value "DISTRIB_RELEASE")"
    major="$(printf '%s' "$release" | sed 's/[^0-9].*$//' | cut -d. -f1)"

    if [ -n "$major" ] && [ "$major" -lt 24 ]; then
        fail "Podkop Plus requires OpenWrt 24.10 or newer"
    fi

    available_space="$(df /overlay 2>/dev/null | awk 'NR==2 {print $4}')"
    [ -n "$available_space" ] || available_space="$(df / 2>/dev/null | awk 'NR==2 {print $4}')"

    if [ -n "$available_space" ] && [ "$available_space" -lt "$REQUIRED_SPACE_KB" ]; then
        fail "Not enough free flash space. Available: $((available_space / 1024)) MB, required: $((REQUIRED_SPACE_KB / 1024)) MB"
    fi
}

installer_is_ru() {
    [ "$INSTALLER_LANG" = "ru" ]
}

installer_text() {
    key="$1"

    if installer_is_ru; then
        case "$key" in
            yes) printf '%s\n' "Да" ;;
            no) printf '%s\n' "Нет" ;;
            select) printf '%s\n' "Выберите номер" ;;
            invalid_choice) printf '%s\n' "Введите номер из списка." ;;
            i18n_installed) printf '%s\n' "Русский пакет интерфейса уже установлен и будет обновлен." ;;
            i18n_prompt) printf '%s\n' "Установить русский пакет интерфейса?" ;;
            i18n_skip) printf '%s\n' "Продолжаю без русского пакета интерфейса." ;;
            luci_ru) printf '%s\n' "Язык LuCI - русский." ;;
            sing_box_prompt) printf '%s\n' "Какой вариант sing-box установить?" ;;
            sing_box_skip) printf '%s\n' "Не менять sing-box" ;;
            sing_box_stable) printf '%s\n' "Установить обычный sing-box" ;;
            sing_box_tiny) printf '%s\n' "Установить sing-box tiny" ;;
            sing_box_extended) printf '%s\n' "Установить sing-box extended" ;;
            sing_box_extended_compressed) printf '%s\n' "Установить sing-box extended compressed" ;;
            sing_box_skip_msg) printf '%s\n' "Пропускаю установку sing-box." ;;
            *) printf '%s\n' "$key" ;;
        esac
        return 0
    fi

    case "$key" in
        yes) printf '%s\n' "Yes" ;;
        no) printf '%s\n' "No" ;;
        select) printf '%s\n' "Select a number" ;;
        invalid_choice) printf '%s\n' "Enter a number from the list." ;;
        i18n_installed) printf '%s\n' "The Russian interface package is already installed and will be updated." ;;
        i18n_prompt) printf '%s\n' "Install the Russian interface language package?" ;;
        i18n_skip) printf '%s\n' "Continuing without the Russian interface language package." ;;
        luci_ru) printf '%s\n' "LuCI language is Russian." ;;
        sing_box_prompt) printf '%s\n' "Which sing-box variant should be installed?" ;;
        sing_box_skip) printf '%s\n' "Do not change sing-box" ;;
        sing_box_stable) printf '%s\n' "Install stable sing-box" ;;
        sing_box_tiny) printf '%s\n' "Install sing-box tiny" ;;
        sing_box_extended) printf '%s\n' "Install sing-box extended" ;;
        sing_box_extended_compressed) printf '%s\n' "Install sing-box extended compressed" ;;
        sing_box_skip_msg) printf '%s\n' "Skipping sing-box installation." ;;
        *) printf '%s\n' "$key" ;;
    esac
}

detect_installer_language() {
    luci_lang="$(get_luci_main_lang)"

    INSTALLER_LANG="en"
    if pkg_is_installed "luci-i18n-podkop-plus-ru"; then
        INSTALLER_LANG="ru"
        return 0
    fi

    case "$luci_lang" in
        ru|ru_*|ru-*) INSTALLER_LANG="ru" ;;
    esac
}

numbered_yes_no_prompt() {
    prompt_text="$1"
    answer=""

    if [ ! -t 0 ]; then
        msg "$prompt_text: 1 ($(installer_text yes), non-interactive)"
        return 0
    fi

    while :; do
        printf '\n%s\n' "$prompt_text"
        printf '  1) %s\n' "$(installer_text yes)"
        printf '  2) %s\n' "$(installer_text no)"
        printf '%s [2]: ' "$(installer_text select)"
        read -r answer || return 1

        case "$answer" in
            1)
                return 0
                ;;
            2|"")
                return 1
                ;;
            *)
                warn "$(installer_text invalid_choice)"
                ;;
        esac
    done
}

confirm_prompt() {
    prompt_text="$1"
    numbered_yes_no_prompt "$prompt_text"
}

get_luci_main_lang() {
    install_json_ucode uci-get luci.main.lang 2>/dev/null || true
}

extract_package_version() {
    package_name="$1"

    case "$package_name" in
        podkop-plus_*.ipk)
            printf '%s\n' "$package_name" | sed 's/^podkop-plus_//;s/_[^_]*\.ipk$//'
            ;;
        podkop-plus_*.apk)
            printf '%s\n' "$package_name" | sed 's/^podkop-plus_//;s/\.apk$//'
            ;;
        podkop-plus-*.ipk)
            printf '%s\n' "$package_name" | sed 's/^podkop-plus-//;s/-[^-]*\.ipk$//'
            ;;
        podkop-plus-*.apk)
            printf '%s\n' "$package_name" | sed 's/^podkop-plus-//;s/\.apk$//'
            ;;
        luci-app-podkop-plus_*.ipk)
            printf '%s\n' "$package_name" | sed 's/^luci-app-podkop-plus_//;s/_[^_]*\.ipk$//'
            ;;
        luci-app-podkop-plus_*.apk)
            printf '%s\n' "$package_name" | sed 's/^luci-app-podkop-plus_//;s/\.apk$//'
            ;;
        luci-app-podkop-plus-*.ipk)
            printf '%s\n' "$package_name" | sed 's/^luci-app-podkop-plus-//;s/-[^-]*\.ipk$//'
            ;;
        luci-app-podkop-plus-*.apk)
            printf '%s\n' "$package_name" | sed 's/^luci-app-podkop-plus-//;s/\.apk$//'
            ;;
        luci-i18n-podkop-plus-ru_*.ipk)
            printf '%s\n' "$package_name" | sed 's/^luci-i18n-podkop-plus-ru_//;s/_[^_]*\.ipk$//'
            ;;
        luci-i18n-podkop-plus-ru_*.apk)
            printf '%s\n' "$package_name" | sed 's/^luci-i18n-podkop-plus-ru_//;s/\.apk$//'
            ;;
        luci-i18n-podkop-plus-ru-*.ipk)
            printf '%s\n' "$package_name" | sed 's/^luci-i18n-podkop-plus-ru-//;s/-[^-]*\.ipk$//'
            ;;
        luci-i18n-podkop-plus-ru-*.apk)
            printf '%s\n' "$package_name" | sed 's/^luci-i18n-podkop-plus-ru-//;s/\.apk$//'
            ;;
        *)
            printf '%s\n' "$package_name"
            ;;
    esac
}

fetch_github_latest_release_json() {
    owner="$1"
    repo="$2"
    response=""
    message=""
    url="https://api.github.com/repos/${owner}/${repo}/releases/latest"

    response="$(http_get "$url" 2>/dev/null || true)"
    [ -n "$response" ] || fail "Failed to query GitHub latest release metadata for ${owner}/${repo}"

    message="$(printf '%s' "$response" | install_json_ucode github-message 2>/dev/null)" ||
        fail "GitHub returned an invalid latest release response for ${owner}/${repo}"
    case "$message" in
        *"API rate limit"*|*"rate limit exceeded"*)
            fail "GitHub API rate limit reached. Try again later."
            ;;
        "Not Found")
            fail "No published latest release found for ${owner}/${repo}"
            ;;
    esac

    printf '%s' "$response"
}

resolve_podkop_plus_release() {
    asset_ext="ipk"

    [ "$PKG_IS_APK" -eq 1 ] && asset_ext="apk"

    PODKOP_PLUS_RELEASE_JSON="$(fetch_github_latest_release_json "$REPO_OWNER" "$REPO_NAME")"
    PODKOP_PLUS_RELEASE_TAG="$(printf '%s' "$PODKOP_PLUS_RELEASE_JSON" | install_json_ucode release-tag 2>/dev/null)"
    [ -n "$PODKOP_PLUS_RELEASE_TAG" ] || fail "Failed to detect the Podkop Plus release tag"

    PODKOP_PLUS_BACKEND_URL="$(printf '%s' "$PODKOP_PLUS_RELEASE_JSON" | install_json_ucode release-asset-url backend "$asset_ext" 2>/dev/null)"
    [ -n "$PODKOP_PLUS_BACKEND_URL" ] || fail "The Podkop Plus release does not contain a podkop-plus .$asset_ext package"

    PODKOP_PLUS_APP_URL="$(printf '%s' "$PODKOP_PLUS_RELEASE_JSON" | install_json_ucode release-asset-url app "$asset_ext" 2>/dev/null)"
    [ -n "$PODKOP_PLUS_APP_URL" ] || fail "The Podkop Plus release does not contain a luci-app-podkop-plus .$asset_ext package"

    PODKOP_PLUS_BACKEND_NAME="$(basename "$PODKOP_PLUS_BACKEND_URL")"
    PODKOP_PLUS_APP_NAME="$(basename "$PODKOP_PLUS_APP_URL")"
    PODKOP_PLUS_PACKAGE_VERSION="$(extract_package_version "$PODKOP_PLUS_BACKEND_NAME")"

    PODKOP_PLUS_I18N_URL=""
    PODKOP_PLUS_I18N_NAME=""

    if [ "$PODKOP_PLUS_I18N_REQUESTED" -eq 1 ]; then
        PODKOP_PLUS_I18N_URL="$(printf '%s' "$PODKOP_PLUS_RELEASE_JSON" | install_json_ucode release-asset-url i18n "$asset_ext" 2>/dev/null)"
        [ -n "$PODKOP_PLUS_I18N_URL" ] || fail "The Podkop Plus release does not contain a luci-i18n-podkop-plus-ru .$asset_ext package"
        PODKOP_PLUS_I18N_NAME="$(basename "$PODKOP_PLUS_I18N_URL")"
    fi
}

sing_box_version_value() {
    command_exists sing-box || return 0

    if sing_box_compressed_marker_set; then
        read_sing_box_version_state 2>/dev/null || true
        return 0
    fi

    if sing_box_extended_marker_set; then
        read_sing_box_version_state 2>/dev/null && return 0
    fi

    read_sing_box_binary_version /usr/bin/sing-box
}

sing_box_is_extended() {
    version="${1:-}"

    if [ -z "$version" ] && command_exists sing-box &&
        { sing_box_compressed_marker_set || sing_box_extended_marker_set; }; then
        return 0
    fi

    [ -n "$version" ] || version="$(sing_box_version_value)"
    case "$version" in
        *extended*) return 0 ;;
    esac
    return 1
}

sing_box_compressed_marker_set() {
    [ -r "$SING_BOX_VARIANT_STATE_FILE" ] || return 1
    [ "$(cat "$SING_BOX_VARIANT_STATE_FILE" 2>/dev/null)" = "extended-compressed" ]
}

sing_box_extended_marker_set() {
    [ -r "$SING_BOX_VARIANT_STATE_FILE" ] || return 1
    [ "$(cat "$SING_BOX_VARIANT_STATE_FILE" 2>/dev/null)" = "extended" ]
}

sing_box_tiny_marker_set() {
    [ -r "$SING_BOX_VARIANT_STATE_FILE" ] || return 1
    [ "$(cat "$SING_BOX_VARIANT_STATE_FILE" 2>/dev/null)" = "tiny" ]
}

read_sing_box_version_state() {
    [ -r "$SING_BOX_VERSION_STATE_FILE" ] || return 1
    sed -n '1p' "$SING_BOX_VERSION_STATE_FILE" 2>/dev/null
}

read_sing_box_binary_version() {
    binary_path="$1"
    library_dir="${2:-}"

    [ -x "$binary_path" ] || return 1

    if [ -n "$library_dir" ]; then
        LD_LIBRARY_PATH="$library_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$binary_path" version 2>/dev/null | head -n 1 | awk '{print $3}'
    else
        "$binary_path" version 2>/dev/null | head -n 1 | awk '{print $3}'
    fi
}

sing_box_supports_tailscale() {
    sing_box_is_extended && return 0
    command_exists sing-box || return 1
    sing-box version 2>/dev/null | grep -Eq '(^|[,:[:space:]])with_tailscale([,[:space:]]|$)'
}

sing_box_active_variant() {
    if ! command_exists sing-box; then
        printf '%s\n' "none"
        return 0
    fi

    if sing_box_compressed_marker_set; then
        printf '%s\n' "extended-compressed"
        return 0
    fi

    if sing_box_extended_marker_set || sing_box_is_extended; then
        printf '%s\n' "extended"
        return 0
    fi

    if pkg_is_installed "sing-box-tiny" || { sing_box_tiny_marker_set && ! sing_box_supports_tailscale; }; then
        printf '%s\n' "tiny"
        return 0
    fi

    printf '%s\n' "stable"
}

select_sing_box_installation() {
    active_variant="$(sing_box_active_variant)"
    answer=""
    skip_choice=""
    default_choice=1
    next_choice=1
    stable_choice=""
    tiny_choice=""
    extended_choice=""
    extended_compressed_choice=""

    if [ "$active_variant" != "none" ]; then
        skip_choice="$next_choice"
        next_choice=$((next_choice + 1))
    fi
    if [ "$active_variant" != "stable" ]; then
        stable_choice="$next_choice"
        next_choice=$((next_choice + 1))
    fi
    if [ "$active_variant" != "tiny" ]; then
        tiny_choice="$next_choice"
        next_choice=$((next_choice + 1))
    fi
    if [ "$active_variant" != "extended" ]; then
        extended_choice="$next_choice"
        next_choice=$((next_choice + 1))
    fi
    if [ "$active_variant" != "extended-compressed" ]; then
        extended_compressed_choice="$next_choice"
        next_choice=$((next_choice + 1))
    fi

    if [ ! -t 0 ]; then
        if [ "$active_variant" = "none" ]; then
            SING_BOX_INSTALL_VARIANT="stable"
            msg "$(installer_text sing_box_prompt): $default_choice ($(installer_text sing_box_stable), non-interactive)"
        else
            SING_BOX_INSTALL_VARIANT=""
            msg "$(installer_text sing_box_prompt): $default_choice ($(installer_text sing_box_skip), non-interactive)"
        fi
        return 0
    fi

    while :; do
        printf '\n%s\n' "$(installer_text sing_box_prompt)"
        [ -n "$skip_choice" ] && printf '  %s) %s\n' "$skip_choice" "$(installer_text sing_box_skip)"
        [ -n "$stable_choice" ] && printf '  %s) %s\n' "$stable_choice" "$(installer_text sing_box_stable)"
        [ -n "$tiny_choice" ] && printf '  %s) %s\n' "$tiny_choice" "$(installer_text sing_box_tiny)"
        [ -n "$extended_choice" ] && printf '  %s) %s\n' "$extended_choice" "$(installer_text sing_box_extended)"
        [ -n "$extended_compressed_choice" ] && printf '  %s) %s\n' "$extended_compressed_choice" "$(installer_text sing_box_extended_compressed)"
        printf '%s [%s]: ' "$(installer_text select)" "$default_choice"
        read -r answer || return 1
        [ -n "$answer" ] || answer="$default_choice"

        if [ -n "$skip_choice" ] && [ "$answer" = "$skip_choice" ]; then
            SING_BOX_INSTALL_VARIANT=""
            return 0
        fi
        if [ -n "$stable_choice" ] && [ "$answer" = "$stable_choice" ]; then
            SING_BOX_INSTALL_VARIANT="stable"
            return 0
        fi
        if [ -n "$tiny_choice" ] && [ "$answer" = "$tiny_choice" ]; then
            SING_BOX_INSTALL_VARIANT="tiny"
            return 0
        fi
        if [ -n "$extended_choice" ] && [ "$answer" = "$extended_choice" ]; then
            SING_BOX_INSTALL_VARIANT="extended"
            return 0
        fi
        if [ -n "$extended_compressed_choice" ] && [ "$answer" = "$extended_compressed_choice" ]; then
            SING_BOX_INSTALL_VARIANT="extended-compressed"
            return 0
        fi

        warn "$(installer_text invalid_choice)"
    done
}

install_selected_sing_box() {
    action=""
    output_file="$TMP_DIR/sing-box-component-action.json"

    case "$SING_BOX_INSTALL_VARIANT" in
        "")
            msg "$(installer_text sing_box_skip_msg)"
            return 0
            ;;
        stable)
            action="install_stable"
            ;;
        tiny)
            action="install_tiny"
            ;;
        extended)
            action="install_extended"
            ;;
        extended-compressed)
            action="install_extended_compressed"
            ;;
        *)
            fail "Unknown sing-box installation variant: $SING_BOX_INSTALL_VARIANT"
            ;;
    esac

    [ -x /usr/bin/podkop-plus ] || fail "podkop-plus backend must be installed before sing-box component action"
    msg "Installing selected sing-box variant through Podkop Plus ucode backend"
    if ! /usr/bin/podkop-plus component_action sing_box "$action" >"$output_file" 2>&1; then
        cat "$output_file" >&2 2>/dev/null || true
        fail "Failed to install selected sing-box variant"
    fi
}

cleanup_legacy_installation() {
    state_file="$TMP_DIR/install-state.env"

    install_json_ucode installer-cleanup-legacy >"$state_file" ||
        fail "Failed to prepare the system before Podkop Plus package installation"

    # shellcheck disable=SC1090
    . "$state_file"
}

decide_i18n_installation() {
    luci_lang="$(get_luci_main_lang)"

    detect_installer_language

    if pkg_is_installed "luci-i18n-podkop-plus-ru"; then
        PODKOP_PLUS_I18N_REQUESTED=1
        msg "$(installer_text i18n_installed)"
        return 0
    fi

    case "$luci_lang" in
        ru|ru_*|ru-*)
            msg "$(installer_text luci_ru)"
            ;;
    esac

    if confirm_prompt "$(installer_text i18n_prompt)"; then
        PODKOP_PLUS_I18N_REQUESTED=1
        INSTALLER_LANG="ru"
        return 0
    fi

    warn "$(installer_text i18n_skip)"
}

download_podkop_plus_packages() {
    PODKOP_PLUS_BACKEND_FILE="$TMP_DIR/$PODKOP_PLUS_BACKEND_NAME"
    PODKOP_PLUS_APP_FILE="$TMP_DIR/$PODKOP_PLUS_APP_NAME"
    PODKOP_PLUS_I18N_FILE=""

    download_with_retry "$PODKOP_PLUS_BACKEND_URL" "$PODKOP_PLUS_BACKEND_FILE" "$PODKOP_PLUS_BACKEND_NAME" || fail "Failed to download $PODKOP_PLUS_BACKEND_NAME"
    download_with_retry "$PODKOP_PLUS_APP_URL" "$PODKOP_PLUS_APP_FILE" "$PODKOP_PLUS_APP_NAME" || fail "Failed to download $PODKOP_PLUS_APP_NAME"

    if [ -n "$PODKOP_PLUS_I18N_URL" ]; then
        PODKOP_PLUS_I18N_FILE="$TMP_DIR/$PODKOP_PLUS_I18N_NAME"
        download_with_retry "$PODKOP_PLUS_I18N_URL" "$PODKOP_PLUS_I18N_FILE" "$PODKOP_PLUS_I18N_NAME" || fail "Failed to download $PODKOP_PLUS_I18N_NAME"
    fi
}

install_packages() {
    pkg_install_files "$PODKOP_PLUS_BACKEND_FILE" || fail "podkop-plus installation failed"
    pkg_install_files "$PODKOP_PLUS_APP_FILE" || fail "luci-app-podkop-plus installation failed"

    if [ -n "$PODKOP_PLUS_I18N_FILE" ]; then
        pkg_install_files "$PODKOP_PLUS_I18N_FILE" || fail "luci-i18n-podkop-plus-ru installation failed"
    fi
}

post_install() {
    PODKOP_WAS_ENABLED="$PODKOP_WAS_ENABLED" PODKOP_WAS_RUNNING="$PODKOP_WAS_RUNNING" \
        install_json_ucode installer-post-install ||
        fail "Failed to complete Podkop Plus post-install actions"
}

main() {
    trap cleanup EXIT HUP INT TERM

    parse_args "$@"
    check_root
    init_tmp_dir
    detect_fetcher
    sync_time
    check_system

    pkg_list_update || fail "Failed to update package lists"
    ensure_bootstrap_ucode_runtime

    decide_i18n_installation
    select_sing_box_installation

    resolve_podkop_plus_release
    download_podkop_plus_packages

    cleanup_legacy_installation
    install_packages
    install_selected_sing_box
    post_install

    msg "Podkop Plus $PODKOP_PLUS_PACKAGE_VERSION has been installed successfully"
    msg "Source release: ${REPO_OWNER}/${REPO_NAME}@${PODKOP_PLUS_RELEASE_TAG}"
    warn "Open LuCI and review your rules before enabling Podkop Plus"
}

main "$@"
